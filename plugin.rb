# frozen_string_literal: true

# name: Discourse-Media-Plugin
# about: Media gallery API with tokenized streaming + server-side transcoding (no direct upload URLs)
# version: 0.3.1
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

add_admin_route "admin.media_gallery.title", "mediaGallery"

enabled_site_setting :media_gallery_enabled

module ::MediaGallery
  PLUGIN_NAME = "Discourse-Media-Plugin"
end

after_initialize do
  begin
    Rails.application.config.filter_parameters |= [
      :token,
      :stream_token,
      :hls_token,
      :access_token,
      :auth_token,
      :sig,
      :signature,
      :authorization,
      :cookie,
    ]
  rescue
    # Keep plugin boot resilient if Rails filter configuration is unavailable.
  end

  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/path_security"
  require_relative "lib/media_gallery/storage_settings_resolver"
  require_relative "lib/media_gallery/request_security"
  require_relative "lib/media_gallery/security_review"
  require_relative "lib/media_gallery/operation_errors"
  require_relative "lib/media_gallery/operation_logger"
  require_relative "lib/media_gallery/operation_coordinator"
  require_relative "lib/media_gallery/orphan_inspector"
  require_relative "lib/media_gallery/storage_health"
  require_relative "lib/media_gallery/storage_safety"
  require_relative "lib/media_gallery/storage_reconciler"
  require_relative "lib/media_gallery/migration_preview"
  require_relative "lib/media_gallery/migration_run_history"
  require_relative "lib/media_gallery/migration_copy"
  require_relative "lib/media_gallery/migration_switch"
  require_relative "lib/media_gallery/migration_cleanup"
  require_relative "lib/media_gallery/migration_verify"
  require_relative "lib/media_gallery/migration_rollback"
  require_relative "lib/media_gallery/migration_finalize"
  require_relative "lib/media_gallery/processing_workspace"
  require_relative "lib/media_gallery/temp_workspace_cleanup"
  require_relative "lib/media_gallery/source_acquirer"
  require_relative "lib/media_gallery/text_sanitizer"
  require_relative "lib/media_gallery/asset_store"
  require_relative "lib/media_gallery/local_asset_store"
  require_relative "lib/media_gallery/s3_asset_store"
  require_relative "lib/media_gallery/asset_manifest"
  require_relative "lib/media_gallery/delivery_resolver"
  require_relative "lib/media_gallery/security"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/hls"
  require_relative "lib/media_gallery/hls_aes128"
  require_relative "lib/media_gallery/hls_aes128_backfill"
  require_relative "lib/media_gallery/hls_clear_rollback"
  require_relative "lib/media_gallery/hls_aes128_maintenance"
  require_relative "lib/media_gallery/hls_integrity_verifier"
  require_relative "lib/media_gallery/fingerprinting"
  require_relative "lib/media_gallery/type_detector"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"
  require_relative "lib/media_gallery/private_storage"
  require_relative "lib/media_gallery/test_downloads"
  require_relative "lib/media_gallery/forensics_identify_tasks"
  require_relative "lib/media_gallery/forensics_identify_file_runner"
  require_relative "lib/media_gallery/watermark"   # ✅ NEW
  require_relative "lib/media_gallery/playback_overlay"
  require_relative "lib/media_gallery/forensics_identify"
  require_relative "lib/media_gallery/log_events"
  require_relative "lib/media_gallery/processing_notifications"
  require_relative "lib/media_gallery/health_check"

  require_dependency File.expand_path("app/models/media_gallery/media_item.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/hls_aes128_key.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_like.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_fingerprint.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_playback_session.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_overlay_session.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_forensics_export.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_log_event.rb", __dir__)
  require_dependency File.expand_path("app/serializers/media_gallery/media_item_serializer.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_fingerprints_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_forensics_exports_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_forensics_identify_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_media_items_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_reports_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_health_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_logs_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_storage_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_security_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_test_downloads_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_user_diagnostics_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/media_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/stream_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/hls_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/library_controller.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_generate_test_download.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_forensics_identify_job.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_process_item.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_copy_item_to_target.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_cleanup_source_after_switch.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_hls_aes128_backfill_item.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_hls_clear_rollback_item.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_cleanup_originals.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_forensics_retention.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_health_watchdog.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_temp_workspace_cleanup.rb", __dir__)

  Discourse::Application.routes.append do
    # Admin UI page (served by the admin Ember app)
    get "/admin/plugins/media-gallery" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-forensics-exports" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-forensics-identify" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-test-downloads" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-migrations" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-management" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-reports" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-health" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-logs" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-user-diagnostics" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-security" => "admin/plugins#index", constraints: AdminConstraint.new

    get "/media-library" => "media_gallery/library#index"

    # Admin-only forensic helpers
    get "/admin/plugins/media-gallery/fingerprints/:public_id" => "media_gallery/admin_fingerprints#show", defaults: { format: :json }
    get "/admin/plugins/media-gallery/forensics-exports" => "media_gallery/admin_forensics_exports#index", defaults: { format: :json }
    # Download (admin-only). Support both /:id and /:id.csv.
    get "/admin/plugins/media-gallery/forensics-exports/:id" => "media_gallery/admin_forensics_exports#download", constraints: { id: /\d+/ }
    get "/admin/plugins/media-gallery/forensics-exports/:id.csv" => "media_gallery/admin_forensics_exports#download", constraints: { id: /\d+/ }
    delete "/admin/plugins/media-gallery/forensics-exports/:id" => "media_gallery/admin_forensics_exports#destroy", defaults: { format: :json }, constraints: { id: /\d+/ }

    get "/admin/plugins/media-gallery/forensics-identify/overlay-lookup" => "media_gallery/admin_forensics_identify#overlay_lookup", defaults: { format: :json }

    # Admin-only: upload a leaked copy to identify likely user/fingerprint.
    get "/admin/plugins/media-gallery/forensics-identify/:public_id" => "media_gallery/admin_forensics_identify#show"
    post "/admin/plugins/media-gallery/forensics-identify/:public_id" => "media_gallery/admin_forensics_identify#identify", defaults: { format: :json }
    post "/admin/plugins/media-gallery/forensics-identify/:public_id/queue" => "media_gallery/admin_forensics_identify#queue", defaults: { format: :json }
    post "/admin/plugins/media-gallery/forensics-identify/:public_id/preflight" => "media_gallery/admin_forensics_identify#preflight", defaults: { format: :json }
    get "/admin/plugins/media-gallery/forensics-identify/status/:task_id" => "media_gallery/admin_forensics_identify#status", defaults: { format: :json }

    # Admin-only helper to find media items by public_id/title/id.
    get "/admin/plugins/media-gallery/media-items/search" => "media_gallery/admin_media_items#search", defaults: { format: :json }
    get "/admin/plugins/media-gallery/reports" => "media_gallery/admin_reports#index", defaults: { format: :json }
    get "/admin/plugins/media-gallery/health" => "media_gallery/admin_health#index", defaults: { format: :json }
    get "/admin/plugins/media-gallery/security" => "media_gallery/admin_security#index", defaults: { format: :json }
    post "/admin/plugins/media-gallery/health/reconcile" => "media_gallery/admin_health#reconcile", defaults: { format: :json }
    get "/admin/plugins/media-gallery/health/reconciliation-export" => "media_gallery/admin_health#reconciliation_export", defaults: { format: :json }
    post "/admin/plugins/media-gallery/health/ignore" => "media_gallery/admin_health#ignore", defaults: { format: :json }
    delete "/admin/plugins/media-gallery/health/ignore" => "media_gallery/admin_health#unignore", defaults: { format: :json }
    post "/admin/plugins/media-gallery/reports/:report_id/review" => "media_gallery/admin_reports#review", defaults: { format: :json }
    post "/admin/plugins/media-gallery/reports/:report_id/block-owner" => "media_gallery/admin_reports#block_owner", defaults: { format: :json }
    post "/admin/plugins/media-gallery/reports/:report_id/unblock-owner" => "media_gallery/admin_reports#unblock_owner", defaults: { format: :json }
    post "/admin/plugins/media-gallery/reports/:report_id/block-owner-upload" => "media_gallery/admin_reports#block_owner_upload", defaults: { format: :json }
    post "/admin/plugins/media-gallery/reports/:report_id/unblock-owner-upload" => "media_gallery/admin_reports#unblock_owner_upload", defaults: { format: :json }
    get "/admin/plugins/media-gallery/storage/profiles" => "media_gallery/admin_storage#profiles", defaults: { format: :json }
    get "/admin/plugins/media-gallery/storage/health" => "media_gallery/admin_storage#health", defaults: { format: :json }
    get "/admin/plugins/media-gallery/logs" => "media_gallery/admin_logs#index", defaults: { format: :json }
    get "/admin/plugins/media-gallery/user-diagnostics/search" => "media_gallery/admin_user_diagnostics#search", defaults: { format: :json }
    get "/admin/plugins/media-gallery/user-diagnostics/:user_id" => "media_gallery/admin_user_diagnostics#show", defaults: { format: :json }
    post "/admin/plugins/media-gallery/storage/probe" => "media_gallery/admin_storage#probe", defaults: { format: :json }
    get "/admin/plugins/media-gallery/media-items/:public_id/management" => "media_gallery/admin_media_items#management", defaults: { format: :json }
    put "/admin/plugins/media-gallery/media-items/:public_id/admin-update" => "media_gallery/admin_media_items#admin_update", defaults: { format: :json }
    patch "/admin/plugins/media-gallery/media-items/:public_id/admin-update" => "media_gallery/admin_media_items#admin_update", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/visibility" => "media_gallery/admin_media_items#visibility", defaults: { format: :json }
    delete "/admin/plugins/media-gallery/media-items/:public_id/admin-destroy" => "media_gallery/admin_media_items#admin_destroy", defaults: { format: :json }
    get "/admin/plugins/media-gallery/media-items/:public_id/diagnostics" => "media_gallery/admin_media_items#diagnostics", defaults: { format: :json }
    get "/admin/plugins/media-gallery/media-items/:public_id/diagnostics-bundle" => "media_gallery/admin_media_items#diagnostics_bundle", defaults: { format: :json }
    get "/admin/plugins/media-gallery/media-items/:public_id/migration-plan" => "media_gallery/admin_media_items#migration_plan", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/copy-to-target" => "media_gallery/admin_media_items#copy_to_target", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/switch-to-target" => "media_gallery/admin_media_items#switch_to_target", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/cleanup-source" => "media_gallery/admin_media_items#cleanup_source", defaults: { format: :json }
    get "/admin/plugins/media-gallery/media-items/:public_id/verify-target" => "media_gallery/admin_media_items#verify_target", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/verify-hls-integrity" => "media_gallery/admin_media_items#verify_hls_integrity", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/aes-backfill" => "media_gallery/admin_media_items#aes_backfill", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/aes-backfill/restart" => "media_gallery/admin_media_items#restart_aes_backfill", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/aes-backfill/clear" => "media_gallery/admin_media_items#clear_aes_backfill", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/aes-maintenance/cleanup" => "media_gallery/admin_media_items#aes_maintenance_cleanup", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/hls-clear-rollback" => "media_gallery/admin_media_items#hls_clear_rollback", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/hls-clear-rollback/restart" => "media_gallery/admin_media_items#restart_hls_clear_rollback", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/hls-clear-rollback/clear" => "media_gallery/admin_media_items#clear_hls_clear_rollback", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/bulk-aes-backfill" => "media_gallery/admin_media_items#bulk_aes_backfill", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/rollback-to-source" => "media_gallery/admin_media_items#rollback_to_source", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/finalize-migration" => "media_gallery/admin_media_items#finalize_migration", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/clear-queued-state" => "media_gallery/admin_media_items#clear_queued_state", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/bulk-migrate" => "media_gallery/admin_media_items#bulk_migrate", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/retry-processing" => "media_gallery/admin_media_items#retry_processing", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/block-owner" => "media_gallery/admin_media_items#block_owner", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/unblock-owner" => "media_gallery/admin_media_items#unblock_owner", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/block-owner-upload" => "media_gallery/admin_media_items#block_owner_upload", defaults: { format: :json }
    post "/admin/plugins/media-gallery/media-items/:public_id/unblock-owner-upload" => "media_gallery/admin_media_items#unblock_owner_upload", defaults: { format: :json }

    # Admin-only: generate temporary personalized remux/clip downloads for testing.
    post "/admin/plugins/media-gallery/test-downloads/:public_id" => "media_gallery/admin_test_downloads#create", defaults: { format: :json }
    get "/admin/plugins/media-gallery/test-downloads/status/:task_id" => "media_gallery/admin_test_downloads#status", defaults: { format: :json }
    get "/admin/plugins/media-gallery/test-downloads/:public_id/:artifact_id" => "media_gallery/admin_test_downloads#download"

    get "/media/stream" => "media_gallery/stream#show",
        defaults: { format: :json }

    get "/media/stream/:token(.:ext)" => "media_gallery/stream#show",
        defaults: { format: :json },
        constraints: { token: /[^\/\.]+/ }

    # HLS (milestone 1)
    get "/media/hls/:public_id/master.m3u8" => "media_gallery/hls#master"
    get "/media/hls/:public_id/v/:variant/index.m3u8" => "media_gallery/hls#variant"
    # AES-128 HLS key delivery. The key_id is public metadata; the key bytes are
    # only returned by the controller after the same HLS token/session/user checks
    # as playlist and segment delivery.
    get "/media/hls/:public_id/key/:key_id.key" => "media_gallery/hls#key",
        constraints: { key_id: /[A-Za-z0-9_-]+/ }
    # Segment requests can include a per-segment fingerprint variant (a|b).
    get "/media/hls/:public_id/seg/:variant/:ab/:segment" => "media_gallery/hls#segment",
        constraints: { ab: /a|b/i, segment: /[^\/]+/ }
    # Backwards-compatible (no a|b in path)
    get "/media/hls/:public_id/seg/:variant/:segment" => "media_gallery/hls#segment",
        constraints: { segment: /[^\/]+/ }

    get "/media/my" => "media_gallery/media#my", defaults: { format: :json }
    get "/user/media" => "media_gallery/media#my", defaults: { format: :json }

    # config endpoint (must be before /media/:public_id)
    # NOTE: do not name controller action `config` (conflicts with ActionController::Base#config)
    get "/media/config" => "media_gallery/media#plugin_config", defaults: { format: :json }

    get "/media" => "media_gallery/media#index", defaults: { format: :json }
    post "/media" => "media_gallery/media#create", defaults: { format: :json }
    put "/media/:public_id" => "media_gallery/media#update", defaults: { format: :json }
    patch "/media/:public_id" => "media_gallery/media#update", defaults: { format: :json }

    get "/media/:public_id" => "media_gallery/media#show", defaults: { format: :json }
    delete "/media/:public_id" => "media_gallery/media#destroy", defaults: { format: :json }

    get "/media/:public_id/status" => "media_gallery/media#status", defaults: { format: :json }
    get "/media/:public_id/status.json" => "media_gallery/media#status", defaults: { format: :json }

    get "/media/:public_id/play" => "media_gallery/media#play", defaults: { format: :json }
    post "/media/:public_id/play" => "media_gallery/media#play", defaults: { format: :json }

    # Client heartbeat for best-effort concurrent session limiting
    post "/media/heartbeat" => "media_gallery/media#heartbeat", defaults: { format: :json }

    # Best-effort early token revocation (on overlay close/ended)
    post "/media/revoke" => "media_gallery/media#revoke", defaults: { format: :json }

    get "/media/:public_id/thumbnail" => "media_gallery/media#thumbnail"

    post "/media/:public_id/retry" => "media_gallery/media#retry_processing", defaults: { format: :json }

    post "/media/:public_id/like" => "media_gallery/media#like", defaults: { format: :json }
    post "/media/:public_id/unlike" => "media_gallery/media#unlike", defaults: { format: :json }
    post "/media/:public_id/report" => "media_gallery/media#report", defaults: { format: :json }
  end
end
