# frozen_string_literal: true

require "cgi"
require "digest/sha1"
require "time"
require "uri"

module ::MediaGallery
  module HealthCheck
    module_function

    STORE_NAMESPACE = "media_gallery_health"
    LAST_ALERT_KEY = "last_alert"
    SEVERITY_ORDER = { "ok" => 0, "warning" => 1, "critical" => 2 }.freeze
    VALID_NOTIFY_SEVERITIES = %w[warning critical].freeze

    def summary(full_storage: false)
      started_at = Time.zone.now
      sections = []

      sections << processing_section
      sections << storage_section(full_storage: full_storage)
      sections << settings_section
      sections << permissions_section
      sections << reports_section

      severity = highest_severity(sections.map { |section| section[:severity] })
      issues = sections.flat_map { |section| Array(section[:items]).select { |item| item[:severity].to_s != "ok" } }

      {
        ok: severity == "ok",
        severity: severity,
        generated_at: started_at.iso8601,
        generated_at_label: started_at.strftime("%Y-%m-%d %H:%M:%S"),
        full_storage: !!full_storage,
        summary_cards: summary_cards(sections, issues),
        sections: sections,
        alert_state: last_alert_state,
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
        alert_state: last_alert_state,
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
        missing = missing_asset_examples(limit: setting_int(:media_gallery_health_ready_asset_sample_limit, 40))
        items << issue(
          id: "missing_ready_assets",
          label: "Ready item asset check",
          severity: missing.present? ? "critical" : "ok",
          count: missing.length,
          message: missing.present? ? "Ready media items have missing or incomplete stored assets." : "Sampled ready media items have required assets.",
          detail: "This full check verifies a bounded sample of ready items against their active storage profile.",
          examples: missing.first(8)
        )
      else
        ready_count = safe_count(::MediaGallery::MediaItem.where(status: "ready"))
        items << issue(
          id: "ready_asset_check_not_run",
          label: "Ready item asset check",
          severity: "ok",
          count: ready_count,
          message: "Full ready-asset verification was not run for this refresh.",
          detail: "Use Run full storage check to verify a bounded sample of ready items. The scheduled watchdog keeps this light to avoid heavy S3/storage scans."
        )
      end

      section(
        id: "storage",
        title: "Storage health",
        description: "Check configured storage profiles and optional sampled asset availability.",
        help: "The regular watchdog performs light storage checks. The full storage check may call S3/local exists checks for sampled items.",
        items: items
      )
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
        severity: blocked_groups.present? ? "warning" : "ok",
        count: blocked_groups.length,
        message: blocked_groups.present? ? "#{blocked_groups.length} blocked group#{'s' if blocked_groups.length != 1} configured." : "No blocked media groups configured.",
        detail: blocked_groups.present? ? "Members of these groups cannot view or upload media unless they are staff/admin." : "Use blocked groups for explicit exclusion."
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

        rows << {
          public_id: item.public_id,
          title: item.title.to_s.presence || "Untitled media",
          status: item.status,
          missing: missing.join(", "),
          updated_at: item.updated_at&.iso8601,
          url: "/admin/plugins/media-gallery-management?public_id=#{CGI.escape(item.public_id.to_s)}",
        }
      rescue => e
        rows << {
          public_id: item.public_id,
          title: item.title.to_s.presence || "Untitled media",
          status: item.status,
          missing: "check failed",
          detail: "#{e.class}: #{e.message}".truncate(300),
          updated_at: item.updated_at&.iso8601,
          url: "/admin/plugins/media-gallery-management?public_id=#{CGI.escape(item.public_id.to_s)}",
        }
      end
      rows
    end

    def missing_roles_for(item)
      missing = []
      missing << "main" unless role_available?(item, "main")
      if item.media_type.to_s != "audio"
        missing << "thumbnail" unless role_available?(item, "thumbnail")
      end
      if item.media_type.to_s == "video" && ::MediaGallery::AssetManifest.role_for(item, "hls").present?
        missing << "hls" unless role_available?(item, "hls")
      end
      missing
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

    def summary_cards(sections, issues)
      processing = sections.find { |s| s[:id] == "processing" }
      storage = sections.find { |s| s[:id] == "storage" }
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
          url: "/admin/plugins/media-gallery-management?public_id=#{CGI.escape(item.public_id.to_s)}",
        }.compact
      end
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
