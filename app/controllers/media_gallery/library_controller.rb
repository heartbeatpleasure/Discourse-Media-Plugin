# frozen_string_literal: true

module ::MediaGallery
  class LibraryController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_can_view

    def index
      # Theme component renders the Ember route + template.
      render layout: "application"
    end

    private

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end
  end
end
