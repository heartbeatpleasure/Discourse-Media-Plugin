# frozen_string_literal: true

require "date"
require "digest"

module ::MediaGallery
  module EvidenceGovernance
    module_function

    PROFILE_SCHEMA = "media-gallery-evidence-governance-v1"
    HOSTING_REGIONS = %w[unknown eu_eea non_eu_eea mixed].freeze

    def current_profile(captured_at: Time.now.utc)
      values = current_profile_values
      configured_ref = setting(:media_gallery_evidence_governance_profile_reference, max_length: 200)
      digest = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(values))
      profile_ref = configured_ref.presence || "GOV-#{digest[0, 12].upcase}"

      values.merge(
        "profile_ref" => profile_ref,
        "profile_sha256" => digest,
        "captured_at_utc" => captured_at.utc.iso8601(6),
      )
    end

    def current_profile_values
      {
        "schema" => PROFILE_SCHEMA,
        "effective_from" => normalized_date(setting(:media_gallery_evidence_governance_effective_from, max_length: 32)),
        "issuer_display_name" => ::MediaGallery::EvidencePolicy.issuer_name,
        "operator_display_name" => ::MediaGallery::EvidencePolicy.operator_identity,
        "website_url" => site_base_url,
        "generic_contact" => setting(:media_gallery_evidence_generic_contact, max_length: 500),
        "privacy_legal_notice_url" => ::MediaGallery::EvidencePolicy.legal_notice_url,
        "policy_reference" => setting(:media_gallery_evidence_policy_reference, max_length: 200),
        "controller_country" => setting(:media_gallery_evidence_controller_country, max_length: 100),
        "hosting_region" => normalized_hosting_region(setting(:media_gallery_evidence_hosting_region, max_length: 32)),
        "report_visibility" => report_visibility,
      }.compact
    end

    def capture!(evidence_case:, user:, force: false, reason: nil)
      snapshot = current_profile
      cleaned_reason = sanitize(reason, 1000)
      ::MediaGallery::ForensicEvidenceCase.transaction do
        evidence_case.lock!
        evidence_case.reload
        raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?

        existing = evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot : {}
        next if existing.present? && !force
        if existing.present? && force && cleaned_reason.blank?
          raise ArgumentError, "governance_replacement_reason_missing"
        end

        evidence_case.update!(
          governance_profile_ref: snapshot.fetch("profile_ref"),
          governance_snapshot: snapshot,
          updated_by: user,
        )
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: existing.present? ? "governance_profile_replaced" : "governance_profile_captured",
          user: user,
          reason: cleaned_reason,
          details: {
            governance_profile_ref: snapshot["profile_ref"],
            governance_profile_sha256: snapshot["profile_sha256"],
            previous_governance_profile_ref: existing["profile_ref"],
          }.compact,
        )
      end
      evidence_case
    end

    def snapshot_for_new_case
      current_profile
    end

    def current_matches?(evidence_case)
      stored = evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot : {}
      return false if stored.blank?

      stored["profile_sha256"].to_s == current_profile_values_digest
    end

    def current_profile_values_digest
      Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(current_profile_values))
    end

    def external_profile(evidence_case)
      snapshot = evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot.deep_dup : {}
      visibility = snapshot["report_visibility"].is_a?(Hash) ? snapshot["report_visibility"] : {}
      output = {
        "profile_ref" => (snapshot["profile_ref"] if truthy?(visibility["show_policy_reference"])),
        "issuer_display_name" => snapshot["issuer_display_name"],
        "website_url" => snapshot["website_url"],
        "operator_display_name" => (snapshot["operator_display_name"] if truthy?(visibility["show_operator_identity"])),
        "generic_contact" => (snapshot["generic_contact"] if truthy?(visibility["show_generic_contact"])),
        "privacy_legal_notice_url" => (snapshot["privacy_legal_notice_url"] if truthy?(visibility["show_privacy_legal_notice_url"])),
        "policy_reference" => (snapshot["policy_reference"] if truthy?(visibility["show_policy_reference"])),
        "controller_country" => (snapshot["controller_country"] if truthy?(visibility["show_controller_country"])),
      }.compact
      output.delete_if { |_key, value| value.respond_to?(:empty?) && value.empty? }
      output["profile_snapshot_sha256"] = snapshot["profile_sha256"] if snapshot["profile_sha256"].present?
      output
    end

    def report_visibility
      {
        "show_operator_identity" => boolean_setting(:media_gallery_evidence_report_show_operator_identity, true),
        "show_generic_contact" => boolean_setting(:media_gallery_evidence_report_show_generic_contact, false),
        "show_privacy_legal_notice_url" => boolean_setting(:media_gallery_evidence_report_show_privacy_legal_notice_url, true),
        "show_policy_reference" => boolean_setting(:media_gallery_evidence_report_show_policy_reference, false),
        "show_controller_country" => boolean_setting(:media_gallery_evidence_report_show_controller_country, false),
      }
    end

    def site_base_url
      return nil unless defined?(Discourse) && Discourse.respond_to?(:base_url)

      Discourse.base_url.to_s.strip.sub(%r{/+\z}, "").presence
    rescue
      nil
    end

    def setting(name, max_length: nil)
      return nil unless SiteSetting.respond_to?(name)

      value = SiteSetting.public_send(name)
      text = ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length || 1000, allow_newlines: false).to_s.strip
      text.presence
    rescue
      nil
    end

    def boolean_setting(name, fallback)
      return fallback unless SiteSetting.respond_to?(name)

      ActiveModel::Type::Boolean.new.cast(SiteSetting.public_send(name))
    rescue
      fallback
    end

    def normalized_hosting_region(value)
      candidate = value.to_s
      HOSTING_REGIONS.include?(candidate) ? candidate : "unknown"
    end

    def normalized_date(value)
      return nil if value.to_s.strip.blank?

      Date.iso8601(value.to_s.strip).iso8601
    rescue Date::Error
      nil
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def sanitize(value, max_length)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: max_length, allow_newlines: true).to_s.strip.presence
    end
    private_class_method :normalized_hosting_region, :normalized_date, :truthy?, :sanitize
  end
end
