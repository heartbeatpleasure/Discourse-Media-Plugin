# frozen_string_literal: true

# name: Discourse-Media-Plugin
# about: Media gallery API with tokenized streaming, transcoding, tags, gender filter, and likes
# version: 0.1.0
# authors: Chris
# url: https://github.com/heartbeatpleasure/Discourse-Media-Plugin

enabled_site_setting :media_gallery_enabled

module ::MediaGallery
  # Must match plugin directory name AND plugin.rb "# name:" exactly
  PLUGIN_NAME = "Discourse-Media-Plugin"
end

after_initialize do
  require_relative "lib/media_gallery/engine"
  require_relative "lib/media_gallery/token"
  require_relative "lib/media_gallery/ffmpeg"
  require_relative "lib/media_gallery/upload_path"
  require_relative "lib/media_gallery/permissions"

  # Prepend so routes are matched before Discourse catch-all
  Discourse::Application.routes.prepend do
    mount ::MediaGallery::Engine, at: "/"
  end
end
