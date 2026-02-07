# frozen_string_literal: true

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_plugin_enabled

    # Members-only: always require a logged-in user.
    before_action :ensure_logged_in
    before_action :ensure_can_view

    # GET/HEAD /media/stream/:token(.:ext)
    def show
      payload = MediaGallery::Token.verify(params[:token].to_s)
      raise Discourse::NotFound if payload.blank?

      # Token can be bound to a user (recommended)
      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        raise Discourse::NotFound
      end

      # Token can be bound to an IP (optional)
      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        raise Discourse::NotFound
      end

      item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      raise Discourse::NotFound if item.blank?
      raise Discourse::NotFound unless item.ready?

      upload = Upload.find_by(id: payload["upload_id"])
      raise Discourse::NotFound if upload.blank?

      # Prevent token reuse for arbitrary uploads.
      allowed_upload_ids = [item.processed_upload_id, item.thumbnail_upload_id, item.original_upload_id]
        .compact
        .map(&:to_i)
      raise Discourse::NotFound unless allowed_upload_ids.include?(upload.id)

      local_path = MediaGallery::UploadPath.local_path_for(upload)
      raise Discourse::NotFound if local_path.blank? || !File.exist?(local_path)

      filename_ext = upload.extension.to_s.downcase
      filename = "media-#{item.public_id}"
      filename = "#{filename}.#{filename_ext}" if filename_ext.present?

      content_type = upload.content_type.presence || "application/octet-stream"
      file_size = File.size(local_path)

      # Discourage caching / storing.
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Disposition"] = "inline; filename=\"#{filename}\""

      if request.head?
        response.headers["Content-Type"] = content_type
        response.headers["Content-Length"] = file_size.to_s
        return head :ok
      end

      range = request.headers["HTTP_RANGE"].to_s

      if range.present? && range.start_with?("bytes=")
        # Example: bytes=0-1023
        m = range.match(/bytes=(\d*)-(\d*)/)
        if m
          start_s, end_s = m[1], m[2]
          start_pos = start_s.present? ? start_s.to_i : 0
          end_pos = end_s.present? ? end_s.to_i : (file_size - 1)

          start_pos = 0 if start_pos.negative?
          end_pos = file_size - 1 if end_pos >= file_size

          if start_pos <= end_pos
            length = (end_pos - start_pos) + 1

            response.status = 206
            response.headers["Content-Type"] = content_type
            response.headers["Content-Range"] = "bytes #{start_pos}-#{end_pos}/#{file_size}"
            response.headers["Content-Length"] = length.to_s

            data = IO.binread(local_path, length, start_pos)
            return send_data(data, type: content_type, disposition: "inline", filename: filename)
          end
        end
      end

      response.headers["Content-Type"] = content_type
      response.headers["Content-Length"] = file_size.to_s
      send_file(local_path, disposition: "inline", filename: filename, type: content_type)
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end
  end
end
