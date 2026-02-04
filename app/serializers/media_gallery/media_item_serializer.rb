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
      :created_at,
      :uploader_username,
      :thumbnail_url,
      :liked
    )

    attribute :status, if: :can_see_status?

    def uploader_username
      object.user&.username
    end

    def thumbnail_url
      # Stable URL that performs a server-side redirect to a short-lived tokenized stream.
      # This keeps raw Upload URLs out of HTML/JS.
      "/media/#{object.public_id}/thumbnail"
    end

    def liked
      u = scope&.user
      return false if u.nil?
      MediaGallery::MediaLike.exists?(user_id: u.id, media_item_id: object.id)
    end

    def can_see_status?
      u = scope&.user
      return false if u.nil?
      u.admin? || u.id == object.user_id
    end
  end
end
