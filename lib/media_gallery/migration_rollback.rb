# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MigrationRollback
    module_function

    ROLLBACK_STATE_KEY = "migration_rollback"
    SWITCHABLE_ROLE_NAMES = %w[main thumbnail hls].freeze

    def rollback!(item, requested_by: nil, force: false)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?
      ::MediaGallery::OperationCoordinator.ensure_operation_allowed!(item, requested_operation: "rollback") unless force

      switch_state = ::MediaGallery::MigrationSwitch.switch_state_for(item)
      cleanup_state = ::MediaGallery::MigrationCleanup.cleanup_state_for(item)
      finalize_state = ::MediaGallery::MigrationFinalize.finalize_state_for(item)
      validate_rollback!(item, switch_state, cleanup_state, finalize_state, force: force)

      ::MediaGallery::OperationLogger.info("migration_rollback_started", item: item, operation: "rollback", data: { requested_by: requested_by, force: !!force })

      source_backend = switch_state["source_backend"].to_s
      source_profile_key = switch_state["source_profile_key"].to_s
      source_store = store_for_profile(profile_key: source_profile_key, backend: source_backend)
      raise "rollback_source_store_missing" if source_store.blank?

      source_store.ensure_available!
      verify_source_objects_available!(item, source_store)

      rollback_state = {
        "status" => "rolled_back",
        "rolled_back_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "source_backend" => source_backend,
        "source_profile_key" => source_profile_key,
        "target_backend" => item.managed_storage_backend.to_s,
        "target_profile_key" => item.managed_storage_profile.to_s,
        "last_error" => nil,
      }
      ::MediaGallery::OperationErrors.clear_failure!(rollback_state)

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[ROLLBACK_STATE_KEY] = rollback_state
      meta[::MediaGallery::MigrationSwitch::SWITCH_STATE_KEY] = switch_state.merge(
        "status" => "rolled_back",
        "rolled_back_at" => rollback_state["rolled_back_at"],
        "rolled_back_by" => requested_by.to_s.presence
      )

      item.storage_manifest = manifest_for_backend(item, source_backend)
      item.managed_storage_backend = source_backend
      item.managed_storage_profile = source_profile_key
      item.delivery_mode = delivery_mode_for_backend(source_backend)
      item.migration_state = "rolled_back" if item.respond_to?(:migration_state)
      item.migration_error = nil if item.respond_to?(:migration_error)
      item.extra_metadata = meta
      item.save!

      ::MediaGallery::OperationLogger.info("migration_rollback_completed", item: item, operation: "rollback", data: { source_profile_key: rollback_state["source_profile_key"], target_profile_key: rollback_state["target_profile_key"], requested_by: requested_by, force: !!force })

      rollback_state
    rescue => e
      state = rollback_state_for(item)
      state["status"] = "failed"
      state["rolled_back_at"] ||= Time.now.utc.iso8601
      ::MediaGallery::OperationErrors.apply_failure!(state, e, operation: "rollback")
      save_rollback_state!(item, state) if item&.persisted?
      ::MediaGallery::OperationLogger.error("migration_rollback_failed", item: item, operation: "rollback", data: { error: state["last_error"], error_code: state["last_error_code"], requested_by: requested_by, force: !!force })
      raise e
    end

    def rollback_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[ROLLBACK_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_rollback_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[ROLLBACK_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end

    def validate_rollback!(item, switch_state, cleanup_state, finalize_state, force: false)
      raise "switch_state_missing" unless switch_state.is_a?(Hash)

      allowed_statuses = %w[switched rolled_back]
      raise "rollback_not_available" unless allowed_statuses.include?(switch_state["status"].to_s)
      raise "rollback_source_profile_missing" if switch_state["source_profile_key"].to_s.blank?
      raise "rollback_source_backend_missing" if switch_state["source_backend"].to_s.blank?
      raise "rollback_source_already_cleaned" if cleanup_state["status"].to_s == "cleaned" && !force
      raise "rollback_not_available_after_finalize" if finalize_state["status"].to_s == "finalized" && !force

      if item.managed_storage_profile.to_s == switch_state["source_profile_key"].to_s &&
           item.managed_storage_backend.to_s == switch_state["source_backend"].to_s && !force
        raise "already_on_source_profile"
      end
      true
    end
    private_class_method :validate_rollback!

    def store_for_profile(profile_key:, backend:)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key.to_s)
      return store if store.present?

      ::MediaGallery::StorageSettingsResolver.build_store(backend.to_s)
    end
    private_class_method :store_for_profile

    def verify_source_objects_available!(item, source_store)
      missing = []
      objects = ::MediaGallery::MigrationPreview.objects_for_item(item, store: source_store)
      objects.each do |object|
        next if source_store.object_info(object[:key]).deep_symbolize_keys[:exists]

        missing << object[:key]
      end
      raise "rollback_source_missing:#{missing.first}" if missing.present?
      true
    end
    private_class_method :verify_source_objects_available!

    def manifest_for_backend(item, backend)
      roles = {}
      SWITCHABLE_ROLE_NAMES.each do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?

        updated = role.deep_dup
        updated["backend"] = backend.to_s
        roles[role_name] = updated
      end

      {
        "schema_version" => ::MediaGallery::AssetManifest::SCHEMA_VERSION,
        "public_id" => item.public_id.to_s,
        "generated_at" => Time.now.utc.iso8601,
        "roles" => roles,
      }
    end
    private_class_method :manifest_for_backend

    def delivery_mode_for_backend(backend)
      if backend.to_s == "s3"
        ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect" ? "s3_redirect" : "s3_proxy"
      else
        mode = ::MediaGallery::StorageSettingsResolver.default_delivery_mode
        mode == "x_accel" ? "x_accel" : "local_stream"
      end
    end
    private_class_method :delivery_mode_for_backend
  end
end
