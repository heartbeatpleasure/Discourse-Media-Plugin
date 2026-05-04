# frozen_string_literal: true

module ::Jobs
  class MediaGalleryTempWorkspaceCleanup < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.media_gallery_enabled
      return unless defined?(::MediaGallery::TempWorkspaceCleanup)

      result = ::MediaGallery::TempWorkspaceCleanup.cleanup!(dry_run: false)
      ::MediaGallery::OperationLogger.audit(
        "admin_temp_workspace_cleanup_run",
        operation: "temp_cleanup",
        data: {
          stale_count: result[:stale_count],
          attempted_count: result[:attempted_count],
          removed_count: result[:removed_count],
          retention_hours: result[:retention_hours],
        }
      ) if defined?(::MediaGallery::OperationLogger)
    rescue => e
      Rails.logger.warn("[media_gallery] temp workspace cleanup failed: #{e.class}: #{e.message}")
    end
  end
end
