# frozen_string_literal: true

module ::MediaGallery
  class MediaLogEvent < ::ActiveRecord::Base
    self.table_name = "media_gallery_log_events"

    belongs_to :user, class_name: "::User", optional: true
    belongs_to :media_item, class_name: "MediaGallery::MediaItem", optional: true

    validates :event_type, presence: true
    validates :severity, presence: true
    validates :category, presence: true
  end
end
