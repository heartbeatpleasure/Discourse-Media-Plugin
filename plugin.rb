# frozen_string_literal: true

# name: Discourse-Media-Plugin
# about: Media gallery API with tokenized streaming, transcoding, tags, gender filter, and likes
# version: 0.1.0
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

enabled_site_setting :media_gallery_enabled

module ::MediaGallery
  # Must match plugin directory and plugin.rb name exactly (case-sensitive)
  PLUGIN_NAME = "Discourse-Media-Plugin"
end

after_initialize do
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"

  # IMPORTANT: Define routes directly on the main router, and prepend them
  # so they are matched before Discourse catch-all routes.
  Discourse::Application.routes.prepend do
    # Stream endpoint (tokenized)
    get "/media/stream/:token" => "media_gallery/stream#show", constraints: { token: /[^\/]+/ }

    # Convenience route for "my items" must come before :public_id
    get "/media/my" => "media_gallery/media#my"

    # Gallery
    get  "/media" => "media_gallery/media#index"
    post "/media" => "media_gallery/media#create"

    # Item
    get  "/media/:public_id" => "media_gallery/media#show"
    get  "/media/:public_id/status" => "media_gallery/media#status"
    post "/media/:public_id/play" => "media_gallery/media#play"
    get  "/media/:public_id/thumbnail" => "media_gallery/media#thumbnail"

    # Likes (toggle)
    post "/media/:public_id/like" => "media_gallery/media#toggle_like"
  end
end
