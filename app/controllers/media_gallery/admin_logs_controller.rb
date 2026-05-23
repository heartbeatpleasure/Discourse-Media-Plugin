# frozen_string_literal: true

module ::MediaGallery
  class AdminLogsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    MEDIA_GALLERY_ADMIN_PAGE_KEY = :logs
    include ::MediaGallery::AdminAccess::ControllerMethods

    def index
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timing = {}
      search = timed_phase!(timing, :search) do
        ::MediaGallery::LogEvents.search(
          q: params[:q],
          severity: params[:severity],
          category: params[:category],
          event_type: params[:event_type],
          hours: params[:hours],
          limit: params[:limit],
          sort: params[:sort],
        )
      end
      events = timed_phase!(timing, :serialize) { ::MediaGallery::LogEvents.serialize_rows(search[:rows]) }
      summary = timed_phase!(timing, :summary) do
        ::MediaGallery::LogEvents.summary(
          scope: search[:scope],
          rows: search[:rows],
          hours: search[:hours],
        )
      end
      filter_options = timed_phase!(timing, :filter_options) do
        {
          severities: %w[all info success warning warning_or_danger danger],
          categories: ::MediaGallery::LogEvents.category_options,
          event_types: ::MediaGallery::LogEvents.event_type_options,
        }
      end
      timing[:total] = elapsed_ms_since(started_at)

      render_json_dump(
        events: events,
        summary: summary,
        filters: {
          q: params[:q].to_s,
          severity: params[:severity].to_s.presence || "all",
          category: params[:category].to_s.presence || "all",
          event_type: params[:event_type].to_s.presence || "all",
          hours: search[:hours].to_s,
          limit: search[:limit].to_s,
          sort: search[:sort],
        },
        filter_options: filter_options,
        error: search[:error].presence,
        timing_ms: timing[:total],
        timing_breakdown_ms: timing,
        show_performance_timings: admin_pages_show_performance_timings?,
      )
    rescue => e
      Rails.logger.warn("[media_gallery] admin logs index failed #{e.class}: #{e.message}")
      render_json_dump(
        events: [],
        summary: ::MediaGallery::LogEvents.summary(scope: nil, rows: [], hours: normalized_hours),
        filters: {
          q: params[:q].to_s,
          severity: params[:severity].to_s.presence || "all",
          category: params[:category].to_s.presence || "all",
          event_type: params[:event_type].to_s.presence || "all",
          hours: normalized_hours.to_s,
          limit: normalized_limit.to_s,
          sort: normalized_sort,
        },
        filter_options: {
          severities: %w[all info success warning warning_or_danger danger],
          categories: [],
          event_types: [],
        },
        error: "Unable to load logs. #{e.class}: #{e.message}",
      )
    end

    private

    def timed_phase!(timing, key)
      phase_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      timing[key] = elapsed_ms_since(phase_started) if timing && key && phase_started
    end

    def elapsed_ms_since(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    rescue
      0
    end

    def admin_pages_show_performance_timings?
      SiteSetting.respond_to?(:media_gallery_admin_pages_show_performance_timings) &&
        SiteSetting.media_gallery_admin_pages_show_performance_timings
    rescue
      false
    end

    def normalized_hours
      value = params[:hours].to_i
      return 168 if value <= 0

      [value, 24 * 90].min
    end

    def normalized_limit
      value = params[:limit].to_i
      return 25 if value <= 0

      [value, 250].min
    end

    def normalized_sort
      value = params[:sort].to_s.strip
      %w[created_at_desc created_at_asc].include?(value) ? value : "created_at_desc"
    end
  end
end
