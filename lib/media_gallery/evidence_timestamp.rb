# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "time"

module ::MediaGallery
  module EvidenceTimestamp
    module_function

    MODES = %w[disabled rfc3161].freeze
    TRUST_MODES = %w[system_store custom_ca_bundle pinned_certificate custom_ca_and_pinned].freeze
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024

    def mode
      value = setting(:media_gallery_evidence_timestamp_mode, "disabled")
      MODES.include?(value) ? value : "disabled"
    end

    def enabled?
      mode == "rfc3161"
    end

    def trust_mode
      value = setting(:media_gallery_evidence_timestamp_trust_mode, "system_store")
      TRUST_MODES.include?(value) ? value : "system_store"
    end

    def configured?
      return true unless enabled?
      return false unless defined?(OpenSSL::Timestamp::Request) && defined?(OpenSSL::Timestamp::Response)

      uri = endpoint_uri
      return false unless uri&.is_a?(URI::HTTPS)
      username = setting(:media_gallery_evidence_timestamp_username)
      password_env = setting(:media_gallery_evidence_timestamp_password_env)
      return false if username.present? && (password_env.blank? || ENV[password_env].to_s.blank?)

      case trust_mode
      when "system_store"
        true
      when "custom_ca_bundle"
        File.file?(trust_bundle_path)
      when "pinned_certificate"
        valid_fingerprint?(expected_certificate_sha256)
      when "custom_ca_and_pinned"
        File.file?(trust_bundle_path) && valid_fingerprint?(expected_certificate_sha256)
      else
        false
      end
    rescue
      false
    end

    def create(data)
      return disabled_result unless enabled?
      raise ArgumentError, "timestamp_not_configured" unless configured?

      request = build_request(data)
      response_der, http_metadata = send_request(request.to_der)
      response = OpenSSL::Timestamp::Response.new(response_der)
      unless [OpenSSL::Timestamp::Response::GRANTED, OpenSSL::Timestamp::Response::GRANTED_WITH_MODS].include?(response.status.to_i)
        raise "timestamp_rejected:#{response.failure_info || Array(response.status_text).join(' ')}"
      end

      verification = verify(request_der: request.to_der, response_der: response_der)
      raise "timestamp_verification_failed:#{Array(verification[:errors]).join(',')}" unless verification[:verified]

      {
        status: "verified",
        request_der: request.to_der,
        response_der: response_der,
        request_sha256: Digest::SHA256.hexdigest(request.to_der),
        response_sha256: Digest::SHA256.hexdigest(response_der),
        verification: verification,
        http: http_metadata,
      }
    end

    def verify(request_der:, response_der:, expected_policy_oid: nil)
      errors = []
      warnings = []
      request = OpenSSL::Timestamp::Request.new(request_der)
      response = OpenSSL::Timestamp::Response.new(response_der)
      status_ok = [OpenSSL::Timestamp::Response::GRANTED, OpenSSL::Timestamp::Response::GRANTED_WITH_MODS].include?(response.status.to_i)
      errors << "timestamp_response_not_granted" unless status_ok

      token_info = response.token_info
      errors << "timestamp_token_missing" if token_info.blank?
      required_policy_oid = expected_policy_oid.nil? ? self.expected_policy_oid : expected_policy_oid.to_s.strip
      policy_ok = required_policy_oid.blank? || token_info&.policy_id.to_s == required_policy_oid
      errors << "timestamp_policy_mismatch" unless policy_ok

      tsa_certificate = response.tsa_certificate
      errors << "timestamp_tsa_certificate_missing" if tsa_certificate.blank?
      pin_verified = tsa_certificate.present? && certificate_pin_verified?(tsa_certificate)
      errors << "timestamp_certificate_pin_mismatch" if pin_required? && !pin_verified

      token_certificates = Array(response.token&.certificates).compact
      intermediates = token_certificates.reject do |certificate|
        tsa_certificate.present? && certificate.to_der == tsa_certificate.to_der
      end
      verification_time = token_info&.gen_time&.utc

      response_integrity_verified = false
      if status_ok && token_info.present? && tsa_certificate.present? && policy_ok
        begin
          embedded_store = OpenSSL::X509::Store.new
          ([tsa_certificate] + token_certificates).uniq { |certificate| certificate.to_der }.each do |certificate|
            embedded_store.add_cert(certificate)
          end
          embedded_store.time = verification_time if verification_time && embedded_store.respond_to?(:time=)
          response.verify(request, embedded_store, intermediates)
          response_integrity_verified = true
        rescue => e
          errors << "timestamp_chain_or_imprint_invalid:#{safe_error(e)}"
        end
      end

      certificate_trust_verified = false
      if response_integrity_verified && (!pin_required? || pin_verified)
        certificate_trust_verified = case trust_mode
        when "pinned_certificate"
          pin_verified
        else
          begin
            store, configured_intermediates = trust_store_and_intermediates(tsa_certificate)
            store.time = verification_time if verification_time && store.respond_to?(:time=)
            response.verify(request, store, (intermediates + configured_intermediates).uniq { |certificate| certificate.to_der })
            true
          rescue => e
            warnings << "timestamp_certificate_trust_not_established:#{safe_error(e)}"
            false
          end
        end
      end

      verified = response_integrity_verified && certificate_trust_verified && (!pin_required? || pin_verified)
      {
        verified: verified,
        response_integrity_verified: response_integrity_verified,
        certificate_trust_verified: certificate_trust_verified,
        status: response.status.to_i,
        status_text: Array(response.status_text),
        failure_info: response.failure_info,
        trust_mode: trust_mode,
        certificate_pin_verified: pin_verified,
        certificate_chain_verified: certificate_trust_verified,
        tsa_certificate: tsa_certificate.present? ? ::MediaGallery::EvidenceSeal.certificate_metadata(tsa_certificate) : nil,
        token: token_info.present? ? {
          "policy_id" => token_info.policy_id,
          "algorithm" => token_info.algorithm,
          "message_imprint_hex" => token_info.message_imprint.to_s.unpack1("H*"),
          "serial_hex" => token_info.serial_number.to_i.to_s(16).upcase,
          "gen_time_utc" => token_info.gen_time&.utc&.iso8601(6),
          "nonce" => token_info.nonce&.to_i,
          "ordering" => token_info.ordering,
        }.compact : nil,
        errors: errors.uniq,
        warnings: warnings.uniq,
      }
    rescue => e
      {
        verified: false,
        response_integrity_verified: false,
        certificate_trust_verified: false,
        trust_mode: trust_mode,
        certificate_pin_verified: false,
        certificate_chain_verified: false,
        errors: ["timestamp_verification_error:#{safe_error(e)}"],
        warnings: [],
      }
    end

    def health
      result = {
        "mode" => mode,
        "configured" => configured?,
        "trust_mode" => trust_mode,
        "endpoint_host" => endpoint_uri&.host,
        "expected_policy_oid" => expected_policy_oid.presence,
      }.compact
      return result.merge("status" => "disabled") unless enabled?
      return result.merge("status" => "not_configured") unless configured?

      result.merge("status" => "available")
    rescue => e
      result.merge("status" => "unavailable", "error" => safe_error(e))
    end

    def expected_policy_oid
      setting(:media_gallery_evidence_timestamp_policy_oid)
    end

    def expected_certificate_sha256
      ::MediaGallery::EvidenceSeal.normalize_fingerprint(setting(:media_gallery_evidence_timestamp_expected_certificate_sha256))
    end

    def build_request(data)
      request = OpenSSL::Timestamp::Request.new
      request.version = 1
      request.algorithm = "SHA256"
      request.message_imprint = Digest::SHA256.digest(data)
      request.nonce = SecureRandom.random_number(2**63 - 1) + 1
      request.cert_requested = true
      request.policy_id = expected_policy_oid if expected_policy_oid.present?
      request
    end

    def send_request(request_der)
      uri = endpoint_uri
      raise ArgumentError, "timestamp_https_required" unless uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = timeout_seconds
      http.read_timeout = timeout_seconds
      http.write_timeout = timeout_seconds if http.respond_to?(:write_timeout=)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = tls_store

      request = Net::HTTP::Post.new(uri.request_uri.presence || "/")
      request["Content-Type"] = "application/timestamp-query"
      request["Accept"] = "application/timestamp-reply"
      request["User-Agent"] = "Discourse-Media-Library-Evidence-Timestamp/1.0"
      username = setting(:media_gallery_evidence_timestamp_username)
      password = password_from_env
      request.basic_auth(username, password) if username.present? && password.present?
      request.body = request_der

      body = +"".b
      response = nil
      http.request(request) do |current_response|
        response = current_response
        current_response.read_body do |chunk|
          body << chunk
          raise "timestamp_response_too_large" if body.bytesize > MAX_RESPONSE_BYTES
        end
      end
      raise "timestamp_http_error:#{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise "timestamp_empty_response" if body.blank?

      [
        body,
        {
          "endpoint_host" => uri.host,
          "http_status" => response.code.to_i,
          "content_type" => response["Content-Type"].to_s.truncate(200),
          "received_at_utc" => Time.now.utc.iso8601(6),
        },
      ]
    end

    def endpoint_uri
      value = setting(:media_gallery_evidence_timestamp_url)
      return nil if value.blank?

      uri = URI.parse(value)
      return nil unless uri.host.present? && uri.userinfo.blank? && uri.fragment.blank?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def timeout_seconds
      value = integer_setting(:media_gallery_evidence_timestamp_timeout_seconds, 15)
      value.clamp(3, 120)
    end

    def tls_store
      store = OpenSSL::X509::Store.new
      path = setting(:media_gallery_evidence_timestamp_tls_ca_bundle_path)
      if path.present?
        raise ArgumentError, "timestamp_tls_ca_bundle_missing" unless File.file?(path)
        ::MediaGallery::EvidenceSeal.parse_certificates(File.binread(path)).each { |cert| store.add_cert(cert) }
      else
        store.set_default_paths
      end
      store
    end

    def trust_store_and_intermediates(tsa_certificate)
      store = OpenSSL::X509::Store.new
      intermediates = []
      case trust_mode
      when "system_store"
        store.set_default_paths
      when "custom_ca_bundle", "custom_ca_and_pinned"
        raise ArgumentError, "timestamp_trust_bundle_missing" unless File.file?(trust_bundle_path)
        certificates = ::MediaGallery::EvidenceSeal.parse_certificates(File.binread(trust_bundle_path))
        certificates.each { |cert| store.add_cert(cert) }
        intermediates = certificates
      when "pinned_certificate"
        store.add_cert(tsa_certificate)
      end
      [store, intermediates]
    end

    def trust_bundle_path
      setting(:media_gallery_evidence_timestamp_trust_bundle_path)
    end

    def pin_required?
      %w[pinned_certificate custom_ca_and_pinned].include?(trust_mode) || expected_certificate_sha256.present?
    end

    def certificate_pin_verified?(certificate)
      expected = expected_certificate_sha256
      return true if expected.blank?

      actual = ::MediaGallery::EvidenceSeal.certificate_fingerprint(certificate)
      secure_compare(actual, expected)
    end

    def valid_fingerprint?(value)
      value.to_s.match?(/\A[0-9a-f]{64}\z/)
    end

    def password_from_env
      env_name = setting(:media_gallery_evidence_timestamp_password_env)
      env_name.present? ? ENV[env_name].to_s : ""
    end

    def disabled_result
      {
        status: "not_configured",
        request_der: nil,
        response_der: nil,
        request_sha256: nil,
        response_sha256: nil,
        verification: {
          verified: false,
          trust_mode: "none",
          errors: [],
        },
        http: {},
      }
    end

    def setting(name, default = "")
      return default unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_s.strip
    rescue
      default
    end

    def integer_setting(name, default)
      return default unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def secure_compare(left, right)
      left = left.to_s
      right = right.to_s
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    rescue
      false
    end

    def safe_error(error)
      "#{error.class}: #{error.message}".to_s.gsub(/[\r\n]+/, " ").truncate(300)
    end
  end
end
