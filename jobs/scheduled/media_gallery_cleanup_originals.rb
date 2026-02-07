# frozen_string_literal: true

module ::Jobs
  class MediaGalleryCleanupOriginals < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless SiteSetting.respond_to?(:media_gallery_private_storage_enabled)
      return unless SiteSetting.media_gallery_private_storage_enabled

      MediaGallery::PrivateStorage.cleanup_exported_originals!
    rescue => e
      Rails.logger.error("[media_gallery] cleanup originals failed: #{e.class}: #{e.message}")
    end
  end
end
