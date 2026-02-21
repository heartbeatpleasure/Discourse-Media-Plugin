# frozen_string_literal: true

# name: Discourse-Media-Plugin
# about: Media gallery API with tokenized streaming + server-side transcoding (no direct upload URLs)
# version: 0.3.1
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

add_admin_route "admin.media_gallery.forensics_exports.title", "mediaGalleryForensicsExports"
add_admin_route "admin.media_gallery.forensics_identify.title", "mediaGalleryForensicsIdentify"

enabled_site_setting :media_gallery_enabled

module ::MediaGallery
  PLUGIN_NAME = "Discourse-Media-Plugin"
end

after_initialize do
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/security"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/hls"
  require_relative "lib/media_gallery/fingerprinting"
  require_relative "lib/media_gallery/type_detector"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"
  require_relative "lib/media_gallery/private_storage"
  require_relative "lib/media_gallery/watermark"   # ✅ NEW
  require_relative "lib/media_gallery/forensics_identify"

  require_dependency File.expand_path("app/models/media_gallery/media_item.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_like.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_fingerprint.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_playback_session.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_forensics_export.rb", __dir__)
  require_dependency File.expand_path("app/serializers/media_gallery/media_item_serializer.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_fingerprints_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_forensics_exports_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/admin_forensics_identify_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/media_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/stream_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/hls_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/library_controller.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_process_item.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_cleanup_originals.rb", __dir__)
  require_dependency File.expand_path("jobs/scheduled/media_gallery_forensics_retention.rb", __dir__)

  Discourse::Application.routes.append do
    # Admin UI page (served by the admin Ember app)
    get "/admin/plugins/media-gallery-forensics-exports" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/media-gallery-forensics-identify" => "admin/plugins#index", constraints: AdminConstraint.new

    get "/media-library" => "media_gallery/library#index"

    # Admin-only forensic helpers
    get "/admin/plugins/media-gallery/fingerprints/:public_id" => "media_gallery/admin_fingerprints#show", defaults: { format: :json }
    get "/admin/plugins/media-gallery/forensics-exports" => "media_gallery/admin_forensics_exports#index", defaults: { format: :json }
    # Download (admin-only). Support both /:id and /:id.csv.
    get "/admin/plugins/media-gallery/forensics-exports/:id" => "media_gallery/admin_forensics_exports#download", constraints: { id: /\d+/ }
    get "/admin/plugins/media-gallery/forensics-exports/:id.csv" => "media_gallery/admin_forensics_exports#download", constraints: { id: /\d+/ }

    # Admin-only: upload a leaked copy to identify likely user/fingerprint.
    get "/admin/plugins/media-gallery/forensics-identify/:public_id" => "media_gallery/admin_forensics_identify#show"
    post "/admin/plugins/media-gallery/forensics-identify/:public_id" => "media_gallery/admin_forensics_identify#identify", defaults: { format: :json }

    get "/media/stream/:token(.:ext)" => "media_gallery/stream#show",
        defaults: { format: :json },
        constraints: { token: /[^\/\.]+/ }

    # HLS (milestone 1)
    get "/media/hls/:public_id/master.m3u8" => "media_gallery/hls#master"
    get "/media/hls/:public_id/v/:variant/index.m3u8" => "media_gallery/hls#variant"
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
  end
end
