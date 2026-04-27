# frozen_string_literal: true

require "cgi"
require "csv"
require "digest/sha1"
require "time"
require "set"
require "uri"

module ::MediaGallery
  module HealthCheck
    module_function

    STORE_NAMESPACE = "media_gallery_health"
    LAST_ALERT_KEY = "last_alert"
    LAST_FULL_STORAGE_CHECK_KEY = "last_full_storage_check"
    LAST_RECONCILIATION_KEY = "last_storage_reconciliation"
    RECONCILIATION_HISTORY_KEY = "storage_reconciliation_history"
    IGNORED_FINDINGS_KEY = "ignored_findings"
    SEVERITY_ORDER = { "ok" => 0, "warning" => 1, "critical" => 2 }.freeze
    VALID_NOTIFY_SEVERITIES = %w[warning critical].freeze

    def summary(full_storage: false)
      started_at = Time.zone.now
      sections = []

      sections << processing_section
      sections << storage_section(full_storage: full_storage)
      sections << reconciliation_section
      sections << settings_section
      sections << permissions_section
      sections << reports_section

      severity = highest_severity(sections.map { |section| section[:severity] })
      issues = attention_issues(sections)

      {
        ok: severity == "ok",
        severity: severity,
        generated_at: started_at.iso8601,
        generated_at_label: started_at.strftime("%Y-%m-%d %H:%M:%S"),
        full_storage: !!full_storage,
        summary_cards: summary_cards(sections, issues),
        sections: sections,
        issues: issues,
        alert_state: last_alert_state,
        ignored_findings: ignored_findings_for_ui,
        last_full_storage_check: last_full_storage_check_summary,
        reconciliation: last_reconciliation_summary,
        reconciliation_history: reconciliation_history,
      }
    rescue => e
      Rails.logger.error("[media_gallery] health summary failed: #{e.class}: #{e.message}")
      {
        ok: false,
        severity: "critical",
        generated_at: Time.zone.now.iso8601,
        generated_at_label: Time.zone.now.strftime("%Y-%m-%d %H:%M:%S"),
        full_storage: !!full_storage,
        summary_cards: [],
        sections: [
          {
            id: "health_internal_error",
            title: "Health check error",
            description: "The health check could not complete.",
            severity: "critical",
            help: "Check Rails logs for the full exception before retrying.",
            items: [
              issue(
                id: "health_summary_failed",
                label: "Health summary failed",
                severity: "critical",
                message: "#{e.class}: #{e.message}".truncate(500)
              ),
            ],
          },
        ],
        issues: [
          issue(
            id: "health_summary_failed",
            label: "Health summary failed",
            severity: "critical",
            message: "#{e.class}: #{e.message}".truncate(500),
            metadata: { section_id: "health_internal_error", section_title: "Health check error" }
          ),
        ],
        alert_state: last_alert_state,
        ignored_findings: ignored_findings_for_ui,
        last_full_storage_check: last_full_storage_check_summary,
        reconciliation: last_reconciliation_summary,
      }
    end

    def watchdog!
      return { skipped: true, reason: "disabled" } unless enabled?
      return { skipped: true, reason: "plugin_disabled" } unless SiteSetting.media_gallery_enabled

      result = summary(full_storage: false)
      notified = maybe_notify!(result)
      { skipped: false, severity: result[:severity], notified: notified }
    rescue => e
      Rails.logger.error("[media_gallery] health watchdog failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
      nil
    end

    def maybe_notify!(result)
      min = min_notify_severity
      severity = result[:severity].to_s
      return false if severity_value(severity) < severity_value(min)

      issues = normalized_alert_issues(result)
      return false if issues.blank?

      signature = alert_signature(severity, issues)
      now = Time.zone.now
      last = last_alert_state
      cooldown_hours = setting_int(:media_gallery_health_alert_cooldown_hours, 24)
      cooldown_since = now - cooldown_hours.hours
      last_sent_at = parse_time(last["sent_at"])

      if last["signature"].to_s == signature && last_sent_at.present? && last_sent_at > cooldown_since
        return false
      end

      group_name = notify_group_name
      if group_name.blank? || ::Group.where("lower(name) = ?", group_name.downcase).blank?
        Rails.logger.warn("[media_gallery] health alert not sent: notify group missing group=#{group_name.inspect}")
        store_alert_state(
          severity: severity,
          signature: signature,
          sent_at: last["sent_at"],
          attempted_at: now.iso8601,
          error: "notify_group_missing",
          group: group_name
        )
        return false
      end

      title = "Media Gallery health alert: #{severity.titleize}"
      raw = build_alert_pm_body(result, issues)

      ::PostCreator.create!(
        Discourse.system_user,
        target_group_names: [group_name],
        archetype: Archetype.private_message,
        title: title.truncate(200),
        raw: raw
      )

      store_alert_state(
        severity: severity,
        signature: signature,
        sent_at: now.iso8601,
        attempted_at: now.iso8601,
        error: nil,
        group: group_name
      )

      record_log_event(
        event_type: "media_gallery_health_alert_sent",
        severity: severity == "critical" ? "error" : "warning",
        message: "Media Gallery health alert sent to #{group_name}.",
        details: { severity: severity, issues_count: issues.length, group: group_name }
      )

      true
    rescue => e
      Rails.logger.warn("[media_gallery] health alert failed: #{e.class}: #{e.message}")
      store_alert_state(
        severity: result[:severity].to_s,
        signature: alert_signature(result[:severity], normalized_alert_issues(result)),
        sent_at: last_alert_state["sent_at"],
        attempted_at: Time.zone.now.iso8601,
        error: "#{e.class}: #{e.message}".truncate(500),
        group: notify_group_name
      )
      false
    end

    def enabled?
      !SiteSetting.respond_to?(:media_gallery_health_watchdog_enabled) || SiteSetting.media_gallery_health_watchdog_enabled
    end

    def last_alert_state
      value = ::PluginStore.get(STORE_NAMESPACE, LAST_ALERT_KEY)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    rescue
      {}
    end

    def processing_section
      now = Time.zone.now
      stuck_minutes = setting_int(:media_gallery_health_stuck_processing_minutes, processing_stale_after_minutes)
      queued_minutes = setting_int(:media_gallery_health_stuck_queued_minutes, 60)
      failed_critical_threshold = setting_int(:media_gallery_health_failed_items_critical_threshold, 10)

      stuck_processing_scope = ::MediaGallery::MediaItem.where(status: "processing").where("updated_at < ?", stuck_minutes.minutes.ago)
      stuck_queued_scope = ::MediaGallery::MediaItem.where(status: "queued").where("created_at < ?", queued_minutes.minutes.ago)
      failed_scope = ::MediaGallery::MediaItem.where(status: "failed")
      failed_count = safe_count(failed_scope)

      items = []
      items << issue(
        id: "stuck_processing",
        label: "Stuck processing",
        severity: safe_count(stuck_processing_scope).positive? ? "critical" : "ok",
        count: safe_count(stuck_processing_scope),
        message: safe_count(stuck_processing_scope).positive? ? "Media items have been processing longer than #{stuck_minutes} minutes." : "No stuck processing items found.",
        detail: "The watchdog does not automatically change items. Retry processing from Media management or inspect logs.",
        examples: example_items(stuck_processing_scope.order(updated_at: :asc).limit(5), now: now)
      )
      items << issue(
        id: "stuck_queued",
        label: "Queued too long",
        severity: safe_count(stuck_queued_scope).positive? ? "warning" : "ok",
        count: safe_count(stuck_queued_scope),
        message: safe_count(stuck_queued_scope).positive? ? "Media items have been queued longer than #{queued_minutes} minutes." : "No long-queued items found.",
        detail: "Queued items may indicate Sidekiq or processing workers are not keeping up.",
        examples: example_items(stuck_queued_scope.order(created_at: :asc).limit(5), now: now)
      )
      items << issue(
        id: "failed_processing",
        label: "Failed processing",
        severity: failed_count >= failed_critical_threshold ? "critical" : (failed_count.positive? ? "warning" : "ok"),
        count: failed_count,
        message: failed_count.positive? ? "#{failed_count} media item#{'s' if failed_count != 1} currently failed processing." : "No failed processing items found.",
        detail: "Single failed uploads are usually user-level problems. A growing number may indicate a codec, storage, or worker problem.",
        examples: example_items(failed_scope.order(updated_at: :desc).limit(5), now: now)
      )

      section(
        id: "processing",
        title: "Processing health",
        description: "Detect stuck jobs, failed processing, and queued media that did not progress.",
        help: "Processing checks are read-only. They never retry, hide, delete, or alter media automatically.",
        items: items
      )
    end

    def storage_section(full_storage: false)
      items = []
      profiles = configured_profiles

      profiles.each do |profile_key|
        health = ::MediaGallery::StorageHealth.health(profile: profile_key)
        ok = ActiveModel::Type::Boolean.new.cast(health[:ok])
        items << issue(
          id: "storage_profile_#{profile_key}",
          label: "#{health[:label].presence || profile_key} availability",
          severity: ok ? "ok" : "critical",
          count: ok ? 0 : 1,
          message: ok ? "Storage profile is available." : "Storage profile is unavailable or misconfigured.",
          detail: Array(health[:validation_errors]).presence&.join(", ") || health[:availability_error].to_s.presence || "Backend: #{health[:backend].presence || 'unknown'}",
          metadata: {
            profile_key: profile_key,
            backend: health[:backend],
            availability_ms: health[:availability_ms],
          }.compact
        )
      end

      if full_storage
        raw_missing = missing_asset_examples(limit: setting_int(:media_gallery_health_ready_asset_sample_limit, 40))
        store_full_storage_check!(raw_missing)
        active_missing = active_missing_rows(raw_missing)
        ignored_count = ignored_matching_rows(raw_missing).length
        checked_at = Time.zone.now.iso8601

        items << issue(
          id: "missing_ready_assets",
          label: "Ready item asset check",
          severity: active_missing.present? ? "critical" : "ok",
          count: active_missing.length,
          message: active_missing.present? ? "#{active_missing.length} ready media item#{'s' if active_missing.length != 1} have missing required asset files." : "No missing required files found in the sampled ready items.",
          detail: full_storage_detail(raw_missing.length, active_missing.length, ignored_count, checked_at: checked_at),
          examples: active_missing.first(10),
          metadata: { checked_at: checked_at, full_storage: true }
        )
      elsif (cached = last_full_storage_check).present?
        raw_missing = Array(cached["missing_assets"])
        active_missing = active_missing_rows(raw_missing)
        ignored_count = ignored_matching_rows(raw_missing).length
        checked_at = cached["checked_at"].to_s.presence

        items << issue(
          id: "missing_ready_assets_cached",
          label: "Last full ready item asset check",
          severity: active_missing.present? ? "critical" : "ok",
          count: active_missing.length,
          message: active_missing.present? ? "The last full storage check found #{active_missing.length} ready media item#{'s' if active_missing.length != 1} with missing required asset files." : "The last full storage check has no active missing-file findings.",
          detail: full_storage_detail(raw_missing.length, active_missing.length, ignored_count, checked_at: checked_at, cached: true),
          examples: active_missing.first(10),
          metadata: { checked_at: checked_at, full_storage: false, cached: true }
        )
      else
        ready_count = safe_count(::MediaGallery::MediaItem.where(status: "ready"))
        items << issue(
          id: "ready_asset_check_not_run",
          label: "Ready item asset check",
          severity: "ok",
          count: ready_count,
          message: "Full ready-asset verification has not been run yet.",
          detail: "Use Run full storage check to verify a bounded sample of ready items. The result is kept on this page until the next full check, so refreshes keep showing the latest storage findings."
        )
      end

      ignored_count = ignored_findings_hash.length
      if ignored_count.positive?
        items << issue(
          id: "ignored_storage_findings",
          label: "Ignored storage findings",
          severity: "ok",
          count: ignored_count,
          message: "#{ignored_count} storage finding#{'s' if ignored_count != 1} ignored by admins.",
          detail: "Ignored findings are listed separately on this page and can be restored with Unignore."
        )
      end

      section(
        id: "storage",
        title: "Storage health",
        description: "Check configured storage profiles and sampled asset availability.",
        help: "The regular watchdog performs light storage checks and reuses the latest full storage result. Run full storage check to refresh the stored missing-file findings. Ignored findings are excluded from warning and critical status.",
        items: items
      )
    end

    def reconciliation_section
      cached = last_reconciliation
      if cached.blank?
        return section(
          id: "storage_reconciliation",
          title: "Storage reconciliation",
          description: "Review whether database records and storage objects still match.",
          help: "Run storage reconciliation to detect missing assets, orphan candidates, deleted media leftovers, and invalid storage references. This first iteration is read-only and never deletes files.",
          items: [
            issue(
              id: "storage_reconciliation_not_run",
              label: "Storage reconciliation",
              severity: "ok",
              count: 0,
              message: "Storage reconciliation has not been run yet.",
              detail: "Use Run storage reconciliation to perform a bounded read-only scan. Results are cached until the next run and can be exported."
            ),
          ]
        )
      end

      categories = Array(cached["categories"])
      items = categories.map do |category|
        all_findings = Array(category["findings"])
        active_findings = active_reconciliation_rows(all_findings)
        ignored_count = ignored_matching_rows(all_findings).length
        severity = active_findings.present? ? highest_severity(active_findings.map { |row| row["severity"] || row[:severity] }) : "ok"
        issue(
          id: "reconciliation_#{category["id"]}",
          label: category["title"].to_s.presence || category["id"].to_s.titleize,
          severity: severity,
          count: active_findings.length,
          message: reconciliation_category_message(category, active_findings.length, ignored_count),
          detail: reconciliation_category_detail(category, cached, ignored_count),
          examples: active_findings.first(10),
          metadata: { checked_at: cached["generated_at"], read_only: true, category_id: category["id"] }
        )
      end

      if Array(cached.dig("stats", "truncated_profiles")).present?
        items << issue(
          id: "reconciliation_scan_truncated",
          label: "Bounded storage scan",
          severity: "warning",
          count: Array(cached.dig("stats", "truncated_profiles")).length,
          message: "One or more storage profiles reached the scan limit.",
          detail: "Profiles: #{truncated_profile_names(cached).join(', ')}. Increase the reconciliation object limit only after considering performance impact.",
          metadata: { checked_at: cached["generated_at"], read_only: true }
        )
      end

      section(
        id: "storage_reconciliation",
        title: "Storage reconciliation",
        description: "Detect missing assets, orphan candidates, deleted media leftovers, and invalid storage references.",
        help: "This section is read-only. It stores the latest bounded reconciliation result for review and export. Cleanup is intentionally not available in this iteration.",
        items: items.presence || [
          issue(
            id: "storage_reconciliation_ok",
            label: "Storage reconciliation",
            severity: "ok",
            count: 0,
            message: "The latest reconciliation result has no active findings.",
            detail: "Ignored findings remain available in the ignored findings panel."
          )
        ]
      )
    end

    def run_reconciliation!
      report = ::MediaGallery::StorageReconciler.run(
        item_limit: setting_int(:media_gallery_health_reconciliation_item_limit, 500),
        object_limit: setting_int(:media_gallery_health_reconciliation_object_limit, 2000),
        orphan_sample_limit: setting_int(:media_gallery_health_reconciliation_orphan_sample_limit, 50)
      )
      store_reconciliation!(report)
      record_log_event(
        event_type: "media_gallery_storage_reconciliation_run",
        severity: report[:severity].to_s == "critical" ? "error" : (report[:severity].to_s == "warning" ? "warning" : "info"),
        message: "Media Gallery storage reconciliation completed.",
        details: {
          severity: report[:severity],
          duration_ms: report[:duration_ms],
          stats: report[:stats],
          counts: Array(report[:categories]).to_h { |category| [category[:id], category[:count]] },
        }
      )
      report
    end

    def store_reconciliation!(report)
      previous = last_reconciliation
      stored = report.deep_stringify_keys
      current_keys = active_reconciliation_keys(stored)
      previous_keys = active_reconciliation_keys(previous)
      diff = reconciliation_diff_payload(current_keys: current_keys, previous_keys: previous_keys)
      stored["diff"] = diff

      ::PluginStore.set(STORE_NAMESPACE, LAST_RECONCILIATION_KEY, stored)
      store_reconciliation_history_entry!(stored, diff)
      true
    rescue => e
      Rails.logger.warn("[media_gallery] storing storage reconciliation result failed: #{e.class}: #{e.message}")
      false
    end

    def last_reconciliation
      value = ::PluginStore.get(STORE_NAMESPACE, LAST_RECONCILIATION_KEY)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    rescue
      {}
    end

    def last_reconciliation_summary
      cached = last_reconciliation
      return nil if cached.blank?

      categories = Array(cached["categories"])
      active_count = categories.sum { |category| active_reconciliation_rows(Array(category["findings"])).length }
      ignored_count = categories.sum { |category| ignored_matching_rows(Array(category["findings"])).length }
      {
        generated_at: cached["generated_at"],
        generated_at_label: cached["generated_at_label"],
        severity: cached["severity"],
        read_only: true,
        cleanup_available: false,
        active_findings_count: active_count,
        ignored_findings_count: ignored_count,
        new_findings_count: cached.dig("diff", "new_findings_count").to_i,
        resolved_findings_count: cached.dig("diff", "resolved_findings_count").to_i,
        duration_ms: cached["duration_ms"],
        stats: cached["stats"] || {},
        profiles: cached["profiles"] || {},
        limits: cached["limits"] || {},
        categories: reconciliation_category_summaries(categories),
      }
    end

    def reconciliation_category_summaries(categories)
      Array(categories).map do |category|
        findings = Array(category["findings"])
        active_rows = active_reconciliation_rows(findings)
        ignored_rows = ignored_matching_rows(findings)
        {
          id: category["id"].to_s,
          title: category["title"].to_s.presence || category["id"].to_s.titleize,
          severity: category["severity"].to_s.presence || "ok",
          count: findings.length,
          active_count: active_rows.length,
          ignored_count: ignored_rows.length,
        }
      end
    end

    def active_reconciliation_rows(rows)
      ignored = ignored_findings_hash
      Array(rows).reject { |row| ignored.key?(row_key(row)) }
    end

    def active_reconciliation_keys(report)
      Array(report&.dig("categories")).flat_map do |category|
        active_reconciliation_rows(Array(category["findings"])).map { |row| row_key(row) }
      end.compact.uniq.sort
    rescue
      []
    end

    def reconciliation_diff_payload(current_keys:, previous_keys:)
      current = Array(current_keys).to_set
      previous = Array(previous_keys).to_set
      new_keys = (current - previous).to_a.sort
      resolved_keys = (previous - current).to_a.sort
      {
        "new_findings_count" => new_keys.length,
        "resolved_findings_count" => resolved_keys.length,
        "new_finding_keys" => new_keys.first(50),
        "resolved_finding_keys" => resolved_keys.first(50),
      }
    end

    def store_reconciliation_history_entry!(report, diff)
      history = reconciliation_history_raw
      entry = reconciliation_history_entry(report, diff)
      history.unshift(entry)
      compacted = history.uniq { |row| row["generated_at"].to_s }.first(10)
      ::PluginStore.set(STORE_NAMESPACE, RECONCILIATION_HISTORY_KEY, compacted)
    rescue => e
      Rails.logger.warn("[media_gallery] storing storage reconciliation history failed: #{e.class}: #{e.message}")
    end

    def reconciliation_history_entry(report, diff)
      categories = Array(report["categories"])
      active_count = categories.sum { |category| active_reconciliation_rows(Array(category["findings"])).length }
      ignored_count = categories.sum { |category| ignored_matching_rows(Array(category["findings"])).length }
      {
        "generated_at" => report["generated_at"].to_s,
        "finished_at" => report["finished_at"].to_s,
        "severity" => report["severity"].to_s.presence || "ok",
        "duration_ms" => report["duration_ms"].to_i,
        "active_findings_count" => active_count,
        "ignored_findings_count" => ignored_count,
        "new_findings_count" => diff["new_findings_count"].to_i,
        "resolved_findings_count" => diff["resolved_findings_count"].to_i,
        "items_checked" => report.dig("stats", "items_checked").to_i,
        "objects_scanned" => report.dig("stats", "objects_scanned").to_i,
        "profile_labels" => checked_profile_labels(report).first(8),
        "truncated_profile_labels" => Array(report.dig("stats", "truncated_profile_labels")).map(&:to_s).reject(&:blank?).first(8),
      }.compact
    end

    def reconciliation_history
      reconciliation_history_raw.map do |entry|
        entry.slice(
          "generated_at",
          "finished_at",
          "severity",
          "duration_ms",
          "active_findings_count",
          "ignored_findings_count",
          "new_findings_count",
          "resolved_findings_count",
          "items_checked",
          "objects_scanned",
          "profile_labels",
          "truncated_profile_labels"
        )
      end
    rescue
      []
    end

    def reconciliation_history_raw
      value = ::PluginStore.get(STORE_NAMESPACE, RECONCILIATION_HISTORY_KEY)
      value.is_a?(Array) ? value.map { |row| row.is_a?(Hash) ? row.deep_stringify_keys : {} }.reject(&:blank?) : []
    rescue
      []
    end

    def checked_profile_labels(report)
      profiles = report["profiles"].is_a?(Hash) ? report["profiles"] : {}
      checked = Array(profiles["checked"]) + Array(profiles[:checked])
      checked.filter_map do |profile|
        next unless profile.is_a?(Hash)
        profile["label"].to_s.presence || profile[:label].to_s.presence || profile["name"].to_s.presence || profile[:name].to_s.presence
      end.uniq
    rescue
      []
    end

    def reconciliation_export_payload(category: nil, include_ignored: false)
      cached = last_reconciliation
      return {} if cached.blank?

      report = cached.deep_dup
      report["categories"] = filtered_reconciliation_categories(
        Array(report["categories"]),
        category: category,
        include_ignored: include_ignored
      )
      report["export_filter"] = {
        "category" => category.to_s.presence || "all",
        "include_ignored" => !!include_ignored,
      }
      report
    end

    def filtered_reconciliation_categories(categories, category:, include_ignored:)
      requested = category.to_s.strip
      Array(categories).filter_map do |entry|
        next if requested.present? && requested != "all" && entry["id"].to_s != requested

        copy = entry.deep_dup
        rows = Array(copy["findings"])
        copy["findings"] = include_ignored ? rows : active_reconciliation_rows(rows)
        copy["count"] = copy["findings"].length
        copy
      end
    end

    def reconciliation_export_csv(category: nil, include_ignored: false)
      report = reconciliation_export_payload(category: category, include_ignored: include_ignored)
      CSV.generate(headers: true) do |csv|
        csv << [
          "category",
          "severity",
          "issue_type",
          "label",
          "public_id",
          "title",
          "status",
          "profile",
          "backend",
          "role",
          "storage_key",
          "missing",
          "detail",
          "suggestion",
          "url",
          "key",
        ]
        Array(report["categories"]).each do |category_row|
          Array(category_row["findings"]).each do |finding|
            csv << [
              category_row["title"].to_s.presence || category_row["id"].to_s,
              finding["severity"],
              finding["issue_type"],
              finding["label"],
              finding["public_id"],
              finding["title"],
              finding["status"],
              finding["profile_label"].to_s.presence || finding["profile_display_label"].to_s.presence || finding["profile_key"],
              finding["backend"],
              finding["role"],
              finding["storage_key"],
              finding["missing"],
              finding["detail"],
              finding["suggestion"],
              finding["url"],
              finding["key"],
            ]
          end
        end
      end
    end

    def truncated_profile_names(cached)
      names = Array(cached.dig("stats", "truncated_profile_labels")).map(&:to_s).reject(&:blank?)
      return names if names.present?

      Array(cached.dig("stats", "truncated_profiles")).map(&:to_s).reject(&:blank?)
    end

    def reconciliation_category_message(category, active_count, ignored_count)
      title = category["title"].to_s.presence || category["id"].to_s.titleize
      if active_count.positive?
        "#{active_count} active #{title.downcase} finding#{'s' if active_count != 1}."
      else
        "No active #{title.downcase} findings."
      end.tap do |message|
        message << " #{ignored_count} ignored." if ignored_count.positive?
      end
    end

    def reconciliation_category_detail(category, cached, ignored_count)
      checked_at = cached["generated_at_label"].to_s.presence || cached["generated_at"].to_s
      description = category["description"].to_s.presence
      limits = cached["limits"] || {}
      limit_text = "Items checked: #{cached.dig("stats", "items_checked").to_i}; objects scanned: #{cached.dig("stats", "objects_scanned").to_i}; object limit: #{limits["object_limit"].presence || 'n/a'}."
      ignored_text = ignored_count.positive? ? " Ignored findings are excluded from the health status." : ""
      [description, "Last run: #{checked_at}.", limit_text + ignored_text, "No cleanup is performed from this page."].compact.join(" ")
    end

    def settings_section
      items = []
      items.concat(group_setting_issues)
      items.concat(url_setting_issues)
      items.concat(mode_setting_issues)

      items << issue(
        id: "processing_notifications_setting",
        label: "Uploader processing notifications",
        severity: processing_notifications_enabled? ? "ok" : "warning",
        count: processing_notifications_enabled? ? 0 : 1,
        message: processing_notifications_enabled? ? "Uploaders are notified when processing finishes or fails." : "Uploader processing notifications are disabled.",
        detail: "Keeping this enabled helps users know when asynchronous processing completes."
      )

      section(
        id: "settings",
        title: "Settings health",
        description: "Validate common Media Gallery configuration values.",
        help: "These checks find missing groups, invalid modes, and URL settings that would make UI notices or moderation alerts fail.",
        items: items.presence || [issue(id: "settings_ok", label: "Settings", severity: "ok", message: "No obvious configuration issues found.")]
      )
    end

    def permissions_section
      viewer_groups = ::MediaGallery::Permissions.viewer_groups
      uploader_groups = ::MediaGallery::Permissions.uploader_groups
      blocked_groups = ::MediaGallery::Permissions.blocked_groups

      items = []
      items << issue(
        id: "viewer_policy",
        label: "Viewer policy",
        severity: "ok",
        message: viewer_groups.blank? ? "All logged-in users may view the media library." : "Viewing is limited to #{viewer_groups.join(', ')}.",
        detail: "Blocked groups always take precedence for regular users."
      )
      items << issue(
        id: "uploader_policy",
        label: "Uploader policy",
        severity: "ok",
        message: uploader_groups.blank? ? "All logged-in users may upload to the media library." : "Uploading is limited to #{uploader_groups.join(', ')}.",
        detail: "Staff/admin users are allowed to manage and recover access."
      )
      items << issue(
        id: "blocked_policy",
        label: "Blocked media groups",
        severity: "ok",
        count: blocked_groups.length,
        message: blocked_groups.present? ? "#{blocked_groups.length} blocked group#{'s' if blocked_groups.length != 1} configured." : "No explicit blocked media groups configured.",
        detail: blocked_groups.present? ? "Members of these groups cannot view or upload media unless they are staff/admin. This is informational and does not indicate a problem." : "This is allowed, but no explicit exclusion group is active."
      )

      section(
        id: "permissions",
        title: "Permissions health",
        description: "Summarize viewer, uploader, and block rules.",
        help: "This is a policy summary, not a per-user access debugger.",
        items: items
      )
    end

    def reports_section
      report_items = ::MediaGallery::MediaItem.where("jsonb_typeof(extra_metadata -> ?) = 'array'", "media_reports")
      open_count = 0
      closed_count = 0
      old_open = []

      report_items.limit(1000).to_a.each do |item|
        reports = item.extra_metadata_hash["media_reports"]
        next unless reports.is_a?(Array)

        reports.each do |report|
          next unless report.is_a?(Hash)
          if report["status"].to_s == "open"
            open_count += 1
            created = parse_time(report["created_at"])
            if created.present? && created < 3.days.ago
              old_open << {
                public_id: item.public_id,
                title: item.title.to_s.presence || "Untitled media",
                status: "open",
                created_at: report["created_at"],
                age: human_age(created),
                url: "/admin/plugins/media-gallery-reports",
              }
            end
          else
            closed_count += 1
          end
        end
      end

      items = []
      items << issue(
        id: "open_reports",
        label: "Open reports",
        severity: open_count.positive? ? "warning" : "ok",
        count: open_count,
        message: open_count.positive? ? "#{open_count} open media report#{'s' if open_count != 1} need review." : "No open media reports.",
        detail: "Open reports are expected if users recently reported content.",
        examples: old_open.first(5)
      )
      items << issue(
        id: "old_open_reports",
        label: "Old open reports",
        severity: old_open.present? ? "warning" : "ok",
        count: old_open.length,
        message: old_open.present? ? "Some reports have been open longer than 3 days." : "No reports older than 3 days are still open.",
        detail: "Older open reports may need staff review or closure.",
        examples: old_open.first(5)
      )
      items << issue(
        id: "closed_reports",
        label: "Closed reports",
        severity: "ok",
        count: closed_count,
        message: "#{closed_count} reviewed media report#{'s' if closed_count != 1} retained for audit.",
        detail: "Closed reports stay available on the reports page."
      )

      section(
        id: "reports",
        title: "Reports and moderation health",
        description: "Summarize open media reports and moderation backlog.",
        help: "Report checks do not change visibility. Auto-hide decisions happen when reports are created, not from this health page.",
        items: items
      )
    end

    def missing_asset_examples(limit:)
      rows = []
      ::MediaGallery::MediaItem.where(status: "ready").order(updated_at: :desc).limit(limit).find_each do |item|
        missing = missing_roles_for(item)
        next if missing.blank?

        rows << missing_asset_row(item, missing)
      rescue => e
        rows << {
          key: ignore_key_for("missing_ready_asset", item.public_id),
          issue_type: "missing_ready_asset",
          public_id: item.public_id,
          title: item.title.to_s.presence || "Untitled media",
          status: item.status,
          missing: "check failed",
          detail: "#{e.class}: #{e.message}".truncate(300),
          updated_at: item.updated_at&.iso8601,
          url: management_url_for(item.public_id),
          can_ignore: true,
        }
      end
      rows
    end

    def missing_asset_row(item, missing)
      {
        key: ignore_key_for("missing_ready_asset", item.public_id),
        issue_type: "missing_ready_asset",
        public_id: item.public_id,
        title: item.title.to_s.presence || "Untitled media",
        status: item.status,
        missing: missing.join(", "),
        updated_at: item.updated_at&.iso8601,
        url: management_url_for(item.public_id),
        can_ignore: true,
      }
    end

    def missing_roles_for(item)
      missing = []

      if item.media_type.to_s == "video" && ::MediaGallery::AssetManifest.role_for(item, "hls").present?
        missing << "hls" unless role_available?(item, "hls")
      else
        missing << "main" unless role_available?(item, "main")
      end

      if item.media_type.to_s != "audio"
        missing << "thumbnail" unless role_available?(item, "thumbnail")
      end

      missing
    end

    def management_url_for(public_id)
      encoded = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-management?q=#{encoded}&public_id=#{encoded}"
    end

    def role_available?(item, role_name)
      role = ::MediaGallery::AssetManifest.role_for(item, role_name)
      return false unless role.is_a?(Hash)

      backend = role["backend"].to_s
      case backend
      when "upload"
        upload_id = role["upload_id"].presence
        return false if upload_id.blank?
        ::Upload.exists?(id: upload_id)
      when "local", "s3"
        profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
        return false if store.blank?

        if role_name.to_s == "hls"
          master_key = role["master_key"].to_s.presence || File.join(item.public_id.to_s, "hls", "master.m3u8")
          complete_key = role["complete_key"].to_s.presence
          return false unless store.exists?(master_key)
          return complete_key.blank? || store.exists?(complete_key)
        end

        key = role["key"].to_s.presence
        key.present? && store.exists?(key)
      else
        false
      end
    end

    def group_setting_issues
      definitions = [
        ["media_gallery_viewer_groups", "Viewer groups", safe_setting(:media_gallery_viewer_groups), true],
        ["media_gallery_allowed_uploader_groups", "Uploader groups", safe_setting(:media_gallery_allowed_uploader_groups), true],
        ["media_gallery_blocked_groups", "Blocked groups", safe_setting(:media_gallery_blocked_groups), true],
        ["media_gallery_quick_block_group", "Quick block group", safe_setting(:media_gallery_quick_block_group), false],
        ["media_gallery_report_auto_hide_groups", "Report auto-hide groups", safe_setting(:media_gallery_report_auto_hide_groups), true],
        ["media_gallery_report_notify_group", "Report notify group", safe_setting(:media_gallery_report_notify_group), false],
        ["media_gallery_health_notify_group", "Health notify group", safe_setting(:media_gallery_health_notify_group), false],
      ]

      definitions.flat_map do |setting_id, label, value, allow_trust_and_staff|
        missing = missing_groups(value, allow_trust_and_staff: allow_trust_and_staff)
        next [] if missing.blank?

        [issue(
          id: "missing_group_#{setting_id}",
          label: label,
          severity: "warning",
          count: missing.length,
          message: "Unknown group#{'s' if missing.length != 1}: #{missing.join(', ')}.",
          detail: "Check the site setting #{setting_id}."
        )]
      end.compact
    end

    def missing_groups(value, allow_trust_and_staff: true)
      names = ::MediaGallery::Permissions.list_setting(value).map(&:downcase)
      names.reject do |name|
        next true if name.blank?
        next true if allow_trust_and_staff && trust_level_group?(name)
        next true if allow_trust_and_staff && %w[staff admins moderators].include?(name)

        ::Group.where("lower(name) = ?", name).exists?
      end
    end

    def url_setting_issues
      terms_url = safe_setting(:media_gallery_upload_terms_url).to_s.strip
      notice_enabled = !SiteSetting.respond_to?(:media_gallery_library_notice_enabled) || SiteSetting.media_gallery_library_notice_enabled
      items = []

      if terms_url.present? && !safe_url?(terms_url)
        items << issue(
          id: "invalid_terms_url",
          label: "Upload terms URL",
          severity: "warning",
          message: "The upload terms URL does not look safe or valid.",
          detail: "Use https://, http://, or a local /path URL."
        )
      elsif notice_enabled && terms_url.blank?
        items << issue(
          id: "missing_notice_terms_url",
          label: "Library notice link",
          severity: "warning",
          message: "The library notice is enabled, but no upload terms URL is configured.",
          detail: "The notice link needs media_gallery_upload_terms_url."
        )
      end

      items
    end

    def mode_setting_issues
      items = []
      duplicate_action = safe_setting(:media_gallery_duplicate_upload_action).to_s.presence || "allow"
      unless %w[allow warn block].include?(duplicate_action)
        items << issue(
          id: "invalid_duplicate_action",
          label: "Duplicate upload action",
          severity: "warning",
          message: "Duplicate upload action is invalid: #{duplicate_action}.",
          detail: "Use allow, warn, or block."
        )
      end
      items
    end

    def section(id:, title:, description:, help:, items:)
      {
        id: id,
        title: title,
        description: description,
        help: help,
        severity: highest_severity(Array(items).map { |item| item[:severity] }),
        items: items,
      }
    end

    def issue(id:, label:, severity:, message:, detail: nil, count: nil, examples: nil, metadata: nil)
      {
        id: id,
        label: label,
        severity: normalize_severity(severity),
        message: message,
        detail: detail,
        count: count,
        examples: Array(examples).compact,
        metadata: metadata || {},
      }.compact
    end

    def attention_issues(sections)
      Array(sections).flat_map do |section|
        Array(section[:items]).filter_map do |item|
          next if item[:severity].to_s == "ok"

          item.merge(
            section_id: section[:id].to_s,
            section_title: section[:title].to_s.presence || section[:id].to_s.titleize
          )
        end
      end
    end

    def summary_cards(sections, issues)
      processing = sections.find { |s| s[:id] == "processing" }
      storage = sections.find { |s| s[:id] == "storage" }
      reconciliation = sections.find { |s| s[:id] == "storage_reconciliation" }
      reports = sections.find { |s| s[:id] == "reports" }

      [
        {
          label: "Overall status",
          value: highest_severity(sections.map { |section| section[:severity] }).titleize,
          severity: highest_severity(sections.map { |section| section[:severity] }),
        },
        {
          label: "Open issues",
          value: issues.length,
          severity: issues.any? ? highest_severity(issues.map { |issue| issue[:severity] }) : "ok",
        },
        {
          label: "Processing",
          value: processing&.dig(:severity).to_s.titleize,
          severity: processing&.dig(:severity) || "ok",
        },
        {
          label: "Storage",
          value: storage&.dig(:severity).to_s.titleize,
          severity: storage&.dig(:severity) || "ok",
        },
        {
          label: "Reconciliation",
          value: reconciliation&.dig(:severity).to_s.titleize,
          severity: reconciliation&.dig(:severity) || "ok",
        },
        {
          label: "Reports",
          value: reports&.dig(:severity).to_s.titleize,
          severity: reports&.dig(:severity) || "ok",
        },
      ]
    end

    def example_items(scope, now: Time.zone.now)
      scope.map do |item|
        base_time = item.status.to_s == "queued" ? item.created_at : item.updated_at
        {
          public_id: item.public_id,
          title: item.title.to_s.presence || "Untitled media",
          status: item.status,
          updated_at: item.updated_at&.iso8601,
          age: human_age(base_time),
          error: item.error_message.to_s.presence,
          url: management_url_for(item.public_id),
        }.compact
      end
    end

    def ignore_finding!(params, user:)
      key = params[:key].to_s.strip
      public_id = params[:public_id].to_s.strip
      issue_type = params[:issue_type].to_s.strip.presence || "missing_ready_asset"

      if key.blank? && public_id.present?
        key = ignore_key_for(issue_type, public_id)
      end

      raise Discourse::InvalidParameters.new(:key) unless valid_ignore_key?(key)

      ignored = ignored_findings_hash
      expires_at = ignore_expires_at(params[:expires_in_days])
      ignored[key] = {
        "key" => key,
        "issue_type" => issue_type,
        "public_id" => public_id.presence || key.split(":").last,
        "title" => params[:title].to_s.strip.truncate(200),
        "reason" => ::MediaGallery::TextSanitizer.plain_text(params[:reason].to_s, max_length: 500, allow_newlines: true).presence,
        "ignored_at" => Time.zone.now.iso8601,
        "ignored_by_user_id" => user&.id,
        "ignored_by_username" => user&.username,
        "expires_at" => expires_at&.iso8601,
      }.compact
      ::PluginStore.set(STORE_NAMESPACE, IGNORED_FINDINGS_KEY, ignored)
      true
    end

    def unignore_finding!(params)
      key = params[:key].to_s.strip
      public_id = params[:public_id].to_s.strip
      issue_type = params[:issue_type].to_s.strip.presence || "missing_ready_asset"
      key = ignore_key_for(issue_type, public_id) if key.blank? && public_id.present?
      raise Discourse::InvalidParameters.new(:key) unless valid_ignore_key?(key)

      ignored = ignored_findings_hash
      ignored.delete(key)
      ::PluginStore.set(STORE_NAMESPACE, IGNORED_FINDINGS_KEY, ignored)
      true
    end

    def ignored_findings_for_ui
      ignored_findings_hash.values.map do |entry|
        public_id = entry["public_id"].to_s
        item = public_id.present? ? ::MediaGallery::MediaItem.find_by(public_id: public_id) : nil
        title = item&.title.to_s.presence || entry["title"].to_s.presence || "Media item"
        {
          key: entry["key"].to_s,
          issue_type: entry["issue_type"].to_s.presence || "missing_ready_asset",
          public_id: public_id,
          title: title,
          ignored_at: entry["ignored_at"],
          ignored_by_username: entry["ignored_by_username"],
          expires_at: entry["expires_at"].to_s.presence,
          reason: entry["reason"].to_s.presence,
          url: public_id.present? ? management_url_for(public_id) : nil,
        }.compact
      end.sort_by { |entry| entry[:ignored_at].to_s }.reverse
    rescue
      []
    end

    def ignored_findings_hash
      value = ::PluginStore.get(STORE_NAMESPACE, IGNORED_FINDINGS_KEY)
      ignored = value.is_a?(Hash) ? value.deep_stringify_keys : {}
      active = ignored.reject { |_key, entry| ignored_entry_expired?(entry) }
      if active.length != ignored.length
        ::PluginStore.set(STORE_NAMESPACE, IGNORED_FINDINGS_KEY, active)
      end
      active
    rescue
      {}
    end

    def ignored_entry_expired?(entry)
      expires_at = entry.is_a?(Hash) ? entry["expires_at"].to_s.presence : nil
      return false if expires_at.blank?

      Time.zone.parse(expires_at) < Time.zone.now
    rescue
      false
    end

    def ignore_expires_at(value)
      days = value.to_i
      return nil unless days.positive?

      days = [days, 365].min
      Time.zone.now + days.days
    rescue
      nil
    end

    def store_full_storage_check!(missing_rows)
      ::PluginStore.set(
        STORE_NAMESPACE,
        LAST_FULL_STORAGE_CHECK_KEY,
        {
          "checked_at" => Time.zone.now.iso8601,
          "missing_assets" => Array(missing_rows).map { |row| row.deep_stringify_keys },
        }
      )
    rescue => e
      Rails.logger.warn("[media_gallery] storing full storage health result failed: #{e.class}: #{e.message}")
    end

    def last_full_storage_check
      value = ::PluginStore.get(STORE_NAMESPACE, LAST_FULL_STORAGE_CHECK_KEY)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    rescue
      {}
    end

    def last_full_storage_check_summary
      cached = last_full_storage_check
      return nil if cached.blank?

      raw_missing = Array(cached["missing_assets"])
      {
        checked_at: cached["checked_at"],
        raw_missing_count: raw_missing.length,
        active_missing_count: active_missing_rows(raw_missing).length,
        ignored_missing_count: ignored_matching_rows(raw_missing).length,
      }
    end

    def active_missing_rows(rows)
      ignored = ignored_findings_hash
      Array(rows).reject { |row| ignored.key?(row_key(row)) }
    end

    def ignored_matching_rows(rows)
      ignored = ignored_findings_hash
      Array(rows).select { |row| ignored.key?(row_key(row)) }
    end

    def row_key(row)
      data = row.respond_to?(:deep_stringify_keys) ? row.deep_stringify_keys : row
      data["key"].to_s.presence || ignore_key_for(data["issue_type"].presence || "missing_ready_asset", data["public_id"])
    end

    def ignore_key_for(issue_type, public_id)
      safe_type = issue_type.to_s.gsub(/[^a-z0-9_:-]/i, "_").downcase.presence || "missing_ready_asset"
      safe_public_id = public_id.to_s.gsub(/[^a-z0-9_-]/i, "")
      "#{safe_type}:#{safe_public_id}"
    end

    def valid_ignore_key?(key)
      key.to_s.match?(/\A[a-z0-9_:-]{8,180}\z/)
    end

    def full_storage_detail(raw_count, active_count, ignored_count, checked_at:, cached: false)
      prefix = cached ? "This is the latest stored full storage result" : "This full storage check result"
      checked = checked_at.present? ? " from #{checked_at}" : ""
      ignored = ignored_count.positive? ? " #{ignored_count} finding#{'s' if ignored_count != 1} are ignored and excluded from health status." : ""
      "#{prefix}#{checked}. It found #{raw_count} total missing-file finding#{'s' if raw_count != 1}; #{active_count} active.#{ignored} Run full storage check again after fixing files to refresh this result."
    end

    def build_alert_pm_body(result, issues)
      admin_url = Discourse.base_url + "/admin/plugins/media-gallery-health"
      lines = []
      lines << "Media Gallery health detected #{result[:severity]} issues."
      lines << ""
      lines << "Review the health page: #{admin_url}"
      lines << ""
      issues.first(10).each do |issue|
        lines << "- #{issue[:label]}: #{issue[:message]}"
      end
      lines << "" if issues.length > 10
      lines << "#{issues.length - 10} more issue(s) are available on the health page." if issues.length > 10
      lines.join("\n")
    end

    def normalized_alert_issues(result)
      source_issues = Array(result[:issues]).presence
      if source_issues.present?
        return source_issues.map do |item|
          {
            section: item[:section_id].to_s.presence || item.dig(:metadata, :section_id).to_s,
            id: item[:id].to_s,
            label: item[:label].to_s,
            severity: item[:severity].to_s,
            count: item[:count].to_i,
            message: item[:message].to_s,
          }
        end
      end

      Array(result[:sections]).flat_map do |section|
        Array(section[:items]).filter_map do |item|
          next if item[:severity].to_s == "ok"

          {
            section: section[:id].to_s,
            id: item[:id].to_s,
            label: item[:label].to_s,
            severity: item[:severity].to_s,
            count: item[:count].to_i,
            message: item[:message].to_s,
          }
        end
      end
    end

    def alert_signature(severity, issues)
      source = [severity.to_s, issues.map { |i| [i[:section], i[:id], i[:severity], i[:count], i[:message]].join(":") }.join("|")].join("|")
      Digest::SHA1.hexdigest(source)
    end

    def store_alert_state(severity:, signature:, sent_at:, attempted_at:, error:, group:)
      ::PluginStore.set(
        STORE_NAMESPACE,
        LAST_ALERT_KEY,
        {
          severity: severity,
          signature: signature,
          sent_at: sent_at,
          attempted_at: attempted_at,
          error: error,
          group: group,
        }.compact
      )
    rescue => e
      Rails.logger.warn("[media_gallery] health alert state failed: #{e.class}: #{e.message}")
    end

    def configured_profiles
      profiles = ::MediaGallery::StorageSettingsResolver.configured_profiles_summary.map { |p| p[:profile_key].to_s }.compact_blank
      profiles = [::MediaGallery::StorageSettingsResolver.active_profile_key.to_s.presence || "local"] if profiles.blank?
      profiles.uniq
    rescue
      ["active"]
    end

    def processing_notifications_enabled?
      !SiteSetting.respond_to?(:media_gallery_processing_notifications_enabled) || SiteSetting.media_gallery_processing_notifications_enabled
    end

    def safe_url?(value)
      url = value.to_s.strip
      return false if url.blank?
      return true if url.start_with?("/") && !url.start_with?("//")
      uri = URI.parse(url)
      %w[http https].include?(uri.scheme.to_s.downcase) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def trust_level_group?(name)
      name.to_s.match?(/\Atrust_level_[0-4]\z/)
    end

    def safe_count(scope)
      scope.count
    rescue
      0
    end

    def setting_int(name, fallback)
      return fallback unless SiteSetting.respond_to?(name)
      value = SiteSetting.public_send(name).to_i
      value.positive? ? value : fallback
    rescue
      fallback
    end

    def safe_setting(name)
      return nil unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name)
    rescue
      nil
    end

    def min_notify_severity
      value = safe_setting(:media_gallery_health_notify_min_severity).to_s.strip.downcase
      VALID_NOTIFY_SEVERITIES.include?(value) ? value : "warning"
    end

    def notify_group_name
      ::MediaGallery::TextSanitizer.plain_text(
        safe_setting(:media_gallery_health_notify_group).presence || "admins",
        max_length: 100,
        allow_newlines: false
      ).to_s.strip
    end

    def processing_stale_after_minutes
      setting_int(:media_gallery_processing_stale_after_minutes, 240)
    end

    def normalize_severity(value)
      severity = value.to_s.downcase
      SEVERITY_ORDER.key?(severity) ? severity : "ok"
    end

    def highest_severity(values)
      Array(values).map { |v| normalize_severity(v) }.max_by { |v| SEVERITY_ORDER[v] } || "ok"
    end

    def severity_value(value)
      SEVERITY_ORDER[normalize_severity(value)] || 0
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue
      nil
    end

    def human_age(value)
      time = parse_time(value)
      return nil if time.blank?
      seconds = (Time.zone.now - time).to_i
      return "just now" if seconds < 60
      minutes = seconds / 60
      return "#{minutes}m" if minutes < 60
      hours = minutes / 60
      return "#{hours}h" if hours < 48
      days = hours / 24
      "#{days}d"
    end

    def record_log_event(event_type:, severity:, message:, details: nil)
      return unless defined?(::MediaGallery::LogEvents)
      ::MediaGallery::LogEvents.record(
        event_type: event_type,
        severity: severity,
        category: "health",
        message: message,
        details: details || {}
      )
    rescue
      nil
    end
  end
end
