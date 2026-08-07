# frozen_string_literal: true

module Jobs
  class MediaGalleryReplicateItem < ::Jobs::Base
    sidekiq_options queue: "default", retry: false

    def execute(args)
      item = ::MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      runner = lambda do
        ::MediaGallery::StorageReplica.perform!(
          item,
          run_token: args[:run_token].to_s.presence,
          reason: args[:reason].to_s.presence,
          requested_by: args[:requested_by].to_s.presence,
          force: ActiveModel::Type::Boolean.new.cast(args[:force]),
        )
      end

      if defined?(::DistributedMutex)
        # Keep replica writes from racing a migration copy or source cleanup for
        # the same item. StorageReplica.perform! acquires the per-item replica
        # mutex inside these two migration locks, giving every writer a stable
        # and consistent lock order.
        ::DistributedMutex.synchronize("media_gallery_copy_item_#{item.id}", validity: 12.hours) do
          ::DistributedMutex.synchronize("media_gallery_cleanup_item_#{item.id}", validity: 12.hours) do
            runner.call
          end
        end
      else
        runner.call
      end
    end
  end
end
