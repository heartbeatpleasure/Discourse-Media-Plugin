# frozen_string_literal: true

module ::MediaGallery
  class AdminAccessController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_media_gallery_admin_landing_access

    def index
      render_json_dump(::MediaGallery::AdminAccess.landing_access_payload(current_user))
    end

    private

    def ensure_media_gallery_admin_landing_access
      ::MediaGallery::AdminAccess.ensure_landing_access!(current_user)
    end
  end
end
