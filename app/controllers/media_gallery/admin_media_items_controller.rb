# frozen_string_literal: true

module ::MediaGallery
  # Admin-only helper endpoints.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    # Returns a small list for quickly selecting a public_id in the admin UI.
    def search
      q = params[:q].to_s.strip
      limit = 20

      scope = ::MediaGallery::MediaItem.includes(:user).order(created_at: :desc)

      if q.present?
        if q =~ /\A\d+\z/
          # Numeric input: treat as media_item id.
          scope = scope.where(id: q.to_i)
        else
          like = "%#{q}%"
          scope = scope.where(
            "public_id ILIKE :q OR title ILIKE :q",
            q: like
          )
        end
      end

      items = scope.limit(limit).map do |item|
        {
          id: item.id,
          public_id: item.public_id,
          title: item.title,
          status: item.status,
          created_at: item.created_at,
          user_id: item.user_id,
          username: item.user&.username,
        }
      end

      render_json_dump(items: items)
    end

    # GET /admin/plugins/media-gallery/media-items/:public_id/diagnostics.json
    def diagnostics
      item = find_item!
      render_json_dump(
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        status: item.status,
        error_message: item.error_message,
        managed_storage_backend: item.managed_storage_backend,
        managed_storage_profile: item.managed_storage_profile,
        delivery_mode: item.delivery_mode,
        roles: diagnostics_roles(item),
        processing: processing_metadata(item),
      )
    end

    # POST /admin/plugins/media-gallery/media-items/:public_id/retry-processing.json
    def retry_processing
      item = find_item!
      force = ActiveModel::Type::Boolean.new.cast(params[:force])

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
      meta["processing"] = processing

      item.update!(status: "queued", error_message: nil, extra_metadata: meta)
      ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id, force_run: force)

      render_json_dump(ok: true, public_id: item.public_id, status: item.status)
    end

    private

    def find_item!
      item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank?
      item
    end

    def processing_metadata(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta["processing"]
      value.is_a?(Hash) ? value : {}
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
      when "local"
        if role_name == "hls"
          prefix = role["key"].to_s
          store = ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_root_path)
          store.list_prefix(prefix, limit: 1).any?
        else
          store = ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_root_path)
          store.exists?(role["key"])
        end
      when "s3"
        store = ::MediaGallery::StorageSettingsResolver.build_store("s3")
        return false if store.blank?

        if role_name == "hls"
          store.list_prefix(role["key"].to_s, limit: 1).any?
        else
          store.exists?(role["key"])
        end
      else
        false
      end
    rescue => e
      "error: #{e.class}: #{e.message}"
    end
  end
end
