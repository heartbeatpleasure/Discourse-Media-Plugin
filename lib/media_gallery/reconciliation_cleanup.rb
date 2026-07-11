# frozen_string_literal: true

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
      validate_prefix_state!(finding, public_id: public_id, prefix: prefix, profile_key: profile_key, classification: classification)

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

    def cleanup_deleted_media_item!(finding, actor:, request:)
      public_id = finding["public_id"].to_s
      raise UnsafeCleanup, "Finding has no media public_id." if public_id.blank?

      item = ::MediaGallery::MediaItem.find_by(public_id: public_id)
      raise UnsafeCleanup, "Deleted-media cleanup requires the media record to still exist." if item.blank?
      raise UnsafeCleanup, "This media record is not marked as asset-deleted." unless asset_deleted?(item)

      summary = ::MediaGallery::MediaAssetCleanup.cleanup_item!(
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
      when "hls_media_prefix"
        raise UnsafeCleanup, "The media item still exists; clean it from Management instead." if item.present?
      when "untracked_media_prefix"
        raise UnsafeCleanup, "The media item now exists. Run reconciliation again and clean it from Management if needed." if item.present?
      when "migration_source_leftovers"
        raise UnsafeCleanup, "Migration-source cleanup requires the media item to still exist." if item.blank?
        current_profile = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
        raise UnsafeCleanup, "The finding profile is now the current media profile. Run reconciliation again." if current_profile.blank? || current_profile == profile_key.to_s
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
