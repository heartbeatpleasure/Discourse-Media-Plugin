# frozen_string_literal: true

module ::MediaGallery
  class Engine < ::Rails::Engine
    engine_name "media_gallery"
    isolate_namespace MediaGallery
  end
end

MediaGallery::Engine.routes.draw do
  # Stream endpoint (tokenized)
  get "/media/stream/:token" => "stream#show", constraints: { token: /[^\/]+/ }

  # Convenience route for "my items" must come before :public_id
  get "/media/my" => "media#my"

  # Gallery
  get "/media" => "media#index"
  post "/media" => "media#create"

  # Item
  get "/media/:public_id" => "media#show"
  get "/media/:public_id/status" => "media#status"
  post "/media/:public_id/play" => "media#play"
  get "/media/:public_id/thumbnail" => "media#thumbnail"

  # Likes (toggle)
  post "/media/:public_id/like" => "media#toggle_like"
end
