# frozen_string_literal: true

require "fileutils"
require "time"
require "securerandom"

module ::MediaGallery
  # Repackage existing ready video items into AES-128 HLS without rerunning the
  # full media processing pipeline. This is intentionally conservative: it only
  # works when HLS + AES-128 are enabled and a processed video source can be
  # acquired from the current media role.
  module HlsAes128Backfill
    module_function

    STATE_KEY = "hls_aes128_backfill"
    STATUSES_IN_PROGRESS = %w[queued processing].freeze

    def enqueue_item!(item, requested_by:, force: false)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?
      validate_backfill_preconditions!(item, force: force, allow_already_ready: true)

      run_token = SecureRandom.hex(16)
      state = mark_queued!(item, requested_by: requested_by, force: force, run_token: run_token)
      enqueue_backfill_job!(item, requested_by: requested_by, force: force, run_token: run_token)
      state
    end

    def restart_item!(item, requested_by:)
      enqueue_item!(item, requested_by: requested_by, force: true)
    end

    def clear_state!(item, requested_by:, reason: nil)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?

      update_state!(item) do |state|
        now = Time.now.utc.iso8601
        state.merge(
          "status" => "cancelled",
          "cancelled_at" => now,
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

        unless job_token_current?(current_state, run_token)
          return current_state
        end

        if current_state["status"].to_s == "cancelled" && !force
          return current_state
        end

        ::MediaGallery::OperationLogger.info(
          "hls_aes128_backfill_job_started",
          item: item,
          operation: "hls_aes128_backfill",
          data: { requested_by: requested_by.to_s.presence, force: !!force, run_token_present: run_token.to_s.present? }
        ) if defined?(::MediaGallery::OperationLogger)

        if aes_ready?(item) && !force
          return mark_skipped!(item, reason: "already_aes_ready", requested_by: requested_by, force: force)
        end

        validate_backfill_preconditions!(item, force: force, allow_already_ready: false)
        mark_processing!(item, requested_by: requested_by, force: force, run_token: current_state["run_token"].presence || run_token)

        result = nil
        ::MediaGallery::ProcessingWorkspace.open do |workspace|
          input_path = acquire_processed_video!(item, workspace: workspace)
          store = target_hls_store_for(item)
          raise "hls_aes128_backfill_store_unavailable" if store.blank?

          hls_meta = ::MediaGallery::Hls.package_video!(item, input_path: input_path, workspace: workspace)
          raise "hls_aes128_backfill_package_failed" if hls_meta.blank?
          raise "hls_aes128_backfill_package_not_encrypted" unless hls_meta.dig("encryption", "method").to_s.casecmp("AES-128").zero?

          hls_role = ::MediaGallery::Hls.publish_packaged_video!(item, store: store, hls_meta: hls_meta)
          persist_hls_role_and_meta!(item, hls_role: hls_role, hls_meta: hls_meta)
          result = mark_succeeded!(item, requested_by: requested_by, force: force, hls_role: hls_role, hls_meta: hls_meta)
          ::MediaGallery::OperationLogger.info(
            "hls_aes128_backfill_job_succeeded",
            item: item,
            operation: "hls_aes128_backfill",
            data: { requested_by: requested_by.to_s.presence, force: !!force, key_id: result["key_id"].to_s.presence, scheme: result["scheme"].to_s.presence }
          ) if defined?(::MediaGallery::OperationLogger)
        end

        result
      end
    rescue => e
      mark_failed!(item, error: e, requested_by: requested_by, force: force) if item&.persisted?
      raise e
    end

    def enqueue_backfill_job!(item, requested_by:, force: false, run_token: nil)
      unless defined?(::Jobs::MediaGalleryHlsAes128BackfillItem)
        raise "hls_aes128_backfill_job_not_loaded"
      end

      job_id = ::Jobs.enqueue(
        :media_gallery_hls_aes128_backfill_item,
        media_item_id: item.id,
        requested_by: requested_by.to_s,
        force: !!force,
        run_token: run_token.to_s.presence
      )

      update_state!(item) do |state|
        state.merge(
          "job_enqueued_at" => Time.now.utc.iso8601,
          "job_class" => "Jobs::MediaGalleryHlsAes128BackfillItem",
          "job_name" => "media_gallery_hls_aes128_backfill_item",
          "job_id" => job_id.to_s.presence,
        )
      end

      ::MediaGallery::OperationLogger.info(
        "hls_aes128_backfill_job_enqueued",
        item: item,
        operation: "hls_aes128_backfill",
        data: { requested_by: requested_by.to_s, force: !!force, run_token_present: run_token.to_s.present?, job_id: job_id.to_s.presence }
      ) if defined?(::MediaGallery::OperationLogger)

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

      status = state["status"].to_s
      case status
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

    def stale?(item)
      stale_state?(state_for(item))
    end

    def eligible?(item, force: false)
      validate_backfill_preconditions!(item, force: force, allow_already_ready: true)
      true
    rescue
      false
    end

    def bulk_limit
      value = if SiteSetting.respond_to?(:media_gallery_hls_aes128_backfill_bulk_limit)
        SiteSetting.media_gallery_hls_aes128_backfill_bulk_limit.to_i
      else
        10
      end
      value = 10 if value <= 0
      [[value, 1].max, 100].min
    rescue
      10
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

    def validate_backfill_preconditions!(item, force: false, allow_already_ready: false)
      raise "hls_disabled" unless ::MediaGallery::Hls.enabled?
      raise "hls_aes128_disabled" unless ::MediaGallery::Hls.aes128_enabled?
      raise "managed_storage_disabled" unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?
      raise "media_item_not_ready" unless item&.ready?
      raise "media_item_not_video" unless item&.media_type.to_s == "video"

      hls_role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      raise "hls_role_missing" unless hls_role.is_a?(Hash)
      raise "hls_not_ready" unless ::MediaGallery::Hls.ready?(item)

      if aes_ready?(item) && !force && !allow_already_ready
        raise "hls_aes128_already_ready"
      end

      if in_progress?(item) && !force
        raise "hls_aes128_backfill_already_queued"
      end

      true
    end

    def aes_ready?(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      ::MediaGallery::Hls.aes128_ready?(item, role: role)
    rescue
      false
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
        now = Time.now.utc.iso8601
        state.merge(
          "status" => "processing",
          "started_at" => now,
          "started_by" => requested_by.to_s.presence,
          "force" => !!force,
          "attempt_count" => state["attempt_count"].to_i + 1,
          "run_token" => run_token.to_s.presence || state["run_token"].to_s.presence,
        ).except("last_error", "last_error_class", "failed_at", "cancelled_at", "cancelled_by", "cancel_reason")
      end
    end

    def mark_succeeded!(item, requested_by:, force:, hls_role:, hls_meta:)
      update_state!(item) do |state|
        encryption = hls_meta.is_a?(Hash) ? hls_meta["encryption"] : nil
        state.merge(
          "status" => "ready",
          "finished_at" => Time.now.utc.iso8601,
          "finished_by" => requested_by.to_s.presence,
          "force" => !!force,
          "key_id" => encryption.is_a?(Hash) ? encryption["key_id"].to_s.presence : nil,
          "scheme" => encryption.is_a?(Hash) ? encryption["scheme"].to_s.presence : nil,
          "role_backend" => hls_role.is_a?(Hash) ? hls_role["backend"].to_s.presence : nil,
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
      Rails.logger.warn("[media_gallery] AES backfill failure state update failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
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

    def acquire_processed_video!(item, workspace:)
      dest = workspace.path("hls-aes128-source-#{item.public_id}.mp4")
      role = ::MediaGallery::AssetManifest.role_for(item, "main")
      role = role.deep_stringify_keys if role.is_a?(Hash)

      if role.is_a?(Hash) && %w[local s3].include?(role["backend"].to_s) && role["key"].present?
        store = store_for_role(item, role)
        raise "processed_store_unavailable" if store.blank?
        store.download_to_file!(role["key"].to_s, dest)
        raise "processed_download_missing" unless File.exist?(dest) && File.size(dest).positive?
        return dest
      end

      if item.processed_upload.present?
        return ::MediaGallery::SourceAcquirer.new.acquire!(upload: item.processed_upload, workspace: workspace)
      end

      raise "processed_source_unavailable"
    end

    def target_hls_store_for(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      store = ::MediaGallery::Hls.store_for_managed_role(item, role) if role.is_a?(Hash)
      return store if store.present?

      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) if profile_key.present?
      store || ::MediaGallery::StorageSettingsResolver.build_store
    end

    def store_for_role(item, role)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"].to_s)
      return nil if store.blank?
      return nil if role["backend"].to_s.present? && store.backend.to_s != role["backend"].to_s

      store
    end

    def persist_hls_role_and_meta!(item, hls_role:, hls_meta:)
      manifest = item.storage_manifest_hash.deep_dup
      manifest = { "roles" => {} } unless manifest.is_a?(Hash)
      manifest["schema_version"] = ::MediaGallery::AssetManifest::SCHEMA_VERSION
      manifest["public_id"] = item.public_id.to_s
      manifest["generated_at"] = Time.now.utc.iso8601
      manifest["roles"] ||= {}
      manifest["roles"]["hls"] = hls_role.deep_stringify_keys

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta["hls"] = sanitized_hls_meta_for_storage(hls_meta)
      meta.delete("hls_error")

      item.storage_manifest = manifest
      item.extra_metadata = meta
      item.save!
    end

    def sanitized_hls_meta_for_storage(hls_meta)
      hls_meta = hls_meta.deep_stringify_keys
      hls_meta.except("build_root", "cleanup_build_root_after_publish")
    rescue
      hls_meta
    end

    def with_item_mutex(item, &blk)
      name = "media_gallery_hls_aes128_backfill_#{item.id}"
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(name, validity: 2.hours, &blk)
      else
        yield
      end
    end
  end
end
