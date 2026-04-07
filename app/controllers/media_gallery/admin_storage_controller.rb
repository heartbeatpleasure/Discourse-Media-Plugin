# frozen_string_literal: true

module ::MediaGallery
  class AdminStorageController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/storage/health.json?profile=active|target
    def health
      profile = params[:profile].to_s.presence || "active"
      render_json_dump(::MediaGallery::StorageHealth.health(profile: profile))
    end

    # POST /admin/plugins/media-gallery/storage/probe.json
    def probe
      profile = params[:profile].to_s.presence || "active"
      render_json_dump(::MediaGallery::StorageHealth.probe!(profile: profile))
    end
  end
end
