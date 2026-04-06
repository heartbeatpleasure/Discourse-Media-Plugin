# frozen_string_literal: true

module ::MediaGallery
  module StorageSettingsResolver
    module_function

    BACKENDS = %w[local s3].freeze
    DELIVERY_MODES = %w[stream x_accel redirect].freeze

    def managed_storage_enabled?
      backend = configured_backend
      return true if backend.present?

      SiteSetting.respond_to?(:media_gallery_private_storage_enabled) &&
        SiteSetting.media_gallery_private_storage_enabled
    rescue
      false
    end

    def active_backend
      return nil unless managed_storage_enabled?

      backend = configured_backend
      return backend if BACKENDS.include?(backend)

      "local"
    end

    def local_backend?
      active_backend == "local"
    end

    def s3_backend?
      active_backend == "s3"
    end

    def configured_backend
      return nil unless SiteSetting.respond_to?(:media_gallery_asset_storage_backend)

      value = SiteSetting.media_gallery_asset_storage_backend.to_s.strip
      BACKENDS.include?(value) ? value : nil
    rescue
      nil
    end

    def processing_root_path
      value =
        if SiteSetting.respond_to?(:media_gallery_processing_root_path)
          SiteSetting.media_gallery_processing_root_path.to_s.strip
        else
          ""
        end

      value.presence || nil
    end

    def local_asset_root_path
      value =
        if SiteSetting.respond_to?(:media_gallery_local_asset_root_path)
          SiteSetting.media_gallery_local_asset_root_path.to_s.strip
        else
          ""
        end

      value.presence || legacy_private_root_path || "/shared/media_gallery/private"
    end

    def default_delivery_mode
      value =
        if SiteSetting.respond_to?(:media_gallery_delivery_mode_default)
          SiteSetting.media_gallery_delivery_mode_default.to_s.strip
        else
          ""
        end

      return value if DELIVERY_MODES.include?(value)

      s3_backend? ? "redirect" : "stream"
    rescue
      "stream"
    end

    def active_profile_key
      case active_backend
      when "s3" then "active_s3"
      when "local" then "active_local"
      else nil
      end
    end

    def build_store(backend = active_backend)
      case backend.to_s
      when "local"
        ::MediaGallery::LocalAssetStore.new(root_path: local_asset_root_path)
      when "s3"
        ::MediaGallery::S3AssetStore.new(s3_options)
      else
        nil
      end
    end

    def s3_options
      {
        endpoint: site_setting_string(:media_gallery_s3_endpoint),
        region: site_setting_string(:media_gallery_s3_region).presence || "auto",
        bucket: site_setting_string(:media_gallery_s3_bucket),
        prefix: normalize_prefix(site_setting_string(:media_gallery_s3_prefix)),
        access_key_id: site_setting_string(:media_gallery_s3_access_key_id),
        secret_access_key: site_setting_string(:media_gallery_s3_secret_access_key),
        force_path_style: site_setting_bool(:media_gallery_s3_force_path_style, default: false),
        presign_ttl_seconds: site_setting_int(:media_gallery_s3_presign_ttl_seconds, default: 300)
      }
    end

    def s3_ready?
      opts = s3_options
      opts[:endpoint].present? &&
        opts[:bucket].present? &&
        opts[:access_key_id].present? &&
        opts[:secret_access_key].present?
    end

    def validate_active_backend!
      return true unless managed_storage_enabled?

      case active_backend
      when "local"
        root = local_asset_root_path
        raise "local_asset_root_path_missing" if root.blank?
      when "s3"
        raise "s3_backend_incomplete" unless s3_ready?
      else
        raise "unknown_asset_storage_backend"
      end

      true
    end

    def normalize_key(relative_key)
      rel = relative_key.to_s.sub(%r{\A/+}, "")
      pref = s3_options[:prefix].to_s
      return rel if pref.blank?
      return pref if rel.blank?

      "#{pref}/#{rel}"
    end

    def strip_prefix(key)
      raw = key.to_s.sub(%r{\A/+}, "")
      pref = s3_options[:prefix].to_s
      return raw if pref.blank?
      return raw unless raw.start_with?("#{pref}/")

      raw.delete_prefix("#{pref}/")
    end

    def hls_supported_on_active_backend?
      true
    end

    def site_setting_string(name)
      return "" unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_s.strip
    rescue
      ""
    end

    def site_setting_bool(name, default: false)
      return default unless SiteSetting.respond_to?(name)
      !!SiteSetting.public_send(name)
    rescue
      default
    end

    def site_setting_int(name, default: 0)
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def normalize_prefix(value)
      value.to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
    end
    private_class_method :normalize_prefix

    def legacy_private_root_path
      return nil unless SiteSetting.respond_to?(:media_gallery_private_root_path)
      value = SiteSetting.media_gallery_private_root_path.to_s.strip
      value.presence
    rescue
      nil
    end
    private_class_method :legacy_private_root_path
  end
end
