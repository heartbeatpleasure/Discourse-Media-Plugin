# frozen_string_literal: true

require "digest"
require "securerandom"
require "uri"

module ::MediaGallery
  module EvidenceRelease
    module_function

    class Unavailable < StandardError; end

    DEFAULT_EXPIRY_HOURS = 72
    MAX_EXPIRY_HOURS = 720
    DEFAULT_MAX_DOWNLOADS = 1
    ABSOLUTE_MAX_DOWNLOADS = 20

    def create!(evidence_case:, package:, user:, recipient_ref:, purpose:, expires_in_hours: nil, max_downloads: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      raise ArgumentError, "package_case_mismatch" unless package.evidence_case_id == evidence_case.id
      raise ArgumentError, "case_withdrawn" if evidence_case.status == "withdrawn"
      raise ArgumentError, "case_superseded" if evidence_case.status == "superseded"
      raise ArgumentError, "privacy_processing_restricted" if evidence_case.processing_restricted?
      raise ArgumentError, "retention_disposal_requested" if ::MediaGallery::EvidenceRetention.disposal_requested?(evidence_case)
      raise ArgumentError, "latest_package_required" unless evidence_case.latest_package&.id == package.id
      raise ArgumentError, "secure_release_transport_required" unless transport_ready?

      verification = ::MediaGallery::EvidencePackage.verify(package)
      raise ArgumentError, "package_verification_failed" unless verification[:ok]

      clean_recipient = sanitize(recipient_ref, 200, allow_newlines: false)
      clean_purpose = sanitize(purpose, 4000)
      raise ArgumentError, "release_recipient_reference_missing" if clean_recipient.blank?
      raise ArgumentError, "release_purpose_missing" if clean_purpose.blank?

      hours = normalize_expiry_hours(expires_in_hours)
      allowed_downloads = normalize_max_downloads(max_downloads)
      raw_token = SecureRandom.urlsafe_base64(32, false)
      token_digest = Digest::SHA256.hexdigest(raw_token)
      now = Time.now.utc
      disclosure = nil

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "case_withdrawn" if evidence_case.status == "withdrawn"
        raise ArgumentError, "case_superseded" if evidence_case.status == "superseded"
        raise ArgumentError, "privacy_processing_restricted" if evidence_case.processing_restricted?
        raise ArgumentError, "retention_disposal_requested" if ::MediaGallery::EvidenceRetention.disposal_requested?(evidence_case)
        raise ArgumentError, "latest_package_required" unless evidence_case.latest_package&.id == package.id

        disclosure = ::MediaGallery::ForensicEvidenceDisclosure.create!(
          evidence_case: evidence_case,
          evidence_package: package,
          disclosure_ref: ::MediaGallery::EvidenceReference.disclosure_ref,
          recipient_ref: clean_recipient,
          purpose: clean_purpose,
          token_digest: token_digest,
          expires_at: now + hours.hours,
          max_downloads: allowed_downloads,
          download_count: 0,
          released_by: user,
          released_at: now,
          metadata: {
            "package_sha256" => package.package_sha256,
            "manifest_sha256" => package.manifest_sha256,
            "release_schema" => "media-gallery-evidence-release-v1",
          },
        )

        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "package_release_link_created",
          user: user,
          object_ref: package.package_ref,
          reason: clean_purpose,
          details: {
            disclosure_ref: disclosure.disclosure_ref,
            package_ref: package.package_ref,
            expires_at_utc: disclosure.expires_at.iso8601(6),
            max_downloads: disclosure.max_downloads,
            recipient_ref_sha256: Digest::SHA256.hexdigest(clean_recipient),
            purpose_sha256: Digest::SHA256.hexdigest(clean_purpose),
          },
        )
      end

      ::MediaGallery::EvidenceRetention.apply!(evidence_case: evidence_case.reload, user: user, anchor: now, reason: "Controlled disclosure changed the retention class.", force: true)
      { disclosure: disclosure, token: raw_token }
    end

    def revoke!(disclosure:, user:, reason:)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      clean_reason = sanitize(reason, 4000)
      raise ArgumentError, "release_revocation_reason_missing" if clean_reason.blank?

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case = disclosure.evidence_case
        evidence_case.lock!
        disclosure.lock!
        raise ArgumentError, "release_already_revoked" if disclosure.revoked?

        now = Time.now.utc
        disclosure.update!(
          revoked_at: now,
          revoked_by: user,
          revocation_reason: clean_reason,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "package_release_link_revoked",
          user: user,
          object_ref: disclosure.evidence_package.package_ref,
          reason: clean_reason,
          details: {
            disclosure_ref: disclosure.disclosure_ref,
            package_ref: disclosure.evidence_package.package_ref,
            download_count: disclosure.download_count,
          },
        )
      end
      disclosure
    end

    def revoke_active_for_case!(evidence_case:, user:, reason:)
      evidence_case.disclosures.where(revoked_at: nil).where("download_count < max_downloads").find_each do |disclosure|
        next if disclosure.expired?

        revoke!(disclosure: disclosure, user: user, reason: reason)
      end
    end

    def redeem!(token:, disclosure_ref:)
      digest = Digest::SHA256.hexdigest(token.to_s)
      disclosure = ::MediaGallery::ForensicEvidenceDisclosure.find_by(
        disclosure_ref: disclosure_ref.to_s,
        token_digest: digest,
      )
      raise Unavailable if disclosure.blank?

      package = disclosure.evidence_package
      verification = ::MediaGallery::EvidencePackage.verify(package)
      raise Unavailable unless verification[:ok]

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case = disclosure.evidence_case
        evidence_case.lock!
        disclosure.lock!
        now = Time.now.utc
        raise Unavailable if %w[withdrawn superseded].include?(evidence_case.status)
        raise Unavailable if evidence_case.processing_restricted?
        raise Unavailable unless disclosure.active?(at: now)

        next_count = disclosure.download_count + 1
        disclosure.update!(
          download_count: next_count,
          first_downloaded_at: disclosure.first_downloaded_at || now,
          last_downloaded_at: now,
        )

        if !evidence_case.legal_hold? && evidence_case.status != "released"
          evidence_case.update!(status: "released", updated_at: now)
        end

        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "package_released",
          actor_type: "external_recipient",
          actor_ref: "recipient:#{disclosure.disclosure_ref}",
          object_ref: package.package_ref,
          details: {
            disclosure_ref: disclosure.disclosure_ref,
            package_ref: package.package_ref,
            download_count: next_count,
            max_downloads: disclosure.max_downloads,
            release_status: disclosure.status(at: now),
          },
        )
      end

      { disclosure: disclosure.reload, package: package, path: ::MediaGallery::EvidencePackage.absolute_path(package) }
    rescue Unavailable
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] evidence release redemption failed #{e.class}: #{e.message.to_s.truncate(500)}")
      raise Unavailable
    end


    def site_base_url
      return "" unless Discourse.respond_to?(:base_url)

      Discourse.base_url.to_s.strip.sub(%r{/+\z}, "")
    end

    def transport_secure?
      base = site_base_url
      return false if base.empty?

      uri = URI.parse(base)
      uri.scheme.to_s.downcase == "https" && uri.host.to_s.present?
    rescue URI::InvalidURIError
      false
    end

    def insecure_transport_allowed?
      SiteSetting.respond_to?(:media_gallery_evidence_allow_insecure_release_links) &&
        SiteSetting.media_gallery_evidence_allow_insecure_release_links == true
    rescue
      false
    end

    def transport_ready?
      site_base_url.present? && (transport_secure? || insecure_transport_allowed?)
    end

    # Keep the secret token in the URL fragment. Browsers do not send fragments to the server,
    # so reverse-proxy and Rails access logs receive only the non-secret disclosure reference.
    def public_url(disclosure, token)
      base = site_base_url
      raise ArgumentError, "secure_release_transport_required" if base.blank?

      "#{base}/media-gallery/evidence-release/#{disclosure.disclosure_ref}##{token}"
    end

    def receipt(disclosure)
      evidence_case = disclosure.evidence_case
      package = disclosure.evidence_package
      related_events = evidence_case.chain_events.order(:occurred_at, :id).select do |event|
        event.details.is_a?(Hash) && event.details.deep_stringify_keys["disclosure_ref"] == disclosure.disclosure_ref
      end
      payload = {
        schema: "media-gallery-evidence-release-receipt-v1",
        generated_at_utc: Time.now.utc.iso8601(6),
        disclosure_ref: disclosure.disclosure_ref,
        case_ref: evidence_case.case_ref,
        package_ref: package.package_ref,
        package_sha256: package.package_sha256,
        manifest_sha256: package.manifest_sha256,
        recipient_ref: disclosure.recipient_ref,
        purpose: disclosure.purpose,
        released_by_ref: ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: disclosure.released_by_id,
          role: "senior_staff_reviewer",
        ),
        revoked_by_ref: disclosure.revoked_by_id.present? ? ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: disclosure.revoked_by_id,
          role: "senior_staff_reviewer",
        ) : nil,
        status: disclosure.status,
        released_at_utc: disclosure.released_at&.utc&.iso8601(6),
        expires_at_utc: disclosure.expires_at&.utc&.iso8601(6),
        max_downloads: disclosure.max_downloads,
        download_count: disclosure.download_count,
        first_downloaded_at_utc: disclosure.first_downloaded_at&.utc&.iso8601(6),
        last_downloaded_at_utc: disclosure.last_downloaded_at&.utc&.iso8601(6),
        revoked_at_utc: disclosure.revoked_at&.utc&.iso8601(6),
        revocation_reason: disclosure.revocation_reason,
        chain_events: related_events.map { |event| ::MediaGallery::EvidenceChain.external_hash(event) },
        chain_verification: ::MediaGallery::EvidenceChain.verify(evidence_case),
        limitations: [
          "This receipt is an administrative audit extract generated from the current append-only case record.",
          "The release token is never included and cannot be reconstructed from this receipt.",
          "A successful package hash verification does not establish legal identity, conduct, rights or liability.",
        ],
      }.compact
      canonical = ::MediaGallery::EvidenceReference.canonical_json(payload)
      { receipt: payload, receipt_sha256: Digest::SHA256.hexdigest(canonical), receipt_hash_scope: "canonical_json_of_receipt_object" }
    end

    def default_expiry_hours
      configured = if SiteSetting.respond_to?(:media_gallery_evidence_release_default_hours)
        SiteSetting.media_gallery_evidence_release_default_hours.to_i
      else
        DEFAULT_EXPIRY_HOURS
      end
      [[configured, 1].max, max_expiry_hours].min
    rescue
      DEFAULT_EXPIRY_HOURS
    end

    def max_expiry_hours
      configured = if SiteSetting.respond_to?(:media_gallery_evidence_release_max_hours)
        SiteSetting.media_gallery_evidence_release_max_hours.to_i
      else
        MAX_EXPIRY_HOURS
      end
      [[configured, 1].max, MAX_EXPIRY_HOURS].min
    rescue
      MAX_EXPIRY_HOURS
    end

    def max_downloads_limit
      configured = if SiteSetting.respond_to?(:media_gallery_evidence_release_max_downloads)
        SiteSetting.media_gallery_evidence_release_max_downloads.to_i
      else
        5
      end
      [[configured, 1].max, ABSOLUTE_MAX_DOWNLOADS].min
    rescue
      5
    end

    def normalize_expiry_hours(value)
      requested = value.to_i
      requested = default_expiry_hours if requested <= 0
      [[requested, 1].max, max_expiry_hours].min
    end
    private_class_method :normalize_expiry_hours

    def normalize_max_downloads(value)
      requested = value.to_i
      requested = DEFAULT_MAX_DOWNLOADS if requested <= 0
      [[requested, 1].max, max_downloads_limit].min
    end
    private_class_method :normalize_max_downloads

    def sanitize(value, max_length, allow_newlines: true)
      ::MediaGallery::TextSanitizer.plain_text(
        value,
        max_length: max_length,
        allow_newlines: allow_newlines,
      ).to_s.strip
    end
    private_class_method :sanitize
  end
end
