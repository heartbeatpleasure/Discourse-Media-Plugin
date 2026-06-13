# frozen_string_literal: true

module ::MediaGallery
  class MediaItemSerializer < ::ApplicationSerializer
    attributes(
      :public_id,
      :title,
      :description,
      :media_type,
      :gender,
      :tags,
      :duration_seconds,
      :width,
      :height,
      :filesize_processed_bytes,
      :views_count,
      :likes_count,
      :comments_count,
      :last_commented_at,
      :created_at,
      :uploader_username,
      :thumbnail_url,
      :force_blur_thumbnail,
      :playable,
      :liked,
      :can_view_likes
    )

    attribute :status, if: :can_see_status?
    attribute :error_message, if: :can_see_status?

    def comments_count
      return object.comments_count.to_i if object.respond_to?(:has_attribute?) && object.has_attribute?("comments_count")
      return object.comments_count.to_i if object.respond_to?(:comments_count)

      0
    rescue ActiveModel::MissingAttributeError, NoMethodError
      0
    end

    def last_commented_at
      return object.last_commented_at if object.respond_to?(:has_attribute?) && object.has_attribute?("last_commented_at")
      return object.last_commented_at if object.respond_to?(:last_commented_at)

      nil
    rescue ActiveModel::MissingAttributeError, NoMethodError
      nil
    end

    def uploader_username
      object.user&.username
    end

    def thumbnail_url
      # Stable URL that serves the thumbnail directly (with Cache-Control + ETag/Last-Modified).
      # This keeps raw Upload URLs out of HTML/JS AND allows browser caching across gallery pages.
      "/media/#{object.public_id}/thumbnail"
    end

    def force_blur_thumbnail
      return false unless object.respond_to?(:thumbnail_blur_supported?) && object.thumbnail_blur_supported?
      return object.force_blur_thumbnail_enabled? if object.respond_to?(:force_blur_thumbnail_enabled?)

      ActiveModel::Type::Boolean.new.cast(object.force_blur_thumbnail)
    rescue ActiveModel::MissingAttributeError, NoMethodError
      false
    end

    def playable
      object.status == "ready" && object.filesize_processed_bytes.to_i > 0
    end

    def liked
      u = scope&.user
      return false if u.nil?
      MediaGallery::MediaLike.exists?(user_id: u.id, media_item_id: object.id)
    end

    def can_view_likes
      u = scope&.user
      return false if u.nil?

      mode = if SiteSetting.respond_to?(:media_gallery_like_viewers)
        SiteSetting.media_gallery_like_viewers.to_s
      else
        "owner"
      end

      return true if mode == "everyone"
      return true if u.id == object.user_id

      u.staff? || u.admin?
    end

    def can_see_status?
      u = scope&.user
      return false if u.nil?
      u.admin? || u.staff? || u.id == object.user_id
    end
  end
end
