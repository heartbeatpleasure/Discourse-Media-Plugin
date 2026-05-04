# frozen_string_literal: true

module Jobs
  class MediaGalleryHlsAes128BackfillItem < ::Jobs::Base
    sidekiq_options queue: "default"

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      ::MediaGallery::HlsAes128Backfill.perform_item!(
        item,
        requested_by: args[:requested_by].to_s.presence,
        force: ActiveModel::Type::Boolean.new.cast(args[:force])
      )
    rescue => e
      Rails.logger.warn("[media_gallery] AES backfill job failed item_id=#{args[:media_item_id]} error=#{e.class}: #{e.message}")
      raise e if SiteSetting.respond_to?(:media_gallery_processing_raise_to_sidekiq_retry) && SiteSetting.media_gallery_processing_raise_to_sidekiq_retry
      nil
    end
  end
end
