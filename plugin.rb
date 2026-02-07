# frozen_string_literal: true

# name: Discourse-Media-Plugin
# about: Media gallery API with tokenized streaming + server-side transcoding (no direct upload URLs)
# version: 0.2.8
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

enabled_site_setting :media_gallery_enabled

module ::MediaGallery
  PLUGIN_NAME = "Discourse-Media-Plugin"
end

after_initialize do
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"

  require_dependency File.expand_path("app/models/media_gallery/media_item.rb", __dir__)
  require_dependency File.expand_path("app/models/media_gallery/media_like.rb", __dir__)
  require_dependency File.expand_path("app/serializers/media_gallery/media_item_serializer.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/media_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/media_gallery/stream_controller.rb", __dir__)
  require_dependency File.expand_path("jobs/regular/media_gallery_process_item.rb", __dir__)

  Discourse::Application.routes.append do
    get  "/media/stream/:token(.:ext)" => "media_gallery/stream#show", constraints: { token: /[^\/\.]+/ }

    get  "/media/my" => "media_gallery/media#my"
    get  "/user/media" => "media_gallery/media#my"

    get  "/media" => "media_gallery/media#index"
    get  "/media.json" => "media_gallery/media#index", defaults: { format: :json }

    post "/media" => "media_gallery/media#create", defaults: { format: :json }

    get  "/media/:public_id" => "media_gallery/media#show"
    get  "/media/:public_id.json" => "media_gallery/media#show", defaults: { format: :json }
    get  "/media/:public_id/status" => "media_gallery/media#status"
    post "/media/:public_id/play" => "media_gallery/media#play", defaults: { format: :json }
    get  "/media/:public_id/thumbnail" => "media_gallery/media#thumbnail"

    # NEW: retry processing for failed/queued items (owner/staff only)
    post "/media/:public_id/retry" => "media_gallery/media#retry_processing", defaults: { format: :json }

    post "/media/:public_id/like" => "media_gallery/media#like", defaults: { format: :json }
    post "/media/:public_id/unlike" => "media_gallery/media#unlike", defaults: { format: :json }
  end
end
