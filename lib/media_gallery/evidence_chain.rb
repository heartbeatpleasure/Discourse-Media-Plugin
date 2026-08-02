# frozen_string_literal: true

require "digest"

module ::MediaGallery
  module EvidenceChain
    module_function

    HASH_SCHEMA = "media-gallery-evidence-chain-v1"
    MATERIAL_REVIEW_EVENT_TYPES = %w[
      case_created case_intake_updated source_capture_added evidence_object_acquired
      evidence_quarantine_reviewed evidence_acquisition_checked identify_snapshot_attached claimant_confirmation_recorded
    ].freeze
    REPORT_MATERIAL_EVENT_TYPES = (MATERIAL_REVIEW_EVENT_TYPES + %w[review_approved review_rejected]).freeze
    EXTERNAL_DETAIL_KEYS = %w[
      status media_public_id classification report_language changed_fields claimant_confirmation_invalidated role storage_kind sha256
      size_bytes quarantine_status previous_status scan_state scan_provider inspection_state run_ref run_kind decision synthetic_population
      raw_result_sha256 sanity_status review_kind reviewer_role reviewer_ref checklist report_version
      report_data_sha256 pdf_sha256 package_version package_sha256 manifest_sha256 seal_method
      cms_signature_integrity_verified certificate_trust_verified timestamp_status disclosure_ref package_ref
      expires_at_utc max_downloads download_count release_status recipient_ref_sha256 purpose_sha256 superseding_case_ref superseded_case_ref
    ].freeze

    def record!(evidence_case:, event_type:, user: nil, object_ref: nil, reason: nil, details: {}, actor_ref: nil, actor_type: nil, occurred_at: Time.now.utc)
      evidence_case.with_lock do
        previous = evidence_case.chain_events.order(occurred_at: :desc, id: :desc).first
        resolved_actor_type = actor_type.presence || ::MediaGallery::EvidenceReference.actor_type_for_user(user)
        resolved_actor_ref = actor_ref.presence || actor_reference(evidence_case, user, resolved_actor_type)
        event_ref = ::MediaGallery::EvidenceReference.event_ref
        normalized_reason = reason.to_s.presence
        normalized_details = details.is_a?(Hash) ? details.deep_stringify_keys : {}
        payload = event_hash_payload(
          event_ref: event_ref,
          case_ref: evidence_case.case_ref,
          event_type: event_type.to_s,
          actor_type: resolved_actor_type,
          actor_ref: resolved_actor_ref,
          object_ref: object_ref.to_s.presence,
          reason: normalized_reason,
          previous_event_hash: previous&.event_hash,
          details: normalized_details,
          occurred_at: occurred_at,
        )
        event_hash = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload))

        ::MediaGallery::ForensicChainEvent.create!(
          evidence_case: evidence_case,
          event_ref: event_ref,
          event_type: event_type.to_s,
          actor_type: resolved_actor_type,
          actor_user: user,
          actor_ref: resolved_actor_ref,
          object_ref: object_ref.to_s.presence,
          reason: normalized_reason,
          previous_event_hash: previous&.event_hash,
          event_hash: event_hash,
          details: normalized_details,
          occurred_at: occurred_at.utc,
        )
      end
    end

    def verify(evidence_case)
      errors = []
      previous_hash = nil
      events = evidence_case.chain_events.order(:occurred_at, :id).to_a
      events.each_with_index do |event, index|
        payload = event_hash_payload(
          event_ref: event.event_ref,
          case_ref: evidence_case.case_ref,
          event_type: event.event_type,
          actor_type: event.actor_type,
          actor_ref: event.actor_ref,
          object_ref: event.object_ref,
          reason: event.reason,
          previous_event_hash: event.previous_event_hash,
          details: event.details.is_a?(Hash) ? event.details : {},
          occurred_at: event.occurred_at,
        )
        expected = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload))
        errors << "event_#{index + 1}_hash_mismatch" unless secure_compare(expected, event.event_hash)
        errors << "event_#{index + 1}_previous_hash_mismatch" unless event.previous_event_hash.to_s == previous_hash.to_s
        previous_hash = event.event_hash
      end

      {
        ok: errors.empty?,
        hash_schema: HASH_SCHEMA,
        event_count: events.length,
        head_hash: previous_hash,
        errors: errors,
      }
    end

    # Internal serialization is restricted and may contain free-text reasons and complete details.
    def serialize(evidence_case)
      evidence_case.chain_events.order(:occurred_at, :id).map { |event| internal_hash(event) }
    end

    def internal_hash(event)
      common_hash(event).merge(
        reason: event.reason,
        details: event.details.is_a?(Hash) ? event.details : {},
      ).compact
    end

    # External reports/packages contain the exact digests used by the event hash, plus a strictly
    # allowlisted detail summary. This permits independent hash-chain verification without exposing
    # staff free text, legal references, usernames, user IDs, IP addresses or other accidental data.
    def external_hash(event)
      reason = event.reason.to_s
      details = event.details.is_a?(Hash) ? event.details.deep_stringify_keys : {}
      common_hash(event).merge(
        reason_present: reason.present?,
        reason_sha256: reason.present? ? Digest::SHA256.hexdigest(reason) : nil,
        details_sha256: details_digest(details),
        details_summary: details.slice(*EXTERNAL_DETAIL_KEYS),
      ).compact
    end

    def latest_material_event_at(evidence_case)
      evidence_case.chain_events.where(event_type: MATERIAL_REVIEW_EVENT_TYPES).maximum(:occurred_at) || Time.at(0).utc
    end

    def latest_report_material_event_at(evidence_case)
      evidence_case.chain_events.where(event_type: REPORT_MATERIAL_EVENT_TYPES).maximum(:occurred_at) || Time.at(0).utc
    end

    def actor_reference(evidence_case, user, actor_type)
      return "system:evidence-service" if user.blank?

      role = case actor_type.to_s
      when "senior_staff"
        "senior_staff_reviewer"
      when "privacy_approver"
        "privacy_legal_approver"
      else
        "staff_reviewer"
      end
      ::MediaGallery::EvidenceReference.reviewer_ref(case_ref: evidence_case.case_ref, user_id: user.id, role: role)
    end
    private_class_method :actor_reference

    def event_hash_payload(event_ref:, case_ref:, event_type:, actor_type:, actor_ref:, object_ref:, reason:, previous_event_hash:, details:, occurred_at:)
      reason_text = reason.to_s
      normalized_details = details.is_a?(Hash) ? details.deep_stringify_keys : {}
      {
        hash_schema: HASH_SCHEMA,
        event_ref: event_ref,
        case_ref: case_ref,
        event_type: event_type,
        actor_type: actor_type,
        actor_ref: actor_ref,
        object_ref: object_ref,
        reason_present: reason_text.present?,
        reason_sha256: reason_text.present? ? Digest::SHA256.hexdigest(reason_text) : nil,
        details_sha256: details_digest(normalized_details),
        previous_event_hash: previous_event_hash,
        occurred_at_utc: occurred_at.utc.iso8601(6),
      }
    end
    private_class_method :event_hash_payload

    def common_hash(event)
      {
        hash_schema: HASH_SCHEMA,
        event_ref: event.event_ref,
        case_ref: event.evidence_case.case_ref,
        event_type: event.event_type,
        actor_type: event.actor_type,
        actor_ref: event.actor_ref,
        object_ref: event.object_ref,
        previous_event_hash: event.previous_event_hash,
        event_hash: event.event_hash,
        occurred_at_utc: event.occurred_at&.utc&.iso8601(6),
      }
    end
    private_class_method :common_hash

    def details_digest(details)
      Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(details.is_a?(Hash) ? details : {}))
    end
    private_class_method :details_digest

    def secure_compare(left, right)
      return false if left.blank? || right.blank? || left.bytesize != right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    rescue
      left == right
    end
    private_class_method :secure_compare
  end
end
