# frozen_string_literal: true

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_plugin_enabled

    before_action :ensure_can_view, only: [:index, :status, :thumbnail, :play]
    before_action :ensure_logged_in, only: [:create, :like, :unlike]
    before_action :ensure_can_upload, only: [:create]

    def index
      page = (params[:page].presence || 1).to_i
      per_page = [(params[:per_page].presence || 24).to_i, 100].min
      offset = (page - 1) * per_page

      items = MediaGallery::MediaItem
        .where(status: "ready")
        .order(created_at: :desc)

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

    def create
      upload_id = params[:upload_id].to_i
      if upload_id <= 0
        render_json_error("invalid_upload_id")
        return
      end

      upload = Upload.find_by(id: upload_id)
      if upload.blank?
        render_json_error("upload_not_found")
        return
      end

      # Caller may pass media_type, otherwise infer from the Upload.
      media_type = params[:media_type].to_s.downcase.presence
      media_type ||= infer_media_type(upload)

      unless MediaGallery::MediaItem::TYPES.include?(media_type)
        render_json_error("invalid_media_type")
        return
      end

      tags = params[:tags]
      tags = tags.is_a?(Array) ? tags : tags.to_s.split(",") if tags.present?

      # Images can be served as-is (no ffmpeg pipeline). Video/audio go through processing.
      status = (media_type == "image" ? "ready" : "queued")

      item = MediaGallery::MediaItem.create!(
        public_id: SecureRandom.uuid,
        user_id: current_user.id,
        title: params[:title].to_s,
        description: params[:description].to_s,
        media_type: media_type,
        gender: params[:gender].to_s.presence,
        tags: (tags || []).map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq,
        original_upload_id: upload.id,
        status: status,
        processed_upload_id: (status == "ready" ? upload.id : nil),
        thumbnail_upload_id: (status == "ready" ? upload.id : nil),
        width: (status == "ready" ? upload.width : nil),
        height: (status == "ready" ? upload.height : nil)
      )

      Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id) if status == "queued"

      render_json_dump(public_id: item.public_id, status: item.status)
    end

    def status
      item = find_item_by_public_id!(params[:public_id])

      render_json_dump(
        public_id: item.public_id,
        status: item.status,
        error_message: item.error_message
      )
    end

    def play
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?
      raise Discourse::NotFound if item.processed_upload_id.blank?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: item.processed_upload_id,
        kind: "main",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)

      # Best-effort view count
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      # Important: do NOT hardcode mp4. Use the actual extension (mp4/mp3/jpg/...)
      ext = item.processed_upload&.extension.to_s.downcase
      stream_url =
        if ext.present?
          "/media/stream/#{token}.#{ext}"
        else
          "/media/stream/#{token}"
        end

      render_json_dump(stream_url: stream_url, expires_at: payload["exp"])
    end

    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?
      raise Discourse::NotFound if item.thumbnail_upload_id.blank?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: item.thumbnail_upload_id,
        kind: "thumbnail",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)

      ext = item.thumbnail_upload&.extension.to_s.downcase
      url =
        if ext.present?
          "/media/stream/#{token}.#{ext}"
        else
          "/media/stream/#{token}"
        end

      redirect_to url
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
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(current_user)
    end

    def ensure_can_upload
      raise Discourse::NotFound unless MediaGallery::Permissions.can_upload?(current_user)
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.blank?
      item
    end

    def infer_media_type(upload)
      ext = upload.extension.to_s.downcase
      ctype = upload.content_type.to_s.downcase

      return "image" if ctype.start_with?("image/") || %w[jpg jpeg png gif webp svg].include?(ext)
      return "audio" if ctype.start_with?("audio/") || %w[mp3 m4a aac ogg opus wav flac].include?(ext)
      return "video" if ctype.start_with?("video/") || %w[mp4 m4v mov webm mkv avi].include?(ext)

      nil
    end
  end
end
