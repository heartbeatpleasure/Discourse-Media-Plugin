# frozen_string_literal: true

module ::Jobs
  class MediaGalleryHealthWatchdog < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless SiteSetting.media_gallery_enabled
      return unless defined?(::MediaGallery::HealthCheck)

      ::MediaGallery::HealthCheck.watchdog!
    rescue => e
      Rails.logger.error("[media_gallery] health watchdog job failed: #{e.class}: #{e.message}")
    end
  end
end
