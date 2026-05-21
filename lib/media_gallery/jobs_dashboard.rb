# frozen_string_literal: true

require "cgi"
require "json"

module ::MediaGallery
  # Read-only admin dashboard for Media Gallery background-like operations.
  #
  # The plugin stores most operation state on MediaItem.extra_metadata instead of
  # a dedicated jobs table. This dashboard deliberately reads those states only;
  # it does not enqueue, cancel, retry, or mutate any operation.
  module JobsDashboard
    extend self

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    RECENT_WINDOW_DAYS = 90
    STALE_FORENSICS_TASK_AFTER = 6.hours
    TEST_DOWNLOAD_TASK_RECENT_WINDOW = 7.days
    MAX_PLUGIN_STORE_TASK_ROWS = 1000

    ACTIVE_STATUSES = %w[
      queued working running processing copying verifying cleaning pending pending_cleanup switching rolling_back finalizing
    ].freeze
    FAILED_STATUSES = %w[failed error danger stale stale_queued stale_working].freeze
    COMPLETED_STATUSES = %w[
      ready copied verified switched cleaned finalized rolled_back skipped cancelled cleared completed complete success logged idle scheduled
    ].freeze

    TYPE_GROUPS = {
      "processing" => "Media processing",
      "migration" => "Migration",
      "aes" => "AES / HLS",
      "forensics" => "Forensics",
      "test_download" => "Test downloads",
      "maintenance" => "Maintenance",
    }.freeze

    def index(filters = {})
      status_filter = normalize_status(filters[:status])
      type_filter = normalize_type(filters[:type])
      limit = normalize_limit(filters[:limit])

      all_rows = all_operation_rows
      status_rows = apply_status_filter(all_rows, status_filter)
      rows = apply_type_filter(status_rows, type_filter)
      rows = sort_rows(rows)

      {
        summary: summary_for(rows: rows, all_rows: all_rows, status_filter: status_filter, type_filter: type_filter),
        rows: rows.first(limit),
        total_count: rows.length,
        limit: limit,
        filters: {
          status: status_filter,
          type: type_filter,
        },
        filter_options: {
          statuses: %w[all active failed completed],
          types: [{ value: "all", label: "All job types" }] + TYPE_GROUPS.map { |value, label| { value: value, label: label } },
        },
        generated_at: Time.zone.now.iso8601,
        generated_at_label: Time.zone.now.strftime("%Y-%m-%d %H:%M:%S"),
      }
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard failed #{e.class}: #{e.message}")
      {
        summary: empty_summary,
        rows: [],
        total_count: 0,
        limit: normalize_limit(filters[:limit]),
        filters: {
          status: normalize_status(filters[:status]),
          type: normalize_type(filters[:type]),
        },
        filter_options: {
          statuses: %w[all active failed completed],
          types: [{ value: "all", label: "All job types" }] + TYPE_GROUPS.map { |value, label| { value: value, label: label } },
        },
        error: "Unable to load jobs dashboard. #{e.class}: #{e.message}",
      }
    end

    private

    def all_operation_rows
      rows = media_item_operation_rows
      rows.concat(forensics_task_rows)
      rows.concat(test_download_task_rows)
      rows.concat(maintenance_task_rows)
      rows.concat(recent_activity_rows)
      rows
    end

    def media_item_operation_rows
      items = candidate_items
      rows = []

      items.each do |item|
        rows.concat(rows_for_item(item))
      end

      rows
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard media rows failed #{e.class}: #{e.message}")
      []
    end

    def candidate_items
      scope = ::MediaGallery::MediaItem.includes(:user)
      recent = scope.where("updated_at >= ?", RECENT_WINDOW_DAYS.days.ago)
      active = scope.where(status: %w[queued processing failed])
      scope.where(id: recent.select(:id)).or(scope.where(id: active.select(:id))).order(updated_at: :desc).limit(500).to_a
    rescue
      ::MediaGallery::MediaItem.includes(:user).order(updated_at: :desc).limit(250).to_a
    end

    def rows_for_item(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      rows = []

      rows << processing_row(item, meta) if processing_relevant?(item, meta)
      rows << state_row(item, meta["migration_copy"], key: "migration_copy", group: "migration", label: "Migration copy", operation: "copy")
      rows << state_row(item, meta["migration_verify"], key: "migration_verify", group: "migration", label: "Migration verify", operation: "verify")
      rows << state_row(item, meta["migration_switch"], key: "migration_switch", group: "migration", label: "Migration switch", operation: "switch")
      rows << state_row(item, meta["migration_cleanup"], key: "migration_cleanup", group: "migration", label: "Migration cleanup", operation: "cleanup")
      rows << state_row(item, meta["migration_rollback"], key: "migration_rollback", group: "migration", label: "Migration rollback", operation: "rollback")
      rows << state_row(item, meta["migration_finalize"], key: "migration_finalize", group: "migration", label: "Migration finalize", operation: "finalize")

      aes_state = meta["hls_aes128_backfill"]
      if aes_state.is_a?(Hash) && aes_state.present?
        operation = aes_state["operation"].to_s
        label = operation == "key_rotation" ? "AES key rotation" : "AES backfill"
        rows << state_row(item, aes_state, key: "hls_aes128_backfill", group: "aes", label: label, operation: operation.presence || "hls_aes128_backfill")
      end

      rows << state_row(item, meta["hls_clear_rollback"], key: "hls_clear_rollback", group: "aes", label: "Normal HLS rollback", operation: "hls_clear_rollback")

      rows.compact
    end

    def processing_relevant?(item, meta)
      %w[queued processing failed].include?(item.status.to_s) || meta["processing"].is_a?(Hash) && meta["processing"].present?
    end

    def processing_row(item, meta)
      processing = meta["processing"].is_a?(Hash) ? meta["processing"] : {}
      status = item.status.to_s.presence || processing["current_stage"].to_s.presence || "unknown"
      state = processing.merge("status" => status)

      base_row(
        item: item,
        state: state,
        state_key: "processing",
        group: "processing",
        label: "Media processing",
        operation: "processing",
      ).merge(
        stage: processing["current_stage"].presence || item.status,
        detail: processing["current_run_job_class"].presence || processing["last_failed_stage"].presence,
      )
    end

    def state_row(item, state, key:, group:, label:, operation:)
      return nil unless state.is_a?(Hash) && state.present?
      return nil if state["status"].blank? && state["started_at"].blank? && state["queued_at"].blank? && state["finished_at"].blank?

      base_row(
        item: item,
        state: state,
        state_key: key,
        group: group,
        label: label,
        operation: operation,
      )
    end

    def base_row(item:, state:, state_key:, group:, label:, operation:)
      status = state["status"].to_s.presence || "unknown"
      updated_at = first_present(state["updated_at"], state["finished_at"], state["started_at"], state["queued_at"], item.updated_at&.iso8601)
      progress = progress_for(state)
      target = first_present(state["target_profile"], state["target_profile_key"], state["target_backend"])
      source = first_present(state["source_profile"], state["source_profile_key"], state["source_backend"])
      error = first_present(state["last_error"], state["last_error_message"], state["error"])

      {
        id: "#{item.id}-#{state_key}",
        state_key: state_key,
        group: group,
        group_label: TYPE_GROUPS[group] || group.to_s.humanize,
        label: label,
        operation: operation,
        status: status,
        status_group: status_group(status),
        status_label: status_label(status),
        title: item.title.to_s.presence || item.public_id.to_s,
        public_id: item.public_id.to_s,
        media_type: item.media_type.to_s,
        item_status: item.status.to_s,
        username: item.user&.username,
        queued_at: state["queued_at"],
        started_at: state["started_at"] || state["job_started_at"],
        finished_at: first_present(state["finished_at"], state["copied_at"], state["cleaned_at"], state["verified_at"], state["switched_at"], state["finalized_at"], state["rolled_back_at"]),
        updated_at: updated_at,
        updated_at_label: time_label(updated_at),
        source_profile: source,
        target_profile: target,
        progress: progress,
        current_object: first_present(state["current_key"], state["current_role"], state["current_object"]),
        error: error.to_s.presence,
        error_code: first_present(state["last_error_code"], state["error_code"]),
        management_url: media_management_url(item.public_id),
        migrations_url: media_migrations_url(item.public_id),
        logs_url: "/admin/plugins/media-gallery-logs?q=#{CGI.escape(item.public_id.to_s)}&hours=720",
      }.compact
    end

    def forensics_task_rows
      return [] unless defined?(::MediaGallery::ForensicsIdentifyTasks)

      root = ::MediaGallery::ForensicsIdentifyTasks.root_path
      return [] if root.blank? || !Dir.exist?(root)

      Dir.glob(File.join(root, "*", ".task.json"))
        .sort_by { |path| File.mtime(path) rescue Time.at(0) }
        .reverse
        .first(50)
        .map { |path| forensics_task_row(path) }
        .compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard forensics task rows failed #{e.class}: #{e.message}")
      []
    end

    def forensics_task_row(path)
      payload = JSON.parse(File.read(path))
      task_id = payload["task_id"].to_s.presence || File.basename(File.dirname(path))
      public_id = payload["public_id"].to_s.presence
      item = public_id.present? ? ::MediaGallery::MediaItem.find_by(public_id: public_id) : nil
      raw_status = payload["status"].to_s.presence || "unknown"
      updated_at = first_present(payload["updated_at"], payload["finished_at"], payload["created_at"], File.mtime(path).utc.iso8601)
      status = stale_forensics_status(raw_status, updated_at)
      error = payload["error"].to_s.presence

      detail = if status.to_s.start_with?("stale_")
        "Task marker still says #{raw_status}, but it has not changed for more than #{(STALE_FORENSICS_TASK_AFTER.to_i / 1.hour.to_i).to_i} hours. Review the identify page or logs before retrying."
      elsif payload["original_filename"].present?
        "Input file: #{payload["original_filename"]}"
      end

      {
        id: "forensics-task-#{task_id}",
        state_key: "forensics_task",
        group: "forensics",
        group_label: TYPE_GROUPS["forensics"],
        label: "Forensics identify task",
        operation: "forensics_identify",
        status: status,
        status_group: status_group(status),
        status_label: status_label(status),
        original_status: raw_status,
        title: item&.title.to_s.presence || public_id || "Identify task #{task_id}",
        public_id: public_id,
        media_type: item&.media_type.to_s.presence,
        item_status: item&.status.to_s.presence,
        username: item&.user&.username,
        updated_at: updated_at,
        updated_at_label: time_label(updated_at),
        detail: detail,
        error: error,
        management_url: public_id.present? ? media_management_url(public_id) : nil,
        forensics_url: public_id.present? ? media_forensics_url(public_id) : "/admin/plugins/media-gallery-forensics-identify",
        logs_url: public_id.present? ? "/admin/plugins/media-gallery-logs?q=#{CGI.escape(public_id.to_s)}&event_type=forensics_identify&hours=720" : "/admin/plugins/media-gallery-logs?event_type=forensics_identify&hours=720",
      }.compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard forensics task row failed #{path} #{e.class}: #{e.message}")
      nil
    end

    def test_download_task_rows
      return [] unless defined?(::MediaGallery::TestDownloads)
      return [] unless defined?(::PluginStoreRow) && ::PluginStoreRow.respond_to?(:where)
      return [] if ::PluginStoreRow.respond_to?(:table_exists?) && !::PluginStoreRow.table_exists?

      namespace = ::MediaGallery::TestDownloads::TASK_NAMESPACE
      rows = plugin_store_rows_for(namespace)
      rows
        .filter_map { |store_row| test_download_task_payload(namespace, store_row) }
        .filter_map { |payload| test_download_task_row(payload) }
        .sort_by { |row| -(parse_time(row[:updated_at])&.to_f || 0) }
        .first(50)
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard test download task rows failed #{e.class}: #{e.message}")
      []
    end

    def plugin_store_rows_for(namespace)
      scope = ::PluginStoreRow.where(plugin_name: namespace)
      recent_rows = scope
      recent_rows = recent_rows.order(updated_at: :desc) if plugin_store_row_column?("updated_at")

      rows = recent_rows.limit(MAX_PLUGIN_STORE_TASK_ROWS).to_a
      rows.concat(active_plugin_store_rows(scope))
      rows.uniq { |row| plugin_store_row_identity(row) }
    end

    def active_plugin_store_rows(scope)
      return [] unless plugin_store_row_column?("value")

      active_statuses = %w[queued working running processing]
      patterns = active_statuses.flat_map { |status| ["%\"status\":\"#{status}\"%", "%\"status\": \"#{status}\"%"] }
      where_clause = Array.new(patterns.length, "value LIKE ?").join(" OR ")
      scope.where(where_clause, *patterns).limit(MAX_PLUGIN_STORE_TASK_ROWS).to_a
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard active test download task lookup failed #{e.class}: #{e.message}")
      []
    end

    def plugin_store_row_identity(row)
      return row.id if row.respond_to?(:id) && row.id.present?
      return row.key if row.respond_to?(:key) && row.key.present?

      row.object_id
    end

    def plugin_store_row_column?(column)
      ::PluginStoreRow.respond_to?(:column_names) && ::PluginStoreRow.column_names.include?(column.to_s)
    rescue
      false
    end

    def test_download_task_payload(namespace, store_row)
      key = store_row.respond_to?(:key) ? store_row.key.to_s : nil
      return nil if key.blank?

      payload = ::PluginStore.get(namespace, key)
      payload.is_a?(Hash) ? payload.merge("_plugin_store_key" => key) : nil
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard test download task read failed key=#{key} #{e.class}: #{e.message}")
      nil
    end

    def test_download_task_row(payload)
      task_id = payload["task_id"].to_s.presence
      public_id = payload["public_id"].to_s.presence
      raw_status = payload["status"].to_s.presence || "unknown"
      updated_at = first_present(payload["updated_at"], payload["finished_at"], payload["completed_at"], payload["created_at"])
      return nil unless test_download_task_relevant?(raw_status, updated_at)

      status = stale_test_download_status(raw_status, updated_at)
      item = public_id.present? ? ::MediaGallery::MediaItem.find_by(public_id: public_id) : nil
      user = payload["user_id"].present? ? ::User.find_by(id: payload["user_id"].to_i) : nil
      artifact = payload["artifact"].is_a?(Hash) ? payload["artifact"] : {}
      mode = payload["mode"].to_s.presence
      segment_count = payload["segment_count"].presence
      start_segment = payload["start_segment"].presence
      detail_parts = []
      detail_parts << "Mode: #{mode}" if mode.present?
      detail_parts << "Start segment: #{start_segment}" if start_segment.present?
      detail_parts << "Segment count: #{segment_count}" if segment_count.present?
      detail_parts << "Artifact: #{artifact["artifact_id"]}" if artifact["artifact_id"].present?

      detail = if status.to_s.start_with?("stale_")
        "Task marker still says #{raw_status}, but it has not changed for more than #{distance_label(test_download_stale_after)}. Review Test downloads or logs before retrying."
      else
        detail_parts.join(" • ").presence
      end

      {
        id: "test-download-task-#{task_id || payload["_plugin_store_key"] || public_id}",
        state_key: "test_download_task",
        group: "test_download",
        group_label: TYPE_GROUPS["test_download"],
        label: "Test download generation",
        operation: "generate_test_download",
        status: status,
        status_group: status_group(status),
        status_label: status_label(status),
        original_status: raw_status,
        title: item&.title.to_s.presence || public_id || "Test download task #{task_id}",
        public_id: public_id,
        media_type: item&.media_type.to_s.presence,
        item_status: item&.status.to_s.presence,
        username: user&.username || item&.user&.username,
        queued_at: payload["created_at"],
        started_at: payload["started_at"],
        finished_at: first_present(payload["finished_at"], payload["completed_at"]),
        updated_at: updated_at,
        updated_at_label: time_label(updated_at),
        detail: detail,
        error: payload["error"].to_s.presence,
        management_url: public_id.present? ? media_management_url(public_id) : nil,
        test_downloads_url: public_id.present? ? media_test_downloads_url(public_id) : "/admin/plugins/media-gallery-test-downloads",
        logs_url: public_id.present? ? "/admin/plugins/media-gallery-logs?q=#{CGI.escape(public_id.to_s)}&event_type=test_download&hours=720" : "/admin/plugins/media-gallery-logs?event_type=test_download&hours=720",
      }.compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard test download task row failed #{e.class}: #{e.message}")
      nil
    end

    def test_download_task_relevant?(status, updated_at)
      return true if ACTIVE_STATUSES.include?(status.to_s.downcase)

      time = parse_time(updated_at)
      time.present? && time >= TEST_DOWNLOAD_TASK_RECENT_WINDOW.ago
    end

    def maintenance_task_rows
      rows = []
      rows << chunked_upload_cleanup_row if defined?(::MediaGallery::ChunkedUploads)
      rows.compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard maintenance rows failed #{e.class}: #{e.message}")
      []
    end

    def chunked_upload_cleanup_row
      cleanup = ::MediaGallery::ChunkedUploads.last_cleanup_summary
      summary = (::MediaGallery::ChunkedUploads.workspace_summary rescue {})
      cleanup = cleanup.is_a?(Hash) ? cleanup.with_indifferent_access : {}
      summary = summary.is_a?(Hash) ? summary.with_indifferent_access : {}

      skipped = cleanup[:skipped].to_i
      skipped_errors = Array(cleanup[:skipped_errors])
      removed = cleanup[:removed].to_i
      scanned = cleanup[:scanned].to_i
      bytes_removed = cleanup[:bytes_removed].to_i
      ran_at = cleanup[:ran_at].presence
      enabled = ActiveModel::Type::Boolean.new.cast(summary[:enabled])
      expired = summary[:expired_sessions].to_i
      active = summary[:active_sessions].to_i
      temp_bytes = summary[:actual_temp_storage_bytes].to_i

      status = if skipped.positive? || skipped_errors.present?
        "failed"
      elsif ran_at.present?
        "completed"
      else
        "idle"
      end

      detail = chunked_upload_cleanup_detail(
        enabled: enabled,
        active: active,
        expired: expired,
        temp_bytes: temp_bytes,
        ran_at: ran_at,
        scanned: scanned,
        removed: removed,
        skipped: skipped,
        bytes_removed: bytes_removed
      )

      {
        id: "maintenance-chunked-upload-cleanup",
        state_key: "chunked_upload_cleanup",
        group: "maintenance",
        group_label: TYPE_GROUPS["maintenance"],
        label: "Chunked upload cleanup",
        operation: "media_gallery_cleanup_chunked_uploads",
        status: status,
        status_group: status_group(status),
        status_label: status_label(status),
        title: "Chunked upload cleanup",
        updated_at: ran_at,
        updated_at_label: time_label(ran_at),
        detail: detail,
        error: skipped_errors.first && skipped_errors.first["error"].to_s.presence,
        health_url: "/admin/plugins/media-gallery-health",
        logs_url: "/admin/plugins/media-gallery-logs?event_type=media_gallery_chunked_upload_cleanup&hours=168",
      }.compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard chunked cleanup row failed #{e.class}: #{e.message}")
      nil
    end

    def recent_activity_rows
      return [] unless defined?(::MediaGallery::MediaLogEvent) && ::MediaGallery::LogEvents.table_present?

      patterns = ["forensics_identify", "test_download"]
      rows = ::MediaGallery::MediaLogEvent.includes(:media_item, :user)
        .where("created_at >= ?", 7.days.ago)
        .where(patterns.map { "event_type LIKE ?" }.join(" OR "), *patterns.map { |p| "#{p}%" })
        .order(created_at: :desc)
        .limit(50)
        .to_a

      rows.map { |event| log_activity_row(event) }.compact
    rescue => e
      Rails.logger.warn("[media_gallery] jobs dashboard recent activity failed #{e.class}: #{e.message}")
      []
    end

    def log_activity_row(event)
      item = event.media_item
      group = event.event_type.to_s.start_with?("test_download") ? "test_download" : "forensics"
      public_id = event.media_public_id.presence || item&.public_id
      title = item&.title.to_s.presence || public_id || event.event_type.to_s
      result = event.details.is_a?(Hash) ? event.details["result"].to_s.presence : nil
      status = event.severity.to_s == "danger" ? "failed" : "logged"
      label = group == "test_download" ? "Test download log" : "Forensics identify log"
      detail = [event.message, result.present? ? "Result: #{result}" : nil].compact.join(" — ")

      {
        id: "log-#{event.id}",
        state_key: "log_event",
        group: group,
        group_label: TYPE_GROUPS[group] || group.humanize,
        label: label,
        operation: event.event_type,
        status: status,
        status_group: status_group(status),
        status_label: status_label(status),
        title: title,
        public_id: public_id,
        username: event.user&.username,
        updated_at: event.created_at&.iso8601,
        updated_at_label: time_label(event.created_at),
        detail: detail.presence,
        management_url: public_id.present? ? media_management_url(public_id) : nil,
        forensics_url: group == "forensics" ? (public_id.present? ? media_forensics_url(public_id) : "/admin/plugins/media-gallery-forensics-identify") : nil,
        test_downloads_url: group == "test_download" ? (public_id.present? ? media_test_downloads_url(public_id) : "/admin/plugins/media-gallery-test-downloads") : nil,
        logs_url: "/admin/plugins/media-gallery-logs?event_type=#{CGI.escape(event.event_type.to_s)}&hours=168",
      }.compact
    end


    def media_management_url(public_id)
      escaped = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-management?q=#{escaped}&public_id=#{escaped}"
    end

    def media_migrations_url(public_id)
      escaped = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-migrations?q=#{escaped}&public_id=#{escaped}"
    end

    def media_forensics_url(public_id)
      escaped = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-forensics-identify?q=#{escaped}&public_id=#{escaped}"
    end

    def media_test_downloads_url(public_id)
      escaped = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-test-downloads?q=#{escaped}&public_id=#{escaped}"
    end

    def stale_forensics_status(status, updated_at)
      normalized = status.to_s.downcase
      return normalized unless %w[queued working running processing].include?(normalized)

      time = parse_time(updated_at)
      return normalized if time.blank? || time > STALE_FORENSICS_TASK_AFTER.ago

      "stale_#{normalized}"
    end

    def stale_test_download_status(status, updated_at)
      normalized = status.to_s.downcase
      return normalized unless %w[queued working running processing].include?(normalized)

      time = parse_time(updated_at)
      return normalized if time.blank? || time > test_download_stale_after.ago

      "stale_#{normalized}"
    end

    def test_download_stale_after
      minutes = if SiteSetting.respond_to?(:media_gallery_admin_long_job_polling_timeout_minutes)
        SiteSetting.media_gallery_admin_long_job_polling_timeout_minutes.to_i
      else
        45
      end
      minutes = 45 if minutes <= 0
      [minutes.minutes + 30.minutes, 2.hours].max
    rescue
      2.hours
    end


    def chunked_upload_cleanup_detail(enabled:, active:, expired:, temp_bytes:, ran_at:, scanned:, removed:, skipped:, bytes_removed:)
      parts = []

      if ran_at.blank?
        parts << "No cleanup run has been recorded yet."
      elsif skipped.to_i.positive?
        parts << "Cleanup completed with #{skipped} skipped folder#{'s' if skipped.to_i != 1}. Check logs."
      elsif removed.to_i.positive?
        parts << "Removed #{removed} expired session#{'s' if removed.to_i != 1} and freed #{bytes_label(bytes_removed)}."
      elsif scanned.to_i.positive?
        parts << "No expired chunked upload sessions found."
      else
        parts << "No chunked upload cleanup was needed."
      end

      context = []
      context << "chunked uploads disabled" unless enabled
      context << "#{active} active upload#{'s' if active.to_i != 1}" if active.to_i.positive?
      context << "#{expired} expired folder#{'s' if expired.to_i != 1} waiting" if expired.to_i.positive?
      context << "temp usage #{bytes_label(temp_bytes)}" if temp_bytes.to_i.positive?
      parts << context.join(" · ") if context.present?

      parts.join(" ")
    rescue
      "Cleanup status is unavailable."
    end

    def bytes_label(value)
      bytes = value.to_i
      return "0 B" if bytes <= 0

      units = %w[B KB MB GB TB]
      amount = bytes.to_f
      unit = units.shift
      while amount >= 1024.0 && units.present?
        amount /= 1024.0
        unit = units.shift
      end

      precision = amount >= 10 || unit == "B" ? 0 : 1
      "#{amount.round(precision)} #{unit}"
    rescue
      "0 B"
    end

    def distance_label(duration)
      seconds = duration.to_i
      return "#{(seconds / 1.hour.to_i).round} hours" if seconds >= 1.hour.to_i
      return "#{(seconds / 1.minute.to_i).round} minutes" if seconds >= 1.minute.to_i

      "#{seconds} seconds"
    end

    def progress_for(state)
      index = first_present(state["progress_index"], state["current_index"])
      total = first_present(state["progress_total"], state["object_count"], state["total"])
      copied = first_present(state["objects_copied"], state["copied"])
      skipped = first_present(state["objects_skipped"], state["skipped"])
      failed = first_present(state["objects_failed"], state["failed"])

      return nil if index.blank? && total.blank? && copied.blank? && skipped.blank? && failed.blank?

      percent = nil
      if index.to_i.positive? && total.to_i.positive?
        percent = [(index.to_f / total.to_f * 100).round, 100].min
      elsif copied.to_i.positive? && total.to_i.positive?
        percent = [(copied.to_f / total.to_f * 100).round, 100].min
      end

      {
        index: index,
        total: total,
        copied: copied,
        skipped: skipped,
        failed: failed,
        percent: percent,
      }.compact
    end

    def status_group(status)
      normalized = status.to_s.downcase
      return "active" if ACTIVE_STATUSES.include?(normalized)
      return "failed" if FAILED_STATUSES.include?(normalized)
      return "completed" if COMPLETED_STATUSES.include?(normalized)

      "other"
    end

    def status_label(status)
      status.to_s.tr("_", " ").presence&.capitalize || "Unknown"
    end

    def apply_type_filter(rows, type_filter)
      return rows if type_filter == "all"

      rows.select { |row| row[:group].to_s == type_filter }
    end

    def apply_status_filter(rows, status_filter)
      return rows if status_filter == "all"

      rows.select { |row| row[:status_group].to_s == status_filter }
    end

    def sort_rows(rows)
      rows.sort_by { |row| -(parse_time(row[:updated_at])&.to_f || 0) }
    end

    def summary_for(rows:, all_rows:, status_filter:, type_filter:)
      status_scope_rows = type_filter == "all" ? all_rows : all_rows.select { |row| row[:group].to_s == type_filter }
      type_scope_rows = status_filter == "all" ? all_rows : all_rows.select { |row| row[:status_group].to_s == status_filter }

      active = status_scope_rows.count { |row| row[:status_group].to_s == "active" }
      failed = status_scope_rows.count { |row| row[:status_group].to_s == "failed" }
      completed = status_scope_rows.count { |row| row[:status_group].to_s == "completed" }

      {
        active_count: active,
        failed_count: failed,
        completed_count: completed,
        visible_count: rows.length,
        total_count: all_rows.length,
        status_scope_count: status_scope_rows.length,
        type_scope_count: type_scope_rows.length,
        by_status: [
          { status: "all", label: "All statuses", count: status_scope_rows.length },
          { status: "active", label: "Active", count: active },
          { status: "failed", label: "Failed", count: failed },
          { status: "completed", label: "Completed", count: completed },
        ],
        by_type: TYPE_GROUPS.keys.map do |type|
          { type: type, label: TYPE_GROUPS[type], count: type_scope_rows.count { |row| row[:group].to_s == type } }
        end,
      }
    end

    def empty_summary
      {
        active_count: 0,
        failed_count: 0,
        completed_count: 0,
        visible_count: 0,
        total_count: 0,
        status_scope_count: 0,
        type_scope_count: 0,
        by_status: [
          { status: "all", label: "All statuses", count: 0 },
          { status: "active", label: "Active", count: 0 },
          { status: "failed", label: "Failed", count: 0 },
          { status: "completed", label: "Completed", count: 0 },
        ],
        by_type: TYPE_GROUPS.keys.map { |type| { type: type, label: TYPE_GROUPS[type], count: 0 } },
      }
    end

    def normalize_status(value)
      value = value.to_s.strip
      %w[all active failed completed].include?(value) ? value : "all"
    end

    def normalize_type(value)
      value = value.to_s.strip
      (value == "all" || TYPE_GROUPS.key?(value)) ? value : "all"
    end

    def normalize_limit(value)
      limit = value.to_i
      limit = DEFAULT_LIMIT if limit <= 0
      [[limit, 10].max, MAX_LIMIT].min
    end

    def first_present(*values)
      values.find { |value| value.present? }
    end

    def time_label(value)
      time = parse_time(value)
      time&.in_time_zone&.strftime("%Y-%m-%d %H:%M:%S")
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue
      nil
    end
  end
end
