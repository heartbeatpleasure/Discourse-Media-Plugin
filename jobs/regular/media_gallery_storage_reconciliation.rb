# frozen_string_literal: true

module Jobs
  class MediaGalleryStorageReconciliation < ::Jobs::Base
    sidekiq_options queue: "default", retry: false

    MUTEX_KEY = "media_gallery_storage_reconciliation_job"
    MUTEX_VALIDITY = 6.hours
    PROGRESS_WRITE_INTERVAL_SECONDS = 1.0
    PROGRESS_ITEM_MILESTONE = 10

    def execute(args)
      task_id = args[:task_id].to_s
      task = ::MediaGallery::ReconciliationTasks.read_task(task_id)
      return if task.blank?
      return if ::MediaGallery::ReconciliationTasks.terminal_status?(task["status"])

      work = proc { perform_reconciliation(task_id) }

      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(MUTEX_KEY, validity: MUTEX_VALIDITY, &work)
      else
        work.call
      end
    rescue => e
      Rails.logger.error("[media_gallery] storage reconciliation job failed task_id=#{task_id}: #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(30).join("\n")) if e.backtrace.present?
      ::MediaGallery::ReconciliationTasks.mark_task_failed!(task_id, e) if task_id.present?
      nil
    end

    private

    def perform_reconciliation(task_id)
      task = ::MediaGallery::ReconciliationTasks.mark_task_working!(task_id)
      return if task.blank?

      last_write_at = 0.0
      last_stage = nil
      last_items_checked = 0
      last_profiles_checked = 0

      progress_callback = lambda do |progress|
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stage = progress[:stage].to_s
        items_checked = progress[:items_checked].to_i
        profiles_checked = progress[:profiles_checked].to_i
        stage_changed = stage != last_stage
        item_milestone = items_checked > last_items_checked && (items_checked % PROGRESS_ITEM_MILESTONE).zero?
        profile_changed = profiles_checked != last_profiles_checked
        interval_elapsed = now - last_write_at >= PROGRESS_WRITE_INTERVAL_SECONDS

        next unless stage_changed || item_milestone || profile_changed || interval_elapsed

        ::MediaGallery::ReconciliationTasks.update_progress!(task_id, progress)
        last_write_at = now
        last_stage = stage
        last_items_checked = items_checked
        last_profiles_checked = profiles_checked
      end

      report = ::MediaGallery::HealthCheck.run_reconciliation!(
        scan_mode: task["scan_mode"],
        progress_callback: progress_callback,
      )

      ::MediaGallery::ReconciliationTasks.mark_task_complete!(task_id, report)
    end
  end
end
