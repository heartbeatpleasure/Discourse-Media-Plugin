# frozen_string_literal: true

module ::Jobs
  class MediaGalleryCleanupChunkedUploads < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless SiteSetting.media_gallery_enabled
      return unless defined?(::MediaGallery::ChunkedUploads)

      result = ::MediaGallery::ChunkedUploads.cleanup_expired!(source: "scheduled")
      Rails.logger.info(
        "[media_gallery] chunked upload cleanup scanned=#{result[:scanned]} removed=#{result[:removed]} bytes_removed=#{result[:bytes_removed].to_i}"
      ) if result[:removed].to_i.positive?
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload cleanup failed: #{e.class}: #{e.message}")
    end
  end
end
