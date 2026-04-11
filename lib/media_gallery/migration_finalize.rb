# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MigrationFinalize
    module_function

    FINALIZE_STATE_KEY = "migration_finalize"

    def finalize!(item, requested_by: nil, force: false)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      cleanup_state = ::MediaGallery::MigrationCleanup.cleanup_state_for(item)
      rollback_state = ::MediaGallery::MigrationRollback.rollback_state_for(item)

      if rollback_state["status"].to_s == "rolled_back"
        return finalize_after_rollback!(item, cleanup_state: cleanup_state, rollback_state: rollback_state, requested_by: requested_by, force: force)
      end

      if cleanup_state["status"].to_s != "cleaned"
        cleanup_state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: requested_by, force: force)
        state = {
          "status" => "pending_cleanup",
          "requested_by" => requested_by.to_s.presence,
          "queued_at" => cleanup_state["queued_at"] || Time.now.utc.iso8601,
          "last_error" => nil,
        }
        save_finalize_state!(item, state)
        return state
      end

      state = {
        "status" => "finalized",
        "finalize_mode" => "switched",
        "requested_by" => requested_by.to_s.presence,
        "finalized_at" => Time.now.utc.iso8601,
        "cleaned_at" => cleanup_state["cleaned_at"],
        "source_profile_key" => cleanup_state["source_profile_key"],
        "target_profile_key" => cleanup_state["target_profile_key"],
        "last_error" => nil,
      }

      persist_finalized_state!(item, state, requested_by: requested_by, reason: "finalized")
      state
    rescue => e
      state = finalize_state_for(item)
      state["status"] = "failed"
      state["last_error"] = "#{e.class}: #{e.message}"
      state["updated_at"] = Time.now.utc.iso8601
      save_finalize_state!(item, state) if item&.persisted?
      raise e
    end

    def finalize_after_rollback!(item, cleanup_state:, rollback_state:, requested_by:, force: false)
      cleanup_status = cleanup_state["status"].to_s
      if %w[queued cleaning].include?(cleanup_status) && !force
        state = {
          "status" => "pending_cleanup",
          "finalize_mode" => "rolled_back",
          "requested_by" => requested_by.to_s.presence,
          "queued_at" => cleanup_state["queued_at"] || cleanup_state["started_at"] || Time.now.utc.iso8601,
          "cleanup_status" => cleanup_status,
          "last_error" => nil,
        }
        save_finalize_state!(item, state)
        return state
      end

      state = {
        "status" => "finalized",
        "finalize_mode" => "rolled_back",
        "requested_by" => requested_by.to_s.presence,
        "finalized_at" => Time.now.utc.iso8601,
        "rolled_back_at" => rollback_state["rolled_back_at"],
        "cleanup_status" => cleanup_status.presence || "not_run",
        "source_profile_key" => rollback_state["source_profile_key"],
        "target_profile_key" => rollback_state["target_profile_key"],
        "cleaned_at" => cleanup_state["cleaned_at"],
        "last_error" => nil,
      }

      persist_finalized_state!(item, state, requested_by: requested_by, reason: "finalized_after_rollback")
      state
    end
    private_class_method :finalize_after_rollback!

    def persist_finalized_state!(item, state, requested_by:, reason:)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[FINALIZE_STATE_KEY] = state
      attrs = { extra_metadata: meta, updated_at: Time.now }
      if item.respond_to?(:migration_state)
        attrs[:migration_state] = "finalized"
      end
      attrs[:migration_error] = nil if item.respond_to?(:migration_error)
      item.update_columns(attrs)
      ::MediaGallery::MigrationRunHistory.archive_current_cycle!(
        item,
        archived_by: requested_by,
        reason: reason
      )
    end
    private_class_method :persist_finalized_state!

    def finalize_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[FINALIZE_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_finalize_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[FINALIZE_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end
  end
end
