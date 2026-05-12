# frozen_string_literal: true

module ::MediaGallery
  module ResponseSecurityHeaders
    module_function

    REFERRER_POLICY = "no-referrer"
    CROSS_ORIGIN_RESOURCE_POLICY = "same-origin"

    def apply!(headers, include_corp: true)
      return unless enabled?
      return if headers.blank?

      headers["Referrer-Policy"] ||= REFERRER_POLICY
      headers["Cross-Origin-Resource-Policy"] ||= CROSS_ORIGIN_RESOURCE_POLICY if include_corp
    rescue => e
      Rails.logger.debug("[media_gallery] response security headers failed: #{e.class}: #{e.message}") if defined?(Rails) && Rails.logger.respond_to?(:debug)
      nil
    end

    def enabled?
      return true unless SiteSetting.respond_to?(:media_gallery_extra_media_security_headers_enabled)

      !!SiteSetting.media_gallery_extra_media_security_headers_enabled
    rescue
      true
    end
  end
end
