# frozen_string_literal: true

module ::MediaGallery
  class StreamController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_plugin_enabled
    before_action :ensure_can_view

    # GET/HEAD /media/stream/:token(.ext)
    def show
      payload = MediaGallery::Token.verify(params[:token].to_s)
      raise Discourse::NotFound if payload.blank?

      # If token is bound to a user, enforce it.
      if payload["user_id"].present?
        raise Discourse::NotFound if current_user.blank?
        raise Discourse::NotFound if current_user.id != payload["user_id"].to_i
      end

      item = MediaGallery::MediaItem.find_by(id: payload["media_item_id"])
      raise Discourse::NotFound if item.blank?
      raise Discourse::NotFound unless item.ready?

      # Extra auth check (e.g. public view disabled)
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(current_user)

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

      if request.head?
        response.headers["Content-Type"] = content_type
        response.headers["Content-Length"] = File.size(local_path).to_s
        response.headers["Accept-Ranges"] = "bytes"
        return head :ok
      end

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
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(current_user)
    end
  end
end
