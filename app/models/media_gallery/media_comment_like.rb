# frozen_string_literal: true

module ::MediaGallery
  class MediaCommentLike < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_comment_likes"

    # IMPORTANT: inside the MediaGallery namespace, `belongs_to :user` would try
    # to resolve MediaGallery::User (which does not exist). We must point to ::User.
    belongs_to :user, class_name: "::User"
    belongs_to :media_item, class_name: "MediaGallery::MediaItem", foreign_key: :media_item_id
    belongs_to :media_comment, class_name: "MediaGallery::MediaComment", foreign_key: :media_comment_id

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :media_comment_id, presence: true
    validates :user_id, uniqueness: { scope: :media_comment_id }
  end
end
