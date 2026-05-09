# frozen_string_literal: true

module ::MediaGallery
  class AdminJobsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def index
      render_json_dump(
        ::MediaGallery::JobsDashboard.index(
          status: params[:status],
          type: params[:type],
          limit: params[:limit],
        )
      )
    rescue => e
      Rails.logger.warn("[media_gallery] admin jobs index failed #{e.class}: #{e.message}")
      render_json_dump(
        summary: {
          active_count: 0,
          failed_count: 0,
          completed_count: 0,
          visible_count: 0,
          total_count: 0,
          by_type: [],
        },
        rows: [],
        total_count: 0,
        error: "Unable to load jobs dashboard. #{e.class}: #{e.message}",
      )
    end
  end
end
