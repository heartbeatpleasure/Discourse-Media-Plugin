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
                   only: [:index, :show, :status, :thumbnail, :play, :heartbeat, :revoke, :my, :like, :unlike, :retry_processing, :destroy, :update]

    before_action :ensure_can_upload, only: [:create]
    before_action :ensure_secure_write_request!, only: [:create, :update, :destroy, :retry_processing, :like, :unlike, :heartbeat, :revoke]
    before_action :ensure_secure_play_request!, only: [:play]

    # NOTE: do not name this action `config` (conflicts with ActionController::Base#config)
    def plugin_config
      can_view = MediaGallery::Permissions.can_view?(guardian)
      can_upload = MediaGallery::Permissions.can_upload?(guardian)
      wm_enabled = can_upload && !!SiteSetting.media_gallery_watermark_enabled

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
        },
        playback_overlay: can_view ? MediaGallery::PlaybackOverlay.client_enabled_config : nil,
        permissions: media_gallery_permissions_payload,
        upload_policy: can_upload ? upload_policy_payload : nil
      )
    end
    
    def index
      page = positive_page_param(params[:page], default: 1)
      per_page = bounded_per_page_param(params[:per_page], default: 24, max: 100)
      offset = (page - 1) * per_page

      items = apply_admin_visibility_filter(MediaGallery::MediaItem.where(status: "ready")).order(created_at: :desc)

      if params[:media_type].present? && MediaGallery::MediaItem::TYPES.include?(params[:media_type].to_s)
        items = items.where(media_type: params[:media_type].to_s)
      end

      if params[:gender].present? && MediaGallery::MediaItem::GENDERS.include?(params[:gender].to_s)
        items = items.where(gender: params[:gender].to_s)
      end

      if params[:tags].present?
        tags = ::MediaGallery::TextSanitizer.tag_list(
          params[:tags],
          max_count: [SiteSetting.media_gallery_max_tags_per_item.to_i, 50].max,
          max_length: 40,
          allowed: MediaGallery::Permissions.allowed_tags
        )
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
      page = positive_page_param(params[:page], default: 1)
      per_page = bounded_per_page_param(params[:per_page], default: 24, max: 100)
      offset = (page - 1) * per_page

      items = apply_admin_visibility_filter(MediaGallery::MediaItem.where(user_id: current_user.id)).order(created_at: :desc)

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

      title = ::MediaGallery::TextSanitizer.plain_text(params[:title], max_length: 200, allow_newlines: false)
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
        if upload.filesize.to_i > max_bytes
          return render_json_error(
            "upload_too_large",
            message: upload_too_large_message(max_mb: max_mb, actual_bytes: upload.filesize.to_i),
            extra: {
              details: {
                scope: "plugin",
                actual_bytes: upload.filesize.to_i,
                actual_mb: rounded_mb(upload.filesize.to_i),
                max_mb: max_mb
              }
            }
          )
        end
      end

      media_type = infer_media_type(upload)
      unless MediaGallery::MediaItem::TYPES.include?(media_type)
        return render_json_error(
          "unsupported_file_type",
          message: unsupported_file_type_message(upload),
          extra: {
            details: unsupported_file_type_details(upload)
          }
        )
      end

      unless allowed_extension_for_type?(upload, media_type)
        return render_json_error(
          "unsupported_file_extension",
          message: unsupported_file_extension_message(upload, media_type),
          extra: {
            details: unsupported_file_extension_details(upload, media_type)
          }
        )
      end

      if (duration_limit_error = preflight_duration_limit_error(upload, media_type))
        return render_json_error(
          duration_limit_error[:error_code],
          message: duration_limit_error[:message],
          extra: { details: duration_limit_error[:details] }
        )
      end

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
        return render_json_error(err[:error_code], message: err[:message], extra: { details: err[:details] })
      end

      # Ensure private storage roots exist early, so we fail fast with a clear error.
      begin
        preflight_private_storage!
      rescue => e
        Rails.logger.error(
          "[media_gallery] private storage preflight failed request_id=#{request.request_id} error=#{e.class}: #{e.message}"
        )
        return render_json_error("private_storage_unavailable", status: 500, message: "Private storage is currently unavailable. Please contact an administrator.")
      end

      tags = ::MediaGallery::TextSanitizer.tag_list(
        params[:tags],
        max_count: [SiteSetting.media_gallery_max_tags_per_item.to_i, 10].max,
        max_length: 40,
        allowed: MediaGallery::Permissions.allowed_tags
      )

      extra_metadata = params[:extra_metadata]
      extra_metadata = {} if extra_metadata.blank?

      transcode_images =
        if SiteSetting.respond_to?(:media_gallery_transcode_images_to_jpg)
          SiteSetting.media_gallery_transcode_images_to_jpg
        else
          false
        end

      managed_storage = ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?
      needs_processing =
        if managed_storage
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
        description: ::MediaGallery::TextSanitizer.plain_text(params[:description], max_length: 4000, allow_newlines: true).presence,
        extra_metadata: (extra_metadata.is_a?(Hash) ? extra_metadata : { "raw" => extra_metadata.to_s }),
        media_type: media_type,
        watermark_enabled: watermark_enabled,
        watermark_preset_id: watermark_preset_id,
        gender: subject.presence,
        tags: tags,
        original_upload_id: upload.id,
        status: status,
        processed_upload_id: (status == "ready" && !managed_storage ? upload.id : nil),
        thumbnail_upload_id: (status == "ready" && !managed_storage ? upload.id : nil),
        width: (status == "ready" && !managed_storage ? upload.width : nil),
        height: (status == "ready" && !managed_storage ? upload.height : nil),
        duration_seconds: nil,
        filesize_original_bytes: upload.filesize,
        filesize_processed_bytes: (status == "ready" && !managed_storage ? upload.filesize : nil),
        managed_storage_backend: (managed_storage ? ::MediaGallery::StorageSettingsResolver.active_backend : nil),
        managed_storage_profile: (managed_storage ? ::MediaGallery::StorageSettingsResolver.active_profile_key : nil),
        delivery_mode: (managed_storage ? managed_delivery_mode_for_backend(::MediaGallery::StorageSettingsResolver.active_backend) : nil)
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

    # PUT/PATCH /media/:public_id
    # Updates editable metadata for a media item. Owner/staff only.
    def update
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless can_manage_item?(item)

      title = ::MediaGallery::TextSanitizer.plain_text(params[:title], max_length: 200, allow_newlines: false)
      return render_json_error("title_required") if title.blank?

      subject = params[:gender].to_s.strip
      return render_json_error("gender_required") if subject.blank?
      unless MediaGallery::MediaItem::GENDERS.include?(subject)
        return render_json_error("invalid_gender")
      end

      description = ::MediaGallery::TextSanitizer.plain_text(params[:description], max_length: 4000, allow_newlines: true)
      tags = ::MediaGallery::TextSanitizer.tag_list(
        params[:tags],
        max_count: [SiteSetting.media_gallery_max_tags_per_item.to_i, 10].max,
        max_length: 40,
        allowed: MediaGallery::Permissions.allowed_tags
      )

      item.update!(
        title: title,
        description: description.presence,
        gender: subject,
        tags: tags
      )

      item.reload
      render_json_dump(serialize_data(item, MediaGallery::MediaItemSerializer, root: false))
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[media_gallery] update validation failed request_id=#{request.request_id} public_id=#{params[:public_id]} errors=#{e.record.errors.full_messages.join(", ")}"
      )
      render_json_error("validation_error", status: 422, extra: { details: e.record.errors.full_messages })
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error(
        "[media_gallery] update failed request_id=#{request.request_id} public_id=#{params[:public_id]} error=#{e.class}: #{e.message}
#{e.backtrace&.first(40)&.join("\n")}"
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

        # Remove managed assets (safe no-op if not present)
        delete_managed_assets_safely!(item)

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
      ensure_item_visible_to_current_user!(item)
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

      # Best-effort extra hardening (active token + concurrent session limiting).
      ip = request.remote_ip.to_s
      user_id = current_user&.id

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      return render_json_error("not_found", status: 404) if item.blank?
      ensure_item_visible_to_current_user!(item)

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

      force_stream =
        begin
          ActiveModel::Type::Boolean.new.cast(params[:force_stream])
        rescue
          %w[1 true yes on].include?(params[:force_stream].to_s.downcase)
        end

      use_hls =
        item.media_type.to_s == "video" &&
          SiteSetting.respond_to?(:media_gallery_hls_enabled) &&
          SiteSetting.media_gallery_hls_enabled &&
          MediaGallery::PrivateStorage.enabled? &&
          MediaGallery::Hls.ready?(item) &&
          !force_stream

      fingerprint_id = nil
      if use_hls && MediaGallery::Fingerprinting.enabled?
        # Deterministic fingerprint id per user+media (cannot be re-rolled by requesting new tokens).
        fingerprint_id = MediaGallery::Fingerprinting.touch_fingerprint_record!(
          user_id: current_user.id,
          media_item_id: item.id,
          ip: ip
        )
      end

      if upload_id.blank?
        return render_json_error("private_storage_disabled", status: 500) unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

        unless use_hls
          delivery = ::MediaGallery::DeliveryResolver.new(item, "main").resolve
          return render_json_error("processed_file_missing", status: 404) if delivery.blank?
        end
      end

      ok, err = MediaGallery::Security.enforce_active_token_limits!(user_id: user_id, ip: ip)
      unless ok
        log_security_event(
          event_type: "play_token_limit_reached",
          severity: "warning",
          category: "playback",
          user: current_user,
          media_item: item,
          message: err,
          details: { ip: ip, media_public_id: item.public_id, playback: (use_hls ? "hls" : "stream") },
        )
        return render_json_error(err, status: 429, message: playback_limit_message(err))
      end

      streaming_session = item.media_type.to_s == "video" || item.media_type.to_s == "audio"
      heartbeat_enabled = streaming_session && MediaGallery::Security.heartbeat_enabled?

      if heartbeat_enabled
        ok2, err2 = MediaGallery::Security.enforce_new_session_limits!(user_id: user_id, ip: ip)
        unless ok2
          log_security_event(
            event_type: "new_session_limit_reached",
            severity: "warning",
            category: "playback",
            user: current_user,
            media_item: item,
            message: err2,
            details: { ip: ip, media_public_id: item.public_id, playback: (use_hls ? "hls" : "stream") },
          )
          return render_json_error(err2, status: 429, message: playback_limit_message(err2))
        end
      end

      session_binding = MediaGallery::Token.ensure_session_binding_cookie!(request: request, cookies: cookies)

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: (use_hls ? nil : upload_id.presence),
        kind: (use_hls ? "hls" : "main"),
        user: current_user,
        request: request,
        fingerprint_id: fingerprint_id,
        cookies: cookies,
        session_binding: session_binding
      )

      token = MediaGallery::Token.generate(payload, purpose: (use_hls ? "hls" : "stream"))
      expires_at = payload["exp"]

      overlay_payload = nil
      if item.media_type.to_s == "video" || item.media_type.to_s == "image"
        overlay_payload = MediaGallery::PlaybackOverlay.build_or_reuse_payload(
          media_item: item,
          user: current_user,
          request: request,
          token: token,
          fingerprint_id: fingerprint_id,
          reuse_code: params[:overlay_code_reuse].to_s.presence
        )
      end

      # Track active tokens (best effort). This does not affect playback.
      MediaGallery::Security.track_token!(token: token, exp: expires_at, user_id: user_id, ip: ip)

      # Best-effort forensic logging (who received which fingerprint_id + token hash).
      if fingerprint_id.present? && MediaGallery::Fingerprinting.enabled?
        MediaGallery::Fingerprinting.log_playback_session!(
          user_id: user_id,
          media_item_id: item.id,
          fingerprint_id: fingerprint_id,
          token: token,
          ip: ip,
          user_agent: request.user_agent
        )
      end


      # Register an active session immediately (will be refreshed by heartbeat on play).
      # Useful both today (MP4) and for future HLS.
      if heartbeat_enabled
        MediaGallery::Security.open_or_touch_session!(token: token, user_id: user_id, ip: ip)

        ok3, err3 = MediaGallery::Security.enforce_session_limits!(user_id: user_id, ip: ip)
        if !ok3
          log_security_event(
            event_type: "concurrent_session_limit_reached",
            severity: "warning",
            category: "playback",
            user: current_user,
            media_item: item,
            overlay_code: overlay_payload.is_a?(Hash) ? overlay_payload[:overlay_code] || overlay_payload["overlay_code"] : nil,
            fingerprint_id: fingerprint_id,
            message: err3,
            details: { ip: ip, media_public_id: item.public_id, playback: (use_hls ? "hls" : "stream") },
          )
          MediaGallery::Security.revoke!(token: token, exp: expires_at, user_id: user_id, ip: ip)
          return render_json_error(err3, status: 429, message: playback_limit_message(err3))
        end
      end

      # keep this lightweight: avoid callbacks/validations
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      set_sensitive_json_headers!
      log_security_event(
        event_type: "play_token_issued",
        severity: "info",
        category: "playback",
        user: current_user,
        media_item: item,
        overlay_code: overlay_payload.is_a?(Hash) ? overlay_payload[:overlay_code] || overlay_payload["overlay_code"] : nil,
        fingerprint_id: fingerprint_id,
        message: use_hls ? "hls" : "stream",
        details: {
          media_public_id: item.public_id,
          playback: (use_hls ? "hls" : "stream"),
          heartbeat_enabled: heartbeat_enabled,
          overlay_enabled: overlay_payload.present?,
        },
      )

      if use_hls
        render_json_dump(
          playback: "hls",
          token: token,
          hls_master_url: "/media/hls/#{item.public_id}/master.m3u8?token=#{token}",
          expires_at: expires_at,
          playable: true,
          security: {
            revoke_enabled: MediaGallery::Security.revoke_enabled?,
            heartbeat_enabled: heartbeat_enabled,
            heartbeat_interval_seconds: MediaGallery::Security.heartbeat_interval_seconds,
            heartbeat_ttl_seconds: MediaGallery::Security.heartbeat_ttl_seconds
          },
          overlay: overlay_payload
        )
      else
        render_json_dump(
          playback: "stream",
          token: token,
          # Do not include a file extension in the URL.
          #
          # Rationale:
          # - Avoids exposing ".mp4" etc in the DOM.
          # - Keeps the URL less obviously "downloadable".
          # - StreamController sets the correct Content-Type based on the token payload.
          stream_url: "/media/stream/#{token}",
          expires_at: expires_at,
          playable: true,
          security: {
            revoke_enabled: MediaGallery::Security.revoke_enabled?,
            heartbeat_enabled: heartbeat_enabled,
            heartbeat_interval_seconds: MediaGallery::Security.heartbeat_interval_seconds,
            heartbeat_ttl_seconds: MediaGallery::Security.heartbeat_ttl_seconds
          },
          overlay: overlay_payload
        )
      end
    rescue => e
      Rails.logger.error(
        "[media_gallery] play failed request_id=#{request.request_id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}"
      )
      render_json_error("internal_error", status: 500)
    end

    # POST /media/heartbeat
    # Lightweight session keep-alive to support best-effort concurrent playback limits.
    def heartbeat
      raise Discourse::NotFound unless SiteSetting.media_gallery_heartbeat_enabled

      token = (params[:token].presence || params[:stream_token].presence).to_s
      return render_json_error("invalid_token", status: 400) if token.blank?
      raise Discourse::NotFound if MediaGallery::Security.revoked?(token)

      payload = MediaGallery::Token.verify_any(token)
      if payload.blank?
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, message: "invalid_or_expired_token", details: { token_present: token.present? })
        raise Discourse::NotFound
      end

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, message: "user_mismatch", details: { media_item_id: payload["media_item_id"], fingerprint_id: payload["fingerprint_id"] })
        raise Discourse::NotFound
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, message: "ip_mismatch", details: { media_item_id: payload["media_item_id"], fingerprint_id: payload["fingerprint_id"] })
        raise Discourse::NotFound
      end

      unless MediaGallery::Token.request_session_binding_valid?(payload: payload, request: request, cookies: cookies)
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, overlay_code: payload["overlay_code"], fingerprint_id: payload["fingerprint_id"], message: "session_binding_mismatch", details: { media_item_id: payload["media_item_id"] })
        raise Discourse::NotFound
      end

      # Only sessions for audio/video are counted.
      item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      if item.blank?
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, overlay_code: payload["overlay_code"], fingerprint_id: payload["fingerprint_id"], message: "media_item_missing", details: { media_item_id: payload["media_item_id"] })
        raise Discourse::NotFound
      end
      ensure_item_visible_to_current_user!(item)
      unless item.ready?
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, media_item: item, overlay_code: payload["overlay_code"], fingerprint_id: payload["fingerprint_id"], message: "item_not_ready")
        raise Discourse::NotFound
      end
      unless MediaGallery::Token.asset_binding_valid?(media_item: item, kind: payload["kind"], payload: payload)
        log_security_event(event_type: "heartbeat_denied", severity: "warning", category: "playback", user: current_user, media_item: item, overlay_code: payload["overlay_code"], fingerprint_id: payload["fingerprint_id"], message: "asset_binding_mismatch")
        raise Discourse::NotFound
      end

      streaming_session = item.media_type.to_s == "video" || item.media_type.to_s == "audio"

      if streaming_session
        ip = request.remote_ip.to_s
        user_id = current_user.id

        if MediaGallery::Fingerprinting.enabled? && payload["fingerprint_id"].present?
          MediaGallery::Fingerprinting.touch_fingerprint_record!(user_id: user_id, media_item_id: item.id, ip: ip)
        end

        MediaGallery::Security.open_or_touch_session!(token: token, user_id: user_id, ip: ip)

        ok, err = MediaGallery::Security.enforce_session_limits!(user_id: user_id, ip: ip)
        if !ok
          log_security_event(
            event_type: "heartbeat_session_limit_reached",
            severity: "warning",
            category: "playback",
            user: current_user,
            media_item: item,
            overlay_code: payload["overlay_code"],
            fingerprint_id: payload["fingerprint_id"],
            message: err,
            details: { media_public_id: item.public_id, ip: ip },
          )
          MediaGallery::Security.revoke!(token: token, exp: payload["exp"], user_id: user_id, ip: ip)
          return render_json_error(err, status: 429, message: playback_limit_message(err))
        end
      end

      set_sensitive_json_headers!
      render_json_dump(ok: true)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] heartbeat failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_error("internal_error", status: 500)
    end

    # POST /media/revoke
    # Best-effort early revocation of a stream token.
    def revoke
      return render_json_dump(ok: true) unless SiteSetting.media_gallery_revoke_enabled

      token = (params[:token].presence || params[:stream_token].presence).to_s
      return render_json_dump(ok: true) if token.blank?

      payload = MediaGallery::Token.verify_any(token)
      # If it's already expired, there is nothing to revoke.
      return render_json_dump(ok: true) if payload.blank?

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        log_security_event(event_type: "revoke_denied", severity: "warning", category: "playback", user: current_user, message: "user_mismatch", details: { media_item_id: payload["media_item_id"] })
        raise Discourse::NotFound
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        log_security_event(event_type: "revoke_denied", severity: "warning", category: "playback", user: current_user, message: "ip_mismatch", details: { media_item_id: payload["media_item_id"] })
        raise Discourse::NotFound
      end

      unless MediaGallery::Token.request_session_binding_valid?(payload: payload, request: request, cookies: cookies)
        log_security_event(event_type: "revoke_denied", severity: "warning", category: "playback", user: current_user, overlay_code: payload["overlay_code"], fingerprint_id: payload["fingerprint_id"], message: "session_binding_mismatch", details: { media_item_id: payload["media_item_id"] })
        raise Discourse::NotFound
      end

      MediaGallery::Security.revoke!(
        token: token,
        exp: payload["exp"],
        user_id: current_user.id,
        ip: request.remote_ip.to_s
      )

      set_sensitive_json_headers!
      render_json_dump(ok: true)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] revoke failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
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
      log_security_event(
        event_type: "play_rate_limited",
        severity: "warning",
        category: "playback",
        user: current_user,
        message: "rate_limited",
        details: { ip: request.remote_ip.to_s },
      )
      render_json_error("rate_limited", status: 429, message: playback_limit_message("rate_limited"))
      false
    end

    private :enforce_play_rate_limits!

    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      unless admin_preview_request?
        ensure_item_visible_to_current_user!(item)
      end
      unless item.ready?
        return render_default_thumbnail(item) if item.queued_or_processing? || item.status.to_s == "failed"

        raise Discourse::NotFound
      end

      # Thumbnails are served via a stable URL so browsers can cache them efficiently.
      # Streaming URLs remain tokenized (short TTL) for the main media bytes.
      #
      # We still require a logged-in user + view permission (before_action), but the response
      # itself is cacheable in the user's browser (private cache).

      thumb = resolve_thumbnail_file!(item)
      return render_default_thumbnail(item) if thumb.blank?

      max_age = thumbnail_cache_max_age_seconds
      response.headers["Cache-Control"] = thumbnail_cache_control_header(max_age)
      response.headers["X-Content-Type-Options"] = "nosniff"

      if thumb[:mode] == :memory
        data = thumb[:data].to_s.b
        file_size = data.bytesize
        file_mtime = thumb[:last_modified] || item.updated_at || Time.now
        etag = Digest::SHA1.hexdigest("thumb|#{item.public_id}|#{file_size}|#{file_mtime.to_i}")

        return unless stale?(etag: etag, last_modified: file_mtime, public: false)

        response.headers["Content-Disposition"] = "inline; filename=\"#{thumb[:filename]}\""
        response.headers["Content-Type"] = thumb[:content_type]
        if request.head?
          response.headers["Content-Length"] = file_size.to_s
          return head :ok
        end

        response.headers["Content-Length"] = file_size.to_s
        return send_data(data, disposition: "inline", filename: thumb[:filename], type: thumb[:content_type])
      end

      local_path = thumb[:local_path]
      return render_default_thumbnail(item) if local_path.blank? || !File.exist?(local_path)

      file_mtime = File.mtime(local_path).utc
      file_size = File.size(local_path).to_i
      etag = Digest::SHA1.hexdigest("thumb|#{item.public_id}|#{file_size}|#{file_mtime.to_i}")

      # Handle conditional GET/HEAD (ETag + Last-Modified)
      return unless stale?(etag: etag, last_modified: file_mtime, public: false)

      response.headers["Content-Disposition"] = "inline; filename=\"#{thumb[:filename]}\""
      response.headers["Content-Type"] = thumb[:content_type]

      if request.head?
        response.headers["Content-Length"] = file_size.to_s
        return head :ok
      end

      data = File.binread(local_path)
      response.headers["Content-Length"] = data.bytesize.to_s
      send_data(data, disposition: "inline", filename: thumb[:filename], type: thumb[:content_type])
    end

    def like
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
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
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      like = MediaGallery::MediaLike.find_by(media_item_id: item.id, user_id: current_user.id)
      raise Discourse::NotFound if like.blank?

      like.destroy!
      MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = GREATEST(likes_count - 1, 0)")

      render_json_dump(success: true)
    end

    private

    def ensure_secure_write_request!
      return if ::MediaGallery::RequestSecurity.secure_write_request?(self)

      ::MediaGallery::OperationLogger.warn(
        "request_blocked",
        operation: action_name,
        item: nil,
        data: {
          reason: "csrf_or_same_origin_failed",
          origin: request.headers["Origin"].to_s.presence,
          referer: request.referer.to_s.presence,
          sec_fetch_site: request.headers["Sec-Fetch-Site"].to_s.presence,
          method: request.request_method
        }
      )
      log_security_event(
        event_type: "request_blocked",
        severity: "warning",
        category: "request_security",
        message: "csrf_or_same_origin_failed",
        details: {
          reason: "csrf_or_same_origin_failed",
          origin: request.headers["Origin"].to_s.presence,
          referer: request.referer.to_s.presence,
          sec_fetch_site: request.headers["Sec-Fetch-Site"].to_s.presence,
          method: request.request_method,
        },
      )

      set_sensitive_json_headers!
      render_json_error("forbidden", status: 403, message: "Forbidden")
    end

    def ensure_secure_play_request!
      return if ::MediaGallery::RequestSecurity.secure_token_issue_request?(self)

      ::MediaGallery::OperationLogger.warn(
        "request_blocked",
        operation: action_name,
        item: nil,
        data: {
          reason: "same_origin_required_for_play",
          origin: request.headers["Origin"].to_s.presence,
          referer: request.referer.to_s.presence,
          sec_fetch_site: request.headers["Sec-Fetch-Site"].to_s.presence,
          method: request.request_method
        }
      )
      log_security_event(
        event_type: "play_request_blocked",
        severity: "warning",
        category: "request_security",
        message: "same_origin_required_for_play",
        details: {
          reason: "same_origin_required_for_play",
          origin: request.headers["Origin"].to_s.presence,
          referer: request.referer.to_s.presence,
          sec_fetch_site: request.headers["Sec-Fetch-Site"].to_s.presence,
          method: request.request_method,
        },
      )

      set_sensitive_json_headers!
      render_json_error("forbidden", status: 403, message: "Forbidden")
    end


    def log_security_event(event_type:, severity: "info", category: "general", user: nil, media_item: nil, overlay_code: nil, fingerprint_id: nil, message: nil, details: nil)
      ::MediaGallery::LogEvents.record(
        event_type: event_type,
        severity: severity,
        category: category,
        request: request,
        user: user || current_user,
        media_item: media_item,
        overlay_code: overlay_code,
        fingerprint_id: fingerprint_id,
        message: message,
        details: details,
      )
    end

    def set_sensitive_json_headers!
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end

    def ensure_can_upload
      raise Discourse::NotFound unless MediaGallery::Permissions.can_upload?(guardian)
    end

    def access_group_names_for_client(groups)
      groups
        .map { |g| g.to_s.strip }
        .reject(&:blank?)
        .uniq
        .first(50)
    end

    def media_gallery_permissions_payload
      {
        can_view: MediaGallery::Permissions.can_view?(guardian),
        can_upload: MediaGallery::Permissions.can_upload?(guardian),
        viewer_groups: access_group_names_for_client(MediaGallery::Permissions.viewer_groups),
        uploader_groups: access_group_names_for_client(MediaGallery::Permissions.uploader_groups)
      }
    end

    def can_manage_item?(item)
      (current_user&.staff? || current_user&.admin?) || (guardian.user&.id == item.user_id)
    end

    def ensure_item_visible_to_current_user!(item)
      return if item.blank?
      return if !item.respond_to?(:admin_hidden?) || !item.admin_hidden?

      raise Discourse::NotFound
    end

    def admin_preview_request?
      current_user&.staff? && params[:admin_preview].to_s == "1"
    end

    def apply_admin_visibility_filter(scope)
      scope.where("COALESCE((extra_metadata -> 'admin_visibility' ->> 'hidden')::boolean, false) = false")
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.blank?
      item
    end

    
    def positive_page_param(value, default: 1)
      page = value.to_i
      page = default if page <= 0
      page
    end

    def bounded_per_page_param(value, default:, max:)
      per_page = value.to_i
      per_page = default if per_page <= 0
      per_page = max if per_page > max
      per_page
    end

    def playback_limit_message(code)
      case code.to_s
      when "rate_limited"
        "Playback rate limited. Please wait and try again."
      when "too_many_concurrent_sessions_user", "too_many_concurrent_sessions_ip"
        "Playback blocked: too many active sessions. Close another player and try again."
      when "too_many_active_tokens_user", "too_many_active_tokens_ip"
        "Playback blocked: too many active playback links. Please close other sessions and try again."
      else
        "Playback blocked. Please try again."
      end
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
      return unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

      ::MediaGallery::StorageSettingsResolver.validate_active_backend!
      store = ::MediaGallery::StorageSettingsResolver.build_store
      store&.ensure_available!
      MediaGallery::PrivateStorage.ensure_private_root!
      MediaGallery::PrivateStorage.ensure_original_export_root!
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
      if item.thumbnail_upload_id.present?
        upload = item.thumbnail_upload
        return nil if upload.blank?

        local_path = MediaGallery::UploadPath.local_path_for(upload)
        return nil if local_path.blank?

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

        return { mode: :local, local_path: local_path, content_type: content_type, filename: filename }
      end

      return nil unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

      delivery = ::MediaGallery::DeliveryResolver.new(item, "thumbnail").resolve
      return nil if delivery.blank?

      if delivery.mode == :local
        return { mode: :local, local_path: delivery.local_path, content_type: delivery.content_type, filename: delivery.filename }
      end

      role = ::MediaGallery::AssetManifest.role_for(item, "thumbnail")
      return nil if role.blank?

      store = delivery.store
      if store.blank?
        profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
        store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
        store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"])
      end
      return nil if store.blank?

      key = delivery.key.presence || role["key"].to_s
      return nil if key.blank?

      data = store.read(key)
      {
        mode: :memory,
        data: data,
        content_type: delivery.content_type.presence || role["content_type"].presence || "image/jpeg",
        filename: delivery.filename,
        last_modified: item.updated_at || Time.now
      }
    rescue => e
      Rails.logger.warn("[media_gallery] thumbnail resolve failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def managed_delivery_mode_for_backend(backend)
      if backend.to_s == "s3"
        ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect" ? "s3_redirect" : "s3_proxy"
      else
        mode = ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s
        mode == "x_accel" ? "x_accel" : "local_stream"
      end
    rescue
      backend.to_s == "s3" ? "s3_redirect" : "local_stream"
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
      title = item.title.to_s[0, 60]
      safe_title = ERB::Util.html_escape(title)

      processing = item.extra_metadata.is_a?(Hash) ? item.extra_metadata["processing"] : nil
      processing = processing.is_a?(Hash) ? processing : {}
      stage = processing["current_stage"].presence || processing["last_stage"].presence || processing["last_failed_stage"].presence
      stage_label = ERB::Util.html_escape(stage.to_s.tr("_-", " ").squeeze(" ").strip).presence

      headline, subtitle =
        case item.status.to_s
        when "queued"
          ["Queued", stage_label || safe_title]
        when "processing"
          ["Processing…", stage_label || safe_title]
        when "failed"
          ["Thumbnail unavailable", stage_label || safe_title]
        else
          ["No thumbnail", safe_title]
        end

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180" role="img" aria-label="Thumbnail">
          <rect width="320" height="180" fill="#f2f2f2"/>
          <rect x="8" y="8" width="304" height="164" fill="#ffffff" stroke="#d9d9d9"/>
          <g fill="#666666" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif">
            <text x="160" y="86" font-size="16" text-anchor="middle">#{headline}</text>
            <text x="160" y="112" font-size="12" text-anchor="middle">#{subtitle}</text>
          </g>
        </svg>
      SVG
    end

    # Plugin-level per-type size enforcement (MB).
    # Returns a structured error hash when too large, or nil when OK.
    def enforce_type_size_limit(upload, media_type)
      size_bytes = upload.filesize.to_i
      max_mb = type_size_limit_mb_for(media_type)
      return nil unless max_mb.positive?

      max_bytes = max_mb * 1024 * 1024
      return nil if size_bytes <= max_bytes

      {
        error_code: size_error_code_for(media_type),
        message: type_size_limit_message(media_type: media_type, actual_bytes: size_bytes, max_mb: max_mb),
        details: {
          media_type: media_type.to_s,
          actual_bytes: size_bytes,
          actual_mb: rounded_mb(size_bytes),
          max_mb: max_mb
        }
      }
    end

    def upload_policy_payload
      {
        site_max_upload_mb: site_max_upload_mb,
        plugin_max_upload_mb: positive_or_nil(SiteSetting.media_gallery_max_upload_size_mb.to_i),
        type_max_upload_mb: {
          "video" => positive_or_nil(type_size_limit_mb_for("video")),
          "audio" => positive_or_nil(type_size_limit_mb_for("audio")),
          "image" => positive_or_nil(type_size_limit_mb_for("image"))
        },
        duration_limits_seconds: {
          "video" => positive_or_nil(SiteSetting.media_gallery_video_max_duration_seconds.to_i),
          "audio" => positive_or_nil(SiteSetting.media_gallery_audio_max_duration_seconds.to_i)
        },
        allowed_extensions: {
          "image" => allowed_extension_list_for_type("image"),
          "audio" => allowed_extension_list_for_type("audio"),
          "video" => allowed_extension_list_for_type("video")
        }
      }
    end

    def site_max_upload_mb
      kb = SiteSetting.respond_to?(:max_attachment_size_kb) ? SiteSetting.max_attachment_size_kb.to_i : 0
      return nil unless kb.positive?

      (kb.to_f / 1024.0).round(1)
    end

    def positive_or_nil(value)
      v = value.to_i
      v.positive? ? v : nil
    end

    def rounded_mb(bytes)
      return 0 if bytes.to_i <= 0

      (bytes.to_f / (1024.0 * 1024.0)).round(1)
    end

    def media_type_label(media_type)
      case media_type.to_s
      when "video" then "video"
      when "audio" then "audio file"
      when "image" then "image"
      else "file"
      end
    end

    def pluralize_seconds(seconds)
      v = seconds.to_i
      v == 1 ? "1 second" : "#{v} seconds"
    end

    def human_duration(seconds)
      total = seconds.to_f.round
      return pluralize_seconds(total) if total < 60

      mins = (total / 60).floor
      secs = (total % 60).round
      if secs <= 0
        mins == 1 ? "1 minute" : "#{mins} minutes"
      elsif mins <= 0
        pluralize_seconds(secs)
      else
        "#{mins} minute#{"s" unless mins == 1} #{secs} second#{"s" unless secs == 1}"
      end
    end

    def type_size_limit_mb_for(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_max_video_size_mb) ? SiteSetting.media_gallery_max_video_size_mb.to_i : 0
      when "audio"
        SiteSetting.respond_to?(:media_gallery_max_audio_size_mb) ? SiteSetting.media_gallery_max_audio_size_mb.to_i : 0
      when "image"
        SiteSetting.respond_to?(:media_gallery_max_image_size_mb) ? SiteSetting.media_gallery_max_image_size_mb.to_i : 0
      else
        0
      end
    end

    def size_error_code_for(media_type)
      case media_type.to_s
      when "video" then "video_too_large"
      when "audio" then "audio_too_large"
      when "image" then "image_too_large"
      else "upload_too_large"
      end
    end

    def upload_too_large_message(max_mb:, actual_bytes:)
      "This file is too large (#{rounded_mb(actual_bytes)} MB). The maximum allowed size is #{max_mb} MB."
    end

    def type_size_limit_message(media_type:, actual_bytes:, max_mb:)
      "This #{media_type_label(media_type)} is too large (#{rounded_mb(actual_bytes)} MB). The maximum allowed #{media_type.to_s} size is #{max_mb} MB."
    end

    def allowed_extension_list_for_type(media_type)
      allowed =
        case media_type.to_s
        when "image" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_image_extensions)
        when "audio" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_audio_extensions)
        when "video" then MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_video_extensions)
        else []
        end

      allowed =
        case media_type.to_s
        when "image" then MediaGallery::MediaItem::IMAGE_EXTS
        when "audio" then MediaGallery::MediaItem::AUDIO_EXTS
        when "video" then MediaGallery::MediaItem::VIDEO_EXTS
        else []
        end if allowed.blank?

      allowed.map { |e| e.to_s.downcase.sub(/\A\./, "") }.uniq
    end

    def unsupported_file_type_details(upload)
      {
        filename: upload&.original_filename.to_s,
        extension: normalized_upload_extension(upload).presence,
        mime_type: upload_mime(upload),
        allowed_extensions: {
          image: allowed_extension_list_for_type("image"),
          audio: allowed_extension_list_for_type("audio"),
          video: allowed_extension_list_for_type("video")
        }
      }
    end

    def unsupported_file_type_message(upload)
      details = unsupported_file_type_details(upload)
      ext = details[:extension].present? ? " (.#{details[:extension]})" : ""
      "This file type#{ext} is not supported. Allowed extensions: images (#{details[:allowed_extensions][:image].join(', ')}), audio (#{details[:allowed_extensions][:audio].join(', ')}), video (#{details[:allowed_extensions][:video].join(', ')})."
    end

    def unsupported_file_extension_details(upload, media_type)
      {
        media_type: media_type.to_s,
        filename: upload&.original_filename.to_s,
        extension: normalized_upload_extension(upload).presence,
        allowed_extensions: allowed_extension_list_for_type(media_type)
      }
    end

    def unsupported_file_extension_message(upload, media_type)
      details = unsupported_file_extension_details(upload, media_type)
      ext = details[:extension].presence || "unknown"
      "Files with the .#{ext} extension are not allowed for #{media_type.to_s} uploads. Allowed extensions: #{details[:allowed_extensions].join(', ')}."
    end

    def preflight_duration_limit_error(upload, media_type)
      return nil unless %w[video audio].include?(media_type.to_s)

      max_seconds =
        case media_type.to_s
        when "video" then SiteSetting.media_gallery_video_max_duration_seconds.to_i
        when "audio" then SiteSetting.media_gallery_audio_max_duration_seconds.to_i
        else 0
        end
      return nil unless max_seconds.positive?

      local_path = ::MediaGallery::UploadPath.local_path_for(upload)
      return nil if local_path.blank? || !File.exist?(local_path)

      begin
        probe = ::MediaGallery::Ffmpeg.probe(local_path)
        actual_seconds = probe.dig("format", "duration").to_f
        return nil unless actual_seconds.positive? && actual_seconds > max_seconds

        {
          error_code: media_type.to_s == "video" ? "video_too_long" : "audio_too_long",
          message: "This #{media_type_label(media_type)} is too long (#{human_duration(actual_seconds)}). The maximum allowed #{media_type.to_s} duration is #{human_duration(max_seconds)}.",
          details: {
            media_type: media_type.to_s,
            actual_seconds: actual_seconds.round,
            max_seconds: max_seconds
          }
        }
      rescue => e
        Rails.logger.warn(
          "[media_gallery] duration preflight skipped request_id=#{request.request_id} upload_id=#{upload&.id} error=#{e.class}: #{e.message}"
        )
        nil
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

    def normalized_upload_extension(upload)
      ext = upload&.extension.to_s.downcase.sub(/\A\./, "")
      return ext if ext.present?

      filename = upload&.original_filename.to_s
      fallback = File.extname(filename).to_s.downcase.sub(/\A\./, "")
      fallback.presence.to_s
    end

    def infer_media_type(upload)
      ext = normalized_upload_extension(upload)
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
      ext = normalized_upload_extension(upload)
      allowed_extension_list_for_type(media_type).include?(ext)
    end
  end
end
