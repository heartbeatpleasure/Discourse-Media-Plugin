# frozen_string_literal: true

# name: discourse-media-plugin
# about: Media gallery API with tokenized streaming, transcoding, tags, gender filter, and likes
# version: 0.1.0
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

enabled_site_setting :media_gallery_enabled

after_initialize do
  module ::MediaGallery
    PLUGIN_NAME = "discourse-secure-media"
  end

  require_relative "lib/media_gallery/engine"
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"

  # Mount engine routes
  Discourse::Application.routes.append do
    mount ::MediaGallery::Engine, at: "/"
  end
end
