# frozen_string_literal: true

module ::MediaGallery
  module EvidenceReview
    module_function

    def record!(evidence_case:, user:, review_kind:, outcome:, checklist:, reason: nil)
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      kind = review_kind.to_s
      raise ArgumentError, "invalid_review_kind" unless %w[technical senior privacy].include?(kind)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, ::MediaGallery::EvidenceAuthorization.review_capability(kind))

      normalized = ::MediaGallery::EvidencePolicy.normalize_checklist(checklist)
      result = outcome.to_s == "approved" ? "approved" : "rejected"
      cleaned_reason = sanitize(reason, 4000)
      raise ArgumentError, "review_checklist_incomplete" if result == "approved" && !::MediaGallery::EvidencePolicy.approved_checklist?(normalized)
      raise ArgumentError, "review_rejection_reason_missing" if result == "rejected" && cleaned_reason.blank?

      review = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        role = case kind
        when "privacy" then "privacy_legal_approver"
        when "senior" then "senior_staff_reviewer"
        else "staff_reviewer"
        end
        review = ::MediaGallery::ForensicEvidenceReview.create!(
          evidence_case: evidence_case,
          review_ref: ::MediaGallery::EvidenceReference.review_ref,
          review_kind: kind,
          reviewer_role: role,
          reviewer: user,
          reviewer_ref: ::MediaGallery::EvidenceReference.reviewer_ref(case_ref: evidence_case.case_ref, user_id: user.id, role: role),
          outcome: result,
          reason: cleaned_reason,
          checklist: normalized,
          reviewed_at: Time.now.utc,
        )

        next_status = if result == "approved"
          evidence_case.claimant_confirmed? ? "claimant_confirmed" : "reviewed"
        else
          "review_pending"
        end
        evidence_case.update!(status: next_status, updated_by: user)
        chain_actor_type = case role
        when "privacy_legal_approver" then "privacy_approver"
        when "senior_staff_reviewer" then "senior_staff"
        else "staff"
        end
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: result == "approved" ? "review_approved" : "review_rejected",
          user: user,
          actor_type: chain_actor_type,
          actor_ref: review.reviewer_ref,
          object_ref: review.review_ref,
          reason: review.reason,
          details: {
            review_kind: review.review_kind,
            reviewer_role: review.reviewer_role,
            reviewer_ref: review.reviewer_ref,
            checklist: review.checklist,
          },
        )
      end
      review
    end

    def review_legal_hold!(evidence_case:, user:, reason:, authority_ref: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      raise ArgumentError, "legal_hold_not_active" unless evidence_case.legal_hold?
      cleaned_reason = sanitize(reason, 4000)
      raise ArgumentError, "legal_hold_reason_missing" if cleaned_reason.blank?

      now = Time.now.utc
      review_due_at = now + legal_hold_review_days.days
      hold = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "legal_hold_not_active" unless evidence_case.legal_hold?

        actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "senior_staff_reviewer",
        )
        hold = ::MediaGallery::ForensicLegalHold.create!(
          evidence_case: evidence_case,
          hold_ref: ::MediaGallery::EvidenceReference.hold_ref,
          action: "reviewed",
          reason: cleaned_reason,
          authority_ref: sanitize(authority_ref, 200),
          actor: user,
          actor_ref: actor_ref,
          occurred_at: now,
          review_due_at: review_due_at,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "legal_hold_reviewed",
          user: user,
          actor_type: "senior_staff",
          actor_ref: actor_ref,
          object_ref: hold.hold_ref,
          reason: cleaned_reason,
          details: {
            hold_action: "reviewed",
            review_due_at_utc: review_due_at.iso8601(6),
          },
        )
      end
      hold
    end

    def set_legal_hold!(evidence_case:, user:, active:, reason:, authority_ref: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      requested = ActiveModel::Type::Boolean.new.cast(active)
      cleaned_reason = sanitize(reason, 4000)
      raise ArgumentError, "legal_hold_reason_missing" if cleaned_reason.blank?

      hold = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "legal_hold_already_in_state" if evidence_case.legal_hold? == requested

        actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "senior_staff_reviewer",
        )
        hold = ::MediaGallery::ForensicLegalHold.create!(
          evidence_case: evidence_case,
          hold_ref: ::MediaGallery::EvidenceReference.hold_ref,
          action: requested ? "placed" : "released",
          reason: cleaned_reason,
          authority_ref: sanitize(authority_ref, 200),
          actor: user,
          actor_ref: actor_ref,
          occurred_at: Time.now.utc,
          review_due_at: requested ? Time.now.utc + legal_hold_review_days.days : nil,
        )
        closed_status = %w[withdrawn superseded].include?(evidence_case.status)
        next_status = if requested
          closed_status ? evidence_case.status : "legal_hold"
        elsif closed_status
          evidence_case.status
        else
          evidence_case.pre_legal_hold_status.presence || restored_status(evidence_case)
        end
        evidence_case.update!(
          legal_hold: requested,
          status: next_status,
          pre_legal_hold_status: requested && !closed_status ? evidence_case.status : nil,
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: requested ? "legal_hold_placed" : "legal_hold_released",
          user: user,
          object_ref: hold.hold_ref,
          reason: cleaned_reason,
          details: { authority_ref: hold.authority_ref, review_due_at_utc: hold.review_due_at&.utc&.iso8601(6) }.compact,
        )
      end
      hold
    end

    def restored_status(evidence_case)
      package = evidence_case.latest_package
      return "sealed" if package&.status == "sealed"
      return "packaged" if package.present?
      return "approved_for_seal" if evidence_case.reports.where(status: "final_unsealed").exists?
      return "claimant_confirmed" if evidence_case.claimant_confirmed?
      return "reviewed" if evidence_case.reviews.where(outcome: "approved").exists?
      return "identified" if evidence_case.identify_snapshots.exists?
      return "evidence_acquired" if evidence_case.evidence_objects.exists?

      "draft"
    end

    def legal_hold_review_days
      value = SiteSetting.respond_to?(:media_gallery_evidence_legal_hold_review_days) ? SiteSetting.media_gallery_evidence_legal_hold_review_days.to_i : 180
      value.between?(1, 3650) ? value : 180
    rescue
      180
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip
    end
    private_class_method :sanitize, :restored_status, :legal_hold_review_days
  end
end
