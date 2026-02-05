# frozen_string_literal: true

module ::MediaGallery
  class MediaController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_plugin_enabled
    before_action :ensure_can_view, only: [:index, :show, :status, :play, :thumbnail]
    before_action :ensure_logged_in, only: [:create, :toggle_like, :play]
    before_action :ensure_can_upload, only: [:create]

    def index
      scope = MediaGallery::MediaItem.ready.order(created_at: :desc)

      if params[:gender].present? && MediaGallery::MediaItem::GENDERS.include?(params[:gender])
        scope = scope.where(gender: params[:gender])
      end

      if params[:tags].present?
        tags =
          case params[:tags]
          when String then params[:tags].split(",").map(&:strip).reject(&:blank?)
          when Array then params[:tags].map(&:to_s).map(&:strip).reject(&:blank?)
          else []
          end

        tags.each { |t| scope = scope.where("tags @> ARRAY[?]::varchar[]", t) } if tags.any?
      end

      page = params[:page].to_i
      page = 1 if page < 1

      per_page = params[:per_page].to_i
      per_page = 24 if per_page <= 0
      per_page = [per_page, 100].min

      total = scope.count
      items = scope.offset((page - 1) * per_page).limit(per_page)

      render json: {
        media_items: items.map { |i| serialize_item(i) },
        page: page,
        per_page: per_page,
        total: total
      }
    end

    def show
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id])
      raise Discourse::NotFound if item.nil?

      render json: serialize_item(item)
    end

    def create
      upload_id = params[:upload_id].to_i
      title = params[:title].to_s
      description = params[:description].to_s
      media_type = params[:media_type].to_s.presence

      gender = params[:gender].to_s
      unless MediaGallery::MediaItem::GENDERS.include?(gender)
        return render json: { errors: ["invalid_gender"] }, status: 400
      end

      tags =
        case params[:tags]
        when String then params[:tags].split(",").map(&:strip).reject(&:blank?)
        when Array then params[:tags].map(&:to_s).map(&:strip).reject(&:blank?)
        else []
        end

      item = MediaGallery::MediaItem.new(
        upload_id: upload_id,
        title: title,
        description: description,
        media_type: media_type,
        gender: gender,
        tags: tags,
        uploader_id: current_user.id,
        status: MediaGallery::MediaItem.statuses[:queued]
      )

      item.save!

      ::Jobs.enqueue(:media_gallery_process_item, media_item_id: item.id)

      render json: { public_id: item.public_id, status: item.status }, status: 201
    rescue StandardError => e
      Rails.logger.error("[media_gallery] create failed: #{e.class}: #{e.message}\n#{e.backtrace&.take(40)&.join("\n")}")
      render json: { errors: ["internal_error"], detail: e.message }, status: 500
    end

    def status
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id])
      raise Discourse::NotFound if item.nil?

      render json: {
        public_id: item.public_id,
        status: item.status,
        error_message: item.error_message
      }
    end

    def play
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id])
      raise Discourse::NotFound if item.nil?
      raise Discourse::InvalidAccess unless item.ready?

      upload = item.processed_upload || item.original_upload
      raise Discourse::NotFound if upload.nil?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload: upload,
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.sign(payload)

      # ✅ geen hardcoded mp4; extension dynamisch
      ext = upload.extension.to_s.strip
      stream_url = ext.present? ? "/media/stream/#{token}.#{ext}" : "/media/stream/#{token}"

      render json: { stream_url: stream_url, expires_at: payload[:exp] }
    rescue StandardError => e
      Rails.logger.error("[media_gallery] play failed: #{e.class}: #{e.message}\n#{e.backtrace&.take(40)&.join("\n")}")
      render json: { errors: ["internal_error"], detail: e.message }, status: 500
    end

    def thumbnail
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id])
      raise Discourse::NotFound if item.nil?
      raise Discourse::InvalidAccess unless item.ready?

      upload = item.thumbnail_upload || item.processed_upload || item.original_upload
      raise Discourse::NotFound if upload.nil?

      payload = MediaGallery::Token.build_stream_payload(
        media_item: item,
        upload: upload,
        user: current_user,
        request: request
      )

      token = MediaGallery::Token.sign(payload)

      ext = upload.extension.to_s.strip
      url = ext.present? ? "/media/stream/#{token}.#{ext}" : "/media/stream/#{token}"

      redirect_to url
    end

    def toggle_like
      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id])
      raise Discourse::NotFound if item.nil?

      like = MediaGallery::MediaLike.find_by(media_item_id: item.id, user_id: current_user.id)

      if like
        like.destroy!
        item.decrement!(:likes_count)
        liked = false
      else
        MediaGallery::MediaLike.create!(media_item_id: item.id, user_id: current_user.id)
        item.increment!(:likes_count)
        liked = true
      end

      render json: { liked: liked, likes_count: item.likes_count }
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless MediaGallery::Permissions.enabled?
    end

    def ensure_can_view
      raise Discourse::InvalidAccess unless MediaGallery::Permissions.can_view?(guardian)
    end

    def ensure_can_upload
      raise Discourse::InvalidAccess unless MediaGallery::Permissions.can_upload?(guardian)
    end

    def serialize_item(item)
      {
        public_id: item.public_id,
        title: item.title,
        description: item.description.to_s,
        media_type: item.media_type,
        gender: item.gender,
        tags: item.tags || [],
        duration_seconds: item.duration_seconds,
        width: item.width,
        height: item.height,
        filesize_processed_bytes: item.filesize_processed_bytes,
        views_count: item.views_count,
        likes_count: item.likes_count,
        created_at: item.created_at,
        uploader_username: item.uploader&.username,
        thumbnail_url: "/media/#{item.public_id}/thumbnail",
        liked: (current_user ? MediaGallery::MediaLike.exists?(media_item_id: item.id, user_id: current_user.id) : false),
        status: item.status
      }
    end
  end
end
