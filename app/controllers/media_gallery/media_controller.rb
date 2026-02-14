# frozen_string_literal: true

require "digest/sha1"
require "erb"
require "fileutils"

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in

    before_action :ensure_can_view,
                   only: [:index, :plugin_config, :show, :status, :thumbnail, :play, :my, :like, :unlike, :retry_processing, :destroy]

    before_action :ensure_can_upload, only: [:create]

    # NOTE: do not name this action `config` (conflicts with ActionController::Base#config)
    def plugin_config
      wm_enabled = !!SiteSetting.media_gallery_watermark_enabled

      choices = wm_enabled ? MediaGallery::Watermark.safe_choices_for_client(user: current_user) : []
      default_choice = wm_enabled ? MediaGallery::Watermark.default_choice_for_client(user: current_user) : nil

      # Legacy shape expected by the separate theme component:
      # presets: [{id,label}] and default_preset_id
      legacy_presets = choices.map { |c| { id: c[:value], label: c[:label] } }
      legacy_default_preset_id = default_choice&.dig(:value)

      render_json_dump(
        watermark: {
          enabled: wm_enabled,
          user_can_toggle: wm_enabled && SiteSetting.media_gallery_watermark_user_can_toggle,
          # legacy key name kept for backwards compatibility in the separate theme component
          user_can_choose_preset: wm_enabled && SiteSetting.media_gallery_watermark_user_can_choose_preset,
          default_preset_id: legacy_default_preset_id,
          default_text: SiteSetting.media_gallery_watermark_default_text.to_s.presence,
          presets: legacy_presets,
          choices: choices,
          default_choice: default_choice,
          position: MediaGallery::Watermark.global_position,
          opacity_percent: MediaGallery::Watermark.global_opacity_percent,
          size_percent: MediaGallery::Watermark.global_size_percent,
          margin_px: MediaGallery::Watermark.global_margin_px
        }
      )
    end
    
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
        if tags.present?
          # Be defensive about the DB column type.
          # Some installs may have tags as text[]; others as varchar[] (older schema).
          # Postgres will 500 with "operator does not exist" if the array types differ.
          col_type = MediaGallery::MediaItem.columns_hash["tags"]&.sql_type.to_s
          if col_type.include?("character varying") || col_type.include?("varchar")
            items = items.where("tags @> ARRAY[?]::varchar[]", tags)
          else
            items = items.where("tags @> ARRAY[?]::text[]", tags)
          end
        end
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

      subject = params[:gender].to_s.strip
      return render_json_error("gender_required") if subject.blank?
      unless MediaGallery::MediaItem::GENDERS.include?(subject)
        return render_json_error("invalid_gender")
      end

      authorized = ActiveModel::Type::Boolean.new.cast(params[:authorized])
      return render_json_error("authorization_required") unless authorized

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

            # Watermark (burned into processed video/image outputs) - configured server-side via presets.
      watermark_enabled = false
      watermark_preset_id = nil

      if SiteSetting.media_gallery_watermark_enabled && (media_type == "video" || media_type == "image")
        if SiteSetting.media_gallery_watermark_user_can_toggle
          watermark_enabled = ActiveModel::Type::Boolean.new.cast(params[:watermark_enabled])
          watermark_enabled = true if params[:watermark_enabled].nil?
        else
          watermark_enabled = true
        end

        if watermark_enabled && SiteSetting.media_gallery_watermark_user_can_choose_preset
          # Accept both param names (older clients send watermark_preset_id)
          candidate = (params[:watermark_choice].presence || params[:watermark_preset_id]).to_s.strip
          if candidate.present?
            unless MediaGallery::Watermark.choice_allowed?(candidate)
              # Keep legacy error key for older clients, but message now means "option".
              return render_json_error("invalid_watermark_preset", status: 422)
            end
            watermark_preset_id = candidate
          end
        end
      end

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
      needs_processing =
        if private_storage
          true
        elsif media_type == "image"
          transcode_images || watermark_enabled
        else
          true
        end

      status = needs_processing ? "queued" : "ready"

      item = MediaGallery::MediaItem.create!(
        public_id: SecureRandom.uuid,
        user_id: current_user.id,
        title: title,
        description: params[:description].to_s,
        extra_metadata: (extra_metadata.is_a?(Hash) ? extra_metadata : { "raw" => extra_metadata.to_s }),
        media_type: media_type,
        watermark_enabled: watermark_enabled,
        watermark_preset_id: watermark_preset_id,
        gender: subject.presence,
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

    # DELETE /media/:public_id
    # Permanently deletes a media item and associated files. Owner/staff only.
    def destroy
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless can_manage_item?(item)

      item.with_lock do
        public_id = item.public_id.to_s

        upload_ids =
          [
            item.original_upload_id,
            item.processed_upload_id,
            item.thumbnail_upload_id
          ].compact.uniq

        uploads = upload_ids.present? ? ::Upload.where(id: upload_ids).to_a : []

        # Remove private-storage outputs (safe no-op if not present)
        delete_private_storage_dirs_safely!(public_id)

        # Remove uploads (safe no-op if already deleted)
        uploads.each do |u|
          destroy_upload_safely!(u)
        end

        # Finally delete DB record (also deletes likes via dependent: :delete_all)
        item.destroy!
      end

      render_json_dump(success: true)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error(
        "[media_gallery] destroy failed request_id=#{request.request_id} public_id=#{params[:public_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(40)&.join("\n")}"
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
      return unless enforce_play_rate_limits!

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

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: upload_id.presence,
        kind: "main",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)
      expires_at = payload["exp"]

      # keep this lightweight: avoid callbacks/validations
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      render_json_dump(
        # Do not include a file extension in the URL.
        #
        # Rationale:
        # - Avoids exposing ".mp4" etc in the DOM.
        # - Keeps the URL less obviously "downloadable".
        # - StreamController sets the correct Content-Type based on the token payload.
        stream_url: "/media/stream/#{token}",
        expires_at: expires_at,
        playable: true
      )
    rescue => e
      Rails.logger.error(
        "[media_gallery] play failed request_id=#{request.request_id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}"
      )
      render_json_error("internal_error", status: 500)
    end

    # Optional per-IP rate limit for issuing play tokens.
    #
    # IMPORTANT: We intentionally rate limit the token issuance endpoint (/media/:id/play)
    # and not the streaming endpoint (/media/stream/:token), because video playback uses
    # multiple range requests and seeks.
    def enforce_play_rate_limits!
      per_min = SiteSetting.media_gallery_play_tokens_per_ip_per_minute.to_i
      return true if per_min <= 0

      ip = request.remote_ip.to_s
      key = "media_gallery_play_tokens_ip_#{ip}"

      RateLimiter.new(nil, key, per_min, 1.minute).performed!
      true
    rescue RateLimiter::LimitExceeded
      render_json_error("rate_limited", status: 429)
      false
    end

    private :enforce_play_rate_limits!

    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      # Thumbnails are served via a stable URL so browsers can cache them efficiently.
      # Streaming URLs remain tokenized (short TTL) for the main media bytes.
      #
      # We still require a logged-in user + view permission (before_action), but the response
      # itself is cacheable in the user's browser (private cache).

      local_path, content_type, filename = resolve_thumbnail_file!(item)

      if local_path.blank? || !File.exist?(local_path)
        return render_default_thumbnail(item)
      end

      file_mtime = File.mtime(local_path).utc
      file_size = File.size(local_path).to_i
      etag = Digest::SHA1.hexdigest("thumb|#{item.public_id}|#{file_size}|#{file_mtime.to_i}")

      max_age = thumbnail_cache_max_age_seconds
      response.headers["Cache-Control"] = thumbnail_cache_control_header(max_age)
      response.headers["X-Content-Type-Options"] = "nosniff"

      # Handle conditional GET/HEAD (ETag + Last-Modified)
      return unless stale?(etag: etag, last_modified: file_mtime, public: false)

      response.headers["Content-Disposition"] = "inline; filename=\"#{filename}\""
      response.headers["Content-Type"] = content_type

      if request.head?
        response.headers["Content-Length"] = file_size.to_s
        return head :ok
      end

      # Hardening: prefer send_data over send_file for thumbnails.
      # Some proxy setups (Rack::Sendfile / X-Accel-Redirect) can behave oddly for
      # small/private files served through Rails. Reading and sending bytes directly
      # avoids those edge-cases.
      data = File.binread(local_path)
      response.headers["Content-Length"] = data.bytesize.to_s
      send_data(data, disposition: "inline", filename: filename, type: content_type)
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

    def delete_private_storage_dirs_safely!(public_id)
      begin
        dir = MediaGallery::PrivateStorage.item_private_dir(public_id)
        FileUtils.rm_rf(dir) if dir.present? && Dir.exist?(dir)
      rescue => e
        Rails.logger.warn("[media_gallery] failed to delete private dir public_id=#{public_id}: #{e.class}: #{e.message}")
      end

      begin
        odir = MediaGallery::PrivateStorage.item_original_dir(public_id)
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

    def resolve_thumbnail_file!(item)
      # Upload-backed thumbnail (private storage off)
      if item.thumbnail_upload_id.present?
        upload = item.thumbnail_upload
        return [nil, nil, nil] if upload.blank?

        local_path = MediaGallery::UploadPath.local_path_for(upload)
        return [nil, nil, nil] if local_path.blank?

        ext = upload.extension.to_s.downcase
        filename = "media-#{item.public_id}-thumb"
        filename = "#{filename}.#{ext}" if ext.present?

        content_type =
          if upload.respond_to?(:mime_type) && upload.mime_type.present?
            upload.mime_type.to_s
          elsif upload.respond_to?(:content_type) && upload.content_type.present?
            upload.content_type.to_s
          else
            (defined?(Rack::Mime) ? Rack::Mime.mime_type(".#{ext}") : "image/jpeg")
          end
        content_type = "image/jpeg" if content_type.blank?

        return [local_path, content_type, filename]
      end

      # Private storage thumbnail (default)
      return [nil, nil, nil] unless MediaGallery::PrivateStorage.enabled?

      local_path = MediaGallery::PrivateStorage.thumbnail_abs_path(item)
      filename = "media-#{item.public_id}-thumb.jpg"
      content_type = "image/jpeg"

      [local_path, content_type, filename]
    end

    def thumbnail_cache_max_age_seconds
      # seconds; 0 disables caching in the browser (forces revalidation)
      v =
        if SiteSetting.respond_to?(:media_gallery_thumbnail_cache_max_age_seconds)
          SiteSetting.media_gallery_thumbnail_cache_max_age_seconds.to_i
        else
          86_400
        end

      v = 0 if v.negative?
      v = 31_536_000 if v > 31_536_000 # clamp to 1 year
      v
    end

    def thumbnail_cache_control_header(max_age_seconds)
      max_age = max_age_seconds.to_i
      if max_age <= 0
        "private, max-age=0, must-revalidate"
      else
        "private, max-age=#{max_age}"
      end
    end

    def render_default_thumbnail(item)
      svg = default_thumbnail_svg(item)

      # If a real thumbnail appears later (e.g. reprocess), we don't want a long-lived placeholder cache.
      # Cache placeholders briefly.
      max_age = [thumbnail_cache_max_age_seconds, 60].min
      last_modified = (item.updated_at || Time.now).utc
      etag = Digest::SHA1.hexdigest("thumb-missing|v1|#{item.public_id}|#{last_modified.to_i}")

      response.headers["Cache-Control"] = thumbnail_cache_control_header(max_age)
      response.headers["X-Content-Type-Options"] = "nosniff"

      return unless stale?(etag: etag, last_modified: last_modified, public: false)

      filename = "media-#{item.public_id}-thumb.svg"
      response.headers["Content-Disposition"] = "inline; filename=\"#{filename}\""
      response.headers["Content-Type"] = "image/svg+xml"

      if request.head?
        response.headers["Content-Length"] = svg.bytesize.to_s
        return head :ok
      end

      render plain: svg, content_type: "image/svg+xml"
    end

    def default_thumbnail_svg(item)
      title = item.title.to_s
      title = title[0, 60]
      safe_title = ERB::Util.html_escape(title)

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180" role="img" aria-label="Thumbnail">
          <rect width="320" height="180" fill="#f2f2f2"/>
          <rect x="8" y="8" width="304" height="164" fill="#ffffff" stroke="#d9d9d9"/>
          <g fill="#666666" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif">
            <text x="160" y="86" font-size="16" text-anchor="middle">No thumbnail</text>
            <text x="160" y="112" font-size="12" text-anchor="middle">#{safe_title}</text>
          </g>
        </svg>
      SVG
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
