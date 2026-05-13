# frozen_string_literal: true

module ::MediaGallery
  class AdminStatisticsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    PERIODS = {
      "day" => { sql: "day", label: "%Y-%m-%d", default_limit: 30, max_limit: 120 },
      "week" => { sql: "week", label: "%G-W%V", default_limit: 12, max_limit: 104 },
      "month" => { sql: "month", label: "%Y-%m", default_limit: 12, max_limit: 60 },
      "year" => { sql: "year", label: "%Y", default_limit: 5, max_limit: 15 },
    }.freeze

    MEDIA_REPORTS_KEY = "media_reports"

    def index
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timing = {}
      period = normalized_period
      limit = normalized_limit(period)
      since = period_since(period, limit)

      summary = timed_phase!(timing, :summary) { summary_payload }
      trends = timed_phase!(timing, :trends) { trends_payload(period, since, limit) }
      breakdowns = timed_phase!(timing, :breakdowns) { breakdowns_payload }
      top_content = timed_phase!(timing, :top_content) { top_content_payload }
      moderation = timed_phase!(timing, :moderation) { moderation_payload(period, since, limit) }
      quality = timed_phase!(timing, :quality) { quality_payload(period, since, limit) }
      period_summary = timed_phase!(timing, :period_summary) { period_summary_payload(period, since, limit) }
      contributors = timed_phase!(timing, :contributors) { contributors_payload(since) }
      watchlist = timed_phase!(timing, :watchlist) { watchlist_payload }
      content_profile = timed_phase!(timing, :content_profile) { content_profile_payload }
      engagement_quality = timed_phase!(timing, :engagement_quality) { engagement_quality_payload(since, summary) }
      delivery_integrity = timed_phase!(timing, :delivery_integrity) { delivery_integrity_payload(since) }
      content_curation = timed_phase!(timing, :content_curation) { content_curation_payload(since) }
      insights = timed_phase!(timing, :insights) { insights_payload(summary, moderation, quality, watchlist, engagement_quality, delivery_integrity, content_curation) }

      payload = {
        filters: {
          period: period,
          limit: limit,
          since: since&.utc&.iso8601,
        },
        summary: summary,
        trends: trends,
        breakdowns: breakdowns,
        top_content: top_content,
        moderation: moderation,
        quality: quality,
        period_summary: period_summary,
        contributors: contributors,
        watchlist: watchlist,
        content_profile: content_profile,
        engagement_quality: engagement_quality,
        delivery_integrity: delivery_integrity,
        content_curation: content_curation,
        insights: insights,
        generated_at: Time.zone.now.utc.iso8601,
        notes: analytics_notes,
      }

      timing[:total] = elapsed_ms_since(started_at)
      payload[:timing_ms] = timing[:total]
      payload[:timing_breakdown_ms] = timing
      payload[:show_performance_timings] = admin_pages_show_performance_timings?

      render_json_dump(payload)
    rescue => e
      Rails.logger.warn("[media_gallery] admin statistics index failed request_id=#{request.request_id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
      render_json_dump(
        filters: { period: normalized_period, limit: normalized_limit(normalized_period) },
        summary: empty_summary,
        trends: empty_trends,
        breakdowns: empty_breakdowns,
        top_content: [],
        moderation: empty_moderation,
        quality: empty_quality,
        period_summary: empty_period_summary,
        contributors: empty_contributors,
        watchlist: empty_watchlist,
        content_profile: empty_content_profile,
        engagement_quality: empty_engagement_quality,
        delivery_integrity: empty_delivery_integrity,
        content_curation: empty_content_curation,
        insights: [],
        generated_at: Time.zone.now.utc.iso8601,
        notes: analytics_notes,
        error: "Unable to load statistics. #{e.class}: #{e.message}"
      )
    end

    private

    def summary_payload
      items_scope = media_item_scope
      ready_scope = items_scope.where(status: "ready")
      failed_scope = items_scope.where(status: "failed")
      active_processing_scope = items_scope.where(status: %w[queued processing])

      playback_scope = playback_session_scope
      media_reports = media_report_stats
      comment_reports = comment_report_stats

      {
        total_items: safe_count(items_scope),
        ready_items: safe_count(ready_scope),
        failed_items: safe_count(failed_scope),
        queued_or_processing_items: safe_count(active_processing_scope),
        unique_uploaders: safe_distinct_count(items_scope, :user_id),
        total_views: safe_sum(items_scope, :views_count),
        playback_sessions: safe_count(playback_scope),
        unique_viewers: safe_distinct_count(playback_scope, :user_id),
        media_likes: safe_count(media_like_scope),
        comment_count: safe_count(media_comment_scope),
        comment_likes: safe_count(media_comment_like_scope),
        total_reports: media_reports[:total] + comment_reports[:total],
        open_reports: media_reports[:open] + comment_reports[:open],
        media_reports: media_reports[:total],
        comment_reports: comment_reports[:total],
        storage_original_bytes: safe_sum(items_scope, :filesize_original_bytes),
        storage_processed_bytes: safe_sum(items_scope, :filesize_processed_bytes),
        latest_upload_at: max_time(items_scope, :created_at),
        latest_playback_at: max_time(playback_scope, playback_timestamp_column),
      }
    end

    def trends_payload(period, since, limit)
      {
        uploads: normalize_series(grouped_count(media_item_scope, :created_at, period, since), period, since, limit),
        playbacks: normalize_series(grouped_count(playback_session_scope, playback_timestamp_column, period, since), period, since, limit),
        likes: normalize_series(grouped_count(media_like_scope, :created_at, period, since), period, since, limit),
        comments: normalize_series(grouped_count(media_comment_scope, :created_at, period, since), period, since, limit),
        comment_likes: normalize_series(grouped_count(media_comment_like_scope, :created_at, period, since), period, since, limit),
        log_events: normalize_series(grouped_count(media_log_event_scope, :created_at, period, since), period, since, limit),
      }
    end

    def breakdowns_payload
      {
        by_status: to_name_count_rows(safe_group_count(media_item_scope, :status)),
        by_type: to_name_count_rows(safe_group_count(media_item_scope, :media_type)),
        by_gender: to_name_count_rows(safe_group_count(media_item_scope, :gender)),
        by_storage_backend: to_name_count_rows(safe_group_count(media_item_scope, :managed_storage_backend)),
        by_delivery_mode: to_name_count_rows(safe_group_count(media_item_scope, :delivery_mode)),
        log_severities: to_name_count_rows(safe_group_count(media_log_event_scope, :severity)),
        log_categories: to_name_count_rows(safe_group_count(media_log_event_scope, :category)),
      }
    end

    def top_content_payload
      base = media_item_scope.includes(:user)
      playback_counts = top_group_counts(playback_session_scope, :media_item_id, 25)

      rows = base
        .order(Arel.sql(top_content_order_sql))
        .limit(20)
        .to_a

      rows.map do |item|
        {
          public_id: item.public_id,
          title: item.title,
          status: item.status,
          media_type: item.media_type,
          uploader: item.user&.username,
          views_count: item.views_count.to_i,
          likes_count: item.likes_count.to_i,
          comments_count: item.respond_to?(:comments_count) ? item.comments_count.to_i : 0,
          playback_sessions: playback_counts[item.id].to_i,
          reports_count: media_reports_for_item(item).length + comment_reports_for_item(item.id),
          created_at: item.created_at&.utc&.iso8601,
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics top content failed #{e.class}: #{e.message}")
      []
    end


    def top_content_order_sql
      table = ::MediaGallery::MediaItem.table_name
      parts = []
      parts << "COALESCE(views_count, 0) DESC" if column_available?(table, :views_count)
      parts << "COALESCE(likes_count, 0) DESC" if column_available?(table, :likes_count)
      parts << "COALESCE(comments_count, 0) DESC" if column_available?(table, :comments_count)
      parts << "created_at DESC"
      parts.join(", ")
    end

    def period_summary_payload(period, since, limit)
      bounds = period_summary_bounds(period, since, limit)
      current = window_metrics(bounds[:current_from], bounds[:current_to])
      previous = window_metrics(bounds[:previous_from], bounds[:previous_to])

      {
        current: current,
        previous: previous,
        delta: window_delta(current, previous),
        labels: {
          current: window_label(bounds[:current_from], bounds[:current_to]),
          previous: window_label(bounds[:previous_from], bounds[:previous_to]),
        },
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics period summary failed #{e.class}: #{e.message}")
      empty_period_summary
    end

    def contributors_payload(since)
      {
        top_uploaders: top_uploaders_payload(since),
        top_viewers: top_viewers_payload(since),
        top_commenters: top_commenters_payload(since),
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics contributors failed #{e.class}: #{e.message}")
      empty_contributors
    end

    def watchlist_payload
      {
        recent_failures: recent_failures_payload,
        processing_queue: processing_queue_payload,
        most_reported_media: most_reported_media_payload,
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics watchlist failed #{e.class}: #{e.message}")
      empty_watchlist
    end

    def insights_payload(summary, moderation, quality, watchlist, engagement_quality = nil, delivery_integrity = nil, content_curation = nil)
      rows = []
      open_reports = summary[:open_reports].to_i
      failed_items = summary[:failed_items].to_i
      queued_or_processing = summary[:queued_or_processing_items].to_i
      recent_failures = Array(watchlist[:recent_failures]).length
      reported_items = Array(watchlist[:most_reported_media]).length
      success_rate = quality[:processing_success_rate_percent]

      if open_reports.positive?
        rows << insight_row(
          "warning",
          "Open reports need review",
          "#{open_reports} open report#{'s' if open_reports != 1} across media and comments.",
          "Open the reports page and review the oldest/highest-risk reports first."
        )
      end

      if failed_items.positive?
        rows << insight_row(
          "warning",
          "Failed processing items present",
          "#{failed_items} failed item#{'s' if failed_items != 1} detected; #{recent_failures} shown in the recent failure watchlist.",
          "Check the error message and retry or remove failed items where appropriate."
        )
      end

      if queued_or_processing.positive?
        rows << insight_row(
          "info",
          "Processing queue is active",
          "#{queued_or_processing} item#{'s' if queued_or_processing != 1} currently queued or processing.",
          "If this number stays high, verify background jobs and storage/FFmpeg health."
        )
      end

      if success_rate.present? && success_rate.to_f < 95.0
        rows << insight_row(
          "info",
          "Processing success rate below target",
          "Current all-time processing success is #{success_rate}%.",
          "Use the recent failures and health pages to look for recurring formats or storage errors."
        )
      end

      if reported_items.positive?
        rows << insight_row(
          "info",
          "Reported content watchlist available",
          "#{reported_items} item#{'s' if reported_items != 1} with report activity are listed below.",
          "Prioritize content with open reports or repeated reports from different users."
        )
      end

      quiet_ready_count = Array(content_curation&.dig(:quiet_ready_media)).length
      if quiet_ready_count.positive?
        rows << insight_row(
          "info",
          "Quiet ready media detected",
          "#{quiet_ready_count} ready item#{'s' if quiet_ready_count != 1} with little or no engagement are listed for curation review.",
          "Consider featuring, retagging, renaming or archiving content that consistently gets no activity."
        )
      end

      missing_receipts = Array(delivery_integrity&.dig(:missing_delivery_receipts)).length
      if missing_receipts.positive?
        rows << insight_row(
          "warning",
          "Playback delivery receipts incomplete",
          "#{missing_receipts} recent playback session#{'s' if missing_receipts != 1} are missing one or more HLS delivery receipt fields.",
          "Check whether older playback records are expected, or investigate HLS delivery logging if this persists for new sessions."
        )
      end

      report_pressure = engagement_quality&.dig(:rates, :reports_per_1000_views).to_f
      if report_pressure.positive? && report_pressure >= 10.0
        rows << insight_row(
          "warning",
          "High report pressure",
          "Reports per 1,000 views is currently #{report_pressure.round(1)}.",
          "Review reported media and comment report patterns to distinguish real content issues from false-report behavior."
        )
      end

      rows.presence || [
        insight_row(
          "success",
          "No immediate analytics attention required",
          "No open reports, failed items or active queue pressure detected in the current snapshot.",
          "Keep monitoring trends after busy upload periods."
        ),
      ]
    rescue => e
      Rails.logger.warn("[media_gallery] statistics insights failed #{e.class}: #{e.message}")
      []
    end

    def moderation_payload(period, since, limit)
      media_reports = media_report_stats
      comment_reports = comment_report_stats

      {
        totals: {
          media: media_reports,
          comments: comment_reports,
          combined: {
            total: media_reports[:total] + comment_reports[:total],
            open: media_reports[:open] + comment_reports[:open],
            accepted: media_reports[:accepted] + comment_reports[:accepted],
            rejected: media_reports[:rejected] + comment_reports[:rejected],
            resolved: media_reports[:resolved] + comment_reports[:resolved],
          },
        },
        report_trend: normalize_series(comment_report_trend(period, since), period, since, limit),
        false_report_ratio_percent: false_report_ratio_percent(media_reports, comment_reports),
      }
    end

    def quality_payload(period, since, limit)
      items = media_item_scope
      ready_count = safe_count(items.where(status: "ready"))
      failed_count = safe_count(items.where(status: "failed"))
      queued_count = safe_count(items.where(status: "queued"))
      processing_count = safe_count(items.where(status: "processing"))
      total_count = safe_count(items)
      completed_count = ready_count + failed_count
      processed_bytes = safe_sum(items, :filesize_processed_bytes)
      original_bytes = safe_sum(items, :filesize_original_bytes)

      {
        processing_success_rate_percent: completed_count.positive? ? ((ready_count.to_f / completed_count) * 100).round(1) : nil,
        ready_share_percent: total_count.positive? ? ((ready_count.to_f / total_count) * 100).round(1) : nil,
        failed_share_percent: total_count.positive? ? ((failed_count.to_f / total_count) * 100).round(1) : nil,
        queued_count: queued_count,
        processing_count: processing_count,
        failed_count: failed_count,
        ready_count: ready_count,
        byte_reduction_percent: original_bytes.positive? ? (((original_bytes - processed_bytes).to_f / original_bytes) * 100).round(1) : nil,
        status_trend: normalize_status_series(period, since, limit),
      }
    end

    def empty_summary
      {
        total_items: 0,
        ready_items: 0,
        failed_items: 0,
        queued_or_processing_items: 0,
        unique_uploaders: 0,
        total_views: 0,
        playback_sessions: 0,
        unique_viewers: 0,
        media_likes: 0,
        comment_count: 0,
        comment_likes: 0,
        total_reports: 0,
        open_reports: 0,
        storage_original_bytes: 0,
        storage_processed_bytes: 0,
      }
    end

    def empty_trends
      { uploads: [], playbacks: [], likes: [], comments: [], comment_likes: [], log_events: [] }
    end

    def empty_breakdowns
      { by_status: [], by_type: [], by_gender: [], by_storage_backend: [], by_delivery_mode: [], log_severities: [], log_categories: [] }
    end

    def empty_moderation
      {
        totals: {
          media: base_report_stats,
          comments: base_report_stats,
          combined: base_report_stats,
        },
        report_trend: [],
        false_report_ratio_percent: nil,
      }
    end

    def empty_quality
      {
        processing_success_rate_percent: nil,
        ready_share_percent: nil,
        failed_share_percent: nil,
        queued_count: 0,
        processing_count: 0,
        failed_count: 0,
        ready_count: 0,
        byte_reduction_percent: nil,
        status_trend: [],
      }
    end

    def empty_period_summary
      {
        current: empty_window_metrics,
        previous: empty_window_metrics,
        delta: {},
        labels: { current: nil, previous: nil },
      }
    end

    def empty_window_metrics
      {
        uploads: 0,
        ready_uploads: 0,
        failed_uploads: 0,
        playbacks: 0,
        unique_viewers: 0,
        media_likes: 0,
        comments: 0,
        comment_likes: 0,
        reports: 0,
        log_events: 0,
        processed_storage_added_bytes: 0,
        engagement_total: 0,
      }
    end

    def empty_contributors
      { top_uploaders: [], top_viewers: [], top_commenters: [] }
    end

    def empty_watchlist
      { recent_failures: [], processing_queue: [], most_reported_media: [] }
    end

    def empty_content_profile
      {
        duration_buckets: [],
        processed_size_buckets: [],
        resolution_buckets: [],
        tag_usage: [],
        visibility: [],
        hls_catalog: [],
      }
    end

    def empty_engagement_quality
      { rates: {}, rising_content: [] }
    end

    def empty_delivery_integrity
      { receipt_summary: {}, hls_variants: [], missing_delivery_receipts: [] }
    end

    def empty_content_curation
      { quiet_ready_media: [], stale_ready_media: [] }
    end

    def analytics_notes
      [
        "This statistics dashboard is read-only and uses existing Media Gallery tables and metadata.",
        "Upload, like, comment, playback and log trends are grouped by the selected time unit.",
        "Iteration 2 adds period comparison, contributor leaderboards, recent failure watchlists and actionable admin insights without adding migrations.",
        "Iterations 3 and 4 add content profile, engagement quality, delivery integrity and curation watchlists using existing records only.",
        "Media report history is stored in item metadata; report timestamps are parsed where available, while comment reports use their own table timestamps.",
      ]
    end

    def media_item_scope
      ::MediaGallery::MediaItem.all
    rescue
      ::MediaGallery::MediaItem.none
    end

    def media_like_scope
      table_available?("media_gallery_media_likes") ? ::MediaGallery::MediaLike.all : empty_relation(::MediaGallery::MediaLike)
    end

    def media_comment_scope
      table_available?("media_gallery_media_comments") ? ::MediaGallery::MediaComment.all : empty_relation(::MediaGallery::MediaComment)
    end

    def media_comment_like_scope
      table_available?("media_gallery_media_comment_likes") ? ::MediaGallery::MediaCommentLike.all : empty_relation(::MediaGallery::MediaCommentLike)
    end

    def media_comment_report_scope
      table_available?("media_gallery_media_comment_reports") ? ::MediaGallery::MediaCommentReport.all : empty_relation(::MediaGallery::MediaCommentReport)
    end

    def playback_session_scope
      table_available?("media_gallery_playback_sessions") ? ::MediaGallery::MediaPlaybackSession.all : empty_relation(::MediaGallery::MediaPlaybackSession)
    end

    def media_log_event_scope
      table_available?("media_gallery_log_events") ? ::MediaGallery::MediaLogEvent.all : empty_relation(::MediaGallery::MediaLogEvent)
    end

    def empty_relation(model_class)
      model_class.none
    rescue
      ::MediaGallery::MediaItem.none
    end

    def table_available?(name)
      ::ActiveRecord::Base.connection.data_source_exists?(name)
    rescue
      false
    end

    def column_available?(table_name, column_name)
      ::ActiveRecord::Base.connection.column_exists?(table_name, column_name)
    rescue
      false
    end

    def playback_timestamp_column
      column_available?("media_gallery_playback_sessions", :played_at) ? :played_at : :created_at
    end

    def grouped_count(scope, timestamp_column, period, since)
      return {} if scope.nil? || since.blank?

      table = scope.klass.table_name
      return {} unless column_available?(table, timestamp_column)

      sql_period = PERIODS.fetch(period)[:sql]
      expression = "DATE_TRUNC('#{sql_period}', #{table}.#{timestamp_column})"
      scope
        .where("#{table}.#{timestamp_column} >= ?", since)
        .where.not(timestamp_column => nil)
        .group(Arel.sql(expression))
        .order(Arel.sql(expression))
        .count
    rescue => e
      Rails.logger.warn("[media_gallery] statistics grouped count failed table=#{scope&.klass&.table_name} column=#{timestamp_column} #{e.class}: #{e.message}")
      {}
    end

    def normalize_series(counts, period, since, limit)
      bucket_starts = expected_bucket_starts(period, since, limit)
      counts_by_key = {}

      counts.each do |bucket, count|
        next if bucket.blank?

        key = bucket_key(bucket, period)
        counts_by_key[key] = count.to_i
      end

      bucket_starts.map do |bucket_start|
        key = bucket_key(bucket_start, period)
        {
          key: key,
          label: bucket_label(bucket_start, period),
          count: counts_by_key[key].to_i,
          started_at: bucket_start.utc.iso8601,
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics normalize series failed #{e.class}: #{e.message}")
      []
    end

    def normalize_status_series(period, since, limit)
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, :created_at) && column_available?(table, :status)

      sql_period = PERIODS.fetch(period)[:sql]
      expression = "DATE_TRUNC('#{sql_period}', #{table}.created_at)"
      counts = media_item_scope
        .where("#{table}.created_at >= ?", since)
        .group(Arel.sql(expression), :status)
        .count

      buckets = expected_bucket_starts(period, since, limit).map do |bucket_start|
        key = bucket_key(bucket_start, period)
        row = {
          key: key,
          label: bucket_label(bucket_start, period),
          started_at: bucket_start.utc.iso8601,
          queued: 0,
          processing: 0,
          ready: 0,
          failed: 0,
        }

        counts.each do |(bucket, status), count|
          next unless bucket_key(bucket, period) == key

          normalized_status = status.to_s.presence || "unknown"
          row[normalized_status.to_sym] = count.to_i if row.key?(normalized_status.to_sym)
        end

        row
      end

      buckets
    rescue => e
      Rails.logger.warn("[media_gallery] statistics status series failed #{e.class}: #{e.message}")
      []
    end

    def expected_bucket_starts(period, since, limit)
      current = truncate_time(Time.zone.now, period)
      starts = []
      (limit - 1).downto(0) do |offset|
        starts << shift_period(current, period, -offset)
      end
      starts.select { |start| since.blank? || start >= truncate_time(since, period) }
    end

    def truncate_time(value, period)
      time = value.in_time_zone
      case period
      when "year"
        time.beginning_of_year
      when "month"
        time.beginning_of_month
      when "week"
        time.beginning_of_week
      else
        time.beginning_of_day
      end
    end

    def shift_period(time, period, amount)
      case period
      when "year"
        time + amount.years
      when "month"
        time + amount.months
      when "week"
        time + amount.weeks
      else
        time + amount.days
      end
    end

    def bucket_key(value, period)
      bucket = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
      truncate_time(bucket, period).strftime(PERIODS.fetch(period)[:label])
    rescue
      value.to_s
    end

    def bucket_label(value, period)
      time = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
      case period
      when "year"
        time.strftime("%Y")
      when "month"
        time.strftime("%b %Y")
      when "week"
        "Week #{time.strftime("%V")} #{time.strftime("%G")}"
      else
        time.strftime("%b %-d")
      end
    rescue
      value.to_s
    end

    def period_summary_bounds(period, since, limit)
      current_from = since || period_since(period, limit)
      current_to = Time.zone.now
      previous_to = current_from
      previous_from = shift_period(current_from, period, -limit)

      {
        current_from: current_from,
        current_to: current_to,
        previous_from: previous_from,
        previous_to: previous_to,
      }
    end

    def window_metrics(from_time, to_time)
      report_stats = report_stats_for_window(from_time, to_time)
      likes = time_window_count(media_like_scope, :created_at, from_time, to_time)
      comments = time_window_count(media_comment_scope, :created_at, from_time, to_time)
      comment_likes = time_window_count(media_comment_like_scope, :created_at, from_time, to_time)

      {
        uploads: time_window_count(media_item_scope, :created_at, from_time, to_time),
        ready_uploads: time_window_count(media_item_scope.where(status: "ready"), :created_at, from_time, to_time),
        failed_uploads: time_window_count(media_item_scope.where(status: "failed"), :created_at, from_time, to_time),
        playbacks: time_window_count(playback_session_scope, playback_timestamp_column, from_time, to_time),
        unique_viewers: time_window_distinct_count(playback_session_scope, :user_id, playback_timestamp_column, from_time, to_time),
        media_likes: likes,
        comments: comments,
        comment_likes: comment_likes,
        reports: report_stats[:total].to_i,
        log_events: time_window_count(media_log_event_scope, :created_at, from_time, to_time),
        processed_storage_added_bytes: time_window_sum(media_item_scope, :filesize_processed_bytes, :created_at, from_time, to_time),
        engagement_total: likes + comments + comment_likes,
      }
    end

    def window_delta(current, previous)
      keys = (current.keys + previous.keys).uniq
      keys.each_with_object({}) do |key, memo|
        current_value = current[key].to_i
        previous_value = previous[key].to_i
        difference = current_value - previous_value
        memo[key] = {
          current: current_value,
          previous: previous_value,
          difference: difference,
          percent_change: percent_change(current_value, previous_value),
          direction: difference.positive? ? "up" : (difference.negative? ? "down" : "flat"),
        }
      end
    rescue
      {}
    end

    def percent_change(current_value, previous_value)
      return nil if previous_value.to_i.zero?

      (((current_value.to_f - previous_value.to_f) / previous_value.to_f) * 100).round(1)
    end

    def report_stats_for_window(from_time, to_time)
      stats = { total: 0, media: 0, comments: 0 }

      each_media_report do |report|
        created_at = parse_report_time(report["created_at"])
        next if created_at.blank? || created_at < from_time || created_at >= to_time

        stats[:total] += 1
        stats[:media] += 1
      end

      comment_scope = time_window_scope(media_comment_report_scope, :created_at, from_time, to_time)
      comment_count = safe_count(comment_scope)
      stats[:total] += comment_count
      stats[:comments] += comment_count
      stats
    rescue => e
      Rails.logger.warn("[media_gallery] statistics report window failed #{e.class}: #{e.message}")
      { total: 0, media: 0, comments: 0 }
    end

    def top_uploaders_payload(since)
      scope = time_window_scope(media_item_scope, :created_at, since, nil)
      counts = top_group_counts(scope, :user_id, 10)
      ids = counts.keys.compact
      usernames = usernames_by_id(ids)
      ready_counts = safe_group_count(scope.where(status: "ready"), :user_id)
      failed_counts = safe_group_count(scope.where(status: "failed"), :user_id)
      view_sums = safe_group_sum(scope, :user_id, :views_count)
      storage_sums = safe_group_sum(scope, :user_id, :filesize_processed_bytes)
      latest_uploads = safe_group_max(scope, :user_id, :created_at)

      counts.map do |user_id, count|
        {
          user_id: user_id,
          username: usernames[user_id] || "user ##{user_id}",
          uploads: count.to_i,
          ready: ready_counts[user_id].to_i,
          failed: failed_counts[user_id].to_i,
          views: view_sums[user_id].to_i,
          processed_storage_bytes: storage_sums[user_id].to_i,
          latest_upload_at: latest_uploads[user_id]&.utc&.iso8601,
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics top uploaders failed #{e.class}: #{e.message}")
      []
    end

    def top_viewers_payload(since)
      timestamp_column = playback_timestamp_column
      scope = time_window_scope(playback_session_scope, timestamp_column, since, nil)
      counts = top_group_counts(scope, :user_id, 10)
      ids = counts.keys.compact
      usernames = usernames_by_id(ids)
      media_counts = safe_group_distinct_count(scope, :user_id, :media_item_id)
      latest_playbacks = safe_group_max(scope, :user_id, timestamp_column)

      counts.map do |user_id, count|
        {
          user_id: user_id,
          username: usernames[user_id] || "user ##{user_id}",
          playbacks: count.to_i,
          unique_media: media_counts[user_id].to_i,
          latest_playback_at: latest_playbacks[user_id]&.utc&.iso8601,
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics top viewers failed #{e.class}: #{e.message}")
      []
    end

    def top_commenters_payload(since)
      scope = time_window_scope(media_comment_scope, :created_at, since, nil)
      counts = top_group_counts(scope, :user_id, 10)
      ids = counts.keys.compact
      usernames = usernames_by_id(ids)
      media_counts = safe_group_distinct_count(scope, :user_id, :media_item_id)
      latest_comments = safe_group_max(scope, :user_id, :created_at)

      counts.map do |user_id, count|
        {
          user_id: user_id,
          username: usernames[user_id] || "user ##{user_id}",
          comments: count.to_i,
          unique_media: media_counts[user_id].to_i,
          latest_comment_at: latest_comments[user_id]&.utc&.iso8601,
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics top commenters failed #{e.class}: #{e.message}")
      []
    end

    def recent_failures_payload
      media_item_scope
        .includes(:user)
        .where(status: "failed")
        .order(updated_at: :desc)
        .limit(10)
        .map do |item|
          {
            public_id: item.public_id,
            title: item.title,
            uploader: item.user&.username,
            media_type: item.media_type,
            error_message: item.error_message.to_s.truncate(220),
            updated_at: item.updated_at&.utc&.iso8601,
            created_at: item.created_at&.utc&.iso8601,
          }
        end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics recent failures failed #{e.class}: #{e.message}")
      []
    end

    def processing_queue_payload
      media_item_scope
        .includes(:user)
        .where(status: %w[queued processing])
        .order(updated_at: :asc)
        .limit(10)
        .map do |item|
          {
            public_id: item.public_id,
            title: item.title,
            uploader: item.user&.username,
            media_type: item.media_type,
            status: item.status,
            updated_at: item.updated_at&.utc&.iso8601,
            created_at: item.created_at&.utc&.iso8601,
          }
        end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics processing queue failed #{e.class}: #{e.message}")
      []
    end

    def most_reported_media_payload
      counts = Hash.new { |hash, key| hash[key] = { total: 0, open: 0, media: 0, comments: 0 } }

      each_media_report do |report, item|
        item_id = item&.id
        next if item_id.blank?

        status = normalized_report_status(report["status"])
        counts[item_id][:total] += 1
        counts[item_id][:media] += 1
        counts[item_id][:open] += 1 if status == :open
      end

      media_comment_report_scope.group(:media_item_id, :status).count.each do |(item_id, status), count|
        next if item_id.blank?

        normalized = normalized_report_status(status)
        counts[item_id][:total] += count.to_i
        counts[item_id][:comments] += count.to_i
        counts[item_id][:open] += count.to_i if normalized == :open
      end

      top_ids = counts.sort_by { |_id, row| [-row[:open].to_i, -row[:total].to_i] }.first(10).map(&:first)
      items_by_id = media_item_scope.includes(:user).where(id: top_ids).index_by(&:id)

      top_ids.map do |item_id|
        item = items_by_id[item_id]
        row = counts[item_id]
        next if item.blank?

        {
          public_id: item.public_id,
          title: item.title,
          uploader: item.user&.username,
          media_type: item.media_type,
          status: item.status,
          total_reports: row[:total].to_i,
          open_reports: row[:open].to_i,
          media_reports: row[:media].to_i,
          comment_reports: row[:comments].to_i,
          created_at: item.created_at&.utc&.iso8601,
        }
      end.compact
    rescue => e
      Rails.logger.warn("[media_gallery] statistics most reported media failed #{e.class}: #{e.message}")
      []
    end

    def content_profile_payload
      {
        duration_buckets: duration_bucket_rows,
        processed_size_buckets: processed_size_bucket_rows,
        resolution_buckets: resolution_bucket_rows,
        tag_usage: tag_usage_rows,
        visibility: admin_visibility_rows,
        hls_catalog: hls_catalog_rows,
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics content profile failed #{e.class}: #{e.message}")
      empty_content_profile
    end

    def engagement_quality_payload(since, summary = nil)
      summary ||= summary_payload
      total_items = summary[:total_items].to_i
      ready_items = summary[:ready_items].to_i
      views = summary[:total_views].to_i
      playbacks = summary[:playback_sessions].to_i
      likes = summary[:media_likes].to_i
      comments = summary[:comment_count].to_i
      reports = summary[:total_reports].to_i

      {
        rates: {
          views_per_item: safe_ratio(views, total_items, 2),
          playbacks_per_ready_item: safe_ratio(playbacks, ready_items, 2),
          likes_per_100_views: safe_ratio(likes * 100, views, 1),
          comments_per_100_views: safe_ratio(comments * 100, views, 1),
          reports_per_1000_views: safe_ratio(reports * 1000, views, 1),
          engagement_per_ready_item: safe_ratio(likes + comments, ready_items, 2),
        },
        rising_content: rising_content_payload(since),
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics engagement quality failed #{e.class}: #{e.message}")
      empty_engagement_quality
    end

    def delivery_integrity_payload(since)
      playback_scope = time_window_scope(playback_session_scope, playback_timestamp_column, since, nil)
      total_playbacks = safe_count(playback_scope)
      with_signature = column_available?(playback_scope.klass.table_name, :hls_delivery_signature) ? safe_count(playback_scope.where.not(hls_delivery_signature: [nil, ""])) : 0
      with_manifest = column_available?(playback_scope.klass.table_name, :hls_manifest_sha256) ? safe_count(playback_scope.where.not(hls_manifest_sha256: [nil, ""])) : 0
      with_sequence = column_available?(playback_scope.klass.table_name, :hls_variant_sequence_sha256) ? safe_count(playback_scope.where.not(hls_variant_sequence_sha256: [nil, ""])) : 0
      average_sequence_length = column_available?(playback_scope.klass.table_name, :hls_variant_sequence_length) ? playback_scope.average(:hls_variant_sequence_length)&.to_f&.round(1) : nil

      {
        receipt_summary: {
          total_playbacks: total_playbacks,
          with_delivery_signature: with_signature,
          with_manifest_sha: with_manifest,
          with_variant_sequence: with_sequence,
          signature_coverage_percent: total_playbacks.positive? ? ((with_signature.to_f / total_playbacks) * 100).round(1) : nil,
          manifest_coverage_percent: total_playbacks.positive? ? ((with_manifest.to_f / total_playbacks) * 100).round(1) : nil,
          sequence_coverage_percent: total_playbacks.positive? ? ((with_sequence.to_f / total_playbacks) * 100).round(1) : nil,
          average_variant_sequence_length: average_sequence_length,
        },
        hls_variants: hls_variant_rows(playback_scope),
        missing_delivery_receipts: missing_delivery_receipts_payload(playback_scope),
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics delivery integrity failed #{e.class}: #{e.message}")
      empty_delivery_integrity
    end

    def content_curation_payload(since)
      {
        quiet_ready_media: quiet_ready_media_payload(since),
        stale_ready_media: stale_ready_media_payload,
      }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics content curation failed #{e.class}: #{e.message}")
      empty_content_curation
    end

    def duration_bucket_rows
      buckets = [
        ["unknown", "Unknown", nil, nil],
        ["under_1_min", "Under 1 min", 0, 60],
        ["1_to_5_min", "1–5 min", 60, 300],
        ["5_to_15_min", "5–15 min", 300, 900],
        ["15_to_30_min", "15–30 min", 900, 1800],
        ["over_30_min", "Over 30 min", 1800, nil],
      ]
      bucket_count_rows(:duration_seconds, buckets)
    end

    def processed_size_bucket_rows
      buckets = [
        ["unknown", "Unknown", nil, nil],
        ["under_10_mb", "Under 10 MB", 0, 10.megabytes],
        ["10_to_50_mb", "10–50 MB", 10.megabytes, 50.megabytes],
        ["50_to_200_mb", "50–200 MB", 50.megabytes, 200.megabytes],
        ["200_mb_to_1_gb", "200 MB–1 GB", 200.megabytes, 1.gigabyte],
        ["over_1_gb", "Over 1 GB", 1.gigabyte, nil],
      ]
      bucket_count_rows(:filesize_processed_bytes, buckets)
    end

    def bucket_count_rows(column, buckets)
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, column)

      buckets.map do |key, label, min, max|
        scope = media_item_scope
        if key == "unknown"
          scope = scope.where(column => nil)
        else
          scope = scope.where("#{table}.#{column} >= ?", min) if min.present?
          scope = scope.where("#{table}.#{column} < ?", max) if max.present?
        end
        { name: key, label: label, count: safe_count(scope) }
      end.select { |row| row[:count].positive? }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics bucket count failed column=#{column} #{e.class}: #{e.message}")
      []
    end

    def resolution_bucket_rows
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, :width) && column_available?(table, :height)

      scopes = {
        unknown: media_item_scope.where("#{table}.width IS NULL OR #{table}.height IS NULL"),
        vertical: media_item_scope.where("#{table}.width IS NOT NULL AND #{table}.height IS NOT NULL AND #{table}.height > #{table}.width"),
        square: media_item_scope.where("#{table}.width IS NOT NULL AND #{table}.height IS NOT NULL AND #{table}.width = #{table}.height"),
        landscape: media_item_scope.where("#{table}.width IS NOT NULL AND #{table}.height IS NOT NULL AND #{table}.width > #{table}.height"),
        hd_or_larger: media_item_scope.where("#{table}.width >= 1280 OR #{table}.height >= 720"),
        full_hd_or_larger: media_item_scope.where("#{table}.width >= 1920 OR #{table}.height >= 1080"),
      }

      scopes.map do |key, scope|
        { name: key.to_s, label: humanize_token(key), count: safe_count(scope) }
      end.select { |row| row[:count].positive? }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics resolution buckets failed #{e.class}: #{e.message}")
      []
    end

    def tag_usage_rows
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, :tags)

      sql = <<~SQL
        SELECT tag, COUNT(*) AS count
        FROM #{table}, LATERAL unnest(#{table}.tags) AS tag
        WHERE tag IS NOT NULL AND tag <> ''
        GROUP BY tag
        ORDER BY count DESC, tag ASC
        LIMIT 20
      SQL

      ::ActiveRecord::Base.connection.exec_query(sql).map do |row|
        { name: row["tag"].to_s, label: row["tag"].to_s, count: row["count"].to_i }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics tag usage failed #{e.class}: #{e.message}")
      []
    end

    def admin_visibility_rows
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, :extra_metadata)

      hidden = safe_count(media_item_scope.where("COALESCE((#{table}.extra_metadata -> 'admin_visibility' ->> 'hidden')::boolean, false) = true"))
      visible = [safe_count(media_item_scope) - hidden, 0].max
      [
        { name: "visible", label: "Visible", count: visible },
        { name: "admin_hidden", label: "Admin hidden", count: hidden },
      ].select { |row| row[:count].positive? }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics admin visibility failed #{e.class}: #{e.message}")
      []
    end

    def hls_catalog_rows
      table = ::MediaGallery::MediaItem.table_name
      return [] unless column_available?(table, :storage_manifest)

      hls_scope = media_item_scope.where("#{table}.storage_manifest -> 'roles' -> 'hls' IS NOT NULL")
      aes_scope = hls_scope.where("#{table}.storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NOT NULL")
      clear_hls_scope = hls_scope.where("#{table}.storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NULL")
      no_hls_scope = media_item_scope.where("#{table}.storage_manifest -> 'roles' -> 'hls' IS NULL")

      [
        { name: "hls_ready", label: "HLS ready", count: safe_count(hls_scope) },
        { name: "aes_hls", label: "AES protected HLS", count: safe_count(aes_scope) },
        { name: "clear_hls", label: "Clear HLS", count: safe_count(clear_hls_scope) },
        { name: "no_hls", label: "No HLS role", count: safe_count(no_hls_scope) },
      ].select { |row| row[:count].positive? }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics hls catalog failed #{e.class}: #{e.message}")
      []
    end

    def rising_content_payload(since)
      timestamp_column = playback_timestamp_column
      play_scope = time_window_scope(playback_session_scope, timestamp_column, since, nil)
      play_counts = top_group_counts(play_scope, :media_item_id, 15)
      like_counts = safe_group_count(time_window_scope(media_like_scope, :created_at, since, nil), :media_item_id)
      comment_counts = safe_group_count(time_window_scope(media_comment_scope, :created_at, since, nil), :media_item_id)

      ids = (play_counts.keys + like_counts.keys + comment_counts.keys).compact.uniq
      items = media_item_scope.includes(:user).where(id: ids).index_by(&:id)
      ranked = ids.map do |id|
        item = items[id]
        next if item.blank?

        plays = play_counts[id].to_i
        likes = like_counts[id].to_i
        comments = comment_counts[id].to_i
        score = plays + (likes * 3) + (comments * 4)
        next if score <= 0

        {
          public_id: item.public_id,
          title: item.title,
          uploader: item.user&.username,
          media_type: item.media_type,
          status: item.status,
          playbacks: plays,
          likes: likes,
          comments: comments,
          score: score,
          created_at: item.created_at&.utc&.iso8601,
        }
      end.compact

      ranked.sort_by { |row| [-row[:score].to_i, -row[:playbacks].to_i, row[:title].to_s] }.first(10)
    rescue => e
      Rails.logger.warn("[media_gallery] statistics rising content failed #{e.class}: #{e.message}")
      []
    end

    def hls_variant_rows(scope)
      return [] unless column_available?(scope.klass.table_name, :hls_variant)

      to_name_count_rows(safe_group_count(scope, :hls_variant)).first(12)
    rescue => e
      Rails.logger.warn("[media_gallery] statistics hls variants failed #{e.class}: #{e.message}")
      []
    end

    def missing_delivery_receipts_payload(scope)
      table = scope.klass.table_name
      return [] unless column_available?(table, :hls_delivery_signature) || column_available?(table, :hls_manifest_sha256) || column_available?(table, :hls_variant_sequence_sha256)

      conditions = []
      conditions << "#{table}.hls_delivery_signature IS NULL OR #{table}.hls_delivery_signature = ''" if column_available?(table, :hls_delivery_signature)
      conditions << "#{table}.hls_manifest_sha256 IS NULL OR #{table}.hls_manifest_sha256 = ''" if column_available?(table, :hls_manifest_sha256)
      conditions << "#{table}.hls_variant_sequence_sha256 IS NULL OR #{table}.hls_variant_sequence_sha256 = ''" if column_available?(table, :hls_variant_sequence_sha256)
      return [] if conditions.blank?

      scope
        .includes(:user, :media_item)
        .where(conditions.map { |condition| "(#{condition})" }.join(" OR "))
        .order(Arel.sql("COALESCE(#{table}.#{playback_timestamp_column}, #{table}.created_at) DESC"))
        .limit(10)
        .map do |session|
          item = session.media_item
          {
            id: session.id,
            public_id: item&.public_id,
            title: item&.title,
            user: session.user&.username,
            hls_variant: session.respond_to?(:hls_variant) ? session.hls_variant : nil,
            played_at: playback_time_for(session)&.utc&.iso8601,
            missing_signature: session.respond_to?(:hls_delivery_signature) && session.hls_delivery_signature.blank?,
            missing_manifest: session.respond_to?(:hls_manifest_sha256) && session.hls_manifest_sha256.blank?,
            missing_sequence: session.respond_to?(:hls_variant_sequence_sha256) && session.hls_variant_sequence_sha256.blank?,
          }
        end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics missing delivery receipts failed #{e.class}: #{e.message}")
      []
    end

    def quiet_ready_media_payload(since)
      table = ::MediaGallery::MediaItem.table_name
      scope = media_item_scope.includes(:user).where(status: "ready")
      scope = scope.where("#{table}.created_at >= ?", since) if since.present?
      scope = scope.where("COALESCE(#{table}.views_count, 0) = 0") if column_available?(table, :views_count)
      scope = scope.where("COALESCE(#{table}.likes_count, 0) = 0") if column_available?(table, :likes_count)
      scope = scope.where("COALESCE(#{table}.comments_count, 0) = 0") if column_available?(table, :comments_count)
      scope.order(created_at: :desc).limit(10).map { |item| curation_item_row(item) }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics quiet ready media failed #{e.class}: #{e.message}")
      []
    end

    def stale_ready_media_payload
      table = ::MediaGallery::MediaItem.table_name
      cutoff = 90.days.ago
      scope = media_item_scope.includes(:user).where(status: "ready").where("#{table}.created_at < ?", cutoff)
      scope = scope.where("COALESCE(#{table}.views_count, 0) <= 1") if column_available?(table, :views_count)
      scope = scope.where("COALESCE(#{table}.likes_count, 0) = 0") if column_available?(table, :likes_count)
      scope = scope.where("COALESCE(#{table}.comments_count, 0) = 0") if column_available?(table, :comments_count)
      scope.order(created_at: :asc).limit(10).map { |item| curation_item_row(item) }
    rescue => e
      Rails.logger.warn("[media_gallery] statistics stale ready media failed #{e.class}: #{e.message}")
      []
    end

    def curation_item_row(item)
      {
        public_id: item.public_id,
        title: item.title,
        uploader: item.user&.username,
        media_type: item.media_type,
        views_count: item.respond_to?(:views_count) ? item.views_count.to_i : 0,
        likes_count: item.respond_to?(:likes_count) ? item.likes_count.to_i : 0,
        comments_count: item.respond_to?(:comments_count) ? item.comments_count.to_i : 0,
        created_at: item.created_at&.utc&.iso8601,
      }
    rescue
      {}
    end

    def playback_time_for(session)
      value = session.respond_to?(:played_at) ? session.played_at : nil
      value.presence || session.created_at
    rescue
      nil
    end

    def safe_ratio(numerator, denominator, precision = 1)
      denominator = denominator.to_f
      return nil unless denominator.positive?

      (numerator.to_f / denominator).round(precision)
    rescue
      nil
    end

    def insight_row(severity, title, message, action)
      { severity: severity, title: title, message: message, action: action }
    end

    def window_label(from_time, to_time)
      return nil if from_time.blank? || to_time.blank?

      "#{from_time.to_date.iso8601} – #{(to_time - 1.second).to_date.iso8601}"
    rescue
      nil
    end

    def time_window_scope(scope, timestamp_column, from_time, to_time)
      return scope if scope.nil?
      return scope unless column_available?(scope.klass.table_name, timestamp_column)

      scoped = scope.where.not(timestamp_column => nil)
      scoped = scoped.where("#{scope.klass.table_name}.#{timestamp_column} >= ?", from_time) if from_time.present?
      scoped = scoped.where("#{scope.klass.table_name}.#{timestamp_column} < ?", to_time) if to_time.present?
      scoped
    rescue
      scope
    end

    def time_window_count(scope, timestamp_column, from_time, to_time)
      safe_count(time_window_scope(scope, timestamp_column, from_time, to_time))
    end

    def time_window_sum(scope, sum_column, timestamp_column, from_time, to_time)
      safe_sum(time_window_scope(scope, timestamp_column, from_time, to_time), sum_column)
    end

    def time_window_distinct_count(scope, distinct_column, timestamp_column, from_time, to_time)
      safe_distinct_count(time_window_scope(scope, timestamp_column, from_time, to_time), distinct_column)
    end

    def parse_report_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue
      nil
    end

    def usernames_by_id(ids)
      clean_ids = Array(ids).compact.map(&:to_i).uniq
      return {} if clean_ids.blank?

      ::User.where(id: clean_ids).pluck(:id, :username).to_h
    rescue
      {}
    end

    def safe_group_sum(scope, group_column, sum_column)
      return {} unless column_available?(scope.klass.table_name, group_column)
      return {} unless column_available?(scope.klass.table_name, sum_column)

      scope.group(group_column).sum(sum_column)
    rescue
      {}
    end

    def safe_group_max(scope, group_column, max_column)
      return {} unless column_available?(scope.klass.table_name, group_column)
      return {} unless column_available?(scope.klass.table_name, max_column)

      scope.group(group_column).maximum(max_column)
    rescue
      {}
    end

    def safe_group_distinct_count(scope, group_column, distinct_column)
      return {} unless column_available?(scope.klass.table_name, group_column)
      return {} unless column_available?(scope.klass.table_name, distinct_column)

      table = scope.klass.table_name
      scope.group(group_column).pluck(group_column, Arel.sql("COUNT(DISTINCT #{table}.#{distinct_column})")).to_h
    rescue
      {}
    end

    def comment_report_trend(period, since)
      grouped_count(media_comment_report_scope, :created_at, period, since)
    end

    def media_report_stats
      stats = base_report_stats
      each_media_report do |report|
        status = normalized_report_status(report["status"])
        stats[:total] += 1
        stats[status] += 1 if stats.key?(status)
      end
      stats
    rescue => e
      Rails.logger.warn("[media_gallery] statistics media report stats failed #{e.class}: #{e.message}")
      base_report_stats
    end

    def comment_report_stats
      scope = media_comment_report_scope
      stats = base_report_stats
      return stats if scope.blank?

      grouped = safe_group_count(scope, :status)
      grouped.each do |status, count|
        normalized = normalized_report_status(status)
        stats[:total] += count.to_i
        stats[normalized] += count.to_i if stats.key?(normalized)
      end
      stats
    rescue => e
      Rails.logger.warn("[media_gallery] statistics comment report stats failed #{e.class}: #{e.message}")
      base_report_stats
    end

    def base_report_stats
      { total: 0, open: 0, accepted: 0, rejected: 0, resolved: 0 }
    end

    def normalized_report_status(value)
      case value.to_s
      when "accepted", "accept", "hidden"
        :accepted
      when "rejected", "reject"
        :rejected
      when "resolved", "resolve"
        :resolved
      else
        :open
      end
    end

    def each_media_report
      return enum_for(:each_media_report) unless block_given?
      return unless column_available?(::MediaGallery::MediaItem.table_name, :extra_metadata)

      media_item_scope.where("extra_metadata ? ?", MEDIA_REPORTS_KEY).find_each(batch_size: 100) do |item|
        media_reports_for_item(item).each { |report| yield report, item }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] statistics each media report failed #{e.class}: #{e.message}")
    end

    def media_reports_for_item(item)
      metadata = item&.extra_metadata
      reports = metadata.is_a?(Hash) ? metadata[MEDIA_REPORTS_KEY] : []
      reports.is_a?(Array) ? reports.select { |entry| entry.is_a?(Hash) } : []
    rescue
      []
    end

    def comment_reports_for_item(item_id)
      return 0 if item_id.blank?

      media_comment_report_scope.where(media_item_id: item_id).count
    rescue
      0
    end

    def false_report_ratio_percent(media_reports, comment_reports)
      total = media_reports[:total].to_i + comment_reports[:total].to_i
      return nil unless total.positive?

      rejected = media_reports[:rejected].to_i + comment_reports[:rejected].to_i
      ((rejected.to_f / total) * 100).round(1)
    end

    def safe_count(scope)
      scope.count.to_i
    rescue
      0
    end

    def safe_sum(scope, column)
      return 0 unless column_available?(scope.klass.table_name, column)

      scope.sum(column).to_i
    rescue
      0
    end

    def safe_distinct_count(scope, column)
      return 0 unless column_available?(scope.klass.table_name, column)

      scope.where.not(column => nil).distinct.count(column).to_i
    rescue
      0
    end

    def safe_group_count(scope, column)
      return {} unless column_available?(scope.klass.table_name, column)

      scope.group(column).count
    rescue
      {}
    end

    def top_group_counts(scope, column, limit)
      return {} if scope.nil?
      return {} unless column_available?(scope.klass.table_name, column)

      scope.group(column).order(Arel.sql("COUNT(*) DESC")).limit(limit).count
    rescue
      {}
    end

    def max_time(scope, column)
      return nil if scope.nil?
      return nil unless column_available?(scope.klass.table_name, column)

      scope.maximum(column)&.utc&.iso8601
    rescue
      nil
    end

    def to_name_count_rows(hash)
      hash.map do |name, count|
        { name: name.to_s.presence || "unknown", label: humanize_token(name), count: count.to_i }
      end.sort_by { |row| [-row[:count], row[:label].to_s] }
    rescue
      []
    end

    def humanize_token(value)
      text = value.to_s.strip
      return "Unknown" if text.blank?

      text.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    def normalized_period
      value = params[:period].to_s.presence || "day"
      PERIODS.key?(value) ? value : "day"
    end

    def normalized_limit(period)
      config = PERIODS.fetch(period)
      value = params[:limit].to_i
      value = config[:default_limit] if value <= 0
      [[value, 1].max, config[:max_limit]].min
    end

    def period_since(period, limit)
      now = truncate_time(Time.zone.now, period)
      shift_period(now, period, -(limit - 1))
    rescue
      30.days.ago
    end

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
  end
end
