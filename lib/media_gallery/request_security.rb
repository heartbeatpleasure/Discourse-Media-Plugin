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

      origin = request.headers["Origin"].to_s.strip
      referer = request.referer.to_s.strip
      fetch_site = request.headers["Sec-Fetch-Site"].to_s.strip.downcase
      expected = request.base_url.to_s.strip

      return true if origin.present? && same_origin_url?(origin, expected)
      return true if referer.present? && same_origin_url?(referer, expected)
      return true if origin.blank? && referer.blank? && %w[same-origin none].include?(fetch_site)

      false
    rescue
      false
    end

    def same_origin_url?(candidate, expected)
      candidate_uri = URI.parse(candidate)
      expected_uri = URI.parse(expected)

      normalize_port(candidate_uri) == normalize_port(expected_uri) &&
        candidate_uri.scheme.to_s == expected_uri.scheme.to_s &&
        candidate_uri.host.to_s == expected_uri.host.to_s
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
