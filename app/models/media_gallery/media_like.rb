# frozen_string_literal: true

module ::MediaGallery
  class MediaLike < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_likes"

    belongs_to :user
    belongs_to :media_item, class_name: "MediaGallery::MediaItem"

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :user_id, uniqueness: { scope: :media_item_id }
  end
end
