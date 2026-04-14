# frozen_string_literal: true

require "digest/sha1"
require "json"

module ::MediaGallery
  module LogEvents
    module_function

    MAX_TEXT = 500
    MAX_PATH = 500
    MAX_REQUEST_ID = 100
    MAX_OVERLAY_CODE = 32
    MAX_FINGERPRINT_ID = 128
    MAX_IP = 80
    MAX_EVENT_TYPE = 80
    MAX_SEVERITY = 20
    MAX_CATEGORY = 40
    MAX_METHOD = 12
    MAX_MEDIA_PUBLIC_ID = 64
    MAX_UA_HASH = 40

    def record(event_type:, severity: "info", category: "general", request: nil, user: nil, media_item: nil, overlay_code: nil, fingerprint_id: nil, message: nil, details: nil)
      return unless table_present?

      payload = sanitize_details(details)

      ::MediaGallery::MediaLogEvent.create!(
        event_type: truncate(event_type, MAX_EVENT_TYPE),
        severity: normalize_severity(severity),
        category: truncate(category, MAX_CATEGORY),
        message: truncate(message, MAX_TEXT),
        user_id: user&.id,
        media_item_id: media_item&.id,
        media_public_id: truncate(media_item&.public_id || payload["media_public_id"], MAX_MEDIA_PUBLIC_ID),
        overlay_code: truncate(overlay_code || payload["overlay_code"], MAX_OVERLAY_CODE),
        fingerprint_id: truncate(fingerprint_id || payload["fingerprint_id"], MAX_FINGERPRINT_ID),
        ip: truncate(request&.remote_ip, MAX_IP),
        request_id: truncate(request&.request_id, MAX_REQUEST_ID),
        path: truncate(request_path(request), MAX_PATH),
        method: truncate(request&.request_method, MAX_METHOD),
        user_agent_hash: truncate(user_agent_hash(request&.user_agent), MAX_UA_HASH),
        details: payload,
      )
    rescue => e
      Rails.logger.warn("[media_gallery] log event failed type=#{event_type} error=#{e.class}: #{e.message}")
      nil
    end

    def table_present?
      ::ActiveRecord::Base.connection.data_source_exists?("media_gallery_log_events")
    rescue
      false
    end

    def search(filters = {})
      hours = normalize_hours(filters[:hours])
      limit = normalize_limit(filters[:limit])
      return empty_search(hours:, limit:, error: "Log table is not available yet. Run the plugin migration first.") unless table_present?

      scope = ::MediaGallery::MediaLogEvent.includes(:user, :media_item).order(log_events_table[:created_at].desc)

      severity = filters[:severity].to_s.strip
      scope = scope.where(severity: severity) if severity.present? && severity != "all"

      event_type = filters[:event_type].to_s.strip
      scope = scope.where(event_type: event_type) if event_type.present? && event_type != "all"

      scope = scope.where(log_events_table[:created_at].gteq(hours.hours.ago))

      query = filters[:q].to_s.strip
      if query.present?
        pattern = "%#{::ActiveRecord::Base.sanitize_sql_like(query)}%"
        scope = scope.left_outer_joins(:user, :media_item).where(
          "media_gallery_log_events.event_type ILIKE :q OR media_gallery_log_events.message ILIKE :q OR media_gallery_log_events.overlay_code ILIKE :q OR media_gallery_log_events.fingerprint_id ILIKE :q OR media_gallery_log_events.ip ILIKE :q OR media_gallery_log_events.request_id ILIKE :q OR media_gallery_log_events.media_public_id ILIKE :q OR users.username ILIKE :q OR users.name ILIKE :q OR media_gallery_media_items.public_id ILIKE :q OR media_gallery_media_items.title ILIKE :q",
          q: pattern,
        )
      end

      rows = scope.limit(limit).to_a
      {
        scope: scope,
        rows: rows,
        hours: hours,
        limit: limit,
        error: nil,
      }
    rescue => e
      Rails.logger.warn("[media_gallery] log search failed #{e.class}: #{e.message}")
      empty_search(hours:, limit:, error: "Unable to query logs. #{e.class}: #{e.message}")
    end

    def summary(scope:, rows:, hours:)
      return empty_summary(hours:, rows_count: rows.length) unless table_present? && scope.present?

      total_scope_count = safe_count(scope)
      last_24h_scope = ::MediaGallery::MediaLogEvent.where(log_events_table[:created_at].gteq(24.hours.ago))
      recent_rows = ::MediaGallery::MediaLogEvent.where(log_events_table[:created_at].gteq(24.hours.ago)).pluck(:created_at)
      hourly_counts = Array.new(24, 0)
      now = Time.zone.now
      recent_rows.each do |created_at|
        next unless created_at
        age_hours = ((now - created_at) / 3600.0).floor
        next if age_hours.negative? || age_hours > 23
        index = 23 - age_hours
        hourly_counts[index] += 1
      end

      top_event_types = safe_group_count(scope, :event_type).sort_by { |_, count| -count }.first(6).map do |name, count|
        { event_type: name, count: count }
      end

      severity_counts = safe_group_count(scope, :severity)
      {
        filtered_count: total_scope_count,
        last_24h_count: safe_count(last_24h_scope),
        unique_users: safe_distinct_count(scope, :user_id),
        unique_media_items: safe_distinct_count(scope, :media_item_id),
        unique_ips: safe_distinct_count(scope.where.not(log_events_table_name => { ip: [nil, ""] }), :ip),
        severity_counts: severity_counts,
        top_event_types: top_event_types,
        hourly_counts: hourly_counts.each_with_index.map do |count, index|
          point_time = (now.beginning_of_hour - (23 - index).hours)
          { label: point_time.strftime("%H:%M"), count: count }
        end,
        active_hours_window: hours,
        shown_rows: rows.length,
      }
    rescue => e
      Rails.logger.warn("[media_gallery] log summary failed #{e.class}: #{e.message}")
      empty_summary(hours:, rows_count: rows.length)
    end

    def serialize_rows(rows)
      rows.map do |row|
        item = row.media_item
        user = row.user
        {
          id: row.id,
          event_type: row.event_type,
          severity: row.severity,
          category: row.category,
          message: row.message,
          created_at: row.created_at,
          created_at_label: row.created_at&.in_time_zone&.strftime("%Y-%m-%d %H:%M:%S"),
          request_id: row.request_id,
          path: row.path,
          method: row.method,
          ip: row.ip,
          user_agent_hash: row.user_agent_hash,
          overlay_code: row.overlay_code,
          fingerprint_id: row.fingerprint_id,
          media_item_id: row.media_item_id,
          media_public_id: row.media_public_id.presence || item&.public_id,
          media_title: item&.title,
          user_id: row.user_id,
          username: user&.username,
          name: user&.name,
          details: row.details.is_a?(Hash) ? row.details : {},
          details_pretty: pretty_details(row.details),
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] log serialization failed #{e.class}: #{e.message}")
      []
    end

    def event_type_options
      return [] unless table_present?
      ::MediaGallery::MediaLogEvent.distinct.order(:event_type).limit(100).pluck(:event_type).compact
    rescue => e
      Rails.logger.warn("[media_gallery] log event type options failed #{e.class}: #{e.message}")
      []
    end

    def normalize_severity(value)
      case value.to_s.strip.downcase
      when "debug", "info", "notice"
        "info"
      when "warn", "warning"
        "warning"
      when "error", "danger"
        "danger"
      else
        "info"
      end
    end
    private_class_method :normalize_severity

    def normalize_hours(value)
      hours = value.to_i
      return 168 if hours <= 0
      [hours, 24 * 90].min
    end
    private_class_method :normalize_hours

    def normalize_limit(value)
      limit = value.to_i
      return 100 if limit <= 0
      [limit, 250].min
    end
    private_class_method :normalize_limit

    def empty_search(hours:, limit:, error: nil)
      { scope: nil, rows: [], hours: hours, limit: limit, error: error }
    end
    private_class_method :empty_search

    def empty_summary(hours:, rows_count: 0)
      now = Time.zone.now
      {
        filtered_count: 0,
        last_24h_count: 0,
        unique_users: 0,
        unique_media_items: 0,
        unique_ips: 0,
        severity_counts: {},
        top_event_types: [],
        hourly_counts: (0..23).map do |index|
          point_time = (now.beginning_of_hour - (23 - index).hours)
          { label: point_time.strftime("%H:%M"), count: 0 }
        end,
        active_hours_window: hours,
        shown_rows: rows_count,
      }
    end
    private_class_method :empty_summary

    def safe_count(scope)
      scope.reorder(nil).count
    rescue
      0
    end
    private_class_method :safe_count

    def safe_group_count(scope, column)
      scope.reorder(nil).group(qualified_log_column_name(column)).count
    rescue
      {}
    end
    private_class_method :safe_group_count

    def safe_distinct_count(scope, column)
      scope.reorder(nil).where.not(log_events_table_name => { column => nil }).distinct.count(qualified_log_column_name(column))
    rescue
      0
    end
    private_class_method :safe_distinct_count

    def sanitize_details(value)
      hash = value.is_a?(Hash) ? value.deep_stringify_keys : {}
      hash.each_with_object({}) do |(key, raw), result|
        next if raw.nil?
        sanitized = sanitize_detail_value(raw)
        result[truncate(key, 80)] = sanitized unless sanitized.nil?
      end
    rescue
      {}
    end
    private_class_method :sanitize_details

    def sanitize_detail_value(value)
      case value
      when String
        truncate(value, 500)
      when Numeric, TrueClass, FalseClass
        value
      when Array
        value.first(20).map { |entry| sanitize_detail_value(entry) }.compact
      when Hash
        sanitize_details(value)
      else
        truncate(value.to_s, 500)
      end
    end
    private_class_method :sanitize_detail_value

    def request_path(request)
      return nil if request.blank?
      request.fullpath.to_s.presence || request.path.to_s.presence
    rescue
      nil
    end
    private_class_method :request_path

    def user_agent_hash(value)
      text = value.to_s.strip
      return nil if text.blank?
      Digest::SHA1.hexdigest(text)[0, 16]
    rescue
      nil
    end
    private_class_method :user_agent_hash

    def truncate(value, max)
      text = value.to_s
      return nil if text.blank?
      text.length > max ? text[0, max] : text
    end
    private_class_method :truncate

    def pretty_details(value)
      hash = value.is_a?(Hash) ? value : {}
      return "" if hash.blank?
      JSON.pretty_generate(hash)
    rescue
      ""
    end
    private_class_method :pretty_details

    def log_events_table
      ::MediaGallery::MediaLogEvent.arel_table
    end
    private_class_method :log_events_table

    def log_events_table_name
      ::MediaGallery::MediaLogEvent.table_name
    end
    private_class_method :log_events_table_name

    def qualified_log_column_name(column)
      "#{log_events_table_name}.#{column}"
    end
    private_class_method :qualified_log_column_name
  end
end
