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
      profile_key("active")
    end

    def target_backend
      value = site_setting_string(:media_gallery_target_asset_storage_backend)
      BACKENDS.include?(value) ? value : nil
    end

    def target_profile_key
      profile_key("target")
    end

    def profile_key(profile)
      backend = profile_backend(profile)
      case [profile.to_s, backend]
      when ["active", "s3"] then "active_s3"
      when ["active", "local"] then "active_local"
      when ["target", "s3"] then "target_s3"
      when ["target", "local"] then "target_local"
      else nil
      end
    end

    def profile_backend(profile)
      case profile.to_s
      when "target" then target_backend
      else active_backend
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

    def build_store_for_profile_key(profile_key)
      case profile_key.to_s
      when "active_local"
        ::MediaGallery::LocalAssetStore.new(root_path: local_asset_root_path)
      when "active_s3"
        ::MediaGallery::S3AssetStore.new(s3_options)
      when "target_local"
        ::MediaGallery::LocalAssetStore.new(root_path: target_local_asset_root_path)
      when "target_s3"
        ::MediaGallery::S3AssetStore.new(target_s3_options)
      else
        nil
      end
    end

    def profile_key_location_fingerprint(profile_key)
      case profile_key.to_s
      when "active_local"
        { backend: "local", root_path: File.expand_path(local_asset_root_path.to_s) }
      when "active_s3"
        s3_location_fingerprint(s3_options)
      when "target_local"
        { backend: "local", root_path: File.expand_path(target_local_asset_root_path.to_s) }
      when "target_s3"
        s3_location_fingerprint(target_s3_options)
      else
        nil
      end
    end

    def sanitized_config_for_profile_key(profile_key)
      case profile_key.to_s
      when "active_local"
        { local_asset_root_path: local_asset_root_path }
      when "active_s3"
        sanitized_s3_config_for_options(s3_options)
      when "target_local"
        { local_asset_root_path: target_local_asset_root_path }
      when "target_s3"
        sanitized_s3_config_for_options(target_s3_options)
      else
        {}
      end
    end

    def s3_options_for_profile_key(profile_key)
      case profile_key.to_s
      when "target_s3"
        target_s3_options
      else
        s3_options
      end
    end

    def presign_ttl_for_profile_key(profile_key)
      ttl = s3_options_for_profile_key(profile_key)[:presign_ttl_seconds].to_i
      ttl.positive? ? ttl : 300
    end

    def build_store_for_profile(profile)
      case profile.to_s
      when "target"
        backend = target_backend
        case backend
        when "local"
          ::MediaGallery::LocalAssetStore.new(root_path: target_local_asset_root_path)
        when "s3"
          ::MediaGallery::S3AssetStore.new(target_s3_options)
        else
          nil
        end
      else
        build_store(active_backend)
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

    def target_local_asset_root_path
      value = site_setting_string(:media_gallery_target_local_asset_root_path)
      value.presence || local_asset_root_path
    end

    def target_s3_options
      {
        endpoint: site_setting_string(:media_gallery_target_s3_endpoint),
        region: site_setting_string(:media_gallery_target_s3_region).presence || "auto",
        bucket: site_setting_string(:media_gallery_target_s3_bucket),
        prefix: normalize_prefix(site_setting_string(:media_gallery_target_s3_prefix)),
        access_key_id: site_setting_string(:media_gallery_target_s3_access_key_id),
        secret_access_key: site_setting_string(:media_gallery_target_s3_secret_access_key),
        force_path_style: site_setting_bool(:media_gallery_target_s3_force_path_style, default: false),
        presign_ttl_seconds: site_setting_int(:media_gallery_target_s3_presign_ttl_seconds, default: 300)
      }
    end

    def s3_ready?
      s3_options_ready?(s3_options)
    end

    def target_s3_ready?
      s3_options_ready?(target_s3_options)
    end

    def profile_summary(profile)
      backend = profile_backend(profile)
      {
        profile: profile.to_s,
        backend: backend,
        profile_key: profile_key(profile),
        config: sanitized_config_for(profile),
      }
    end

    def validate_profile(profile)
      backend = profile_backend(profile)
      errors = []

      if backend.blank?
        errors << "backend_not_configured"
        return errors
      end

      case backend
      when "local"
        root = profile.to_s == "target" ? target_local_asset_root_path : local_asset_root_path
        errors << "local_asset_root_path_missing" if root.blank?
      when "s3"
        opts = profile.to_s == "target" ? target_s3_options : s3_options
        errors.concat(validate_s3_options(opts))
      else
        errors << "unknown_asset_storage_backend"
      end

      errors
    end

    def validate_active_backend!
      return true unless managed_storage_enabled?

      errors = validate_profile("active")
      raise(errors.first || "unknown_asset_storage_backend") if errors.present?

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

    def sanitized_config_for(profile)
      case profile.to_s
      when "target"
        sanitized_config_for_profile_key(target_profile_key)
      else
        sanitized_config_for_profile_key(active_profile_key)
      end
    end
    private_class_method :sanitized_config_for

    def sanitized_s3_config_for_options(opts)
      {
        endpoint: opts[:endpoint],
        region: opts[:region],
        bucket: opts[:bucket],
        prefix: opts[:prefix],
        force_path_style: !!opts[:force_path_style],
        presign_ttl_seconds: opts[:presign_ttl_seconds].to_i,
        access_key_id_last4: redact_tail(opts[:access_key_id]),
        secret_access_key_present: opts[:secret_access_key].present?,
      }
    end
    private_class_method :sanitized_s3_config_for_options

    def s3_location_fingerprint(opts)
      {
        backend: "s3",
        endpoint: opts[:endpoint].to_s.sub(%r{/+\z}, ""),
        region: opts[:region].to_s,
        bucket: opts[:bucket].to_s,
        prefix: opts[:prefix].to_s,
        force_path_style: !!opts[:force_path_style],
      }
    end
    private_class_method :s3_location_fingerprint

    def redact_tail(value)
      raw = value.to_s
      return nil if raw.blank?
      return raw if raw.length <= 4

      raw[-4, 4]
    end
    private_class_method :redact_tail

    def s3_options_ready?(opts)
      validate_s3_options(opts).empty?
    end
    private_class_method :s3_options_ready?

    def validate_s3_options(opts)
      errors = []
      errors << "s3_endpoint_missing" if opts[:endpoint].to_s.blank?
      errors << "s3_bucket_missing" if opts[:bucket].to_s.blank?
      errors << "s3_access_key_id_missing" if opts[:access_key_id].to_s.blank?
      errors << "s3_secret_access_key_missing" if opts[:secret_access_key].to_s.blank?
      errors
    end
    private_class_method :validate_s3_options

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
