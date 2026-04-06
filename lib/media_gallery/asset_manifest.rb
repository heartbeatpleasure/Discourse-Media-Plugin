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
      role = manifest.dig("roles", role_name) if manifest.is_a?(Hash)
      role = legacy_role_for(item, role_name) if role.blank?
      role.is_a?(Hash) ? role.deep_stringify_keys : nil
    rescue
      legacy_role_for(item, role_name)
    end

    def role_present?(item, role_name)
      role_for(item, role_name).present?
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
        elsif item.public_id.present?
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
  end
end
