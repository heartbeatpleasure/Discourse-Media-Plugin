# frozen_string_literal: true

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in

    before_action :ensure_can_view,
                  only: [:index, :show, :status, :thumbnail, :play, :my, :like, :unlike, :retry_processing]

    before_action :ensure_can_upload, only: [:create]

    def index
      page = (params[:page].presence || 1).to_i
      per_page = [(params[:per_page].presence || 24).to_i, 100].min
      offset = (page - 1) * per_page

      items = MediaGallery::MediaItem.where(status: "ready").order(created_at: :desc)

      if params[:media_type].present? && MediaGallery::MediaItem::TYPES.include?(params[:media_type].to_s)
        items = items.where(media_type: params[:media_type].to_s)
      end

      if params[:gender].present? && MediaGallery::MediaItem::GENDERS.include?(params[:gender].to_s)
        items = items.where(gender: params[:gender].to_s)
      end

      if params[:tags].present?
        tags = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].to_s.split(",")
        tags = tags.map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq
        items = items.where("tags @> ARRAY[?]::varchar[]", tags) if tags.present?
      end

      total = items.count
      items = items.offset(offset).limit(per_page)

      render_json_dump(
        media_items: serialize_data(items, MediaGallery::MediaItemSerializer, root: false),
        page: page,
        per_page: per_page,
        total: total
      )
    end

    def my
      page = (params[:page].presence || 1).to_i
      per_page = [(params[:per_page].presence || 24).to_i, 100].min
      offset = (page - 1) * per_page

      items = MediaGallery::MediaItem.where(user_id: current_user.id).order(created_at: :desc)

      if params[:status].present? && MediaGallery::MediaItem::STATUSES.include?(params[:status].to_s)
        items = items.where(status: params[:status].to_s)
      end

      total = items.count
      items = items.offset(offset).limit(per_page)

      render_json_dump(
        media_items: serialize_data(items, MediaGallery::MediaItemSerializer, root: false),
        page: page,
        per_page: per_page,
        total: total
      )
    end

    def create
      upload_id = params[:upload_id].to_i
      return render_json_error("invalid_upload_id") if upload_id <= 0

      title = params[:title].to_s.strip
      return render_json_error("title_required") if title.blank?

      upload = ::Upload.find_by(id: upload_id)
      return render_json_error("upload_not_found") if upload.blank?

      if upload.user_id.present? && upload.user_id != current_user.id && !(current_user&.staff? || current_user&.admin?)
        return render_json_error("upload_not_owned")
      end

      # Optional extra global cap (plugin-level)
      max_mb = SiteSetting.media_gallery_max_upload_size_mb.to_i
      if max_mb.positive?
        max_bytes = max_mb * 1024 * 1024
        return render_json_error("upload_too_large") if upload.filesize.to_i > max_bytes
      end

      media_type = infer_media_type(upload)
      return render_json_error("unsupported_file_type") unless MediaGallery::MediaItem::TYPES.include?(media_type)
      return render_json_error("unsupported_file_extension") unless allowed_extension_for_type?(upload, media_type)

      # Per-type caps (plugin-level)
      if (err = enforce_type_size_limit(upload, media_type))
        return render_json_error(err)
      end

      # Ensure private storage roots exist early, so we fail fast with a clear error.
      begin
        preflight_private_storage!
      rescue => e
        Rails.logger.error(
          "[media_gallery] private storage preflight failed request_id=#{request.request_id} error=#{e.class}: #{e.message}"
        )
        return render_json_error("private_storage_unavailable", status: 500, message: "private_storage_unavailable: #{e.message}"[0, 300])
      end

      tags = params[:tags]
      tags = tags.is_a?(Array) ? tags : tags.to_s.split(",") if tags.present?

      extra_metadata = params[:extra_metadata]
      extra_metadata = {} if extra_metadata.blank?

      transcode_images =
        if SiteSetting.respond_to?(:media_gallery_transcode_images_to_jpg)
          SiteSetting.media_gallery_transcode_images_to_jpg
        else
          false
        end

      private_storage = MediaGallery::PrivateStorage.enabled?

      status =
        if private_storage
          "queued"
        elsif media_type == "image"
          transcode_images ? "queued" : "ready"
        else
          "queued"
        end

      item = MediaGallery::MediaItem.create!(
        public_id: SecureRandom.uuid,
        user_id: current_user.id,
        title: title,
        description: params[:description].to_s,
        extra_metadata: (extra_metadata.is_a?(Hash) ? extra_metadata : { "raw" => extra_metadata.to_s }),
        media_type: media_type,
        gender: params[:gender].to_s.presence,
        tags: (tags || []).map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq,
        original_upload_id: upload.id,
        status: status,
        processed_upload_id: (status == "ready" && !private_storage ? upload.id : nil),
        thumbnail_upload_id: (status == "ready" && !private_storage ? upload.id : nil),
        width: (status == "ready" && !private_storage ? upload.width : nil),
        height: (status == "ready" && !private_storage ? upload.height : nil),
        duration_seconds: nil,
        filesize_original_bytes: upload.filesize,
        filesize_processed_bytes: (status == "ready" && !private_storage ? upload.filesize : nil)
      )

      if status == "queued"
        begin
          ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id)
        rescue => e
          Rails.logger.error("[media_gallery] enqueue failed item_id=#{item.id}: #{e.class}: #{e.message}")
        end
      end

      render_json_dump(public_id: item.public_id, status: item.status)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[media_gallery] create validation failed request_id=#{request.request_id} errors=#{e.record.errors.full_messages.join(", ")}"
      )
      render_json_error("validation_error", status: 422, extra: { details: e.record.errors.full_messages })
    rescue => e
      Rails.logger.error(
        "[media_gallery] create failed request_id=#{request.request_id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(40)&.join("\n")}"
      )
      render_json_error("internal_error", status: 500)
    end

    # POST /media/:public_id/retry
    # Requeues processing after a failure (or if stuck). Owner/staff only.
    def retry_processing
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless can_manage_item?(item)

      if item.ready?
        return render_json_error("already_ready")
      end

      item.update!(status: "queued", error_message: nil)

      begin
        ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id)
      rescue => e
        Rails.logger.error("[media_gallery] retry enqueue failed item_id=#{item.id}: #{e.class}: #{e.message}")
        return render_json_error("enqueue_failed")
      end

      render_json_dump(public_id: item.public_id, status: item.status)
    rescue => e
      Rails.logger.error("[media_gallery] retry failed request_id=#{request.request_id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(40)&.join("\n")}")
      render_json_error("internal_error (request_id=#{request.request_id})")
    end

    def show
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound if !item.ready? && !can_manage_item?(item)
      render_json_dump(serialize_data(item, MediaGallery::MediaItemSerializer, root: false))
    end

    def status
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless can_manage_item?(item)

      render_json_dump(
        public_id: item.public_id,
        status: item.status,
        error_message: item.error_message,
        playable: item.ready?
      )
    end

    def play
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      return render_json_error("not_found", status: 404) if item.blank?

      unless item.ready?
        if item.status == "failed"
          # Keep message short; job already stores a compact error_message.
          return render_json_error(
            "processing_failed",
            status: 422,
            message: item.error_message.presence || "processing_failed",
            extra: { status: item.status }
          )
        end

        return render_json_error("not_ready", status: 409, extra: { status: item.status })
      end

      upload_id = item.processed_upload_id

      if upload_id.blank?
        return render_json_error("private_storage_disabled", status: 500) unless MediaGallery::PrivateStorage.enabled?

        processed_path = MediaGallery::PrivateStorage.processed_abs_path(item)
        return render_json_error("processed_file_missing", status: 404) unless File.exist?(processed_path)
      end

      payload = {
        "item_id" => item.id,
        "upload_id" => upload_id,
        "exp" => (Time.now.to_i + SiteSetting.media_gallery_stream_ttl_seconds.to_i)
      }

      token = MediaGallery::StreamToken.encode(payload)
      expires_at = payload["exp"]

      # keep this lightweight: avoid callbacks/validations
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      ext = (item.media_type == "audio" ? "mp3" : "mp4")

      render_json_dump(
        stream_url: "/media/stream/#{token}.#{ext}",
        expires_at: expires_at,
        playable: true
      )
    rescue => e
      Rails.logger.error(
        "[media_gallery] play failed request_id=#{request.request_id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}"
      )
      render_json_error("internal_error", status: 500)
    end


    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      upload_id = item.thumbnail_upload_id

      if upload_id.blank?
        raise Discourse::NotFound unless MediaGallery::PrivateStorage.enabled?
        raise Discourse::NotFound unless File.exist?(MediaGallery::PrivateStorage.thumbnail_abs_path(item))
        upload_id = nil
      end

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: upload_id,
        kind: "thumbnail",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)

      ext =
        if upload_id.present?
          item.thumbnail_upload&.extension.to_s.downcase
        else
          "jpg"
        end

      redirect_to(ext.present? ? "/media/stream/#{token}.#{ext}" : "/media/stream/#{token}")
    end

    def like
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      like = MediaGallery::MediaLike.find_by(media_item_id: item.id, user_id: current_user.id)
      if like.blank?
        MediaGallery::MediaLike.create!(media_item_id: item.id, user_id: current_user.id)
        MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = likes_count + 1")
      end

      render_json_dump(success: true)
    end

    def unlike
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      like = MediaGallery::MediaLike.find_by(media_item_id: item.id, user_id: current_user.id)
      raise Discourse::NotFound if like.blank?

      like.destroy!
      MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = GREATEST(likes_count - 1, 0)")

      render_json_dump(success: true)
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end

    def ensure_can_upload
      raise Discourse::NotFound unless MediaGallery::Permissions.can_upload?(guardian)
    end

    def can_manage_item?(item)
      (current_user&.staff? || current_user&.admin?) || (guardian.user&.id == item.user_id)
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.blank?
      item
    end

    # Consistent JSON errors for API clients.
    # Always returns at least { errors: [..], error_code: "..", request_id: ".." }.
    def render_json_error(error_code, status: 422, message: nil, extra: nil)
      code = error_code.to_s
      payload = {
        errors: [message.presence || code],
        error_type: "media_gallery_error",
        error_code: code,
        request_id: request&.request_id
      }
      payload.merge!(extra) if extra.is_a?(Hash)
      render json: payload, status: status
    end

    def preflight_private_storage!
      return unless MediaGallery::PrivateStorage.enabled?

      MediaGallery::PrivateStorage.ensure_private_root!
      MediaGallery::PrivateStorage.ensure_original_export_root!
    end

    # Plugin-level per-type size enforcement (MB).
    # Returns an error key string when too large, or nil when OK.
    def enforce_type_size_limit(upload, media_type)
      size_bytes = upload.filesize.to_i

      max_mb =
        case media_type
        when "video"
          SiteSetting.respond_to?(:media_gallery_max_video_size_mb) ? SiteSetting.media_gallery_max_video_size_mb.to_i : 0
        when "audio"
          SiteSetting.respond_to?(:media_gallery_max_audio_size_mb) ? SiteSetting.media_gallery_max_audio_size_mb.to_i : 0
        when "image"
          SiteSetting.respond_to?(:media_gallery_max_image_size_mb) ? SiteSetting.media_gallery_max_image_size_mb.to_i : 0
        else
          0
        end

      return nil unless max_mb.positive?

      max_bytes = max_mb * 1024 * 1024
      return nil if size_bytes <= max_bytes

      case media_type
      when "video" then "video_too_large"
      when "audio" then "audio_too_large"
      when "image" then "image_too_large"
      else "upload_too_large"
      end
    end

    # Discourse Upload changed across versions; some have `mime_type`, some had `content_type`.
    def upload_mime(upload)
      if upload.respond_to?(:mime_type) && upload.mime_type.present?
        upload.mime_type.to_s.downcase
      elsif upload.respond_to?(:content_type) && upload.content_type.present?
        upload.content_type.to_s.downcase
      else
        ""
      end
    end

    def infer_media_type(upload)
      ext = upload.extension.to_s.downcase
      mime = upload_mime(upload)

      return "image" if (mime.start_with?("image/") && MediaGallery::MediaItem::IMAGE_EXTS.include?(ext)) ||
                        MediaGallery::MediaItem::IMAGE_EXTS.include?(ext)

      return "audio" if (mime.start_with?("audio/") && MediaGallery::MediaItem::AUDIO_EXTS.include?(ext)) ||
                        MediaGallery::MediaItem::AUDIO_EXTS.include?(ext)

      return "video" if (mime.start_with?("video/") && MediaGallery::MediaItem::VIDEO_EXTS.include?(ext)) ||
                        MediaGallery::MediaItem::VIDEO_EXTS.include?(ext)

      nil
    end

    def allowed_extension_for_type?(upload, media_type)
      ext = upload.extension.to_s.downcase.sub(/\A\./, "")

      allowed =
        case media_type
        when "image" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_image_extensions)
        when "audio" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_audio_extensions)
        when "video" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_video_extensions)
        else []
        end

      # Empty setting means "use built-in defaults".
      if allowed.blank?
        allowed =
          case media_type
          when "image" then MediaGallery::MediaItem::IMAGE_EXTS
          when "audio" then MediaGallery::MediaItem::AUDIO_EXTS
          when "video" then MediaGallery::MediaItem::VIDEO_EXTS
          else []
          end
      end

      allowed.map { |e| e.to_s.downcase.sub(/\A\./, "") }.include?(ext)
    end
  end
end
