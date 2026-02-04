# frozen_string_literal: true

class CreateMediaGalleryMediaLikes < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_media_likes do |t|
      t.integer :user_id, null: false
      t.integer :media_item_id, null: false
      t.timestamps
    end

    add_index :media_gallery_media_likes, [:user_id, :media_item_id], unique: true, name: "idx_media_gallery_like_unique"
    add_index :media_gallery_media_likes, :media_item_id
  end
end
