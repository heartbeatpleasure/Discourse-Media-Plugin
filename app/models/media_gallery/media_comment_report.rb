# frozen_string_literal: true

module ::MediaGallery
  class MediaCommentReport < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_comment_reports"

    STATUSES = %w[open accepted rejected resolved].freeze

    belongs_to :user, class_name: "::User"
    belongs_to :media_item, class_name: "MediaGallery::MediaItem", foreign_key: :media_item_id
    belongs_to :media_comment, class_name: "MediaGallery::MediaComment", foreign_key: :media_comment_id
    belongs_to :comment_user, class_name: "::User", optional: true
    belongs_to :reviewed_by, class_name: "::User", optional: true

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :media_comment_id, presence: true
    validates :reason, presence: true, length: { maximum: 80 }
    validates :message, length: { maximum: 1200 }, allow_blank: true
    validates :status, inclusion: { in: STATUSES }

    scope :open, -> { where(status: "open") }
  end
end
