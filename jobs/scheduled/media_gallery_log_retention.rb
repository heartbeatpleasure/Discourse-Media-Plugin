# frozen_string_literal: true

module ::Jobs
  class MediaGalleryLogRetention < ::Jobs::Scheduled
    every 1.day

    BATCH_SIZE = 1_000
    DEFAULT_RETENTION_DAYS = 365

    def execute(args)
      days = retention_days
      return if days <= 0
      return unless defined?(::MediaGallery::MediaLogEvent)
      return unless defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.table_present?

      cutoff = Time.zone.now - days.days
      deleted = 0

      ::MediaGallery::MediaLogEvent
        .unscoped
        .where("created_at < ?", cutoff)
        .in_batches(of: BATCH_SIZE) do |batch|
          deleted += batch.delete_all
        end

      if deleted.positive?
        Rails.logger.info(
          "[media_gallery] operational log retention deleted=#{deleted} cutoff=#{cutoff.utc.iso8601} retention_days=#{days}"
        )
      end
    rescue => e
      Rails.logger.error("[media_gallery] operational log retention failed: #{e.class}: #{e.message}")
      raise
    end

    private

    def retention_days
      return DEFAULT_RETENTION_DAYS unless SiteSetting.respond_to?(:media_gallery_log_event_retention_days)

      [SiteSetting.media_gallery_log_event_retention_days.to_i, 0].max
    rescue
      DEFAULT_RETENTION_DAYS
    end
  end
end
