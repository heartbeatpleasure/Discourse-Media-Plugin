# frozen_string_literal: true

module ::MediaGallery
  class AdminLogsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def index
      search = ::MediaGallery::LogEvents.search(
        q: params[:q],
        severity: params[:severity],
        event_type: params[:event_type],
        hours: params[:hours],
        limit: params[:limit],
      )

      render_json_dump(
        events: ::MediaGallery::LogEvents.serialize_rows(search[:rows]),
        summary: ::MediaGallery::LogEvents.summary(
          scope: search[:scope],
          rows: search[:rows],
          hours: search[:hours],
        ),
        filters: {
          q: params[:q].to_s,
          severity: params[:severity].to_s.presence || "all",
          event_type: params[:event_type].to_s.presence || "all",
          hours: search[:hours],
          limit: search[:limit],
        },
        filter_options: {
          severities: %w[all info warning danger],
          event_types: ["all"] + ::MediaGallery::LogEvents.event_type_options,
        },
        error: search[:error].presence,
      )
    rescue => e
      Rails.logger.warn("[media_gallery] admin logs index failed #{e.class}: #{e.message}")
      render_json_dump(
        events: [],
        summary: ::MediaGallery::LogEvents.summary(scope: nil, rows: [], hours: normalized_hours),
        filters: {
          q: params[:q].to_s,
          severity: params[:severity].to_s.presence || "all",
          event_type: params[:event_type].to_s.presence || "all",
          hours: normalized_hours,
          limit: normalized_limit,
        },
        filter_options: {
          severities: %w[all info warning danger],
          event_types: ["all"],
        },
        error: "Unable to load logs. #{e.class}: #{e.message}",
      )
    end

    private

    def normalized_hours
      value = params[:hours].to_i
      return 168 if value <= 0
      [value, 24 * 90].min
    end

    def normalized_limit
      value = params[:limit].to_i
      return 100 if value <= 0
      [value, 250].min
    end
  end
end
