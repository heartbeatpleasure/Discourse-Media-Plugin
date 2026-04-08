# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MigrationVerify
    module_function

    VERIFY_STATE_KEY = "migration_verify"

    def verify!(item, target_profile: "target", requested_by: nil)
      raise "media_item_required" if item.blank?

      plan = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      totals = (plan[:totals] || plan["totals"] || {}).deep_symbolize_keys
      source = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      target = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      warnings = Array(plan[:warnings] || plan["warnings"]).map(&:to_s)
      missing = totals[:missing_on_target_count].to_i
      same_profile = source[:profile_key].present? && source[:profile_key].to_s == target[:profile_key].to_s

      status = if target[:backend].to_s.blank?
        "not_configured"
      elsif same_profile
        "same_profile"
      elsif missing.zero?
        "verified"
      else
        "incomplete"
      end

      state = {
        "status" => status,
        "verified_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "target_profile" => target_profile.to_s,
        "source_profile_key" => source[:profile_key].to_s,
        "target_profile_key" => target[:profile_key].to_s,
        "source_backend" => source[:backend].to_s,
        "target_backend" => target[:backend].to_s,
        "object_count" => totals[:object_count].to_i,
        "target_existing_count" => totals[:target_existing_count].to_i,
        "missing_on_target_count" => missing,
        "warnings" => warnings,
        "last_error" => nil,
      }

      save_verify_state!(item, state)
      { ok: status == "verified", public_id: item.public_id, verification: state, plan: plan }
    rescue => e
      state = {
        "status" => "failed",
        "verified_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "last_error" => "#{e.class}: #{e.message}",
      }
      save_verify_state!(item, state) if item&.persisted?
      raise e
    end

    def verify_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[VERIFY_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_verify_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[VERIFY_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end
  end
end
