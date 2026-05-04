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
      environment = environment_status
      download = download_prevention_status
      baseline = security_baseline_checks(environment, download)
      processing_failures = processing_failure_metrics
      backup_retention = backup_retention_status
      controls = security_controls(download, environment, baseline)
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
          baseline_total: baseline.length,
          baseline_ok_count: baseline.count { |row| row[:status].to_s == "ok" },
          baseline_attention_count: baseline.count { |row| row[:status].to_s == "attention" },
          baseline_partial_count: baseline.count { |row| row[:status].to_s == "partial" },
        },
        environment: environment,
        controls: controls,
        baseline_checks: baseline,
        download_prevention: download,
        settings: security_settings,
        storage: storage_status,
        forensics: forensics_status,
        processing_failures: processing_failures,
        backup_retention: backup_retention,
        rate_limit_tuning: rate_limit_tuning_status,
        recent_events: recent_security_events,
        links: admin_links,
      }
    end

    def security_controls(download, environment, baseline)
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
          "HLS AES-128 content hardening",
          aes128_control_status(download),
          aes128_control_summary(download),
          aes128_control_action(download)
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
        control(
          "Production HTTPS and canonical URL",
          environment[:status],
          environment[:summary],
          environment[:action]
        ),
        control(
          "Recommended security baseline",
          baseline_control_status(baseline),
          baseline_control_summary(baseline),
          "Use the baseline section below as configuration guidance. This is a read-only check and does not change settings."
        ),
        control(
          "Stream scraping anomaly detection",
          stream_scraping_control_status,
          stream_scraping_control_summary,
          "Keep soft anomaly logging enabled first; only enable hard stream limits after observing normal traffic."
        ),
        control(
          "Forensic source URL policy",
          forensic_http_policy_control_status,
          forensic_http_policy_control_summary,
          "Use deny_all in production. Use canonical_only only for HTTP test sites that need local forensic identify URLs."
        ),
        control(
          "Thumbnail cache privacy",
          thumbnail_cache_control_status,
          thumbnail_cache_control_summary,
          "Enable no-store thumbnails when privacy matters more than browser thumbnail caching."
        ),
        control(
          "Upload content validation",
          fail_closed_upload_control_status,
          fail_closed_upload_control_summary,
          "Keep fail-closed enabled so renamed PDFs/ZIPs/random bytes do not enter the full FFmpeg pipeline."
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
      aes128_enabled = setting_bool(:media_gallery_hls_aes128_enabled)
      aes128_required = aes128_enabled && setting_bool(:media_gallery_hls_aes128_required)

      level =
        if hls_enabled && hls_only_enabled && aes128_required && fingerprint_enabled && watermark_enabled && !watermark_toggle_allowed
          "Strong"
        elsif hls_enabled && hls_only_enabled && (aes128_required || (fingerprint_enabled && watermark_enabled && !watermark_toggle_allowed))
          "Medium"
        elsif hls_enabled && hls_only_enabled && (fingerprint_enabled || watermark_enabled || aes128_enabled)
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
        hls_key_requests_per_token_per_minute: setting_int(:media_gallery_hls_key_requests_per_token_per_minute),
        hls_aes128_enabled: aes128_enabled,
        hls_aes128_required: aes128_required,
        hls_aes128_key_rotation_segments: setting_int(:media_gallery_hls_aes128_key_rotation_segments),
        log_hls_aes128_key_denials: setting_bool(:media_gallery_log_hls_aes128_key_denials),
        log_stream_anomalies: setting_bool(:media_gallery_log_stream_anomalies),
        stream_requests_per_token_per_minute: setting_int(:media_gallery_stream_requests_per_token_per_minute),
        stream_range_requests_per_token_per_minute: setting_int(:media_gallery_stream_range_requests_per_token_per_minute),
        stream_anomaly_requests_per_token_per_minute: setting_int(:media_gallery_stream_anomaly_requests_per_token_per_minute),
        stream_anomaly_range_requests_per_token_per_minute: setting_int(:media_gallery_stream_anomaly_range_requests_per_token_per_minute),
        no_store_thumbnails: setting_bool(:media_gallery_no_store_thumbnails),
        forensics_http_source_url_policy: setting_string(:media_gallery_forensics_http_source_url_policy, default: "deny_all"),
        fail_closed_on_unrecognized_media: setting_bool(:media_gallery_fail_closed_on_unrecognized_media, default: true),
        block_direct_media_navigation: setting_bool(:media_gallery_block_direct_media_navigation, default: true),
      }
    end

    def aes128_control_status(download)
      return "attention" if download[:hls_aes128_required] && !download[:hls_aes128_enabled]
      return "ok" if download[:hls_aes128_required]
      return "partial" if download[:hls_aes128_enabled]
      "manual"
    end

    def aes128_control_summary(download)
      if download[:hls_aes128_required]
        "AES-128 is required for HLS playback; non-AES HLS packages are blocked from protected playback."
      elsif download[:hls_aes128_enabled]
        "AES-128 packaging is enabled for new/reprocessed HLS packages, but required mode is still off for migration compatibility."
      else
        "AES-128 HLS encryption is available but disabled. Existing HLS playback remains unchanged."
      end
    end

    def aes128_control_action(download)
      if download[:hls_aes128_required]
        "Monitor key endpoint denials and browser compatibility before tightening related token/rate-limit settings."
      elsif download[:hls_aes128_enabled]
        "Backfill existing HLS video packages and validate Safari/hls.js playback before enabling required mode."
      else
        "Enable AES-128 first on staging, verify encrypted upload/playback, then plan backfill before requiring it site-wide."
      end
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
        setting_row(:media_gallery_hls_aes128_enabled, "HLS AES-128 encryption", recommended: "true after staging validation"),
        setting_row(:media_gallery_hls_aes128_required, "Require HLS AES-128", recommended: "true after backfill"),
        setting_row(:media_gallery_hls_aes128_key_rotation_segments, "HLS AES key rotation", recommended: "0 for v1"),
        setting_row(:media_gallery_fingerprint_enabled, "Fingerprinting", recommended: "true for protected video"),
        setting_row(:media_gallery_watermark_enabled, "Watermarking", recommended: "true for protected video"),
        setting_row(:media_gallery_watermark_user_can_toggle, "Users can disable watermark", recommended: "false for protected video"),
        setting_row(:media_gallery_bind_stream_to_user, "Bind stream tokens to user", recommended: "true"),
        setting_row(:media_gallery_bind_stream_to_session, "Bind stream tokens to session", recommended: "true when supported"),
        setting_row(:media_gallery_hls_playlist_requests_per_token_per_minute, "HLS playlist rate limit", recommended: "> 0"),
        setting_row(:media_gallery_hls_segment_requests_per_token_per_minute, "HLS segment rate limit", recommended: "> 0"),
        setting_row(:media_gallery_hls_key_requests_per_token_per_minute, "HLS AES key rate limit", recommended: "> 0"),
        setting_row(:media_gallery_log_hls_aes128_key_denials, "Log denied HLS AES key requests", recommended: "true during QA, false or monitored in production"),
        setting_row(:media_gallery_forensics_playback_session_retention_days, "Playback-session retention", recommended: "90 days or policy"),
        setting_row(:media_gallery_forensics_export_retention_days, "Export retention", recommended: "90 days or policy"),
        setting_row(:media_gallery_forensics_export_archive_retention_days, "Archive retention", recommended: "90 days or policy"),
        setting_row(:media_gallery_block_direct_media_navigation, "Block direct media navigation", recommended: "true"),
        setting_row(:media_gallery_log_stream_anomalies, "Stream anomaly logging", recommended: "true"),
        setting_row(:media_gallery_stream_anomaly_requests_per_token_per_minute, "Stream anomaly request threshold", recommended: "observe and tune"),
        setting_row(:media_gallery_stream_anomaly_range_requests_per_token_per_minute, "Stream anomaly range threshold", recommended: "observe and tune"),
        setting_row(:media_gallery_forensics_http_source_url_policy, "Forensic HTTP source URL policy", recommended: "deny_all in production"),
        setting_row(:media_gallery_no_store_thumbnails, "No-store thumbnails", recommended: "true for privacy-sensitive libraries"),
        setting_row(:media_gallery_fail_closed_on_unrecognized_media, "Fail closed on unrecognized uploads", recommended: "true"),
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

    def rate_limit_tuning_status
      scope = media_log_scope_since(7.days.ago)
      counts = rate_limit_tuning_counts(scope)

      stream_anomalies = counts["stream_scrape_anomaly"].to_i
      stream_rate_limited = counts["stream_rate_limited"].to_i
      hls_denied = counts["hls_denied"].to_i
      hls_key_denied = hls_key_denied_count(scope)
      play_rate_limited = counts["play_rate_limited"].to_i
      play_tokens = counts["play_token_issued"].to_i
      token_session_limits = %w[
        play_token_limit_reached
        new_session_limit_reached
        concurrent_session_limit_reached
        heartbeat_session_limit_reached
      ].sum { |event_type| counts[event_type].to_i }

      enforcement_hits = stream_rate_limited + play_rate_limited + token_session_limits
      soft_hits = stream_anomalies + hls_denied + hls_key_denied
      status =
        if enforcement_hits.positive?
          "attention"
        elsif soft_hits.positive?
          "warning"
        else
          "ok"
        end

      {
        window_days: 7,
        status: status,
        summary: rate_limit_tuning_summary(status),
        rows: [
          tuning_row("stream_anomalies", "Stream anomaly events", stream_anomalies, stream_anomalies.positive? ? "warning" : "ok", "Soft F08 detections. Use these to tune thresholds before enabling hard blocking."),
          tuning_row("stream_rate_limited", "Hard stream rate limits", stream_rate_limited, stream_rate_limited.positive? ? "attention" : "ok", "Requests blocked by /media/stream hard per-token limits."),
          tuning_row("hls_denied", "HLS denied requests", hls_denied, hls_denied.positive? ? "warning" : "ok", "Denied HLS playlist/segment/key requests, including token, policy, readiness or rate-limit denials."),
          tuning_row("hls_key_denied", "HLS AES key denials", hls_key_denied, hls_key_denied.positive? ? "warning" : "ok", "Denied requests to the AES-128 key endpoint. During QA, use this to detect token/session/key-id problems."),
          tuning_row("play_rate_limited", "Play-token rate limited", play_rate_limited, play_rate_limited.positive? ? "attention" : "ok", "Play-token creation blocked by the per-IP play-token rate limit."),
          tuning_row("token_session_limits", "Token/session limit hits", token_session_limits, token_session_limits.positive? ? "attention" : "ok", "Playback blocked by active-token or concurrent-session limits."),
          tuning_row("play_tokens", "Play tokens issued", play_tokens, "info", "Volume signal only. A sudden increase can indicate sharing, scraping attempts or a successful campaign.")
        ],
        thresholds: rate_limit_tuning_thresholds,
      }
    rescue
      {
        window_days: 7,
        status: "info",
        summary: "Rate-limit and anomaly tuning data is not available yet.",
        rows: [],
        thresholds: rate_limit_tuning_thresholds,
      }
    end

    def media_log_scope_since(time)
      return nil unless defined?(::MediaGallery::MediaLogEvent) && ::MediaGallery::MediaLogEvent.table_exists?

      ::MediaGallery::MediaLogEvent.where("created_at >= ?", time)
    rescue
      nil
    end

    def rate_limit_tuning_counts(scope)
      interesting = %w[
        stream_scrape_anomaly
        stream_rate_limited
        hls_denied
        play_rate_limited
        play_token_issued
        play_token_limit_reached
        new_session_limit_reached
        concurrent_session_limit_reached
        heartbeat_session_limit_reached
      ]

      return Hash.new(0) if scope.blank?

      raw = scope.where(event_type: interesting).group(:event_type).count
      Hash.new(0).merge(raw.transform_keys(&:to_s))
    rescue
      Hash.new(0)
    end

    def hls_key_denied_count(scope)
      return 0 if scope.blank?

      scope.where(event_type: "hls_denied").where("path LIKE ?", "%/key/%").count.to_i
    rescue
      0
    end

    def rate_limit_tuning_summary(status)
      case status.to_s
      when "attention"
        "Hard limits or token/session limits were hit in the last 7 days. Review logs before tightening thresholds further."
      when "warning"
        "Soft anomaly or denial signals were observed in the last 7 days. Use this as tuning input before enforcing stricter limits."
      else
        "No recent rate-limit or anomaly pressure detected. Keep observing normal traffic before changing enforcement."
      end
    end

    def tuning_row(key, label, value, status, detail)
      {
        key: key,
        label: label,
        value: value.to_i,
        status: status,
        detail: detail,
      }
    end

    def rate_limit_tuning_thresholds
      hard_stream = setting_int(:media_gallery_stream_requests_per_token_per_minute)
      hard_range = setting_int(:media_gallery_stream_range_requests_per_token_per_minute)
      anomaly_stream = setting_int(:media_gallery_stream_anomaly_requests_per_token_per_minute)
      anomaly_range = setting_int(:media_gallery_stream_anomaly_range_requests_per_token_per_minute)
      hls_playlist = setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute)
      hls_segments = setting_int(:media_gallery_hls_segment_requests_per_token_per_minute)
      hls_keys = setting_int(:media_gallery_hls_key_requests_per_token_per_minute)
      play_tokens = setting_int(:media_gallery_play_tokens_per_ip_per_minute)

      [
        tuning_row("stream_anomaly_thresholds", "Stream anomaly thresholds", "#{anomaly_stream}/#{anomaly_range}", setting_bool(:media_gallery_log_stream_anomalies) ? "ok" : "warning", "Soft logging thresholds: total requests per token/minute and range requests per token/minute."),
        tuning_row("hard_stream_limits", "Hard stream limits", "#{hard_stream}/#{hard_range}", hard_stream.positive? || hard_range.positive? ? "warning" : "info", "Hard blocking limits: total stream requests/minute and range requests/minute. 0 means observe-only for that limit."),
        tuning_row("hls_rate_limits", "HLS rate limits", "#{hls_playlist}/#{hls_segments}", hls_playlist.positive? && hls_segments.positive? ? "ok" : "warning", "Playlist and segment requests allowed per HLS token per minute."),
        tuning_row("hls_key_rate_limit", "HLS AES key rate limit", hls_keys, hls_keys.positive? ? "ok" : "warning", "AES-128 key endpoint requests allowed per HLS token per minute. 0 disables this protection."),
        tuning_row("play_token_rate_limit", "Play-token rate limit", play_tokens, play_tokens.positive? ? "ok" : "warning", "Maximum play-token creation requests per IP per minute. 0 disables this protection.")
      ]
    end


    def recent_security_events
      scope = nil
      if defined?(::MediaGallery::MediaLogEvent) && ::MediaGallery::MediaLogEvent.table_exists?
        scope = ::MediaGallery::MediaLogEvent.where("created_at >= ?", 7.days.ago)
      end

      return empty_recent_security_events if scope.blank?

      top = scope.group(:event_type).order(Arel.sql("COUNT(*) DESC")).limit(6).count.map do |event_type, count|
        { event_type: event_type.to_s, count: count.to_i }
      end

      counters = recent_event_counters(scope)

      {
        total_7d: scope.count,
        warning_or_danger_7d: scope.where(severity: %w[warning danger error]).count,
        top_event_types: top,
        counters: counters,
      }
    rescue
      empty_recent_security_events
    end

    def environment_status
      base_url = Discourse.base_url.to_s
      base_uri = URI.parse(base_url)
      forwarded_proto = request.headers["X-Forwarded-Proto"].to_s.split(",").first.to_s.strip
      request_scheme = forwarded_proto.presence || request.scheme.to_s
      request_scheme = request_scheme.sub(%r{://\z}, "")
      request_scheme = request_scheme.sub(%r{://.*\z}, "") if request_scheme.include?("://")
      request_scheme = request_scheme.presence || (request.ssl? ? "https" : "http")
      canonical_host = base_uri.host.to_s.downcase
      request_host = request.host.to_s.downcase
      host_matches = canonical_host.present? && request_host == canonical_host
      base_https = base_uri.scheme.to_s == "https"
      request_https = request_scheme.to_s == "https"
      https_ok = base_https && request_https

      status = if https_ok && host_matches
        "ok"
      elsif base_https || request_https || host_matches
        "partial"
      else
        "attention"
      end

      summary = if status == "ok"
        "Canonical URL and current admin request are using HTTPS and the request host matches the canonical host."
      elsif !base_https
        "The canonical Discourse base URL is not HTTPS. Playback tokens and session-bound media requests are safer over HTTPS in production."
      elsif !request_https
        "The canonical URL is HTTPS, but this admin request appears to arrive over #{request_scheme.upcase}. Check reverse proxy HTTPS headers."
      else
        "The current request host does not match the canonical Discourse host. Confirm that admins and users access one canonical domain."
      end

      action = status == "ok" ? "Keep force-HTTPS, reverse proxy and HSTS configuration monitored." : "For production, use HTTPS for the canonical Discourse URL and ensure reverse proxy headers preserve the original scheme."

      {
        status: status,
        label: status_label(status),
        base_url: base_url,
        base_scheme: base_uri.scheme.to_s.presence || "unknown",
        request_scheme: request_scheme,
        canonical_host: canonical_host,
        request_host: request_host,
        host_matches: host_matches,
        https_ok: https_ok,
        summary: summary,
        action: action,
      }
    rescue => e
      {
        status: "partial",
        label: "Partial",
        base_url: Discourse.base_url.to_s,
        base_scheme: "unknown",
        request_scheme: "unknown",
        canonical_host: "unknown",
        request_host: request&.host.to_s,
        host_matches: false,
        https_ok: false,
        summary: "Could not fully inspect HTTPS/canonical URL status: #{e.class.name}.",
        action: "Verify Discourse base_url, force_https, HSTS and reverse proxy scheme headers manually.",
      }
    end

    def security_baseline_checks(environment, download)
      ttl = setting_int(:media_gallery_stream_token_ttl_minutes)
      archive_enabled = setting_bool(:media_gallery_forensics_export_archive_enabled)
      archive_days = setting_int(:media_gallery_forensics_export_archive_retention_days)
      f11_policy = setting_string(:media_gallery_forensics_http_source_url_policy, default: "deny_all")
      playlist_limit = setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute)
      segment_limit = setting_int(:media_gallery_hls_segment_requests_per_token_per_minute)
      key_limit = setting_int(:media_gallery_hls_key_requests_per_token_per_minute)
      aes_enabled = setting_bool(:media_gallery_hls_aes128_enabled)
      aes_required = aes_enabled && setting_bool(:media_gallery_hls_aes128_required)

      [
        baseline_check("production_https", "Production HTTPS/canonical URL", environment[:https_ok] ? "HTTPS" : "Review", "HTTPS canonical production URL", environment[:status], environment[:summary]),
        baseline_check("hls_enabled", "HLS enabled", yes_no(download[:hls_enabled]), "Enabled for protected videos", download[:hls_enabled] ? "ok" : "attention", "HLS enables segmented delivery, fingerprinting and stricter video fallback policy."),
        baseline_check("hls_only", "HLS-only protected video", yes_no(download[:hls_only_enabled]), "Enabled for protected video", download[:hls_only_enabled] ? "ok" : "attention", "Blocks direct MP4 stream fallback for protected video playback."),
        baseline_check("hls_aes128", "HLS AES-128 content hardening", aes_required ? "Required" : aes_enabled ? "Enabled" : "Disabled", "Enabled, then required after backfill", aes_required ? "ok" : aes_enabled ? "partial" : "partial", "Encrypts HLS segments with an authenticated key endpoint. This is not DRM; authorized clients can still receive keys."),
        baseline_check("bind_user", "Bind stream tokens to user", yes_no(download[:bind_to_user]), "Enabled", download[:bind_to_user] ? "ok" : "attention", "Prevents a token issued for one user from being reused by another user."),
        baseline_check("bind_session", "Bind stream tokens to browser session", yes_no(download[:bind_to_session]), "Enabled", download[:bind_to_session] ? "ok" : "partial", "Adds a signed session-binding cookie check in addition to token validation."),
        baseline_check("stream_ttl", "Stream token lifetime", "#{ttl} minutes", "5-15 minutes for high-value content", ttl.positive? && ttl <= 20 ? "ok" : ttl.positive? ? "partial" : "attention", "Shorter TTLs reduce replay windows; very short values can affect unstable clients."),
        baseline_check("watermark", "Visible watermark", yes_no(download[:watermark_enabled]), "Enabled for protected content", download[:watermark_enabled] ? "ok" : "partial", "A visible watermark is a deterrent and helps communicate traceability."),
        baseline_check("watermark_toggle", "User watermark opt-out", download[:watermark_user_can_toggle] ? "Allowed" : "Blocked", "Blocked for protected content", download[:watermark_user_can_toggle] ? "partial" : "ok", "Protected content is stronger when users cannot disable the visible watermark."),
        baseline_check("fingerprint", "HLS fingerprinting", yes_no(download[:fingerprint_enabled]), "Enabled for protected videos", download[:fingerprint_enabled] ? "ok" : "partial", "A/B HLS fingerprinting helps identify likely recipients of leaked streams."),
        baseline_check("hls_limits", "HLS request rate limits", "playlist #{playlist_limit}/min, segments #{segment_limit}/min, keys #{key_limit}/min", "All > 0", playlist_limit.positive? && segment_limit.positive? && key_limit.positive? ? "ok" : "partial", "Per-token HLS limits make automated playlist, segment and AES-key scraping noisier and easier to detect."),
        baseline_check("direct_media_navigation", "Block direct media navigation", yes_no(download[:block_direct_media_navigation]), "Enabled", download[:block_direct_media_navigation] ? "ok" : "partial", "Blocks clear address-bar/new-tab navigation to tokenized play/stream/HLS endpoints while allowing normal player requests."),
        baseline_check("stream_anomaly", "Stream anomaly logging", yes_no(setting_bool(:media_gallery_log_stream_anomalies)), "Enabled", setting_bool(:media_gallery_log_stream_anomalies) ? "ok" : "partial", "Soft anomaly logging is safer than immediate blocking while thresholds are tuned."),
        baseline_check("f11_policy", "Forensic HTTP source URL policy", f11_policy, "deny_all in production", f11_policy == "deny_all" ? "ok" : f11_policy == "canonical_only" ? "partial" : "attention", "Controls whether admin forensic identify may use http:// source URLs."),
        baseline_check("thumbnail_no_store", "Thumbnail no-store", yes_no(setting_bool(:media_gallery_no_store_thumbnails)), "Enabled for privacy-sensitive libraries", setting_bool(:media_gallery_no_store_thumbnails) ? "ok" : "partial", "No-store thumbnails reduce browser/proxy caching of stable thumbnail URLs."),
        baseline_check("fail_closed_uploads", "Fail closed on unrecognized uploads", yes_no(setting_bool(:media_gallery_fail_closed_on_unrecognized_media, default: true)), "Enabled", setting_bool(:media_gallery_fail_closed_on_unrecognized_media, default: true) ? "ok" : "attention", "Rejects renamed non-media before the full FFmpeg processing pipeline."),
        baseline_check("playback_retention", "Playback-session retention", "#{setting_int(:media_gallery_forensics_playback_session_retention_days)} days", "90 days or policy", setting_int(:media_gallery_forensics_playback_session_retention_days).positive? ? "ok" : "attention", "Playback forensic data can include IP/user-agent signals and should have a real retention period."),
        baseline_check("export_retention", "Forensics export retention", "#{setting_int(:media_gallery_forensics_export_retention_days)} days", "90 days or policy", setting_int(:media_gallery_forensics_export_retention_days).positive? ? "ok" : "partial", "Export files should not remain available forever unless a policy explicitly requires that."),
        baseline_check("archive_retention", "Forensics archive retention", archive_enabled ? "#{archive_days} days" : "Archive disabled", "90 days or policy when archive is enabled", !archive_enabled || archive_days.positive? ? "ok" : "partial", "Archive copies should have explicit retention if enabled."),
      ]
    end

    def baseline_check(key, label, current, recommended, status, note)
      status = status.to_s.presence || "info"
      {
        key: key,
        label: label,
        current: current.to_s.presence || "—",
        recommended: recommended.to_s.presence || "—",
        status: status,
        status_label: status_label(status),
        note: note.to_s,
      }
    end

    def baseline_control_status(baseline)
      statuses = Array(baseline).map { |row| row[:status].to_s }
      return "attention" if statuses.include?("attention")
      return "partial" if statuses.include?("partial")
      "ok"
    end

    def baseline_control_summary(baseline)
      ok = Array(baseline).count { |row| row[:status].to_s == "ok" }
      partial = Array(baseline).count { |row| row[:status].to_s == "partial" }
      attention = Array(baseline).count { |row| row[:status].to_s == "attention" }
      "Recommended baseline: #{ok} OK, #{partial} partial, #{attention} attention."
    end

    def stream_scraping_control_status
      return "ok" if setting_bool(:media_gallery_log_stream_anomalies)
      "partial"
    end

    def stream_scraping_control_summary
      soft = setting_bool(:media_gallery_log_stream_anomalies) ? "enabled" : "disabled"
      hard = [setting_int(:media_gallery_stream_requests_per_token_per_minute), setting_int(:media_gallery_stream_range_requests_per_token_per_minute)].any?(&:positive?) ? "configured" : "disabled"
      "Soft anomaly logging is #{soft}; hard stream request limits are #{hard}."
    end

    def forensic_http_policy_control_status
      case setting_string(:media_gallery_forensics_http_source_url_policy, default: "deny_all")
      when "deny_all" then "ok"
      when "canonical_only" then "partial"
      else "attention"
      end
    end

    def forensic_http_policy_control_summary
      policy = setting_string(:media_gallery_forensics_http_source_url_policy, default: "deny_all")
      "Admin forensic identify HTTP source URL policy is #{policy}."
    end

    def thumbnail_cache_control_status
      setting_bool(:media_gallery_no_store_thumbnails) ? "ok" : "partial"
    end

    def thumbnail_cache_control_summary
      setting_bool(:media_gallery_no_store_thumbnails) ?
        "Thumbnail responses use no-store/no-cache headers." :
        "Thumbnail responses may use private browser caching for performance."
    end

    def fail_closed_upload_control_status
      setting_bool(:media_gallery_fail_closed_on_unrecognized_media, default: true) ? "ok" : "attention"
    end

    def fail_closed_upload_control_summary
      setting_bool(:media_gallery_fail_closed_on_unrecognized_media, default: true) ?
        "Unrecognized uploaded media fails before the full FFmpeg processing pipeline." :
        "Unrecognized media may fall back to the declared extension/MIME processing path."
    end

    def processing_failure_metrics
      return empty_processing_failure_metrics unless defined?(::MediaGallery::MediaItem)

      scope = ::MediaGallery::MediaItem.where(status: "failed")
      last_7 = scope.where("updated_at >= ?", 7.days.ago)
      last_30 = scope.where("updated_at >= ?", 30.days.ago)
      reasons = normalized_failure_reason_counts(last_30.limit(5000).pluck(:error_message))

      {
        total_failed: scope.count,
        failed_7d: last_7.count,
        failed_30d: last_30.count,
        top_reasons_30d: reasons.first(8).map { |reason, count| { reason: reason, count: count } },
      }
    rescue
      empty_processing_failure_metrics
    end

    def empty_processing_failure_metrics
      { total_failed: 0, failed_7d: 0, failed_30d: 0, top_reasons_30d: [] }
    end

    def normalized_failure_reason_counts(messages)
      counts = Hash.new(0)
      Array(messages).each do |message|
        counts[normalize_failure_reason(message)] += 1
      end
      counts.sort_by { |reason, count| [-count, reason] }
    end

    def normalize_failure_reason(message)
      msg = message.to_s.strip
      return "unknown_failure" if msg.blank?
      return "file_content_unrecognized" if msg == "file_content_unrecognized"
      return "file_content_mismatch" if msg == "file_content_mismatch"
      return "duration_probe_failed" if msg == "duration_probe_failed"
      return "duration_exceeds_limit" if msg.start_with?("duration_exceeds_")
      return "processing_attempt_limit_reached" if msg == "processing_attempt_limit_reached"
      return "ffprobe_failed" if msg.include?("ffprobe_failed")
      return "ffmpeg_failed" if msg.include?("ffmpeg_") || msg.include?("FFmpeg")
      return "storage_failed" if msg.include?("storage") || msg.include?("store_") || msg.include?("upload")
      return "hls_packaging_failed" if msg.include?("hls")
      "other_processing_failure"
    end

    def backup_retention_status
      paths = backup_retention_paths
      attention_count = paths.count { |row| row[:status].to_s == "attention" }
      partial_count = paths.count { |row| row[:status].to_s == "partial" }

      {
        status: attention_count.positive? ? "attention" : partial_count.positive? ? "partial" : "ok",
        paths: paths,
        summary: "#{paths.length} private/export paths reviewed; #{attention_count} attention, #{partial_count} partial.",
      }
    rescue
      { status: "partial", paths: [], summary: "Backup/retention path visibility could not be calculated." }
    end

    def backup_retention_paths
      private_root = setting_string(:media_gallery_private_root_path, default: "/shared/media_gallery/private")
      original_root = setting_string(:media_gallery_original_export_root_path, default: "/shared/media_gallery/original_export")
      export_root = effective_forensics_export_root(private_root, original_root)
      archive_root = effective_forensics_archive_root(private_root)

      [
        backup_path_row("Private media root", private_root, "processed media and thumbnails", "backup required for local/private media", "retention depends on media lifecycle"),
        backup_path_row("Original export root", original_root, "temporary exported originals", "include or exclude intentionally", "#{setting_int(:media_gallery_original_retention_hours)} hours"),
        backup_path_row("Forensics export root", export_root, "admin forensic CSV/GZIP exports", "sensitive evidence files", "#{setting_int(:media_gallery_forensics_export_retention_days)} days"),
        backup_path_row("Forensics archive root", archive_root, "optional private archive copies", "sensitive evidence files", "#{setting_int(:media_gallery_forensics_export_archive_retention_days)} days"),
      ]
    end

    def backup_path_row(label, path, purpose, recommendation, retention)
      path = path.to_s.strip
      status = if path.blank?
        "partial"
      elsif path.start_with?("/shared/") || path == "/shared"
        "ok"
      else
        "partial"
      end
      note = if path.blank?
        "No explicit path is set; plugin fallback behavior will be used."
      elsif status == "ok"
        "Path is under /shared, which is normally included in Discourse container backups."
      else
        "Path is outside /shared. Confirm your backup/retention process covers it intentionally."
      end

      {
        label: label,
        path: path.presence || "—",
        purpose: purpose,
        recommendation: recommendation,
        retention: retention,
        status: status,
        status_label: status_label(status),
        note: note,
      }
    end

    def effective_forensics_export_root(private_root, original_root)
      configured = setting_string(:media_gallery_forensics_export_root_path)
      return configured if configured.present?
      return ::File.join(original_root, "forensics_exports") if original_root.present?
      return ::File.join(private_root, "forensics_exports") if private_root.present?
      "/shared/media_gallery/private/forensics_exports"
    end

    def effective_forensics_archive_root(private_root)
      configured = setting_string(:media_gallery_forensics_export_archive_root_path)
      return configured if configured.present?
      return ::File.join(private_root, "forensics_export_archive") if private_root.present?
      "/shared/media_gallery/private/forensics_export_archive"
    end

    def recent_event_counters(scope)
      interesting = %w[
        stream_scrape_anomaly
        stream_rate_limited
        hls_denied
        play_rate_limited
        hls_only_force_stream_blocked
        direct_media_navigation_blocked
      ]
      raw = scope.where(event_type: interesting).group(:event_type).count
      interesting.map { |event_type| { event_type: event_type, count: raw[event_type].to_i } }
    end

    def empty_recent_security_events
      {
        total_7d: 0,
        warning_or_danger_7d: 0,
        top_event_types: [],
        counters: [],
      }
    end

    def yes_no(value)
      value ? "Yes" : "No"
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
