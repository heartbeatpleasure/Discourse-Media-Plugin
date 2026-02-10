# frozen_string_literal: true

class AddWatermarkToMediaGalleryMediaItems < ActiveRecord::Migration[7.0]
  def change
    add_column :media_gallery_media_items, :watermark_enabled, :boolean, null: false, default: false
    add_column :media_gallery_media_items, :watermark_preset_id, :string

    add_index :media_gallery_media_items, :watermark_enabled
    add_index :media_gallery_media_items, :watermark_preset_id
  end
end
