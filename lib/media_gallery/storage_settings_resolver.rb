# frozen_string_literal: true

module ::MediaGallery
  module StorageSettingsResolver
    module_function

    BACKENDS = %w[local s3].freeze
    DELIVERY_MODES = %w[stream x_accel redirect].freeze
    TARGET_PROFILE_KEYS = %w[target_local target_s3 target_s3_2 target_s3_3].freeze
    PROFILE_KEYS = (%w[active_local active_s3] + TARGET_PROFILE_KEYS).freeze

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
      active_profile_key_from_backend
    end

    def target_backend
      value = site_setting_string(:media_gallery_target_asset_storage_backend)
      BACKENDS.include?(value) ? value : nil
    end

    def target_profile_key
      case target_backend
      when "local"
        "target_local"
      when "s3"
        "target_s3"
      else
        first_available_target_profile_key || "target_local"
      end
    end

    def profile_key(profile)
      value = profile.to_s.strip
      return active_profile_key_from_backend if value.blank? || value == "active"
      return target_profile_key if value == "target"
      return value if PROFILE_KEYS.include?(value)

      nil
    end

    def normalized_profile_key(profile)
      value = profile.to_s.strip
      return active_profile_key_from_backend if value.blank? || value == "active"
      return target_profile_key if value == "target"
      return value if PROFILE_KEYS.include?(value)

      nil
    end

    def profile_backend(profile)
      key = normalized_profile_key(profile)
      backend_for_profile_key(key)
    end

    def backend_for_profile_key(profile_key)
      case profile_key.to_s
      when "active_local", "target_local"
        "local"
      when "active_s3", "target_s3", "target_s3_2", "target_s3_3"
        "s3"
      else
        nil
      end
    end


    def active_profile_key_from_backend
      case active_backend
      when "s3"
        "active_s3"
      when "local"
        "active_local"
      else
        nil
      end
    end
    private_class_method :active_profile_key_from_backend

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
      key = normalized_profile_key(profile_key)
      backend = backend_for_profile_key(key)
      return nil if backend.blank?

      case backend
      when "local"
        ::MediaGallery::LocalAssetStore.new(root_path: local_root_for_profile_key(key))
      when "s3"
        ::MediaGallery::S3AssetStore.new(s3_options_for_profile_key(key))
      else
        nil
      end
    end

    def profile_key_location_fingerprint(profile_key)
      key = normalized_profile_key(profile_key)
      case backend_for_profile_key(key)
      when "local"
        root_path = local_root_for_profile_key(key)
        return nil if root_path.blank?

        { backend: "local", root_path: File.expand_path(root_path.to_s) }
      when "s3"
        opts = s3_options_for_profile_key(key)
        return nil if opts.blank?

        s3_location_fingerprint(opts)
      else
        nil
      end
    end

    def profile_location_fingerprint_key(profile_key)
      value = profile_key_location_fingerprint(profile_key)
      value.present? ? value.to_json : nil
    end

    def sanitized_config_for_profile_key(profile_key)
      key = normalized_profile_key(profile_key)
      case backend_for_profile_key(key)
      when "local"
        { local_asset_root_path: local_root_for_profile_key(key) }
      when "s3"
        sanitized_s3_config_for_options(s3_options_for_profile_key(key))
      else
        {}
      end
    end

    def s3_options_for_profile_key(profile_key)
      case normalized_profile_key(profile_key).to_s
      when "active_s3"
        s3_options
      when "target_s3"
        target_s3_options
      when "target_s3_2"
        target_s3_2_options
      when "target_s3_3"
        target_s3_3_options
      else
        {}
      end
    end

    def presign_ttl_for_profile_key(profile_key)
      ttl = s3_options_for_profile_key(profile_key)[:presign_ttl_seconds].to_i
      ttl.positive? ? ttl : 300
    end

    def build_store_for_profile(profile)
      build_store_for_profile_key(normalized_profile_key(profile))
    end

    def profile_summary(profile)
      key = normalized_profile_key(profile)
      backend = backend_for_profile_key(key)
      {
        profile: profile.to_s.presence || "active",
        backend: backend,
        profile_key: key,
        label: profile_label_for_key(key),
        config: sanitized_config_for_profile_key(key),
        location_fingerprint: profile_key_location_fingerprint(key),
        location_fingerprint_key: profile_location_fingerprint_key(key),
      }
    end

    def validate_profile(profile)
      key = normalized_profile_key(profile)
      backend = backend_for_profile_key(key)
      errors = []

      if backend.blank?
        errors << "backend_not_configured"
        return errors
      end

      case backend
      when "local"
        root = local_root_for_profile_key(key)
        errors << "local_asset_root_path_missing" if root.blank?
      when "s3"
        errors.concat(validate_s3_options(s3_options_for_profile_key(key)))
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

    def available_target_profiles(exclude_profile_key: nil, exclude_location_fingerprint_key: nil)
      TARGET_PROFILE_KEYS.filter_map do |profile_key|
        next unless target_profile_visible?(profile_key)

        summary = profile_summary(profile_key)
        next if exclude_profile_key.present? && summary[:profile_key].to_s == exclude_profile_key.to_s
        next if exclude_location_fingerprint_key.present? && summary[:location_fingerprint_key].to_s == exclude_location_fingerprint_key.to_s

        summary
      end
    end

    def target_profiles_summary
      available_target_profiles
    end

    def profile_label_for_key(profile_key)
      case normalized_profile_key(profile_key).to_s
      when "active_local"
        "Active local storage"
      when "active_s3"
        "Active S3 storage"
      when "target_local"
        site_setting_string(:media_gallery_target_local_profile_name).presence || "Local storage"
      when "target_s3"
        site_setting_string(:media_gallery_target_s3_profile_name).presence || "S3 profile 1"
      when "target_s3_2"
        site_setting_string(:media_gallery_target_s3_2_profile_name).presence || "S3 profile 2"
      when "target_s3_3"
        site_setting_string(:media_gallery_target_s3_3_profile_name).presence || "S3 profile 3"
      else
        profile_key.to_s
      end
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

    def active_local_profile_name
      "Active local storage"
    end
    private_class_method :active_local_profile_name

    def active_s3_profile_name
      "Active S3 storage"
    end
    private_class_method :active_s3_profile_name

    def first_available_target_profile_key
      available_target_profiles.first&.dig(:profile_key)
    end
    private_class_method :first_available_target_profile_key

    def target_profile_visible?(profile_key)
      case normalized_profile_key(profile_key).to_s
      when "target_local"
        local_root_for_profile_key("target_local").present?
      when "target_s3", "target_s3_2", "target_s3_3"
        s3_options_ready?(s3_options_for_profile_key(profile_key))
      else
        false
      end
    end
    private_class_method :target_profile_visible?

    def local_root_for_profile_key(profile_key)
      case normalized_profile_key(profile_key).to_s
      when "target_local"
        target_local_asset_root_path
      else
        local_asset_root_path
      end
    end
    private_class_method :local_root_for_profile_key

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

    def target_s3_2_options
      {
        endpoint: site_setting_string(:media_gallery_target_s3_2_endpoint),
        region: site_setting_string(:media_gallery_target_s3_2_region).presence || "auto",
        bucket: site_setting_string(:media_gallery_target_s3_2_bucket),
        prefix: normalize_prefix(site_setting_string(:media_gallery_target_s3_2_prefix)),
        access_key_id: site_setting_string(:media_gallery_target_s3_2_access_key_id),
        secret_access_key: site_setting_string(:media_gallery_target_s3_2_secret_access_key),
        force_path_style: site_setting_bool(:media_gallery_target_s3_2_force_path_style, default: false),
        presign_ttl_seconds: site_setting_int(:media_gallery_target_s3_2_presign_ttl_seconds, default: 300)
      }
    end
    private_class_method :target_s3_2_options

    def target_s3_3_options
      {
        endpoint: site_setting_string(:media_gallery_target_s3_3_endpoint),
        region: site_setting_string(:media_gallery_target_s3_3_region).presence || "auto",
        bucket: site_setting_string(:media_gallery_target_s3_3_bucket),
        prefix: normalize_prefix(site_setting_string(:media_gallery_target_s3_3_prefix)),
        access_key_id: site_setting_string(:media_gallery_target_s3_3_access_key_id),
        secret_access_key: site_setting_string(:media_gallery_target_s3_3_secret_access_key),
        force_path_style: site_setting_bool(:media_gallery_target_s3_3_force_path_style, default: false),
        presign_ttl_seconds: site_setting_int(:media_gallery_target_s3_3_presign_ttl_seconds, default: 300)
      }
    end
    private_class_method :target_s3_3_options

    def sanitized_config_for(profile)
      sanitized_config_for_profile_key(normalized_profile_key(profile))
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
