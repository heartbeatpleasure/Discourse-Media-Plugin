# frozen_string_literal: true

class CreateMediaGalleryMediaItems < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_media_items do |t|
      t.string  :public_id, null: false

      t.integer :user_id, null: false

      t.integer :original_upload_id
      t.integer :processed_upload_id
      t.integer :thumbnail_upload_id

      t.string  :media_type
      t.string  :status, null: false, default: "queued"

      t.string  :title, null: false
      t.text    :description

      t.string  :gender
      t.text    :tags, array: true, default: []

      t.integer :duration_seconds
      t.integer :width
      t.integer :height

      t.bigint  :filesize_original_bytes
      t.bigint  :filesize_processed_bytes

      t.integer :views_count, null: false, default: 0
      t.integer :likes_count, null: false, default: 0

      t.text    :error_message
      t.jsonb   :extra_metadata, null: false, default: {}

      t.timestamps
    end

    add_index :media_gallery_media_items, :public_id, unique: true
    add_index :media_gallery_media_items, :status
    add_index :media_gallery_media_items, :media_type
    add_index :media_gallery_media_items, :gender
    add_index :media_gallery_media_items, :created_at
    add_index :media_gallery_media_items, :tags, using: "gin"
  end
end
