# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"
require "json"
require "uri"

module ::MediaGallery
  module EvidenceReference
    module_function

    SENSITIVE_QUERY_KEYS = /(?:token|sig|signature|auth|authorization|key|secret|password|cookie|session|jwt|access[_-]?token)/i

    def case_ref(time: Time.now.utc)
      "CASE-#{time.year}-#{SecureRandom.hex(6).upcase}"
    end

    def object_ref
      "OBJ-#{SecureRandom.hex(8).upcase}"
    end

    def run_ref
      "RUN-#{SecureRandom.hex(8).upcase}"
    end

    def review_ref
      "REV-#{SecureRandom.hex(8).upcase}"
    end

    def event_ref
      "EVT-#{SecureRandom.hex(8).upcase}"
    end

    def report_ref(case_ref:, version:)
      "RPT-#{case_ref.to_s.sub(/\ACASE-/, "")}-V#{version.to_i}"
    end

    def package_ref(case_ref:, version:)
      "EP-#{case_ref.to_s.sub(/\ACASE-/, "")}-V#{version.to_i}"
    end

    def hold_ref
      "HOLD-#{SecureRandom.hex(8).upcase}"
    end

    def disclosure_ref
      "DISC-#{Time.now.utc.year}-#{SecureRandom.hex(8).upcase}"
    end

    def retention_review_ref
      "RET-#{Time.now.utc.year}-#{SecureRandom.hex(8).upcase}"
    end

    def privacy_request_ref
      "PRIV-#{Time.now.utc.year}-#{SecureRandom.hex(8).upcase}"
    end

    def annex_ref(case_ref:, version:)
      "RIA-#{case_ref.to_s.sub(/\ACASE-/, "")}-V#{version.to_i}"
    end

    def reviewer_ref(case_ref:, user_id:, role: "staff_reviewer")
      prefix = role.to_s == "senior_staff_reviewer" ? "SSR" : (role.to_s == "privacy_legal_approver" ? "PLA" : "SR")
      digest = OpenSSL::HMAC.hexdigest("SHA256", reviewer_secret, "#{case_ref}:reviewer:#{user_id}")
      "#{prefix}-#{digest[0, 4].upcase}-#{digest[4, 4].upcase}-#{digest[8, 4].upcase}"
    end

    def account_ref(case_ref:, user_id:)
      digest = OpenSSL::HMAC.hexdigest("SHA256", reviewer_secret, "#{case_ref}:account:#{user_id}")
      "UA-#{digest[0, 4].upcase}-#{digest[4, 4].upcase}"
    end

    def reviewer_secret
      configured = if SiteSetting.respond_to?(:media_gallery_evidence_reviewer_secret)
        SiteSetting.media_gallery_evidence_reviewer_secret.to_s
      else
        ""
      end
      return configured if configured.present?

      Rails.application.secret_key_base.to_s
    end

    def reviewer_secret_key_id
      Digest::SHA256.hexdigest(reviewer_secret)[0, 16]
    end

    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def pretty_canonical_json(value)
      JSON.pretty_generate(canonicalize(value))
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), out|
          out[key.to_s] = canonicalize(child)
        end.sort.to_h
      when Array
        value.map { |child| canonicalize(child) }
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.utc.iso8601(6)
      when Date
        value.iso8601
      when BigDecimal
        value.to_s("F")
      when Symbol
        value.to_s
      else
        value
      end
    end

    def sha256_bytes(bytes)
      Digest::SHA256.hexdigest(bytes.to_s.b)
    end

    def ascii_text(value, max_length: nil)
      text = value.to_s
      text = text.unicode_normalize(:nfkd) if text.respond_to?(:unicode_normalize)
      text = text.encode("ASCII", invalid: :replace, undef: :replace, replace: "?")
      text = text.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, "")
      text = text[0, max_length] if max_length.present? && max_length.to_i.positive?
      text
    rescue
      value.to_s.encode("ASCII", invalid: :replace, undef: :replace, replace: "?")
    end

    def pdf_safe_identity(value, fallback_ref:)
      original = value.to_s
      converted = ascii_text(original, max_length: 200)
      if original.present? && converted == original && converted.match?(/\A[\x20-\x7E]+\z/)
        converted
      else
        "#{fallback_ref} (platform username retained in the integrity package metadata)"
      end
    end

    def safe_filename(value, fallback: "evidence.bin")
      base = File.basename(value.to_s.tr("\\", "/"))
      base = ascii_text(base, max_length: 180)
      base = base.gsub(/[^A-Za-z0-9._-]+/, "_").gsub(/\A[.]+/, "")
      base = fallback if base.blank? || %w[. ..].include?(base)
      base
    end

    def redacted_url(raw_url)
      raw = raw_url.to_s.strip
      return [nil, nil] if raw.blank?
      raise ArgumentError, "source_url_too_long" if raw.bytesize > 10_000

      uri = URI.parse(raw)
      raise ArgumentError, "source_url_scheme_not_allowed" unless %w[http https].include?(uri.scheme.to_s.downcase)
      raise ArgumentError, "source_url_userinfo_not_allowed" if uri.userinfo.present?
      raise ArgumentError, "source_url_host_missing" if uri.host.blank?

      original_hash = Digest::SHA256.hexdigest(raw)
      if uri.query.present?
        pairs = URI.decode_www_form(uri.query)
        uri.query = URI.encode_www_form(pairs.map { |key, value| [key, key.match?(SENSITIVE_QUERY_KEYS) ? "REDACTED" : value] })
      end
      uri.fragment = nil
      [uri.to_s, original_hash]
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid_source_url"
    end

    def role_for_user(user, requested_kind = nil)
      kind = requested_kind.to_s
      return "privacy_legal_approver" if kind == "privacy" && user&.admin?
      return "senior_staff_reviewer" if kind == "senior" && user&.admin?

      "staff_reviewer"
    end

    def actor_type_for_user(user)
      return "system" if user.blank?
      return "senior_staff" if user.admin?

      "staff"
    end
  end
end
