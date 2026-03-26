# frozen_string_literal: true

module Jobs
  class MediaGalleryForensicsIdentifyJob < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      task_id = args[:task_id].to_s
      task = ::MediaGallery::ForensicsIdentifyTasks.read_task(task_id)
      return if task.blank?

      ::MediaGallery::ForensicsIdentifyTasks.mark_task_working!(task_id)

      item = ::MediaGallery::MediaItem.find_by(id: task["media_item_id"].to_i) ||
        ::MediaGallery::MediaItem.find_by(public_id: task["public_id"].to_s)
      raise Discourse::NotFound if item.blank?

      result = ::MediaGallery::ForensicsIdentifyFileRunner.run(
        media_item: item,
        file_path: task["input_file_path"].to_s,
        max_samples: task["max_samples"].to_i,
        max_offset_segments: task["max_offset_segments"].to_i,
        layout: task["layout"].to_s.presence,
        async_mode: true,
      )

      ::MediaGallery::ForensicsIdentifyTasks.mark_task_complete!(task_id, result)
    rescue => e
      Rails.logger.warn("[media_gallery] forensics identify job failed task_id=#{task_id} error=#{e.class}: #{e.message}")
      Rails.logger.warn(e.backtrace.first(30).join("\n")) if e.backtrace.present?
      ::MediaGallery::ForensicsIdentifyTasks.mark_task_failed!(task_id, "#{e.class}: #{e.message}")
    end
  end
end
