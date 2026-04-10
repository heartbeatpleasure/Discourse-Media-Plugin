# frozen_string_literal: true

module ::MediaGallery
  # Admin-only helper endpoints.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    # Returns a small list for quickly selecting a public_id in the admin UI.
    def search
      items = filtered_search_scope.limit(search_limit).map do |item|
        has_hls = ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash)
        next if has_hls_filter == "true" && !has_hls
        next if has_hls_filter == "false" && has_hls

        serialize_search_item(item, has_hls: has_hls)
      end.compact

      render_json_dump(items: items)
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
        user_id: item.user_id,
        username: item.user&.username,
        media_type: item.media_type,
        thumbnail_url: "/media/#{item.public_id}/thumbnail",
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
        processing_stale: processing_stale?(item),
        processing_stale_after_minutes: processing_stale_after_minutes,
      )
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/reset-processing.json
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

    # GET /admin/plugins/media-gallery/media-items/:public_id/migration-plan.json
    def migration_plan
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      render_json_dump(::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile))
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # GET /admin/plugins/media-gallery/media-items/:public_id/verify-target.json
    def verify_target
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      result = ::MediaGallery::MigrationVerify.verify!(item, target_profile: target_profile, requested_by: current_user.username)
      render_json_dump(result)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/copy-to-target.json
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

      render_json_dump(ok: true, public_id: item.public_id, migration_copy: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/switch-to-target.json
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

      render_json_dump(ok: true, public_id: item.public_id, migration_switch: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/cleanup-source.json
    def cleanup_source
      item = load_item!
      state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_cleanup: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/rollback-to-source.json
    def rollback_to_source
      item = load_item!
      state = ::MediaGallery::MigrationRollback.rollback!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_rollback: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/finalize-migration.json
    def finalize_migration
      item = load_item!
      state = ::MediaGallery::MigrationFinalize.finalize!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_finalize: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/clear-queued-state.json
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

      return render_json_error("no_queued_state_to_clear", status: 422) if changed.empty?

      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      render_json_dump(ok: true, public_id: item.public_id, cleared: changed, message: "Queued state cleared.")
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/bulk-migrate.json
    def bulk_migrate
      target_profile = params[:target_profile].to_s.presence || "target"
      items = bulk_migration_scope.to_a
      results = []
      queued = 0
      skipped = 0

      if items.blank?
        return render_json_error("no_media_items_selected", status: 422)
      end

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
            auto_cleanup: boolean_param(:auto_cleanup)
          )
          queued += 1
          results << { public_id: item.public_id, status: state["status"].to_s.presence || "queued" }
        rescue => e
          skipped += 1
          results << { public_id: item.public_id, status: "skipped", error: e.message }
        end
      end

      render_json_dump(
        ok: true,
        target_profile: target_profile,
        requested_count: items.length,
        queued_count: queued,
        skipped_count: skipped,
        items: results
      )
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/retry-processing.json
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

      render_json_dump(ok: true, public_id: item.public_id, status: item.status)
    end

    private

    def load_item!
      @current_item ||= begin
        item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
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

    def requested_bulk_public_ids
      values = params[:public_ids]
      values = values.split(",") if values.is_a?(String)
      Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(100)
    end

    def filtered_search_scope
      scope = ::MediaGallery::MediaItem.includes(:user).order(created_at: :desc)
      q = params[:q].to_s.strip

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

      status = params[:status].to_s.strip
      scope = scope.where(status: status) if status.present?

      media_type = params[:media_type].to_s.strip
      scope = scope.where(media_type: media_type) if %w[audio image video].include?(media_type)

      scope
    end

    def search_limit
      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 100 if limit > 100
      limit
    end

    def has_hls_filter
      params[:has_hls].to_s.strip
    end

    def boolean_param(name)
      ActiveModel::Type::Boolean.new.cast(params[name])
    end

    def serialize_search_item(item, has_hls:)
      {
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        status: item.status,
        created_at: item.created_at,
        user_id: item.user_id,
        username: item.user&.username,
        media_type: item.media_type,
        filesize_processed_bytes: item.filesize_processed_bytes,
        error_message: item.error_message,
        thumbnail_url: "/media/#{item.public_id}/thumbnail",
        managed_storage_backend: item.managed_storage_backend,
        managed_storage_profile: managed_storage_profile_key_for(item),
        managed_storage_profile_label: managed_storage_profile_label_for(item),
        managed_storage_location_fingerprint_key: managed_storage_location_fingerprint_key_for(item),
        delivery_mode: item.delivery_mode,
        has_hls: has_hls,
      }
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
      "error: #{e.class}: #{e.message}"
    end

    def managed_store_for_role(role)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(@current_item)
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"].to_s)
      return nil if store.blank?
      return nil if role["backend"].to_s.present? && store.backend.to_s != role["backend"].to_s

      store
    end
  end
end
