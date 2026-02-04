# frozen_string_literal: true

module ::MediaGallery
  class Engine < ::Rails::Engine
    engine_name "media_gallery"
    isolate_namespace MediaGallery
  end
end

MediaGallery::Engine.routes.draw do
  # Stream endpoint (tokenized)
  get "/stream/:token" => "stream#show", constraints: { token: /[^\/]+/ }

  # Convenience route for "my items" must come before :public_id
  get "/my" => "media#my"

  # Gallery
  get "/" => "media#index"
  post "/" => "media#create"

  # Item
  get "/:public_id" => "media#show"
  get "/:public_id/status" => "media#status"
  post "/:public_id/play" => "media#play"
  get "/:public_id/thumbnail" => "media#thumbnail"

  # Likes (toggle)
  post "/:public_id/like" => "media#toggle_like"
end
