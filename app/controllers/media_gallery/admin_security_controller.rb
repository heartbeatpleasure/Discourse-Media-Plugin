# frozen_string_literal: true

module ::MediaGallery
  class AdminSecurityController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def index
      render_json_dump(security_payload)
    rescue => e
      Rails.logger.error("[media_gallery] admin security status failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("security_status_failed", status: 422, message: "Security status could not be loaded. Please check Rails logs and try again.")
    end

    private

    def security_payload
      download = download_prevention_status
      controls = security_controls(download)
      counts = controls.each_with_object(Hash.new(0)) { |control, memo| memo[control[:status].to_s] += 1 }

      {
        generated_at: Time.now.utc.iso8601,
        summary: {
          posture: posture_label(controls),
          download_prevention_level: download[:level],
          controls_total: controls.length,
          ok_count: counts["ok"],
          attention_count: counts["attention"],
          partial_count: counts["partial"],
          manual_count: counts["manual"],
        },
        controls: controls,
        download_prevention: download,
        settings: security_settings,
        storage: storage_status,
        forensics: forensics_status,
        recent_events: recent_security_events,
        links: admin_links,
      }
    end

    def security_controls(download)
      [
        control(
          "Request origin protection",
          "ok",
          "Media write and play-token requests use canonical Discourse origin checks plus the existing CSRF/same-origin request checks.",
          "Review if the site is intentionally served from more than one hostname."
        ),
        control(
          "Token confidentiality",
          "ok",
          "Playback token tracking uses hashed/redacted token identifiers in Redis/logging paths instead of exposing raw bearer tokens.",
          "Keep token TTL and binding settings aligned with your audience and network behavior."
        ),
        control(
          "Video stream fallback control",
          download[:hls_only_enabled] ? "ok" : "attention",
          download[:hls_only_enabled] ?
            "Protected video HLS-only mode is enabled; direct stream fallback is blocked for video playback." :
            "Video playback can still fall back to direct stream mode when HLS fails or is explicitly forced.",
          download[:hls_only_enabled] ? "Monitor HLS health and browser compatibility." : "Enable HLS-only mode for protected/high-value video content."
        ),
        control(
          "Watermark and fingerprinting",
          watermark_fingerprint_status,
          watermark_fingerprint_summary,
          watermark_fingerprint_action
        ),
        control(
          "Session and replay resistance",
          session_resistance_status,
          session_resistance_summary,
          "Use a balanced combination of user/session/IP binding, heartbeat and active-token limits for your audience."
        ),
        control(
          "HLS request throttling",
          hls_rate_limit_status,
          hls_rate_limit_summary,
          "Keep playlist and segment limits above normal playback needs but below abuse-friendly values."
        ),
        control(
          "Forensics export lifecycle",
          forensics_lifecycle_status,
          forensics_lifecycle_summary,
          "Keep retention aligned with privacy/compliance needs and verify export archive paths stay private."
        ),
        control(
          "Storage source validation",
          "ok",
          "Admin forensics source URLs are restricted to the canonical site and configured storage origins; configured storage profiles are shown without secrets.",
          "Re-test if custom CDN/public delivery domains are introduced later."
        ),
        control(
          "Security event logging",
          "ok",
          "Structured media gallery event logging is available for playback/security signals and admin diagnostics.",
          "Review recent events periodically and ensure production log routing/backups are in place."
        ),
      ]
    end

    def control(title, status, summary, action)
      {
        title: title,
        status: status,
        label: status_label(status),
        summary: summary,
        action: action,
      }
    end

    def posture_label(controls)
      statuses = controls.map { |control| control[:status].to_s }
      return "Needs attention" if statuses.include?("attention")
      return "Partial" if statuses.include?("partial") || statuses.include?("manual")

      "Good"
    end

    def status_label(status)
      case status.to_s
      when "ok"
        "OK"
      when "partial"
        "Partial"
      when "attention"
        "Attention"
      when "manual"
        "Manual"
      else
        status.to_s.presence || "Info"
      end
    end

    def download_prevention_status
      hls_enabled = setting_bool(:media_gallery_hls_enabled)
      hls_only_available = SiteSetting.respond_to?(:media_gallery_protected_video_hls_only)
      hls_only_enabled = hls_only_available && setting_bool(:media_gallery_protected_video_hls_only)
      watermark_enabled = setting_bool(:media_gallery_watermark_enabled)
      watermark_toggle_allowed = setting_bool(:media_gallery_watermark_user_can_toggle, default: true)
      fingerprint_enabled = setting_bool(:media_gallery_fingerprint_enabled)

      level =
        if hls_enabled && hls_only_enabled && fingerprint_enabled && watermark_enabled && !watermark_toggle_allowed
          "Strong"
        elsif hls_enabled && hls_only_enabled && (fingerprint_enabled || watermark_enabled)
          "Medium"
        elsif hls_enabled
          "Basic"
        else
          "Minimal"
        end

      {
        level: level,
        hls_enabled: hls_enabled,
        hls_only_available: hls_only_available,
        hls_only_enabled: hls_only_enabled,
        watermark_enabled: watermark_enabled,
        watermark_user_can_toggle: watermark_toggle_allowed,
        watermark_user_can_choose_preset: setting_bool(:media_gallery_watermark_user_can_choose_preset, default: true),
        fingerprint_enabled: fingerprint_enabled,
        fingerprint_layout: setting_string(:media_gallery_fingerprint_watermark_layout),
        stream_token_ttl_minutes: setting_int(:media_gallery_stream_token_ttl_minutes),
        bind_to_user: setting_bool(:media_gallery_bind_stream_to_user),
        bind_to_ip: setting_bool(:media_gallery_bind_stream_to_ip),
        bind_to_session: setting_bool(:media_gallery_bind_stream_to_session),
        revoke_enabled: setting_bool(:media_gallery_revoke_enabled),
        heartbeat_enabled: setting_bool(:media_gallery_heartbeat_enabled),
        max_concurrent_sessions_per_user: setting_int(:media_gallery_max_concurrent_sessions_per_user),
        max_concurrent_sessions_per_ip: setting_int(:media_gallery_max_concurrent_sessions_per_ip),
        max_active_tokens_per_user: setting_int(:media_gallery_max_active_tokens_per_user),
        max_active_tokens_per_ip: setting_int(:media_gallery_max_active_tokens_per_ip),
        hls_playlist_requests_per_token_per_minute: setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute),
        hls_segment_requests_per_token_per_minute: setting_int(:media_gallery_hls_segment_requests_per_token_per_minute),
      }
    end

    def watermark_fingerprint_status
      watermark = setting_bool(:media_gallery_watermark_enabled)
      fingerprint = setting_bool(:media_gallery_fingerprint_enabled)
      toggle = setting_bool(:media_gallery_watermark_user_can_toggle, default: true)

      return "ok" if watermark && fingerprint && !toggle
      return "partial" if watermark || fingerprint
      "attention"
    end

    def watermark_fingerprint_summary
      watermark = setting_bool(:media_gallery_watermark_enabled)
      fingerprint = setting_bool(:media_gallery_fingerprint_enabled)
      toggle = setting_bool(:media_gallery_watermark_user_can_toggle, default: true)

      if watermark && fingerprint && !toggle
        "Watermarking and fingerprinting are enabled and users cannot disable the watermark."
      elsif watermark || fingerprint
        "Watermarking/fingerprinting is partially enabled; review whether users can disable visible protection."
      else
        "Watermarking and fingerprinting are currently not active for new protected playback."
      end
    end

    def watermark_fingerprint_action
      "For stronger download deterrence, enable watermark and fingerprinting and disable user-controlled watermark opt-out for protected content."
    end

    def session_resistance_status
      binding_enabled = setting_bool(:media_gallery_bind_stream_to_user) || setting_bool(:media_gallery_bind_stream_to_ip) || setting_bool(:media_gallery_bind_stream_to_session)
      limits_enabled = setting_int(:media_gallery_max_active_tokens_per_user).positive? || setting_int(:media_gallery_max_concurrent_sessions_per_user).positive?
      heartbeat = setting_bool(:media_gallery_heartbeat_enabled)
      revoke = setting_bool(:media_gallery_revoke_enabled)

      return "ok" if binding_enabled && limits_enabled && heartbeat && revoke
      return "partial" if binding_enabled || limits_enabled || heartbeat || revoke
      "attention"
    end

    def session_resistance_summary
      parts = []
      parts << "binding" if setting_bool(:media_gallery_bind_stream_to_user) || setting_bool(:media_gallery_bind_stream_to_ip) || setting_bool(:media_gallery_bind_stream_to_session)
      parts << "limits" if setting_int(:media_gallery_max_active_tokens_per_user).positive? || setting_int(:media_gallery_max_concurrent_sessions_per_user).positive?
      parts << "heartbeat" if setting_bool(:media_gallery_heartbeat_enabled)
      parts << "revoke" if setting_bool(:media_gallery_revoke_enabled)
      return "Replay controls active: #{parts.join(', ')}." if parts.present?

      "Replay/session controls are available but not active."
    end

    def hls_rate_limit_status
      playlist = setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute)
      segments = setting_int(:media_gallery_hls_segment_requests_per_token_per_minute)
      return "ok" if playlist.positive? && segments.positive?
      return "partial" if playlist.positive? || segments.positive?
      "attention"
    end

    def hls_rate_limit_summary
      "Playlist limit: #{setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute)}/min; segment limit: #{setting_int(:media_gallery_hls_segment_requests_per_token_per_minute)}/min."
    end

    def forensics_lifecycle_status
      retention = setting_int(:media_gallery_forensics_playback_session_retention_days)
      export_retention = setting_int(:media_gallery_forensics_export_retention_days)
      return "ok" if retention.positive? && export_retention.positive?
      return "partial" if retention.positive? || export_retention.positive?
      "attention"
    end

    def forensics_lifecycle_summary
      archive_text = if SiteSetting.respond_to?(:media_gallery_forensics_export_archive_enabled)
        setting_bool(:media_gallery_forensics_export_archive_enabled) ? "archive enabled" : "archive disabled"
      else
        "archive setting unavailable"
      end

      "Playback retention: #{setting_int(:media_gallery_forensics_playback_session_retention_days)} days; export retention: #{setting_int(:media_gallery_forensics_export_retention_days)} days; #{archive_text}."
    end

    def security_settings
      [
        setting_row(:media_gallery_protected_video_hls_only, "HLS-only video mode", recommended: "true for protected video"),
        setting_row(:media_gallery_hls_enabled, "HLS enabled", recommended: "true"),
        setting_row(:media_gallery_fingerprint_enabled, "Fingerprinting", recommended: "true for protected video"),
        setting_row(:media_gallery_watermark_enabled, "Watermarking", recommended: "true for protected video"),
        setting_row(:media_gallery_watermark_user_can_toggle, "Users can disable watermark", recommended: "false for protected video"),
        setting_row(:media_gallery_bind_stream_to_user, "Bind stream tokens to user", recommended: "true"),
        setting_row(:media_gallery_bind_stream_to_session, "Bind stream tokens to session", recommended: "true when supported"),
        setting_row(:media_gallery_hls_playlist_requests_per_token_per_minute, "HLS playlist rate limit", recommended: "> 0"),
        setting_row(:media_gallery_hls_segment_requests_per_token_per_minute, "HLS segment rate limit", recommended: "> 0"),
        setting_row(:media_gallery_forensics_playback_session_retention_days, "Playback-session retention", recommended: "90 days or policy"),
        setting_row(:media_gallery_forensics_export_retention_days, "Export retention", recommended: "90 days or policy"),
        setting_row(:media_gallery_forensics_export_archive_retention_days, "Archive retention", recommended: "90 days or policy"),
      ]
    end

    def setting_row(name, label, recommended: nil)
      exists = SiteSetting.respond_to?(name)
      value = exists ? SiteSetting.public_send(name) : nil
      {
        key: name.to_s,
        label: label,
        value: exists ? setting_value_for_display(value) : "Not available",
        recommended: recommended.to_s,
        present: exists,
      }
    rescue
      { key: name.to_s, label: label, value: "Unavailable", recommended: recommended.to_s, present: false }
    end

    def storage_status
      profiles = ::MediaGallery::StorageSettingsResolver.configured_profiles_summary.map do |profile|
        {
          profile_key: profile[:profile_key].to_s,
          label: profile[:label].to_s,
          backend: profile[:backend].to_s,
          delivery_mode: profile[:backend].to_s == "s3" ? ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s : "local",
          configured: true,
          config: safe_storage_config(profile[:config]),
        }
      end

      {
        active_profile: ::MediaGallery::StorageSettingsResolver.active_profile_key.to_s,
        active_backend: ::MediaGallery::StorageSettingsResolver.active_backend.to_s,
        default_delivery_mode: ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s,
        profiles: profiles,
      }
    rescue
      { active_profile: "", active_backend: "", default_delivery_mode: "", profiles: [] }
    end

    def safe_storage_config(config)
      h = config.is_a?(Hash) ? config.deep_stringify_keys : {}
      h.except("access_key_id", "secret_access_key")
    rescue
      {}
    end

    def forensics_status
      exports_count = forensics_export_scope&.count.to_i
      latest = forensics_export_scope&.order(created_at: :desc)&.first
      expired_exports = expired_export_count

      {
        playback_session_retention_days: setting_int(:media_gallery_forensics_playback_session_retention_days),
        export_retention_days: setting_int(:media_gallery_forensics_export_retention_days),
        archive_enabled: setting_bool(:media_gallery_forensics_export_archive_enabled),
        archive_retention_days: setting_int(:media_gallery_forensics_export_archive_retention_days),
        export_count: exports_count,
        expired_exports: expired_exports,
        latest_export_at: latest&.created_at&.utc&.iso8601,
        delete_action_available: true,
        csv_formula_protection: true,
      }
    rescue
      {
        playback_session_retention_days: setting_int(:media_gallery_forensics_playback_session_retention_days),
        export_retention_days: setting_int(:media_gallery_forensics_export_retention_days),
        archive_enabled: setting_bool(:media_gallery_forensics_export_archive_enabled),
        archive_retention_days: setting_int(:media_gallery_forensics_export_archive_retention_days),
        export_count: 0,
        expired_exports: 0,
        latest_export_at: nil,
        delete_action_available: true,
        csv_formula_protection: true,
      }
    end

    def forensics_export_scope
      return nil unless defined?(::MediaGallery::MediaForensicsExport)
      return nil unless ::MediaGallery::MediaForensicsExport.table_exists?

      ::MediaGallery::MediaForensicsExport.all
    rescue
      nil
    end

    def expired_export_count
      scope = forensics_export_scope
      days = setting_int(:media_gallery_forensics_export_retention_days)
      return 0 if scope.blank? || days <= 0

      scope.where("created_at < ?", days.days.ago).count
    rescue
      0
    end

    def recent_security_events
      scope = nil
      if defined?(::MediaGallery::MediaLogEvent) && ::MediaGallery::MediaLogEvent.table_exists?
        scope = ::MediaGallery::MediaLogEvent.where("created_at >= ?", 7.days.ago)
      end

      return { total_7d: 0, warning_or_danger_7d: 0, top_event_types: [] } if scope.blank?

      top = scope.group(:event_type).order(Arel.sql("COUNT(*) DESC")).limit(6).count.map do |event_type, count|
        { event_type: event_type.to_s, count: count.to_i }
      end

      {
        total_7d: scope.count,
        warning_or_danger_7d: scope.where(severity: %w[warning danger error]).count,
        top_event_types: top,
      }
    rescue
      { total_7d: 0, warning_or_danger_7d: 0, top_event_types: [] }
    end

    def admin_links
      [
        { label: "Settings", url: "/admin/site_settings/category/all_results?filter=media_gallery" },
        { label: "Health", url: "/admin/plugins/media-gallery-health" },
        { label: "Logs", url: "/admin/plugins/media-gallery-logs" },
        { label: "Storage / migrations", url: "/admin/plugins/media-gallery-migrations" },
        { label: "Forensics exports", url: "/admin/plugins/media-gallery-forensics-exports" },
      ]
    end

    def setting_bool(name, default: false)
      return default unless SiteSetting.respond_to?(name)
      !!SiteSetting.public_send(name)
    rescue
      default
    end

    def setting_int(name, default: 0)
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def setting_string(name, default: "")
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_s
    rescue
      default
    end

    def setting_value_for_display(value)
      case value
      when TrueClass
        "true"
      when FalseClass
        "false"
      when NilClass
        "—"
      else
        value.to_s.presence || "—"
      end
    end
  end
end
