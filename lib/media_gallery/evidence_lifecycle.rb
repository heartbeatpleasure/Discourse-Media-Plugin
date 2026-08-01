# frozen_string_literal: true

module ::MediaGallery
  module EvidenceLifecycle
    module_function

    def withdraw!(evidence_case:, user:, reason:)
      raise Discourse::InvalidAccess.new unless user&.admin?
      raise ArgumentError, "case_already_withdrawn" if evidence_case.status == "withdrawn"
      raise ArgumentError, "case_already_superseded" if evidence_case.status == "superseded"

      clean_reason = sanitize(reason, 4000)
      raise ArgumentError, "lifecycle_reason_missing" if clean_reason.blank?

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "case_already_withdrawn" if evidence_case.status == "withdrawn"
        raise ArgumentError, "case_already_superseded" if evidence_case.status == "superseded"

        ::MediaGallery::EvidenceRelease.revoke_active_for_case!(
          evidence_case: evidence_case,
          user: user,
          reason: "Case withdrawn: #{clean_reason}",
        )
        evidence_case.update!(
          status: "withdrawn",
          lifecycle_reason: clean_reason,
          closed_at: Time.now.utc,
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "case_withdrawn",
          user: user,
          reason: clean_reason,
          details: { status: "withdrawn" },
        )
      end
      evidence_case
    end

    def supersede!(evidence_case:, replacement_case:, user:, reason:)
      raise Discourse::InvalidAccess.new unless user&.admin?
      raise ArgumentError, "replacement_case_required" if replacement_case.blank?
      raise ArgumentError, "cannot_supersede_with_same_case" if replacement_case.id == evidence_case.id
      raise ArgumentError, "case_already_withdrawn" if evidence_case.status == "withdrawn"
      raise ArgumentError, "case_already_superseded" if evidence_case.status == "superseded"
      raise ArgumentError, "replacement_case_closed" if %w[withdrawn superseded].include?(replacement_case.status)
      if evidence_case.media_item_id.present? && replacement_case.media_item_id.present? && evidence_case.media_item_id != replacement_case.media_item_id
        raise ArgumentError, "replacement_case_media_mismatch"
      end
      if replacement_case.supersedes_case_id.present? && replacement_case.supersedes_case_id != evidence_case.id
        raise ArgumentError, "replacement_case_already_supersedes_another_case"
      end

      clean_reason = sanitize(reason, 4000)
      raise ArgumentError, "lifecycle_reason_missing" if clean_reason.blank?

      ::MediaGallery::ForensicEvidenceCase.transaction do
        [evidence_case, replacement_case].sort_by(&:id).each(&:lock!)
        evidence_case.reload
        replacement_case.reload
        raise ArgumentError, "case_already_withdrawn" if evidence_case.status == "withdrawn"
        raise ArgumentError, "case_already_superseded" if evidence_case.status == "superseded"
        raise ArgumentError, "replacement_case_closed" if %w[withdrawn superseded].include?(replacement_case.status)
        if replacement_case.supersedes_case_id.present? && replacement_case.supersedes_case_id != evidence_case.id
          raise ArgumentError, "replacement_case_already_supersedes_another_case"
        end

        ::MediaGallery::EvidenceRelease.revoke_active_for_case!(
          evidence_case: evidence_case,
          user: user,
          reason: "Case superseded by #{replacement_case.case_ref}: #{clean_reason}",
        )
        evidence_case.update!(
          status: "superseded",
          superseded_by_case_id: replacement_case.id,
          lifecycle_reason: clean_reason,
          closed_at: Time.now.utc,
          updated_by: user,
        )
        replacement_case.update!(supersedes_case_id: evidence_case.id, updated_by: user)

        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "case_superseded",
          user: user,
          reason: clean_reason,
          details: {
            status: "superseded",
            superseding_case_ref: replacement_case.case_ref,
          },
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: replacement_case,
          event_type: "case_supersedes_prior_case",
          user: user,
          reason: clean_reason,
          details: { superseded_case_ref: evidence_case.case_ref },
        )
      end
      evidence_case
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip
    end
    private_class_method :sanitize
  end
end
