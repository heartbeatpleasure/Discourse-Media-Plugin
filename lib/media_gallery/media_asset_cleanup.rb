# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MediaAssetCleanup
    extend self

    ROLE_NAMES = %w[main thumbnail hls].freeze

    def cleanup_item!(item, mode:, actor: nil, request: nil, note: nil, trigger_event_type: nil, delete_uploads: true, delete_item_prefixes: true, delete_filesystem_paths: true)
      raise ArgumentError, "media_item_missing" if item.blank?

      summary = build_summary(item, mode: mode, actor: actor, note: note, trigger_event_type: trigger_event_type)
      roles = roles_for_cleanup(item)

      delete_managed_roles!(item, roles, summary)
      delete_item_prefixes!(item, summary) if delete_item_prefixes
      delete_uploads!(item, roles, summary) if delete_uploads
      delete_filesystem_paths!(item, summary) if delete_filesystem_paths

      finalize_summary!(summary)
      log_cleanup_result!(item, summary, actor: actor, request: request)
      summary
    end

    private

    def build_summary(item, mode:, actor:, note: nil, trigger_event_type: nil)
      {
        "schema_version" => 1,
        "mode" => mode.to_s.presence || "media_asset_cleanup",
        "public_id" => item.public_id.to_s,
        "media_item_id" => item.id,
        "title_present" => item.title.to_s.present?,
        "managed_storage_backend" => item.try(:managed_storage_backend).to_s.presence,
        "managed_storage_profile" => item.try(:managed_storage_profile).to_s.presence,
        "actor_id" => actor&.id,
        "actor_username" => actor&.username,
        "note_present" => note.to_s.present?,
        "trigger_event_type" => trigger_event_type.to_s.presence || default_trigger_event_type(mode),
        "started_at" => Time.now.utc.iso8601,
        "managed_assets" => [],
        "storage_prefixes" => [],
        "uploads" => [],
        "filesystem_paths" => [],
        "warnings" => [],
      }.compact
    end

    def roles_for_cleanup(item)
      roles = []
      manifest_roles = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash.dig("roles") : nil
      manifest_roles = manifest_roles.is_a?(Hash) ? manifest_roles : {}

      ROLE_NAMES.each do |role_name|
        stored = manifest_roles[role_name]
        roles << normalize_role(role_name, stored, source: "storage_manifest") if stored.is_a?(Hash)

        resolved = ::MediaGallery::AssetManifest.role_for(item, role_name)
        roles << normalize_role(role_name, resolved, source: "resolved_role") if resolved.is_a?(Hash)
      rescue => e
        roles << {
          "role" => role_name,
          "source" => "role_resolution_error",
          "warning" => "#{e.class}: #{e.message}",
        }
      end

      dedupe_roles(roles.compact)
    end

    def normalize_role(role_name, role, source:)
      value = role.deep_stringify_keys
      value["role"] = role_name.to_s
      value["source"] = source.to_s
      value
    end

    def dedupe_roles(roles)
      seen = {}
      roles.each_with_object([]) do |role, acc|
        key = [
          role["role"].to_s,
          role["backend"].to_s,
          role["profile"].to_s.presence || role["profile_key"].to_s.presence,
          role["key"].to_s.presence,
          role["key_prefix"].to_s.presence,
          role["upload_id"].to_s.presence,
        ].join("|")
        next if seen[key]

        seen[key] = true
        acc << role
      end
    end

    def delete_managed_roles!(item, roles, summary)
      roles.each do |role|
        warning = role["warning"].to_s.presence
        if warning.present?
          add_warning!(summary, "#{role['role']}: #{warning}")
          next
        end

        backend = role["backend"].to_s
        next unless %w[local s3].include?(backend)

        if role["role"].to_s == "hls"
          delete_role_prefix!(item, role, summary)
        else
          delete_role_key!(item, role, summary)
        end
      end
    end

    def delete_role_key!(item, role, summary)
      key = role["key"].to_s.presence
      result = base_managed_asset_result(role).merge("key" => key.to_s)

      if key.blank?
        result["warning"] = "key_missing"
        add_warning!(summary, "#{role['role']}: key_missing")
        summary["managed_assets"] << result
        return
      end

      begin
        store, profile_key = store_for_role(item, role)
        result["profile_key"] = profile_key if profile_key.present?
        result["profile_label"] = profile_label(profile_key) if profile_key.present?
        if store.blank?
          result["warning"] = "store_missing"
        else
          result["existed"] = safe_store_exists?(store, key)
          deleted = !!store.delete(key)
          remaining = safe_store_exists?(store, key)
          result["deleted"] = deleted && remaining != true
          result["remaining"] = remaining if !remaining.nil?
          result["warning"] = "delete_failed" if remaining == true || !deleted
        end
      rescue => e
        result["warning"] = "#{e.class}: #{e.message}"
      end

      add_warning!(summary, "#{role['role']}: #{result['warning']}") if result["warning"].present?
      summary["managed_assets"] << result.compact
    end

    def delete_role_prefix!(item, role, summary)
      public_id = item.public_id.to_s
      prefix = role["key_prefix"].presence || role["key"].presence || ::MediaGallery::PrivateStorage.hls_root_rel_dir(public_id)
      result = base_managed_asset_result(role).merge("key_prefix" => prefix.to_s)

      if prefix.blank?
        result["warning"] = "key_prefix_missing"
        add_warning!(summary, "#{role['role']}: key_prefix_missing")
        summary["managed_assets"] << result
        return
      end

      begin
        store, profile_key = store_for_role(item, role)
        result["profile_key"] = profile_key if profile_key.present?
        result["profile_label"] = profile_label(profile_key) if profile_key.present?
        if store.blank?
          result["warning"] = "store_missing"
        else
          result["existed"] = safe_prefix_exists?(store, prefix)
          deleted = !!store.delete_prefix(prefix.to_s)
          remaining = safe_prefix_exists?(store, prefix)
          result["deleted"] = deleted && remaining != true
          result["remaining"] = remaining if !remaining.nil?
          result["warning"] = "delete_prefix_failed" if remaining == true || !deleted
        end
      rescue => e
        result["warning"] = "#{e.class}: #{e.message}"
      end

      add_warning!(summary, "#{role['role']}: #{result['warning']}") if result["warning"].present?
      summary["managed_assets"] << result.compact
    end

    def base_managed_asset_result(role)
      {
        "role" => role["role"].to_s,
        "source" => role["source"].to_s.presence,
        "backend" => role["backend"].to_s,
        "deleted" => false,
      }.compact
    end

    def delete_item_prefixes!(item, summary)
      public_id = item.public_id.to_s
      prefix = item_prefix(public_id)
      return if prefix.blank?

      profile_keys_for_prefix_cleanup(item).each do |profile_key|
        result = {
          "profile_key" => profile_key,
          "profile_label" => profile_label(profile_key),
          "backend" => ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key).to_s,
          "key_prefix" => prefix,
          "deleted" => false,
        }.compact

        begin
          store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
          if store.blank?
            result["warning"] = "store_missing"
          else
            result["existed"] = safe_prefix_exists?(store, prefix)
            deleted = !!store.delete_prefix(prefix)
            remaining = safe_prefix_exists?(store, prefix)
            result["deleted"] = deleted && remaining != true
            result["remaining"] = remaining if !remaining.nil?
            result["warning"] = "delete_prefix_failed" if remaining == true || !deleted
          end
        rescue => e
          result["warning"] = "#{e.class}: #{e.message}"
        end

        add_warning!(summary, "#{profile_key}/#{prefix}: #{result['warning']}") if result["warning"].present?
        summary["storage_prefixes"] << result.compact
      end
    end

    def delete_uploads!(item, roles, summary)
      upload_ids = upload_ids_for_cleanup(item, roles)
      uploads = upload_ids.present? ? ::Upload.where(id: upload_ids).to_a : []
      found_ids = uploads.map(&:id)

      (upload_ids - found_ids).each do |missing_id|
        summary["uploads"] << { "id" => missing_id, "deleted" => true, "existed" => false }
      end

      uploads.each do |upload|
        result = {
          "id" => upload.id,
          "original_filename" => upload.try(:original_filename).to_s,
          "sha1" => upload.try(:sha1).to_s,
          "filesize" => upload.try(:filesize),
          "deleted" => false,
          "existed" => true,
        }.compact

        begin
          if defined?(::UploadDestroyer)
            ::UploadDestroyer.new(Discourse.system_user, upload).destroy
          else
            upload.destroy!
          end
          result["deleted"] = !::Upload.exists?(id: upload.id)
          result["warning"] = "upload_delete_failed" unless result["deleted"]
        rescue => e
          result["warning"] = "#{e.class}: #{e.message}"
        end

        add_warning!(summary, "upload #{upload.id}: #{result['warning']}") if result["warning"].present?
        summary["uploads"] << result.compact
      end
    end

    def delete_filesystem_paths!(item, summary)
      public_id = item.public_id.to_s
      [
        { "label" => "private_dir", "path" => ::MediaGallery::PrivateStorage.item_private_dir(public_id), "root" => ::MediaGallery::PrivateStorage.private_root },
        { "label" => "original_export_dir", "path" => ::MediaGallery::PrivateStorage.item_original_dir(public_id), "root" => ::MediaGallery::PrivateStorage.original_export_root },
      ].each do |entry|
        result = entry.slice("label", "path").merge("removed" => false)

        begin
          if entry["path"].present? && Dir.exist?(entry["path"])
            ::MediaGallery::PathSecurity.remove_tree_under!(entry["path"], entry["root"].to_s)
            result["removed"] = !Dir.exist?(entry["path"])
            result["warning"] = "filesystem_remove_failed" unless result["removed"]
          else
            result["removed"] = true
            result["existed"] = false
          end
        rescue => e
          result["warning"] = "#{e.class}: #{e.message}"
        end

        add_warning!(summary, "#{entry['label']}: #{result['warning']}") if result["warning"].present?
        summary["filesystem_paths"] << result.compact
      end
    end

    def store_for_role(item, role)
      profile_key = role["profile_key"].presence || role["profile"].presence || role["storage_profile"].presence
      backend = role["backend"].to_s.presence

      profile_key = item.try(:managed_storage_profile).to_s.presence if profile_key.blank? && backend.present? && item_backend_matches?(item, backend)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item) if profile_key.blank? && backend.blank?

      if profile_key.present?
        normalized = ::MediaGallery::StorageSettingsResolver.normalized_profile_key(profile_key)
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(normalized)
        if backend.present? && store.present? && store.backend.to_s != backend
          fallback = ::MediaGallery::StorageSettingsResolver.build_store(backend)
          return [fallback, profile_key_for_backend(backend)] if fallback.present?
          return [nil, normalized]
        end
        return [store, normalized]
      end

      return [nil, nil] if backend.blank?

      store = ::MediaGallery::StorageSettingsResolver.build_store(backend)
      [store, profile_key_for_backend(backend)]
    end

    def item_backend_matches?(item, backend)
      item.try(:managed_storage_backend).to_s == backend.to_s || ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(item.try(:managed_storage_profile)).to_s == backend.to_s
    rescue
      false
    end

    def profile_key_for_backend(backend)
      ::MediaGallery::StorageSettingsResolver.configured_profile_keys.find do |key|
        ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(key).to_s == backend.to_s
      end
    rescue
      nil
    end

    def profile_keys_for_prefix_cleanup(item)
      keys = []
      keys << item.try(:managed_storage_profile).to_s.presence
      keys << ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      keys.concat(Array(::MediaGallery::StorageSettingsResolver.configured_profile_keys))
      keys.compact.map { |key| ::MediaGallery::StorageSettingsResolver.normalized_profile_key(key) }.compact.uniq
    rescue
      []
    end

    def upload_ids_for_cleanup(item, roles)
      ids = [item.try(:original_upload_id), item.try(:processed_upload_id), item.try(:thumbnail_upload_id)]
      roles.each do |role|
        ids << role["upload_id"] if role["backend"].to_s == "upload"
      end
      ids.compact.map(&:to_i).select(&:positive?).uniq
    end

    def item_prefix(public_id)
      ::MediaGallery::PrivateStorage.safe_path_component(public_id, name: "public_id")
    rescue
      public_id.to_s
    end

    def safe_store_exists?(store, key)
      store.exists?(key.to_s)
    rescue
      nil
    end

    def safe_prefix_exists?(store, prefix)
      Array(store.list_prefix(prefix.to_s, limit: 1)).any?
    rescue
      nil
    end

    def profile_label(profile_key)
      return nil if profile_key.blank?
      ::MediaGallery::StorageSettingsResolver.profile_label_for_key(profile_key)
    rescue
      profile_key.to_s
    end

    def add_warning!(summary, message)
      return if message.to_s.blank?
      summary["warnings"] << message.to_s
      summary["warnings"].uniq!
    end

    def finalize_summary!(summary)
      summary["finished_at"] = Time.now.utc.iso8601
      summary["status"] = summary["warnings"].present? ? "partial" : "complete"
      summary["counts"] = {
        "managed_assets" => summary["managed_assets"].length,
        "storage_prefixes" => summary["storage_prefixes"].length,
        "uploads" => summary["uploads"].length,
        "filesystem_paths" => summary["filesystem_paths"].length,
        "warnings" => summary["warnings"].length,
      }
      summary
    end



    def default_trigger_event_type(mode)
      case mode.to_s
      when "admin_hard_delete"
        "admin_media_item_deleted"
      when "user_hard_delete"
        "user_media_item_deleted"
      when "report_asset_delete_keep_audit_record"
        "report_accept_delete_asset"
      else
        nil
      end
    end

    def cleanup_context_label(summary)
      case summary["mode"].to_s
      when "admin_hard_delete"
        "after admin delete"
      when "user_hard_delete"
        "after user delete"
      when "report_asset_delete_keep_audit_record"
        "after report asset delete"
      else
        "for media asset cleanup"
      end
    end

    def cleanup_log_message(summary)
      suffix = summary["status"].to_s == "complete" ? "completed" : "completed with warnings"
      "Storage cleanup #{cleanup_context_label(summary)} #{suffix}."
    end

    def log_cleanup_result!(item, summary, actor:, request:)
      event = summary["status"] == "complete" ? "media_asset_cleanup_completed" : "media_asset_cleanup_partial"
      severity = summary["status"] == "complete" ? "info" : "warning"

      ::MediaGallery::OperationLogger.public_send(
        severity == "warning" ? :warn : :info,
        event,
        item: item,
        operation: "asset_cleanup",
        data: {
          mode: summary["mode"],
          status: summary["status"],
          actor_username: summary["actor_username"],
          counts: summary["counts"],
          warnings: summary["warnings"].first(10),
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
          message: cleanup_log_message(summary),
          details: {
            mode: summary["mode"],
            trigger_event_type: summary["trigger_event_type"],
            status: summary["status"],
            counts: summary["counts"],
            warnings: summary["warnings"].first(20),
          }
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] cleanup result logging failed public_id=#{item&.public_id} error=#{e.class}: #{e.message}")
    end
  end
end
