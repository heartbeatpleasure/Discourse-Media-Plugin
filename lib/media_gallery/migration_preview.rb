# frozen_string_literal: true

module ::MediaGallery
  module MigrationPreview
    module_function

    SUPPORTED_ROLE_NAMES = %w[main thumbnail hls].freeze


    def objects_for_item(item, store: nil)
      raise "media_item_required" if item.blank?

      SUPPORTED_ROLE_NAMES.flat_map do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next [] if role.blank?

        enumerate_role_objects(item: item, role_name: role_name, role: role, source_store: store).map do |obj|
          obj.merge(role_name: role_name.to_s)
        end
      end.reject { |row| row[:key].to_s.blank? }.uniq { |row| row[:key].to_s }
    end

    def preview(item, target_profile: "target")
      raise "media_item_required" if item.blank?

      source = source_summary_for(item)
      target = target_summary_for(target_profile)
      source_store = build_store_from_summary(source)
      target_store = build_store_from_summary(target)

      role_previews = SUPPORTED_ROLE_NAMES.filter_map do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?

        preview_role(
          item: item,
          role_name: role_name,
          role: role,
          source_store: source_store,
          target_store: target_store
        )
      end

      total_source_bytes = role_previews.sum { |r| r[:summary][:source_bytes].to_i }
      total_target_existing_bytes = role_previews.sum { |r| r[:summary][:target_existing_bytes].to_i }
      source_object_count = role_previews.sum { |r| r[:summary][:object_count].to_i }
      target_existing_count = role_previews.sum { |r| r[:summary][:target_existing_count].to_i }

      warnings = []
      warnings << "target_profile_not_configured" if target[:backend].blank?
      warnings << "source_backend_upload_roles_present" if role_previews.any? { |r| r[:summary][:unsupported_upload_role] }
      warnings << "source_and_target_same_profile" if source[:profile_key].present? && source[:profile_key] == target[:profile_key]
      warnings << "source_and_target_same_location" if source[:location_fingerprint_key].present? && source[:location_fingerprint_key] == target[:location_fingerprint_key]
      warnings.concat(role_previews.flat_map { |r| Array(r[:warnings]) })
      warnings.uniq!

      {
        ok: warnings.exclude?("target_profile_not_configured"),
        public_id: item.public_id,
        status: item.status,
        source: source,
        target: target,
        totals: {
          source_bytes: total_source_bytes,
          target_existing_bytes: total_target_existing_bytes,
          object_count: source_object_count,
          target_existing_count: target_existing_count,
          missing_on_target_count: source_object_count - target_existing_count
        },
        warnings: warnings,
        roles: role_previews,
        safety_summary: migration_safety_summary(
          item: item,
          source: source,
          target: target,
          totals: {
            source_bytes: total_source_bytes,
            object_count: source_object_count,
            target_existing_count: target_existing_count,
            missing_on_target_count: source_object_count - target_existing_count
          },
          warnings: warnings
        ),
        copy_state: ::MediaGallery::MigrationCopy.copy_state_for(item)
      }
    end

    def migration_safety_summary(item:, source:, target:, totals:, warnings:)
      rows = []
      rows << safety_row("Objects to copy", totals[:object_count].to_i, "Object count includes main, thumbnail and HLS objects when present.", totals[:object_count].to_i > 0 ? "ok" : "warning")
      rows << safety_row("Bytes to copy", totals[:source_bytes].to_i, "Approximate source bytes in the dry-run preview.", "ok")
      rows << safety_row("Objects already on target", totals[:target_existing_count].to_i, "Existing objects will usually be skipped or verified instead of overwritten.", totals[:target_existing_count].to_i.positive? ? "warning" : "ok")
      rows << safety_row("Missing on target", totals[:missing_on_target_count].to_i, "Objects still expected to be copied before switching.", totals[:missing_on_target_count].to_i.zero? ? "ok" : "warning")

      if source[:profile_key].present? && target[:profile_key].present? && source[:profile_key].to_s == target[:profile_key].to_s
        rows << safety_row("Source equals target", "yes", "Choose a different destination profile before executing migration.", "critical")
      end
      if source[:location_fingerprint_key].present? && source[:location_fingerprint_key].to_s == target[:location_fingerprint_key].to_s
        rows << safety_row("Same storage location", "yes", "The source and target appear to point to the same storage location.", "critical")
      end

      severity = rows.any? { |r| r[:status] == "critical" } ? "critical" : (rows.any? { |r| r[:status] == "warning" } || Array(warnings).present? ? "warning" : "ok")
      { status: severity, rows: rows, warnings: Array(warnings).map(&:to_s) }
    end
    private_class_method :migration_safety_summary

    def safety_row(label, value, detail, status = "ok")
      { label: label.to_s, value: value, detail: detail.to_s, status: status.to_s }
    end
    private_class_method :safety_row

    def source_summary_for(item)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      backend = item.managed_storage_backend.presence || ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key) || ::MediaGallery::StorageSettingsResolver.active_backend
      {
        profile: profile_key,
        backend: backend,
        profile_key: profile_key,
        label: ::MediaGallery::StorageSettingsResolver.profile_label_for_key(profile_key),
        config: sanitized_config_for_profile_key(profile_key, backend),
        location_fingerprint: ::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(profile_key),
        location_fingerprint_key: ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(profile_key)
      }
    end
    private_class_method :source_summary_for

    def target_summary_for(target_profile)
      ::MediaGallery::StorageSettingsResolver.profile_summary(target_profile).deep_symbolize_keys
    end
    private_class_method :target_summary_for

    def preview_role(item:, role_name:, role:, source_store:, target_store:)
      if role_name.to_s == "hls"
        return preview_hls_role(item: item, role_name: role_name, role: role, source_store: source_store, target_store: target_store)
      end

      objects = enumerate_role_objects(item: item, role_name: role_name, role: role, source_store: source_store)
      warnings = []
      warnings << "source_store_unavailable" if source_store.blank? && role["backend"].to_s != "upload"

      object_rows = objects.map do |obj|
        source_info = source_object_info(source_store: source_store, object: obj)
        target_info = target_object_info(target_store: target_store, key: obj[:key])
        warnings << source_info[:error] if source_info[:error].present?
        warnings << target_info[:error] if target_info[:error].present?

        {
          key: obj[:key],
          content_type: obj[:content_type],
          source: source_info,
          target: target_info
        }
      end

      {
        name: role_name,
        backend: role["backend"].to_s,
        role: role,
        summary: {
          object_count: object_rows.length,
          source_bytes: object_rows.sum { |r| r.dig(:source, :bytes).to_i },
          target_existing_bytes: object_rows.sum { |r| r.dig(:target, :bytes).to_i },
          target_existing_count: object_rows.count { |r| r.dig(:target, :exists) },
          unsupported_upload_role: role["backend"].to_s == "upload"
        },
        warnings: warnings.compact.uniq,
        objects: object_rows
      }
    end
    private_class_method :preview_role

    def preview_hls_role(item:, role_name:, role:, source_store:, target_store:)
      source_store = local_store_for_hls(role, source_store)
      prefix = hls_prefix_for(item, role)
      warnings = []
      warnings << "source_store_unavailable" if source_store.blank? && role["backend"].to_s != "upload"

      source_entries = list_prefix_entries(source_store, prefix)
      target_entries = list_prefix_entries(target_store, prefix)
      source_entries = source_entries.uniq { |entry| entry[:key].to_s }.sort_by { |entry| entry[:key].to_s }
      target_entry_map = target_entries.index_by { |entry| entry[:key].to_s }

      object_rows = source_entries.map do |entry|
        key = entry[:key].to_s
        target_entry = target_entry_map[key]
        {
          key: key,
          content_type: entry[:content_type].presence || content_type_for_hls_key(key),
          source: info_from_prefix_entry(source_store, entry, exists: true),
          target: target_entry.present? ? info_from_prefix_entry(target_store, target_entry, exists: true) : missing_info_for(target_store, key)
        }
      end

      warnings << "hls_role_has_no_objects_on_source" if object_rows.empty?
      warnings << "target_store_missing" if target_store.blank?

      {
        name: role_name,
        backend: role["backend"].to_s,
        role: role,
        summary: {
          object_count: object_rows.length,
          source_bytes: object_rows.sum { |r| r.dig(:source, :bytes).to_i },
          target_existing_bytes: object_rows.sum { |r| r.dig(:target, :bytes).to_i },
          target_existing_count: object_rows.count { |r| r.dig(:target, :exists) },
          unsupported_upload_role: role["backend"].to_s == "upload",
          listing_based: true
        },
        warnings: warnings.compact.uniq,
        objects: object_rows
      }
    end
    private_class_method :preview_hls_role

    def enumerate_role_objects(item:, role_name:, role:, source_store:)
      case role_name.to_s
      when "main", "thumbnail"
        enumerate_single_object(role)
      when "hls"
        enumerate_hls_objects(item: item, role: role, source_store: source_store)
      else
        []
      end
    end
    private_class_method :enumerate_role_objects

    def enumerate_single_object(role)
      return [] if role["backend"].to_s == "upload"
      key = role["key"].to_s
      return [] if key.blank?
      [{ key: key, content_type: role["content_type"].to_s.presence }]
    end
    private_class_method :enumerate_single_object

    def enumerate_hls_objects(item:, role:, source_store:)
      source_store = local_store_for_hls(role, source_store)
      prefix = hls_prefix_for(item, role)
      list_prefix_entries(source_store, prefix).map do |entry|
        key = entry[:key].to_s
        { key: key, content_type: entry[:content_type].presence || content_type_for_hls_key(key) }
      end
    end
    private_class_method :enumerate_hls_objects

    def local_store_for_hls(role, source_store)
      if role["backend"].to_s == "local" && source_store.blank?
        ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_asset_root_path)
      else
        source_store
      end
    end
    private_class_method :local_store_for_hls

    def hls_prefix_for(item, role)
      role["key_prefix"].to_s.presence || File.join(item.public_id.to_s, "hls")
    end
    private_class_method :hls_prefix_for

    def list_prefix_entries(store, prefix)
      return [] if store.blank?

      entries = if store.respond_to?(:list_prefix_entries)
        store.list_prefix_entries(prefix)
      else
        Array(store.list_prefix(prefix)).map { |key| { key: key } }
      end

      Array(entries).map do |entry|
        entry.is_a?(Hash) ? entry.deep_symbolize_keys : { key: entry.to_s }
      end.reject { |entry| entry[:key].to_s.blank? }
    end
    private_class_method :list_prefix_entries

    def info_from_prefix_entry(store, entry, exists:)
      key = entry[:key].to_s
      {
        exists: !!exists,
        backend: store&.backend,
        key: key,
        bytes: entry[:bytes].to_i,
        content_type: entry[:content_type].to_s.presence,
        etag: entry[:etag].to_s.presence
      }.compact
    end
    private_class_method :info_from_prefix_entry

    def missing_info_for(store, key)
      { exists: false, backend: store&.backend, key: key.to_s }
    end
    private_class_method :missing_info_for

    def source_object_info(source_store:, object:)
      if source_store.blank?
        { exists: false, backend: nil, key: object[:key], error: "source_store_missing" }
      else
        source_store.object_info(object[:key]).deep_symbolize_keys
      end
    end
    private_class_method :source_object_info

    def target_object_info(target_store:, key:)
      return { exists: false, backend: nil, key: key, error: "target_store_missing" } if target_store.blank?

      target_store.object_info(key).deep_symbolize_keys
    end
    private_class_method :target_object_info

    def build_store_from_summary(summary)
      backend = summary[:backend].to_s
      profile_key = summary[:profile_key].to_s

      if profile_key.present?
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
        return store if store.present?
      end

      case backend
      when "local"
        if summary.dig(:config, :local_asset_root_path).present?
          ::MediaGallery::LocalAssetStore.new(root_path: summary.dig(:config, :local_asset_root_path))
        else
          ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_asset_root_path)
        end
      when "s3"
        nil
      else
        nil
      end
    rescue
      nil
    end
    private_class_method :build_store_from_summary

    def sanitized_config_for_profile_key(profile_key, backend)
      config = ::MediaGallery::StorageSettingsResolver.sanitized_config_for_profile_key(profile_key)
      return config.deep_symbolize_keys if config.present?

      { backend: backend }
    end
    private_class_method :sanitized_config_for_profile_key

    def content_type_for_hls_key(key)
      case File.extname(key.to_s).downcase
      when ".m3u8" then "application/vnd.apple.mpegurl"
      when ".ts" then "video/MP2T"
      when ".m4s" then "video/iso.segment"
      when ".mp4" then "video/mp4"
      when ".json" then "application/json"
      else "application/octet-stream"
      end
    end
    private_class_method :content_type_for_hls_key
  end
end
