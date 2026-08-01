# frozen_string_literal: true

module ::MediaGallery
  module EvidenceErrors
    module_function

    MESSAGES = {
      "evidence_needs_rerun" => "Run Forensics Identify again and create a new evidence case from the new result.",
      "identify_attestation_legacy_result_requires_rerun" => "This result uses an earlier evidence attestation format. Run Forensics Identify again and create the case from the new result.",
      "identify_attestation_result_hash_mismatch" => "The server-attested identify result changed during browser transport and cannot be imported safely. Run Forensics Identify again; check the server logs if a new result also fails.",
      "identify_result_not_server_attested" => "This identify result is not server-attested. Run Forensics Identify again after evidence reporting is enabled.",
      "identify_attestation_signature_invalid" => "The server attestation signature is invalid. Do not use this result as evidence; run Forensics Identify again and review the server logs if it repeats.",
      "identify_attestation_signature_missing" => "The identify result does not contain a complete server attestation. Run Forensics Identify again.",
      "identify_attestation_schema_invalid" => "The identify result uses an unsupported evidence attestation format. Run Forensics Identify again after updating the plugin.",
      "identify_attestation_hash_canonicalization_invalid" => "The identify result uses an unsupported evidence hash format. Run Forensics Identify again after updating the plugin.",
      "identify_attestation_public_id_mismatch" => "The attested media ID does not match the selected media item. Run Forensics Identify again for the correct item.",
      "identify_attestation_media_item_mismatch" => "The attested internal media item does not match the selected media item. Run Forensics Identify again for the correct item.",
      "identify_attestation_run_ref_missing" => "The server attestation is incomplete because its run reference is missing. Run Forensics Identify again.",
      "identify_attestation_non_finite_number" => "The identify result contains an invalid non-finite number and cannot be stored as evidence.",
      "identify_attestation_invalid_number" => "The identify result contains an invalid numeric value and cannot be stored as evidence.",
      "evidence_attestation_secret_unavailable" => "The evidence attestation secret is unavailable. Check the evidence reviewer secret and the Discourse secret configuration.",
      "invalid_identify_result" => "The identify result is incomplete or has an invalid structure.",
      "invalid_identify_json" => "The identify result is not valid JSON.",
      "identify_result_too_large" => "The identify result is too large to store as an evidence snapshot.",
      "identify_media_item_missing" => "The media item referenced by the identify result could not be found.",
      "identify_media_item_mismatch" => "The identify result belongs to a different media item.",
      "case_not_mutable" => "This evidence case can no longer be changed because it has already entered an immutable lifecycle stage.",
      "invalid_datetime" => "One of the entered dates or times is invalid. Select a valid date and time and try again.",
      "rights_statement_missing" => "Record when the rights claimant statement was received before confirming the claimant.",
      "invalid_review_kind" => "The selected review type is not supported.",
      "review_checklist_incomplete" => "Complete every review checklist item before approving the review.",
      "review_rejection_reason_missing" => "Enter a reason before rejecting a review.",
      "legal_hold_reason_missing" => "Enter a reason before placing or releasing a legal hold.",
      "legal_hold_already_in_state" => "The legal hold is already in the requested state.",
      "evidence_package_missing" => "Generate or select an evidence package before creating a release link.",
      "package_case_mismatch" => "The selected package does not belong to this evidence case.",
      "latest_package_required" => "Create the release link for the latest evidence package version.",
      "package_verification_failed" => "The evidence package did not pass integrity verification and cannot be released.",
      "secure_release_transport_required" => "Controlled evidence-package release requires an HTTPS site URL. Use HTTPS, or enable the explicit insecure test-only override in an isolated test environment.",
      "release_recipient_reference_missing" => "Enter a non-sensitive recipient reference before creating the release link.",
      "release_purpose_missing" => "Describe the authorised purpose for this release.",
      "release_revocation_reason_missing" => "Enter a reason before revoking the release link.",
      "release_already_revoked" => "This release link has already been revoked.",
      "case_withdrawn" => "This case has been withdrawn and cannot be released.",
      "case_superseded" => "This case has been superseded and cannot be released.",
      "case_already_withdrawn" => "This case has already been withdrawn.",
      "case_already_superseded" => "This case has already been superseded.",
      "lifecycle_reason_missing" => "Enter a reason for the lifecycle action.",
      "replacement_case_required" => "Select the replacement evidence case.",
      "cannot_supersede_with_same_case" => "A case cannot supersede itself.",
      "replacement_case_closed" => "The replacement case is withdrawn or superseded and cannot be used.",
      "replacement_case_media_mismatch" => "The replacement case refers to a different media item.",
      "replacement_case_already_supersedes_another_case" => "The replacement case already supersedes another evidence case.",
      "invalid_lifecycle_action" => "The selected case lifecycle action is not supported.",
      "invalid_quarantine_status" => "The selected quarantine status is not supported.",
      "not_applicable_not_allowed" => "External originals and working copies must be explicitly marked clean or rejected.",
      "evidence_file_empty" => "The selected evidence file is empty.",
      "evidence_file_too_large" => "The selected evidence file exceeds the configured evidence upload limit.",
      "invalid_evidence_role" => "The selected evidence-object role is not supported.",
      "invalid_sha256" => "Enter a valid 64-character SHA-256 hash.",
      "vault_reference_missing" => "Enter a vault reference.",
      "invalid_size_bytes" => "Enter a valid non-negative file size.",
      "source_url_too_long" => "The external source URL is too long.",
      "source_url_scheme_not_allowed" => "The external source URL must use HTTP or HTTPS.",
      "source_url_userinfo_not_allowed" => "The external source URL must not contain a username or password.",
      "source_url_host_missing" => "The external source URL must contain a hostname.",
      "invalid_source_url" => "Enter a valid external source URL.",
      "draft_not_allowed_after_final_report" => "A new draft cannot be generated after a final report has been created.",
      "final_report_missing" => "Generate a final report before creating an evidence package.",
      "final_report_required" => "Select a final report before creating an evidence package.",
      "latest_final_report_required" => "Create the package from the latest final report version.",
      "final_report_stale_after_material_change" => "The final report is older than a material case change. Generate and approve a new final report first.",
      "cms_seal_not_configured" => "CMS signing is selected, but the signing key and certificate are not fully configured.",
      "evidence_case_not_ready" => "This case is not ready for finalization. Complete the remaining items shown under Finalization readiness.",
      "generated_package_verification_failed" => "The generated evidence package failed its integrity verification and was not accepted.",
      "package_hash_mismatch" => "The stored evidence package no longer matches its recorded SHA-256 hash.",
      "report_hash_mismatch" => "The stored evidence report no longer matches its recorded SHA-256 hash.",
      "record_not_found" => "The requested evidence case or evidence object could not be found.",
      "invalid_access" => "You do not have permission to perform this evidence action.",
      "invalid_parameters" => "One or more submitted values are invalid.",
      "validation_failed" => "The evidence record could not be saved because one or more values are invalid.",
      "evidence_request_failed" => "The evidence request could not be completed because of an internal error. Check the Discourse server logs for the recorded evidence error.",
    }.freeze

    CODE_PATTERN = /\A[a-z][a-z0-9_]*(?::.*)?\z/

    def payload(error)
      code = code_for(error)
      { error: message_for(error, code: code), error_code: code }
    end

    def code_for(error)
      raw = error&.message.to_s.strip
      if raw.match?(CODE_PATTERN)
        base = raw.split(":", 2).first
        return base if base.present?
      end

      return "record_not_found" if defined?(ActiveRecord::RecordNotFound) && error.is_a?(ActiveRecord::RecordNotFound)
      return "validation_failed" if defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)
      return "invalid_access" if defined?(Discourse::InvalidAccess) && error.is_a?(Discourse::InvalidAccess)
      return "invalid_parameters" if defined?(Discourse::InvalidParameters) && error.is_a?(Discourse::InvalidParameters)

      "evidence_request_failed"
    end

    def message_for(error, code: code_for(error))
      return validation_message(error) if code == "validation_failed"

      MESSAGES[code] || humanize_code(code)
    end

    def status_for(error)
      return 403 if defined?(Discourse::InvalidAccess) && error.is_a?(Discourse::InvalidAccess)
      if (defined?(ActiveRecord::RecordNotFound) && error.is_a?(ActiveRecord::RecordNotFound)) ||
          (defined?(Discourse::NotFound) && error.is_a?(Discourse::NotFound))
        return 404
      end
      return 422 if error.is_a?(ArgumentError)
      return 422 if defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)
      return 422 if defined?(Discourse::InvalidParameters) && error.is_a?(Discourse::InvalidParameters)

      500
    end

    def humanize_code(code)
      text = code.to_s.split(":", 2).first.to_s.tr("_", " ").strip
      return MESSAGES["evidence_request_failed"] if text.blank?

      "#{text.sub(/\A./) { |character| character.upcase }}."
    end

    def validation_message(error)
      messages = error.respond_to?(:record) ? Array(error.record&.errors&.full_messages) : []
      cleaned = messages.map { |message| humanize_validation_text(message) }.reject(&:blank?)
      return MESSAGES["validation_failed"] if cleaned.empty?

      "The evidence record could not be saved: #{cleaned.join('; ')}."
    rescue
      MESSAGES["validation_failed"]
    end
    private_class_method :validation_message

    def humanize_validation_text(value)
      text = value.to_s.tr("_", " ").gsub(/\s+/, " ").strip
      text.sub(/\A./) { |character| character.upcase }
    end
    private_class_method :humanize_validation_text
  end
end
