# frozen_string_literal: true

module Jobs
  class MediaGalleryCleanupSourceAfterSwitch < ::Jobs::Base
    sidekiq_options queue: "default"

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      mutex_key = "media_gallery_cleanup_item_#{item.id}"
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(mutex_key, validity: 4.hours) do
          item.reload
          ::MediaGallery::MigrationCleanup.perform_cleanup!(
            item,
            run_token: args[:run_token].to_s.presence,
            force: ActiveModel::Type::Boolean.new.cast(args[:force]),
            auto_finalize: ActiveModel::Type::Boolean.new.cast(args[:auto_finalize])
          )
        end
      else
        ::MediaGallery::MigrationCleanup.perform_cleanup!(
          item,
          run_token: args[:run_token].to_s.presence,
          force: ActiveModel::Type::Boolean.new.cast(args[:force]),
          auto_finalize: ActiveModel::Type::Boolean.new.cast(args[:auto_finalize])
        )
      end
    rescue => e
      Rails.logger.error("[media-gallery] cleanup job failed for item=#{item&.id || args[:media_item_id]}: #{e.class}: #{e.message}")
      nil
    end
  end
end
