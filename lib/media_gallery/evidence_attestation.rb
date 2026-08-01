# frozen_string_literal: true

require "digest"
require "openssl"

module ::MediaGallery
  module EvidenceAttestation
    module_function

    SCHEMA = "media-gallery-identify-evidence-attestation-v1"
    PURPOSE = "media-gallery-identify-evidence-attestation-v1"

    # Adds an HMAC-backed server attestation after the identify decision is final. The attestation
    # prevents a browser-modified result from being imported as evidence. It does not change any
    # identify score, ranking, threshold or decision field.
    def attach!(result:, public_id:, media_item_id:, source_ref: nil, actor_user_id: nil, issued_at: Time.now.utc)
      raise ArgumentError, "invalid_identify_result" unless result.is_a?(Hash)

      normalized = result.deep_stringify_keys
      normalized["meta"] ||= {}
      normalized["meta"].delete("evidence_attestation")
      result_sha256 = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(normalized))
      payload = {
        "schema" => SCHEMA,
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
      raise ArgumentError, "identify_attestation_schema_invalid" unless signed_payload["schema"] == SCHEMA
      raise ArgumentError, "identify_attestation_run_ref_missing" if signed_payload["run_ref"].to_s.blank?
      raise ArgumentError, "identify_attestation_signature_missing" unless signature.match?(/\A[0-9a-f]{64}\z/i)

      if expected_public_id.present? && signed_payload["public_id"].to_s != expected_public_id.to_s
        raise ArgumentError, "identify_attestation_public_id_mismatch"
      end
      if expected_media_item_id.to_i.positive? && signed_payload["media_item_id"].to_i != expected_media_item_id.to_i
        raise ArgumentError, "identify_attestation_media_item_mismatch"
      end

      unsigned = normalized.deep_dup
      unsigned["meta"] ||= {}
      unsigned["meta"].delete("evidence_attestation")
      actual_result_sha256 = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(unsigned))
      unless secure_compare(actual_result_sha256, signed_payload["result_sha256"].to_s)
        raise ArgumentError, "identify_attestation_result_hash_mismatch"
      end
      unless secure_compare(signature_for(signed_payload), signature.downcase)
        raise ArgumentError, "identify_attestation_signature_invalid"
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
