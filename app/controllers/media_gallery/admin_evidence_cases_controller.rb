# frozen_string_literal: true

require "digest"

module ::MediaGallery
  class AdminEvidenceCasesController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    MEDIA_GALLERY_ADMIN_PAGE_KEY = :evidence_cases
    include ::MediaGallery::AdminAccess::ControllerMethods

    before_action :ensure_evidence_enabled
    before_action :no_store_headers!
    before_action :ensure_case_operator!, only: %i[create from_identify update upload_object add_vault_reference quarantine rescan_object attach_identify confirm_claimant]
    before_action :ensure_senior_reviewer!, only: %i[create_package legal_hold review_legal_hold verify_package create_release revoke_release download_release_receipt lifecycle download_package]
    before_action :ensure_policy_administrator!, only: %i[capture_governance retention_review create_privacy_request update_privacy_request]

    def index
      scope = ::MediaGallery::ForensicEvidenceCase.includes(:supersedes_case, :superseded_by_case).order(created_at: :desc, id: :desc)
      scope = scope.where(status: params[:status].to_s) if ::MediaGallery::ForensicEvidenceCase::STATUSES.include?(params[:status].to_s)
      scope = scope.where(decision: params[:decision].to_s) if ::MediaGallery::ForensicEvidenceCase::DECISIONS.include?(params[:decision].to_s)
      query = params[:q].to_s.strip
      if query.present?
        escaped = ActiveRecord::Base.sanitize_sql_like(query)
        scope = scope.where("case_ref ILIKE :q OR claimant_ref ILIKE :q OR external_platform ILIKE :q", q: "%#{escaped}%")
      end
      limit = [[params[:limit].to_i, 1].max, 100].min
      limit = 50 if params[:limit].to_i <= 0
      rows = scope.limit(limit).to_a

      selected = nil
      selected_error = nil
      if params[:case_ref].present?
        begin
          selected = case_payload(find_case!)
        rescue => e
          selected_error = ::MediaGallery::EvidenceErrors.payload(e)
          log_evidence_error(e, context: "index_selected_case")
        end
      end

      render_json_dump(
        ok: true,
        cases: rows.map { |evidence_case| case_summary(evidence_case) },
        selected: selected,
        selected_error: selected_error,
        config: config_payload,
      )
    rescue => e
      render_evidence_error(e)
    end

    def show
      render_json_dump(ok: true, case: case_payload(find_case!), config: config_payload)
    rescue => e
      render_evidence_error(e)
    end

    def create
      evidence_case = ::MediaGallery::EvidenceSnapshot.create_case!(
        user: current_user,
        public_id: params[:media_public_id],
        claimant_ref: params[:claimant_ref],
        research_question: params[:research_question],
        classification: params[:classification],
        jurisdiction_context: params[:jurisdiction_context],
        external_url: params[:external_url],
        external_platform: params[:external_platform],
        external_username: params[:external_username],
        external_observed_at: params[:external_observed_at],
        external_displayed_at: params[:external_displayed_at],
        rights_statement_received_at: params[:rights_statement_received_at],
        rights_statement_ref: params[:rights_statement_ref],
      )
      render_json_dump(ok: true, case: case_payload(evidence_case))
    rescue => e
      render_evidence_error(e)
    end

    def from_identify
      public_id = identify_public_id
      evidence_case = nil
      snapshot = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case = ::MediaGallery::EvidenceSnapshot.create_case!(
          user: current_user,
          public_id: public_id,
          claimant_ref: params[:claimant_ref].presence || "PENDING-CLAIMANT",
          research_question: params[:research_question].presence || default_research_question(public_id),
          classification: params[:classification],
          jurisdiction_context: params[:jurisdiction_context],
        )
        snapshot = ::MediaGallery::EvidenceSnapshot.attach_identify!(
          evidence_case: evidence_case,
          raw_result: params[:result] || params[:raw_result],
          user: current_user,
          public_id: public_id,
        )
      end
      render_json_dump(ok: true, case: case_payload(evidence_case), identify_snapshot: identify_payload(snapshot))
    rescue => e
      render_evidence_error(e)
    end

    def update
      evidence_case = find_case!
      ::MediaGallery::EvidenceSnapshot.update_case!(evidence_case: evidence_case, user: current_user, attributes: params.permit(
        :claimant_ref, :research_question, :classification, :jurisdiction_context, :external_url,
        :external_platform, :external_username, :external_observed_at, :external_displayed_at,
        :rights_statement_received_at, :rights_statement_ref,
      ))
      render_json_dump(ok: true, case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def upload_object
      evidence_case = find_case!
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      role = params[:role].to_s
      object = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        object = ::MediaGallery::EvidenceVault.store_upload!(
          evidence_case: evidence_case,
          upload: params[:file],
          role: role,
          user: current_user,
          parent: params[:parent_object_ref].present? ? evidence_case.evidence_objects.find_by!(object_ref: params[:parent_object_ref]) : nil,
          metadata: { "staff_description" => plain_text(params[:description], 1000), "acquisition_method" => plain_text(params[:acquisition_method], 500) }.compact,
          include_in_package: params.key?(:include_in_package) ? ActiveModel::Type::Boolean.new.cast(params[:include_in_package]) : nil,
        )
        after_object_added!(evidence_case, object)
      end
      ::MediaGallery::EvidenceAcquisition.enqueue!(object, requested_by_id: current_user.id)
      render_json_dump(ok: true, object: evidence_object_payload(object.reload), case: case_payload(evidence_case.reload))
    rescue => e
      ::MediaGallery::EvidenceVault.discard_uncommitted_file!(object) if defined?(object) && object.present?
      render_evidence_error(e)
    end

    def add_vault_reference
      evidence_case = find_case!
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      object = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        object = ::MediaGallery::EvidenceVault.register_vault_reference!(
          evidence_case: evidence_case,
          vault_reference: params[:vault_reference],
          sha256: params[:sha256],
          size_bytes: params[:size_bytes],
          role: params[:role],
          user: current_user,
          mime_type: params[:mime_type],
          original_filename: params[:original_filename],
          metadata: { "staff_description" => plain_text(params[:description], 1000) }.compact,
        )
        after_object_added!(evidence_case, object)
      end
      render_json_dump(ok: true, object: evidence_object_payload(object), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def quarantine
      evidence_case = find_case!
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      object = evidence_case.evidence_objects.find_by!(object_ref: params[:object_ref].to_s)
      status = params[:quarantine_status].to_s
      raise ArgumentError, "invalid_quarantine_status" unless %w[pending clean rejected].include?(status)
      previous = object.quarantine_status
      raise ArgumentError, "infected_evidence_cannot_be_marked_clean" if previous == "infected" && status == "clean"
      reason = plain_text(params[:reason], 1000)
      raise ArgumentError, "quarantine_reason_required" if reason.blank?
      scan_metadata = object.scan_metadata.is_a?(Hash) ? object.scan_metadata.deep_dup.deep_stringify_keys : {}
      previous_scan_state = scan_metadata["state"].to_s
      if previous_scan_state.present? && !previous_scan_state.start_with?("manual_")
        scan_metadata["automatic_state_before_manual_review"] = previous_scan_state
      end
      scan_metadata.merge!(
        "provider" => "manual_review",
        "state" => status == "clean" ? "manual_clean" : (status == "rejected" ? "manual_rejected" : "manual_pending"),
        "manual_review_at_utc" => Time.now.utc.iso8601(6),
        "manual_review_reason_sha256" => Digest::SHA256.hexdigest(reason),
      )
      ::MediaGallery::ForensicEvidenceCase.transaction do
        object.update!(quarantine_status: status, scan_metadata: scan_metadata)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "evidence_quarantine_reviewed",
          user: current_user,
          object_ref: object.object_ref,
          reason: reason,
          details: { previous_status: previous, quarantine_status: status, scan_state: scan_metadata["state"] },
        )
      end
      if status == "clean" && object.storage_kind == "file"
        ::MediaGallery::EvidenceAcquisition.enqueue!(
          object.reload,
          requested_by_id: current_user.id,
          force: true,
          inspection_only: true,
        )
      end
      render_json_dump(ok: true, object: evidence_object_payload(object.reload), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def rescan_object
      evidence_case = find_case!
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      object = evidence_case.evidence_objects.find_by!(object_ref: params[:object_ref].to_s)
      raise ArgumentError, "evidence_object_not_file_backed" unless object.storage_kind == "file"
      queued = ::MediaGallery::EvidenceAcquisition.enqueue!(object, requested_by_id: current_user.id, force: true)
      raise ArgumentError, "evidence_scan_queue_failed" unless queued

      render_json_dump(ok: true, object: evidence_object_payload(object.reload), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def attach_identify
      evidence_case = find_case!
      snapshot = ::MediaGallery::EvidenceSnapshot.attach_identify!(
        evidence_case: evidence_case,
        raw_result: params[:result] || params[:raw_result],
        user: current_user,
        public_id: params[:media_public_id],
      )
      render_json_dump(ok: true, identify_snapshot: identify_payload(snapshot), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def review
      evidence_case = find_case!
      review = ::MediaGallery::EvidenceReview.record!(
        evidence_case: evidence_case,
        user: current_user,
        review_kind: params[:review_kind],
        outcome: params[:outcome],
        checklist: params[:checklist].respond_to?(:to_unsafe_h) ? params[:checklist].to_unsafe_h : params[:checklist],
        reason: params[:reason],
      )
      render_json_dump(ok: true, review: review_payload(review), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def confirm_claimant
      evidence_case = find_case!
      ::MediaGallery::EvidenceSnapshot.confirm_claimant!(evidence_case: evidence_case, user: current_user, reason: params[:reason])
      render_json_dump(ok: true, case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def generate_report
      evidence_case = find_case!
      report = ::MediaGallery::EvidenceReporter.generate!(
        evidence_case: evidence_case,
        user: current_user,
        final: ActiveModel::Type::Boolean.new.cast(params[:final]),
      )
      render_json_dump(ok: true, report: report_payload(report), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def create_package
      evidence_case = find_case!
      report = if params[:report_ref].present?
        evidence_case.reports.find_by!(report_ref: params[:report_ref].to_s)
      else
        evidence_case.reports.where(status: %w[final_unsealed final_sealed]).order(version: :desc).first
      end
      raise ArgumentError, "final_report_missing" if report.blank?
      package = ::MediaGallery::EvidencePackage.create!(evidence_case: evidence_case, report: report, user: current_user)
      render_json_dump(ok: true, package: package_payload(package), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def legal_hold
      evidence_case = find_case!
      hold = ::MediaGallery::EvidenceReview.set_legal_hold!(
        evidence_case: evidence_case,
        user: current_user,
        active: params[:active],
        reason: params[:reason],
        authority_ref: params[:authority_ref],
      )
      render_json_dump(ok: true, legal_hold: legal_hold_payload(hold), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def review_legal_hold
      evidence_case = find_case!
      hold = ::MediaGallery::EvidenceReview.review_legal_hold!(
        evidence_case: evidence_case,
        user: current_user,
        reason: params[:reason],
        authority_ref: params[:authority_ref],
      )
      render_json_dump(ok: true, legal_hold: legal_hold_payload(hold), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def verify_package
      evidence_case = find_case!
      package = evidence_case.packages.find_by!(package_ref: params[:package_ref].to_s)
      render_json_dump(ok: true, verification: ::MediaGallery::EvidencePackage.verify(package), package: package_payload(package))
    rescue => e
      render_evidence_error(e)
    end

    def create_release
      evidence_case = find_case!
      package = if params[:package_ref].present?
        evidence_case.packages.find_by!(package_ref: params[:package_ref].to_s)
      else
        evidence_case.latest_package
      end
      raise ArgumentError, "evidence_package_missing" if package.blank?

      result = ::MediaGallery::EvidenceRelease.create!(
        evidence_case: evidence_case,
        package: package,
        user: current_user,
        recipient_ref: params[:recipient_ref],
        purpose: params[:purpose],
        expires_in_hours: params[:expires_in_hours],
        max_downloads: params[:max_downloads],
      )
      disclosure = result[:disclosure]
      render_json_dump(
        ok: true,
        disclosure: disclosure_payload(disclosure),
        release_url: ::MediaGallery::EvidenceRelease.public_url(disclosure, result[:token]),
        release_url_shown_once: true,
        case: case_payload(evidence_case.reload),
      )
    rescue => e
      render_evidence_error(e)
    end

    def revoke_release
      evidence_case = find_case!
      disclosure = evidence_case.disclosures.find_by!(disclosure_ref: params[:disclosure_ref].to_s)
      ::MediaGallery::EvidenceRelease.revoke!(
        disclosure: disclosure,
        user: current_user,
        reason: params[:reason],
      )
      render_json_dump(ok: true, disclosure: disclosure_payload(disclosure.reload), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def download_release_receipt
      evidence_case = find_case!
      disclosure = evidence_case.disclosures.find_by!(disclosure_ref: params[:disclosure_ref].to_s)
      receipt = ::MediaGallery::EvidenceRelease.receipt(disclosure)
      no_store_headers!
      send_data(
        JSON.pretty_generate(receipt) + "\n",
        filename: "#{disclosure.disclosure_ref}-release-receipt.json",
        type: "application/json",
        disposition: "attachment",
      )
    rescue => e
      render_evidence_error(e)
    end

    def lifecycle
      evidence_case = find_case!
      action = params[:lifecycle_action].to_s
      case action
      when "withdraw"
        ::MediaGallery::EvidenceLifecycle.withdraw!(
          evidence_case: evidence_case,
          user: current_user,
          reason: params[:reason],
        )
      when "supersede"
        replacement = ::MediaGallery::ForensicEvidenceCase.find_by!(case_ref: params[:replacement_case_ref].to_s.strip)
        ::MediaGallery::EvidenceLifecycle.supersede!(
          evidence_case: evidence_case,
          replacement_case: replacement,
          user: current_user,
          reason: params[:reason],
        )
      else
        raise ArgumentError, "invalid_lifecycle_action"
      end
      render_json_dump(ok: true, case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def capture_governance
      evidence_case = find_case!
      ::MediaGallery::EvidenceGovernance.capture!(
        evidence_case: evidence_case,
        user: current_user,
        force: ActiveModel::Type::Boolean.new.cast(params[:force]),
        reason: params[:reason],
      )
      render_json_dump(ok: true, case: case_payload(evidence_case.reload), config: config_payload)
    rescue => e
      render_evidence_error(e)
    end

    def retention_review
      evidence_case = find_case!
      review = ::MediaGallery::EvidenceRetention.review!(
        evidence_case: evidence_case,
        user: current_user,
        action: params[:retention_action],
        reason: params[:reason],
        extension_days: params[:extension_days],
      )
      render_json_dump(ok: true, retention_review: retention_review_payload(review), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def create_privacy_request
      evidence_case = find_case!
      request = ::MediaGallery::EvidencePrivacy.create_request!(
        evidence_case: evidence_case,
        user: current_user,
        request_type: params[:request_type],
        requester_ref: params[:privacy_requester_ref].presence || params[:requester_ref],
        received_at: params[:received_at],
        processing_restricted: params[:processing_restricted],
        reason: params[:privacy_reason].presence || params[:reason],
      )
      render_json_dump(ok: true, privacy_request: privacy_request_payload(request), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def update_privacy_request
      evidence_case = find_case!
      request = evidence_case.privacy_requests.find_by!(request_ref: params[:request_ref].to_s)
      ::MediaGallery::EvidencePrivacy.update_request!(
        request: request,
        user: current_user,
        status: params[:status],
        processing_restricted: params.key?(:processing_restricted) ? params[:processing_restricted] : nil,
        decision: params[:privacy_decision].presence || params[:decision],
        reason: params[:privacy_reason].presence || params[:reason],
      )
      render_json_dump(ok: true, privacy_request: privacy_request_payload(request.reload), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def create_identity_annex
      evidence_case = find_case!
      annex = ::MediaGallery::EvidenceIdentityAnnex.create!(
        evidence_case: evidence_case,
        user: current_user,
        selections: params[:annex_selections].presence || params[:selections],
        necessity_reason: params[:annex_necessity_reason].presence || params[:necessity_reason],
      )
      render_json_dump(ok: true, identity_annex: identity_annex_payload(annex), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def view_identity_annex
      evidence_case = find_case!
      annex = evidence_case.identity_annexes.find_by!(annex_ref: params[:annex_ref].to_s)
      render_json_dump(ok: true, identity_annex: identity_annex_payload(annex), payload: ::MediaGallery::EvidenceIdentityAnnex.view!(annex: annex, user: current_user))
    rescue => e
      render_evidence_error(e)
    end

    def approve_identity_annex
      evidence_case = find_case!
      annex = evidence_case.identity_annexes.find_by!(annex_ref: params[:annex_ref].to_s)
      ::MediaGallery::EvidenceIdentityAnnex.approve!(annex: annex, user: current_user, approval_kind: params[:approval_kind], reason: params[:reason])
      render_json_dump(ok: true, identity_annex: identity_annex_payload(annex.reload), case: case_payload(evidence_case.reload))
    rescue => e
      render_evidence_error(e)
    end

    def export_identity_annex
      evidence_case = find_case!
      annex = evidence_case.identity_annexes.find_by!(annex_ref: params[:annex_ref].to_s)
      bytes = ::MediaGallery::EvidenceIdentityAnnex.export!(
        annex: annex,
        user: current_user,
        passphrase: params[:annex_passphrase].presence || params[:passphrase],
        recipient_ref: params[:annex_recipient_ref].presence || params[:recipient_ref],
        purpose: params[:annex_purpose].presence || params[:purpose],
      )
      no_store_headers!
      send_data bytes, filename: "#{annex.annex_ref}-encrypted.json", type: "application/json", disposition: "attachment"
    rescue => e
      render_evidence_error(e)
    end

    def download_report
      evidence_case = find_case!
      report = evidence_case.reports.find_by!(report_ref: params[:report_ref].to_s)
      if report.status == "draft"
        raise Discourse::InvalidAccess.new unless evidence_capability?(:technical_reviewer) || evidence_capability?(:case_operator)
      else
        ensure_senior_reviewer!
      end
      path = ::MediaGallery::EvidenceReporter.absolute_path(report)
      no_store_headers!
      send_file path, filename: "#{report.report_ref}.pdf", type: "application/pdf", disposition: "attachment"
    end

    def download_package
      evidence_case = find_case!
      package = evidence_case.packages.find_by!(package_ref: params[:package_ref].to_s)
      path = ::MediaGallery::EvidencePackage.absolute_path(package)
      no_store_headers!
      send_file path, filename: "#{package.package_ref}.tar.gz", type: "application/gzip", disposition: "attachment"
    end

    private

    def ensure_evidence_enabled
      raise Discourse::InvalidAccess.new unless ::MediaGallery::EvidencePolicy.enabled?
    end

    def evidence_capability?(capability)
      ::MediaGallery::EvidenceAuthorization.allowed?(current_user, capability)
    end

    def ensure_case_operator!
      ::MediaGallery::EvidenceAuthorization.ensure!(current_user, :case_operator)
    end

    def ensure_senior_reviewer!
      ::MediaGallery::EvidenceAuthorization.ensure!(current_user, :senior_reviewer)
    end

    def ensure_policy_administrator!
      ::MediaGallery::EvidenceAuthorization.ensure!(current_user, :policy_administrator)
    end

    def ensure_evidence_admin!
      ensure_senior_reviewer!
    end

    def find_case!
      ref = params[:case_ref].to_s.sub(/\.(json|html)\z/i, "").strip
      ::MediaGallery::ForensicEvidenceCase.find_by!(case_ref: ref)
    end

    def after_object_added!(evidence_case, object)
      event_type = object.role.start_with?("source_") ? "source_capture_added" : "evidence_object_acquired"
      next_status = object.role.start_with?("source_") ? "source_captured" : (evidence_case.identify_snapshots.exists? ? evidence_case.status : "evidence_acquired")
      evidence_case.update!(status: next_status, updated_by: current_user) if evidence_case.mutable?
      ::MediaGallery::EvidenceChain.record!(
        evidence_case: evidence_case,
        event_type: event_type,
        user: current_user,
        object_ref: object.object_ref,
        details: {
          role: object.role,
          storage_kind: object.storage_kind,
          sha256: object.sha256,
          size_bytes: object.size_bytes,
          quarantine_status: object.quarantine_status,
        },
      )
    end

    def case_summary(evidence_case)
      {
        case_ref: evidence_case.case_ref,
        status: evidence_case.status,
        classification: evidence_case.classification,
        decision: evidence_case.decision,
        claimant_ref: evidence_case.claimant_ref,
        media_public_id: evidence_case.media_snapshot&.dig("public_id"),
        media_title: evidence_case.media_snapshot&.dig("title"),
        external_platform: evidence_case.external_platform,
        legal_hold: evidence_case.legal_hold?,
        legal_hold_review_due_at_utc: latest_legal_hold_review_due_at(evidence_case)&.utc&.iso8601(6),
        privacy_request_open: evidence_case.respond_to?(:privacy_request_open?) ? evidence_case.privacy_request_open? : false,
        processing_restricted: evidence_case.respond_to?(:processing_restricted?) ? evidence_case.processing_restricted? : false,
        retention_review_overdue: evidence_case.respond_to?(:retention_review_due_at) ? ::MediaGallery::EvidenceRetention.overdue?(evidence_case) : false,
        mutable: evidence_case.mutable?,
        supersedes_case_ref: evidence_case.supersedes_case&.case_ref,
        superseded_by_case_ref: evidence_case.superseded_by_case&.case_ref,
        closed_at_utc: evidence_case.closed_at&.utc&.iso8601(6),
        created_at_utc: evidence_case.created_at&.utc&.iso8601(6),
        updated_at_utc: evidence_case.updated_at&.utc&.iso8601(6),
      }
    end

    def case_payload(evidence_case)
      policy = ::MediaGallery::EvidencePolicy.finalization_blockers(evidence_case)
      case_summary(evidence_case).merge(
        research_question: evidence_case.research_question,
        jurisdiction_context: evidence_case.jurisdiction_context,
        report_language: evidence_case.report_language,
        external_url: evidence_case.external_url,
        external_url_sha256: evidence_case.external_url_sha256,
        external_username: evidence_case.external_username,
        external_observed_at_utc: evidence_case.external_observed_at&.utc&.iso8601(6),
        external_displayed_at: evidence_case.external_displayed_at,
        rights_statement_received_at_utc: evidence_case.rights_statement_received_at&.utc&.iso8601(6),
        rights_statement_ref: evidence_case.rights_statement_ref,
        claimant_confirmed: evidence_case.claimant_confirmed?,
        claimant_confirmed_at_utc: evidence_case.claimant_confirmed_at&.utc&.iso8601(6),
        retention_due_at_utc: evidence_case.retention_due_at&.utc&.iso8601(6),
        retention_class: evidence_case.respond_to?(:retention_class) ? evidence_case.retention_class : nil,
        retention_reviewed_at_utc: evidence_case.respond_to?(:retention_reviewed_at) ? evidence_case.retention_reviewed_at&.utc&.iso8601(6) : nil,
        retention_review_due_at_utc: evidence_case.respond_to?(:retention_review_due_at) ? evidence_case.retention_review_due_at&.utc&.iso8601(6) : nil,
        retention_review_overdue: evidence_case.respond_to?(:retention_review_due_at) ? ::MediaGallery::EvidenceRetention.overdue?(evidence_case) : false,
        retention_review_due_soon: evidence_case.respond_to?(:retention_review_due_at) ? ::MediaGallery::EvidenceRetention.due_soon?(evidence_case) : false,
        retention_disposal_requested: ::MediaGallery::EvidenceRetention.disposal_requested?(evidence_case),
        governance_profile_ref: evidence_case.respond_to?(:governance_profile_ref) ? evidence_case.governance_profile_ref : nil,
        governance_snapshot: evidence_case.respond_to?(:governance_snapshot) ? evidence_case.governance_snapshot : {},
        governance_matches_current: evidence_case.respond_to?(:governance_snapshot) ? ::MediaGallery::EvidenceGovernance.current_matches?(evidence_case) : false,
        privacy_request_open: evidence_case.respond_to?(:privacy_request_open?) ? evidence_case.privacy_request_open? : false,
        processing_restricted: evidence_case.respond_to?(:processing_restricted?) ? evidence_case.processing_restricted? : false,
        lifecycle_reason: evidence_capability?(:senior_reviewer) ? evidence_case.lifecycle_reason : nil,
        supersedes_case_ref: evidence_case.supersedes_case&.case_ref,
        superseded_by_case_ref: evidence_case.superseded_by_case&.case_ref,
        closed_at_utc: evidence_case.closed_at&.utc&.iso8601(6),
        media_snapshot: evidence_case.media_snapshot,
        identify_snapshots: evidence_case.identify_snapshots.order(created_at: :desc).map { |snapshot| identify_payload(snapshot) },
        evidence_objects: evidence_case.evidence_objects.order(:created_at, :id).map { |object| evidence_object_payload(object) },
        reviews: evidence_case.reviews.order(:reviewed_at, :id).map { |review| review_payload(review) },
        reports: visible_reports(evidence_case).map { |report| report_payload(report) },
        packages: visible_packages(evidence_case).map { |package| package_payload(package) },
        legal_holds: evidence_capability?(:senior_reviewer) ? evidence_case.legal_holds.order(:occurred_at, :id).map { |hold| legal_hold_payload(hold) } : [],
        disclosures: evidence_capability?(:senior_reviewer) ? evidence_case.disclosures.order(released_at: :desc, id: :desc).map { |disclosure| disclosure_payload(disclosure) } : [],
        retention_reviews: evidence_capability?(:policy_administrator) ? evidence_case.retention_reviews.order(occurred_at: :desc, id: :desc).map { |review| retention_review_payload(review) } : [],
        privacy_requests: evidence_capability?(:policy_administrator) ? evidence_case.privacy_requests.order(received_at: :desc, id: :desc).map { |request| privacy_request_payload(request) } : [],
        identity_annexes: ::MediaGallery::EvidenceIdentityAnnex.enabled? && evidence_capability?(:restricted_approver) ? evidence_case.identity_annexes.order(version: :desc).map { |annex| identity_annex_payload(annex) } : [],
        chain: {
          verification: policy[:chain],
          events: evidence_case.chain_events.order(:occurred_at, :id).map { |event| ::MediaGallery::EvidenceChain.external_hash(event) },
        },
        finalization: { ready: policy[:ready], blockers: policy[:blockers], warnings: policy[:warnings] },
      )
    end

    def visible_reports(evidence_case)
      scope = evidence_case.reports.order(version: :desc)
      evidence_capability?(:senior_reviewer) ? scope.to_a : scope.where(status: "draft").to_a
    end

    def visible_packages(evidence_case)
      evidence_capability?(:senior_reviewer) ? evidence_case.packages.order(version: :desc).to_a : []
    end

    def latest_legal_hold_review_due_at(evidence_case)
      return nil unless evidence_case.legal_hold?

      evidence_case.legal_holds.where(action: %w[placed reviewed]).order(occurred_at: :desc, id: :desc).limit(1).pick(:review_due_at)
    rescue
      nil
    end

    def evidence_object_payload(object)
      {
        object_ref: object.object_ref,
        parent_ref: object.parent&.object_ref,
        role: object.role,
        storage_kind: object.storage_kind,
        vault_reference: (evidence_capability?(:case_operator) || evidence_capability?(:senior_reviewer)) && object.storage_kind == "vault_reference" ? object.vault_reference : nil,
        original_filename: object.original_filename,
        mime_type: object.mime_type,
        size_bytes: object.size_bytes,
        sha256: object.sha256,
        quarantine_status: object.quarantine_status,
        scan_metadata: object.respond_to?(:scan_metadata) ? object.scan_metadata : {},
        inspection_metadata: object.respond_to?(:inspection_metadata) ? object.inspection_metadata : {},
        scan_started_at_utc: object.respond_to?(:scan_started_at) ? object.scan_started_at&.utc&.iso8601(6) : nil,
        scan_completed_at_utc: object.respond_to?(:scan_completed_at) ? object.scan_completed_at&.utc&.iso8601(6) : nil,
        inspected_at_utc: object.respond_to?(:inspected_at) ? object.inspected_at&.utc&.iso8601(6) : nil,
        can_rescan: object.storage_kind == "file",
        include_in_package: object.include_in_package?,
        immutable_at_utc: object.immutable_at&.utc&.iso8601(6),
        metadata: object.metadata,
      }.compact
    end

    def identify_payload(snapshot)
      {
        run_ref: snapshot.run_ref,
        run_kind: snapshot.run_kind,
        decision: snapshot.decision,
        conclusive: snapshot.conclusive?,
        synthetic_population: snapshot.synthetic_population?,
        candidate_population_count: snapshot.candidate_population_count,
        attributed_username: snapshot.attributed_username,
        attributed_account_ref: snapshot.attributed_account_ref,
        fingerprint_id: snapshot.fingerprint_id,
        fingerprint_assigned_at_utc: snapshot.fingerprint_assigned_at&.utc&.iso8601(6),
        layout: snapshot.layout,
        raw_result_sha256: snapshot.raw_result_sha256,
        summary: snapshot.summary,
        software_snapshot: snapshot.software_snapshot,
        analysis_settings: snapshot.analysis_settings,
        sanity_checks: snapshot.sanity_checks,
        immutable_at_utc: snapshot.immutable_at&.utc&.iso8601(6),
      }.compact
    end

    def review_payload(review)
      {
        review_ref: review.review_ref,
        review_kind: review.review_kind,
        reviewer_role: review.reviewer_role,
        reviewer_ref: review.reviewer_ref,
        outcome: review.outcome,
        reason: review.reason,
        checklist: review.checklist,
        reviewed_at_utc: review.reviewed_at&.utc&.iso8601(6),
      }.compact
    end

    def report_payload(report)
      {
        report_ref: report.report_ref,
        version: report.version,
        status: report.status,
        pdf_sha256: report.pdf_sha256,
        report_data_sha256: report.report_data_sha256,
        size_bytes: report.size_bytes,
        immutable_at_utc: report.immutable_at&.utc&.iso8601(6),
        download_url: "/admin/plugins/media-gallery/evidence-cases/#{report.evidence_case.case_ref}/reports/#{report.report_ref}",
      }
    end

    def package_payload(package)
      {
        package_ref: package.package_ref,
        version: package.version,
        status: package.status,
        package_sha256: package.package_sha256,
        manifest_sha256: package.manifest_sha256,
        size_bytes: package.size_bytes,
        seal_method: package.seal_method,
        seal_key_id: package.seal_key_id,
        signature_verified: package.signature_verified?,
        cms_signature_integrity_verified: package.signature_verified?,
        certificate_trust_verified: false,
        timestamp_status: package.timestamp_status,
        immutable_at_utc: package.immutable_at&.utc&.iso8601(6),
        download_url: "/admin/plugins/media-gallery/evidence-cases/#{package.evidence_case.case_ref}/packages/#{package.package_ref}",
      }.compact
    end

    def disclosure_payload(disclosure)
      {
        disclosure_ref: disclosure.disclosure_ref,
        package_ref: disclosure.evidence_package.package_ref,
        recipient_ref: disclosure.recipient_ref,
        purpose: disclosure.purpose,
        status: disclosure.status,
        expires_at_utc: disclosure.expires_at&.utc&.iso8601(6),
        max_downloads: disclosure.max_downloads,
        download_count: disclosure.download_count,
        released_at_utc: disclosure.released_at&.utc&.iso8601(6),
        first_downloaded_at_utc: disclosure.first_downloaded_at&.utc&.iso8601(6),
        last_downloaded_at_utc: disclosure.last_downloaded_at&.utc&.iso8601(6),
        revoked_at_utc: disclosure.revoked_at&.utc&.iso8601(6),
        revocation_reason: disclosure.revoked? ? disclosure.revocation_reason : nil,
        active: disclosure.active?,
        receipt_download_url: "/admin/plugins/media-gallery/evidence-cases/#{disclosure.evidence_case.case_ref}/releases/#{disclosure.disclosure_ref}/receipt",
      }.compact
    end

    def legal_hold_payload(hold)
      {
        hold_ref: hold.hold_ref,
        action: hold.action,
        reason: hold.reason,
        authority_ref: hold.authority_ref,
        actor_ref: hold.actor_ref,
        occurred_at_utc: hold.occurred_at&.utc&.iso8601(6),
        review_due_at_utc: hold.respond_to?(:review_due_at) ? hold.review_due_at&.utc&.iso8601(6) : nil,
      }.compact
    end

    def retention_review_payload(review)
      {
        review_ref: review.review_ref,
        action: review.action,
        retention_class: review.retention_class,
        previous_due_at_utc: review.previous_due_at&.utc&.iso8601(6),
        next_due_at_utc: review.next_due_at&.utc&.iso8601(6),
        reason: review.reason,
        actor_ref: review.actor_ref,
        occurred_at_utc: review.occurred_at&.utc&.iso8601(6),
      }.compact
    end

    def privacy_request_payload(request)
      {
        request_ref: request.request_ref,
        request_type: request.request_type,
        requester_ref: request.requester_ref,
        status: request.status,
        received_at_utc: request.received_at&.utc&.iso8601(6),
        due_at_utc: request.due_at&.utc&.iso8601(6),
        processing_restricted: request.processing_restricted?,
        reason: request.reason,
        decision: request.decision,
        created_by_ref: request.created_by_ref,
        resolved_by_ref: request.resolved_by_ref,
        resolved_at_utc: request.resolved_at&.utc&.iso8601(6),
      }.compact
    end

    def identity_annex_payload(annex)
      {
        annex_ref: annex.annex_ref,
        version: annex.version,
        status: annex.status,
        categories: annex.categories,
        key_id: annex.key_id,
        payload_sha256: annex.payload_sha256,
        necessity_reason_recorded: annex.necessity_reason_sha256.present?,
        necessity_reason_sha256: annex.necessity_reason_sha256,
        created_by_ref: annex.created_by_ref,
        senior_approved_by_ref: annex.senior_approved_by_ref,
        senior_approved_at_utc: annex.senior_approved_at&.utc&.iso8601(6),
        privacy_approved_by_ref: annex.privacy_approved_by_ref,
        privacy_approved_at_utc: annex.privacy_approved_at&.utc&.iso8601(6),
        fully_approved: annex.fully_approved?,
        last_viewed_at_utc: annex.last_viewed_at&.utc&.iso8601(6),
        last_exported_at_utc: annex.last_exported_at&.utc&.iso8601(6),
        created_at_utc: annex.created_at&.utc&.iso8601(6),
      }.compact
    end

    def config_payload
      {
        enabled: ::MediaGallery::EvidencePolicy.enabled?,
        can_finalize: evidence_capability?(:senior_reviewer),
        capabilities: ::MediaGallery::EvidenceAuthorization.capabilities(current_user),
        issuer_name: ::MediaGallery::EvidencePolicy.issuer_name,
        operator_identity: ::MediaGallery::EvidencePolicy.operator_identity,
        legal_notice_url: ::MediaGallery::EvidencePolicy.legal_notice_url,
        jurisdiction_notice: ::MediaGallery::EvidencePolicy.jurisdiction_notice,
        seal_mode: ::MediaGallery::EvidencePolicy.seal_mode,
        cms_seal_configured: ::MediaGallery::EvidencePolicy.cms_seal_configured?,
        timestamp_status: "not_configured",
        report_language: "en",
        automatic_source_fetch: false,
        restricted_identity_annex: ::MediaGallery::EvidenceIdentityAnnex.enabled?,
        restricted_identity_annex_configured: ::MediaGallery::EvidenceIdentityAnnex.configured?,
        restricted_identity_annex_allowed_categories: ::MediaGallery::EvidenceIdentityAnnex.allowed_categories,
        governance_current_profile: ::MediaGallery::EvidenceGovernance.current_profile,
        retention_classes: ::MediaGallery::EvidenceRetention::CLASSES,
        retention_actions: ::MediaGallery::EvidenceRetention::ACTIONS,
        privacy_request_types: ::MediaGallery::ForensicEvidencePrivacyRequest::REQUEST_TYPES,
        privacy_request_statuses: ::MediaGallery::ForensicEvidencePrivacyRequest::STATUSES,
        required_review_checks: ::MediaGallery::EvidencePolicy::REQUIRED_REVIEW_CHECKS,
        roles: ::MediaGallery::ForensicEvidenceObject::ROLES,
        classifications: ::MediaGallery::ForensicEvidenceCase::CLASSIFICATIONS,
        decisions: ::MediaGallery::ForensicEvidenceCase::DECISIONS,
      }.merge(release_config_payload).merge(acquisition_config_payload)
    end

    def acquisition_config_payload
      health = ::MediaGallery::EvidenceAcquisition.health
      {
        acquisition_health: health,
        malware_scanner_mode: ::MediaGallery::EvidenceScanner.mode,
        malware_scanner_enabled: ::MediaGallery::EvidenceScanner.enabled?,
        scan_on_upload: ::MediaGallery::EvidenceAcquisition.automatic_queue_enabled?,
      }
    rescue => e
      log_evidence_error(e, context: "acquisition_config")
      {
        acquisition_health: { "status" => "unavailable", "message" => e.message.to_s.truncate(500) },
        malware_scanner_mode: "unknown",
        malware_scanner_enabled: false,
        scan_on_upload: false,
      }
    end

    def release_config_payload
      {
        release_configuration_available: true,
        release_transport_secure: ::MediaGallery::EvidenceRelease.transport_secure?,
        release_insecure_test_override: ::MediaGallery::EvidenceRelease.insecure_transport_allowed?,
        release_default_hours: ::MediaGallery::EvidenceRelease.default_expiry_hours,
        release_max_hours: ::MediaGallery::EvidenceRelease.max_expiry_hours,
        release_max_downloads: ::MediaGallery::EvidenceRelease.max_downloads_limit,
      }
    rescue => e
      log_evidence_error(e, context: "release_config")
      {
        release_configuration_available: false,
        release_transport_secure: false,
        release_insecure_test_override: false,
        release_default_hours: ::MediaGallery::EvidenceRelease::DEFAULT_EXPIRY_HOURS,
        release_max_hours: ::MediaGallery::EvidenceRelease::MAX_EXPIRY_HOURS,
        release_max_downloads: ::MediaGallery::EvidenceRelease::DEFAULT_MAX_DOWNLOADS,
      }
    end

    def identify_public_id
      raw = params[:result] || params[:raw_result]
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raw = JSON.parse(raw) if raw.is_a?(String)
      params[:media_public_id].to_s.strip.presence || raw&.dig("meta", "public_id").to_s.strip.presence || raw&.dig(:meta, :public_id).to_s.strip.presence
    rescue JSON::ParserError
      params[:media_public_id].to_s.strip.presence
    end

    def default_research_question(public_id)
      id = plain_text(public_id, 200).presence || "the selected media item"
      "Does the acquired external file correspond to media item #{id}, and does its forensic pattern meet the recorded criteria for attribution within the investigated candidate population?"
    end

    def plain_text(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip.presence
    end

    def render_evidence_error(error)
      log_evidence_error(error)
      payload = ::MediaGallery::EvidenceErrors.payload(error)
      render json: { ok: false, **payload }, status: ::MediaGallery::EvidenceErrors.status_for(error)
    end

    def log_evidence_error(error, context: nil)
      suffix = context.present? ? " context=#{context}" : ""
      Rails.logger.warn(
        "[media_gallery] evidence reporting request failed user_id=#{current_user&.id} " \
          "action=#{action_name}#{suffix} #{error.class}: #{error.message.to_s.truncate(1000)}",
      )
    end

    def no_store_headers!
      response.headers["Cache-Control"] = "no-store, private"
      response.headers["Pragma"] = "no-cache"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
    end
  end
end
