# frozen_string_literal: true

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_plugin_enabled

    # This endpoint is intentionally simple: validate token -> send_file inline.
    # It does not expose Upload URLs and discourages caching.
    def show
      token = params[:token].to_s
      payload = MediaGallery::Token.verify(token)
      raise Discourse::NotFound if payload.blank?

      exp = payload["exp"].to_i
      raise Discourse::NotFound if exp <= Time.now.to_i

      media_item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      raise Discourse::NotFound if media_item.nil? || !media_item.ready?

      upload = ::Upload.find_by(id: payload["upload_id"])
      raise Discourse::NotFound if upload.nil?

      # Optional binding checks
      if SiteSetting.media_gallery_bind_stream_to_user && payload["user_id"].present?
        raise Discourse::NotLoggedIn if current_user.nil?
        raise Discourse::InvalidAccess if current_user.id != payload["user_id"].to_i
      end

      if SiteSetting.media_gallery_bind_stream_to_ip && payload["ip"].present?
        raise Discourse::InvalidAccess if request.remote_ip != payload["ip"].to_s
      end

      # Access control (viewer rules)
      raise Discourse::InvalidAccess unless MediaGallery::Permissions.can_view?(guardian)

      path = MediaGallery::UploadPath.local_path_for(upload)

      # Anti-cache / anti-trivial-reuse headers
      response.headers["Cache-Control"] = "private, no-store, no-cache, must-revalidate, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
      response.headers["Accept-Ranges"] = "bytes"

      send_file(
        path,
        disposition: "inline",
        type: upload.content_type.presence || "application/octet-stream"
      )
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless MediaGallery::Permissions.enabled?
    end
  end
end
