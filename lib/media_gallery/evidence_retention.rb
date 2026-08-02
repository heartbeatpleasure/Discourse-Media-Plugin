# frozen_string_literal: true

module ::MediaGallery
  module EvidenceRetention
    module_function

    CLASSES = %w[incomplete rejected non_conclusive conclusive sealed_released].freeze
    ACTIONS = %w[retain request_disposal cancel_disposal].freeze

    SETTING_BY_CLASS = {
      "incomplete" => :media_gallery_evidence_retention_incomplete_days,
      "rejected" => :media_gallery_evidence_retention_rejected_days,
      "non_conclusive" => :media_gallery_evidence_retention_non_conclusive_days,
      "conclusive" => :media_gallery_evidence_retention_conclusive_days,
      "sealed_released" => :media_gallery_evidence_retention_sealed_released_days,
    }.freeze

    DEFAULT_DAYS = {
      "incomplete" => 30,
      "rejected" => 90,
      "non_conclusive" => 365,
      "conclusive" => 730,
      "sealed_released" => 1825,
    }.freeze

    def class_for(evidence_case)
      return "rejected" if %w[withdrawn superseded].include?(evidence_case.status)
      return "sealed_released" if evidence_case.packages.exists? || %w[packaged sealed released].include?(evidence_case.status)
      return "conclusive" if evidence_case.decision == "conclusive_match"
      return "non_conclusive" if %w[likely_match ambiguous no_match].include?(evidence_case.decision)

      "incomplete"
    rescue
      "incomplete"
    end

    def days_for(retention_class)
      key = CLASSES.include?(retention_class.to_s) ? retention_class.to_s : "incomplete"
      setting = SETTING_BY_CLASS.fetch(key)
      configured = SiteSetting.respond_to?(setting) ? SiteSetting.public_send(setting).to_i : 0
      configured.positive? ? configured : DEFAULT_DAYS.fetch(key)
    rescue
      DEFAULT_DAYS.fetch(key, 30)
    end

    def apply!(evidence_case:, user: nil, anchor: Time.now.utc, reason: nil, force: false)
      retention_class = class_for(evidence_case)
      due_at = anchor.utc + days_for(retention_class).days
      current_class = evidence_case.respond_to?(:retention_class) ? evidence_case.retention_class.to_s : ""
      current_due = evidence_case.respond_to?(:retention_review_due_at) ? evidence_case.retention_review_due_at : nil
      return evidence_case if !force && current_class == retention_class && current_due.present?

      attributes = {
        retention_class: retention_class,
        retention_due_at: due_at,
        retention_review_due_at: due_at,
      }
      attributes[:updated_by] = user if user.present?
      evidence_case.update!(attributes)
      if user.present?
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "retention_policy_applied",
          user: user,
          reason: sanitize(reason, 1000),
          details: {
            retention_class: retention_class,
            retention_due_at_utc: due_at.iso8601(6),
          },
        )
      end
      evidence_case
    end

    def review!(evidence_case:, user:, action:, reason:, extension_days: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :policy_administrator)
      chosen_action = action.to_s
      raise ArgumentError, "invalid_retention_action" unless ACTIONS.include?(chosen_action)
      cleaned_reason = sanitize(reason, 4000)
      raise ArgumentError, "retention_reason_missing" if cleaned_reason.blank?
      now = Time.now.utc
      review = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "legal_hold_blocks_disposal" if chosen_action == "request_disposal" && evidence_case.legal_hold?

        previous_due = evidence_case.retention_review_due_at || evidence_case.retention_due_at
        retention_class = class_for(evidence_case)
        days = extension_days.to_i
        days = days_for(retention_class) if days <= 0
        raise ArgumentError, "invalid_retention_extension" unless days.between?(1, 3650)
        next_due = chosen_action == "retain" ? now + days.days : previous_due
        metadata = evidence_case.metadata.is_a?(Hash) ? evidence_case.metadata.deep_dup.deep_stringify_keys : {}
        metadata["retention_disposal_requested"] = chosen_action == "request_disposal"
        if chosen_action == "request_disposal"
          metadata["retention_disposal_requested_at_utc"] = now.iso8601(6)
        else
          metadata.delete("retention_disposal_requested_at_utc")
        end

        actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "senior_staff_reviewer",
        )
        review = ::MediaGallery::ForensicEvidenceRetentionReview.create!(
          evidence_case: evidence_case,
          review_ref: ::MediaGallery::EvidenceReference.retention_review_ref,
          action: chosen_action,
          retention_class: retention_class,
          previous_due_at: previous_due,
          next_due_at: next_due,
          reason: cleaned_reason,
          actor: user,
          actor_ref: actor_ref,
          occurred_at: now,
          metadata: { "extension_days" => (days if chosen_action == "retain") }.compact,
        )
        evidence_case.update!(
          retention_class: retention_class,
          retention_reviewed_at: now,
          retention_due_at: next_due || evidence_case.retention_due_at,
          retention_review_due_at: next_due || evidence_case.retention_review_due_at,
          metadata: metadata,
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "retention_review_recorded",
          user: user,
          object_ref: review.review_ref,
          reason: cleaned_reason,
          details: {
            retention_action: chosen_action,
            retention_class: retention_class,
            previous_due_at_utc: previous_due&.utc&.iso8601(6),
            next_due_at_utc: next_due&.utc&.iso8601(6),
          }.compact,
        )
      end
      review
    end

    def warning_days
      value = SiteSetting.respond_to?(:media_gallery_evidence_retention_warning_days) ? SiteSetting.media_gallery_evidence_retention_warning_days.to_i : 30
      value.between?(1, 365) ? value : 30
    rescue
      30
    end

    def overdue?(evidence_case, at: Time.now.utc)
      due = evidence_case.retention_review_due_at || evidence_case.retention_due_at
      due.present? && due < at
    end

    def due_soon?(evidence_case, at: Time.now.utc)
      due = evidence_case.retention_review_due_at || evidence_case.retention_due_at
      due.present? && due >= at && due <= at + warning_days.days
    end

    def disposal_requested?(evidence_case)
      evidence_case.metadata.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(evidence_case.metadata["retention_disposal_requested"])
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip.presence
    end
    private_class_method :sanitize
  end
end
