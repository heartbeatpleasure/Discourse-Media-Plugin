# frozen_string_literal: true

require "digest"
require "json"

module ::MediaGallery
  module EvidenceSnapshot
    module_function

    RAW_RESULT_MAX_BYTES = 25 * 1024 * 1024
    SETTING_ALLOWLIST = %i[
      media_gallery_hls_segment_duration_seconds
      media_gallery_fingerprint_enabled
      media_gallery_fingerprint_watermark_layout
      media_gallery_fingerprint_preserve_legacy_layouts_for_new_uploads
      media_gallery_forensics_identify_policy_min_usable_any
      media_gallery_forensics_identify_policy_min_usable_strong
      media_gallery_forensics_identify_policy_min_match_strong_percent
      media_gallery_forensics_identify_policy_min_delta_strong_percent
      media_gallery_forensics_identify_policy_max_mismatch_rate_strong_percent
      media_gallery_forensics_identify_policy_min_usable_likely
      media_gallery_forensics_identify_policy_min_match_likely_percent
      media_gallery_forensics_identify_policy_min_delta_likely_percent
    ].freeze
    CLAIMANT_CONFIRMATION_SCOPE_FIELDS = %i[
      claimant_ref research_question external_url external_url_sha256 external_platform external_username
      external_observed_at rights_statement_received_at rights_statement_ref
    ].freeze

    def create_case!(user:, public_id: nil, claimant_ref:, research_question:, external_url: nil, external_platform: nil, external_username: nil, external_observed_at: nil, external_displayed_at: nil, classification: "confidential", jurisdiction_context: "international", rights_statement_received_at: nil, rights_statement_ref: nil)
      raise Discourse::InvalidAccess.new unless ::MediaGallery::EvidencePolicy.enabled?

      item = public_id.to_s.strip.present? ? ::MediaGallery::MediaItem.find_by(public_id: public_id.to_s.strip) : nil
      raise Discourse::InvalidParameters.new(:public_id) if public_id.to_s.strip.present? && item.blank?

      redacted_url, url_hash = ::MediaGallery::EvidenceReference.redacted_url(external_url)
      now = Time.now.utc
      case_ref = ::MediaGallery::EvidenceReference.case_ref(time: now)
      evidence_case = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case = ::MediaGallery::ForensicEvidenceCase.create!(
          case_ref: case_ref,
          media_item: item,
          claimant_ref: plain_text(claimant_ref, 200),
          research_question: plain_text(research_question, 4000, allow_newlines: true),
          status: "draft",
          classification: normalized_classification(classification),
          decision: "pending",
          jurisdiction_context: plain_text(jurisdiction_context, 100),
          report_language: "en",
          external_url: redacted_url,
          external_url_sha256: url_hash,
          external_platform: plain_text(external_platform, 200),
          external_username: plain_text(external_username, 200),
          external_observed_at: parse_time(external_observed_at),
          external_displayed_at: plain_text(external_displayed_at, 200),
          rights_statement_received_at: parse_time(rights_statement_received_at),
          rights_statement_ref: plain_text(rights_statement_ref, 200),
          created_by: user,
          updated_by: user,
          media_snapshot: item.present? ? media_snapshot(item, case_ref: case_ref) : {},
          settings_snapshot: settings_snapshot,
          metadata: {
            "report_scope" => "international_jurisdiction_neutral_technical_core",
            "source_url_redacted" => redacted_url.present? && redacted_url != external_url.to_s.strip,
            "restricted_identity_annex" => "not_implemented_default_deny",
            "automatic_source_fetch" => "disabled",
            "retention_enforcement" => "advisory_review_date_only",
            "pseudonymization_key_id" => ::MediaGallery::EvidenceReference.reviewer_secret_key_id,
          },
          retention_due_at: draft_retention_due_at(now),
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "case_created",
          user: user,
          details: {
            status: evidence_case.status,
            media_public_id: item&.public_id,
            classification: evidence_case.classification,
            report_language: "en",
          },
        )
      end
      evidence_case
    end

    def attach_identify!(evidence_case:, raw_result:, user:, public_id: nil)
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      parsed = normalize_raw_result(raw_result)
      raw_bytes = ::MediaGallery::EvidenceReference.pretty_canonical_json(parsed).b
      raise ArgumentError, "identify_result_too_large" if raw_bytes.bytesize > RAW_RESULT_MAX_BYTES

      item = resolve_media_item(evidence_case, parsed, public_id)
      attestation = ::MediaGallery::EvidenceAttestation.verify!(
        parsed,
        expected_public_id: item.public_id,
        expected_media_item_id: item.id,
      )
      synthetic = ::MediaGallery::EvidencePolicy.synthetic_result?(parsed)
      decision = synthetic ? "ambiguous" : ::MediaGallery::EvidencePolicy.normalize_decision(parsed)
      candidates = Array(parsed["candidates"]).select { |row| row.is_a?(Hash) }
      top_candidate = synthetic ? nil : candidates.first
      fingerprint = fingerprint_record(item, top_candidate)
      user_record = attributed_user_record(top_candidate, fingerprint)
      account_ref = user_record.present? ? ::MediaGallery::EvidenceReference.account_ref(case_ref: evidence_case.case_ref, user_id: user_record.id) : nil
      candidate_refs = candidate_account_ref_map(evidence_case.case_ref, candidates)
      candidate_refs[user_record.id.to_s] = account_ref if user_record.present? && account_ref.present?
      checks = sanity_checks(
        evidence_case: evidence_case,
        item: item,
        parsed: parsed,
        synthetic: synthetic,
        decision: decision,
        top_candidate: top_candidate,
        fingerprint: fingerprint,
      )

      raw_object = nil
      snapshot = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        raw_object = ::MediaGallery::EvidenceVault.store_bytes!(
          evidence_case: evidence_case,
          bytes: raw_bytes,
          filename: "raw-result-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}.json",
          mime_type: "application/json",
          role: "identify_raw_json",
          user: user,
          metadata: {
            "source" => "forensics_identify_admin_result",
            "production_evidence_eligible" => !synthetic,
          },
          quarantine_status: "not_applicable",
          include_in_package: false,
        )

        snapshot = ::MediaGallery::ForensicIdentifySnapshot.create!(
          evidence_case: evidence_case,
          raw_result_object: raw_object,
          run_ref: attestation.fetch("run_ref"),
          run_kind: synthetic ? "diagnostic" : "production",
          decision: decision,
          conclusive: decision == "conclusive_match",
          synthetic_population: synthetic,
          candidate_population_count: candidate_population_count(parsed, candidates),
          attributed_user: user_record,
          attributed_username: user_record&.username || top_candidate&.dig("username"),
          attributed_account_ref: account_ref,
          fingerprint_id: fingerprint&.fingerprint_id || top_candidate&.dig("fingerprint_id"),
          fingerprint_assigned_at: fingerprint&.created_at,
          layout: identify_layout(parsed),
          raw_result_sha256: raw_object.sha256,
          summary: identify_summary(parsed, candidates, decision, evidence_case.case_ref, candidate_refs),
          account_snapshot: account_snapshot(user_record, account_ref, candidate_refs),
          fingerprint_snapshot: fingerprint_snapshot(fingerprint, item, account_ref),
          software_snapshot: software_snapshot(parsed, attestation),
          analysis_settings: analysis_settings(parsed),
          sanity_checks: checks,
          immutable_at: Time.now.utc,
          created_by: user,
        )

        evidence_case.update!(
          media_item: item,
          media_snapshot: media_snapshot(item, case_ref: evidence_case.case_ref),
          settings_snapshot: settings_snapshot,
          decision: decision,
          status: "identified",
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "identify_snapshot_attached",
          user: user,
          object_ref: raw_object.object_ref,
          details: {
            run_ref: snapshot.run_ref,
            run_kind: snapshot.run_kind,
            decision: snapshot.decision,
            synthetic_population: snapshot.synthetic_population,
            raw_result_sha256: snapshot.raw_result_sha256,
            sanity_status: checks.any? { |check| check["status"] == "critical" } ? "critical" : (checks.any? { |check| check["status"] == "warning" } ? "warning" : "ok"),
          },
        )
      end
      snapshot
    rescue
      ::MediaGallery::EvidenceVault.discard_uncommitted_file!(raw_object) if defined?(raw_object) && raw_object.present?
      raise
    end

    def update_case!(evidence_case:, user:, attributes: {})
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?

      attrs = attributes.to_h.stringify_keys
      update = {}
      update[:claimant_ref] = plain_text(attrs["claimant_ref"], 200) if attrs.key?("claimant_ref")
      update[:research_question] = plain_text(attrs["research_question"], 4000, allow_newlines: true) if attrs.key?("research_question")
      update[:classification] = normalized_classification(attrs["classification"]) if attrs.key?("classification")
      update[:jurisdiction_context] = plain_text(attrs["jurisdiction_context"], 100) if attrs.key?("jurisdiction_context")
      update[:external_platform] = plain_text(attrs["external_platform"], 200) if attrs.key?("external_platform")
      update[:external_username] = plain_text(attrs["external_username"], 200) if attrs.key?("external_username")
      update[:external_displayed_at] = plain_text(attrs["external_displayed_at"], 200) if attrs.key?("external_displayed_at")
      update[:external_observed_at] = parse_time(attrs["external_observed_at"]) if attrs.key?("external_observed_at")
      update[:rights_statement_received_at] = parse_time(attrs["rights_statement_received_at"]) if attrs.key?("rights_statement_received_at")
      update[:rights_statement_ref] = plain_text(attrs["rights_statement_ref"], 200) if attrs.key?("rights_statement_ref")
      if attrs.key?("external_url")
        update[:external_url], update[:external_url_sha256] = ::MediaGallery::EvidenceReference.redacted_url(attrs["external_url"])
      end
      changed = update.each_with_object({}) do |(key, value), out|
        out[key] = value unless comparable_value(evidence_case.public_send(key)) == comparable_value(value)
      end
      return evidence_case if changed.empty?

      confirmation_scope_changed = (changed.keys & CLAIMANT_CONFIRMATION_SCOPE_FIELDS).any?
      confirmation_invalidated = confirmation_scope_changed && evidence_case.claimant_confirmed?
      if confirmation_invalidated
        changed[:claimant_confirmed] = false
        changed[:claimant_confirmed_at] = nil
        changed[:status] = status_after_claimant_invalidation(evidence_case)
      end
      changed[:updated_by] = user

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.update!(changed)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "case_intake_updated",
          user: user,
          details: {
            changed_fields: changed.keys.map(&:to_s) - ["updated_by"],
            claimant_confirmation_invalidated: confirmation_invalidated,
          },
        )
      end
      evidence_case
    end

    def confirm_claimant!(evidence_case:, user:, reason: nil)
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      raise ArgumentError, "rights_statement_missing" if evidence_case.rights_statement_received_at.blank?

      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.update!(
          claimant_confirmed: true,
          claimant_confirmed_at: Time.now.utc,
          status: "claimant_confirmed",
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: "claimant_confirmation_recorded",
          user: user,
          reason: plain_text(reason, 1000, allow_newlines: true),
          details: { rights_statement_ref: evidence_case.rights_statement_ref },
        )
      end
      evidence_case
    end

    def media_snapshot(item, case_ref: nil)
      upload = item.original_upload
      processed = item.processed_upload
      storage_manifest = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash : {}
      {
        "media_item_id" => item.id,
        "public_id" => item.public_id,
        "title" => item.title,
        "media_type" => item.media_type,
        "status" => item.status,
        "content_contributor" => {
          "user_id" => item.user_id,
          "username" => item.user&.username,
          "account_ref" => case_ref.present? && item.user_id.to_i.positive? ? ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: item.user_id) : nil,
          "account_created_at_utc" => item.user&.created_at&.utc&.iso8601(6),
        }.compact,
        "created_at_utc" => item.created_at&.utc&.iso8601(6),
        "updated_at_utc" => item.updated_at&.utc&.iso8601(6),
        "duration_seconds" => item.duration_seconds,
        "width" => item.width,
        "height" => item.height,
        "filesize_original_bytes" => item.filesize_original_bytes,
        "filesize_processed_bytes" => item.filesize_processed_bytes,
        "watermark_enabled" => item.respond_to?(:watermark_enabled) ? item.watermark_enabled : nil,
        "watermark_preset_id" => item.respond_to?(:watermark_preset_id) ? item.watermark_preset_id : nil,
        "managed_storage_backend" => item.respond_to?(:managed_storage_backend_effective) ? item.managed_storage_backend_effective : nil,
        "storage_manifest_sha256" => Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(storage_manifest)),
        "original_upload" => upload_snapshot(upload),
        "processed_upload" => upload_snapshot(processed),
      }
    end

    def settings_snapshot
      SETTING_ALLOWLIST.each_with_object({}) do |name, out|
        next unless SiteSetting.respond_to?(name)

        out[name.to_s] = SiteSetting.public_send(name)
      rescue
        nil
      end
    end

    def software_snapshot(raw_result = nil, attestation = nil)
      raw_meta = raw_result.is_a?(Hash) ? (raw_result["meta"] || {}) : {}
      {
        "plugin_name" => ::MediaGallery::PLUGIN_NAME,
        "plugin_version" => (::MediaGallery.const_defined?(:PLUGIN_VERSION) ? ::MediaGallery::PLUGIN_VERSION : nil),
        "discourse_version" => (defined?(::Discourse::VERSION::STRING) ? ::Discourse::VERSION::STRING : nil),
        "rails_version" => (defined?(::Rails::VERSION::STRING) ? ::Rails::VERSION::STRING : nil),
        "ruby_version" => RUBY_VERSION,
        "discourse_git_version" => ENV["DISCOURSE_GIT_VERSION"].presence || ENV["GIT_VERSION"].presence,
        "container_image_digest" => ENV["MEDIA_GALLERY_CONTAINER_IMAGE_DIGEST"].presence,
        "identify_detector_version" => raw_meta["detector_version"],
        "identify_policy_version" => raw_meta["decision_policy"] || raw_meta["policy_version"],
        "identify_reference_cache_version" => raw_meta["reference_cache_version"],
        "evidence_reporter_version" => "1.1.0",
        "pseudonymization_key_id" => ::MediaGallery::EvidenceReference.reviewer_secret_key_id,
        "identify_evidence_attestation" => ::MediaGallery::EvidenceAttestation.external_summary(attestation),
      }.compact
    end

    def comparable_value(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
    private_class_method :comparable_value

    def status_after_claimant_invalidation(evidence_case)
      return "review_pending" if evidence_case.identify_snapshots.exists?
      return "evidence_acquired" if evidence_case.evidence_objects.where(role: %w[external_original working_copy]).exists?
      return "source_captured" if evidence_case.evidence_objects.where(role: %w[source_screenshot source_html source_warc source_headers]).exists?

      "draft"
    end
    private_class_method :status_after_claimant_invalidation

    def parse_time(value)
      return value.utc if value.respond_to?(:utc)
      return nil if value.to_s.strip.blank?

      Time.zone.parse(value.to_s)&.utc
    rescue
      raise ArgumentError, "invalid_datetime"
    end

    def plain_text(value, max_length, allow_newlines: false)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: allow_newlines).to_s.strip
    end
    private_class_method :plain_text

    def normalized_classification(value)
      candidate = value.to_s
      ::MediaGallery::ForensicEvidenceCase::CLASSIFICATIONS.include?(candidate) ? candidate : "confidential"
    end
    private_class_method :normalized_classification

    def normalize_raw_result(raw_result)
      value = if raw_result.is_a?(String)
        JSON.parse(raw_result)
      elsif raw_result.respond_to?(:to_unsafe_h)
        raw_result.to_unsafe_h
      else
        raw_result
      end
      raise ArgumentError, "invalid_identify_result" unless value.is_a?(Hash)

      value.deep_stringify_keys
    rescue JSON::ParserError
      raise ArgumentError, "invalid_identify_json"
    end
    private_class_method :normalize_raw_result

    def resolve_media_item(evidence_case, parsed, public_id)
      raw_public_id = parsed.dig("meta", "public_id").to_s.strip
      requested = public_id.to_s.strip.presence || raw_public_id.presence || evidence_case.media_item&.public_id
      item = requested.present? ? ::MediaGallery::MediaItem.find_by(public_id: requested) : evidence_case.media_item
      raise ArgumentError, "identify_media_item_missing" if item.blank?
      if evidence_case.media_item.present? && evidence_case.media_item_id != item.id
        raise ArgumentError, "identify_media_item_mismatch"
      end
      item
    end
    private_class_method :resolve_media_item

    def fingerprint_record(item, top_candidate)
      return nil if item.blank? || top_candidate.blank?

      fp = top_candidate["fingerprint_id"].to_s
      user_id = top_candidate["user_id"].to_i
      scope = ::MediaGallery::MediaFingerprint.where(media_item_id: item.id)
      scope = scope.where(fingerprint_id: fp) if fp.present?
      scope = scope.where(user_id: user_id) if user_id.positive?
      scope.order(created_at: :asc).first
    end
    private_class_method :fingerprint_record

    def attributed_user_record(top_candidate, fingerprint)
      return fingerprint.user if fingerprint&.user.present?
      return nil if top_candidate.blank?

      id = top_candidate["user_id"].to_i
      id.positive? ? ::User.find_by(id: id) : nil
    end
    private_class_method :attributed_user_record

    def candidate_account_ref_map(case_ref, candidates)
      Array(candidates).first(10_000).each_with_object({}) do |candidate, out|
        next unless candidate.is_a?(Hash)

        user_id = candidate["user_id"].to_i
        next unless user_id.positive?

        out[user_id.to_s] ||= ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id)
      end
    end
    private_class_method :candidate_account_ref_map

    def candidate_population_count(parsed, candidates)
      meta = parsed["meta"] || {}
      value = meta["candidate_population_count"] || meta["synthetic_population_actual_total"] || candidates.length
      [value.to_i, candidates.length].max
    end
    private_class_method :candidate_population_count

    def identify_layout(parsed)
      meta = parsed["meta"] || {}
      (meta["layout"] || meta["watermark_layout"] || meta["layout_name"]).to_s.presence
    end
    private_class_method :identify_layout

    def identify_summary(parsed, candidates, decision, case_ref, candidate_refs)
      meta = parsed["meta"] || {}
      observed = parsed["observed"] || {}
      top = candidates.first || {}
      second = candidates[1] || {}
      top_ratio = candidate_ratio(top)
      second_ratio = candidate_ratio(second)
      {
        "decision" => decision,
        "engine_decision" => meta["decision"],
        "conclusive" => decision == "conclusive_match",
        "recommendation" => meta["recommendation"],
        "decision_reasons" => Array(meta["decision_reasons"]),
        "candidate_population_count" => candidate_population_count(parsed, candidates),
        "top_candidate" => candidate_summary(top, case_ref, candidate_refs),
        "second_candidate" => candidate_summary(second, case_ref, candidate_refs),
        "top_match_score" => top_ratio,
        "delta_vs_second" => (top_ratio.present? && second_ratio.present? ? (top_ratio - second_ratio).round(6) : nil),
        "samples" => meta["samples"] || meta["requested_max_samples"],
        "usable_samples" => meta["usable_samples"] || meta["effective_samples"] || meta["ecc_effective_samples"],
        "chosen_offset_segments" => meta["chosen_offset_segments"],
        "phase" => meta["phase"] || meta["chosen_phase"],
        "drift" => meta["drift"] || meta["chosen_drift"],
        "alignment_method" => meta["alignment_method"] || meta["offset_strategy"],
        "observed_variant_count" => observed["variants"].to_s.length,
        "source_mode" => meta["source_mode"],
        "budget_exhausted" => meta["budget_exhausted"],
        "truncated" => meta["truncated"],
      }.compact
    end
    private_class_method :identify_summary

    def candidate_summary(candidate, case_ref, candidate_refs)
      return {} unless candidate.is_a?(Hash) && candidate.present?

      user_id = candidate["user_id"].to_i
      {
        "user_id" => candidate["user_id"],
        "username" => candidate["username"],
        "account_ref" => user_id.positive? ? (candidate_refs[user_id.to_s] || ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id)) : nil,
        "fingerprint_id" => candidate["fingerprint_id"],
        "synthetic" => ActiveModel::Type::Boolean.new.cast(candidate["synthetic"]),
        "match_ratio" => candidate["match_ratio"],
        "weighted_match_ratio" => candidate["match_ratio_weighted"] || candidate["weighted_match_ratio"],
        "adaptive_match_ratio" => candidate["adaptive_match_ratio"],
        "high_quality_match_ratio" => candidate["high_quality_match_ratio"],
        "mismatches" => candidate["mismatches"],
        "compared" => candidate["compared"],
        "best_offset_segments" => candidate["best_offset_segments"],
      }.compact
    end
    private_class_method :candidate_summary

    def candidate_ratio(candidate)
      return nil unless candidate.is_a?(Hash)

      value = candidate["match_ratio_weighted"] || candidate["weighted_match_ratio"] || candidate["match_ratio"]
      number = Float(value, exception: false)
      number&.round(6)
    end
    private_class_method :candidate_ratio

    def account_snapshot(user, account_ref, candidate_refs)
      return { "candidate_account_refs_by_user_id" => candidate_refs } if user.blank?

      {
        "account_ref" => account_ref,
        "internal_user_id" => user.id,
        "username" => user.username,
        "created_at_utc" => user.created_at&.utc&.iso8601(6),
        "active" => (user.respond_to?(:active) ? user.active : nil),
        "staged" => (user.respond_to?(:staged) ? user.staged : nil),
        "suspended" => (user.respond_to?(:suspended?) ? user.suspended? : user.respond_to?(:suspended_at) && user.suspended_at.present?),
        "trust_level" => (user.respond_to?(:trust_level) ? user.trust_level : nil),
        "candidate_account_refs_by_user_id" => candidate_refs,
        "privacy_note" => "No email, IP address, payment data or private-message content included.",
      }.compact
    end
    private_class_method :account_snapshot

    def fingerprint_snapshot(fingerprint, item, account_ref)
      return {} if fingerprint.blank?

      sessions = ::MediaGallery::MediaPlaybackSession.where(media_item_id: item.id, fingerprint_id: fingerprint.fingerprint_id)
      {
        "fingerprint_record_id" => fingerprint.id,
        "fingerprint_id" => fingerprint.fingerprint_id,
        "assigned_user_id" => fingerprint.user_id,
        "assigned_account_ref" => account_ref,
        "media_item_id" => fingerprint.media_item_id,
        "assigned_at_utc" => fingerprint.created_at&.utc&.iso8601(6),
        "last_seen_at_utc" => fingerprint.last_seen_at&.utc&.iso8601(6),
        "distribution_event_summary" => {
          "playback_session_count" => sessions.count,
          "first_played_at_utc" => sessions.minimum(:played_at)&.utc&.iso8601(6),
          "last_played_at_utc" => sessions.maximum(:played_at)&.utc&.iso8601(6),
          "network_identifiers_included" => false,
        },
      }
    rescue
      {
        "fingerprint_record_id" => fingerprint.id,
        "fingerprint_id" => fingerprint.fingerprint_id,
        "assigned_user_id" => fingerprint.user_id,
        "assigned_account_ref" => account_ref,
        "media_item_id" => fingerprint.media_item_id,
        "assigned_at_utc" => fingerprint.created_at&.utc&.iso8601(6),
      }
    end
    private_class_method :fingerprint_snapshot

    def analysis_settings(parsed)
      meta = parsed["meta"] || {}
      keys = %w[
        requested_max_samples effective_max_samples max_samples_used max_offset_segments auto_extended attempts
        configured_filemode_soft_time_budget_seconds configured_filemode_engine_time_budget_seconds
        layout decision_policy detector_version reference_cache_version source_mode alignment_method
        offset_strategy polarity_policy codebook_scheme carrier_version
      ]
      keys.each_with_object({}) { |key, out| out[key] = meta[key] if meta.key?(key) }
    end
    private_class_method :analysis_settings

    def sanity_checks(evidence_case:, item:, parsed:, synthetic:, decision:, top_candidate:, fingerprint:)
      meta = parsed["meta"] || {}
      checks = []
      checks << check("media_reference", item.present? && item.public_id == (meta["public_id"].presence || item.public_id), "Identify media reference matches the case media item.", critical: true)
      checks << check("synthetic_population", !synthetic, "Production evidence run contains no synthetic candidates.", critical: true)
      checks << check("raw_candidates", decision == "no_match" || top_candidate.present?, "A top candidate is present when the decision attributes a distribution copy.", critical: true)
      checks << check("fingerprint_assignment", !%w[conclusive_match likely_match].include?(decision) || fingerprint.present?, "The selected fingerprint exists in the media fingerprint table.", critical: true)
      checks << check("layout_version", identify_layout(parsed).present?, "The identify layout/version is present.")
      checks << check("policy_version", (meta["decision_policy"] || meta["policy_version"]).present?, "The decision policy version is present.")
      checks << check("budget_status", !ActiveModel::Type::Boolean.new.cast(meta["budget_exhausted"]), "The run did not report budget exhaustion.")
      checks << check("truncation_status", !ActiveModel::Type::Boolean.new.cast(meta["truncated"]), "The run did not report result truncation.")
      checks << check("decision_consistency", !(decision == "conclusive_match" && !ActiveModel::Type::Boolean.new.cast(meta["conclusive"])), "The normalized decision is consistent with the engine conclusive flag.")
      checks.map(&:stringify_keys)
    end
    private_class_method :sanity_checks

    def check(code, passed, message, critical: false)
      {
        code: code,
        status: passed ? "ok" : (critical ? "critical" : "warning"),
        message: message,
      }
    end
    private_class_method :check

    def upload_snapshot(upload)
      return nil if upload.blank?

      {
        "upload_id" => upload.id,
        "original_filename" => (upload.respond_to?(:original_filename) ? upload.original_filename : nil),
        "filesize" => (upload.respond_to?(:filesize) ? upload.filesize : nil),
        "sha1" => (upload.respond_to?(:sha1) ? upload.sha1 : nil),
        "extension" => (upload.respond_to?(:extension) ? upload.extension : nil),
        "created_at_utc" => upload.created_at&.utc&.iso8601(6),
      }.compact
    end
    private_class_method :upload_snapshot

    def draft_retention_due_at(now)
      days = SiteSetting.respond_to?(:media_gallery_evidence_draft_retention_days) ? SiteSetting.media_gallery_evidence_draft_retention_days.to_i : 30
      days.positive? ? now + days.days : nil
    rescue
      now + 30.days
    end
    private_class_method :draft_retention_due_at
  end
end
