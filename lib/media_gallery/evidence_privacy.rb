# frozen_string_literal: true

require "digest"

module ::MediaGallery
  module EvidencePrivacy
    module_function

    RESPONSE_PERIOD = 1.month

    def create_request!(evidence_case:, user:, request_type:, requester_ref:, received_at: nil, processing_restricted: false, reason: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :policy_administrator)
      type = request_type.to_s
      raise ArgumentError, "invalid_privacy_request_type" unless ::MediaGallery::ForensicEvidencePrivacyRequest::REQUEST_TYPES.include?(type)
      requester = sanitize(requester_ref, 200)
      raise ArgumentError, "privacy_requester_reference_missing" if requester.blank?
      received = parse_time(received_at) || Time.now.utc
      restriction = ActiveModel::Type::Boolean.new.cast(processing_restricted)
      cleaned_reason = sanitize(reason, 4000)
      if restriction && cleaned_reason.blank?
        raise ArgumentError, "privacy_processing_restriction_reason_missing"
      end

      request = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "privacy_legal_approver",
        )
        request = ::MediaGallery::ForensicEvidencePrivacyRequest.create!(
          evidence_case: evidence_case,
          request_ref: ::MediaGallery::EvidenceReference.privacy_request_ref,
          request_type: type,
          requester_ref: requester,
          status: "open",
          received_at: received,
          due_at: received + RESPONSE_PERIOD,
          processing_restricted: restriction,
          reason: cleaned_reason,
          created_by: user,
          created_by_ref: actor_ref,
        )
        sync_case_flags!(evidence_case, user: user)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "privacy_request_recorded",
          user: user,
          actor_type: "privacy_approver",
          actor_ref: actor_ref,
          object_ref: request.request_ref,
          reason: cleaned_reason,
          details: {
            request_type: type,
            request_status: request.status,
            processing_restricted: restriction,
            due_at_utc: request.due_at.utc.iso8601(6),
            requester_ref_sha256: Digest::SHA256.hexdigest(requester),
          },
        )
      end
      request
    end

    def update_request!(request:, user:, status:, processing_restricted: nil, decision: nil, reason: nil)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :policy_administrator)
      new_status = status.to_s
      raise ArgumentError, "invalid_privacy_request_status" unless ::MediaGallery::ForensicEvidencePrivacyRequest::STATUSES.include?(new_status)
      cleaned_reason = sanitize(reason, 4000)
      cleaned_decision = sanitize(decision, 4000)
      if %w[resolved rejected withdrawn].include?(new_status) && cleaned_decision.blank?
        raise ArgumentError, "privacy_request_decision_missing"
      end

      evidence_case = request.evidence_case
      now = Time.now.utc
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        request.lock!
        request.reload
        actor_ref = ::MediaGallery::EvidenceReference.reviewer_ref(
          case_ref: evidence_case.case_ref,
          user_id: user.id,
          role: "privacy_legal_approver",
        )
        attributes = {
          status: new_status,
          reason: cleaned_reason.presence || request.reason,
          decision: cleaned_decision.presence || request.decision,
        }
        unless processing_restricted.nil?
          requested_restriction = ActiveModel::Type::Boolean.new.cast(processing_restricted)
          if requested_restriction != request.processing_restricted? && cleaned_reason.blank?
            raise ArgumentError, "privacy_processing_restriction_reason_missing"
          end
          attributes[:processing_restricted] = requested_restriction
        end
        if %w[resolved rejected withdrawn].include?(new_status)
          attributes.merge!(resolved_by: user, resolved_by_ref: actor_ref, resolved_at: now)
        else
          attributes.merge!(resolved_by: nil, resolved_by_ref: nil, resolved_at: nil)
        end
        request.update!(attributes)
        sync_case_flags!(evidence_case, user: user)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "privacy_request_updated",
          user: user,
          actor_type: "privacy_approver",
          actor_ref: actor_ref,
          object_ref: request.request_ref,
          reason: cleaned_reason,
          details: {
            request_type: request.request_type,
            request_status: request.status,
            processing_restricted: request.processing_restricted?,
            decision_present: request.decision.to_s.present?,
            decision_sha256: (Digest::SHA256.hexdigest(request.decision.to_s) if request.decision.to_s.present?),
          }.compact,
        )
      end
      request
    end

    def sync_case_flags!(evidence_case, user: nil)
      open_scope = evidence_case.privacy_requests.where(status: %w[open under_review])
      privacy_open = open_scope.exists?
      restricted = open_scope.where(processing_restricted: true).exists?
      attrs = { privacy_request_open: privacy_open, processing_restricted: restricted }
      attrs[:updated_by] = user if user.present?
      evidence_case.update!(attrs)
      evidence_case
    end

    def parse_time(value)
      return value.utc if value.respond_to?(:utc)
      return nil if value.to_s.strip.blank?

      Time.zone.parse(value.to_s)&.utc
    rescue
      raise ArgumentError, "invalid_datetime"
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip.presence
    end
    private_class_method :parse_time, :sanitize
  end
end
