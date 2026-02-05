# frozen_string_literal: true

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in

    def index
      guardian.ensure_can_see_media_gallery!

      page = (params[:page].presence || 1).to_i
      per_page = [(params[:per_page].presence || SiteSetting.media_gallery_per_page).to_i, 50].min

      scope = MediaGallery::MediaItem.ready.order(created_at: :desc)

      if params[:gender].present?
        scope = scope.where(gender: params[:gender])
      end

      if params[:tags].present?
        # allow "tags=a,b" or repeated "tags[]=a"
        tags = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].to_s.split(",")
        tags = tags.map { |t| t.to_s.strip.downcase }.reject(&:blank?)
        scope = scope.where("tags @> ARRAY[?]::varchar[]", tags) if tags.present?
      end

      total = scope.count
      items = scope.offset((page - 1) * per_page).limit(per_page)

      render_json_dump(
        media_items: ActiveModel::ArraySerializer.new(items, each_serializer: MediaGallery::MediaItemSerializer, scope: guardian),
        page: page,
        per_page: per_page,
        total: total
      )
    end

    def my
      guardian.ensure_can_see_media_gallery!

      page = (params[:page].presence || 1).to_i
      per_page = [(params[:per_page].presence || SiteSetting.media_gallery_per_page).to_i, 50].min

      scope = MediaGallery::MediaItem.ready.where(uploader_user_id: current_user.id).order(created_at: :desc)

      total = scope.count
      items = scope.offset((page - 1) * per_page).limit(per_page)

      render_json_dump(
        media_items: ActiveModel::ArraySerializer.new(items, each_serializer: MediaGallery::MediaItemSerializer, scope: guardian),
        page: page,
        per_page: per_page,
        total: total
      )
    end

    def show
      guardian.ensure_can_see_media_gallery!

      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      render_json_dump(
        media_item: MediaGallery::MediaItemSerializer.new(item, scope: guardian)
      )
    end

    def create
      guardian.ensure_can_upload_media_gallery!

      upload_id = params[:upload_id].to_i
      raise Discourse::InvalidParameters if upload_id <= 0

      upload = ::Upload.find_by(id: upload_id)
      raise Discourse::NotFound if upload.nil?

      title = params[:title].to_s.strip
      raise Discourse::InvalidParameters if title.blank?

      description = params[:description].to_s

      gender = params[:gender].to_s
      allowed_genders = %w[male female non-binary]
      raise Discourse::InvalidParameters unless allowed_genders.include?(gender)

      tags = (params[:tags].presence || [])
      tags = tags.is_a?(Array) ? tags : tags.to_s.split(",")
      tags = tags.map { |t| t.to_s.strip.downcase }.reject(&:blank?).uniq
      tags = tags.take(20)

      item = MediaGallery::MediaItem.create!(
        public_id: SecureRandom.uuid,
        uploader_user_id: current_user.id,
        title: title,
        description: description,
        gender: gender,
        tags: tags,
        original_upload_id: upload.id,
        status: "queued"
      )

      Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id)

      render_json_dump(public_id: item.public_id, status: item.status)
    end

    def status
      guardian.ensure_can_see_media_gallery!

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

      upload = ::Upload.find_by(id: item.processed_upload_id)
      raise Discourse::NotFound if upload.nil?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: item.processed_upload_id,
        kind: "main",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)

      # Best-effort view count bump when issuing a token
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      # Optional extension helps browsers pick a better default player.
      # We still set Content-Type based on Upload in the stream controller.
      ext = upload.extension.to_s.downcase.gsub(/[^a-z0-9]/, "")
      ext = "" if ext.length > 10

      stream_url = ext.present? ? "/media/stream/#{token}.#{ext}" : "/media/stream/#{token}"

      render_json_dump(
        stream_url: stream_url,
        expires_at: payload["exp"]
      )
    end

    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      upload_id = item.thumbnail_upload_id.presence || item.processed_upload_id
      raise Discourse::NotFound if upload_id.blank?

      upload = ::Upload.find_by(id: upload_id)
      raise Discourse::NotFound if upload.nil?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: upload_id,
        kind: "thumbnail",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)

      ext = upload.extension.to_s.downcase.gsub(/[^a-z0-9]/, "")
      ext = "" if ext.length > 10

      url = ext.present? ? "/media/stream/#{token}.#{ext}" : "/media/stream/#{token}"
      redirect_to url
    end

    def toggle_like
      guardian.ensure_can_see_media_gallery!

      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      like = MediaGallery::MediaLike.find_by(media_item_id: item.id, user_id: current_user.id)
      if like
        like.destroy!
        MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = GREATEST(likes_count - 1, 0)")
        liked = false
      else
        MediaGallery::MediaLike.create!(media_item_id: item.id, user_id: current_user.id)
        MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = likes_count + 1")
        liked = true
      end

      render_json_dump(liked: liked)
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless MediaGallery::Permissions.enabled?
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.nil?
      item
    end
  end
end
