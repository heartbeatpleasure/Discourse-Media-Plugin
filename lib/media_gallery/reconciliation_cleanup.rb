# frozen_string_literal: true

module ::MediaGallery
  module ReconciliationCleanup
    extend self

    class UnsafeCleanup < StandardError; end

    CONFIRM_TOKEN = "cleanup_selected_reconciliation_finding"
    SAFE_DELETE_PREFIX_CLASSIFICATIONS = %w[
      hls_temporary_prefix
      hls_old_package_prefix
      migration_source_leftovers
      hls_media_prefix
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
      deleted = !!store.delete_prefix(prefix)
      remaining = Array(store.list_prefix(prefix, limit: 1)).map(&:to_s)
      status = deleted && remaining.blank? ? "complete" : "partial"

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
        "deleted" => deleted,
        "remaining" => remaining.present?,
        "sample_keys_before" => sample_before.first(10),
        "warnings" => remaining.present? || !deleted ? ["delete_prefix_failed_or_remaining_objects"] : [],
        "finished_at" => Time.now.utc.iso8601,
      }.compact
    rescue UnsafeCleanup
      raise
    rescue => e
      raise UnsafeCleanup, "Scoped cleanup failed: #{e.class}: #{e.message}"
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
