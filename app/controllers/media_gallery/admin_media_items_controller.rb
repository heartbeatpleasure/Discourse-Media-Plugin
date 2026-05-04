# frozen_string_literal: true

require "digest"
require "json"
require "set"

module ::MediaGallery
  # Admin-only helper endpoints.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    MANAGEMENT_LOG_KEY = "admin_management_log"
    VISIBILITY_KEY = "admin_visibility"
    MAX_MANAGEMENT_LOG_ENTRIES = 50

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    def search
      candidates = filtered_search_scope.limit(search_candidate_limit).to_a
      active_key_ids_by_item = hls_aes128_active_key_ids_by_item(candidates)

      items = []
      candidates.each do |item|
        has_hls = ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash)
        next if has_hls_filter == "true" && !has_hls
        next if has_hls_filter == "false" && has_hls

        aes_status = hls_aes128_status_for(item, has_hls: has_hls, active_key_ids_by_item: active_key_ids_by_item)
        next unless hls_aes128_filter_matches?(aes_status, hls_aes128_filter)

        items << serialize_search_item(item, has_hls: has_hls, hls_aes128_status: aes_status)
        break if items.length >= search_limit
      end

      render_json_dump(items: items, search_profiles: search_profiles_summary)
    end

    # GET /admin/plugins/media-gallery/media-items/:public_id/management.json
    def management
      item = load_item!
      render_json_dump(management_item_payload(item))
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # PUT /admin/plugins/media-gallery/media-items/:public_id/admin-update.json
    def admin_update
      item = load_item!
      title = ::MediaGallery::TextSanitizer.plain_text(params[:title], max_length: 200, allow_newlines: false)
      return render_json_error("title_required", status: 422) if title.blank?

      subject = params[:gender].to_s.strip
      return render_json_error("gender_required", status: 422) if subject.blank?
      return render_json_error("invalid_gender", status: 422) unless ::MediaGallery::MediaItem::GENDERS.include?(subject)

      description = ::MediaGallery::TextSanitizer.plain_text(params[:description], max_length: 4000, allow_newlines: true)
      tags = normalize_tags_param(params[:tags])
      note = ::MediaGallery::TextSanitizer.plain_text(params[:admin_note], max_length: 2000, allow_newlines: true).presence

      changes = {}
      changes["title"] = [item.title, title] if item.title.to_s != title
      changes["description"] = [item.description.to_s, description] if item.description.to_s != description
      changes["gender"] = [item.gender.to_s, subject] if item.gender.to_s != subject
      changes["tags"] = [Array(item.tags).map(&:to_s), tags] if Array(item.tags).map(&:to_s) != tags

      if changes.blank? && note.blank?
        return render_json_dump(ok: true, item: management_item_payload(item), message: "No changes to save.")
      end

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      append_management_log!(
        meta,
        action: changes.present? ? "update_metadata" : "admin_note",
        item: item,
        note: note,
        changes: changes.presence
      )

      item.update!(
        title: title,
        description: description.presence,
        gender: subject,
        tags: tags,
        extra_metadata: meta,
      )

      item.reload
      ::MediaGallery::OperationLogger.info("admin_management_update", item: item, operation: "save", data: { changed_fields: changes.keys, note_present: note.present? })
      render_json_dump(ok: true, item: management_item_payload(item), message: "Item updated.")
    rescue ActiveRecord::RecordInvalid => e
      render_operation_error(e, operation: "save", item: item, status: 422, extra: { details: e.record.errors.full_messages })
    rescue => e
      render_operation_error(e, operation: "save", item: item, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/visibility.json
    def visibility
      item = load_item!
      hidden = boolean_param(:hidden)
      note = ::MediaGallery::TextSanitizer.plain_text(params[:admin_note], max_length: 2000, allow_newlines: true).presence
      reason = params[:reason].to_s.strip.presence || note
      now = Time.now.utc.iso8601

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      visibility = admin_visibility_hash_from_meta(meta)

      visibility["hidden"] = hidden
      visibility["updated_at"] = now
      visibility["updated_by"] = current_user.username
      visibility["reason"] = reason

      if hidden
        visibility["hidden_at"] = now
        visibility["hidden_by"] = current_user.username
      else
        visibility["hidden"] = false
        visibility["unhidden_at"] = now
        visibility["unhidden_by"] = current_user.username
      end

      visibility_changes = { "hidden" => [item.admin_hidden?, hidden] }
      previous_reason = item.admin_visibility_state["reason"].to_s.presence
      if previous_reason != reason
        visibility_changes["reason"] = [previous_reason, reason]
      end

      meta[VISIBILITY_KEY] = visibility
      append_management_log!(
        meta,
        action: hidden ? "hide" : "unhide",
        item: item,
        note: note,
        changes: visibility_changes
      )

      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      item.reload
      ::MediaGallery::OperationLogger.info("admin_visibility_changed", item: item, operation: "visibility", data: { hidden: hidden, reason: reason, note_present: note.present? })
      render_json_dump(ok: true, item: management_item_payload(item), message: hidden ? "Item hidden." : "Item visible again.")
    rescue => e
      render_operation_error(e, operation: "visibility", item: item, status: 422)
    end

    # DELETE /admin/plugins/media-gallery/media-items/:public_id/admin-destroy.json
    def admin_destroy
      item = load_item!
      note = ::MediaGallery::TextSanitizer.plain_text(params[:admin_note], max_length: 2000, allow_newlines: true).presence
      public_id = item.public_id.to_s
      title = item.title.to_s
      delete_summary = nil

      item.with_lock do
        upload_ids = [item.original_upload_id, item.processed_upload_id, item.thumbnail_upload_id].compact.uniq
        uploads = upload_ids.present? ? ::Upload.where(id: upload_ids).to_a : []

        delete_summary = build_delete_summary_for(item)
        delete_managed_assets_safely!(item, delete_summary: delete_summary)
        uploads.each { |upload| destroy_upload_safely!(upload, delete_summary: delete_summary) }
        log_admin_delete!(item, note: note, delete_summary: delete_summary)
        item.destroy!
      end

      partial = Array(delete_summary&.dig("warnings")).present?
      message = partial ? "Item deleted. Some storage cleanup steps failed; see delete summary." : "Item deleted. Storage cleanup completed."
      audit_admin_action!("admin_media_item_deleted", item: nil, operation: "delete", result: partial ? "partial" : "deleted", data: { public_id: public_id, title_present: title.present?, partial: partial })
      render_json_dump(ok: true, public_id: public_id, title: title, deleted: true, delete_summary: delete_summary, message: message)
    rescue => e
      render_operation_error(e, operation: "delete", item: item, status: 422)
    end

    # GET /admin/plugins/media-gallery/media-items/:public_id/diagnostics.json
    def diagnostics
      item = load_item!
      render_json_dump(
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        status: item.status,
        created_at: item.created_at,
        updated_at: item.updated_at,
        user_id: item.user_id,
        username: item.user&.username,
        media_type: item.media_type,
        gender: item.gender,
        thumbnail_url: "/media/#{item.public_id}/thumbnail?admin_preview=1",
        error_message: item.error_message,
        managed_storage_backend: item.managed_storage_backend,
        managed_storage_profile: managed_storage_profile_key_for(item),
        managed_storage_profile_label: managed_storage_profile_label_for(item),
        managed_storage_location_fingerprint_key: managed_storage_location_fingerprint_key_for(item),
        delivery_mode: item.delivery_mode,
        roles: diagnostics_roles(item),
        processing: processing_metadata(item),
        migration_copy: ::MediaGallery::MigrationCopy.copy_state_for(item),
        migration_switch: ::MediaGallery::MigrationSwitch.switch_state_for(item),
        migration_cleanup: ::MediaGallery::MigrationCleanup.cleanup_state_for(item),
        migration_verify: ::MediaGallery::MigrationVerify.verify_state_for(item),
        migration_rollback: ::MediaGallery::MigrationRollback.rollback_state_for(item),
        migration_finalize: ::MediaGallery::MigrationFinalize.finalize_state_for(item),
        migration_history: ::MediaGallery::MigrationRunHistory.history_for(item),
        admin_diagnostics: build_admin_diagnostics(item),
        orphan_cleanup_preview: ::MediaGallery::OrphanInspector.preview_for_item(item),
        security_review: ::MediaGallery::SecurityReview.for_item(item),
        hls_fingerprint: hls_fingerprint_diagnostics(item),
        hls_aes128: hls_aes128_diagnostics(item),
        recent_test_downloads: ::MediaGallery::TestDownloads.recent_artifacts_for(item.public_id, limit: 10),
        processing_stale: processing_stale?(item),
        processing_stale_after_minutes: processing_stale_after_minutes,
      )
    rescue => e
      render_operation_error(e, operation: "diagnostics", item: item, status: 422)
    end

    # GET /admin/plugins/media-gallery/media-items/:public_id/diagnostics-bundle.json
    def diagnostics_bundle
      item = load_item!
      bundle = diagnostics_bundle_for(item)
      audit_admin_action!(
        "diagnostics_bundle_generated",
        item: item,
        operation: "diagnostics_bundle",
        result: "generated",
        data: {
          schema_version: bundle[:schema_version],
          includes_hls: bundle.dig(:hls, :has_role),
          includes_migration: true
        }
      )

      render_json_dump(
        ok: true,
        bundle: bundle,
        bundle_text: JSON.pretty_generate(bundle)
      )
    rescue => e
      render_operation_error(e, operation: "diagnostics_bundle", item: item, status: 422)
    end

    def reset_processing
      item = load_item!
      unless item.queued_or_processing? || item.status == "failed"
        return render_json_error("item_not_resettable", status: 422)
      end

      processing = processing_metadata(item).deep_dup
      clear_current_run_state!(processing)
      processing["current_stage"] = "failed"
      processing["manual_reset_at"] = Time.now.utc.iso8601
      processing["manual_reset_by"] = current_user.username

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta["processing"] = processing

      item.update!(status: "failed", error_message: (item.error_message.presence || "processing_reset_by_admin"), extra_metadata: meta)

      render_json_dump(ok: true, public_id: item.public_id, status: item.status, processing: processing)
    end

    def migration_plan
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      render_json_dump(::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile))
    rescue => e
      render_operation_error(e, operation: "plan", item: item, status: 422)
    end

    def verify_target
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      result = ::MediaGallery::MigrationVerify.verify!(item, target_profile: target_profile, requested_by: current_user.username)
      audit_admin_action!("migration_target_verify_run", item: item, operation: "verify_target", result: result[:status] || result["status"], data: { target_profile: target_profile })
      render_json_dump(result)
    rescue => e
      render_operation_error(e, operation: "verify", item: item, status: 422)
    end

    def verify_hls_integrity
      item = load_item!
      result = ::MediaGallery::HlsIntegrityVerifier.verify(item)
      audit_hls_integrity_verify!(item, result)
      render_json_dump(ok: result[:ok], verification: result)
    rescue => e
      render_operation_error(e, operation: "verify_hls_integrity", item: item, status: 422)
    end

    def aes_backfill
      item = load_item!
      force = boolean_param(:force)
      state = ::MediaGallery::HlsAes128Backfill.enqueue_item!(item, requested_by: current_user.username, force: force)
      append_aes_backfill_management_log!(item, action: "hls_aes128_backfill_requested", result: state["status"], changes: { "hls_aes128_backfill" => [nil, state["status"]] })
      audit_admin_action!("hls_aes128_backfill_requested", item: item, operation: "hls_aes128_backfill", result: state["status"], data: { force: force })
      item.reload
      render_json_dump(ok: true, public_id: item.public_id, hls_aes128_backfill: state, item: management_item_payload(item), message: "AES HLS backfill queued.")
    rescue => e
      render_operation_error(e, operation: "hls_aes128_backfill", item: item, status: 422)
    end

    def restart_aes_backfill
      item = load_item!
      previous = ::MediaGallery::HlsAes128Backfill.state_for(item)
      state = ::MediaGallery::HlsAes128Backfill.restart_item!(item, requested_by: current_user.username)
      append_aes_backfill_management_log!(item, action: "hls_aes128_backfill_restarted", result: state["status"], changes: { "hls_aes128_backfill" => [previous["status"], state["status"]] })
      audit_admin_action!("hls_aes128_backfill_restarted", item: item, operation: "hls_aes128_backfill_restart", result: state["status"], data: { previous_status: previous["status"] })
      item.reload
      render_json_dump(ok: true, public_id: item.public_id, hls_aes128_backfill: state, item: management_item_payload(item), message: "AES HLS backfill restarted.")
    rescue => e
      render_operation_error(e, operation: "hls_aes128_backfill_restart", item: item, status: 422)
    end

    def clear_aes_backfill
      item = load_item!
      previous = ::MediaGallery::HlsAes128Backfill.state_for(item)
      reason = ::MediaGallery::TextSanitizer.plain_text(params[:reason], max_length: 500, allow_newlines: false).presence || "admin_clear"
      state = ::MediaGallery::HlsAes128Backfill.clear_state!(item, requested_by: current_user.username, reason: reason)
      append_aes_backfill_management_log!(item, action: "hls_aes128_backfill_cleared", result: state["status"], changes: { "hls_aes128_backfill" => [previous["status"], state["status"]] })
      audit_admin_action!("hls_aes128_backfill_cleared", item: item, operation: "hls_aes128_backfill_clear", result: state["status"], data: { previous_status: previous["status"], reason: reason })
      item.reload
      render_json_dump(ok: true, public_id: item.public_id, hls_aes128_backfill: state, item: management_item_payload(item), message: "AES HLS backfill state cleared.")
    rescue => e
      render_operation_error(e, operation: "hls_aes128_backfill_clear", item: item, status: 422)
    end

    def copy_to_target
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      state = ::MediaGallery::MigrationCopy.enqueue_copy!(
        item,
        target_profile: target_profile,
        requested_by: current_user.username,
        force: boolean_param(:force),
        auto_switch: boolean_param(:auto_switch),
        auto_cleanup: boolean_param(:auto_cleanup)
      )

      audit_admin_action!("migration_copy_requested", item: item, operation: "copy", result: state["status"], data: { target_profile: target_profile, force: boolean_param(:force), auto_switch: boolean_param(:auto_switch), auto_cleanup: boolean_param(:auto_cleanup) })
      render_json_dump(ok: true, public_id: item.public_id, migration_copy: state)
    rescue => e
      render_operation_error(e, operation: "copy", item: item, status: 422)
    end

    def switch_to_target
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      state = ::MediaGallery::MigrationSwitch.switch!(
        item,
        target_profile: target_profile,
        requested_by: current_user.username,
        mode: "manual",
        auto_cleanup: boolean_param(:auto_cleanup)
      )

      audit_admin_action!("migration_switch_requested", item: item, operation: "switch", result: state["status"], data: { target_profile: target_profile, auto_cleanup: boolean_param(:auto_cleanup) })
      render_json_dump(ok: true, public_id: item.public_id, migration_switch: state)
    rescue => e
      render_operation_error(e, operation: "switch", item: item, status: 422)
    end

    def cleanup_source
      item = load_item!
      state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: current_user.username, force: boolean_param(:force))
      audit_admin_action!("migration_cleanup_requested", item: item, operation: "cleanup", result: state["status"], data: { force: boolean_param(:force) })
      render_json_dump(ok: true, public_id: item.public_id, migration_cleanup: state)
    rescue => e
      render_operation_error(e, operation: "cleanup", item: item, status: 422)
    end

    def rollback_to_source
      item = load_item!
      state = ::MediaGallery::MigrationRollback.rollback!(item, requested_by: current_user.username, force: boolean_param(:force))
      audit_admin_action!("migration_rollback_requested", item: item, operation: "rollback", result: state["status"], data: { force: boolean_param(:force) })
      render_json_dump(ok: true, public_id: item.public_id, migration_rollback: state)
    rescue => e
      render_operation_error(e, operation: "rollback", item: item, status: 422)
    end

    def finalize_migration
      item = load_item!
      state = ::MediaGallery::MigrationFinalize.finalize!(item, requested_by: current_user.username, force: boolean_param(:force))
      audit_admin_action!("migration_finalize_requested", item: item, operation: "finalize", result: state["status"], data: { force: boolean_param(:force) })
      render_json_dump(ok: true, public_id: item.public_id, migration_finalize: state)
    rescue => e
      render_operation_error(e, operation: "finalize", item: item, status: 422)
    end

    def clear_queued_state
      item = load_item!
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      changed = []

      {
        "migration_copy" => %w[queued copying],
        "migration_cleanup" => %w[queued cleaning],
        "migration_finalize" => %w[queued pending_cleanup],
      }.each do |key, statuses|
        state = meta[key]
        next unless state.is_a?(Hash)
        next unless statuses.include?(state["status"].to_s)

        state = state.deep_dup
        state["status"] = "cleared"
        state["cleared_at"] = Time.now.utc.iso8601
        state["cleared_by"] = current_user.username
        state["last_error"] = nil
        meta[key] = state
        changed << key
      end

      return render_operation_error("no_queued_state_to_clear", operation: "clear_state", item: item, status: 422) if changed.empty?

      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      ::MediaGallery::OperationLogger.info("migration_queued_state_cleared", item: item, operation: "clear_state", data: { cleared: changed, requested_by: current_user.username })
      render_json_dump(ok: true, public_id: item.public_id, cleared: changed, message: "Queued state cleared.")
    rescue => e
      render_operation_error(e, operation: "clear_state", item: item, status: 422)
    end

    def bulk_migrate
      target_profile = params[:target_profile].to_s.presence || "target"
      items = bulk_migration_scope.to_a
      results = []
      queued = 0
      skipped = 0

      return render_json_error("no_media_items_selected", status: 422) if items.blank?

      items.each do |item|
        has_hls = ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash)
        next if has_hls_filter == "true" && !has_hls
        next if has_hls_filter == "false" && has_hls

        begin
          state = ::MediaGallery::MigrationCopy.enqueue_copy!(
            item,
            target_profile: target_profile,
            requested_by: current_user.username,
            force: boolean_param(:force),
            auto_switch: boolean_param(:auto_switch),
            auto_cleanup: boolean_param(:auto_cleanup),
            full_migration: boolean_param(:full_migration)
          )
          queued += 1
          results << { public_id: item.public_id, status: state["status"].to_s.presence || "queued" }
        rescue => e
          skipped += 1
          normalized = ::MediaGallery::OperationErrors.normalize(e, operation: "copy")
          results << { public_id: item.public_id, status: "skipped", error: normalized[:message], error_code: normalized[:code] }
        end
      end

      ::MediaGallery::OperationLogger.info("bulk_migration_enqueued", operation: "bulk_copy", data: { target_profile: target_profile, requested_count: items.length, queued_count: queued, skipped_count: skipped, requested_by: current_user.username })
      audit_admin_action!("bulk_migration_requested", operation: "bulk_copy", result: "queued", data: { target_profile: target_profile, requested_count: items.length, queued_count: queued, skipped_count: skipped })
      render_json_dump(
        ok: true,
        target_profile: target_profile,
        requested_count: items.length,
        queued_count: queued,
        skipped_count: skipped,
        items: results
      )
    rescue => e
      render_operation_error(e, operation: "bulk_copy", status: 422)
    end

    def bulk_aes_backfill
      force = boolean_param(:force)
      items = bulk_aes_backfill_scope.to_a
      return render_json_error("no_media_items_selected", status: 422) if items.blank?

      results = []
      queued = 0
      skipped = 0

      items.each do |item|
        begin
          aes_status = hls_aes128_status_for(item)
          unless bulk_aes_backfill_candidate?(item, aes_status: aes_status, force: force)
            skipped += 1
            results << { public_id: item.public_id, status: "skipped", reason: "not_eligible", hls_aes128: aes_status }
            next
          end

          state = ::MediaGallery::HlsAes128Backfill.enqueue_item!(item, requested_by: current_user.username, force: force)
          queued += 1
          results << { public_id: item.public_id, status: state["status"].to_s.presence || "queued", hls_aes128_backfill: state }
        rescue => e
          skipped += 1
          normalized = ::MediaGallery::OperationErrors.normalize(e, operation: "hls_aes128_backfill")
          results << { public_id: item.public_id, status: "skipped", error: normalized[:message], error_code: normalized[:code] }
        end
      end

      ::MediaGallery::OperationLogger.info("bulk_hls_aes128_backfill_requested", operation: "bulk_hls_aes128_backfill", data: { requested_count: items.length, queued_count: queued, skipped_count: skipped, requested_by: current_user.username, force: force })
      audit_admin_action!("bulk_hls_aes128_backfill_requested", operation: "bulk_hls_aes128_backfill", result: queued.positive? ? "queued" : "skipped", data: { requested_count: items.length, queued_count: queued, skipped_count: skipped, force: force })

      render_json_dump(
        ok: queued.positive?,
        requested_count: items.length,
        queued_count: queued,
        skipped_count: skipped,
        items: results,
        message: queued.positive? ? "AES HLS backfill queued for #{queued} item(s)." : "No eligible items were queued."
      )
    rescue => e
      render_operation_error(e, operation: "bulk_hls_aes128_backfill", status: 422)
    end

    def retry_processing
      item = load_item!
      force = boolean_param(:force)

      unless item.status == "failed" || (force && item.queued_or_processing?)
        return render_json_error("item_not_retryable", status: 422)
      end

      meta = (item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {})
      processing = (meta["processing"].is_a?(Hash) ? meta["processing"].deep_dup : {})
      processing["manual_retry_enqueued_at"] = Time.now.utc.iso8601
      processing["manual_retry_enqueued_by"] = current_user.username
      processing["manual_retry_force"] = force
      processing.delete("last_error_class")
      processing.delete("last_error_message")
      processing.delete("last_error_at")
      processing.delete("last_failed_stage")
      processing.delete("last_backtrace")
      clear_current_run_state!(processing) if force
      meta["processing"] = processing

      item.update!(status: "queued", error_message: nil, extra_metadata: meta)
      ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id, force_run: force)

      ::MediaGallery::OperationLogger.info("processing_retry_enqueued", item: item, operation: "retry_processing", data: { requested_by: current_user.username, force: force })
      audit_admin_action!("processing_retry_requested", item: item, operation: "retry_processing", result: "queued", data: { force: force })
      render_json_dump(ok: true, public_id: item.public_id, status: item.status)
    rescue => e
      render_operation_error(e, operation: "retry_processing", item: item, status: 422)
    end

    def block_owner
      update_owner_access_block(block_type: :view, block: true)
    end

    def unblock_owner
      update_owner_access_block(block_type: :view, block: false)
    end

    def block_owner_upload
      update_owner_access_block(block_type: :upload, block: true)
    end

    def unblock_owner_upload
      update_owner_access_block(block_type: :upload, block: false)
    end

    private

    def audit_hls_integrity_verify!(item, result)
      payload = {
        checked_segments: result[:checked_segments],
        role_backend: result[:role_backend],
        status: result[:status],
      }.compact

      ::MediaGallery::OperationLogger.info("hls_integrity_verify_run", item: item, operation: "verify_hls_integrity", data: payload)

      if defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.respond_to?(:record)
        ::MediaGallery::LogEvents.record(
          event_type: "hls_integrity_verify_run",
          severity: "info",
          category: "audit",
          request: request,
          user: current_user,
          media_item: item,
          message: "Admin action: verify_hls_integrity",
          details: payload.merge(actor_id: current_user&.id, actor_username: current_user&.username)
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] HLS integrity audit failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
    end

    def audit_admin_action!(event, item: nil, operation:, result: nil, data: {})
      ::MediaGallery::OperationLogger.audit(event, item: item, operation: operation, user: current_user, request: request, result: result, data: data)
    rescue => e
      Rails.logger.warn("[media_gallery] admin audit failed event=#{event} error=#{e.class}: #{e.message}")
    end

    def append_aes_backfill_management_log!(item, action:, result:, changes: nil)
      item.reload
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      append_management_log!(
        meta,
        action: action,
        item: item,
        note: sanitized_admin_note,
        changes: changes.presence || { "hls_aes128_backfill" => [nil, result] }
      )
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    rescue => e
      Rails.logger.warn("[media_gallery] AES backfill management log failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
    end

    def load_item!
      @current_item ||= begin
        item = ::MediaGallery::MediaItem.includes(:user).find_by(public_id: params[:public_id].to_s)
        raise Discourse::NotFound if item.blank?
        item
      end
    end

    def bulk_migration_scope
      public_ids = requested_bulk_public_ids
      return filtered_search_scope.limit(search_limit) if public_ids.blank?

      items_by_public_id = ::MediaGallery::MediaItem.where(public_id: public_ids).index_by(&:public_id)
      public_ids.filter_map { |public_id| items_by_public_id[public_id] }
    end

    def bulk_aes_backfill_scope
      public_ids = requested_bulk_public_ids
      if public_ids.present?
        items_by_public_id = ::MediaGallery::MediaItem.includes(:user).where(public_id: public_ids).index_by(&:public_id)
        return public_ids.filter_map { |public_id| items_by_public_id[public_id] }
      end

      limit = ::MediaGallery::HlsAes128Backfill.bulk_limit
      filtered_search_scope.where(media_type: "video", status: "ready").limit(limit)
    end

    def bulk_aes_backfill_candidate?(item, aes_status:, force: false)
      return false unless item&.media_type.to_s == "video" && item&.ready?
      return false unless aes_status.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(aes_status["has_hls"])
      return true if force && !ActiveModel::Type::Boolean.new.cast(aes_status["ready"])

      ActiveModel::Type::Boolean.new.cast(aes_status["needs_backfill"])
    end

    def requested_bulk_public_ids
      values = params[:public_ids]
      values = values.split(",") if values.is_a?(String)
      Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(100)
    end

    def filtered_search_scope
      scope = ::MediaGallery::MediaItem.includes(:user).order(created_at: :desc)
      q = ::MediaGallery::TextSanitizer.search_query(params[:q], max_length: 200)

      if q.present?
        if q =~ /\A\d+\z/
          scope = scope.where(id: q.to_i)
        else
          like = "%#{q}%"
          scope = scope.where(
            "public_id ILIKE :q OR title ILIKE :q OR media_type ILIKE :q",
            q: like
          )
        end
      end

      backend = params[:backend].to_s.strip
      scope = scope.where(managed_storage_backend: backend) if %w[local s3].include?(backend)

      gender = params[:gender].to_s.strip
      scope = scope.where(gender: gender) if ::MediaGallery::MediaItem::GENDERS.include?(gender)

      status = params[:status].to_s.strip
      scope = scope.where(status: status) if status.present?

      media_type = params[:media_type].to_s.strip
      scope = scope.where(media_type: media_type) if %w[audio image video].include?(media_type)

      hidden_filter = params[:hidden].to_s.strip
      case hidden_filter
      when "hidden"
        scope = scope.where("COALESCE((extra_metadata -> 'admin_visibility' ->> 'hidden')::boolean, false) = true")
      when "visible"
        scope = scope.where("COALESCE((extra_metadata -> 'admin_visibility' ->> 'hidden')::boolean, false) = false")
      end

      duplicate_filter = params[:duplicate].to_s.strip
      if duplicate_filter == "possible"
        scope = scope.where(
          "COALESCE((extra_metadata -> 'duplicate_detection' ->> 'duplicate_found')::boolean, false) = true OR COALESCE((extra_metadata -> 'duplicate_detection' ->> 'possible_duplicate')::boolean, false) = true"
        )
      end

      owner_user_id = params[:user_id].to_i
      scope = scope.where(user_id: owner_user_id) if owner_user_id.positive?

      profile = params[:profile].to_s.strip
      if profile.present? && profile != "all"
        scope = scope.where(managed_storage_profile: profile)
      end

      scope = apply_hls_aes128_sql_prefilter(scope)

      sort = params[:sort].to_s.strip
      scope = case sort
      when "oldest"
        scope.reorder(created_at: :asc)
      when "title_asc"
        scope.reorder(Arel.sql("LOWER(title) ASC"), created_at: :desc)
      when "title_desc"
        scope.reorder(Arel.sql("LOWER(title) DESC"), created_at: :desc)
      when "updated_desc"
        scope.reorder(updated_at: :desc)
      else
        scope.reorder(created_at: :desc)
      end

      scope
    end

    def apply_hls_aes128_sql_prefilter(scope)
      case hls_aes128_filter
      when "ready"
        scope.where("storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NOT NULL")
      when "needs_backfill", "not_encrypted"
        scope.where(media_type: "video", status: "ready")
          .where("storage_manifest -> 'roles' -> 'hls' IS NOT NULL")
          .where("storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NULL")
      when "not_ready"
        scope.where("storage_manifest -> 'roles' -> 'hls' IS NOT NULL")
      when "no_hls"
        scope.where("storage_manifest -> 'roles' -> 'hls' IS NULL")
      else
        scope
      end
    rescue => e
      ::MediaGallery::OperationLogger.warn("hls_aes128_search_prefilter_failed", operation: "management_search", data: { error_class: e.class.name, error_message: e.message }) if defined?(::MediaGallery::OperationLogger)
      scope
    end

    def search_limit
      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 100 if limit > 100
      limit
    end

    def search_candidate_limit
      # HLS/AES filters are partly derived from manifest metadata, so we may need
      # to inspect more rows than the final UI limit to return a full page. Keep
      # this bounded to avoid expensive admin searches on large libraries.
      return search_limit if hls_aes128_filter.blank? || hls_aes128_filter == "all"

      [[search_limit * 3, search_limit].max, 200].min
    end

    def search_profiles_summary
      ::MediaGallery::StorageSettingsResolver.configured_profiles_summary.map do |profile|
        {
          value: profile[:profile_key].to_s,
          label: profile[:label].to_s,
          backend: profile[:backend].to_s,
        }
      end
    rescue
      []
    end

    def has_hls_filter
      params[:has_hls].to_s.strip
    end

    def hls_aes128_filter
      params[:hls_aes128].to_s.strip
    end

    def hls_aes128_filter_matches?(status, filter)
      filter = filter.to_s.strip
      return true if filter.blank? || filter == "all"

      s = status.is_a?(Hash) ? status : {}
      state = s["status"].to_s
      has_hls = ActiveModel::Type::Boolean.new.cast(s["has_hls"])
      ready = ActiveModel::Type::Boolean.new.cast(s["ready"])
      needs_backfill = ActiveModel::Type::Boolean.new.cast(s["needs_backfill"])

      case filter
      when "ready"
        ready
      when "not_encrypted"
        has_hls && state == "not_encrypted"
      when "needs_backfill"
        needs_backfill
      when "not_ready"
        has_hls && !ready && state != "not_encrypted"
      when "no_hls"
        state == "no_hls" || !has_hls
      else
        true
      end
    end

    def boolean_param(name)
      ActiveModel::Type::Boolean.new.cast(params[name])
    end

    def normalize_tags_param(value)
      raw = value
      raw = raw.split(",") if raw.is_a?(String)
      Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq
    end

    def serialize_search_item(item, has_hls:, hls_aes128_status: nil)
      visibility = item.admin_visibility_state
      {
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        status: item.status,
        created_at: item.created_at,
        updated_at: item.updated_at,
        user_id: item.user_id,
        username: item.user&.username,
        media_type: item.media_type,
        gender: item.gender,
        filesize_processed_bytes: item.filesize_processed_bytes,
        error_message: item.error_message,
        thumbnail_url: "/media/#{item.public_id}/thumbnail?admin_preview=1",
        managed_storage_backend: item.managed_storage_backend,
        managed_storage_profile: managed_storage_profile_key_for(item),
        managed_storage_profile_label: managed_storage_profile_label_for(item),
        managed_storage_location_fingerprint_key: managed_storage_location_fingerprint_key_for(item),
        delivery_mode: item.delivery_mode,
        has_hls: has_hls,
        hls_aes128: hls_aes128_status || hls_aes128_status_for(item, has_hls: has_hls),
        hidden: item.admin_hidden?,
        hidden_reason: visibility["reason"],
        possible_duplicate: possible_duplicate_item?(item),
        duplicate_detection: duplicate_detection_payload(item, resolve_match: false),
      }
    end

    def management_item_payload(item)
      visibility = item.admin_visibility_state
      {
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        description: item.description,
        gender: item.gender,
        tags: item.tags,
        status: item.status,
        media_type: item.media_type,
        created_at: item.created_at,
        updated_at: item.updated_at,
        user_id: item.user_id,
        username: item.user&.username,
        thumbnail_url: "/media/#{item.public_id}/thumbnail?admin_preview=1",
        error_message: item.error_message,
        managed_storage_backend: item.managed_storage_backend,
        managed_storage_profile: managed_storage_profile_key_for(item),
        managed_storage_profile_label: managed_storage_profile_label_for(item),
        delivery_mode: item.delivery_mode,
        has_hls: ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash),
        hls_aes128: hls_aes128_status_for(item),
        hidden: item.admin_hidden?,
        visibility: visibility,
        processing: processing_metadata(item),
        upload_terms_acceptance: upload_terms_acceptance_for(item),
        duplicate_detection: duplicate_detection_payload(item, resolve_match: true),
        owner_media_access: owner_media_access_payload(item.user),
        allowed_tags: ::MediaGallery::Permissions.allowed_tags,
        management_log: item.admin_management_log,
      }
    end

    def upload_terms_acceptance_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta["upload_terms_acceptance"]
      value.is_a?(Hash) ? value : {}
    end

    def duplicate_detection_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta["duplicate_detection"]
      value.is_a?(Hash) ? value : {}
    end

    def possible_duplicate_item?(item)
      detection = duplicate_detection_for(item)
      ActiveModel::Type::Boolean.new.cast(detection["possible_duplicate"]) ||
        ActiveModel::Type::Boolean.new.cast(detection["duplicate_found"])
    end

    def duplicate_detection_payload(item, resolve_match: false)
      detection = duplicate_detection_for(item)
      possible = possible_duplicate_item?(item)
      return { possible_duplicate: false } unless possible

      match = duplicate_match_snapshot(detection, resolve_match: resolve_match)
      {
        possible_duplicate: true,
        checked_at: detection["checked_at"].presence,
        method: detection["method"].presence || "sha1_filesize",
        action: detection["action"].presence || "allow",
        override: ActiveModel::Type::Boolean.new.cast(detection["override"]),
        override_at: detection["override_at"].presence,
        override_by_username: detection["override_by_username"].presence,
        source_sha1: detection["source_sha1"].presence,
        source_filesize: detection["source_filesize"],
        source_extension: detection["source_extension"].presence,
        source_original_filename: detection["source_original_filename"].presence,
        match: match,
      }.compact
    end

    def duplicate_match_snapshot(detection, resolve_match:)
      snapshot = detection["duplicate_item"].is_a?(Hash) ? detection["duplicate_item"].deep_dup : {}
      snapshot["id"] ||= detection["duplicate_media_item_id"]
      snapshot["public_id"] ||= detection["duplicate_public_id"]

      return snapshot.compact unless resolve_match

      match = nil
      public_id = snapshot["public_id"].to_s.presence
      item_id = snapshot["id"].presence
      match = ::MediaGallery::MediaItem.includes(:user).find_by(public_id: public_id) if public_id.present?
      match ||= ::MediaGallery::MediaItem.includes(:user).find_by(id: item_id) if item_id.present?

      if match.present?
        snapshot.merge!(
          "id" => match.id,
          "public_id" => match.public_id.to_s,
          "title" => match.title.to_s,
          "user_id" => match.user_id,
          "username" => match.user&.username.to_s.presence,
          "created_at" => match.created_at&.iso8601,
          "status" => match.status.to_s,
          "media_type" => match.media_type.to_s,
          "original_upload_id" => match.original_upload_id,
          "hidden" => (match.respond_to?(:admin_hidden?) ? match.admin_hidden? : nil),
          "still_exists" => true
        )
      elsif public_id.present? || item_id.present?
        snapshot["still_exists"] = false
      end

      snapshot.compact
    rescue => e
      Rails.logger.warn("[media_gallery] duplicate detection snapshot failed item_id=#{detection['duplicate_media_item_id']}: #{e.class}: #{e.message}")
      snapshot.compact
    end

    def sanitized_admin_note
      ::MediaGallery::TextSanitizer.plain_text(params[:admin_note], max_length: 2000, allow_newlines: true).presence
    end

    def quick_block_group_name
      configured_group_name(:view)
    end

    def quick_upload_block_group_name
      configured_group_name(:upload)
    end

    def configured_group_name(block_type)
      setting =
        block_type == :upload ?
          SiteSetting.media_gallery_quick_upload_block_group :
          SiteSetting.media_gallery_quick_block_group

      ::MediaGallery::TextSanitizer.plain_text(
        setting,
        max_length: 100,
        allow_newlines: false
      ).to_s.strip.presence
    end

    def quick_block_group
      configured_group(:view)
    end

    def quick_upload_block_group
      configured_group(:upload)
    end

    def configured_group(block_type)
      name = configured_group_name(block_type)
      return nil if name.blank?

      ::Group.where("LOWER(name) = ?", name.downcase).first
    end

    def quick_block_group_usable?(group)
      return false if group.blank?
      return false if group.respond_to?(:automatic) && group.automatic

      true
    end

    def user_member_of_group?(user, group)
      return false if user.blank? || group.blank?

      ::GroupUser.where(group_id: group.id, user_id: user.id).exists?
    end

    def user_member_of_named_groups?(user, names)
      normalized = Array(names).map(&:to_s).map(&:downcase).reject(&:blank?)
      return false if user.blank? || normalized.blank?

      user.groups.where("LOWER(name) IN (?)", normalized).exists?
    end

    def owner_media_access_payload(user, group: nil)
      view_group = group || quick_block_group
      upload_group = quick_upload_block_group

      view_configured_name = quick_block_group_name
      upload_configured_name = quick_upload_block_group_name

      view_group_exists = view_group.present?
      upload_group_exists = upload_group.present?
      view_group_usable = quick_block_group_usable?(view_group)
      upload_group_usable = quick_block_group_usable?(upload_group)

      return {
        user_id: nil,
        username: nil,
        quick_block_group_name: view_configured_name,
        quick_block_group_exists: view_group_exists,
        quick_block_group_usable: view_group_usable,
        quick_upload_block_group_name: upload_configured_name,
        quick_upload_block_group_exists: upload_group_exists,
        quick_upload_block_group_usable: upload_group_usable,
        user_blockable: false,
        blocked_by_quick_group: false,
        blocked_by_media_groups: false,
        upload_blocked_by_quick_group: false,
        upload_blocked_by_media_groups: false,
        blocked: false,
        view_blocked: false,
        upload_blocked: false,
        upload_only_blocked: false,
        can_quick_block: false,
        can_quick_unblock: false,
        can_quick_upload_block: false,
        can_quick_upload_unblock: false,
        reason: "media_owner_not_found",
        upload_reason: "media_owner_not_found",
      } if user.blank?

      user_blockable = !(user.admin? || user.staff?)

      view_quick_member = view_group_exists ? user_member_of_group?(user, view_group) : false
      upload_quick_member = upload_group_exists ? user_member_of_group?(user, upload_group) : false

      view_media_blocked = user_blockable && user_member_of_named_groups?(user, ::MediaGallery::Permissions.blocked_groups)
      upload_media_blocked = user_blockable && user_member_of_named_groups?(user, ::MediaGallery::Permissions.upload_blocked_groups)

      view_blocked = view_media_blocked
      upload_only_blocked = upload_media_blocked
      upload_blocked = view_blocked || upload_only_blocked

      view_reason = owner_access_reason(
        configured_name: view_configured_name,
        group_exists: view_group_exists,
        group_usable: view_group_usable,
        user_blockable: user_blockable
      )
      upload_reason = owner_access_reason(
        configured_name: upload_configured_name,
        group_exists: upload_group_exists,
        group_usable: upload_group_usable,
        user_blockable: user_blockable
      )

      {
        user_id: user.id,
        username: user.username,
        quick_block_group_name: view_configured_name,
        quick_block_group_exists: view_group_exists,
        quick_block_group_usable: view_group_usable,
        quick_upload_block_group_name: upload_configured_name,
        quick_upload_block_group_exists: upload_group_exists,
        quick_upload_block_group_usable: upload_group_usable,
        user_blockable: user_blockable,
        blocked_by_quick_group: view_quick_member,
        blocked_by_media_groups: view_media_blocked,
        upload_blocked_by_quick_group: upload_quick_member,
        upload_blocked_by_media_groups: upload_media_blocked,
        blocked: view_blocked,
        view_blocked: view_blocked,
        upload_blocked: upload_blocked,
        upload_only_blocked: upload_only_blocked,
        can_quick_block: view_reason.blank? && !view_quick_member,
        can_quick_unblock: view_reason.blank? && view_quick_member,
        can_quick_upload_block: upload_reason.blank? && !upload_quick_member && !view_blocked,
        can_quick_upload_unblock: upload_reason.blank? && upload_quick_member,
        reason: view_reason,
        upload_reason: upload_reason,
      }
    end

    def owner_access_reason(configured_name:, group_exists:, group_usable:, user_blockable:)
      reason = nil
      reason ||= "media_gallery_quick_block_group_not_configured" if configured_name.blank?
      reason ||= "media_gallery_quick_block_group_not_found" if configured_name.present? && !group_exists
      reason ||= "media_gallery_quick_block_group_not_usable" if group_exists && !group_usable
      reason ||= "media_owner_is_staff" unless user_blockable
      reason
    end

    def owner_access_error_message(code)
      case code.to_s
      when "media_gallery_quick_block_group_not_configured"
        "Configure the relevant media quick block group setting before using this action."
      when "media_gallery_quick_block_group_not_found"
        "The configured media quick block group does not exist. Check the site setting and group name."
      when "media_gallery_quick_block_group_not_usable"
        "The configured media quick block group cannot be used for manual blocking. Use a regular custom group."
      when "media_owner_is_staff"
        "Staff and admin users cannot be blocked from media with this action."
      when "media_owner_not_found"
        "The media owner could not be found."
      else
        "The media owner access action is not available right now."
      end
    end

    def render_owner_access_error(code)
      render json: { error: owner_access_error_message(code), code: code.to_s }, status: 422
    end

    def update_owner_access_block(block_type:, block:)
      item = load_item!
      owner = item.user
      return render_json_error("media_owner_not_found", status: 422) if owner.blank?

      group = configured_group(block_type)
      state = owner_media_access_payload(owner)
      permission_key =
        if block_type == :upload
          block ? :can_quick_upload_block : :can_quick_upload_unblock
        else
          block ? :can_quick_block : :can_quick_unblock
        end
      reason_key = block_type == :upload ? :upload_reason : :reason
      return render_owner_access_error(state[reason_key]) unless state[permission_key]

      note = sanitized_admin_note
      if block
        ::GroupUser.find_or_create_by!(group_id: group.id, user_id: owner.id)
      else
        ::GroupUser.where(group_id: group.id, user_id: owner.id).destroy_all
      end
      owner.reload

      action =
        if block_type == :upload
          block ? "block_owner_upload" : "unblock_owner_upload"
        else
          block ? "block_owner_view" : "unblock_owner_view"
        end

      append_owner_access_log!(
        item,
        owner: owner,
        action: action,
        note: note,
        group: group,
        block_type: block_type,
        from_blocked: !block,
        to_blocked: block
      )

      item.reload
      operation =
        if block_type == :upload
          block ? "admin_media_owner_upload_blocked" : "admin_media_owner_upload_unblocked"
        else
          block ? "admin_media_owner_view_blocked" : "admin_media_owner_view_unblocked"
        end

      ::MediaGallery::OperationLogger.warn(
        operation,
        item: item,
        operation: action,
        data: { owner_user_id: owner.id, owner_username: owner.username, group: group.name, block_type: block_type, requested_by: current_user.username, note_present: note.present? }
      )

      message =
        if block_type == :upload
          block ? "#{owner.username} has been blocked from uploading to the media library." : "#{owner.username} has been removed from the media upload block group."
        else
          block ? "#{owner.username} has been blocked from viewing and uploading media." : "#{owner.username} has been removed from the media view block group."
        end

      render_json_dump(ok: true, item: management_item_payload(item), message: message)
    rescue => e
      render_operation_error(e, operation: "update_owner_access_block", item: item, status: 422)
    end

    def append_owner_access_log!(item, owner:, action:, note:, group:, block_type:, from_blocked:, to_blocked:)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      change_key = block_type == :upload ? "owner_media_upload_blocked" : "owner_media_view_blocked"
      group_key = block_type == :upload ? "quick_upload_block_group" : "quick_block_group"
      append_management_log!(
        meta,
        action: action,
        item: item,
        note: note,
        changes: {
          change_key => [from_blocked, to_blocked],
          "owner" => [owner.username, owner.username],
          group_key => [group.name, group.name],
        }
      )
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end

    def append_management_log!(meta, action:, item:, note:, changes: nil)
      log = meta[MANAGEMENT_LOG_KEY]
      log = [] unless log.is_a?(Array)
      entry = {
        "action" => action.to_s,
        "at" => Time.now.utc.iso8601,
        "admin_username" => current_user.username,
        "admin_user_id" => current_user.id,
        "public_id" => item.public_id.to_s,
      }
      entry["note"] = note if note.present?
      entry["changes"] = stringify_changes(changes) if changes.present?
      log.unshift(entry)
      meta[MANAGEMENT_LOG_KEY] = log.first(MAX_MANAGEMENT_LOG_ENTRIES)
      meta
    end

    def stringify_changes(changes)
      return {} unless changes.is_a?(Hash)

      changes.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value
      end
    end

    def admin_visibility_hash_from_meta(meta)
      value = meta[VISIBILITY_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def managed_storage_profile_key_for(item)
      ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
    end

    def managed_storage_profile_label_for(item)
      ::MediaGallery::StorageSettingsResolver.profile_label_for_key(managed_storage_profile_key_for(item))
    end

    def managed_storage_location_fingerprint_key_for(item)
      ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(managed_storage_profile_key_for(item))
    end

    def processing_metadata(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta["processing"]
      value.is_a?(Hash) ? value : {}
    end

    def processing_stale?(item)
      meta = processing_metadata(item)
      started_at = meta["current_run_started_at"].presence || meta["last_started_at"].presence
      return false if started_at.blank? || item.status != "processing"

      Time.iso8601(started_at) < processing_stale_after_minutes.minutes.ago
    rescue ArgumentError, TypeError
      false
    end

    def processing_stale_after_minutes
      if SiteSetting.respond_to?(:media_gallery_processing_stale_after_minutes)
        value = SiteSetting.media_gallery_processing_stale_after_minutes.to_i
        value.positive? ? value : 240
      else
        240
      end
    end

    def clear_current_run_state!(processing)
      processing.delete("current_run_token")
      processing.delete("current_run_started_at")
      processing.delete("current_run_stale_after_minutes")
      processing.delete("current_run_recovered_stale_processing")
      processing.delete("current_run_job_class")
    end

    def diagnostics_roles(item)
      %w[main thumbnail hls].map do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        {
          name: role_name,
          role: role,
          exists: role_exists?(role_name, role),
        }
      end
    end

    def role_exists?(role_name, role)
      return false unless role.is_a?(Hash)

      case role["backend"].to_s
      when "upload"
        ::Upload.exists?(id: role["upload_id"].to_i)
      when "local", "s3"
        store = managed_store_for_role(role)
        return false if store.blank?

        if role_name == "hls"
          prefix = role["key_prefix"].to_s.presence || role["key"].to_s
          store.list_prefix(prefix, limit: 1).any?
        else
          store.exists?(role["key"])
        end
      else
        false
      end
    rescue => e
      ::MediaGallery::OperationLogger.warn("diagnostic_role_exists_failed", item: @current_item, operation: "diagnostics", data: { role_name: role_name, error_class: e.class.name, error_message: e.message })
      false
    end

    def managed_store_for_role(role)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(@current_item)
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"].to_s)
      return nil if store.blank?
      return nil if role["backend"].to_s.present? && store.backend.to_s != role["backend"].to_s

      store
    end


    def hls_aes128_active_key_ids_by_item(items)
      return {} unless hls_aes128_key_table_available?

      ids = Array(items).map(&:id).compact.uniq
      return {} if ids.blank?

      rows = ::MediaGallery::HlsAes128Key.active
        .where(media_item_id: ids, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: "")
        .pluck(:media_item_id, :key_id)

      rows.each_with_object({}) do |(media_item_id, key_id), memo|
        memo[media_item_id.to_i] ||= Set.new
        memo[media_item_id.to_i] << key_id.to_s
      end
    rescue => e
      ::MediaGallery::OperationLogger.warn("hls_aes128_key_prefetch_failed", operation: "management_search", data: { error_class: e.class.name, error_message: e.message }) if defined?(::MediaGallery::OperationLogger)
      {}
    end

    def hls_aes128_status_for(item, has_hls: nil, active_key_ids_by_item: nil)
      has_hls = ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash) if has_hls.nil?
      role = ::MediaGallery::Hls.managed_role_for(item)
      role = role.deep_stringify_keys if role.is_a?(Hash)
      status = ::MediaGallery::Hls.aes128_status_for(item, role: role)
      encryption = ::MediaGallery::Hls.aes128_encryption_meta_for(item, role: role)
      key_id = status["key_id"].to_s.presence || (encryption.is_a?(Hash) ? encryption["key_id"].to_s.presence : nil)
      key_record_present = key_id.present? && hls_aes128_key_record_present?(item, key_id: key_id, active_key_ids_by_item: active_key_ids_by_item)
      encryption_present = encryption.is_a?(Hash) && encryption.present?
      ready = ActiveModel::Type::Boolean.new.cast(status["ready"]) && key_record_present
      enabled = ActiveModel::Type::Boolean.new.cast(status["enabled"])
      required = ActiveModel::Type::Boolean.new.cast(status["required"])
      backfill_state = defined?(::MediaGallery::HlsAes128Backfill) ? ::MediaGallery::HlsAes128Backfill.state_for(item) : {}
      backfill_status = backfill_state.is_a?(Hash) ? backfill_state["status"].to_s : ""
      backfill_stale = defined?(::MediaGallery::HlsAes128Backfill) ? ::MediaGallery::HlsAes128Backfill.stale_state?(backfill_state) : false
      backfill_in_progress = %w[queued processing].include?(backfill_status)
      needs_backfill = !!has_hls && !ready && (enabled || required) && !encryption_present && !backfill_in_progress

      status_label =
        if ready
          "ready"
        elsif !has_hls
          "no_hls"
        elsif required || encryption_present
          "not_ready"
        else
          "not_encrypted"
        end

      status.merge(
        "has_hls" => !!has_hls,
        "ready" => ready,
        "encrypted" => encryption_present,
        "needs_backfill" => needs_backfill,
        "key_id" => key_id,
        "key_record_present" => key_record_present,
        "status" => status_label,
        "backfill" => backfill_state.merge("stale" => backfill_stale),
      ).compact
    rescue => e
      {
        "has_hls" => !!has_hls,
        "ready" => false,
        "status" => "error",
        "error" => "#{e.class}: #{e.message}"
      }
    end

    def hls_aes128_diagnostics(item)
      status = hls_aes128_status_for(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      role = role.deep_stringify_keys if role.is_a?(Hash)
      encryption = ::MediaGallery::Hls.aes128_encryption_meta_for(item, role: role)

      records = []
      if hls_aes128_key_table_available?
        records = ::MediaGallery::HlsAes128Key.where(media_item_id: item.id).order(created_at: :desc).limit(10).map(&:public_metadata)
      end

      status.merge(
        "encryption_metadata" => encryption,
        "key_records" => records,
        "key_records_count" => records.length,
        "key_table_available" => hls_aes128_key_table_available?,
        "backfill" => (defined?(::MediaGallery::HlsAes128Backfill) ? ::MediaGallery::HlsAes128Backfill.state_for(item) : {}),
      ).compact
    rescue => e
      {
        "ready" => false,
        "status" => "error",
        "error" => "#{e.class}: #{e.message}"
      }
    end

    def hls_aes128_key_record_present?(item, key_id:, active_key_ids_by_item: nil)
      if active_key_ids_by_item.is_a?(Hash) && active_key_ids_by_item.key?(item.id.to_i)
        return active_key_ids_by_item[item.id.to_i].include?(key_id.to_s)
      end

      return false unless hls_aes128_key_table_available?

      ::MediaGallery::HlsAes128Key.active.exists?(
        media_item_id: item.id,
        key_id: key_id.to_s,
        variant: ::MediaGallery::Hls::DEFAULT_VARIANT,
        ab: ""
      )
    rescue
      false
    end

    def hls_aes128_key_table_available?
      defined?(::MediaGallery::HlsAes128Key) && ::MediaGallery::HlsAes128Key.table_exists?
    rescue
      false
    end

    def hls_fingerprint_diagnostics(item)
      configured_layout = ::MediaGallery::FingerprintWatermark.layout_mode
      packaging_selection = ::MediaGallery::FingerprintWatermark.packaging_layout_selection
      role = ::MediaGallery::Hls.managed_role_for(item)
      store = role.present? ? ::MediaGallery::Hls.store_for_managed_role(item, role) : nil
      meta = ::MediaGallery::Hls.fingerprint_meta_for(item, role: role, store: store)

      {
        configured_layout: configured_layout,
        effective_new_upload_layout: packaging_selection[:effective_layout],
        layout_selection_reason: packaging_selection[:reason],
        preserve_legacy_layouts_for_new_uploads: !!packaging_selection[:preserve_legacy],
        packaged_layout: meta.is_a?(Hash) ? meta["layout"].to_s.presence : nil,
        packaged_configured_layout: meta.is_a?(Hash) ? meta["configured_layout"].to_s.presence : nil,
        packaged_layout_selection_reason: meta.is_a?(Hash) ? meta["layout_selection_reason"].to_s.presence : nil,
        packaged_legacy_layout_auto_upgraded: meta.is_a?(Hash) ? ActiveModel::Type::Boolean.new.cast(meta["legacy_layout_auto_upgraded"]) : nil,
        packaged_codebook_scheme: meta.is_a?(Hash) ? meta["codebook_scheme"].to_s.presence : nil,
        packaged_profile: meta.is_a?(Hash) ? meta["profile"].to_s.presence : nil,
        packaged_generated_at: meta.is_a?(Hash) ? meta["generated_at"] : nil,
      }.compact
    rescue => e
      {
        configured_layout: configured_layout,
        effective_new_upload_layout: packaging_selection[:effective_layout],
        layout_selection_reason: packaging_selection[:reason],
        error: "#{e.class}: #{e.message}"
      }.compact
    end

    def build_admin_diagnostics(item)
      {
        delete_semantics: {
          mode: "hard_delete_best_effort",
          summary: "The database row is removed immediately. Managed assets, uploads and private/original directories are then deleted best-effort in the same request.",
        },
        operations: {
          copy: diagnostic_state_for(::MediaGallery::MigrationCopy.copy_state_for(item), operation: "copy"),
          verify: diagnostic_state_for(::MediaGallery::MigrationVerify.verify_state_for(item), operation: "verify"),
          switch: diagnostic_state_for(::MediaGallery::MigrationSwitch.switch_state_for(item), operation: "switch"),
          cleanup: diagnostic_state_for(::MediaGallery::MigrationCleanup.cleanup_state_for(item), operation: "cleanup"),
          rollback: diagnostic_state_for(::MediaGallery::MigrationRollback.rollback_state_for(item), operation: "rollback"),
          finalize: diagnostic_state_for(::MediaGallery::MigrationFinalize.finalize_state_for(item), operation: "finalize"),
        },
        runtime: {
          processing_active: ::MediaGallery::OperationCoordinator.processing_active?(item),
          copy_active: ::MediaGallery::OperationCoordinator.copy_active?(::MediaGallery::MigrationCopy.copy_state_for(item)),
          cleanup_active: ::MediaGallery::OperationCoordinator.cleanup_active?(::MediaGallery::MigrationCleanup.cleanup_state_for(item)),
          finalize_pending: ::MediaGallery::OperationCoordinator.finalize_pending?(::MediaGallery::MigrationFinalize.finalize_state_for(item)),
        }
      }
    end

    def diagnostic_state_for(state, operation:)
      return {} unless state.is_a?(Hash) && state.present?

      normalized = if state["last_error_human"].present?
        {
          code: state["last_error_code"],
          detail: state["last_error_detail"],
          message: state["last_error_human"],
          retryable: state["retryable"],
          recommended_action: state["recommended_action"],
        }
      elsif state["last_error"].present?
        ::MediaGallery::OperationErrors.normalize(state["last_error"], operation: operation)
      else
        {}
      end

      {
        status: state["status"].to_s,
        duration_ms: state["duration_ms"],
        error_code: normalized[:code],
        error_detail: normalized[:detail],
        error_message: normalized[:message],
        retryable: normalized[:retryable],
        recommended_action: normalized[:recommended_action],
      }.compact
    end

    def diagnostics_bundle_for(item)
      processing = processing_metadata(item)
      roles = diagnostics_roles(item)
      hls_role = roles.find { |entry| entry[:name].to_s == "hls" }

      {
        schema_version: "media_gallery_diagnostics_bundle_v1",
        generated_at: Time.now.utc.iso8601,
        generated_by: {
          user_id: current_user&.id,
          username: current_user&.username,
        }.compact,
        item: {
          public_id: item.public_id,
          title_present: item.title.present?,
          status: item.status,
          media_type: item.media_type,
          gender: item.gender,
          created_at: item.created_at&.iso8601,
          updated_at: item.updated_at&.iso8601,
          error_message: truncate_diagnostic_value(item.error_message, 300),
          processing_stale: processing_stale?(item),
          processing_stale_after_minutes: processing_stale_after_minutes,
        }.compact,
        storage: {
          managed_storage_backend: item.managed_storage_backend,
          managed_storage_profile: managed_storage_profile_key_for(item),
          managed_storage_profile_label: managed_storage_profile_label_for(item),
          managed_storage_location_fingerprint_key: managed_storage_location_fingerprint_key_for(item),
          delivery_mode: item.delivery_mode,
        }.compact,
        roles: roles.map { |entry| diagnostics_bundle_role_summary(entry) },
        hls: diagnostics_bundle_hls_summary(item, hls_role),
        processing: diagnostics_bundle_processing_summary(processing),
        migration: diagnostics_bundle_migration_summary(item),
        duplicate_detection: diagnostics_bundle_duplicate_summary(item),
        security_review: diagnostics_bundle_security_review_summary(item),
        relevant_settings: diagnostics_bundle_settings_summary,
        notes: [
          "This bundle is intended for troubleshooting and support.",
          "It intentionally omits raw playback tokens, presigned URLs, credentials, cookies, and full storage object keys.",
          "Storage object identifiers are shown as SHA256 labels and short suffixes only."
        ],
      }.compact
    end

    def diagnostics_bundle_role_summary(entry)
      role = entry[:role].is_a?(Hash) ? entry[:role] : {}
      keys = %w[key key_prefix master_key complete_key fingerprint_meta_key segment_key_template variant_playlist_key_template ab_segment_key_template]

      {
        name: entry[:name],
        backend: role["backend"].to_s.presence,
        exists: entry[:exists],
        upload_id_present: role["upload_id"].present?,
        variants: Array(role["variants"]).map(&:to_s).first(10),
        ready: role.key?("ready") ? !!role["ready"] : nil,
        key_references: keys.each_with_object({}) do |key, memo|
          next if role[key].blank?

          memo[key] = diagnostic_key_reference(role[key])
        end.presence,
      }.compact
    end

    def diagnostics_bundle_hls_summary(item, hls_role)
      role = hls_role.is_a?(Hash) ? hls_role[:role] : nil
      fingerprint = hls_fingerprint_diagnostics(item)

      {
        has_role: role.is_a?(Hash),
        role_backend: role.is_a?(Hash) ? role["backend"].to_s.presence : nil,
        role_ready: role.is_a?(Hash) && role.key?("ready") ? !!role["ready"] : nil,
        variants: role.is_a?(Hash) ? Array(role["variants"]).map(&:to_s).first(10) : [],
        master_key: role.is_a?(Hash) && role["master_key"].present? ? diagnostic_key_reference(role["master_key"]) : nil,
        key_prefix: role.is_a?(Hash) && role["key_prefix"].present? ? diagnostic_key_reference(role["key_prefix"]) : nil,
        fingerprint: fingerprint,
      }.compact
    rescue => e
      { error: "#{e.class}: #{truncate_diagnostic_value(e.message, 180)}" }
    end

    def diagnostics_bundle_processing_summary(processing)
      return {} unless processing.is_a?(Hash)

      allowed = %w[
        current_stage
        current_run_started_at
        current_run_job_class
        last_started_at
        last_finished_at
        last_error_class
        last_error_message
        last_error_code
        last_error_at
        retry_count
        attempts
        ffmpeg_exit_status
        ffprobe_exit_status
      ]

      allowed.each_with_object({}) do |key, memo|
        next unless processing.key?(key)

        memo[key] = truncate_diagnostic_value(processing[key], 500)
      end
    end

    def diagnostics_bundle_migration_summary(item)
      {
        copy: diagnostics_bundle_state_summary(::MediaGallery::MigrationCopy.copy_state_for(item)),
        verify: diagnostics_bundle_state_summary(::MediaGallery::MigrationVerify.verify_state_for(item)),
        switch: diagnostics_bundle_state_summary(::MediaGallery::MigrationSwitch.switch_state_for(item)),
        cleanup: diagnostics_bundle_state_summary(::MediaGallery::MigrationCleanup.cleanup_state_for(item)),
        rollback: diagnostics_bundle_state_summary(::MediaGallery::MigrationRollback.rollback_state_for(item)),
        finalize: diagnostics_bundle_state_summary(::MediaGallery::MigrationFinalize.finalize_state_for(item)),
      }.compact
    end

    def diagnostics_bundle_state_summary(state)
      return nil unless state.is_a?(Hash) && state.present?

      allowed = %w[
        status
        target_profile
        source_profile
        object_count
        progress_index
        progress_total
        objects_copied
        objects_skipped
        objects_deleted
        cleanup_mode
        last_error_code
        last_error_human
        last_error_detail
        last_error_at
        retryable
        recommended_action
        requested_by
        started_at
        finished_at
        updated_at
      ]

      allowed.each_with_object({}) do |key, memo|
        next unless state.key?(key)

        memo[key] = truncate_diagnostic_value(state[key], 500)
      end
    end

    def diagnostics_bundle_duplicate_summary(item)
      detection = duplicate_detection_payload(item, resolve_match: true)
      return {} unless detection.is_a?(Hash)

      {
        possible_duplicate: !!detection[:possible_duplicate],
        reason: truncate_diagnostic_value(detection[:reason], 200),
        match_public_id: detection.dig(:match, :public_id),
        match_status: detection.dig(:match, :status),
      }.compact
    rescue
      {}
    end

    def diagnostics_bundle_security_review_summary(item)
      review = ::MediaGallery::SecurityReview.for_item(item)
      return {} unless review.is_a?(Hash)

      {
        status: review[:status] || review["status"],
        summary: truncate_diagnostic_value(review[:summary] || review["summary"], 500),
        findings_count: Array(review[:findings] || review["findings"]).length,
      }.compact
    rescue
      {}
    end

    def diagnostics_bundle_settings_summary
      {
        hls_enabled: safe_site_setting_bool(:media_gallery_hls_enabled),
        protected_video_hls_only: safe_site_setting_bool(:media_gallery_protected_video_hls_only),
        private_storage_enabled: safe_site_setting_bool(:media_gallery_private_storage_enabled),
        default_storage_profile: safe_site_setting_string(:media_gallery_default_storage_profile_key),
        delivery_mode_default: safe_site_setting_string(:media_gallery_delivery_mode_default),
        bind_stream_to_user: safe_site_setting_bool(:media_gallery_bind_stream_to_user),
        bind_stream_to_session: safe_site_setting_bool(:media_gallery_bind_stream_to_session),
        bind_stream_to_ip: safe_site_setting_bool(:media_gallery_bind_stream_to_ip),
        stream_token_ttl_minutes: safe_site_setting_int(:media_gallery_stream_token_ttl_minutes),
        no_store_thumbnails: safe_site_setting_bool(:media_gallery_no_store_thumbnails),
        block_direct_media_navigation: safe_site_setting_bool(:media_gallery_block_direct_media_navigation),
        fail_closed_on_unrecognized_media: safe_site_setting_bool(:media_gallery_fail_closed_on_unrecognized_media),
        forensics_http_source_url_policy: safe_site_setting_string(:media_gallery_forensics_http_source_url_policy),
      }.compact
    end

    def diagnostic_key_reference(value)
      text = value.to_s
      {
        sha256: Digest::SHA256.hexdigest(text),
        suffix: diagnostic_key_suffix(text),
        length: text.length,
      }
    end

    def diagnostic_key_suffix(value)
      text = value.to_s.split("?").first.to_s
      parts = text.split("/").reject(&:blank?)
      parts.last(3).join("/")
    end

    def truncate_diagnostic_value(value, max = 500)
      return nil if value.nil?
      return value if value == true || value == false
      return value if value.is_a?(Numeric)

      text = value.is_a?(String) ? value : value.to_s
      text.length > max ? "#{text[0, max]}…" : text
    end

    def safe_site_setting_bool(name)
      SiteSetting.respond_to?(name) ? !!SiteSetting.public_send(name) : nil
    rescue
      nil
    end

    def safe_site_setting_int(name)
      SiteSetting.respond_to?(name) ? SiteSetting.public_send(name).to_i : nil
    rescue
      nil
    end

    def safe_site_setting_string(name)
      SiteSetting.respond_to?(name) ? SiteSetting.public_send(name).to_s : nil
    rescue
      nil
    end


    def render_operation_error(error, operation:, item: nil, status: 422, extra: nil)
      normalized = ::MediaGallery::OperationErrors.normalize(error, operation: operation)
      ::MediaGallery::OperationLogger.warn("admin_operation_failed", item: item, operation: operation, data: normalized.merge(extra: extra, requested_by: current_user&.username))

      payload = {
        error: normalized[:message],
        code: normalized[:code],
        detail: normalized[:detail],
        retryable: normalized[:retryable],
        recommended_action: normalized[:recommended_action],
      }.compact
      payload[:details] = extra[:details] if extra.is_a?(Hash) && extra[:details].present?

      render json: payload, status: status
    end

    def build_delete_summary_for(item)
      {
        "mode" => "hard_delete_best_effort",
        "managed_assets" => [],
        "uploads" => [],
        "filesystem_paths" => [],
        "warnings" => [],
      }
    end

    def delete_managed_assets_safely!(item, delete_summary:)
      public_id = item.public_id.to_s

      ["main", "thumbnail"].each do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?
        next unless %w[local s3].include?(role["backend"].to_s)

        deleted = false
        warning = nil
        begin
          store = managed_store_for_role(role)
          if store.blank?
            warning = "store_missing"
          else
            deleted = !!store.delete(role["key"].to_s)
            warning = "delete_failed" unless deleted
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["managed_assets"] << {
          role: role_name,
          backend: role["backend"].to_s,
          key: role["key"].to_s,
          deleted: deleted,
          warning: warning,
        }.compact
        delete_summary["warnings"] << "#{role_name}: #{warning}" if warning.present?
      end

      hls_role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      if hls_role.present? && %w[local s3].include?(hls_role["backend"].to_s)
        prefix = hls_role["key_prefix"].presence || hls_role["key"].presence || ::MediaGallery::PrivateStorage.hls_root_rel_dir(public_id)
        deleted = false
        warning = nil
        begin
          store = managed_store_for_role(hls_role)
          if store.blank?
            warning = "store_missing"
          elsif prefix.present?
            deleted = !!store.delete_prefix(prefix.to_s)
            warning = "delete_prefix_failed" unless deleted
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["managed_assets"] << {
          role: "hls",
          backend: hls_role["backend"].to_s,
          key_prefix: prefix.to_s,
          deleted: deleted,
          warning: warning,
        }.compact
        delete_summary["warnings"] << "hls: #{warning}" if warning.present?
      end

      [
        { label: "private_dir", path: ::MediaGallery::PrivateStorage.item_private_dir(public_id), root: ::MediaGallery::PrivateStorage.private_root },
        { label: "original_export_dir", path: ::MediaGallery::PrivateStorage.item_original_dir(public_id), root: ::MediaGallery::PrivateStorage.original_export_root },
      ].each do |entry|
        removed = false
        warning = nil
        begin
          if entry[:path].present? && Dir.exist?(entry[:path])
            root = entry[:root].to_s
            ::MediaGallery::PathSecurity.remove_tree_under!(entry[:path], root)
            removed = !Dir.exist?(entry[:path])
            warning = "filesystem_remove_failed" unless removed
          else
            removed = true
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["filesystem_paths"] << { label: entry[:label], path: entry[:path].to_s, removed: removed, warning: warning }.compact
        delete_summary["warnings"] << "#{entry[:label]}: #{warning}" if warning.present?
      end

      delete_summary["warnings"].uniq!
      delete_summary["status"] = delete_summary["warnings"].present? ? "partial" : "complete"
      delete_summary
    end

    def destroy_upload_safely!(upload, delete_summary:)
      return if upload.blank?

      deleted = false
      warning = nil
      begin
        if defined?(::UploadDestroyer)
          ::UploadDestroyer.new(Discourse.system_user, upload).destroy
          deleted = !::Upload.exists?(id: upload.id)
        else
          upload.destroy!
          deleted = !::Upload.exists?(id: upload.id)
        end
        warning = "upload_delete_failed" unless deleted
      rescue => e
        warning = "#{e.class}: #{e.message}"
      end

      delete_summary["uploads"] << { id: upload.id, original_filename: upload.original_filename.to_s, deleted: deleted, warning: warning }.compact
      delete_summary["warnings"] << "upload #{upload.id}: #{warning}" if warning.present?
      deleted
    end

    def log_admin_delete!(item, note: nil, delete_summary: nil)
      event = delete_summary.is_a?(Hash) && delete_summary["warnings"].present? ? "admin_delete_partial" : "admin_delete_completed"
      ::MediaGallery::OperationLogger.info(event, item: item, operation: "delete", data: {
        admin: current_user.username,
        note: note,
        delete_summary: delete_summary,
      })
    end

  end
end
