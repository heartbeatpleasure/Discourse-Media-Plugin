# frozen_string_literal: true

module Jobs
  class MediaGalleryHlsAes128BackfillItem < ::Jobs::Base
    sidekiq_options queue: "default"

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      Rails.logger.info("[media_gallery] AES backfill job executing item_id=#{item.id} run_token_present=#{args[:run_token].to_s.present?}")

      ::MediaGallery::HlsAes128Backfill.perform_item!(
        item,
        requested_by: args[:requested_by].to_s.presence,
        force: ActiveModel::Type::Boolean.new.cast(args[:force]),
        run_token: args[:run_token].to_s.presence
      )
      Rails.logger.info("[media_gallery] AES backfill job finished item_id=#{item.id}")
    rescue => e
      Rails.logger.warn("[media_gallery] AES backfill job failed item_id=#{args[:media_item_id]} error=#{e.class}: #{e.message}")
      raise e if SiteSetting.respond_to?(:media_gallery_processing_raise_to_sidekiq_retry) && SiteSetting.media_gallery_processing_raise_to_sidekiq_retry
      nil
    end
  end
end
