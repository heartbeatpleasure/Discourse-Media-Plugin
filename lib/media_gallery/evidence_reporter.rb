# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module ::MediaGallery
  module EvidenceReporter
    module_function

    REPORTER_VERSION = "1.3.0"

    def generate!(evidence_case:, user:, final: false)
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      if final
        ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      else
        raise Discourse::InvalidAccess.new unless ::MediaGallery::EvidenceAuthorization.allowed?(user, :technical_reviewer) || ::MediaGallery::EvidenceAuthorization.allowed?(user, :case_operator)
      end
      if !final && evidence_case.reports.where(status: %w[final_unsealed final_sealed]).exists?
        raise ArgumentError, "draft_not_allowed_after_final_report"
      end

      policy = ::MediaGallery::EvidencePolicy.finalization_blockers(evidence_case)
      raise ArgumentError, "evidence_case_not_ready:#{policy[:blockers].map { |blocker| blocker[:code] }.join(',')}" if final && !policy[:ready]

      generated_at = Time.now.utc
      version = evidence_case.reports.maximum(:version).to_i + 1
      report_ref = ::MediaGallery::EvidenceReference.report_ref(case_ref: evidence_case.case_ref, version: version)
      report_data = build_report_data(evidence_case, report_ref: report_ref, generated_at: generated_at, final: final, policy: policy)
      report_data_sha256 = report_data_digest(report_data)
      report_data["verification"]["report_data_sha256"] = report_data_sha256

      rendered_pdf = ::MediaGallery::EvidencePdf.new(
        title: "TECHNICAL EVIDENCE REPORT",
        subtitle: "Case #{evidence_case.case_ref} | Report #{report_ref}",
        status: final ? "FINAL - UNSIGNED / PACKAGE VERIFICATION REQUIRED" : "DRAFT - NOT FINAL",
        generated_at: generated_at,
        sections: report_sections(report_data),
        footer: "#{report_issuer_name(evidence_case)} Forensic Evidence Service | #{evidence_case.case_ref}",
      ).render
      archival = ::MediaGallery::EvidenceArchivalPdf.process(rendered_pdf, final: final)
      pdf = archival[:bytes]
      pdf_sha256 = Digest::SHA256.hexdigest(pdf)
      storage_ref = "#{report_ref}-#{SecureRandom.hex(6)}"
      path = ::MediaGallery::EvidenceVault.report_path(evidence_case.case_ref, storage_ref)
      ::MediaGallery::EvidenceVault.atomic_write!(path, pdf)

      metadata = report_data.deep_dup
      metadata["verification"]["pdf_sha256_external"] = pdf_sha256
      metadata["verification"]["pdf_hash_location_note"] = "The final PDF byte hash is stored outside the PDF to avoid a self-referential hash."
      metadata["verification"]["pdf_processing"] = archival[:metadata]
      report = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        report = ::MediaGallery::ForensicEvidenceReport.create!(
          evidence_case: evidence_case,
          report_ref: report_ref,
          version: version,
          status: final ? "final_unsealed" : "draft",
          file_path: ::MediaGallery::EvidenceVault.relative_path(path),
          pdf_sha256: pdf_sha256,
          report_data_sha256: report_data_sha256,
          size_bytes: pdf.bytesize,
          supersedes: evidence_case.latest_report,
          immutable_at: generated_at,
          created_by: user,
          metadata: metadata,
        )
        evidence_case.update!(status: final ? "approved_for_seal" : evidence_case.status, updated_by: user)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: final ? "final_report_generated" : "draft_report_generated",
          user: user,
          object_ref: report.report_ref,
          details: {
            report_version: version,
            status: report.status,
            report_data_sha256: report.report_data_sha256,
            pdf_sha256: report.pdf_sha256,
            size_bytes: report.size_bytes,
            pdf_profile: archival.dig(:metadata, "pdf_profile"),
            pdfa_validated: archival.dig(:metadata, "validator_compliant") == true,
          },
        )
      end
      ::MediaGallery::EvidenceRetention.apply!(evidence_case: evidence_case.reload, user: user, anchor: generated_at, reason: "Report generation reviewed the case retention class.", force: true) if final
      report
    rescue
      File.chmod(0o640, path) rescue nil if defined?(path) && path.present? && File.file?(path)
      FileUtils.rm_f(path) if defined?(path) && path.present? && (!defined?(report) || report.blank? || !::MediaGallery::ForensicEvidenceReport.where(id: report.id).exists?)
      raise
    end

    def absolute_path(report)
      root = ::MediaGallery::EvidenceVault.ensure_root!
      path = ::MediaGallery::PathSecurity.safe_join!(root, report.file_path.to_s)
      raise Discourse::NotFound unless File.file?(path)
      raise Discourse::NotFound unless ::MediaGallery::PathSecurity.realpath_under?(path, root)
      raise "report_hash_mismatch" unless Digest::SHA256.file(path).hexdigest == report.pdf_sha256

      path
    end

    def build_report_data(evidence_case, report_ref:, generated_at:, final:, policy:)
      snapshot = evidence_case.latest_identify_snapshot
      reviews = evidence_case.reviews.order(:reviewed_at, :id).to_a
      objects = evidence_case.evidence_objects.order(:created_at, :id).to_a
      media = evidence_case.media_snapshot || {}
      external_media = external_media_snapshot(evidence_case, media)
      summary = snapshot.present? ? external_identify_summary(snapshot.summary, evidence_case.case_ref, snapshot_account_ref_map(snapshot)) : {}

      {
        "schema" => "media-gallery-technical-evidence-report-v1.2",
        "reporter_version" => REPORTER_VERSION,
        "case_ref" => evidence_case.case_ref,
        "report_ref" => report_ref,
        "status" => final ? "final_unsealed" : "draft",
        "generated_at_utc" => generated_at.iso8601(6),
        "language" => "en",
        "jurisdiction_profile" => "international_technical_core",
        "issuer" => report_issuer_data(evidence_case),
        "governance" => {
          "profile_ref" => evidence_case.governance_profile_ref,
          "profile_snapshot_sha256" => evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot["profile_sha256"] : nil,
          "profile_fields_included_by_configuration" => ::MediaGallery::EvidenceGovernance.external_profile(evidence_case).keys.sort,
        }.compact,
        "scope" => {
          "research_question" => evidence_case.research_question,
          "claimant_ref" => evidence_case.claimant_ref,
          "rights_statement_ref" => evidence_case.rights_statement_ref,
          "rights_statement_received_at_utc" => evidence_case.rights_statement_received_at&.utc&.iso8601(6),
          "claimant_confirmation_recorded" => evidence_case.claimant_confirmed?,
          "jurisdiction_context" => evidence_case.jurisdiction_context,
          "jurisdiction_notice" => ::MediaGallery::EvidencePolicy.jurisdiction_notice,
        }.compact,
        "external_observation" => {
          "platform" => evidence_case.external_platform,
          "visible_uploader_account" => evidence_case.external_username,
          "source_url" => evidence_case.external_url,
          "source_url_original_sha256" => evidence_case.external_url_sha256,
          "observed_at_utc" => evidence_case.external_observed_at&.utc&.iso8601(6),
          "platform_displayed_time" => evidence_case.external_displayed_at,
          "capture_objects" => objects.select { |o| o.role.start_with?("source_") }.map { |o| evidence_object_summary(o) },
          "automatic_source_fetch" => "disabled",
        }.compact,
        "evidence_files" => objects.select { |o| %w[external_original working_copy].include?(o.role) }.map { |o| evidence_object_summary(o) },
        "media_reference" => external_media,
        "media_reference_integrity" => {
          "exported_snapshot_sha256" => Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(external_media)),
          "exported_snapshot_location" => "04_reference-media/media-item-snapshot.json in the integrity evidence package",
          "internal_snapshot_hash_not_exported" => true,
        },
        "fingerprint_assignment" => snapshot.present? ? {
          "attributed_distribution_account" => display_account(snapshot),
          "attributed_account_ref" => snapshot.attributed_account_ref,
          "fingerprint_id" => snapshot.fingerprint_id,
          "fingerprint_assigned_at_utc" => snapshot.fingerprint_assigned_at&.utc&.iso8601(6),
          "layout" => snapshot.layout,
          "account_snapshot" => external_account_snapshot(snapshot.account_snapshot),
          "fingerprint_snapshot" => external_fingerprint_snapshot(snapshot.fingerprint_snapshot, evidence_case.case_ref),
        }.compact : {},
        "forensic_method" => snapshot.present? ? {
          "run_ref" => snapshot.run_ref,
          "run_kind" => snapshot.run_kind,
          "synthetic_population" => snapshot.synthetic_population?,
          "raw_result_sha256" => snapshot.raw_result_sha256,
          "analysis_settings" => snapshot.analysis_settings,
          "software_snapshot" => snapshot.software_snapshot,
          "sanity_checks" => snapshot.sanity_checks,
        } : {},
        "result" => snapshot.present? ? {
          "decision" => snapshot.decision,
          "conclusive" => snapshot.conclusive?,
          "candidate_population_count" => snapshot.candidate_population_count,
          "summary" => summary,
          "controlled_conclusion" => controlled_conclusion(snapshot),
        } : {
          "decision" => "pending",
          "controlled_conclusion" => "No immutable forensic identify snapshot has been attached to this case.",
        },
        "alternative_hypotheses" => alternative_hypotheses,
        "mandatory_limitation" => mandatory_limitation,
        "review" => {
          "reviews" => reviews.map { |review| review_summary(review) },
          "four_eyes_required" => snapshot&.decision == "conclusive_match",
          "policy_ready_for_finalization" => policy[:ready],
          "blockers" => policy[:blockers],
          "warnings" => policy[:warnings],
        },
        "chain_of_custody" => {
          "event_count" => evidence_case.chain_events.count,
          "chain_verified" => policy.dig(:chain, :ok),
          "latest_event_hash" => evidence_case.chain_events.order(:occurred_at, :id).last&.event_hash,
        },
        "verification" => {
          "report_data_sha256" => nil,
          "report_data_sha256_scope" => "Canonical JSON with verification.report_data_sha256 set to null and external PDF-hash fields omitted",
          "pdf_sha256_location" => "External manifest and report database record",
          "package_status" => "Not yet generated",
          "pdf_profile" => ::MediaGallery::EvidenceArchivalPdf.enabled? ? "PDF/A-2b; local veraPDF validation required" : "PDF 1.4; not certified PDF/A",
        },
      }
    end

    def report_sections(data)
      scope = data["scope"]
      observation = data["external_observation"]
      media = data["media_reference"]
      assignment = data["fingerprint_assignment"]
      method = data["forensic_method"]
      result = data["result"]
      review = data["review"]
      chain = data["chain_of_custody"]
      verification = data["verification"]

      [
        { heading: "1. Report status and issuer", lines: [
          "Case ID: #{data['case_ref']}", "Report ID: #{data['report_ref']}", "Status: #{data['status']}",
          "Issued by: #{data.dig('issuer', 'service')}",
          *(data.dig('issuer', 'operator_identity').present? ? ["Operator identity: #{data.dig('issuer', 'operator_identity')}"] : []),
          "Website: #{data.dig('issuer', 'website')}",
          *(data.dig('issuer', 'generic_contact').present? ? ["Generic contact: #{data.dig('issuer', 'generic_contact')}"] : []),
          *(data.dig('issuer', 'legal_notice_url').present? ? ["Privacy/legal notice: #{data.dig('issuer', 'legal_notice_url')}"] : []),
          *(data.dig('issuer', 'policy_reference').present? ? ["Policy reference: #{data.dig('issuer', 'policy_reference')}"] : []),
          *(data.dig('issuer', 'controller_country').present? ? ["Controller country: #{data.dig('issuer', 'controller_country')}"] : []),
          "Personal staff names: not included", "Report language: English", "Jurisdiction profile: international technical core",
        ] },
        { heading: "2. Assignment and research question", lines: [
          "Research question: #{scope['research_question']}", "Rights claimant reference: #{scope['claimant_ref']}",
          "Rights statement reference: #{scope['rights_statement_ref']}",
          "Rights statement received: #{scope['rights_statement_received_at_utc']}",
          "Claimant confirmation recorded: #{scope['claimant_confirmation_recorded']}",
        ] },
        { heading: "3. External observation", lines: [
          "Platform: #{observation['platform']}", "Visible uploader account: #{observation['visible_uploader_account']}",
          "Source URL (credential-like query values redacted): #{observation['source_url']}",
          "Page observed by the service: #{observation['observed_at_utc']}",
          "Displayed platform time (not independently verified): #{observation['platform_displayed_time']}",
          "Capture object count: #{Array(observation['capture_objects']).length}",
          "Server-side automatic source fetch: disabled",
        ] },
        { heading: "4. Evidence file", lines: evidence_lines(data["evidence_files"]) },
        { heading: "5. Discourse media reference", lines: [
          "Media public ID: #{media['public_id']}", "Media item ID: #{media['media_item_id']}", "Title: #{media['title']}",
          "Media type: #{media['media_type']}", "Content contributor: #{media.dig('content_contributor', 'username')}",
          "Content contributor is not automatically the legal rights holder.",
          "Exported immutable media snapshot SHA-256: #{data.dig('media_reference_integrity', 'exported_snapshot_sha256')}",
        ] },
        { heading: "6. Fingerprint assignment", lines: [
          "Attributed distribution account: #{assignment['attributed_distribution_account']}",
          "Account reference: #{assignment['attributed_account_ref']}", "Fingerprint ID: #{assignment['fingerprint_id']}",
          "Fingerprint assigned at: #{assignment['fingerprint_assigned_at_utc']}", "Layout: #{assignment['layout']}",
        ] },
        { heading: "7. Forensic method", lines: [
          "Run ID: #{method['run_ref']}", "Run kind: #{method['run_kind']}",
          "Synthetic population used: #{method['synthetic_population']}", "Raw result SHA-256: #{method['raw_result_sha256']}",
          "Detector/policy/software: #{::MediaGallery::EvidenceReference.canonical_json(method['software_snapshot'] || {})}",
          "Analysis settings: #{::MediaGallery::EvidenceReference.canonical_json(method['analysis_settings'] || {})}",
        ] },
        { heading: "8. Results", lines: [
          "Decision: #{result['decision']}", "Conclusive under the recorded technical policy: #{result['conclusive']}",
          "Investigated candidate population: #{result['candidate_population_count']}",
          "Top technical score: #{result.dig('summary', 'top_match_score')} (technical comparison score, not probability)",
          "Delta versus second candidate: #{result.dig('summary', 'delta_vs_second')}",
          "Usable/effective samples: #{result.dig('summary', 'usable_samples')}",
          "Chosen offset: #{result.dig('summary', 'chosen_offset_segments')}; phase: #{result.dig('summary', 'phase')}; drift: #{result.dig('summary', 'drift')}",
          "Controlled conclusion: #{result['controlled_conclusion']}",
        ] },
        { heading: "9. Alternative hypotheses", lines: data["alternative_hypotheses"].map { |row| "- #{row}" } },
        { heading: "10. Mandatory limitations", lines: [data["mandatory_limitation"]] },
        { heading: "11. Human review", lines: [
          "Finalization policy ready: #{review['policy_ready_for_finalization']}",
          "Approved/rejected review records: #{Array(review['reviews']).length}",
          *Array(review["reviews"]).map { |row| "#{row['review_kind']}: #{row['outcome']} by #{row['reviewer_role']} (#{row['reviewer_ref']}) at #{row['reviewed_at_utc']}" },
          *Array(review["blockers"]).map { |row| "BLOCKER #{row[:code] || row['code']}: #{row[:message] || row['message']}" },
          *Array(review["warnings"]).map { |row| "WARNING #{row[:code] || row['code']}: #{row[:message] || row['message']}" },
        ] },
        { heading: "12. Chain of custody and verification", lines: [
          "Chain event count: #{chain['event_count']}", "Event hash chain verified: #{chain['chain_verified']}",
          "Latest event hash: #{chain['latest_event_hash']}", "Canonical report-data SHA-256: #{verification['report_data_sha256']}",
          "Final PDF byte SHA-256: stored in the external manifest and report record (not embedded to avoid circular hashing).",
          "PDF profile: #{verification['pdf_profile']}",
        ] },
      ]
    end

    def evidence_lines(objects)
      rows = Array(objects)
      return ["No external evidence file has been attached."] if rows.empty?

      rows.flat_map.with_index do |object, index|
        [
          "Evidence object #{index + 1}: #{object['object_ref']}", "Role: #{object['role']}",
          "Original filename: excluded from external report; SHA-256 #{object['original_filename_sha256']}; extension #{object['original_extension']}", "MIME type: #{object['mime_type']}",
          "Size: #{object['size_bytes']} bytes", "SHA-256: #{object['sha256']}",
          "Quarantine status: #{object['quarantine_status']}",
          "Malware scan: #{object.dig('scan', 'state').presence || 'not recorded'}",
          "Technical inspection: #{object.dig('inspection', 'state').presence || 'not recorded'}",
          "Storage kind: #{object['storage_kind']}",
        ]
      end
    end

    def evidence_object_summary(object)
      original_name = object.original_filename.to_s
      vault_reference = object.vault_reference.to_s
      {
        "object_ref" => object.object_ref,
        "role" => object.role,
        "storage_kind" => object.storage_kind,
        "vault_reference_present" => vault_reference.present?,
        "vault_reference_sha256" => vault_reference.present? ? Digest::SHA256.hexdigest(vault_reference) : nil,
        "original_filename_included" => false,
        "original_filename_sha256" => original_name.present? ? Digest::SHA256.hexdigest(original_name) : nil,
        "original_extension" => File.extname(original_name).downcase.presence,
        "mime_type" => object.mime_type,
        "size_bytes" => object.size_bytes,
        "sha256" => object.sha256,
        "quarantine_status" => object.quarantine_status,
        "scan" => external_scan_metadata(object.respond_to?(:scan_metadata) ? object.scan_metadata : {}),
        "inspection" => external_inspection_metadata(object.respond_to?(:inspection_metadata) ? object.inspection_metadata : {}),
        "immutable_at_utc" => object.immutable_at&.utc&.iso8601(6),
        "metadata" => external_object_metadata(object.metadata),
      }.compact
    end

    def display_account(snapshot)
      return snapshot.attributed_account_ref if snapshot.attributed_username.blank?

      ::MediaGallery::EvidenceReference.pdf_safe_identity(snapshot.attributed_username, fallback_ref: snapshot.attributed_account_ref.presence || "attributed account")
    end

    def controlled_conclusion(snapshot)
      ref = snapshot.attributed_account_ref.presence || "the recorded account reference"
      case snapshot.decision
      when "conclusive_match"
        "The forensic pattern met the predefined technical criteria for a conclusive match with the distribution copy assigned to account reference #{ref}, within the investigated candidate population and using the recorded method and versions."
      when "likely_match"
        "Account reference #{ref} is the leading candidate, but not all predefined criteria for a conclusive technical attribution were met."
      when "ambiguous"
        "Multiple candidates or technical hypotheses remain plausible. No distribution copy is conclusively attributed."
      when "no_match"
        "The available signal is insufficient for reliable attribution, or no candidate meets the recorded policy."
      else
        "No forensic attribution conclusion is available."
      end
    end

    def mandatory_limitation
      "This report identifies only a technically best-matching distribution copy and its linked platform account reference. It does not independently prove which natural person obtained, copied, forwarded or uploaded the file. It provides no legal conclusion about rights, authorization, liability, intent or damages. A username is not a verified legal identity, and technical match scores are not probability percentages."
    end

    def alternative_hypotheses
      [
        "The account or device may have been shared or compromised.",
        "The distribution copy may have been forwarded by an intermediary.",
        "Screen recording, transcoding, scaling, cropping or frame blending may weaken or erase signal.",
        "A relevant fingerprint may be absent from the investigated candidate population.",
        "The file may contain segments derived from multiple sources or distribution copies.",
        "Platform timestamps and visible external usernames are platform-provided claims, not verified natural-person identity.",
        "Absence of historical access events is not evidence that access did not occur when logging was unavailable.",
      ]
    end

    def review_summary(review)
      {
        "review_ref" => review.review_ref,
        "review_kind" => review.review_kind,
        "reviewer_role" => review.reviewer_role,
        "reviewer_ref" => review.reviewer_ref,
        "outcome" => review.outcome,
        "reason_present" => review.reason.to_s.present?,
        "reason_sha256" => review.reason.to_s.present? ? Digest::SHA256.hexdigest(review.reason.to_s) : nil,
        "checklist" => review.checklist,
        "reviewed_at_utc" => review.reviewed_at&.utc&.iso8601(6),
      }.compact
    end

    def report_data_digest(data)
      payload = data.deep_dup
      payload["verification"] ||= {}
      payload["verification"]["report_data_sha256"] = nil
      payload["verification"].delete("pdf_sha256_external")
      payload["verification"].delete("pdf_hash_location_note")
      payload["verification"].delete("pdf_processing")
      Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload))
    end

    def external_media_snapshot(evidence_case, media)
      snapshot = media.deep_dup
      contributor = snapshot["content_contributor"]
      if contributor.is_a?(Hash)
        user_id = contributor.delete("user_id")
        stored_ref = contributor["account_ref"].to_s
        if user_id.to_i.positive?
          contributor["account_ref"] = stored_ref.presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: evidence_case.case_ref, user_id: user_id)
        end
      end
      %w[original_upload processed_upload].each do |key|
        upload = snapshot[key]
        next unless upload.is_a?(Hash)

        upload.delete("upload_id")
        filename = upload.delete("original_filename").to_s
        upload["original_filename_included"] = false
        upload["original_filename_sha256"] = Digest::SHA256.hexdigest(filename) if filename.present?
        extension = File.extname(filename).downcase
        upload["original_extension"] = extension if extension.match?(/\A\.[a-z0-9]{1,12}\z/)
      end
      snapshot
    end

    def external_identify_summary(summary, case_ref, account_ref_map = {})
      privacy_minimize_identify_data(summary.is_a?(Hash) ? summary : {}, case_ref, account_ref_map)
    end

    def privacy_minimize_identify_data(value, case_ref, account_ref_map = {})
      case value
      when Hash
        source = value.deep_stringify_keys
        user_shaped = source.key?("user_id") || source.key?("internal_user_id") || source.key?("assigned_user_id") || source.key?("username")
        user_id = source["user_id"] || source["internal_user_id"] || source["assigned_user_id"] || (user_shaped ? source["id"] : nil)
        output = {}
        source.each do |key, child|
          next if sensitive_identity_key?(key, user_shaped: user_shaped)

          output[key] = privacy_minimize_identify_data(child, case_ref, account_ref_map)
        end
        output["account_ref"] = account_ref_map[user_id.to_s].presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id) if user_id.to_i.positive?
        output
      when Array
        value.map { |child| privacy_minimize_identify_data(child, case_ref, account_ref_map) }
      else
        value
      end
    end

    def sensitive_identity_key?(key, user_shaped: false)
      name = key.to_s
      return true if user_shaped && %w[id name display_name login user user_id internal_user_id assigned_user_id username].include?(name)
      return true if name.match?(/(?:^|_)(?:user_id|internal_user_id|assigned_user_id|username|user_name|email|e_mail|ip|ip_address|registration_ip|last_ip)$/i)
      return true if name.match?(/(?:email|e_mail|ip_address|registration_ip|last_ip|username|user_name|authorization|cookie|session_token|access_token|refresh_token|api_key|client_secret)/i)

      false
    end

    def snapshot_account_ref_map(snapshot)
      value = snapshot.account_snapshot.is_a?(Hash) ? snapshot.account_snapshot["candidate_account_refs_by_user_id"] : nil
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def external_account_snapshot(snapshot)
      value = snapshot.is_a?(Hash) ? snapshot.deep_dup : {}
      value.delete("internal_user_id")
      value.delete("candidate_account_refs_by_user_id")
      value
    end

    def external_fingerprint_snapshot(snapshot, case_ref)
      value = snapshot.is_a?(Hash) ? snapshot.deep_dup : {}
      user_id = value.delete("assigned_user_id")
      stored_ref = value["assigned_account_ref"].to_s
      value.delete("fingerprint_record_id")
      value.delete("media_item_id")
      value["assigned_account_ref"] = stored_ref.presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id) if user_id.to_i.positive?
      value
    end

    def external_scan_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      value.slice(
        "provider", "state", "complete", "signature", "scanned_at_utc", "started_at_utc",
        "completed_at_utc", "duration_ms", "size_bytes", "scan_limit_bytes", "version",
        "manual_review_at_utc", "manual_review_reason_sha256"
      ).compact
    end

    def external_inspection_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      value.slice(
        "state", "inspected_at_utc", "declared_mime_type", "detected_file_type", "extension",
        "media_type", "ffprobe", "message", "warnings"
      ).compact
    end

    def external_object_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata : {}
      allowed = value.slice("source", "production_evidence_eligible", "acquisition_method")
      description = value["staff_description"].to_s
      allowed["staff_description_present"] = description.present?
      allowed["staff_description_sha256"] = Digest::SHA256.hexdigest(description) if description.present?
      allowed
    end

    def report_issuer_data(evidence_case)
      profile = ::MediaGallery::EvidenceGovernance.external_profile(evidence_case)
      issuer = profile["issuer_display_name"].to_s.presence || ::MediaGallery::EvidencePolicy.issuer_name.presence || "Media Library"
      {
        "service" => "#{issuer} Forensic Evidence Service",
        "operator_identity" => profile["operator_display_name"],
        "website" => profile["website_url"] || ::MediaGallery::EvidenceGovernance.site_base_url,
        "generic_contact" => profile["generic_contact"],
        "legal_notice_url" => profile["privacy_legal_notice_url"],
        "policy_reference" => profile["policy_reference"],
        "controller_country" => profile["controller_country"],
        "personal_staff_names_included" => false,
      }.compact
    end

    def report_issuer_name(evidence_case)
      profile = evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot : {}
      profile["issuer_display_name"].to_s.presence || ::MediaGallery::EvidencePolicy.issuer_name.presence || "Media Library"
    end
    private_class_method :build_report_data, :report_sections, :evidence_lines, :evidence_object_summary,
                         :display_account, :controlled_conclusion, :mandatory_limitation,
                         :alternative_hypotheses, :review_summary, :report_data_digest,
                         :external_media_snapshot, :external_identify_summary, :privacy_minimize_identify_data, :sensitive_identity_key?,
                         :snapshot_account_ref_map, :external_account_snapshot, :external_fingerprint_snapshot,
                         :external_scan_metadata, :external_inspection_metadata, :external_object_metadata, :report_issuer_data, :report_issuer_name
  end
end
