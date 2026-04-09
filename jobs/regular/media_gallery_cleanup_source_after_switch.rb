# frozen_string_literal: true

module Jobs
  class MediaGalleryCleanupSourceAfterSwitch < ::Jobs::Base
    sidekiq_options queue: "default"

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      ::MediaGallery::MigrationCleanup.perform_cleanup!(
        item,
        run_token: args[:run_token].to_s.presence,
        force: ActiveModel::Type::Boolean.new.cast(args[:force]),
        auto_finalize: ActiveModel::Type::Boolean.new.cast(args[:auto_finalize])
      )
    end
  end
end
