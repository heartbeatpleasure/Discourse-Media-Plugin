# frozen_string_literal: true

require "digest"
require "openssl"
require "time"

module ::MediaGallery
  module EvidenceSeal
    module_function

    TRUST_MODES = %w[embedded_only system_store custom_ca_bundle pinned_certificate custom_ca_and_pinned].freeze
    MAX_BUNDLE_BYTES = 4 * 1024 * 1024

    def mode
      ::MediaGallery::EvidencePolicy.seal_mode
    end

    def configured?
      return true if mode == "integrity_only"
      return false unless mode == "cms_detached"

      key_path = setting(:media_gallery_evidence_seal_private_key_path)
      cert_path = setting(:media_gallery_evidence_seal_certificate_path)
      key_path.present? && cert_path.present? && File.file?(key_path) && File.file?(cert_path)
    rescue
      false
    end

    def trust_mode
      value = setting(:media_gallery_evidence_seal_trust_mode, "embedded_only")
      TRUST_MODES.include?(value) ? value : "embedded_only"
    end

    def trust_configured?
      case trust_mode
      when "embedded_only", "system_store"
        true
      when "custom_ca_bundle"
        File.file?(setting(:media_gallery_evidence_seal_ca_bundle_path))
      when "pinned_certificate"
        valid_fingerprint?(expected_certificate_sha256)
      when "custom_ca_and_pinned"
        File.file?(setting(:media_gallery_evidence_seal_ca_bundle_path)) && valid_fingerprint?(expected_certificate_sha256)
      else
        false
      end
    rescue
      false
    end

    def current_key_revoked?
      key_id = seal_key_id
      key_id.present? && revoked_key_ids.include?(key_id)
    end

    def seal_key_id
      setting(:media_gallery_evidence_seal_key_id).presence
    end

    def revoked_key_ids
      setting(:media_gallery_evidence_seal_revoked_key_ids)
        .split(/[\s,;]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    end

    def expected_certificate_sha256
      normalize_fingerprint(setting(:media_gallery_evidence_seal_expected_certificate_sha256))
    end

    def create(manifest_bytes)
      return integrity_only_result unless mode == "cms_detached"
      raise ArgumentError, "cms_seal_not_configured" unless configured?
      raise ArgumentError, "cms_seal_key_revoked" if current_key_revoked?

      key = OpenSSL::PKey.read(File.binread(setting(:media_gallery_evidence_seal_private_key_path)), key_password)
      certificate = OpenSSL::X509::Certificate.new(File.binread(setting(:media_gallery_evidence_seal_certificate_path)))
      ensure_key_matches_certificate!(key, certificate)
      ensure_certificate_current!(certificate)
      ensure_certificate_pin!(certificate)

      chain = certificate_chain
      flags = OpenSSL::PKCS7::BINARY | OpenSSL::PKCS7::DETACHED
      signature = OpenSSL::PKCS7.sign(certificate, key, manifest_bytes, chain, flags).to_der
      verification = verify(
        signature_der: signature,
        certificate_pem: certificate.to_pem,
        chain_pem: chain.map(&:to_pem).join,
        content: manifest_bytes,
        key_id: seal_key_id,
        manifest_certificate_sha256: certificate_fingerprint(certificate),
      )
      raise "cms_signature_self_verification_failed" unless verification[:signature_integrity_verified]
      if trust_mode != "embedded_only" && !verification[:certificate_trust_verified]
        raise "cms_certificate_trust_verification_failed:#{Array(verification[:errors]).join(',')}"
      end

      {
        method: "cms_detached",
        signature: signature,
        certificate_pem: certificate.to_pem,
        chain_pem: chain.map(&:to_pem).join.presence,
        key_id: seal_key_id,
        certificate: certificate_metadata(certificate),
        verification: verification,
      }
    end

    def verify(signature_der:, certificate_pem:, chain_pem:, content:, key_id: nil, manifest_certificate_sha256: nil)
      errors = []
      certificate = OpenSSL::X509::Certificate.new(certificate_pem)
      chain = parse_certificates(chain_pem)
      pkcs7 = OpenSSL::PKCS7.new(signature_der)
      manifest_fingerprint = normalize_fingerprint(manifest_certificate_sha256)
      manifest_certificate_match = manifest_fingerprint.blank? || secure_compare(certificate_fingerprint(certificate), manifest_fingerprint)
      errors << "cms_manifest_certificate_mismatch" unless manifest_certificate_match

      integrity_verified = begin
        flags = OpenSSL::PKCS7::NOVERIFY | OpenSSL::PKCS7::BINARY
        pkcs7.verify([certificate] + chain, OpenSSL::X509::Store.new, content, flags)
      rescue => e
        errors << "cms_signature_invalid:#{safe_error(e)}"
        false
      end

      current = certificate_current?(certificate)
      errors << "cms_certificate_not_current" unless current
      pin_verified = certificate_pin_verified?(certificate)
      errors << "cms_certificate_pin_mismatch" if pin_required? && !pin_verified
      key_revoked = certificate_key_revoked?(key_id)
      errors << "cms_seal_key_revoked" if key_revoked

      trust_verified = false
      if integrity_verified && manifest_certificate_match && current && !key_revoked
        trust_verified = case trust_mode
        when "embedded_only"
          false
        when "pinned_certificate"
          pin_verified
        else
          verify_chain(pkcs7, certificate, chain, content, errors) && (!pin_required? || pin_verified)
        end
      end

      {
        signature_integrity_verified: integrity_verified,
        certificate_trust_verified: trust_verified,
        certificate_time_valid: current,
        certificate_pin_verified: pin_verified,
        certificate_revoked_by_configuration: key_revoked,
        manifest_certificate_match: manifest_certificate_match,
        key_id: key_id.presence || seal_key_id,
        trust_mode: trust_mode,
        certificate: certificate_metadata(certificate),
        errors: errors.uniq,
      }
    rescue => e
      {
        signature_integrity_verified: false,
        certificate_trust_verified: false,
        certificate_time_valid: false,
        certificate_pin_verified: false,
        certificate_revoked_by_configuration: false,
        manifest_certificate_match: false,
        key_id: key_id.presence || seal_key_id,
        trust_mode: trust_mode,
        errors: ["cms_verification_error:#{safe_error(e)}"],
      }
    end

    def current_certificate_metadata
      return nil unless mode == "cms_detached"
      path = setting(:media_gallery_evidence_seal_certificate_path)
      return nil unless path.present? && File.file?(path)

      certificate_metadata(OpenSSL::X509::Certificate.new(File.binread(path)))
    rescue
      nil
    end

    def health
      result = {
        "mode" => mode,
        "configured" => configured?,
        "trust_mode" => trust_mode,
        "trust_configured" => trust_configured?,
        "key_id" => seal_key_id,
        "key_revoked" => current_key_revoked?,
      }
      return result.merge("status" => "disabled") if mode == "integrity_only"
      return result.merge("status" => "not_configured") unless configured?

      certificate = OpenSSL::X509::Certificate.new(File.binread(setting(:media_gallery_evidence_seal_certificate_path)))
      result.merge(
        "status" => current_key_revoked? ? "revoked" : (certificate_current?(certificate) ? "available" : "certificate_not_current"),
        "certificate" => certificate_metadata(certificate),
      )
    rescue => e
      result.merge("status" => "unavailable", "error" => safe_error(e))
    end

    def certificate_metadata(certificate)
      {
        "sha256" => certificate_fingerprint(certificate),
        "serial_hex" => certificate.serial.to_i.to_s(16).upcase,
        "subject" => certificate.subject.to_s,
        "issuer" => certificate.issuer.to_s,
        "not_before_utc" => certificate.not_before.utc.iso8601(6),
        "not_after_utc" => certificate.not_after.utc.iso8601(6),
        "signature_algorithm" => certificate.signature_algorithm,
      }
    end

    def parse_certificates(bytes)
      return [] if bytes.blank?
      raise ArgumentError, "certificate_bundle_too_large" if bytes.to_s.bytesize > MAX_BUNDLE_BYTES

      pem_blocks = bytes.to_s.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
      return pem_blocks.map { |pem| OpenSSL::X509::Certificate.new(pem) } if pem_blocks.any?

      [OpenSSL::X509::Certificate.new(bytes)]
    rescue OpenSSL::X509::CertificateError
      []
    end

    def parse_crls(bytes)
      return [] if bytes.blank?
      raise ArgumentError, "crl_bundle_too_large" if bytes.to_s.bytesize > MAX_BUNDLE_BYTES

      pem_blocks = bytes.to_s.scan(/-----BEGIN X509 CRL-----.*?-----END X509 CRL-----/m)
      return pem_blocks.map { |pem| OpenSSL::X509::CRL.new(pem) } if pem_blocks.any?

      [OpenSSL::X509::CRL.new(bytes)]
    rescue OpenSSL::X509::CRLError
      []
    end

    def certificate_fingerprint(certificate)
      Digest::SHA256.hexdigest(certificate.to_der)
    end

    def normalize_fingerprint(value)
      value.to_s.downcase.gsub(/[^0-9a-f]/, "")
    end

    def valid_fingerprint?(value)
      value.to_s.match?(/\A[0-9a-f]{64}\z/)
    end

    def pin_required?
      %w[pinned_certificate custom_ca_and_pinned].include?(trust_mode) || expected_certificate_sha256.present?
    end

    def certificate_pin_verified?(certificate)
      expected = expected_certificate_sha256
      return false if expected.blank? && %w[pinned_certificate custom_ca_and_pinned].include?(trust_mode)
      return true if expected.blank?

      secure_compare(certificate_fingerprint(certificate), expected)
    end

    def certificate_key_revoked?(key_id = nil)
      value = key_id.to_s.presence || seal_key_id
      value.present? && revoked_key_ids.include?(value)
    end

    def certificate_current?(certificate, at: Time.now.utc)
      certificate.not_before <= at && certificate.not_after >= at
    end

    def ensure_certificate_current!(certificate)
      raise ArgumentError, "cms_certificate_not_current" unless certificate_current?(certificate)
    end

    def ensure_certificate_pin!(certificate)
      raise ArgumentError, "cms_certificate_pin_mismatch" if pin_required? && !certificate_pin_verified?(certificate)
    end

    def ensure_key_matches_certificate!(key, certificate)
      key_public = key.public_key.to_der
      cert_public = certificate.public_key.to_der
      raise ArgumentError, "cms_key_certificate_mismatch" unless secure_compare(Digest::SHA256.hexdigest(key_public), Digest::SHA256.hexdigest(cert_public))
    end

    def verify_chain(pkcs7, certificate, chain, content, errors)
      store = trust_store(certificate)
      flags = OpenSSL::PKCS7::BINARY
      ok = pkcs7.verify([certificate] + chain, store, content, flags)
      errors << "cms_certificate_chain_untrusted" unless ok
      ok
    rescue => e
      errors << "cms_certificate_chain_error:#{safe_error(e)}"
      false
    end

    def trust_store(certificate = nil)
      store = OpenSSL::X509::Store.new
      case trust_mode
      when "system_store"
        store.set_default_paths
      when "custom_ca_bundle", "custom_ca_and_pinned"
        add_certificates_to_store(store, setting(:media_gallery_evidence_seal_ca_bundle_path))
      when "pinned_certificate"
        store.add_cert(certificate) if certificate
      end

      crl_path = setting(:media_gallery_evidence_seal_crl_path)
      if crl_path.present? && File.file?(crl_path)
        parse_crls(File.binread(crl_path)).each { |crl| store.add_crl(crl) }
        if defined?(OpenSSL::X509::V_FLAG_CRL_CHECK)
          flags = OpenSSL::X509::V_FLAG_CRL_CHECK
          flags |= OpenSSL::X509::V_FLAG_CRL_CHECK_ALL if defined?(OpenSSL::X509::V_FLAG_CRL_CHECK_ALL)
          store.flags = flags
        end
      end
      store
    end

    def add_certificates_to_store(store, path)
      raise ArgumentError, "cms_ca_bundle_missing" unless path.present? && File.file?(path)

      parse_certificates(File.binread(path)).each { |cert| store.add_cert(cert) }
      store
    end

    def certificate_chain
      path = setting(:media_gallery_evidence_seal_certificate_chain_path)
      return [] if path.blank?
      raise ArgumentError, "cms_certificate_chain_missing" unless File.file?(path)

      parse_certificates(File.binread(path))
    end

    def key_password
      env_name = setting(:media_gallery_evidence_seal_key_password_env)
      return nil if env_name.blank?

      ENV[env_name].to_s
    end

    def integrity_only_result
      {
        method: "integrity_only",
        signature: nil,
        certificate_pem: nil,
        chain_pem: nil,
        key_id: nil,
        certificate: nil,
        verification: {
          signature_integrity_verified: false,
          certificate_trust_verified: false,
          certificate_time_valid: false,
          certificate_pin_verified: false,
          certificate_revoked_by_configuration: false,
          trust_mode: "none",
          errors: [],
        },
      }
    end

    def setting(name, default = "")
      return default unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_s.strip
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
