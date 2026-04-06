# frozen_string_literal: true

module ::Jobs
  class MediaGalleryCleanupOriginals < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

      MediaGallery::PrivateStorage.cleanup_exported_originals!

      # Also cleanup temporary/old HLS build folders left behind by repackaging.
      # (Safe no-op when HLS isn't enabled.)
      begin
        MediaGallery::Hls.cleanup_build_artifacts! if defined?(MediaGallery::Hls)
      rescue
        # ignore
      end
    rescue => e
      Rails.logger.error("[media_gallery] cleanup originals failed: #{e.class}: #{e.message}")
    end
  end
end
