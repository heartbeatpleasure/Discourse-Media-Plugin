# frozen_string_literal: true

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    layout false

    before_action :ensure_plugin_enabled
    before_action :force_non_html_format

    # This is a binary streaming endpoint. We don't want any HTML bootstrapping,
    # redirects, or preloaded JSON behavior that Discourse normally applies.
    skip_before_action :preload_json, raise: false
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :check_xhr, raise: false

    rescue_from Discourse::NotLoggedIn do
      render plain: "not_logged_in", status: 403
    end

    rescue_from Discourse::InvalidAccess do
      render plain: "forbidden", status: 403
    end

    rescue_from Discourse::NotFound do
      render plain: "not_found", status: 404
    end

    rescue_from StandardError do |e|
      Rails.logger.error("[media_gallery] stream error: #{e.class}: #{e.message}")
      render plain: "error", status: 500
    end

    # validate token -> send_file inline.
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

      # Access control (viewer rules)
      raise Discourse::InvalidAccess unless MediaGallery::Permissions.can_view?(guardian)

      # Optional binding checks
      if SiteSetting.media_gallery_bind_stream_to_user && payload["user_id"].present?
        raise Discourse::NotLoggedIn if current_user.nil?
        raise Discourse::InvalidAccess if current_user.id != payload["user_id"].to_i
      end

      if SiteSetting.media_gallery_bind_stream_to_ip && payload["ip"].present?
        raise Discourse::InvalidAccess if request.remote_ip != payload["ip"].to_s
      end

      path = MediaGallery::UploadPath.local_path_for(upload)

      # Anti-cache / anti-trivial-reuse headers
      response.headers["Cache-Control"] = "private, no-store, no-cache, must-revalidate, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
      response.headers["Accept-Ranges"] = "bytes"

      # Force content type based on the Upload, not the (optional) URL extension.
      content_type = upload.content_type.presence || "application/octet-stream"

      send_file(
        path,
        disposition: "inline",
        type: content_type
      )
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless MediaGallery::Permissions.enabled?
    end

    def force_non_html_format
      # When the client sends Accept: */* (curl default), Rails often resolves the request as HTML.
      # In Discourse that can trigger HTML app-shell behavior on errors/redirects.
      # We keep the endpoint binary by forcing a non-HTML format early.
      request.format = :json if request.format&.html?
    end
  end
end
