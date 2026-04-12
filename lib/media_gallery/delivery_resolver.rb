# frozen_string_literal: true

module ::MediaGallery
  class DeliveryResolver
    Result = Struct.new(:mode, :backend, :local_path, :redirect_url, :bytes, :content_type, :filename, :data, :key, :store, keyword_init: true)

    def initialize(item, role_name)
      @item = item
      @role_name = role_name.to_s
    end

    def resolve(expires_in: nil)
      role = ::MediaGallery::AssetManifest.role_for(@item, @role_name)
      return nil if role.blank?

      backend = role["backend"].to_s
      case backend
      when "upload"
        resolve_upload_role(role)
      when "local"
        resolve_local_role(role)
      when "s3"
        resolve_s3_role(role, expires_in: expires_in)
      else
        nil
      end
    end

    private

    def resolve_upload_role(role)
      upload =
        case @role_name
        when "thumbnail" then @item.thumbnail_upload
        else @item.processed_upload
        end
      return nil if upload.blank?

      path = ::MediaGallery::UploadPath.local_path_for(upload)
      return nil if path.blank? || !File.exist?(path)

      content_type = role["content_type"].presence || upload.try(:mime_type).presence || upload.try(:content_type).presence || "application/octet-stream"
      Result.new(
        mode: :local,
        backend: "upload",
        local_path: path,
        bytes: File.size(path),
        content_type: content_type,
        filename: default_filename(upload.extension.to_s)
      )
    end

    def resolve_local_role(role)
      store = managed_store_for_role(role, expected_backend: "local")
      return nil if store.blank?

      path = store.absolute_path_for(role["key"].to_s)
      return nil unless path.present? && File.exist?(path)

      Result.new(
        mode: :local,
        backend: "local",
        local_path: path,
        bytes: File.size(path),
        content_type: role["content_type"].presence || default_content_type,
        filename: default_filename(File.extname(path).delete_prefix(".")),
        key: role["key"].to_s
      )
    end

    def resolve_s3_role(role, expires_in: nil)
      store = managed_store_for_role(role, expected_backend: "s3")
      return nil if store.blank?

      key = role["key"].to_s
      return nil if key.blank?
      return nil unless store.exists?(key)

      content_type = role["content_type"].presence || default_content_type
      filename = default_filename(file_extension_from_role(role))
      bytes = role["bytes"].to_i

      if s3_redirect_delivery_enabled?
        ttl = expires_in.to_i
        ttl = ::MediaGallery::StorageSettingsResolver.presign_ttl_for_profile_key(managed_profile_key) if ttl <= 0
        ttl = 300 if ttl <= 0

        return Result.new(
          mode: :redirect,
          backend: "s3",
          redirect_url: store.presigned_get_url(
            key,
            expires_in: ttl,
            response_content_type: content_type,
            response_content_disposition: "inline"
          ),
          bytes: bytes,
          content_type: content_type,
          filename: filename,
          key: key,
          store: store
        )
      end

      Result.new(
        mode: :proxy,
        backend: "s3",
        bytes: bytes,
        content_type: content_type,
        filename: filename,
        key: key,
        store: store
      )
    rescue => e
      Rails.logger.warn("[media_gallery] delivery resolve s3 failed item_id=#{@item&.id} role=#{@role_name} error=#{e.class}: #{e.message}")
      nil
    end

    def managed_profile_key
      @item.try(:managed_storage_profile).to_s.presence
    end

    def s3_redirect_delivery_enabled?
      ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect"
    rescue
      true
    end

    def managed_store_for_role(role, expected_backend: nil)
      backend = expected_backend.to_s.presence || role["backend"].to_s
      store = if managed_profile_key.present?
        ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(managed_profile_key)
      end
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(backend)
      return nil if store.blank?
      return nil if backend.present? && store.backend.to_s != backend.to_s

      store
    rescue => e
      Rails.logger.warn("[media_gallery] delivery managed store resolve failed item_id=#{@item&.id} role=#{@role_name} backend=#{backend} profile_key=#{managed_profile_key} error=#{e.class}: #{e.message}")
      nil
    end

    def file_extension_from_role(role)
      key = role["key"].to_s
      ext = File.extname(key).delete_prefix(".")
      return ext if ext.present?

      case @role_name
      when "thumbnail" then "jpg"
      when "main"
        case @item.media_type.to_s
        when "video" then "mp4"
        when "audio" then "mp3"
        when "image" then "jpg"
        else "bin"
        end
      else
        "bin"
      end
    end

    def default_content_type
      case @role_name
      when "thumbnail" then "image/jpeg"
      else
        ::MediaGallery::AssetManifest.inferred_main_content_type(@item)
      end
    end

    def default_filename(ext)
      base = @role_name == "thumbnail" ? "media-#{@item.public_id}-thumb" : "media-#{@item.public_id}"
      ext.present? ? "#{base}.#{ext}" : base
    end
  end
end
