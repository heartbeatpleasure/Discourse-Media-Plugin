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

      payload = {
        filters: {
          period: period,
          limit: limit,
          since: since&.utc&.iso8601,
        },
        summary: timed_phase!(timing, :summary) { summary_payload },
        trends: timed_phase!(timing, :trends) { trends_payload(period, since, limit) },
        breakdowns: timed_phase!(timing, :breakdowns) { breakdowns_payload },
        top_content: timed_phase!(timing, :top_content) { top_content_payload },
        moderation: timed_phase!(timing, :moderation) { moderation_payload(period, since, limit) },
        quality: timed_phase!(timing, :quality) { quality_payload(period, since, limit) },
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

    def analytics_notes
      [
        "This first statistics iteration is read-only and uses existing Media Gallery tables and metadata.",
        "Upload, like, comment, playback and log trends are grouped by the selected time unit.",
        "Media report history is currently stored in item metadata; a later iteration can add explicit analytics event rows for more granular report charts.",
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
        media_reports_for_item(item).each { |report| yield report }
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
