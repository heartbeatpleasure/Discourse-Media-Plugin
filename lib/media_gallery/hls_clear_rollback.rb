# frozen_string_literal: true

require "securerandom"
require "time"

module ::MediaGallery
  # Admin-only repackage path from AES-HLS back to normal/clear HLS.
  # This is deliberately implemented as a background job because FFmpeg packaging
  # can take a while. The operation does not delete media segments directly; it
  # atomically publishes a newly packaged non-AES HLS role and then deactivates
  # old AES key records so the item is treated as legacy/clear HLS again.
  module HlsClearRollback
    module_function

    STATE_KEY = "hls_clear_rollback"
    STATUSES_IN_PROGRESS = %w[queued processing].freeze

    def enqueue_item!(item, requested_by:, force: false)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?
      validate_preconditions!(item, force: force, allow_already_clear: true)

      run_token = SecureRandom.hex(16)
      state = mark_queued!(item, requested_by: requested_by, force: force, run_token: run_token)
      enqueue_job!(item, requested_by: requested_by, force: force, run_token: run_token)
      state
    end

    def restart_item!(item, requested_by:)
      enqueue_item!(item, requested_by: requested_by, force: true)
    end

    def clear_state!(item, requested_by:, reason: nil)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?

      update_state!(item) do |state|
        state.merge(
          "status" => "cancelled",
          "cancelled_at" => Time.now.utc.iso8601,
          "cancelled_by" => requested_by.to_s.presence,
          "cancel_reason" => reason.to_s.presence,
        ).except("last_error", "last_error_class", "failed_at")
      end
    end

    def perform_item!(item, requested_by: nil, force: false, run_token: nil)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?

      with_item_mutex(item) do
        item.reload
        current_state = state_for(item)
        return current_state unless job_token_current?(current_state, run_token)
        return current_state if current_state["status"].to_s == "cancelled" && !force

        log_info("hls_clear_rollback_job_started", item: item, requested_by: requested_by, force: force)

        if clear_hls?(item) && !force
          return mark_skipped!(item, reason: "already_clear_hls", requested_by: requested_by, force: force)
        end

        validate_preconditions!(item, force: force, allow_already_clear: false, allow_in_progress: true)
        processing_state = mark_processing!(item, requested_by: requested_by, force: force, run_token: current_state["run_token"].presence || run_token)
        append_management_log!(item, action: "hls_clear_rollback_processing", requested_by: requested_by, changes: { "hls_clear_rollback" => [current_state["status"], processing_state["status"]] })

        result = nil
        ::MediaGallery::ProcessingWorkspace.open do |workspace|
          input_path = ::MediaGallery::HlsAes128Backfill.acquire_processed_video!(item, workspace: workspace)
          store = ::MediaGallery::HlsAes128Backfill.target_hls_store_for(item)
          raise "hls_clear_rollback_store_unavailable" if store.blank?

          hls_meta = ::MediaGallery::Hls.package_video!(item, input_path: input_path, workspace: workspace, aes128: false)
          raise "hls_clear_rollback_package_failed" if hls_meta.blank?
          if hls_meta.dig("encryption", "method").to_s.casecmp("AES-128").zero?
            raise "hls_clear_rollback_package_still_encrypted"
          end

          hls_role = ::MediaGallery::Hls.publish_packaged_video!(item, store: store, hls_meta: hls_meta)
          if hls_role.is_a?(Hash) && hls_role["encryption"].present?
            raise "hls_clear_rollback_role_still_encrypted"
          end

          ::MediaGallery::HlsAes128Backfill.persist_hls_role_and_meta!(item, hls_role: hls_role, hls_meta: hls_meta)
          deactivated_keys = deactivate_aes_key_records!(item)
          result = mark_succeeded!(item, requested_by: requested_by, force: force, hls_role: hls_role, hls_meta: hls_meta, deactivated_keys: deactivated_keys)
          append_management_log!(item, action: "hls_clear_rollback_succeeded", requested_by: requested_by, changes: { "hls_clear_rollback" => ["processing", result["status"]], "hls_aes128" => ["encrypted", "clear_hls"] })
          log_info("hls_clear_rollback_job_succeeded", item: item, requested_by: requested_by, force: force, data: { deactivated_keys: deactivated_keys })
        end

        result
      end
    rescue => e
      if item&.persisted?
        failed_state = mark_failed!(item, error: e, requested_by: requested_by, force: force)
        append_management_log!(item, action: "hls_clear_rollback_failed", requested_by: requested_by, changes: { "hls_clear_rollback" => ["processing", failed_state&.dig("status") || "failed"], "error" => [nil, e.message.to_s.truncate(500)] })
      end
      raise e
    end

    def enqueue_job!(item, requested_by:, force: false, run_token: nil)
      unless defined?(::Jobs::MediaGalleryHlsClearRollbackItem)
        raise "hls_clear_rollback_job_not_loaded"
      end

      job_id = ::Jobs.enqueue(
        :media_gallery_hls_clear_rollback_item,
        media_item_id: item.id,
        requested_by: requested_by.to_s,
        force: !!force,
        run_token: run_token.to_s.presence
      )

      update_state!(item) do |state|
        state.merge(
          "job_enqueued_at" => Time.now.utc.iso8601,
          "job_class" => "Jobs::MediaGalleryHlsClearRollbackItem",
          "job_name" => "media_gallery_hls_clear_rollback_item",
          "job_id" => job_id.to_s.presence,
        )
      end

      log_info("hls_clear_rollback_job_enqueued", item: item, requested_by: requested_by, force: force, data: { job_id: job_id.to_s.presence })
      job_id
    rescue => e
      mark_failed!(item, error: e, requested_by: requested_by, force: force) if item&.persisted?
      raise e
    end

    def state_for(item)
      meta = item&.extra_metadata
      state = meta.is_a?(Hash) ? meta[STATE_KEY] : nil
      state.is_a?(Hash) ? state.deep_dup : {}
    rescue
      {}
    end

    def in_progress?(item)
      STATUSES_IN_PROGRESS.include?(state_for(item)["status"].to_s)
    end

    def stale_state?(state)
      return false unless state.is_a?(Hash)

      case state["status"].to_s
      when "queued"
        timestamp_stale?(state["queued_at"], 15.minutes.ago)
      when "processing"
        timestamp_stale?(state["started_at"], 4.hours.ago)
      else
        false
      end
    rescue
      false
    end

    def clear_hls?(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      role.is_a?(Hash) && ::MediaGallery::Hls.aes128_encryption_meta_for(item, role: role).blank?
    rescue
      false
    end

    def validate_preconditions!(item, force: false, allow_already_clear: false, allow_in_progress: false)
      raise "hls_disabled" unless ::MediaGallery::Hls.enabled?
      raise "managed_storage_disabled" unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?
      raise "media_item_not_ready" unless item&.ready?
      raise "media_item_not_video" unless item&.media_type.to_s == "video"
      raise "hls_aes128_required_enabled" if ::MediaGallery::Hls.aes128_required?

      hls_role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      raise "hls_role_missing" unless hls_role.is_a?(Hash)
      raise "hls_not_ready" unless ::MediaGallery::Hls.ready?(item)

      if clear_hls?(item) && !force && !allow_already_clear
        raise "hls_clear_rollback_already_clear"
      end

      if in_progress?(item) && !force && !allow_in_progress
        raise "hls_clear_rollback_already_queued"
      end

      true
    end

    def deactivate_aes_key_records!(item)
      return 0 unless defined?(::MediaGallery::HlsAes128Key) && ::MediaGallery::HlsAes128Key.table_exists?

      now = Time.now
      ::MediaGallery::HlsAes128Key.where(media_item_id: item.id, active: true).update_all(active: false, updated_at: now)
    rescue => e
      Rails.logger.warn("[media_gallery] clear HLS rollback AES key deactivation failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      0
    end

    def mark_queued!(item, requested_by:, force: false, run_token: nil)
      update_state!(item) do |state|
        now = Time.now.utc.iso8601
        state.merge(
          "status" => "queued",
          "queued_at" => now,
          "queued_by" => requested_by.to_s.presence,
          "force" => !!force,
          "attempt_count" => state["attempt_count"].to_i,
          "run_token" => run_token.to_s.presence || state["run_token"].to_s.presence,
        ).except("last_error", "last_error_class", "failed_at", "cancelled_at", "cancelled_by", "cancel_reason")
      end
    end

    def mark_processing!(item, requested_by:, force: false, run_token: nil)
      update_state!(item) do |state|
        state.merge(
          "status" => "processing",
          "started_at" => Time.now.utc.iso8601,
          "started_by" => requested_by.to_s.presence,
          "force" => !!force,
          "attempt_count" => state["attempt_count"].to_i + 1,
          "run_token" => run_token.to_s.presence || state["run_token"].to_s.presence,
        ).except("last_error", "last_error_class", "failed_at", "cancelled_at", "cancelled_by", "cancel_reason")
      end
    end

    def mark_succeeded!(item, requested_by:, force:, hls_role:, hls_meta:, deactivated_keys: 0)
      update_state!(item) do |state|
        state.merge(
          "status" => "ready",
          "finished_at" => Time.now.utc.iso8601,
          "finished_by" => requested_by.to_s.presence,
          "force" => !!force,
          "role_backend" => hls_role.is_a?(Hash) ? hls_role["backend"].to_s.presence : nil,
          "deactivated_aes_keys" => deactivated_keys.to_i,
          "segment_duration_seconds" => hls_meta.is_a?(Hash) ? hls_meta["segment_duration_seconds"].to_i : nil,
        ).compact.except("last_error", "last_error_class", "failed_at", "run_token")
      end
    end

    def mark_skipped!(item, reason:, requested_by:, force: false)
      update_state!(item) do |state|
        state.merge(
          "status" => "skipped",
          "reason" => reason.to_s,
          "finished_at" => Time.now.utc.iso8601,
          "finished_by" => requested_by.to_s.presence,
          "force" => !!force,
        ).compact
      end
    end

    def mark_failed!(item, error:, requested_by:, force: false)
      update_state!(item) do |state|
        state.merge(
          "status" => "failed",
          "failed_at" => Time.now.utc.iso8601,
          "failed_by" => requested_by.to_s.presence,
          "force" => !!force,
          "last_error_class" => error.class.to_s,
          "last_error" => error.message.to_s.truncate(1000),
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] clear HLS rollback failure state update failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def update_state!(item)
      item.reload
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      current = meta[STATE_KEY].is_a?(Hash) ? meta[STATE_KEY].deep_dup : {}
      next_state = yield(current)
      meta[STATE_KEY] = next_state.compact
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      next_state.compact
    end

    def job_token_current?(state, run_token)
      token = run_token.to_s.presence
      return true if token.blank?

      state_token = state.is_a?(Hash) ? state["run_token"].to_s.presence : nil
      return false if state_token.blank?
      return false unless state_token == token

      STATUSES_IN_PROGRESS.include?(state["status"].to_s)
    end

    def timestamp_stale?(value, threshold)
      return false if value.blank?
      Time.iso8601(value.to_s) < threshold
    rescue ArgumentError, TypeError
      false
    end

    def append_management_log!(item, action:, requested_by:, changes: nil, note: nil)
      item.reload
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      log = meta["admin_management_log"]
      log = [] unless log.is_a?(Array)

      entry = {
        "action" => action.to_s,
        "at" => Time.now.utc.iso8601,
        "admin_username" => requested_by.to_s.presence || "system",
        "admin_user_id" => nil,
        "public_id" => item.public_id.to_s,
      }
      entry["note"] = note.to_s if note.to_s.present?
      entry["changes"] = changes.deep_stringify_keys if changes.is_a?(Hash) && changes.present?

      log.unshift(entry)
      meta["admin_management_log"] = log.first(50)
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    rescue => e
      Rails.logger.warn("[media_gallery] clear HLS rollback management history update failed item_id=#{item&.id} action=#{action} error=#{e.class}: #{e.message}")
      nil
    end

    def with_item_mutex(item, &blk)
      name = "media_gallery_hls_clear_rollback_#{item.id}"
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(name, validity: 2.hours, &blk)
      else
        yield
      end
    end

    def log_info(event, item:, requested_by:, force:, data: {})
      return unless defined?(::MediaGallery::OperationLogger)

      ::MediaGallery::OperationLogger.info(
        event,
        item: item,
        operation: "hls_clear_rollback",
        data: { requested_by: requested_by.to_s.presence, force: !!force }.merge(data || {})
      )
    rescue
      nil
    end
  end
end
