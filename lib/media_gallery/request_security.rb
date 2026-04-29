# frozen_string_literal: true

require "uri"

module ::MediaGallery
  module RequestSecurity
    module_function

    def secure_write_request?(controller)
      return true if verified_request?(controller)
      same_origin_request?(controller.request)
    rescue
      false
    end

    def secure_token_issue_request?(controller)
      same_origin_request?(controller.request)
    rescue
      false
    end

    def same_origin_request?(request)
      return false if request.blank?

      expected = trusted_base_urls
      return false if expected.blank?

      origin = request.headers["Origin"].to_s.strip
      referer = request.referer.to_s.strip
      fetch_site = request.headers["Sec-Fetch-Site"].to_s.strip.downcase

      return true if origin.present? && same_origin_url_any?(origin, expected)
      return true if referer.present? && same_origin_url_any?(referer, expected)

      # Some browser requests do not include Origin/Referer. In that case, only
      # trust Fetch Metadata when the request itself is addressed to the canonical
      # Discourse origin. This avoids using request.base_url as the security
      # anchor while preserving normal same-origin browser behavior.
      if origin.blank? && referer.blank? && %w[same-origin none].include?(fetch_site)
        return canonical_request_origin?(request, expected)
      end

      false
    rescue
      false
    end

    def trusted_base_urls
      urls = []
      urls << Discourse.base_url.to_s.strip if defined?(Discourse) && Discourse.respond_to?(:base_url)
      urls.compact.map(&:presence).compact.uniq
    rescue
      []
    end
    private_class_method :trusted_base_urls

    def same_origin_url_any?(candidate, expected_urls)
      expected_urls.any? { |expected| same_origin_url?(candidate, expected) }
    rescue
      false
    end
    private_class_method :same_origin_url_any?

    def canonical_request_origin?(request, expected_urls)
      request_origin = request_origin_url(request)
      return false if request_origin.blank?

      same_origin_url_any?(request_origin, expected_urls)
    rescue
      false
    end
    private_class_method :canonical_request_origin?

    def request_origin_url(request)
      scheme = request.protocol.to_s.delete_suffix("://").presence || request.scheme.to_s.presence
      host = request.host.to_s.presence
      port = request.optional_port if request.respond_to?(:optional_port)

      return nil if scheme.blank? || host.blank?

      origin = "#{scheme}://#{host}"
      origin = "#{origin}:#{port}" if port.present?
      origin
    rescue
      nil
    end
    private_class_method :request_origin_url

    def same_origin_url?(candidate, expected)
      candidate_uri = URI.parse(candidate)
      expected_uri = URI.parse(expected)

      normalize_port(candidate_uri) == normalize_port(expected_uri) &&
        candidate_uri.scheme.to_s == expected_uri.scheme.to_s &&
        candidate_uri.host.to_s.downcase == expected_uri.host.to_s.downcase
    rescue URI::InvalidURIError
      false
    end
    private_class_method :same_origin_url?

    def normalize_port(uri)
      return uri.port if uri.port.present?
      return 443 if uri.scheme.to_s == "https"
      80
    end
    private_class_method :normalize_port

    def verified_request?(controller)
      controller.send(:verified_request?)
    rescue
      false
    end
    private_class_method :verified_request?
  end
end
