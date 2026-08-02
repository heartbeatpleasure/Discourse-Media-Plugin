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
      "legal_hold_not_active" => "This case does not currently have an active legal hold to review.",
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
      "evidence_storage_low_space" => "The evidence file was not stored because the private evidence filesystem would fall below its configured free-space reserve.",
      "evidence_storage_unavailable" => "The private evidence filesystem is unavailable or not writable. No evidence data was stored.",
      "evidence_source_symlink_not_allowed" => "The selected evidence upload resolves to a symbolic link and was rejected.",
      "evidence_root_symlink_not_allowed" => "The configured evidence storage root must not be a symbolic link.",
      "evidence_object_not_file_backed" => "Only private file-backed evidence objects can be scanned by this installation.",
      "evidence_scan_queue_failed" => "The evidence security check could not be queued. Check Sidekiq and the Discourse server logs.",
      "quarantine_reason_required" => "Enter a reason for the manual quarantine decision.",
      "infected_evidence_cannot_be_marked_clean" => "Evidence with a malware detection cannot be manually marked clean. Reject it or correct the scanner finding outside this case and rescan a new evidence object.",
      "evidence_scan_file_missing" => "The private evidence file could not be found for scanning.",
      "evidence_clamd_host_missing" => "ClamAV scanning is enabled, but the private clamd host is not configured.",
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
      "cms_seal_key_revoked" => "The configured CMS signing-key ID is marked as revoked. Select a current key before creating another evidence package.",
      "cms_certificate_trust_not_configured" => "The selected CMS certificate-trust mode is incomplete. Configure the required CA bundle or certificate pin.",
      "cms_certificate_not_current" => "The CMS signing certificate is not currently valid. Check its validity period and server time.",
      "cms_certificate_pin_mismatch" => "The CMS signing certificate does not match the configured SHA-256 certificate pin.",
      "cms_key_certificate_mismatch" => "The configured CMS private key does not match the configured signing certificate.",
      "cms_certificate_chain_untrusted" => "The CMS signing certificate chain could not be validated with the configured trust source.",
      "cms_certificate_trust_verification_failed" => "The CMS signature was created, but the configured certificate-trust verification did not succeed. The package was not accepted.",
      "cms_signature_self_verification_failed" => "The newly created CMS signature did not pass immediate integrity verification. The package was not accepted.",
      "cms_signature_invalid" => "The CMS signature does not verify against the package manifest.",
      "cms_manifest_certificate_mismatch" => "The embedded CMS certificate does not match the certificate fingerprint recorded in the signed manifest.",
      "cms_certificate_chain_missing" => "The configured CMS certificate-chain file could not be found.",
      "cms_ca_bundle_missing" => "The configured CMS CA bundle could not be found.",
      "pdfa_conversion_not_configured" => "PDF/A-2b is selected, but Ghostscript, the reviewed PDF/A definition file and veraPDF are not all configured and available.",
      "archival_pdf_tool_timeout" => "The PDF/A conversion or validation tool exceeded the configured time limit.",
      "archival_pdf_tool_failed" => "The PDF/A conversion or validation tool failed. Check the server log for the bounded diagnostic output.",
      "archival_pdf_tool_output_too_large" => "The PDF/A conversion or validation tool produced more diagnostic output than allowed.",
      "pdfa_output_missing" => "The PDF/A converter did not create a usable output file.",
      "pdfa_output_too_large" => "The converted PDF/A report exceeds the report safety limit and was not accepted.",
      "pdfa_validation_failed" => "The converted report did not pass local PDF/A-2b validation and was not accepted as a final report.",
      "verapdf_invalid_json" => "veraPDF returned an invalid validation report. Check the installed veraPDF version and server logs.",
      "timestamp_not_configured" => "RFC 3161 timestamping is selected, but the endpoint or trust configuration is incomplete.",
      "timestamp_https_required" => "The RFC 3161 timestamp endpoint must use HTTPS.",
      "timestamp_tls_ca_bundle_missing" => "The configured TLS CA bundle for the timestamp connection could not be found.",
      "timestamp_trust_bundle_missing" => "The configured RFC 3161 trust bundle could not be found.",
      "timestamp_verification_failed" => "The RFC 3161 response could not be verified against the request and configured trust source.",
      "timestamp_response_not_granted" => "The timestamp authority did not grant the RFC 3161 request.",
      "timestamp_rejected" => "The timestamp authority rejected the RFC 3161 request. Check the configured policy and service account.",
      "timestamp_policy_mismatch" => "The RFC 3161 response uses a different policy OID than the configured policy.",
      "timestamp_tsa_certificate_missing" => "The RFC 3161 response does not contain the TSA certificate required for verification.",
      "timestamp_certificate_pin_mismatch" => "The timestamp-authority certificate does not match the configured SHA-256 certificate pin.",
      "timestamp_chain_or_imprint_invalid" => "The RFC 3161 signature, certificate chain or message imprint could not be verified.",
      "timestamp_response_too_large" => "The timestamp authority returned a response larger than the allowed safety limit.",
      "timestamp_http_error" => "The timestamp authority returned an unsuccessful HTTP response.",
      "timestamp_empty_response" => "The timestamp authority returned an empty response.",
      "evidence_case_not_ready" => "This case is not ready for finalization. Complete the remaining items shown under Finalization readiness.",
      "generated_package_verification_failed" => "The generated evidence package failed its integrity verification and was not accepted.",
      "package_hash_mismatch" => "The stored evidence package no longer matches its recorded SHA-256 hash.",
      "report_hash_mismatch" => "The stored evidence report no longer matches its recorded SHA-256 hash.",
      "record_not_found" => "The requested evidence case or evidence object could not be found.",
      "invalid_access" => "You do not have permission to perform this evidence action.",
      "invalid_parameters" => "One or more submitted values are invalid.",
      "validation_failed" => "The evidence record could not be saved because one or more values are invalid.",
      "governance_profile_missing" => "Capture the current platform governance profile before finalizing this case.",
      "governance_replacement_reason_missing" => "Enter a reason before replacing the case governance snapshot.",
      "invalid_retention_action" => "Select a supported retention-review action.",
      "retention_reason_missing" => "Enter a reason for the retention decision.",
      "retention_disposal_requested" => "A controlled-disposal proposal is pending. Cancel or resolve it before creating new final outputs or disclosures.",
      "legal_hold_blocks_disposal" => "A disposal request cannot be recorded while a legal hold is active.",
      "invalid_retention_extension" => "Enter a retention extension between 1 and 3,650 days.",
      "invalid_privacy_request_type" => "Select a supported privacy-request type.",
      "invalid_privacy_request_status" => "Select a supported privacy-request status.",
      "privacy_requester_reference_missing" => "Enter a non-sensitive reference for the person making the privacy request.",
      "privacy_request_decision_missing" => "Enter the decision before closing this privacy request.",
      "privacy_processing_restriction_reason_missing" => "Enter a reason when restricting or resuming case processing for a privacy request.",
      "privacy_processing_restricted" => "Processing for this case is restricted while a privacy request is under review. Final reports, packages, releases and restricted-annex exports are blocked.",
      "restricted_annex_disabled" => "The Restricted Identity Annex is disabled in site settings.",
      "restricted_annex_encryption_not_configured" => "Configure the Restricted Identity Annex key environment variable and non-secret key identifier before creating an annex.",
      "restricted_annex_key_unavailable" => "The encryption key required for this Restricted Identity Annex is not available. Restore the matching key ID in the configured environment keyring.",
      "restricted_annex_necessity_missing" => "Explain why the selected restricted identity fields are necessary for this case.",
      "restricted_annex_empty" => "Select at least one permitted identity field before creating the annex.",
      "invalid_restricted_annex_approval" => "Select either Senior review or Privacy/Legal approval for this annex.",
      "restricted_annex_withdrawn" => "This Restricted Identity Annex has been withdrawn and cannot be approved.",
      "restricted_annex_two_person_approval_required" => "Senior review and Privacy/Legal approval must be recorded by two different accounts.",
      "restricted_annex_approval_already_recorded" => "This Restricted Identity Annex approval has already been recorded.",
      "restricted_annex_not_approved" => "The Restricted Identity Annex requires both Senior and Privacy/Legal approval before export.",
      "restricted_annex_export_passphrase_too_short" => "Use an export passphrase of at least 16 characters.",
      "restricted_annex_recipient_missing" => "Enter a non-sensitive recipient reference for the annex export.",
      "restricted_annex_export_purpose_missing" => "Describe the authorized purpose for the annex export.",
      "restricted_annex_decryption_failed" => "The Restricted Identity Annex could not be decrypted or its integrity check failed. Review the configured key and server logs.",
      "restricted_annex_payload_hash_mismatch" => "The Restricted Identity Annex payload no longer matches its recorded integrity hash.",
      "invalid_restricted_annex_ip" => "Enter a valid IP address for the selected IP event.",
      "restricted_annex_field_necessity_missing" => "Explain why each manually entered restricted event or reference is necessary.",
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
