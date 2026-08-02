# frozen_string_literal: true

module ::MediaGallery
  module EvidencePolicy
    module_function

    REQUIRED_REVIEW_CHECKS = %w[
      acquisition_reviewed hashes_verified raw_json_reviewed decision_language_reviewed
      alternatives_reviewed privacy_reviewed
    ].freeze

    def enabled?
      base_enabled = SiteSetting.respond_to?(:media_gallery_enabled) && SiteSetting.media_gallery_enabled
      evidence_enabled = SiteSetting.respond_to?(:media_gallery_evidence_enabled) && SiteSetting.media_gallery_evidence_enabled
      base_enabled && evidence_enabled
    rescue
      false
    end

    def normalize_decision(raw_result)
      meta = raw_result.is_a?(Hash) ? (raw_result["meta"] || raw_result[:meta] || {}) : {}
      decision = (meta["decision"] || meta[:decision]).to_s.downcase.strip.tr(" -", "_")
      conclusive = ActiveModel::Type::Boolean.new.cast(meta["conclusive"] || meta[:conclusive])

      # Fail closed for negative/non-conclusive wording before evaluating positive tokens. In
      # particular, "inconclusive" contains the substring "conclusive" and must never be
      # normalized to a conclusive evidence decision.
      return "no_match" if decision.match?(/(?:\Ano_match\z|\Ano_signal\z|insufficient)/)
      return "ambiguous" if decision.match?(/(?:ambiguous|timeout|error|weak|inconclusive|non_?conclusive|not_?conclusive)/)
      return "conclusive_match" if conclusive || %w[conclusive conclusive_match strong_match].include?(decision)
      return "likely_match" if decision.match?(/(?:\Alikely\z|\Alikely_match\z)/)

      Array(raw_result.is_a?(Hash) ? (raw_result["candidates"] || raw_result[:candidates]) : nil).any? ? "ambiguous" : "no_match"
    end

    def synthetic_result?(raw_result)
      return false unless raw_result.is_a?(Hash)

      meta = raw_result["meta"] || raw_result[:meta] || {}
      return true if ActiveModel::Type::Boolean.new.cast(meta["synthetic_population_test_enabled"] || meta[:synthetic_population_test_enabled])
      return true if ActiveModel::Type::Boolean.new.cast(meta["synthetic_population_applied"] || meta[:synthetic_population_applied])

      Array(raw_result["candidates"] || raw_result[:candidates]).any? do |candidate|
        ActiveModel::Type::Boolean.new.cast(candidate.is_a?(Hash) ? (candidate["synthetic"] || candidate[:synthetic]) : false)
      end
    end

    def finalization_blockers(evidence_case)
      blockers = []
      warnings = []
      snapshot = evidence_case.latest_identify_snapshot
      objects = evidence_case.evidence_objects.to_a

      add_blocker(blockers, "evidence_module_disabled", "The evidence module is disabled in site settings.") unless enabled?
      add_blocker(blockers, "issuer_name_missing", "Configure a non-personal evidence issuer name.") if issuer_name.blank?
      add_blocker(blockers, "operator_identity_missing", "Configure the website/operator legal identity or legal-notice identity.") if operator_identity.blank?
      case_key_id = evidence_case.metadata.is_a?(Hash) ? evidence_case.metadata["pseudonymization_key_id"].to_s : ""
      current_key_id = ::MediaGallery::EvidenceReference.reviewer_secret_key_id
      add_blocker(blockers, "pseudonymization_key_id_missing", "The case does not record the pseudonymization-key identifier required for stable reviewer/account references.") if case_key_id.blank?
      if case_key_id.present? && case_key_id != current_key_id
        add_blocker(blockers, "pseudonymization_key_changed", "The pseudonymization secret differs from the one used when this case was created. Restore the original secret or complete an explicitly reviewed migration before generating final evidence.")
      end
      add_blocker(blockers, "media_snapshot_missing", "A frozen media-item snapshot is required.") if evidence_case.media_snapshot.blank?
      add_blocker(blockers, "rights_statement_missing", "Record receipt of a rights claimant statement.") if evidence_case.rights_statement_received_at.blank?
      add_blocker(blockers, "rights_statement_reference_missing", "Record an immutable reference for the received rights claimant statement.") if evidence_case.rights_statement_ref.blank?
      add_blocker(blockers, "claimant_confirmation_missing", "The claimant confirmation must be recorded before finalization.") unless evidence_case.claimant_confirmed?
      add_blocker(blockers, "external_observation_time_missing", "Record when staff observed the external source in UTC.") if evidence_case.external_observed_at.blank?

      source_capture_present = evidence_case.external_url.present? || objects.any? { |o| %w[source_screenshot source_html source_warc source_headers].include?(o.role) }
      add_blocker(blockers, "source_capture_missing", "Record the external URL or add a source-capture object.") unless source_capture_present

      evidence_files = objects.select { |o| %w[external_original working_copy].include?(o.role) }
      add_blocker(blockers, "external_evidence_missing", "Add the acquired external evidence file or a verifiable vault reference.") if evidence_files.empty?

      rejected = objects.select { |o| %w[rejected infected].include?(o.quarantine_status) }
      add_blocker(blockers, "rejected_evidence_present", "One or more evidence objects were rejected or malware was detected during quarantine review.", object_refs: rejected.map(&:object_ref)) if rejected.any?

      if require_clean_quarantine?
        quarantine_scope = objects.select do |object|
          ::MediaGallery::EvidenceAcquisition.scan_required?(object) ||
            (object.storage_kind == "vault_reference" && %w[external_original working_copy].include?(object.role))
        end
        pending = quarantine_scope.select { |object| object.quarantine_status != "clean" }
        add_blocker(
          blockers,
          "quarantine_review_incomplete",
          "Required evidence objects must have a clean automatic scan or documented manual quarantine review.",
          object_refs: pending.map(&:object_ref),
          statuses: pending.to_h { |object| [object.object_ref, object.quarantine_status] },
        ) if pending.any?
      end

      if ::MediaGallery::EvidenceInspector.enabled?
        invalid_role_objects = objects.select do |object|
          object.storage_kind == "file" && object.respond_to?(:inspection_metadata) &&
            object.inspection_metadata.is_a?(Hash) && object.inspection_metadata["state"].to_s == "invalid"
        end
        add_blocker(
          blockers,
          "evidence_role_validation_failed",
          "One or more evidence files do not match the selected evidence role.",
          object_refs: invalid_role_objects.map(&:object_ref),
        ) if invalid_role_objects.any?

        inspection_incomplete = evidence_files.select do |object|
          next false unless object.storage_kind == "file"

          state = object.respond_to?(:inspection_metadata) && object.inspection_metadata.is_a?(Hash) ? object.inspection_metadata["state"].to_s : ""
          !%w[valid warning].include?(state)
        end
        add_blocker(
          blockers,
          "evidence_inspection_incomplete",
          "Primary external evidence must pass bounded technical media inspection before finalization.",
          object_refs: inspection_incomplete.map(&:object_ref),
        ) if inspection_incomplete.any?
      end

      if snapshot.blank?
        add_blocker(blockers, "identify_snapshot_missing", "Attach an immutable production identify snapshot.")
      else
        add_blocker(blockers, "diagnostic_run_not_evidence", "A synthetic/diagnostic identify run cannot support a final attribution report.") unless snapshot.run_kind == "production"
        add_blocker(blockers, "synthetic_population_present", "Synthetic candidates must not be mixed into a production evidence run.") if snapshot.synthetic_population?
        critical_checks = Array(snapshot.sanity_checks).select { |check| check.is_a?(Hash) && (check["status"] || check[:status]).to_s == "critical" }
        add_blocker(blockers, "identify_sanity_checks_failed", "The identify snapshot contains critical sanity-check failures.", checks: critical_checks) if critical_checks.any?

        if %w[conclusive_match likely_match].include?(snapshot.decision)
          add_blocker(blockers, "attributed_account_missing", "The attributed distribution account snapshot is incomplete.") if snapshot.attributed_account_ref.blank?
          add_blocker(blockers, "fingerprint_assignment_missing", "The fingerprint assignment snapshot is incomplete.") if snapshot.fingerprint_id.blank? || snapshot.fingerprint_assigned_at.blank?
          if evidence_case.external_observed_at.present? && snapshot.fingerprint_assigned_at.present? && snapshot.fingerprint_assigned_at > evidence_case.external_observed_at
            add_blocker(blockers, "assignment_after_observation", "The recorded fingerprint assignment post-dates the external observation and cannot be represented as historical assignment evidence.")
          end
        end
      end

      chain = ::MediaGallery::EvidenceChain.verify(evidence_case)
      add_blocker(blockers, "chain_of_custody_invalid", "The append-only evidence event hash chain did not verify.", errors: chain[:errors]) unless chain[:ok]

      review_state = review_state(evidence_case)
      if snapshot.present?
        approved = review_state[:approved_after_material_change]
        technical = approved.select { |review| review.review_kind == "technical" && review.reviewer_role == "staff_reviewer" }
        senior = approved.select { |review| review.review_kind == "senior" && review.reviewer_role == "senior_staff_reviewer" }

        add_blocker(blockers, "technical_review_missing", "An approved Staff Reviewer checklist after the latest material case change is required.") if technical.empty?

        if snapshot.decision == "conclusive_match"
          add_blocker(blockers, "senior_review_missing", "A conclusive report requires an approved Senior Staff Reviewer after the latest material case change.") if senior.empty?
          distinct_reviewers = (technical + senior).map(&:reviewer_user_id).uniq
          add_blocker(blockers, "four_eyes_review_missing", "A conclusive report requires a Staff Reviewer and a different Senior Staff Reviewer.") if distinct_reviewers.length < 2
        end

        if evidence_case.classification == "restricted"
          add_blocker(blockers, "privacy_review_missing", "Restricted cases require a Privacy/Legal approval after the latest material case change.") unless approved.any? { |review| review.review_kind == "privacy" && review.reviewer_role == "privacy_legal_approver" }
        end

        if review_state[:current_rejections].any?
          add_blocker(
            blockers,
            "current_review_rejected",
            "One or more current review tracks are rejected and must be replaced by a later approval of the same review kind.",
            review_kinds: review_state[:current_rejections].map(&:review_kind).uniq.sort,
          )
        end
      end

      warnings << issue("jurisdiction_specific_legal_review_required", "This is a jurisdiction-neutral technical report. Admissibility, disclosure and legal conclusions require review for the recipient jurisdiction.")
      warnings << issue("external_platform_missing", "The external platform name is not recorded; describe this limitation in the report review.") if evidence_case.external_platform.blank?
      warnings << issue("pdf_not_pdfa", "The built-in generator creates a deterministic PDF 1.4 report, not a certified PDF/A file.")
      warnings << issue("trusted_timestamp_not_configured", "No trusted timestamp is included in this release.")
      if seal_mode == "cms_detached"
        warnings << issue("cms_certificate_trust_external", "A CMS signature verifies manifest integrity against the embedded certificate only. Certificate-chain trust must be established independently by the recipient.")
        warnings << issue("cms_seal_not_configured", "CMS signing is selected but the private key and certificate are not fully configured; package generation will be blocked.") unless cms_seal_configured?
      end
      warnings << issue("restricted_annex_not_implemented", "Sensitive identity disclosure is intentionally excluded; the restricted identity annex is not implemented in this release.")
      warnings << issue("automatic_source_fetch_disabled", "External pages are not fetched server-side; source capture must be uploaded or referenced by staff.")
      unless ::MediaGallery::EvidenceScanner.enabled?
        warnings << issue("automatic_malware_scanner_disabled", "Automatic malware scanning is disabled; clean status depends on a documented manual quarantine review.")
      end
      warnings << issue("retention_due_advisory_only", "The retention due date is an administrative review reminder; this release does not automatically delete evidence cases.")

      {
        ready: blockers.empty?,
        blockers: blockers,
        warnings: warnings,
        chain: chain,
        review_state: serialized_review_state(review_state),
      }
    end

    def review_state(evidence_case)
      material_cutoff = ::MediaGallery::EvidenceChain.latest_material_event_at(evidence_case)
      rows = evidence_case.reviews.order(:reviewed_at, :id).to_a
      current_rows = rows.select { |review| review.reviewed_at >= material_cutoff }
      latest_by_kind = current_rows.group_by(&:review_kind).transform_values do |kind_rows|
        kind_rows.max_by { |review| [review.reviewed_at, review.id.to_i] }
      end
      latest_reviews = latest_by_kind.values.compact
      approved = latest_reviews.select do |review|
        review.outcome == "approved" && approved_checklist?(normalize_checklist(review.checklist))
      end
      {
        material_cutoff_at: material_cutoff,
        approved_after_material_change: approved,
        latest_reviews_by_kind: latest_by_kind,
        current_rejections: latest_reviews.select { |review| review.outcome == "rejected" },
        latest_approval: approved.max_by { |review| [review.reviewed_at, review.id.to_i] },
        latest_rejection: latest_reviews.select { |review| review.outcome == "rejected" }.max_by { |review| [review.reviewed_at, review.id.to_i] },
      }
    end

    def normalize_checklist(value)
      source = value.is_a?(Hash) ? value : {}
      REQUIRED_REVIEW_CHECKS.index_with do |key|
        ActiveModel::Type::Boolean.new.cast(source[key] || source[key.to_sym])
      end
    end

    def approved_checklist?(checklist)
      REQUIRED_REVIEW_CHECKS.all? { |key| checklist[key] == true }
    end

    def issuer_name
      value = SiteSetting.respond_to?(:media_gallery_evidence_issuer_name) ? SiteSetting.media_gallery_evidence_issuer_name.to_s.strip : ""
      value.presence || (SiteSetting.respond_to?(:title) ? SiteSetting.title.to_s.strip : "")
    rescue
      ""
    end

    def operator_identity
      SiteSetting.respond_to?(:media_gallery_evidence_operator_identity) ? SiteSetting.media_gallery_evidence_operator_identity.to_s.strip : ""
    rescue
      ""
    end

    def legal_notice_url
      SiteSetting.respond_to?(:media_gallery_evidence_legal_notice_url) ? SiteSetting.media_gallery_evidence_legal_notice_url.to_s.strip : ""
    rescue
      ""
    end

    def jurisdiction_notice
      configured = SiteSetting.respond_to?(:media_gallery_evidence_jurisdiction_notice) ? SiteSetting.media_gallery_evidence_jurisdiction_notice.to_s.strip : ""
      configured.presence || "This report is a jurisdiction-neutral technical record. It does not state that the material is admissible or legally sufficient in any particular country or court."
    rescue
      "This report is a jurisdiction-neutral technical record."
    end

    def require_clean_quarantine?
      return true unless SiteSetting.respond_to?(:media_gallery_evidence_require_clean_quarantine_for_final)

      SiteSetting.media_gallery_evidence_require_clean_quarantine_for_final
    rescue
      true
    end

    def seal_mode
      value = SiteSetting.respond_to?(:media_gallery_evidence_seal_mode) ? SiteSetting.media_gallery_evidence_seal_mode.to_s : "integrity_only"
      %w[integrity_only cms_detached].include?(value) ? value : "integrity_only"
    rescue
      "integrity_only"
    end

    def cms_seal_configured?
      return false unless seal_mode == "cms_detached"

      key_path = SiteSetting.respond_to?(:media_gallery_evidence_seal_private_key_path) ? SiteSetting.media_gallery_evidence_seal_private_key_path.to_s.strip : ""
      cert_path = SiteSetting.respond_to?(:media_gallery_evidence_seal_certificate_path) ? SiteSetting.media_gallery_evidence_seal_certificate_path.to_s.strip : ""
      key_path.present? && cert_path.present? && File.file?(key_path) && File.file?(cert_path)
    rescue
      false
    end

    def issue(code, message, **details)
      { code: code, message: message }.merge(details)
    end
    private_class_method :issue

    def add_blocker(collection, code, message, **details)
      collection << issue(code, message, **details)
    end
    private_class_method :add_blocker

    def serialized_review_state(state)
      {
        material_cutoff_at_utc: state[:material_cutoff_at]&.utc&.iso8601(6),
        approved_after_material_change: state[:approved_after_material_change].map do |review|
          {
            review_ref: review.review_ref,
            review_kind: review.review_kind,
            reviewer_role: review.reviewer_role,
            reviewer_ref: review.reviewer_ref,
            reviewed_at_utc: review.reviewed_at&.utc&.iso8601(6),
          }
        end,
        current_reviews_by_kind: state[:latest_reviews_by_kind].transform_values do |review|
          next nil if review.blank?

          {
            review_ref: review.review_ref,
            outcome: review.outcome,
            reviewer_role: review.reviewer_role,
            reviewer_ref: review.reviewer_ref,
            reviewed_at_utc: review.reviewed_at&.utc&.iso8601(6),
          }
        end.compact,
        current_rejected_kinds: state[:current_rejections].map(&:review_kind).uniq.sort,
        latest_approval_ref: state[:latest_approval]&.review_ref,
        latest_rejection_ref: state[:latest_rejection]&.review_ref,
      }
    end
    private_class_method :serialized_review_state
  end
end
