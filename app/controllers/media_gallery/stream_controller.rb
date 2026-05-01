# frozen_string_literal: true

require "digest"

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_plugin_enabled

    # Members-only: always require a logged-in user.
    #
    # Note: Discourse's Api-Key auth can depend on request format.
    # The route sets defaults: { format: :json } so Api-Key works for curl tests too.
    before_action :ensure_logged_in
    before_action :ensure_can_view

    # GET/HEAD /media/stream/:token(.:ext)
    def show
      token = params[:token].to_s
      # If the client revoked this token (overlay closed/ended), deny access.
      deny_stream!(:token_revoked, token: token) if MediaGallery::Security.revoked?(token)

      payload = MediaGallery::Token.verify(token)
      deny_stream!(:invalid_or_expired_token, token: token) if payload.blank?

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        deny_stream!(:user_mismatch, token: token, payload: payload)
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        deny_stream!(:ip_mismatch, token: token, payload: payload)
      end

      unless MediaGallery::Token.request_session_binding_valid?(payload: payload, request: request, cookies: cookies)
        deny_stream!(:session_binding_mismatch, token: token, payload: payload)
      end

      item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      deny_stream!(:media_item_missing, token: token, payload: payload) if item.blank?
      ensure_item_visible_to_current_user!(item)
      deny_stream!(:item_not_ready, token: token, payload: payload, item: item) unless item.ready?

      kind = payload["kind"].to_s
      unless MediaGallery::Token.asset_binding_valid?(media_item: item, kind: kind, payload: payload)
        deny_stream!(:asset_binding_mismatch, token: token, payload: payload, item: item)
      end

      kind = "main" if kind.blank?

      return unless enforce_stream_scraping_controls!(token: token, payload: payload, item: item)

      delivery = resolve_file(item, payload, kind)
      raise Discourse::NotFound if delivery.blank?

      if delivery[:mode] == :redirect
        response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
        return redirect_to(delivery[:redirect_url], allow_other_host: true, status: 307)
      end

      local_path = delivery[:local_path]
      content_type = delivery[:content_type]
      apply_private_stream_headers!

      if delivery[:mode] == :proxy
        return stream_proxy_delivery(delivery)
      end

      raise Discourse::NotFound if local_path.blank? || !File.exist?(local_path)
      file_size = File.size(local_path)

      if request.head?
        response.headers["Content-Type"] = content_type
        response.headers["Content-Length"] = file_size.to_s
        return head :ok
      end

      parsed_range = parse_requested_byte_range(file_size)
      return if parsed_range == :invalid
      if parsed_range.present?
        start_pos, end_pos = parsed_range
        length = (end_pos - start_pos) + 1
        data = IO.binread(local_path, length, start_pos)

        response.status = 206
        response.headers["Content-Type"] = content_type
        response.headers["Content-Range"] = "bytes #{start_pos}-#{end_pos}/#{file_size}"
        response.headers["Content-Length"] = length.to_s

        return send_data(data, type: content_type, disposition: "inline", status: 206)
      end

      response.headers["Content-Type"] = content_type
      response.headers["Content-Length"] = file_size.to_s
      send_file(local_path, disposition: "inline", type: content_type)
    end

    private


    def deny_stream!(reason, token:, payload: nil, item: nil)
      MediaGallery::LogEvents.record(
        event_type: "stream_denied",
        severity: "warning",
        category: "playback",
        request: request,
        user: current_user,
        media_item: item,
        overlay_code: payload.is_a?(Hash) ? payload["overlay_code"] : nil,
        fingerprint_id: payload.is_a?(Hash) ? payload["fingerprint_id"] : nil,
        message: reason.to_s,
        details: {
          reason: reason.to_s,
          token_kind: payload.is_a?(Hash) ? payload["kind"] : nil,
          media_item_id: payload.is_a?(Hash) ? payload["media_item_id"] : nil,
          media_public_id: item&.public_id,
          token_present: token.present?,
          token_sha256: ::MediaGallery::Security.token_sha256_label(token),
        },
      )
      raise Discourse::NotFound
    end

    def enforce_stream_scraping_controls!(token:, payload:, item:)
      record_stream_anomaly_signals!(token: token, payload: payload, item: item)
      enforce_stream_rate_limit!(token: token, payload: payload, item: item, range_request: extract_range_header.present?)
    end

    def enforce_stream_rate_limit!(token:, payload:, item:, range_request:)
      total_limit = stream_setting_integer(:media_gallery_stream_requests_per_token_per_minute)
      range_limit = range_request ? stream_setting_integer(:media_gallery_stream_range_requests_per_token_per_minute) : 0

      return true if total_limit <= 0 && range_limit <= 0

      token_ip_digest = stream_token_ip_digest(token)

      if total_limit.positive?
        RateLimiter.new(nil, "media_gallery:stream:req:sha256:#{token_ip_digest}", total_limit, 1.minute).performed!
      end

      if range_limit.positive?
        RateLimiter.new(nil, "media_gallery:stream:range:sha256:#{token_ip_digest}", range_limit, 1.minute).performed!
      end

      true
    rescue RateLimiter::LimitExceeded
      MediaGallery::LogEvents.record(
        event_type: "stream_rate_limited",
        severity: "warning",
        category: "playback",
        request: request,
        user: current_user,
        media_item: item,
        overlay_code: payload.is_a?(Hash) ? payload["overlay_code"] : nil,
        fingerprint_id: payload.is_a?(Hash) ? payload["fingerprint_id"] : nil,
        message: range_request ? "range_rate_limited" : "request_rate_limited",
        details: {
          reason: range_request ? "range_rate_limited" : "request_rate_limited",
          range_request: range_request,
          token_kind: payload.is_a?(Hash) ? payload["kind"] : nil,
          media_public_id: item&.public_id,
          token_sha256: ::MediaGallery::Security.token_sha256_label(token),
          total_limit_per_minute: total_limit,
          range_limit_per_minute: range_limit,
        },
      )
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Retry-After"] = "60"
      render plain: "rate_limited", status: 429
      false
    end

    def record_stream_anomaly_signals!(token:, payload:, item:)
      return unless SiteSetting.respond_to?(:media_gallery_log_stream_anomalies) && SiteSetting.media_gallery_log_stream_anomalies

      range_request = extract_range_header.present?
      token_ip_digest = stream_token_ip_digest(token)

      record_stream_anomaly_counter!(
        metric: "requests_per_token_per_minute",
        threshold: stream_setting_integer(:media_gallery_stream_anomaly_requests_per_token_per_minute),
        token_ip_digest: token_ip_digest,
        token: token,
        payload: payload,
        item: item,
        range_request: range_request
      )

      if range_request
        record_stream_anomaly_counter!(
          metric: "range_requests_per_token_per_minute",
          threshold: stream_setting_integer(:media_gallery_stream_anomaly_range_requests_per_token_per_minute),
          token_ip_digest: token_ip_digest,
          token: token,
          payload: payload,
          item: item,
          range_request: true
        )
      end
    rescue => e
      Rails.logger.debug("[media_gallery] stream anomaly tracking failed request_id=#{request.request_id} error=#{e.class}: #{e.message}") if Rails.logger.respond_to?(:debug)
      nil
    end

    def record_stream_anomaly_counter!(metric:, threshold:, token_ip_digest:, token:, payload:, item:, range_request:)
      threshold = threshold.to_i
      return if threshold <= 0

      redis = Discourse.redis
      minute = Time.now.utc.strftime("%Y%m%d%H%M")
      key = "media_gallery:stream:anomaly:#{metric}:#{minute}:sha256:#{token_ip_digest}"
      count = redis.incr(key).to_i
      redis.expire(key, 2.minutes.to_i)

      # Log once per token/IP/minute when the threshold is crossed; avoid log spam.
      return unless count == threshold + 1

      MediaGallery::LogEvents.record(
        event_type: "stream_scrape_anomaly",
        severity: "warning",
        category: "playback",
        request: request,
        user: current_user,
        media_item: item,
        overlay_code: payload.is_a?(Hash) ? payload["overlay_code"] : nil,
        fingerprint_id: payload.is_a?(Hash) ? payload["fingerprint_id"] : nil,
        message: metric.to_s,
        details: {
          metric: metric.to_s,
          count: count,
          threshold: threshold,
          range_request: range_request,
          token_kind: payload.is_a?(Hash) ? payload["kind"] : nil,
          media_public_id: item&.public_id,
          token_sha256: ::MediaGallery::Security.token_sha256_label(token),
        },
      )
    rescue => e
      Rails.logger.debug("[media_gallery] stream anomaly counter failed metric=#{metric} error=#{e.class}: #{e.message}") if Rails.logger.respond_to?(:debug)
      nil
    end

    def stream_token_ip_digest(token)
      Digest::SHA256.hexdigest("#{token}|#{request.remote_ip}")
    rescue
      Digest::SHA256.hexdigest(token.to_s)
    end

    def stream_setting_integer(name, default: 0)
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def apply_private_stream_headers!
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Disposition"] = "inline"
    end

    def extract_range_header
      value = request.headers["Range"].to_s
      value = request.headers["HTTP_RANGE"].to_s if value.blank?
      value.presence
    end

    def parse_requested_byte_range(file_size)
      range = extract_range_header
      return nil unless range.present? && range.start_with?("bytes=")

      match = range.match(/bytes=(\d+)-(\d*)/i)
      return nil if match.blank?

      start_pos = match[1].to_i
      end_pos = match[2].present? ? match[2].to_i : (file_size - 1)

      if start_pos >= file_size
        response.headers["Content-Range"] = "bytes */#{file_size}"
        head 416
        return :invalid
      end

      end_pos = file_size - 1 if end_pos >= file_size
      return nil unless start_pos <= end_pos

      [start_pos, end_pos]
    end

    def stream_proxy_delivery(delivery)
      store = delivery[:store]
      key = delivery[:key].to_s
      raise Discourse::NotFound if store.blank? || key.blank?

      content_type = delivery[:content_type].presence || "application/octet-stream"
      file_size = delivery[:bytes].to_i

      if file_size <= 0 || content_type.blank?
        info = store.object_info(key)
        file_size = info[:bytes].to_i if file_size <= 0 && info.is_a?(Hash)
        content_type = info[:content_type].to_s.presence || content_type if info.is_a?(Hash)
      end

      if request.head?
        response.headers["Content-Type"] = content_type
        response.headers["Content-Length"] = file_size.to_s if file_size.positive?
        return head :ok
      end

      parsed_range = file_size.positive? ? parse_requested_byte_range(file_size) : nil
      return if parsed_range == :invalid

      if parsed_range.present?
        start_pos, end_pos = parsed_range
        data = store.read_range(key, start_pos: start_pos, end_pos: end_pos)
        length = data.to_s.b.bytesize

        response.status = 206
        response.headers["Content-Type"] = content_type
        response.headers["Content-Range"] = "bytes #{start_pos}-#{end_pos}/#{file_size}"
        response.headers["Content-Length"] = length.to_s
        return send_data(data, type: content_type, disposition: "inline", status: 206)
      end

      response.status = 200
      response.headers["Content-Type"] = content_type
      response.headers["Content-Length"] = file_size.to_s if file_size.positive?
      self.response_body = Enumerator.new do |yielder|
        store.stream(key) do |chunk|
          yielder << chunk
        end
      end
      nil
    end

    def resolve_file(item, payload, kind)
      # Backwards compat: old tokens carried an Upload id.
      if payload["upload_id"].present?
        upload = Upload.find_by(id: payload["upload_id"])
        raise Discourse::NotFound if upload.blank?

        allowed_upload_ids = [item.processed_upload_id, item.thumbnail_upload_id, item.original_upload_id]
          .compact
          .map(&:to_i)
        raise Discourse::NotFound unless allowed_upload_ids.include?(upload.id)

        local_path = MediaGallery::UploadPath.local_path_for(upload)
        raise Discourse::NotFound if local_path.blank?

        ext = upload.extension.to_s.downcase
        filename = "media-#{item.public_id}"
        filename = "#{filename}.#{ext}" if ext.present?

        content_type =
          if upload.respond_to?(:mime_type) && upload.mime_type.present?
            upload.mime_type.to_s
          elsif upload.respond_to?(:content_type) && upload.content_type.present?
            upload.content_type.to_s
          else
            (defined?(Rack::Mime) ? Rack::Mime.mime_type(".#{ext}") : "application/octet-stream")
          end
        content_type = "application/octet-stream" if content_type.blank?

        return { mode: :local, local_path: local_path, content_type: content_type, filename: filename }
      end

      raise Discourse::NotFound unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

      role_name = %w[thumbnail thumb].include?(kind.to_s) ? "thumbnail" : "main"
      delivery = ::MediaGallery::DeliveryResolver.new(item, role_name).resolve
      raise Discourse::NotFound if delivery.blank?

      {
        mode: delivery.mode,
        local_path: delivery.local_path,
        redirect_url: delivery.redirect_url,
        content_type: delivery.content_type,
        filename: delivery.filename,
        bytes: delivery.bytes,
        key: delivery.key,
        store: delivery.store
      }
    end

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_item_visible_to_current_user!(item)
      return if item.blank?
      return if !item.respond_to?(:admin_hidden?) || !item.admin_hidden?

      raise Discourse::NotFound
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end
  end
end
