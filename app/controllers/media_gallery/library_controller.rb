# frozen_string_literal: true

module ::MediaGallery
  class LibraryController < ::ApplicationController
    requires_plugin ::MediaGallery::PLUGIN_NAME

    before_action :ensure_logged_in

    def index
      # Theme component renders the Ember route + template.
      render layout: "application"
    end
  end
end
