# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MigrationSwitch
    module_function

    SWITCH_STATE_KEY = "migration_switch"
    SWITCHABLE_ROLE_NAMES = %w[main thumbnail hls].freeze

    def switch!(item, target_profile: "target", requested_by: nil, mode: "manual", auto_cleanup: false)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      plan = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      validate_plan_for_switch!(plan)

      target = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      source = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      target_backend = target[:backend].to_s
      target_profile_key = target[:profile_key].to_s

      manifest = switched_manifest_for(item, target_backend)
      switched_at = Time.now.utc.iso8601
      switch_state = {
        "status" => "switched",
        "mode" => mode.to_s,
        "requested_by" => requested_by.to_s.presence,
        "switched_at" => switched_at,
        "source_backend" => source[:backend].to_s,
        "source_profile" => source[:profile].to_s,
        "source_profile_key" => source[:profile_key].to_s,
        "source_location_fingerprint" => stringify_fingerprint(::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(source[:profile_key].to_s)),
        "target_backend" => target_backend,
        "target_profile" => target[:profile].to_s,
        "target_profile_key" => target_profile_key,
        "target_location_fingerprint" => stringify_fingerprint(::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(target_profile_key)),
        "object_count" => (plan.dig(:totals, :object_count) || plan.dig("totals", "object_count") || 0).to_i,
        "source_bytes" => (plan.dig(:totals, :source_bytes) || plan.dig("totals", "source_bytes") || 0).to_i,
        "verification_missing_on_target_count" => (plan.dig(:totals, :missing_on_target_count) || plan.dig("totals", "missing_on_target_count") || 0).to_i,
        "warnings" => Array(plan[:warnings] || plan["warnings"]),
        "auto_cleanup" => !!auto_cleanup
      }

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[SWITCH_STATE_KEY] = switch_state
      meta.delete(::MediaGallery::MigrationCleanup::CLEANUP_STATE_KEY)

      item.storage_manifest = manifest
      item.managed_storage_backend = target_backend
      item.managed_storage_profile = target_profile_key
      item.delivery_mode = delivery_mode_for_backend(target_backend)
      item.migration_state = "switched" if item.respond_to?(:migration_state)
      item.migration_error = nil if item.respond_to?(:migration_error)
      item.extra_metadata = meta
      item.save!

      if auto_cleanup
        cleanup_state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: requested_by, force: false)
        switch_state["cleanup_enqueued_at"] = cleanup_state["queued_at"] if cleanup_state.is_a?(Hash)
        meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
        meta[SWITCH_STATE_KEY] = switch_state
        item.update_columns(extra_metadata: meta, updated_at: Time.now)
      end

      switch_state
    end


    def stringify_fingerprint(value)
      return nil if value.blank?

      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = stringify_fingerprint(v)
        end
      when Array
        value.map { |v| stringify_fingerprint(v) }
      else
        value
      end
    end
    private_class_method :stringify_fingerprint

    def switch_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[SWITCH_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def validate_plan_for_switch!(plan)
      raise "migration_plan_missing" unless plan.is_a?(Hash)
      target = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      source = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      raise "target_profile_not_configured" if target[:backend].to_s.blank?
      raise "source_and_target_same_profile" if source[:profile_key].present? && source[:profile_key] == target[:profile_key]

      warnings = Array(plan[:warnings] || plan["warnings"]).map(&:to_s)
      unsupported = warnings.find do |w|
        w.include?("upload") ||
          w == "source_store_unavailable" ||
          w == "target_store_missing" ||
          w == "hls_role_has_no_objects_on_source"
      end
      raise(unsupported) if unsupported.present?

      missing = (plan.dig(:totals, :missing_on_target_count) || plan.dig("totals", "missing_on_target_count") || 0).to_i
      raise "target_not_fully_copied" if missing.positive?
      true
    end
    private_class_method :validate_plan_for_switch!

    def switched_manifest_for(item, target_backend)
      roles = {}
      SWITCHABLE_ROLE_NAMES.each do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?
        role = role.deep_dup
        raise "unsupported_upload_role:#{role_name}" if role["backend"].to_s == "upload"
        role["backend"] = target_backend.to_s
        roles[role_name] = role
      end

      {
        "schema_version" => ::MediaGallery::AssetManifest::SCHEMA_VERSION,
        "public_id" => item.public_id.to_s,
        "generated_at" => Time.now.utc.iso8601,
        "roles" => roles
      }
    end
    private_class_method :switched_manifest_for

    def delivery_mode_for_backend(backend)
      if backend.to_s == "s3"
        "s3_redirect"
      else
        mode = ::MediaGallery::StorageSettingsResolver.default_delivery_mode
        mode == "x_accel" ? "x_accel" : "local_stream"
      end
    end
    private_class_method :delivery_mode_for_backend
  end
end
