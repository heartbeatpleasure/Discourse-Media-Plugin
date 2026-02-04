# frozen_string_literal: true

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_plugin_enabled
    before_action :ensure_can_view, only: %i[index show thumbnail my play]
    before_action :ensure_logged_in, only: %i[create toggle_like]
    before_action :ensure_can_upload, only: %i[create]

    def index
      page = (params[:page].to_i <= 0) ? 1 : params[:page].to_i
      per_page = [[params[:per_page].to_i, 1].max, 50].min
      offset = (page - 1) * per_page

      items = MediaGallery::MediaItem.where(status: "ready")

      if params[:media_type].present?
        mt = params[:media_type].to_s.downcase
        items = items.where(media_type: mt) if MediaGallery::MediaItem::TYPES.include?(mt)
      end

      if params[:gender].present?
        g = params[:gender].to_s.downcase
        items = items.where(gender: g) if MediaGallery::MediaItem::GENDERS.include?(g)
      end

      if params[:tags].present?
        tags = params[:tags].to_s.split(",").map { |t| t.strip.downcase }.reject(&:blank?).uniq
        if tags.any?
          # Match ANY tag by default (overlap)
          items = items.where("tags && ARRAY[?]::text[]", tags)
        end
      end

      if params[:q].present?
        q = params[:q].to_s.strip
        if q.length >= 2
          items = items.where("title ILIKE ?", "%#{q}%")
        end
      end

      items = items.order(created_at: :desc)
      total = items.count
      items = items.limit(per_page).offset(offset)

      render_json_dump(
        media_items: serialize_data(items, MediaGallery::MediaItemSerializer),
        page: page,
        per_page: per_page,
        total: total
      )
    end

    def show
      item = find_item_by_public_id!(params[:public_id])

      render_json_dump(
        media_item: serialize_data(item, MediaGallery::MediaItemSerializer)
      )
    end

    def my
      raise Discourse::NotLoggedIn unless current_user

      items = MediaGallery::MediaItem.where(user_id: current_user.id).order(created_at: :desc).limit(100)
      render_json_dump(media_items: serialize_data(items, MediaGallery::MediaItemSerializer))
    end

    def status
      item = find_item_by_public_id!(params[:public_id])
      guardian.ensure_can_see!(item.user) unless guardian.is_admin? || current_user&.id == item.user_id

      render_json_dump(
        public_id: item.public_id,
        status: item.status,
        error_message: item.error_message
      )
    end

    def create
      upload_id = params[:upload_id].to_i
      title = params[:title].to_s.strip
      description = params[:description].to_s
      gender = params[:gender].presence&.to_s&.downcase
      tags = params[:tags]

      upload = ::Upload.find_by(id: upload_id)
      raise Discourse::NotFound if upload.nil?

      # Ownership check (staff can override)
      unless guardian.is_admin? || upload.user_id == current_user.id
        raise Discourse::InvalidAccess
      end

      if gender.present? && !MediaGallery::MediaItem::GENDERS.include?(gender)
        return render_json_error("invalid_gender")
      end

      tag_list =
        case tags
        when Array
          tags
        when String
          tags.split(",")
        else
          []
        end

      item = MediaGallery::MediaItem.new(
        user_id: current_user.id,
        original_upload_id: upload.id,
        status: "queued",
        title: title,
        description: description,
        gender: gender,
        tags: tag_list,
        filesize_original_bytes: upload.filesize
      )

      item.save!

      ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id)

      render_json_dump(public_id: item.public_id, status: item.status)
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

      # Views are counted when a token is issued (best-effort)
      MediaGallery::MediaItem.where(id: item.id).update_all("views_count = views_count + 1")

      render_json_dump(
        stream_url: "/media/stream/#{token}",
        expires_at: payload["exp"]
      )
    end

    def thumbnail
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      upload_id = item.thumbnail_upload_id.presence || item.processed_upload_id
      raise Discourse::NotFound if upload_id.blank?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload_id: upload_id,
        kind: "thumbnail",
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.generate(payload)
      redirect_to "/media/stream/#{token}"
    end

    def toggle_like
      item = find_item_by_public_id!(params[:public_id])
      raise Discourse::NotFound unless item.ready?

      like = MediaGallery::MediaLike.find_by(user_id: current_user.id, media_item_id: item.id)

      if like
        like.destroy!
        MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = GREATEST(likes_count - 1, 0)")
        liked = false
      else
        MediaGallery::MediaLike.create!(user_id: current_user.id, media_item_id: item.id)
        MediaGallery::MediaItem.where(id: item.id).update_all("likes_count = likes_count + 1")
        liked = true
      end

      item.reload
      render_json_dump(public_id: item.public_id, likes_count: item.likes_count, liked: liked)
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless MediaGallery::Permissions.enabled?
    end

    def ensure_can_view
      return if MediaGallery::Permissions.can_view?(guardian)
      raise Discourse::InvalidAccess
    end

    def ensure_can_upload
      return if MediaGallery::Permissions.can_upload?(guardian)
      raise Discourse::InvalidAccess
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.nil?
      item
    end
  end
end
