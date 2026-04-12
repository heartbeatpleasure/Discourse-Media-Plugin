# frozen_string_literal: true

module ::MediaGallery
  # Admin-only helper endpoints.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    MANAGEMENT_LOG_KEY = "admin_management_log"
    VISIBILITY_KEY = "admin_visibility"
    MAX_MANAGEMENT_LOG_ENTRIES = 50

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    def search
      items = filtered_search_scope.limit(search_limit).map do |item|
        has_hls = ::MediaGallery::AssetManifest.role_for(item, "hls").is_a?(Hash)
        next if has_hls_filter == "true" && !has_hls
        next if has_hls_filter == "false" && has_hls

        serialize_search_item(item, has_hls: has_hls)
      end.compact

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
      title = params[:title].to_s.strip
      return render_json_error("title_required", status: 422) if title.blank?

      subject = params[:gender].to_s.strip
      return render_json_error("gender_required", status: 422) if subject.blank?
      return render_json_error("invalid_gender", status: 422) unless ::MediaGallery::MediaItem::GENDERS.include?(subject)

      description = params[:description].to_s.strip
      tags = normalize_tags_param(params[:tags])
      note = params[:admin_note].to_s.strip.presence

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
      render_json_dump(ok: true, item: management_item_payload(item), message: "Item updated.")
    rescue ActiveRecord::RecordInvalid => e
      render_json_error("validation_error", status: 422, extra: { details: e.record.errors.full_messages })
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/visibility.json
    def visibility
      item = load_item!
      hidden = boolean_param(:hidden)
      note = params[:admin_note].to_s.strip.presence
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
      render_json_dump(ok: true, item: management_item_payload(item), message: hidden ? "Item hidden." : "Item visible again.")
    rescue => e
      render_json_error(e.message, status: 422)
    end

    # DELETE /admin/plugins/media-gallery/media-items/:public_id/admin-destroy.json
    def admin_destroy
      item = load_item!
      note = params[:admin_note].to_s.strip.presence
      public_id = item.public_id.to_s

      item.with_lock do
        upload_ids = [item.original_upload_id, item.processed_upload_id, item.thumbnail_upload_id].compact.uniq
        uploads = upload_ids.present? ? ::Upload.where(id: upload_ids).to_a : []

        delete_managed_assets_safely!(item)
        uploads.each { |upload| destroy_upload_safely!(upload) }
        log_admin_delete!(item, note: note)
        item.destroy!
      end

      render_json_dump(ok: true, public_id: public_id, deleted: true, message: "Item deleted.")
    rescue => e
      render_json_error(e.message, status: 422)
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
        processing_stale: processing_stale?(item),
        processing_stale_after_minutes: processing_stale_after_minutes,
      )
    rescue => e
      render_json_error(e.message, status: 422)
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
      render_json_error(e.message, status: 422)
    end

    def verify_target
      item = load_item!
      target_profile = params[:target_profile].to_s.presence || "target"
      result = ::MediaGallery::MigrationVerify.verify!(item, target_profile: target_profile, requested_by: current_user.username)
      render_json_dump(result)
    rescue => e
      render_json_error(e.message, status: 422)
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

      render_json_dump(ok: true, public_id: item.public_id, migration_copy: state)
    rescue => e
      render_json_error(e.message, status: 422)
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

      render_json_dump(ok: true, public_id: item.public_id, migration_switch: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    def cleanup_source
      item = load_item!
      state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_cleanup: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    def rollback_to_source
      item = load_item!
      state = ::MediaGallery::MigrationRollback.rollback!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_rollback: state)
    rescue => e
      render_json_error(e.message, status: 422)
    end

    def finalize_migration
      item = load_item!
      state = ::MediaGallery::MigrationFinalize.finalize!(item, requested_by: current_user.username, force: boolean_param(:force))
      render_json_dump(ok: true, public_id: item.public_id, migration_finalize: state)
    rescue => e
      render_json_error(e.message, status: 422)
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

      return render_json_error("no_queued_state_to_clear", status: 422) if changed.empty?

      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      render_json_dump(ok: true, public_id: item.public_id, cleared: changed, message: "Queued state cleared.")
    rescue => e
      render_json_error(e.message, status: 422)
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

      profile = params[:profile].to_s.strip
      if profile.present? && profile != "all"
        scope = scope.where(managed_storage_profile: profile)
      end

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

    def search_limit
      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 100 if limit > 100
      limit
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

    def boolean_param(name)
      ActiveModel::Type::Boolean.new.cast(params[name])
    end

    def normalize_tags_param(value)
      raw = value
      raw = raw.split(",") if raw.is_a?(String)
      Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq
    end

    def serialize_search_item(item, has_hls:)
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
        hidden: item.admin_hidden?,
        hidden_reason: visibility["reason"],
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
        hidden: item.admin_hidden?,
        visibility: visibility,
        processing: processing_metadata(item),
        allowed_tags: ::MediaGallery::Permissions.allowed_tags,
        management_log: item.admin_management_log,
      }
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

    def delete_managed_assets_safely!(item)
      public_id = item.public_id.to_s

      begin
        ["main", "thumbnail"].each do |role_name|
          role = ::MediaGallery::AssetManifest.role_for(item, role_name)
          next if role.blank?
          next unless %w[local s3].include?(role["backend"].to_s)

          store = ::MediaGallery::StorageSettingsResolver.build_store(role["backend"])
          store&.delete(role["key"].to_s)
        end

        hls_role = ::MediaGallery::AssetManifest.role_for(item, "hls")
        if hls_role.present? && %w[local s3].include?(hls_role["backend"].to_s)
          store = ::MediaGallery::StorageSettingsResolver.build_store(hls_role["backend"])
          prefix = hls_role["key_prefix"].presence || hls_role["key"].presence || ::MediaGallery::PrivateStorage.hls_root_rel_dir(public_id)
          store&.delete_prefix(prefix.to_s) if prefix.present?
        end
      rescue => e
        Rails.logger.warn("[media_gallery] failed to delete managed assets public_id=#{public_id}: #{e.class}: #{e.message}")
      end

      begin
        dir = ::MediaGallery::PrivateStorage.item_private_dir(public_id)
        FileUtils.rm_rf(dir) if dir.present? && Dir.exist?(dir)
      rescue => e
        Rails.logger.warn("[media_gallery] failed to delete private dir public_id=#{public_id}: #{e.class}: #{e.message}")
      end

      begin
        odir = ::MediaGallery::PrivateStorage.item_original_dir(public_id)
        FileUtils.rm_rf(odir) if odir.present? && Dir.exist?(odir)
      rescue => e
        Rails.logger.warn("[media_gallery] failed to delete original export dir public_id=#{public_id}: #{e.class}: #{e.message}")
      end
    end

    def destroy_upload_safely!(upload)
      return if upload.blank?

      if defined?(::UploadDestroyer)
        ::UploadDestroyer.new(Discourse.system_user, upload).destroy
      else
        upload.destroy!
      end
    rescue => e
      Rails.logger.warn("[media_gallery] failed to destroy upload id=#{upload&.id}: #{e.class}: #{e.message}")
    end

    def log_admin_delete!(item, note: nil)
      Rails.logger.info(
        "[media_gallery] admin_delete public_id=#{item.public_id} admin=#{current_user.username} note=#{note.to_s.inspect} title=#{item.title.to_s.inspect}"
      )
    end
  end
end
