# frozen_string_literal: true

module Jobs
  class MediaGalleryCopyItemToTarget < ::Jobs::Base
    sidekiq_options queue: "default"

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      target_profile = args[:target_profile].to_s.presence || "target"
      run_token = args[:run_token].to_s.presence
      force = ActiveModel::Type::Boolean.new.cast(args[:force])
      auto_switch = ActiveModel::Type::Boolean.new.cast(args[:auto_switch])

      mutex_key = "media_gallery_copy_item_#{item.id}"
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(mutex_key, validity: 4.hours) do
          item.reload
          ::MediaGallery::MigrationCopy.perform_copy!(
            item,
            target_profile: target_profile,
            run_token: run_token,
            force: force,
            auto_switch: auto_switch
          )
        end
      else
        ::MediaGallery::MigrationCopy.perform_copy!(
          item,
          target_profile: target_profile,
          run_token: run_token,
          force: force,
          auto_switch: auto_switch
        )
      end
    end
  end
end
