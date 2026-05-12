# frozen_string_literal: true

module ::MediaGallery
  class MediaComment < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_comments"

    STATUSES = %w[visible deleted].freeze

    # IMPORTANT: inside the MediaGallery namespace, `belongs_to :user` would try
    # to resolve MediaGallery::User (which does not exist). We must point to ::User.
    belongs_to :user, class_name: "::User"
    belongs_to :media_item, class_name: "MediaGallery::MediaItem"
    belongs_to :deleted_by, class_name: "::User", optional: true

    has_many :media_comment_likes, class_name: "MediaGallery::MediaCommentLike", dependent: :delete_all

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :body, presence: true, length: { maximum: 5_000 }
    validates :status, inclusion: { in: STATUSES }

    scope :visible, -> { where(status: "visible", deleted_at: nil) }

    def visible?
      status == "visible" && deleted_at.blank?
    end
  end
end
