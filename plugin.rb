# frozen_string_literal: true

# name: discourse-media-plugin
# about: Media gallery API with tokenized streaming, transcoding, tags, gender filter, and likes
# version: 0.1.0
# authors: Your Team
# url: https://example.invalid

enabled_site_setting :media_gallery_enabled

after_initialize do
  module ::MediaGallery
    PLUGIN_NAME = "discourse-media-plugin"
  end

  require_relative "lib/media_gallery/engine"
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"

  Discourse::Application.routes.append do
    mount ::MediaGallery::Engine, at: "/"
  end
end
