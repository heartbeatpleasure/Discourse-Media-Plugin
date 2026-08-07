# frozen_string_literal: true

require "json"

module ::MediaGallery
  module ReconciliationCleanup
    extend self

    class UnsafeCleanup < StandardError; end

    CONFIRM_TOKEN = "cleanup_selected_reconciliation_finding"
    PREFIX_DELETE_MAX_ATTEMPTS = 3
    PREFIX_DELETE_RETRY_DELAY_SECONDS = 0.35
    SAFE_DELETE_PREFIX_CLASSIFICATIONS = %w[
      hls_temporary_prefix
      hls_old_package_prefix
      migration_source_leftovers
      local_hls_mirror
      hls_media_prefix
      untracked_media_prefix
    ].freeze

    def cleanup_finding!(finding_key:, confirm:, actor: nil, request: nil)
      raise UnsafeCleanup, "Run storage reconciliation before cleanup." if ::MediaGallery::HealthCheck.last_reconciliation.blank?
      raise UnsafeCleanup, "Cleanup confirmation is missing or invalid." unless confirm.to_s == CONFIRM_TOKEN

      finding = find_active_finding(finding_key)
      raise UnsafeCleanup, "The selected reconciliation finding is no longer active. Run reconciliation again." if finding.blank?
      raise UnsafeCleanup, "This reconciliation finding is not eligible for scoped cleanup." unless truthy?(finding["cleanup_available"])

      kind = finding["cleanup_kind"].to_s
      result = case kind
      when "delete_prefix"
        cleanup_storage_prefix!(finding)
      when "cleanup_deleted_media_item"
        cleanup_deleted_media_item!(finding, actor: actor, request: request)
      when "cleanup_storage_replica"
        cleanup_storage_replica!(finding)
      else
        raise UnsafeCleanup, "Unsupported reconciliation cleanup action."
      end

      log_cleanup!(finding, result, actor: actor, request: request)
      result
    end

    def find_active_finding(finding_key)
      key = finding_key.to_s
      return nil if key.blank?

      report = ::MediaGallery::HealthCheck.reconciliation_export_payload(include_ignored: false)
      Array(report["categories"]).each do |category|
        Array(category["findings"]).each do |finding|
          return finding.merge("category_id" => category["id"].to_s, "category_title" => category["title"].to_s) if finding["key"].to_s == key
        end
      end
      nil
    end

    def cleanup_storage_prefix!(finding)
      classification = finding["classification"].to_s
      unless SAFE_DELETE_PREFIX_CLASSIFICATIONS.include?(classification)
        raise UnsafeCleanup, "This storage prefix classification is not safe for scoped cleanup."
      end

      public_id = finding["public_id"].to_s
      prefix = normalize_key(finding["group_prefix"].presence || finding["storage_key"])
      profile_key = finding["profile_key"].to_s
      backend = finding["backend"].to_s

      validate_public_prefix!(public_id: public_id, prefix: prefix, classification: classification)
      pre_cleanup_verification = validate_prefix_state!(
        finding,
        public_id: public_id,
        prefix: prefix,
        profile_key: profile_key,
        classification: classification,
      )

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      raise UnsafeCleanup, "Storage profile is unavailable for this finding." if store.blank?

      sample_before = Array(store.list_prefix(prefix, limit: 25)).map(&:to_s)
      existed = sample_before.present?
      delete_result = delete_prefix_until_clear(store, prefix)
      remaining = Array(delete_result[:remaining]).map(&:to_s)
      local_directory_cleanup = prune_empty_local_prefix_directory(
        store,
        prefix,
        public_id: public_id,
        remaining: remaining
      )
      local_directory_remaining = truthy?(local_directory_cleanup["remaining"])
      cleanup_complete = remaining.blank? && !local_directory_remaining && (
        delete_result[:delete_succeeded] || truthy?(local_directory_cleanup["removed"])
      )
      status = cleanup_complete ? "complete" : "partial"
      warnings = []
      warnings << "prefix_still_has_objects_after_cleanup" if remaining.present?
      warnings << "delete_prefix_returned_false" unless delete_result[:delete_succeeded]
      warnings << "empty_local_prefix_directory_remains" if local_directory_remaining
      warnings << "empty_local_prefix_directory_cleanup_failed" if local_directory_cleanup["error"].present?

      {
        "schema_version" => 1,
        "mode" => "reconciliation_scoped_prefix_cleanup",
        "status" => status,
        "classification" => classification,
        "public_id" => public_id.presence,
        "profile_key" => profile_key,
        "profile_label" => profile_label(profile_key),
        "backend" => backend,
        "group_prefix" => prefix,
        "existed" => existed,
        "deleted" => cleanup_complete,
        "remaining" => remaining.present? || local_directory_remaining,
        "delete_attempts" => delete_result[:attempts].length,
        "delete_attempt_details" => delete_result[:attempts],
        "sample_keys_before" => sample_before.first(10),
        "remaining_sample_keys" => remaining.first(10),
        "local_prefix_directory_cleanup" => local_directory_cleanup,
        "pre_cleanup_verification" => pre_cleanup_verification.is_a?(Hash) ? pre_cleanup_verification : nil,
        "warnings" => warnings,
        "finished_at" => Time.now.utc.iso8601,
      }.compact
    rescue UnsafeCleanup
      raise
    rescue => e
      raise UnsafeCleanup, "Scoped cleanup failed: #{e.class}: #{e.message}"
    end

    def delete_prefix_until_clear(store, prefix)
      attempts = []
      remaining = []
      delete_succeeded = false

      PREFIX_DELETE_MAX_ATTEMPTS.times do |index|
        attempt_number = index + 1
        deleted = !!store.delete_prefix(prefix)
        delete_succeeded ||= deleted

        sleep(delete_retry_delay_for(store)) if delete_retry_delay_for(store).positive?

        remaining = Array(store.list_prefix(prefix, limit: 10)).map(&:to_s)
        attempts << {
          "attempt" => attempt_number,
          "deleted" => deleted,
          "remaining_sample_count" => remaining.length,
        }

        break if remaining.blank?
      end

      { ok: delete_succeeded && remaining.blank?, delete_succeeded: delete_succeeded, remaining: remaining, attempts: attempts }
    end


    def prune_empty_local_prefix_directory(store, prefix, public_id:, remaining:)
      return { "applicable" => false } unless store.respond_to?(:backend) && store.backend.to_s == "local"
      return { "applicable" => true, "attempted" => false, "remaining" => true, "reason" => "objects_remain" } if remaining.present?
      return { "applicable" => true, "attempted" => false, "remaining" => true, "reason" => "store_method_unavailable" } unless store.respond_to?(:prune_empty_prefix_directory)

      target_existed_before = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(prefix)
      boundary_existed_before = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(public_id)

      target_removed = store.prune_empty_prefix_directory(prefix, boundary_prefix: public_id)
      boundary_removed = if prefix.to_s == public_id.to_s
        target_removed
      else
        store.prune_empty_prefix_directory(public_id, boundary_prefix: public_id)
      end

      target_remains = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(prefix)
      boundary_remains = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(public_id)
      boundary_empty = boundary_remains && store.respond_to?(:prefix_directory_empty?) && store.prefix_directory_empty?(public_id)
      empty_boundary_remains = boundary_remains && boundary_empty

      {
        "applicable" => true,
        "attempted" => target_existed_before || boundary_existed_before,
        "removed" => !target_remains && !empty_boundary_remains && (target_removed || boundary_removed),
        "remaining" => target_remains || empty_boundary_remains,
        "target_directory_remaining" => target_remains,
        "boundary_directory_remaining" => boundary_remains,
        "boundary_directory_empty" => boundary_empty,
        "checked_prefix" => prefix,
        "boundary_prefix" => public_id,
      }
    rescue => e
      {
        "applicable" => true,
        "attempted" => true,
        "removed" => false,
        "remaining" => true,
        "target_directory_remaining" => true,
        "boundary_directory_remaining" => true,
        "checked_prefix" => prefix,
        "boundary_prefix" => public_id,
        "error" => "#{e.class}: #{e.message}",
      }
    end

    def delete_retry_delay_for(store)
      store.respond_to?(:backend) && store.backend.to_s == "s3" ? PREFIX_DELETE_RETRY_DELAY_SECONDS : 0.0
    rescue
      0.0
    end

    def finding_active?(finding_key)
      find_active_finding(finding_key).present?
    rescue
      false
    end

    def cleanup_storage_replica!(finding)
      public_id = finding["public_id"].to_s
      raise UnsafeCleanup, "Replica cleanup finding has no media public_id." if public_id.blank?

      item = ::MediaGallery::MediaItem.find_by(public_id: public_id)
      raise UnsafeCleanup, "Secondary replica cleanup requires the media item to still exist." if item.blank?

      ::MediaGallery::StorageReplica.synchronize_item(item) do
        item.reload
        cleanup_storage_replica_locked!(finding, item)
      end
    rescue UnsafeCleanup
      raise
    rescue => e
      raise UnsafeCleanup, "Secondary replica cleanup failed: #{e.class}: #{e.message}"
    end

    def cleanup_storage_replica_locked!(finding, item)
      public_id = item.public_id.to_s
      target_profile_key = finding["profile_key"].to_s
      replica_scope = finding["replica_scope"].to_s.presence || "hls_only"
      raise UnsafeCleanup, "Replica cleanup finding has no destination profile." if target_profile_key.blank?
      raise UnsafeCleanup, "Replica scope is invalid." unless ::MediaGallery::StorageReplica::SCOPES.include?(replica_scope)

      validate_replica_cleanup_context!(item, target_profile_key: target_profile_key)
      verification = verify_active_replica_source(item, replica_scope: replica_scope)
      unless verification["ok"] == true
        Rails.logger.warn(
          "[media_gallery] storage replica cleanup blocked public_id=#{public_id} " \
          "source=#{verification['profile_key']} target=#{target_profile_key} errors=#{Array(verification['errors']).join(',')}"
        )
        raise UnsafeCleanup, "The active primary assets did not pass complete verification; replica cleanup is unsafe."
      end

      # Settings and item profile can change while source verification performs
      # remote listing/read operations. Re-evaluate all destructive guards
      # immediately before opening and deleting from the replica destination.
      item.reload
      validate_replica_cleanup_context!(item, target_profile_key: target_profile_key)

      state_for_target = ::MediaGallery::StorageReplica.state_for_target_scope(
        item,
        target_profile_key: target_profile_key,
        replica_scope: replica_scope,
      )
      layout = ::MediaGallery::StorageReplica.replica_layout_for(
        item,
        replica_scope: replica_scope,
        state: state_for_target,
      )
      validate_replica_layout!(item, layout, replica_scope: replica_scope)

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(target_profile_key)
      raise UnsafeCleanup, "Replica destination profile is unavailable." if store.blank?
      store.ensure_available!

      deleted_keys = []
      deleted_prefixes = []
      warnings = []
      key_results = []
      prefix_results = []

      Array(layout[:single_keys]).each do |key|
        result = purge_replica_key(store, key)
        ok = truthy?(result["ok"])
        warnings << "replica_key_delete_failed:#{key}" unless ok
        deleted_keys << key if ok
        key_results << result.merge("key" => key, "deleted" => ok).except("ok")
      end

      Array(layout[:prefixes]).each do |prefix|
        result = purge_replica_prefix(store, prefix)
        remaining = Array(result["remaining_sample_keys"]).map(&:to_s)
        local_cleanup = prune_empty_local_prefix_directory(store, prefix, public_id: public_id, remaining: remaining)
        ok = truthy?(result["ok"]) && remaining.blank? && !truthy?(local_cleanup["remaining"])
        warnings << "replica_prefix_delete_failed:#{prefix}" unless ok
        deleted_prefixes << prefix if ok
        prefix_results << result.merge(
          "prefix" => prefix,
          "deleted" => ok,
          "local_directory_cleanup" => local_cleanup,
        ).except("ok")
      end

      local_item_directory_cleanup = prune_empty_replica_item_directory(
        store,
        public_id,
        object_cleanup_succeeded: warnings.blank?,
      )
      if truthy?(local_item_directory_cleanup["remaining"]) && truthy?(local_item_directory_cleanup["empty"])
        warnings << "empty_local_replica_item_directory_remains"
      end

      complete = warnings.blank?
      ::MediaGallery::StorageReplica.mark_cleaned!(
        item,
        target_profile_key: target_profile_key,
        replica_scope: replica_scope,
        deleted_keys: deleted_keys,
        deleted_prefixes: deleted_prefixes,
      ) if complete

      {
        "schema_version" => 2,
        "mode" => "reconciliation_storage_replica_cleanup",
        "status" => complete ? "complete" : "partial",
        "classification" => "storage_replica",
        "public_id" => public_id,
        "profile_key" => target_profile_key,
        "profile_label" => profile_label(target_profile_key),
        "backend" => ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(target_profile_key),
        "group_prefix" => public_id,
        "replica_scope" => replica_scope,
        "deleted" => complete,
        "remaining" => !complete,
        "key_results" => key_results,
        "prefix_results" => prefix_results,
        "local_item_directory_cleanup" => local_item_directory_cleanup,
        "pre_cleanup_verification" => verification,
        "warnings" => warnings,
        "finished_at" => Time.now.utc.iso8601,
      }
    end

    # Replica cleanup must reclaim the complete destination copy. On versioned
    # S3-compatible stores that includes historical object versions and delete
    # markers, not only the currently visible object. Stores without purge
    # support retain the previous current-object deletion behavior.
    def purge_replica_key(store, key)
      existed = safe_store_exists(store, key)

      if store.respond_to?(:purge_key!)
        begin
          raw = stringify_cleanup_hash(store.purge_key!(key))
          remaining = safe_store_exists(store, key)
          current_cleared = remaining == false ||
            (remaining.nil? && raw["remaining_current_count"].to_i.zero?)
          versions_cleared = raw["remaining_version_entries"].nil? ||
            raw["remaining_version_entries"].to_i.zero?
          ok = truthy?(raw["ok"]) && current_cleared && versions_cleared

          return {
            "ok" => ok,
            "method" => "purge_key",
            "existed" => existed,
            "remaining" => remaining,
            "purge_result" => raw,
          }.compact
        rescue NotImplementedError
          # Compatibility with custom stores that inherit the abstract method.
        rescue => e
          return {
            "ok" => false,
            "method" => "purge_key",
            "existed" => existed,
            "remaining" => safe_store_exists(store, key),
            "error" => "#{e.class}: #{e.message}",
          }.compact
        end
      end

      deleted = existed ? !!store.delete(key) : true
      remaining = safe_store_exists(store, key)
      ok = remaining == false || (remaining.nil? && deleted)
      {
        "ok" => ok,
        "method" => "delete",
        "existed" => existed,
        "remaining" => remaining,
      }.compact
    end

    def purge_replica_prefix(store, prefix)
      sample_before = Array(store.list_prefix(prefix, limit: 10)).map(&:to_s)

      if store.respond_to?(:purge_prefix!)
        begin
          raw = stringify_cleanup_hash(store.purge_prefix!(prefix))
          remaining = Array(store.list_prefix(prefix, limit: 10)).map(&:to_s)
          current_cleared = remaining.blank? && raw["remaining_current_count"].to_i.zero?
          versions_cleared = raw["remaining_version_entries"].nil? ||
            raw["remaining_version_entries"].to_i.zero?
          ok = truthy?(raw["ok"]) && current_cleared && versions_cleared

          return {
            "ok" => ok,
            "method" => "purge_prefix",
            "existed" => sample_before.present? || truthy?(raw["existed"]),
            "remaining_sample_keys" => remaining.first(10),
            "purge_result" => raw,
          }.compact
        rescue NotImplementedError
          # Compatibility with custom stores that inherit the abstract method.
        rescue => e
          return {
            "ok" => false,
            "method" => "purge_prefix",
            "existed" => sample_before.present?,
            "remaining_sample_keys" => Array(store.list_prefix(prefix, limit: 10)).map(&:to_s),
            "error" => "#{e.class}: #{e.message}",
          }.compact
        end
      end

      result = delete_prefix_until_clear(store, prefix)
      remaining = Array(result[:remaining]).map(&:to_s)
      {
        "ok" => truthy?(result[:ok]),
        "method" => "delete_prefix",
        "existed" => sample_before.present?,
        "remaining_sample_keys" => remaining.first(10),
        "delete_attempts" => result[:attempts],
      }.compact
    end

    def stringify_cleanup_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
    end

    def validate_replica_cleanup_context!(item, target_profile_key:)
      if ::MediaGallery::StorageReplica.current_replica_target_expected_for?(
        item,
        target_profile_key: target_profile_key,
      )
        raise UnsafeCleanup, "This destination is currently enabled as the secondary replica. Disable it or choose another destination before cleanup."
      end

      source_profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
      if source_profile_key.blank? || source_profile_key == target_profile_key.to_s
        raise UnsafeCleanup, "The replica destination is now the item's active profile."
      end

      source_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(source_profile_key).to_s.presence
      target_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(target_profile_key).to_s.presence
      if source_location.present? && target_location.present? && source_location == target_location
        raise UnsafeCleanup, "The active profile and replica destination point to the same storage location."
      end

      true
    end

    def prune_empty_replica_item_directory(store, public_id, object_cleanup_succeeded:)
      return { "applicable" => false } unless store.respond_to?(:backend) && store.backend.to_s == "local"
      return { "applicable" => true, "attempted" => false, "reason" => "object_cleanup_incomplete" } unless object_cleanup_succeeded
      return { "applicable" => true, "attempted" => false, "reason" => "store_method_unavailable" } unless store.respond_to?(:prune_empty_prefix_directory)

      existed = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(public_id)
      empty_before = existed && store.respond_to?(:prefix_directory_empty?) && store.prefix_directory_empty?(public_id)
      removed = empty_before ? store.prune_empty_prefix_directory(public_id, boundary_prefix: public_id) : false
      remains = store.respond_to?(:prefix_directory_exists?) && store.prefix_directory_exists?(public_id)
      empty_after = remains && store.respond_to?(:prefix_directory_empty?) && store.prefix_directory_empty?(public_id)
      {
        "applicable" => true,
        "attempted" => !!empty_before,
        "removed" => !!removed,
        "remaining" => !!remains,
        "empty" => !!empty_after,
      }
    rescue => e
      { "applicable" => true, "attempted" => true, "removed" => false, "remaining" => true, "error" => "#{e.class}: #{e.message}" }
    end

    def verify_active_replica_source(item, replica_scope:)
      errors = []
      checked = []
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      errors << "active_profile_store_unavailable" if store.blank?
      return { "ok" => false, "profile_key" => profile_key, "errors" => errors } if errors.present?

      store.ensure_available!
      roles = ::MediaGallery::StorageReplica.role_names_for_scope(replica_scope)
      roles.each do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank? && %w[thumbnail hls].include?(role_name)
        if role.blank?
          errors << "#{role_name}_role_missing"
          next
        end

        if role_name == "hls"
          hls_result = verify_active_remote_hls_package(item, role: role)
          errors.concat(Array(hls_result["errors"])) unless hls_result["ok"] == true
          checked.concat(Array(hls_result["checked_keys"]))
        else
          key = normalize_key(role["key"])
          expected_key = if role_name == "main"
            normalize_key(::MediaGallery::PrivateStorage.processed_rel_path(item))
          else
            normalize_key(::MediaGallery::PrivateStorage.thumbnail_rel_path(item))
          end
          profile_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key).to_s
          errors << "#{role_name}_role_backend_mismatch" unless role["backend"].to_s == profile_backend
          errors << "#{role_name}_key_mismatch" unless key == expected_key
          if key.blank?
            errors << "#{role_name}_key_missing"
            next
          end
          info = store.object_info(key).deep_stringify_keys
          errors << "#{role_name}_object_missing" unless truthy?(info["exists"])
          errors << "#{role_name}_object_empty" if truthy?(info["exists"]) && info["bytes"].to_i <= 0
          checked << key if truthy?(info["exists"])
        end
      end

      {
        "ok" => errors.blank?,
        "profile_key" => profile_key,
        "scope" => replica_scope,
        "checked_objects" => checked.uniq.length,
        "checked_keys" => checked.uniq.first(100),
        "errors" => errors.uniq.first(100),
      }
    rescue => e
      { "ok" => false, "profile_key" => (profile_key rescue nil), "scope" => replica_scope, "errors" => ["replica_source_verification_exception_#{safe_error_token(e.class.name)}"] }
    end

    def validate_replica_layout!(item, layout, replica_scope:)
      public_id = item.public_id.to_s
      allowed_single = [
        ::MediaGallery::PrivateStorage.processed_rel_path(item),
        ::MediaGallery::PrivateStorage.thumbnail_rel_path(item),
      ].map { |key| normalize_key(key) }
      Array(layout[:single_keys]).each do |key|
        normalized = normalize_key(key)
        raise UnsafeCleanup, "Replica cleanup contains an unexpected managed asset key." unless allowed_single.include?(normalized)
      end
      Array(layout[:prefixes]).each do |prefix|
        raise UnsafeCleanup, "Replica cleanup contains an unexpected prefix." unless normalize_key(prefix) == File.join(public_id, "hls")
      end
      if replica_scope == "hls_only" && Array(layout[:single_keys]).present?
        raise UnsafeCleanup, "HLS-only replica cleanup cannot delete main or thumbnail objects."
      end
      true
    end

    def safe_store_exists(store, key)
      !!store.exists?(key)
    rescue
      nil
    end

    def cleanup_deleted_media_item!(finding, actor:, request:)
      public_id = finding["public_id"].to_s
      raise UnsafeCleanup, "Finding has no media public_id." if public_id.blank?

      item = ::MediaGallery::MediaItem.find_by(public_id: public_id)
      raise UnsafeCleanup, "Deleted-media cleanup requires the media record to still exist." if item.blank?
      raise UnsafeCleanup, "This media record is not marked as asset-deleted." unless asset_deleted?(item)

      summary = ::MediaGallery::StorageReplica.synchronize_item(item) do
        ::MediaGallery::MediaAssetCleanup.cleanup_item!(
          item,
          mode: "health_deleted_media_leftovers_cleanup",
          actor: actor,
          request: request,
          note: "Scoped cleanup from Health storage reconciliation.",
          trigger_event_type: "media_gallery_reconciliation_cleanup_completed",
          delete_uploads: false,
          delete_item_prefixes: true,
          delete_filesystem_paths: true
        )
      end

      {
        "schema_version" => 1,
        "mode" => "reconciliation_deleted_media_leftovers_cleanup",
        "status" => summary["status"],
        "classification" => finding["classification"].to_s.presence || "deleted_media_leftovers",
        "public_id" => public_id,
        "media_item_id" => item.id,
        "cleanup_summary" => summary.slice("counts", "warnings", "managed_assets", "storage_prefixes", "filesystem_paths"),
        "warnings" => Array(summary["warnings"]),
        "finished_at" => Time.now.utc.iso8601,
      }
    end

    def validate_public_prefix!(public_id:, prefix:, classification:)
      raise UnsafeCleanup, "Finding has no public_id, so cleanup is not allowed." unless public_id_like?(public_id)
      raise UnsafeCleanup, "Finding has no scoped storage prefix." if prefix.blank?
      unless prefix == public_id || prefix.start_with?("#{public_id}/")
        raise UnsafeCleanup, "Storage prefix does not belong to the finding public_id."
      end

      case classification.to_s
      when "local_hls_mirror"
        raise UnsafeCleanup, "Only the exact local HLS mirror prefix can be cleaned by this action." unless prefix == File.join(public_id, "hls")
      when "hls_media_prefix"
        raise UnsafeCleanup, "Only the HLS prefix can be cleaned for HLS orphan findings." unless prefix == File.join(public_id, "hls")
      when "hls_temporary_prefix"
        raise UnsafeCleanup, "Only hls__tmp_* workspaces can be cleaned by this action." unless prefix.start_with?(File.join(public_id, "hls__tmp_"))
      when "hls_old_package_prefix"
        raise UnsafeCleanup, "Only hls__old_* workspaces can be cleaned by this action." unless prefix.start_with?(File.join(public_id, "hls__old_"))
      when "migration_source_leftovers"
        # Prefix may be the whole public_id or a subfolder when it is on a non-current storage profile.
        true
      when "untracked_media_prefix"
        raise UnsafeCleanup, "Only the exact UUID-scoped media prefix can be cleaned for untracked media." unless prefix == public_id
      else
        raise UnsafeCleanup, "Unsupported cleanup classification."
      end
    end

    def validate_prefix_state!(finding, public_id:, prefix:, profile_key:, classification:)
      raise UnsafeCleanup, "Finding has no storage profile." if profile_key.blank?

      item = ::MediaGallery::MediaItem.find_by(public_id: public_id)
      case classification.to_s
      when "local_hls_mirror"
        validate_local_hls_mirror_cleanup!(item, profile_key: profile_key, prefix: prefix)
      when "hls_media_prefix"
        raise UnsafeCleanup, "The media item still exists; clean it from Management instead." if item.present?
      when "untracked_media_prefix"
        raise UnsafeCleanup, "The media item now exists. Run reconciliation again and clean it from Management if needed." if item.present?
      when "migration_source_leftovers"
        raise UnsafeCleanup, "Migration-source cleanup requires the media item to still exist." if item.blank?
        current_profile = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
        raise UnsafeCleanup, "The finding profile is now the current media profile. Run reconciliation again." if current_profile.blank? || current_profile == profile_key.to_s
        if defined?(::MediaGallery::StorageReplica) && ::MediaGallery::StorageReplica.current_replica_target_expected_for?(item, target_profile_key: profile_key)
          raise UnsafeCleanup, "This profile is currently the configured secondary replica destination. Use replica-aware cleanup after disabling or moving the replica."
        end
        raise UnsafeCleanup, "The active target assets are not available; source cleanup is unsafe." unless active_item_storage_available?(item)
      when "hls_temporary_prefix", "hls_old_package_prefix"
        if item.present?
          active_hls_prefix = active_hls_prefix_for(item)
          if active_hls_prefix.present? && (prefix == active_hls_prefix || prefix.start_with?("#{active_hls_prefix}/"))
            raise UnsafeCleanup, "The selected prefix matches the active HLS package. Run reconciliation again."
          end
        end
      end
    end

    def validate_local_hls_mirror_cleanup!(item, profile_key:, prefix:)
      raise UnsafeCleanup, "Local HLS mirror cleanup requires the media item to still exist." if item.blank?
      if ::MediaGallery::StorageReplica.current_replica_target_expected_for?(item, target_profile_key: "local")
        raise UnsafeCleanup, "Local HLS cleanup is available only after Local storage is no longer enabled as this item's secondary replica destination."
      end
      raise UnsafeCleanup, "The selected finding is not on the local storage profile." unless profile_key.to_s == "local"
      raise UnsafeCleanup, "The selected prefix is not the exact local HLS mirror for this item." unless prefix == File.join(item.public_id.to_s, "hls")
      raise UnsafeCleanup, "Local HLS mirror cleanup applies only to video items." unless item.media_type.to_s == "video"

      current_profile = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
      current_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(current_profile).to_s
      raise UnsafeCleanup, "This item currently uses local storage. Its active HLS package will not be removed." if current_backend == "local"
      raise UnsafeCleanup, "This item does not currently use an S3-compatible storage profile." unless current_backend == "s3"

      role = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash.dig("roles", "hls") : nil
      raise UnsafeCleanup, "The current item has no managed HLS role." unless role.is_a?(Hash)
      raise UnsafeCleanup, "The current HLS role is not stored on an S3-compatible profile." unless role["backend"].to_s == "s3"

      verification = verify_active_remote_hls_package(item, role: role)
      unless verification["ok"] == true
        log_remote_hls_verification_failure(item, verification)
        raise UnsafeCleanup, "The active remote HLS package did not pass complete verification; local HLS replica cleanup is unsafe."
      end

      verification
    end

    def active_item_hls_storage_available?(item, role: nil)
      verification = verify_active_remote_hls_package(item, role: role)
      log_remote_hls_verification_failure(item, verification) unless verification["ok"] == true
      verification["ok"] == true
    rescue
      false
    end

    # Perform a complete deletion guard for a remote HLS package. This is more
    # intentionally expensive than the normal readiness check: it runs only for
    # an explicit local-mirror cleanup and validates every object referenced by
    # the current playlists before the local fallback is removed.
    def verify_active_remote_hls_package(item, role: nil)
      errors = []
      checked_keys = {}
      role ||= item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash.dig("roles", "hls") : nil
      role = role.deep_stringify_keys if role.is_a?(Hash)

      unless item.present? && role.is_a?(Hash)
        return remote_hls_verification_result(item, role, errors: ["managed_hls_role_missing"])
      end

      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
      profile_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key).to_s
      errors << "current_profile_backend_invalid" unless %w[local s3].include?(profile_backend)
      errors << "hls_role_backend_mismatch" unless role["backend"].to_s == profile_backend

      expected_prefix = normalize_key(File.join(item.public_id.to_s, "hls"))
      key_prefix = normalize_key(role["key_prefix"].presence || expected_prefix)
      errors << "hls_role_prefix_mismatch" unless key_prefix == expected_prefix

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      errors << "current_profile_store_unavailable" if store.blank?
      errors << "current_profile_store_backend_mismatch" if store.present? && store.backend.to_s != profile_backend
      return remote_hls_verification_result(item, role, profile_key: profile_key, key_prefix: key_prefix, errors: errors) if errors.present?

      store.ensure_available!
      entries = remote_hls_prefix_entries(store, key_prefix)
      entries_by_key = entries.each_with_object({}) do |entry, memo|
        key = normalize_key(entry["key"] || entry[:key])
        next if key.blank?

        memo[key] = {
          "key" => key,
          "bytes" => (entry["bytes"] || entry[:bytes]).to_i,
        }
      end
      errors << "remote_hls_prefix_empty" if entries_by_key.blank?

      master_key = normalize_key(role["master_key"].presence || File.join(key_prefix, "master.m3u8"))
      complete_key = normalize_key(role["complete_key"].presence || File.join(key_prefix, ".complete"))
      master_raw = read_required_remote_text_object(
        store,
        entries_by_key,
        master_key,
        label: "master_playlist",
        errors: errors,
        checked_keys: checked_keys,
      )
      require_remote_object(entries_by_key, complete_key, label: "complete_marker", errors: errors, checked_keys: checked_keys)

      master_variant_keys = []
      if master_raw.present?
        master_uris = playlist_media_uris(master_raw)
        errors << "master_playlist_has_no_variants" if master_uris.blank?
        master_variant_keys = master_uris.filter_map do |uri|
          resolved = resolve_playlist_object_key(master_key, uri, key_prefix: key_prefix)
          errors << "master_playlist_has_unsafe_variant_uri" if resolved.blank?
          resolved
        end
      end

      variants = ::MediaGallery::Hls.role_variants_for(role)
      errors << "hls_role_has_no_variants" if variants.blank?
      media_playlists = []
      uses_ab_layout = ::MediaGallery::Hls.role_uses_ab_layout?(role)

      variants.each do |variant|
        variant_key = normalize_key(::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: role))
        errors << "master_playlist_missing_variant_#{safe_error_token(variant)}" unless master_variant_keys.include?(variant_key)

        variant_raw = read_required_remote_text_object(
          store,
          entries_by_key,
          variant_key,
          label: "variant_playlist_#{safe_error_token(variant)}",
          errors: errors,
          checked_keys: checked_keys,
        )
        next if variant_raw.blank?

        canonical_media_uris = playlist_media_uris(variant_raw)
        canonical_map_uris = playlist_map_uris(variant_raw)
        errors << "variant_playlist_has_no_segments_#{safe_error_token(variant)}" if canonical_media_uris.blank?
        media_playlists << [variant.to_s, variant_key, variant_raw]

        if uses_ab_layout
          %w[a b].each do |ab|
            ab_playlist_key = normalize_key(File.join(key_prefix, ab, variant.to_s, "index.m3u8"))
            ab_raw = read_required_remote_text_object(
              store,
              entries_by_key,
              ab_playlist_key,
              label: "#{ab}_variant_playlist_#{safe_error_token(variant)}",
              errors: errors,
              checked_keys: checked_keys,
            )
            next if ab_raw.blank?

            ab_media_uris = playlist_media_uris(ab_raw)
            ab_map_uris = playlist_map_uris(ab_raw)
            if normalized_playlist_uri_identities(ab_media_uris) != normalized_playlist_uri_identities(canonical_media_uris)
              errors << "#{ab}_variant_segment_manifest_mismatch_#{safe_error_token(variant)}"
            end
            if normalized_playlist_uri_identities(ab_map_uris) != normalized_playlist_uri_identities(canonical_map_uris)
              errors << "#{ab}_variant_init_manifest_mismatch_#{safe_error_token(variant)}"
            end

            verify_playlist_referenced_objects(
              entries_by_key,
              playlist_key: ab_playlist_key,
              raw: ab_raw,
              key_prefix: key_prefix,
              errors: errors,
              checked_keys: checked_keys,
              label: "#{ab}_variant_#{safe_error_token(variant)}",
            )
            media_playlists << [variant.to_s, ab_playlist_key, ab_raw]
          end
        else
          verify_playlist_referenced_objects(
            entries_by_key,
            playlist_key: variant_key,
            raw: variant_raw,
            key_prefix: key_prefix,
            errors: errors,
            checked_keys: checked_keys,
            label: "variant_#{safe_error_token(variant)}",
          )
        end
      end

      verify_remote_fingerprint_metadata(
        item,
        role,
        store,
        entries_by_key,
        errors: errors,
        checked_keys: checked_keys,
      )
      verify_remote_aes128_state(
        item,
        role,
        media_playlists,
        errors: errors,
      )

      remote_hls_verification_result(
        item,
        role,
        profile_key: profile_key,
        key_prefix: key_prefix,
        errors: errors,
        listed_objects: entries_by_key.length,
        checked_objects: checked_keys.length,
        checked_keys: checked_keys.keys,
      )
    rescue => e
      remote_hls_verification_result(
        item,
        role,
        profile_key: (profile_key rescue nil),
        key_prefix: (key_prefix rescue nil),
        errors: ["remote_hls_verification_exception_#{safe_error_token(e.class.name)}"],
      )
    end

    def remote_hls_prefix_entries(store, key_prefix)
      if store.respond_to?(:list_prefix_entries)
        return Array(store.list_prefix_entries(key_prefix))
      end

      Array(store.list_prefix(key_prefix)).map do |key|
        info = store.respond_to?(:object_info) ? store.object_info(key) : {}
        { "key" => key.to_s, "bytes" => info.is_a?(Hash) ? (info[:bytes] || info["bytes"]).to_i : 0 }
      end
    end

    def require_remote_object(entries_by_key, key, label:, errors:, checked_keys:)
      normalized = normalize_key(key)
      entry = entries_by_key[normalized]
      if entry.blank?
        errors << "#{label}_missing"
        return false
      end
      if entry["bytes"].to_i <= 0
        errors << "#{label}_empty"
        return false
      end

      checked_keys[normalized] = true
      true
    end

    def read_required_remote_text_object(store, entries_by_key, key, label:, errors:, checked_keys:)
      return nil unless require_remote_object(entries_by_key, key, label: label, errors: errors, checked_keys: checked_keys)

      raw = store.read(key).to_s
      if raw.blank?
        errors << "#{label}_unreadable"
        return nil
      end
      unless raw.each_line.any? { |line| line.to_s.strip == "#EXTM3U" }
        errors << "#{label}_invalid_m3u8"
        return nil
      end

      raw
    rescue
      errors << "#{label}_read_failed"
      nil
    end

    def verify_playlist_referenced_objects(entries_by_key, playlist_key:, raw:, key_prefix:, errors:, checked_keys:, label:)
      references = playlist_media_uris(raw) + playlist_map_uris(raw)
      references.each_with_index do |uri, index|
        resolved = resolve_playlist_object_key(playlist_key, uri, key_prefix: key_prefix)
        if resolved.blank?
          errors << "#{label}_unsafe_object_uri_#{index}"
          next
        end

        require_remote_object(
          entries_by_key,
          resolved,
          label: "#{label}_object_#{index}",
          errors: errors,
          checked_keys: checked_keys,
        )
      end
    end

    def verify_remote_fingerprint_metadata(item, role, store, entries_by_key, errors:, checked_keys:)
      key = role["fingerprint_meta_key"].to_s.presence
      return true if key.blank?

      key = normalize_key(key)
      return false unless require_remote_object(entries_by_key, key, label: "fingerprint_metadata", errors: errors, checked_keys: checked_keys)

      raw = store.read(key).to_s
      meta = JSON.parse(raw) rescue nil
      unless meta.is_a?(Hash)
        errors << "fingerprint_metadata_invalid_json"
        return false
      end
      if meta["public_id"].present? && meta["public_id"].to_s != item.public_id.to_s
        errors << "fingerprint_metadata_public_id_mismatch"
      end
      if meta["media_item_id"].present? && meta["media_item_id"].to_i != item.id.to_i
        errors << "fingerprint_metadata_item_id_mismatch"
      end

      true
    rescue
      errors << "fingerprint_metadata_read_failed"
      false
    end

    def verify_remote_aes128_state(item, role, media_playlists, errors:)
      encryption = role["encryption"].is_a?(Hash) ? role["encryption"].deep_stringify_keys : nil
      playlists_with_aes = media_playlists.select { |_variant, _key, raw| playlist_aes128_key_uris(raw).present? }

      if encryption.blank?
        errors << "aes128_playlist_present_without_role_metadata" if playlists_with_aes.present?
        return playlists_with_aes.blank?
      end

      unless encryption["method"].to_s.casecmp("AES-128").zero?
        errors << "unsupported_hls_encryption_method"
        return false
      end

      errors << "aes128_role_not_ready" unless truthy?(encryption["ready"])
      key_id = encryption["key_id"].to_s.presence
      errors << "aes128_role_key_id_missing" if key_id.blank?
      errors << "aes128_role_scheme_missing" if encryption["scheme"].to_s.blank?

      media_playlists.each do |variant, playlist_key, raw|
        key_uris = playlist_aes128_key_uris(raw)
        if key_uris.blank?
          errors << "aes128_key_tag_missing_#{safe_error_token(playlist_key)}"
          next
        end

        key_uris.each do |uri|
          parsed_key_id = ::MediaGallery::HlsAes128.key_id_from_placeholder_uri(uri)
          if parsed_key_id.blank? || (key_id.present? && parsed_key_id.to_s != key_id.to_s)
            errors << "aes128_key_tag_mismatch_#{safe_error_token(playlist_key)}"
          end
        end

        next if key_id.blank?
        key_bytes = ::MediaGallery::HlsAes128.fetch_key_bytes(item: item, key_id: key_id, variant: variant)
        unless ::MediaGallery::HlsAes128.valid_key_bytes?(key_bytes)
          errors << "aes128_key_record_missing_#{safe_error_token(variant)}"
        end
      end

      errors.none? { |error| error.to_s.start_with?("aes128_") || error.to_s == "unsupported_hls_encryption_method" }
    rescue
      errors << "aes128_state_verification_failed"
      false
    end

    def playlist_media_uris(raw)
      raw.to_s.each_line.filter_map do |line|
        value = line.to_s.strip
        next if value.blank? || value.start_with?("#")

        value
      end
    end

    def playlist_map_uris(raw)
      raw.to_s.each_line.filter_map do |line|
        value = line.to_s.strip
        next unless value.start_with?("#EXT-X-MAP:")

        value[/URI="([^"]+)"/i, 1].to_s.presence
      end
    end

    def playlist_aes128_key_uris(raw)
      raw.to_s.each_line.filter_map do |line|
        value = line.to_s.strip
        next unless value.start_with?("#EXT-X-KEY:") && value.match?(/METHOD=AES-128/i)

        value[/URI="([^"]+)"/i, 1].to_s.presence
      end
    end

    def normalized_playlist_uri_identities(uris)
      Array(uris).map do |uri|
        uri.to_s.split(/[?#]/, 2).first.to_s.sub(%r{\A\./}, "")
      end
    end

    def resolve_playlist_object_key(playlist_key, uri, key_prefix:)
      raw = uri.to_s.split(/[?#]/, 2).first.to_s.strip
      return nil if raw.blank?
      return nil if raw.start_with?("/") || raw.match?(%r{\A[a-z][a-z0-9+.-]*://}i)

      base_dir = File.dirname(normalize_key(playlist_key))
      resolved = normalize_key(File.expand_path(raw, File.join("/", base_dir)).delete_prefix("/"))
      prefix = normalize_key(key_prefix)
      return nil unless resolved == prefix || resolved.start_with?("#{prefix}/")

      resolved
    rescue
      nil
    end

    def remote_hls_verification_result(item, role, profile_key: nil, key_prefix: nil, errors:, listed_objects: 0, checked_objects: 0, checked_keys: nil)
      normalized_errors = Array(errors).map(&:to_s).reject(&:blank?).uniq.first(100)
      {
        "ok" => normalized_errors.blank?,
        "public_id" => item&.public_id.to_s.presence,
        "media_item_id" => item&.id,
        "profile_key" => profile_key.to_s.presence,
        "role_backend" => role.is_a?(Hash) ? role["backend"].to_s.presence : nil,
        "key_prefix" => key_prefix.to_s.presence,
        "listed_objects" => listed_objects.to_i,
        "checked_objects" => checked_objects.to_i,
        "checked_keys" => Array(checked_keys).map(&:to_s).reject(&:blank?).first(100),
        "errors" => normalized_errors,
      }.compact
    end

    def log_remote_hls_verification_failure(item, verification)
      return if verification.is_a?(Hash) && verification["ok"] == true

      errors = verification.is_a?(Hash) ? Array(verification["errors"]).first(20) : ["verification_result_missing"]
      Rails.logger.warn(
        "[media_gallery] local HLS mirror cleanup blocked public_id=#{item&.public_id} " \
        "profile_key=#{verification.is_a?(Hash) ? verification['profile_key'] : nil} errors=#{errors.join(',')}"
      )
    rescue
      nil
    end

    def safe_error_token(value)
      value.to_s.gsub(/[^a-zA-Z0-9_-]+/, "_").downcase[0, 120]
    end

    def active_item_storage_available?(item)
      roles = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash.dig("roles") : nil
      roles = roles.is_a?(Hash) ? roles : {}
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      return false if store.blank?

      if item.media_type.to_s == "video" && roles["hls"].is_a?(Hash)
        role = roles["hls"]
        master_key = role["master_key"].to_s.presence || File.join(item.public_id.to_s, "hls", "master.m3u8")
        complete_key = role["complete_key"].to_s.presence
        return false unless store.exists?(master_key)
        return true if complete_key.blank?
        store.exists?(complete_key)
      else
        role = roles["main"].is_a?(Hash) ? roles["main"] : {}
        key = role["key"].to_s.presence
        key.present? && store.exists?(key)
      end
    rescue
      false
    end

    def active_hls_prefix_for(item)
      role = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash.dig("roles", "hls") : nil
      return nil unless role.is_a?(Hash)
      normalize_key(role["key_prefix"].presence || File.join(item.public_id.to_s, "hls"))
    rescue
      nil
    end

    def log_cleanup!(finding, result, actor:, request:)
      event = result["status"].to_s == "complete" ? "media_gallery_reconciliation_cleanup_completed" : "media_gallery_reconciliation_cleanup_partial"
      severity = result["status"].to_s == "complete" ? "info" : "warning"
      item = ::MediaGallery::MediaItem.find_by(public_id: finding["public_id"].to_s) if finding["public_id"].present?

      ::MediaGallery::OperationLogger.public_send(
        severity == "warning" ? :warn : :info,
        event,
        item: item,
        operation: "storage_reconciliation_cleanup",
        data: {
          finding_key: finding["key"],
          category: finding["category_id"],
          classification: finding["classification"],
          profile_key: finding["profile_key"],
          group_prefix: finding["group_prefix"],
          status: result["status"],
          warnings: Array(result["warnings"]).first(10),
        }
      )

      if defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.respond_to?(:record)
        ::MediaGallery::LogEvents.record(
          event_type: event,
          severity: severity,
          category: "storage",
          request: request,
          user: actor,
          media_item: item,
          message: cleanup_message(result),
          details: {
            finding_key: finding["key"],
            category: finding["category_id"],
            classification: finding["classification"],
            profile_key: finding["profile_key"],
            group_prefix: finding["group_prefix"],
            cleanup: result.except("sample_keys_before", "cleanup_summary"),
          }
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] reconciliation cleanup logging failed: #{e.class}: #{e.message}")
    end

    def cleanup_message(result)
      prefix = result["group_prefix"].to_s.presence
      context = prefix.present? ? " for #{prefix}" : ""
      suffix = result["status"].to_s == "complete" ? "completed" : "completed with warnings"
      "Scoped storage reconciliation cleanup#{context} #{suffix}."
    end

    def asset_deleted?(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      meta["reported_asset_deletion"].is_a?(Hash) || meta["asset_deleted_after_report"].present? || item.status.to_s == "asset_deleted"
    end

    def public_id_like?(value)
      ::MediaGallery::StorageReconciler::PUBLIC_ID_PATTERN.match?(value.to_s)
    rescue
      false
    end

    def normalize_key(key)
      key.to_s.sub(%r{\A/+}, "").delete_suffix("/")
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def profile_label(profile_key)
      ::MediaGallery::StorageSettingsResolver.profile_label_for_key(profile_key)
    rescue
      profile_key.to_s
    end
  end
end
