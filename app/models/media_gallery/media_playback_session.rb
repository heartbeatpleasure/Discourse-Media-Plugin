# frozen_string_literal: true

module ::MediaGallery
  class MediaPlaybackSession < ::ActiveRecord::Base
    self.table_name = "media_gallery_playback_sessions"

    belongs_to :media_item, class_name: "MediaGallery::MediaItem"
    belongs_to :user

    validates :user_id, presence: true
    validates :media_item_id, presence: true
    validates :fingerprint_id, presence: true
  end
end
