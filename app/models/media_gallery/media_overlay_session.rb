# frozen_string_literal: true

module ::MediaGallery
  class MediaOverlaySession < ::ActiveRecord::Base
    self.table_name = "media_gallery_overlay_sessions"

    belongs_to :media_item, class_name: "MediaGallery::MediaItem"
    belongs_to :user

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :overlay_code, presence: true
    validates :media_type, presence: true
  end
end
