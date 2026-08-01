# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "openssl"

module ::MediaGallery
  module EvidenceAttestation
    module_function

    LEGACY_SCHEMA = "media-gallery-identify-evidence-attestation-v1"
    SCHEMA = "media-gallery-identify-evidence-attestation-v2"
    PURPOSE = "media-gallery-identify-evidence-attestation-v1"
    HASH_CANONICALIZATION = "typed-json-number-normalization-v1"
    SUPPORTED_SCHEMAS = [LEGACY_SCHEMA, SCHEMA].freeze

    # Adds an HMAC-backed server attestation after the identify decision is final. The attestation
    # prevents a browser-modified result from being imported as evidence. It does not change any
    # identify score, ranking, threshold or decision field.
    #
    # Version 2 hashes a typed, transport-stable representation. JavaScript has one Number type,
    # so values such as Ruby 1.0, -0.0 and 1e20 can be serialized back as 1, 0 and an integer. The
    # typed representation preserves scalar types while normalizing numerically equal JSON values,
    # allowing a genuine result to survive the browser JSON round trip without weakening tamper
    # detection.
    def attach!(result:, public_id:, media_item_id:, source_ref: nil, actor_user_id: nil, issued_at: Time.now.utc)
      raise ArgumentError, "invalid_identify_result" unless result.is_a?(Hash)

      normalized = result.deep_stringify_keys
      normalized["meta"] ||= {}
      normalized["meta"].delete("evidence_attestation")
      result_sha256 = result_sha256_for(normalized, schema: SCHEMA)
      payload = {
        "schema" => SCHEMA,
        "hash_canonicalization" => HASH_CANONICALIZATION,
        "run_ref" => ::MediaGallery::EvidenceReference.run_ref,
        "public_id" => public_id.to_s,
        "media_item_id" => media_item_id.to_i,
        "source_ref" => source_ref.to_s.presence,
        "issued_at_utc" => issued_at.utc.iso8601(6),
        "actor_user_id" => actor_user_id.to_i.positive? ? actor_user_id.to_i : nil,
        "result_sha256" => result_sha256,
      }.compact
      payload["signature"] = signature_for(payload)
      normalized["meta"]["evidence_attestation"] = payload
      result.replace(normalized)
    end

    def verify!(result, expected_public_id: nil, expected_media_item_id: nil)
      raise ArgumentError, "invalid_identify_result" unless result.is_a?(Hash)

      normalized = result.deep_stringify_keys
      attestation = normalized.dig("meta", "evidence_attestation")
      raise ArgumentError, "identify_result_not_server_attested" unless attestation.is_a?(Hash)

      signed_payload = attestation.deep_stringify_keys
      signature = signed_payload.delete("signature").to_s
      schema = signed_payload["schema"].to_s
      raise ArgumentError, "identify_attestation_schema_invalid" unless SUPPORTED_SCHEMAS.include?(schema)
      if schema == SCHEMA && signed_payload["hash_canonicalization"].to_s != HASH_CANONICALIZATION
        raise ArgumentError, "identify_attestation_hash_canonicalization_invalid"
      end
      raise ArgumentError, "identify_attestation_run_ref_missing" if signed_payload["run_ref"].to_s.blank?
      raise ArgumentError, "identify_attestation_signature_missing" unless signature.match?(/\A[0-9a-f]{64}\z/i)

      if expected_public_id.present? && signed_payload["public_id"].to_s != expected_public_id.to_s
        raise ArgumentError, "identify_attestation_public_id_mismatch"
      end
      if expected_media_item_id.to_i.positive? && signed_payload["media_item_id"].to_i != expected_media_item_id.to_i
        raise ArgumentError, "identify_attestation_media_item_mismatch"
      end

      unless secure_compare(signature_for(signed_payload), signature.downcase)
        raise ArgumentError, "identify_attestation_signature_invalid"
      end

      unsigned = normalized.deep_dup
      unsigned["meta"] ||= {}
      unsigned["meta"].delete("evidence_attestation")
      actual_result_sha256 = result_sha256_for(unsigned, schema: schema)
      unless secure_compare(actual_result_sha256, signed_payload["result_sha256"].to_s)
        error = schema == LEGACY_SCHEMA ? "identify_attestation_legacy_result_requires_rerun" : "identify_attestation_result_hash_mismatch"
        raise ArgumentError, error
      end

      signed_payload.merge(
        "signature_verified" => true,
        "verified_result_sha256" => actual_result_sha256,
      )
    end

    def external_summary(attestation)
      source = attestation.is_a?(Hash) ? attestation.deep_stringify_keys : {}
      {
        "schema" => source["schema"],
        "hash_canonicalization" => source["hash_canonicalization"],
        "run_ref" => source["run_ref"],
        "public_id" => source["public_id"],
        "media_item_id" => source["media_item_id"],
        "source_ref" => source["source_ref"],
        "issued_at_utc" => source["issued_at_utc"],
        "result_sha256" => source["result_sha256"] || source["verified_result_sha256"],
        "verified_at_snapshot_creation" => source["signature_verified"] == true,
        "signature_exported" => false,
        "assurance" => "server HMAC verified internally when the immutable identify snapshot was created",
      }.compact
    end

    def result_sha256_for(value, schema: SCHEMA)
      bytes = if schema.to_s == LEGACY_SCHEMA
        ::MediaGallery::EvidenceReference.canonical_json(value)
      else
        ::MediaGallery::EvidenceReference.canonical_json(transport_digest_value(value))
      end
      Digest::SHA256.hexdigest(bytes)
    end

    def transport_digest_value(value)
      case value
      when Hash
        {
          "type" => "object",
          "value" => value.map { |key, child| [key.to_s, transport_digest_value(child)] }.sort_by(&:first),
        }
      when Array
        { "type" => "array", "value" => value.map { |child| transport_digest_value(child) } }
      when String
        { "type" => "string", "value" => value }
      when Integer, Float
        { "type" => "number", "value" => canonical_number(value) }
      when BigDecimal
        # ActiveSupport serializes BigDecimal values as JSON strings. Match the value that the
        # browser receives rather than preserving a Ruby-only numeric type.
        { "type" => "string", "value" => value.to_s("F") }
      when TrueClass, FalseClass
        { "type" => "boolean", "value" => value }
      when NilClass
        { "type" => "null" }
      when Time, DateTime, ActiveSupport::TimeWithZone
        { "type" => "string", "value" => value.utc.iso8601(6) }
      when Date
        { "type" => "string", "value" => value.iso8601 }
      when Symbol
        { "type" => "string", "value" => value.to_s }
      else
        converted = value.respond_to?(:as_json) ? value.as_json : value.to_s
        return transport_digest_value(converted) unless converted.equal?(value)

        { "type" => "string", "value" => value.to_s }
      end
    end
    private_class_method :transport_digest_value

    def canonical_number(value)
      if value.is_a?(Float)
        raise ArgumentError, "identify_attestation_non_finite_number" unless value.finite?
        return "0" if value.zero?
      end

      text = if value.is_a?(Integer)
        value.to_s
      elsif value.is_a?(BigDecimal)
        value.to_s("F")
      else
        BigDecimal(value.to_s).to_s("F")
      end
      if text.include?(".")
        text = text.sub(/0+\z/, "").sub(/\.\z/, "")
      end
      %w[-0 +0].include?(text) ? "0" : text
    rescue ArgumentError, TypeError
      raise ArgumentError, "identify_attestation_invalid_number"
    end
    private_class_method :canonical_number

    def signature_for(payload)
      OpenSSL::HMAC.hexdigest("SHA256", signing_key, ::MediaGallery::EvidenceReference.canonical_json(payload)).downcase
    end
    private_class_method :signature_for

    def signing_key
      secret = Rails.application.secret_key_base.to_s
      raise "evidence_attestation_secret_unavailable" if secret.blank?

      OpenSSL::HMAC.digest("SHA256", secret, PURPOSE)
    end
    private_class_method :signing_key

    def secure_compare(left, right)
      return false if left.blank? || right.blank? || left.bytesize != right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    rescue
      left == right
    end
    private_class_method :secure_compare
  end
end
