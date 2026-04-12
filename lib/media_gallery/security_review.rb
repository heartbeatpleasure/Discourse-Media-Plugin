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
      warnings << "When using S3 HLS delivery, verify bucket CORS only allows the forum origin and required methods/headers." if active_backend == "s3" && hls_enabled
      warnings << "Confirm the S3 bucket is not publicly readable; playback should rely on short redirects/presigned URLs." if active_backend == "s3"
      warnings << "Bind stream tokens to user and/or IP for stronger replay resistance when acceptable for your audience." if !SiteSetting.media_gallery_bind_stream_to_user && !SiteSetting.media_gallery_bind_stream_to_ip

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
        finding("Broken Access Control", "implemented", "Admin endpoints use admin-only controllers; owner/staff checks protect update/delete/retry; hidden items are denied on public media endpoints."),
        finding("Cryptographic Failures", "implemented", "Playback tokens are signed with Rails MessageVerifier and can be bound to the current asset generation."),
        finding("Injection", "implemented_with_framework_controls", "Search/filter inputs use constrained allow-lists or parameterized queries; no raw user input is interpolated into storage keys."),
        finding("Insecure Design", "implemented", "Copy/verify/switch/cleanup/rollback/finalize remain explicit steps with admin-only access and diagnostics."),
        finding("Security Misconfiguration", "manual_validation_required", "Validate bucket privacy, CORS, proxy timeouts, and production-only secrets outside plugin code."),
        finding("Identification and Authentication Failures", "implemented", "Logged-in access, group-based viewing, token TTL, optional user/IP binding, revoke, and heartbeat/session limits are available."),
        finding("Software and Data Integrity Failures", "manual_validation_required", "Confirm deployment process, plugin provenance, and dependency/update hygiene in your operations workflow."),
        finding("Security Logging and Monitoring Failures", "implemented", "Structured operation logging and admin diagnostics are available; production log routing still needs operator setup."),
        finding("SSRF", "limited_surface_manual_validation_required", "The plugin does not proxy arbitrary user URLs for playback; validate any external forensic fetch workflows separately."),
        finding("CSRF", "implemented", "Sensitive write/token-issuing media endpoints require a verified CSRF request or same-origin browser context."),
      ]
    end
    private_class_method :owasp_focus_areas

    def endpoint_controls
      {
        media_mutations_require_same_origin_or_csrf: true,
        admin_controllers_require_admin: true,
        stream_requires_logged_in_and_valid_token: true,
        hls_requires_logged_in_and_valid_token: true,
      }
    end
    private_class_method :endpoint_controls

    def token_policy
      {
        stream_ttl_minutes: SiteSetting.media_gallery_stream_token_ttl_minutes.to_i,
        bind_to_user: !!SiteSetting.media_gallery_bind_stream_to_user,
        bind_to_ip: !!SiteSetting.media_gallery_bind_stream_to_ip,
        revoke_enabled: !!SiteSetting.media_gallery_revoke_enabled,
        heartbeat_enabled: !!SiteSetting.media_gallery_heartbeat_enabled,
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
        expected_delivery_model: active_backend == "s3" ? "app-auth plus short redirect/presigned object retrieval" : "local or X-Accel delivery after app auth",
      }
    end
    private_class_method :cors_signed_url_review

    def manual_checks_required(active_backend:, hls_enabled:)
      checks = [
        "Confirm reverse proxy and app timeouts are compatible with your largest processing and diagnostics paths.",
        "Confirm production secrets and credentials are stored securely and not checked into source control.",
      ]

      if active_backend == "s3"
        checks << "Confirm the S3 bucket is private and does not allow anonymous reads."
        checks << "Confirm endpoint/region/path-style settings match the intended provider and bucket."
      end

      if active_backend == "s3" && hls_enabled
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
