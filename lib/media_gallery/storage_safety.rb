# frozen_string_literal: true

require "uri"

module ::MediaGallery
  module StorageSafety
    module_function

    def profile_review(profile)
      summary = ::MediaGallery::StorageSettingsResolver.profile_summary(profile).deep_symbolize_keys
      profile_key = summary[:profile_key].to_s.presence || profile.to_s
      backend = summary[:backend].to_s
      config = (summary[:config] || {}).deep_symbolize_keys
      checks = []

      if backend.blank?
        checks << check(:critical, "backend_not_configured", "Storage backend is not configured.", "Configure a local or S3/R2 backend before using this profile.")
      elsif backend == "local"
        root_path = config[:local_asset_root_path].to_s
        checks << check(:warning, "local_root_outside_shared", "Local path is outside /shared.", "Paths outside /shared may not be included in normal Discourse container backups.") if root_path.present? && !root_path.start_with?("/shared")
        checks << check(:warning, "local_root_blank", "Local root path is blank.", "Set a private local storage root path.") if root_path.blank?
      elsif backend == "s3"
        endpoint = config[:endpoint].to_s
        bucket = config[:bucket].to_s
        prefix = config[:prefix].to_s
        ttl = config[:presign_ttl_seconds].to_i

        if endpoint.blank?
          checks << check(:critical, "s3_endpoint_missing", "S3/R2 endpoint is missing.", "Set the storage endpoint for this profile.")
        else
          uri = URI.parse(endpoint) rescue nil
          checks << check(:warning, "s3_endpoint_not_https", "S3/R2 endpoint is not HTTPS.", "Use HTTPS endpoints for private media storage.") if uri && uri.scheme.to_s != "https"
          checks << check(:warning, "s3_endpoint_unparseable", "S3/R2 endpoint could not be parsed.", "Check the endpoint URL format.") if uri.blank?
          checks << check(:warning, "r2_dev_endpoint_hint", "Cloudflare r2.dev style endpoint detected.", "Prefer the account R2 S3 endpoint or a controlled/custom domain. Avoid public bucket URLs for protected media.") if endpoint.include?("r2.dev")
        end

        checks << check(:critical, "s3_bucket_missing", "Bucket name is missing.", "Set the target bucket for this profile.") if bucket.blank?
        checks << check(:warning, "s3_prefix_blank", "Object prefix is blank.", "A dedicated prefix reduces accidental mixing with other application files.") if prefix.blank?
        checks << check(:warning, "s3_presign_ttl_high", "Presigned URL TTL is high.", "Use short TTLs for protected media. Consider 60-300 seconds unless there is a clear performance reason.", value: ttl) if ttl > 600
        checks << check(:warning, "s3_access_key_id_missing", "Access key ID is not configured.", "Set credentials for private S3/R2 access.") if config[:access_key_id_last4].blank?
        checks << check(:warning, "s3_secret_missing", "Secret access key is not configured.", "Set the secret access key. The value is intentionally never shown here.") unless ActiveModel::Type::Boolean.new.cast(config[:secret_access_key_present])
      end

      status = checks.any? { |c| c[:severity] == "critical" } ? "critical" : (checks.any? { |c| c[:severity] == "warning" } ? "warning" : "ok")
      {
        profile: profile.to_s,
        profile_key: profile_key,
        label: summary[:label],
        backend: backend,
        status: status,
        checks: checks,
        summary: status == "ok" ? "No storage safety warnings found." : "#{checks.length} storage safety warning#{'s' if checks.length != 1} found.",
      }
    rescue => e
      {
        profile: profile.to_s,
        profile_key: profile.to_s,
        status: "critical",
        checks: [check(:critical, "storage_safety_failed", "Storage safety validation failed.", "#{e.class}: #{e.message}".truncate(500))],
        summary: "Storage safety validation failed.",
      }
    end

    def configured_reviews
      ::MediaGallery::StorageSettingsResolver.configured_profiles_summary.map do |profile|
        profile_review(profile[:profile_key])
      end
    rescue
      []
    end

    def check(severity, code, message, detail, extra = {})
      { severity: severity.to_s, code: code.to_s, message: message.to_s, detail: detail.to_s }.merge(extra)
    end
    private_class_method :check
  end
end
