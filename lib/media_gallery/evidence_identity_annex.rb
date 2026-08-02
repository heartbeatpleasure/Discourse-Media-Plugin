# frozen_string_literal: true

require "base64"
require "digest"
require "ipaddr"
require "json"
require "openssl"
require "securerandom"

module ::MediaGallery
  module EvidenceIdentityAnnex
    module_function

    STORAGE_SCHEMA = "media-gallery-restricted-identity-annex-v1"
    EXPORT_SCHEMA = "media-gallery-restricted-identity-annex-envelope-v1"
    CATEGORIES = %w[
      account_username internal_account_id email_address selected_ip_event
      selected_access_event device_hint custom_identity_reference
    ].freeze

    def enabled?
      SiteSetting.respond_to?(:media_gallery_evidence_restricted_annex_enabled) && SiteSetting.media_gallery_evidence_restricted_annex_enabled
    rescue
      false
    end

    def configured?
      enabled? && key_id.present? && master_secret(key_id).bytesize >= 32
    end

    def allowed_categories
      allowed = %w[account_username internal_account_id]
      allowed << "email_address" if setting_enabled?(:media_gallery_evidence_restricted_annex_allow_email)
      allowed << "selected_ip_event" if setting_enabled?(:media_gallery_evidence_restricted_annex_allow_selected_ip)
      allowed << "selected_access_event" if setting_enabled?(:media_gallery_evidence_restricted_annex_allow_selected_access_event)
      allowed << "device_hint" if setting_enabled?(:media_gallery_evidence_restricted_annex_allow_device_hint)
      allowed << "custom_identity_reference" if setting_enabled?(:media_gallery_evidence_restricted_annex_allow_custom_reference)
      allowed
    end

    def create!(evidence_case:, user:, selections:, necessity_reason:)
      ensure_access!(user)
      raise ArgumentError, "restricted_annex_disabled" unless enabled?
      raise ArgumentError, "restricted_annex_encryption_not_configured" unless configured?

      reason = sanitize(necessity_reason, 4000)
      raise ArgumentError, "restricted_annex_necessity_missing" if reason.blank?
      necessity_reason_sha256 = Digest::SHA256.hexdigest(reason)
      selected = normalize_selections(selections)
      annex = nil

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "privacy_processing_restricted" if evidence_case.processing_restricted?
        raise ArgumentError, "retention_disposal_requested" if ::MediaGallery::EvidenceRetention.disposal_requested?(evidence_case)

        payload = build_payload(evidence_case, selected, reason)
        raise ArgumentError, "restricted_annex_empty" if payload["identity_data"].blank?

        now = Time.now.utc
        version = evidence_case.identity_annexes.maximum(:version).to_i + 1
        annex_ref = ::MediaGallery::EvidenceReference.annex_ref(case_ref: evidence_case.case_ref, version: version)
        payload.merge!(
          "schema" => STORAGE_SCHEMA,
          "annex_ref" => annex_ref,
          "case_ref" => evidence_case.case_ref,
          "version" => version,
          "created_at_utc" => now.iso8601(6),
        )
        encrypted = encrypt_storage(payload, evidence_case.case_ref, annex_ref, version)
        creator_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "privacy_legal_approver",
        )

        annex = ::MediaGallery::ForensicEvidenceIdentityAnnex.create!(
          evidence_case: evidence_case,
          annex_ref: annex_ref,
          version: version,
          status: "pending_approval",
          ciphertext: encrypted.fetch(:ciphertext),
          iv: encrypted.fetch(:iv),
          auth_tag: encrypted.fetch(:auth_tag),
          key_id: key_id,
          payload_sha256: Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload)),
          categories: payload.fetch("identity_data").keys.sort,
          necessity_reason_sha256: necessity_reason_sha256,
          created_by: user,
          created_by_ref: creator_ref,
          metadata: {
            "storage_schema" => STORAGE_SCHEMA,
            "encryption" => "AES-256-GCM",
            "plaintext_stored" => false,
          },
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "restricted_annex_created",
          user: user,
          actor_type: "privacy_approver",
          actor_ref: creator_ref,
          object_ref: annex.annex_ref,
          details: {
            annex_version: version,
            annex_status: annex.status,
            annex_categories: annex.categories,
            annex_payload_sha256: annex.payload_sha256,
            annex_key_id: annex.key_id,
            necessity_reason_sha256: necessity_reason_sha256,
          },
        )
      end
      annex
    end

    def approve!(annex:, user:, approval_kind:, reason: nil)
      kind = approval_kind.to_s
      if kind == "senior"
        ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
        ensure_access!(user)
      elsif kind == "privacy"
        ensure_access!(user)
      else
        raise ArgumentError, "invalid_restricted_annex_approval"
      end
      raise ArgumentError, "restricted_annex_withdrawn" if annex.status == "withdrawn"

      now = Time.now.utc
      role = kind == "senior" ? "senior_staff_reviewer" : "privacy_legal_approver"
      actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
        case_ref: annex.evidence_case.case_ref,
        user_id: user.id,
        role: role,
      )
      ::MediaGallery::ForensicEvidenceCase.transaction do
        annex.evidence_case.lock!
        annex.lock!
        annex.reload
        raise ArgumentError, "restricted_annex_withdrawn" if annex.status == "withdrawn"
        if kind == "senior"
          raise ArgumentError, "restricted_annex_approval_already_recorded" if annex.senior_approved_at.present?
          annex.update!(senior_approved_by: user, senior_approved_by_ref: actor_ref, senior_approved_at: now)
        else
          raise ArgumentError, "restricted_annex_approval_already_recorded" if annex.privacy_approved_at.present?
          annex.update!(privacy_approved_by: user, privacy_approved_by_ref: actor_ref, privacy_approved_at: now)
        end
        if annex.senior_approved_by_id.present? && annex.privacy_approved_by_id.present?
          if annex.senior_approved_by_id == annex.privacy_approved_by_id
            raise ArgumentError, "restricted_annex_two_person_approval_required"
          end
          annex.update!(status: "approved")
        end
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: annex.evidence_case,
          event_type: "restricted_annex_approval_recorded",
          user: user,
          actor_type: kind == "senior" ? "senior_staff" : "privacy_approver",
          actor_ref: actor_ref,
          object_ref: annex.annex_ref,
          reason: sanitize(reason, 1000),
          details: {
            annex_version: annex.version,
            approval_kind: kind,
            annex_status: annex.status,
          },
        )
      end
      annex
    end

    def view!(annex:, user:)
      ensure_access!(user)
      payload = decrypt_storage(annex)
      now = Time.now.utc
      ::MediaGallery::ForensicEvidenceCase.transaction do
        annex.evidence_case.lock!
        annex.lock!
        annex.reload
        annex.update!(last_viewed_at: now)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: annex.evidence_case,
          event_type: "restricted_annex_viewed",
          user: user,
          actor_type: "privacy_approver",
          actor_ref: ::MediaGallery::EvidenceReference.reviewer_ref(
            case_ref: annex.evidence_case.case_ref,
            user_id: user.id,
            role: "privacy_legal_approver",
          ),
          object_ref: annex.annex_ref,
          details: { annex_version: annex.version, annex_payload_sha256: annex.payload_sha256 },
        )
      end
      payload
    end

    def export!(annex:, user:, passphrase:, recipient_ref:, purpose:)
      ensure_access!(user)
      raise ArgumentError, "restricted_annex_not_approved" unless annex.fully_approved? && %w[approved exported].include?(annex.status)
      raise ArgumentError, "privacy_processing_restricted" if annex.evidence_case.processing_restricted?
      raise ArgumentError, "retention_disposal_requested" if ::MediaGallery::EvidenceRetention.disposal_requested?(annex.evidence_case)
      secret = passphrase.to_s
      raise ArgumentError, "restricted_annex_export_passphrase_too_short" if secret.length < 16
      recipient = sanitize(recipient_ref, 200)
      release_purpose = sanitize(purpose, 2000)
      raise ArgumentError, "restricted_annex_recipient_missing" if recipient.blank?
      raise ArgumentError, "restricted_annex_export_purpose_missing" if release_purpose.blank?

      payload = decrypt_storage(annex)
      export_payload = {
        "schema" => "media-gallery-restricted-identity-annex-export-v1",
        "annex" => payload,
        "release" => {
          "recipient_ref" => recipient,
          "purpose" => release_purpose,
          "exported_at_utc" => Time.now.utc.iso8601(6),
        },
      }
      envelope = encrypt_export(export_payload, secret, annex)
      now = Time.now.utc
      ::MediaGallery::ForensicEvidenceCase.transaction do
        annex.evidence_case.lock!
        annex.lock!
        annex.reload
        raise ArgumentError, "restricted_annex_not_approved" unless annex.fully_approved? && %w[approved exported].include?(annex.status)
        raise ArgumentError, "privacy_processing_restricted" if annex.evidence_case.reload.processing_restricted?
        raise ArgumentError, "retention_disposal_requested" if ::MediaGallery::EvidenceRetention.disposal_requested?(annex.evidence_case)

        annex.update!(status: "exported", last_exported_at: now)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: annex.evidence_case,
          event_type: "restricted_annex_exported",
          user: user,
          actor_type: "privacy_approver",
          actor_ref: ::MediaGallery::EvidenceReference.reviewer_ref(
            case_ref: annex.evidence_case.case_ref,
            user_id: user.id,
            role: "privacy_legal_approver",
          ),
          object_ref: annex.annex_ref,
          details: {
            annex_version: annex.version,
            recipient_ref_sha256: Digest::SHA256.hexdigest(recipient),
            purpose_sha256: Digest::SHA256.hexdigest(release_purpose),
            envelope_schema: EXPORT_SCHEMA,
          },
        )
      end
      JSON.pretty_generate(envelope) + "\n"
    end

    def decrypt_storage(annex)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = storage_key(annex.key_id)
      cipher.iv = Base64.strict_decode64(annex.iv)
      cipher.auth_tag = Base64.strict_decode64(annex.auth_tag)
      cipher.auth_data = storage_aad(annex.evidence_case.case_ref, annex.annex_ref, annex.version, annex.key_id)
      plaintext = cipher.update(Base64.strict_decode64(annex.ciphertext)) + cipher.final
      parsed = JSON.parse(plaintext)
      digest = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(parsed))
      raise "restricted_annex_payload_hash_mismatch" unless digest == annex.payload_sha256

      parsed
    rescue OpenSSL::Cipher::CipherError, ArgumentError, JSON::ParserError
      raise ArgumentError, "restricted_annex_decryption_failed"
    end

    def build_payload(evidence_case, selected, reason)
      snapshot = evidence_case.latest_identify_snapshot
      user = snapshot&.attributed_user_id.present? ? ::User.find_by(id: snapshot.attributed_user_id) : nil
      data = {}
      if selected?(selected["account_username"]) && allowed_categories.include?("account_username")
        data["account_username"] = snapshot&.attributed_username.to_s.presence
      end
      if selected?(selected["internal_account_id"]) && allowed_categories.include?("internal_account_id")
        data["internal_account_id"] = snapshot&.attributed_user_id
      end
      if selected?(selected["email_address"]) && allowed_categories.include?("email_address")
        data["email_address"] = user&.email.to_s.presence
      end
      if selected["selected_ip_event"].is_a?(Hash) && allowed_categories.include?("selected_ip_event")
        data["selected_ip_event"] = normalized_ip_event(selected["selected_ip_event"])
      end
      if selected["selected_access_event"].is_a?(Hash) && allowed_categories.include?("selected_access_event")
        data["selected_access_event"] = normalized_event(selected["selected_access_event"], max_value: 1000)
      end
      if selected["device_hint"].is_a?(Hash) && allowed_categories.include?("device_hint")
        data["device_hint"] = normalized_event(selected["device_hint"], max_value: 1000)
      end
      if selected["custom_identity_reference"].is_a?(Hash) && allowed_categories.include?("custom_identity_reference")
        data["custom_identity_reference"] = normalized_event(selected["custom_identity_reference"], max_value: 1000)
      end
      data.compact!
      {
        "case_ref" => evidence_case.case_ref,
        "attributed_account_ref" => snapshot&.attributed_account_ref,
        "identity_data" => data,
        "necessity_reason" => reason,
        "mandatory_warning" => "This annex contains restricted platform identity data. It is not proof that a natural person performed the external upload and must not be included in the standard evidence package.",
      }.compact
    end

    def normalize_selections(value)
      source = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      source.is_a?(Hash) ? source.deep_stringify_keys : {}
    end

    def normalized_ip_event(value)
      row = value.deep_stringify_keys
      ip = sanitize(row["value"], 100)
      return nil if ip.blank?
      begin
        IPAddr.new(ip)
      rescue IPAddr::InvalidAddressError
        raise ArgumentError, "invalid_restricted_annex_ip"
      end
      normalized_event(row.merge("value" => ip), max_value: 100)
    end

    def normalized_event(value, max_value:)
      row = value.deep_stringify_keys
      event_value = sanitize(row["value"], max_value)
      return nil if event_value.blank?
      necessity = sanitize(row["necessity"], 1000)
      raise ArgumentError, "restricted_annex_field_necessity_missing" if necessity.blank?

      {
        "value" => event_value,
        "event_time" => sanitize(row["event_time"], 200),
        "source_ref" => sanitize(row["source_ref"], 300),
        "necessity" => necessity,
        "limitation" => sanitize(row["limitation"], 1000),
      }.compact
    end

    def encrypt_storage(payload, case_ref, annex_ref, version)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      iv = SecureRandom.random_bytes(12)
      active_key_id = key_id
      cipher.key = storage_key(active_key_id)
      cipher.iv = iv
      cipher.auth_data = storage_aad(case_ref, annex_ref, version, active_key_id)
      plaintext = ::MediaGallery::EvidenceReference.canonical_json(payload)
      ciphertext = cipher.update(plaintext) + cipher.final
      {
        ciphertext: Base64.strict_encode64(ciphertext),
        iv: Base64.strict_encode64(iv),
        auth_tag: Base64.strict_encode64(cipher.auth_tag),
      }
    end

    def encrypt_export(payload, passphrase, annex)
      salt = SecureRandom.random_bytes(16)
      iv = SecureRandom.random_bytes(12)
      iterations = 250_000
      key = OpenSSL::PKCS5.pbkdf2_hmac(passphrase, salt, iterations, 32, "SHA256")
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      aad = "#{EXPORT_SCHEMA}|#{annex.annex_ref}|#{annex.payload_sha256}"
      cipher.auth_data = aad
      plaintext = ::MediaGallery::EvidenceReference.canonical_json(payload)
      ciphertext = cipher.update(plaintext) + cipher.final
      {
        "schema" => EXPORT_SCHEMA,
        "annex_ref" => annex.annex_ref,
        "case_ref" => annex.evidence_case.case_ref,
        "payload_sha256" => Digest::SHA256.hexdigest(plaintext),
        "encryption" => {
          "algorithm" => "AES-256-GCM",
          "kdf" => "PBKDF2-HMAC-SHA256",
          "iterations" => iterations,
          "salt_b64" => Base64.strict_encode64(salt),
          "iv_b64" => Base64.strict_encode64(iv),
          "auth_tag_b64" => Base64.strict_encode64(cipher.auth_tag),
          "aad" => aad,
        },
        "ciphertext_b64" => Base64.strict_encode64(ciphertext),
      }
    end

    def storage_aad(case_ref, annex_ref, version, annex_key_id)
      "#{STORAGE_SCHEMA}|#{case_ref}|#{annex_ref}|#{version}|#{annex_key_id}"
    end

    def storage_key(annex_key_id)
      secret = master_secret(annex_key_id)
      raise ArgumentError, "restricted_annex_key_unavailable" if secret.bytesize < 32

      Digest::SHA256.digest(secret)
    end

    # The configured environment variable may contain either a single high-entropy
    # secret for the active key ID or a JSON object mapping key IDs to secrets. The
    # latter permits safe key rotation while keeping old annexes decryptable.
    def master_secret(requested_key_id = key_id)
      env_name = SiteSetting.respond_to?(:media_gallery_evidence_restricted_annex_key_env) ? SiteSetting.media_gallery_evidence_restricted_annex_key_env.to_s.strip : ""
      return "" if env_name.blank?

      raw = ENV[env_name].to_s
      return "" if raw.blank?

      begin
        parsed = JSON.parse(raw)
        if parsed.is_a?(Hash)
          return parsed[requested_key_id.to_s].to_s
        end
      rescue JSON::ParserError
        # A normal random secret is intentionally not JSON.
      end
      requested_key_id.to_s == key_id.to_s ? raw : ""
    rescue
      ""
    end

    def selected?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    rescue
      false
    end

    def key_id
      return "" unless SiteSetting.respond_to?(:media_gallery_evidence_restricted_annex_key_id)

      ::MediaGallery::TextSanitizer.plain_text(
        SiteSetting.media_gallery_evidence_restricted_annex_key_id,
        max_length: 200,
        allow_newlines: false,
      ).to_s.strip
    rescue
      ""
    end

    def setting_enabled?(name)
      SiteSetting.respond_to?(name) && ActiveModel::Type::Boolean.new.cast(SiteSetting.public_send(name))
    rescue
      false
    end

    def ensure_access!(user)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :restricted_approver)
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip.presence
    end
    private_class_method :build_payload, :normalize_selections, :normalized_ip_event, :normalized_event,
                         :encrypt_storage, :encrypt_export, :storage_aad, :storage_key, :master_secret, :selected?,
                         :key_id, :setting_enabled?, :ensure_access!, :sanitize
  end
end
