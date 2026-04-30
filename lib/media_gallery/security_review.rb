# frozen_string_literal: true

module ::MediaGallery
  module SecurityReview
    module_function

    def global_review(profile: nil)
      active_backend = ::MediaGallery::StorageSettingsResolver.active_backend.to_s
      hls_enabled = SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled
      presign_ttl = SiteSetting.respond_to?(:media_gallery_s3_presign_ttl_seconds) ? SiteSetting.media_gallery_s3_presign_ttl_seconds.to_i : 0

      warnings = []
      warnings << "S3 presigned URL TTL is high; keep it short for private playback." if presign_ttl > 600
      if active_backend == "s3" && hls_enabled && ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect"
        warnings << "When using S3 HLS redirect delivery, verify bucket CORS only allows the forum origin and required methods/headers."
      end
      warnings << "Confirm the S3 bucket is not publicly readable; playback should rely on app-auth plus proxy delivery or short-lived redirects." if active_backend == "s3"
      if !SiteSetting.media_gallery_bind_stream_to_user && !SiteSetting.media_gallery_bind_stream_to_ip && !(SiteSetting.respond_to?(:media_gallery_bind_stream_to_session) && SiteSetting.media_gallery_bind_stream_to_session)
        warnings << "Bind stream tokens to user, browser session, and/or IP for stronger replay resistance when acceptable for your audience."
      end

      {
        generated_at: Time.now.utc.iso8601,
        requested_profile: profile.to_s.presence,
        owasp_focus_areas: owasp_focus_areas,
        endpoint_controls: endpoint_controls,
        token_policy: token_policy,
        hidden_visibility_controls: hidden_visibility_controls,
        cors_signed_url_review: cors_signed_url_review(active_backend: active_backend, hls_enabled: hls_enabled, presign_ttl: presign_ttl),
        manual_checks_required: manual_checks_required(active_backend: active_backend, hls_enabled: hls_enabled),
        warnings: warnings,
      }
    end

    def for_item(item)
      return {} if item.blank?

      {
        hidden: item.respond_to?(:admin_hidden?) ? item.admin_hidden? : false,
        backend: item.try(:managed_storage_backend).to_s,
        profile: item.try(:managed_storage_profile).to_s,
        delivery_mode: item.try(:delivery_mode).to_s,
        token_binding: {
          main: ::MediaGallery::Token.current_asset_binding(media_item: item, kind: "main").present?,
          thumbnail: ::MediaGallery::Token.current_asset_binding(media_item: item, kind: "thumbnail").present?,
          hls: ::MediaGallery::Token.current_asset_binding(media_item: item, kind: "hls").present?,
        },
        expected_visibility_guards: {
          library_index: true,
          my_items: true,
          show: true,
          thumbnail: true,
          play: true,
          stream: true,
          hls: true,
          admin_preview_thumbnail: true,
        },
      }
    rescue
      {}
    end

    def owasp_focus_areas
      [
        finding("Broken Access Control", "partial", "Admin endpoints are restricted and hidden items are denied on public media endpoints. A full per-item owner/group/private visibility model is still a product/security design decision."),
        finding("Cryptographic Failures", "implemented", "Playback tokens are signed with Rails MessageVerifier, can be bound to the current asset generation, and session-binding uses signed cookies only."),
        finding("Injection", "implemented_with_framework_controls", "Search/filter inputs use constrained allow-lists or parameterized queries; user-editable text fields are normalized to plain text; forensic CSV exports are formula-injection hardened."),
        finding("Insecure Design", "partial", "Copy/verify/switch/cleanup/rollback remain explicit admin-only steps. Optional HLS-only video protection and watermark/fingerprint controls depend on site settings and operational validation."),
        finding("Security Misconfiguration", "manual_validation_required", "Validate bucket privacy, CORS, proxy timeouts, canonical domain, production secrets, and HLS-only/watermark/fingerprint settings outside plugin code."),
        finding("Identification and Authentication Failures", "implemented", "Logged-in access, group-based viewing gates, token TTL, optional user/IP/session binding, revoke, and heartbeat/session limits are available."),
        finding("Software and Data Integrity Failures", "manual_validation_required", "Confirm deployment process, plugin provenance, and dependency/update hygiene in your operations workflow."),
        finding("Security Logging and Monitoring Failures", "partial", "Structured operation logging, security reports, and forensic export retention are available; production log routing and alerting still need operator setup."),
        finding("SSRF", "partial", "Admin forensics source URL mode is restricted to canonical site media/upload paths and configured S3/R2 origins. Future CDN/custom-domain sources require explicit review/allowlisting."),
        finding("CSRF", "partial", "Custom request security now uses canonical Discourse.base_url for same-origin checks, but full Rails-native CSRF restoration is still not complete."),
      ]
    end
    private_class_method :owasp_focus_areas

    def endpoint_controls
      {
        media_mutations_require_same_origin_or_csrf: "partial_custom_control",
        full_rails_native_csrf_restoration: "open",
        admin_controllers_require_admin: "implemented",
        stream_requires_logged_in_and_valid_token: "implemented",
        hls_requires_logged_in_and_valid_token: "implemented",
        hls_only_video_download_prevention: hls_only_video_status,
        watermark_and_fingerprint_controls: watermark_fingerprint_status,
      }
    end
    private_class_method :endpoint_controls

    def hls_only_video_status
      SiteSetting.respond_to?(:media_gallery_protected_video_hls_only) && SiteSetting.media_gallery_protected_video_hls_only ? "enabled" : "available_but_disabled"
    rescue
      "unknown"
    end
    private_class_method :hls_only_video_status

    def watermark_fingerprint_status
      watermark = SiteSetting.respond_to?(:media_gallery_watermark_enabled) && SiteSetting.media_gallery_watermark_enabled
      fingerprint = SiteSetting.respond_to?(:media_gallery_fingerprint_enabled) && SiteSetting.media_gallery_fingerprint_enabled
      if watermark && fingerprint
        "enabled"
      elsif watermark || fingerprint
        "partial"
      else
        "available_but_disabled"
      end
    rescue
      "unknown"
    end
    private_class_method :watermark_fingerprint_status

    def token_policy
      {
        stream_ttl_minutes: SiteSetting.media_gallery_stream_token_ttl_minutes.to_i,
        bind_to_user: !!SiteSetting.media_gallery_bind_stream_to_user,
        bind_to_ip: !!SiteSetting.media_gallery_bind_stream_to_ip,
        bind_to_session: (SiteSetting.respond_to?(:media_gallery_bind_stream_to_session) && !!SiteSetting.media_gallery_bind_stream_to_session),
        revoke_enabled: !!SiteSetting.media_gallery_revoke_enabled,
        heartbeat_enabled: !!SiteSetting.media_gallery_heartbeat_enabled,
        playback_overlay_video_enabled: (SiteSetting.respond_to?(:media_gallery_playback_overlay_video_enabled) && !!SiteSetting.media_gallery_playback_overlay_video_enabled),
        playback_overlay_image_enabled: (SiteSetting.respond_to?(:media_gallery_playback_overlay_image_enabled) && !!SiteSetting.media_gallery_playback_overlay_image_enabled),
        max_active_tokens_per_user: SiteSetting.media_gallery_max_active_tokens_per_user.to_i,
        max_active_tokens_per_ip: SiteSetting.media_gallery_max_active_tokens_per_ip.to_i,
        max_concurrent_sessions_per_user: SiteSetting.media_gallery_max_concurrent_sessions_per_user.to_i,
        max_concurrent_sessions_per_ip: SiteSetting.media_gallery_max_concurrent_sessions_per_ip.to_i,
      }
    end
    private_class_method :token_policy

    def hidden_visibility_controls
      {
        hidden_items_filtered_from_index: true,
        hidden_items_filtered_from_my_items: true,
        hidden_items_blocked_on_show: true,
        hidden_items_blocked_on_thumbnail_without_admin_preview: true,
        hidden_items_blocked_on_play: true,
        hidden_items_blocked_on_stream: true,
        hidden_items_blocked_on_hls: true,
      }
    end
    private_class_method :hidden_visibility_controls

    def cors_signed_url_review(active_backend:, hls_enabled:, presign_ttl:)
      {
        active_backend: active_backend,
        hls_enabled: hls_enabled,
        s3_presign_ttl_seconds: presign_ttl,
        expected_delivery_model: expected_delivery_model(active_backend),
      }
    end
    private_class_method :cors_signed_url_review

    def expected_delivery_model(active_backend)
      return "local or X-Accel delivery after app auth" unless active_backend == "s3"

      if ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect"
        "app-auth plus short redirect/presigned object retrieval"
      else
        "app-auth plus server-side proxy delivery (origin URL hidden from the browser)"
      end
    end
    private_class_method :expected_delivery_model

    def manual_checks_required(active_backend:, hls_enabled:)
      checks = [
        "Confirm reverse proxy and app timeouts are compatible with your largest processing and diagnostics paths.",
        "Confirm production secrets and credentials are stored securely and not checked into source control.",
      ]

      if active_backend == "s3"
        checks << "Confirm the S3 bucket is private and does not allow anonymous reads."
        checks << "Confirm endpoint/region/path-style settings match the intended provider and bucket."
      end

      if active_backend == "s3" && hls_enabled && ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect"
        checks << "Confirm bucket CORS explicitly allows the forum origin for segment delivery."
        checks << "Validate real browser HLS playback end-to-end with short-lived presigned URLs."
      end

      checks
    end
    private_class_method :manual_checks_required

    def finding(title, status, summary)
      { title: title, status: status, summary: summary }
    end
    private_class_method :finding
  end
end
