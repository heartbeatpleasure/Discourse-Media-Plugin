# frozen_string_literal: true

module ::MediaGallery
  module AssetManifest
    SCHEMA_VERSION = 1
    module_function

    def build(item:, main_role:, thumbnail_role: nil, hls_role: nil)
      roles = {}
      roles["main"] = normalize_role(main_role) if main_role.present?
      roles["thumbnail"] = normalize_role(thumbnail_role) if thumbnail_role.present?
      roles["hls"] = normalize_role(hls_role) if hls_role.present?

      {
        "schema_version" => SCHEMA_VERSION,
        "public_id" => item.public_id.to_s,
        "generated_at" => Time.now.utc.iso8601,
        "roles" => roles
      }
    end

    def role_for(item, role_name)
      role_name = role_name.to_s
      manifest = item.try(:storage_manifest)
      stored_role = manifest.dig("roles", role_name) if manifest.is_a?(Hash)
      stored_role = normalize_role(stored_role) if stored_role.present?

      managed_role = nil
      if stored_role.blank? || should_probe_current_managed_role?(item, stored_role)
        managed_role = current_managed_role_for(item, role_name)
      end

      return managed_role if managed_role.present? && prefer_managed_role?(item, stored_role, managed_role)
      return stored_role if stored_role.present?
      return managed_role if managed_role.present?

      legacy_role_for(item, role_name)
    rescue
      legacy_role_for(item, role_name)
    end

    def role_present?(item, role_name)
      role_for(item, role_name).present?
    end

    def current_managed_role_for(item, role_name)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key)
      return nil if profile_key.blank? || backend.blank?

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      return nil if store.blank?

      case role_name.to_s
      when "main"
        key = ::MediaGallery::PrivateStorage.processed_rel_path(item)
        return nil unless store.exists?(key)

        {
          "backend" => backend,
          "key" => key,
          "content_type" => inferred_main_content_type(item)
        }
      when "thumbnail"
        key = ::MediaGallery::PrivateStorage.thumbnail_rel_path(item)
        return nil unless store.exists?(key)

        {
          "backend" => backend,
          "key" => key,
          "content_type" => "image/jpeg"
        }
      when "hls"
        prefix = File.join(item.public_id.to_s, "hls")
        keys = Array(store.list_prefix(prefix, limit: 8)).compact.map(&:to_s)
        return nil if keys.blank?

        role = {
          "backend" => backend,
          "key_prefix" => prefix,
          "master_key" => File.join(prefix, "master.m3u8"),
          "complete_key" => File.join(prefix, ".complete"),
          "variant_playlist_key_template" => File.join(prefix, "%{variant}", "index.m3u8"),
          "segment_key_template" => File.join(prefix, "%{variant}", "%{segment}"),
          "variants" => hls_variants_for_keys(prefix, keys),
          "ready" => true,
        }

        if keys.include?(File.join(prefix, "fingerprint_meta.json"))
          role["fingerprint_meta_key"] = File.join(prefix, "fingerprint_meta.json")
        end

        if keys.any? { |key| key.start_with?(File.join(prefix, "a") + "/") } && keys.any? { |key| key.start_with?(File.join(prefix, "b") + "/") }
          role["ab_fingerprint"] = true
          role["ab_layout"] = "hls/{a|b}/%{variant}/%{segment}"
          role["ab_segment_key_template"] = File.join(prefix, "%{ab}", "%{variant}", "%{segment}")
        end

        role
      else
        nil
      end
    rescue
      nil
    end

    def legacy_role_for(item, role_name)
      case role_name.to_s
      when "main"
        if item.processed_upload_id.present?
          {
            "backend" => "upload",
            "upload_id" => item.processed_upload_id,
            "content_type" => inferred_main_content_type(item)
          }
        elsif item.extra_metadata.is_a?(Hash) && item.extra_metadata["processed_rel_path"].present?
          {
            "backend" => "local",
            "key" => item.extra_metadata["processed_rel_path"].to_s,
            "content_type" => inferred_main_content_type(item),
            "legacy" => true
          }
        elsif item.public_id.present?
          {
            "backend" => "local",
            "key" => ::MediaGallery::PrivateStorage.processed_rel_path(item),
            "content_type" => inferred_main_content_type(item),
            "legacy" => true
          }
        end
      when "thumbnail"
        if item.thumbnail_upload_id.present?
          {
            "backend" => "upload",
            "upload_id" => item.thumbnail_upload_id,
            "content_type" => "image/jpeg"
          }
        elsif item.extra_metadata.is_a?(Hash) && item.extra_metadata["thumbnail_rel_path"].present?
          {
            "backend" => "local",
            "key" => item.extra_metadata["thumbnail_rel_path"].to_s,
            "content_type" => "image/jpeg",
            "legacy" => true
          }
        elsif implicit_legacy_thumbnail_available?(item)
          {
            "backend" => "local",
            "key" => ::MediaGallery::PrivateStorage.thumbnail_rel_path(item),
            "content_type" => "image/jpeg",
            "legacy" => true
          }
        end
      else
        nil
      end
    end

    def implicit_legacy_thumbnail_available?(item)
      return false if item.blank? || item.public_id.blank?
      return false if item.media_type.to_s == "audio"

      thumbnail_path = ::MediaGallery::PrivateStorage.thumbnail_abs_path(item)
      File.exist?(thumbnail_path)
    rescue
      false
    end
    private_class_method :implicit_legacy_thumbnail_available?

    def inferred_main_content_type(item)
      case item.media_type.to_s
      when "video" then "video/mp4"
      when "audio" then "audio/mpeg"
      when "image" then "image/jpeg"
      else "application/octet-stream"
      end
    end

    def normalize_role(role)
      return nil unless role.is_a?(Hash)
      role.deep_stringify_keys
    end
    private_class_method :normalize_role

    def should_probe_current_managed_role?(item, stored_role)
      return true if stored_role.blank?
      return false if item.try(:managed_storage_profile).blank? && item.try(:managed_storage_backend).blank?
      return true if stored_role["legacy"]

      backend = stored_role["backend"].to_s
      return true if backend.blank? || backend == "unknown"

      expected_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(
        ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      ).to_s
      expected_backend.present? && backend != expected_backend
    end
    private_class_method :should_probe_current_managed_role?

    def prefer_managed_role?(item, stored_role, managed_role)
      return true if stored_role.blank?
      return false unless managed_role.is_a?(Hash)
      return true if stored_role["legacy"]

      stored_backend = stored_role["backend"].to_s
      managed_backend = managed_role["backend"].to_s
      return true if stored_backend.blank? || stored_backend == "unknown"
      return true if stored_backend != managed_backend

      if item.try(:managed_storage_profile).present?
        managed_key = managed_role["key"].to_s.presence || managed_role["key_prefix"].to_s.presence
        stored_key = stored_role["key"].to_s.presence || stored_role["key_prefix"].to_s.presence
        return true if managed_key.present? && stored_key.present? && managed_key != stored_key
      end

      false
    end
    private_class_method :prefer_managed_role?

    def hls_variants_for_keys(prefix, keys)
      variants = keys.filter_map do |key|
        key.match(%r{\A#{Regexp.escape(prefix)}/([^/]+)/index\.m3u8\z})&.captures&.first
      end
      ab_variants = keys.filter_map do |key|
        key.match(%r{\A#{Regexp.escape(prefix)}/[ab]/([^/]+)/})&.captures&.first
      end
      result = (variants + ab_variants).uniq.sort
      result.presence || ["v0"]
    end
    private_class_method :hls_variants_for_keys
  end
end

