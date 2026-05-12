# frozen_string_literal: true

module ::MediaGallery
  class MediaComment < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_comments"

    STATUSES = %w[visible deleted].freeze
    LEGACY_VISIBLE_STATUSES = ["visible", nil, ""].freeze

    # IMPORTANT: inside the MediaGallery namespace, `belongs_to :user` would try
    # to resolve MediaGallery::User (which does not exist). We must point to ::User.
    belongs_to :user, class_name: "::User"
    belongs_to :media_item, class_name: "MediaGallery::MediaItem"
    belongs_to :deleted_by, class_name: "::User", optional: true

    has_many :media_comment_likes, class_name: "MediaGallery::MediaCommentLike", foreign_key: :media_comment_id, dependent: :delete_all
    has_many :media_comment_reports, class_name: "MediaGallery::MediaCommentReport", foreign_key: :media_comment_id, dependent: :delete_all

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :body, presence: true, length: { maximum: 5_000 }
    validates :status, inclusion: { in: STATUSES }

    # Treat blank/nil status as visible for legacy/incomplete rows. The
    # current migration writes "visible" by default, but this keeps older
    # comments from disappearing if a previous iteration or partial migration
    # created rows without an explicit status. Deleted comments remain excluded
    # because deleted_at must still be blank and status "deleted" is not allowed.
    scope :visible, -> { where(deleted_at: nil).where(status: LEGACY_VISIBLE_STATUSES) }

    def visible?
      deleted_at.blank? && (status.blank? || status == "visible")
    end
  end
end
