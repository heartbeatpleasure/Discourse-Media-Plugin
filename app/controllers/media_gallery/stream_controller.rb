# frozen_string_literal: true

require "uri"

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_plugin_enabled

    # Belangrijk: deze endpoint moet nooit “app shell HTML” teruggeven.
    # We serveren via nginx (X-Accel-Redirect) als we LocalStore hebben.
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

      # Viewer access control
      raise Discourse::InvalidAccess unless MediaGallery::Permissions.can_view?(guardian)

      # Anti-cache headers
      response.headers["Cache-Control"] = "private, no-store, no-cache, must-revalidate, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"

      content_type = upload.content_type.presence || "application/octet-stream"
      response.headers["Content-Type"] = content_type

      filename =
        upload.original_filename.presence ||
          begin
            ext = upload.extension.presence
            base = "media-#{media_item.public_id}"
            ext.present? ? "#{base}.#{ext}" : base
          end

      safe_filename = filename.gsub(/[^0-9A-Za-z.\-_]/, "_")
      response.headers["Content-Disposition"] = %(inline; filename="#{safe_filename}")

      # ✅ FAST PATH: LocalStore -> laat nginx het bestand serveren (Range/streaming werkt dan goed)
      # We gebruiken het bestaande publieke pad (/uploads/...) als internal accel redirect.
      accel_path = internal_accel_path_for(upload)
      if accel_path.present?
        response.headers["X-Accel-Redirect"] = accel_path
        return head :ok
      end

      # Fallback: Rails send_file (bijv. non-local store of rare URL)
      path = MediaGallery::UploadPath.local_path_for(upload)
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

    # Zet upload.url om naar een nginx-serveable internal URI-pad ("/uploads/...")
    def internal_accel_path_for(upload)
      url = upload.url.to_s
      return nil if url.blank?

      # scheme-relative urls ("//host/path") -> maak parsebaar
      url = "http:#{url}" if url.start_with?("//")

      uri = URI.parse(url)
      path = uri.path.to_s
      return nil if path.blank?

      # Alleen als het een echte path is (geen externe bucket URL die je niet intern kan serveren)
      # Voor LocalStore is dit vrijwel altijd "/uploads/..."
      path
    rescue URI::InvalidURIError
      nil
    end
  end
end
