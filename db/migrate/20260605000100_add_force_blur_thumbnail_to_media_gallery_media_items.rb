# frozen_string_literal: true

class AddForceBlurThumbnailToMediaGalleryMediaItems < ActiveRecord::Migration[7.0]
  def change
    return if column_exists?(:media_gallery_media_items, :force_blur_thumbnail)

    add_column :media_gallery_media_items, :force_blur_thumbnail, :boolean, null: false, default: false
  end
end
