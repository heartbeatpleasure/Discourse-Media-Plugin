# frozen_string_literal: true

module Jobs
  class MediaGalleryGenerateTestDownload < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      task_id = args[:task_id].to_s
      public_id = args[:public_id].to_s
      user_id = args[:user_id].to_i
      mode = args[:mode].to_s
      start_segment = args[:start_segment].to_i
      segment_count = args[:segment_count].presence&.to_i

      ::MediaGallery::TestDownloads.mark_task_working!(task_id)

      item = ::MediaGallery::MediaItem.find_by(public_id: public_id)
      raise Discourse::NotFound if item.blank?
      raise Discourse::NotFound unless ::MediaGallery::Hls.ready?(item)

      artifact = ::MediaGallery::TestDownloads.build_artifact!(
        item: item,
        user_id: user_id,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      ::MediaGallery::TestDownloads.mark_task_complete!(task_id, artifact)
    rescue => e
      Rails.logger.warn("[media_gallery] test download job failed task_id=#{task_id} error=#{e.class}: #{e.message}")
      Rails.logger.warn(e.backtrace.first(30).join("\n")) if e.backtrace.present?
      ::MediaGallery::TestDownloads.mark_task_failed!(task_id, "#{e.class}: #{e.message}")
    end
  end
end
