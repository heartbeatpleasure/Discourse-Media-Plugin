# frozen_string_literal: true

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in
    before_action :ensure_can_view

    def show
      payload = MediaGallery::Token.verify(params[:token].to_s)
      raise Discourse::NotFound if payload.blank?

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        raise Discourse::NotFound
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        raise Discourse::NotFound
      end

      item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      raise Discourse::NotFound if item.blank?
      raise Discourse::NotFound unless item.ready?

      upload = ::Upload.find_by(id: payload["upload_id"])
      raise Discourse::NotFound if upload.blank?

      allowed_upload_ids =
        [item.processed_upload_id, item.thumbnail_upload_id, item.original_upload_id].compact.map(&:to_i)
      raise Discourse::NotFound unless allowed_upload_ids.include?(upload.id)

      local_path = MediaGallery::UploadPath.local_path_for(upload)
      raise Discourse::NotFound if local_path.blank? || !File.exist?(local_path)

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

      file_size = File.size(local_path)

      # Harder to "save as": short-lived token + no-store headers.
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Disposition"] = %(inline; filename="#{filename}")

      # Handle single-range requests: bytes=start-end
      range = request.headers["Range"].to_s
      if range.present?
        m = range.match(/bytes=(\d+)-(\d*)/i)
        if m
          start_pos = m[1].to_i
          end_pos =
            if m[2].present?
              m[2].to_i
            else
              # If end not specified, serve up to 1MB (typical player probe) or EOF
              [start_pos + (1024 * 1024) - 1, file_size - 1].min
            end

          # Invalid start
          if start_pos >= file_size
            response.headers["Content-Range"] = "bytes */#{file_size}"
            return head 416
          end

          end_pos = [end_pos, file_size - 1].min
          length = (end_pos - start_pos) + 1

          response.status = 206
          response.headers["Content-Type"] = content_type
          response.headers["Content-Range"] = "bytes #{start_pos}-#{end_pos}/#{file_size}"
          response.headers["Content-Length"] = length.to_s

          data = nil
          File.open(local_path, "rb") do |f|
            f.seek(start_pos)
            data = f.read(length)
          end

          self.response_body = [data]
          return
        end
        # If Range header is malformed, ignore and fall through to full response.
      end

      # Full response (no Range)
      response.headers["Content-Type"] = content_type
      response.headers["Content-Length"] = file_size.to_s

      # HEAD support
      return head :ok if request.head?

      # Send full file (players usually use Range anyway; this is fallback)
      send_file(
        local_path,
        disposition: "inline",
        filename: filename,
        type: content_type
      )
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
