# frozen_string_literal: true

class CreateMediaGalleryMediaComments < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_media_comments do |t|
      t.integer :media_item_id, null: false
      t.integer :user_id, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "visible"
      t.datetime :deleted_at
      t.integer :deleted_by_id
      t.jsonb :extra_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :media_gallery_media_comments, [:media_item_id, :id], name: "idx_media_gallery_comments_item_id"
    add_index :media_gallery_media_comments, [:media_item_id, :status, :id], name: "idx_media_gallery_comments_item_status_id"
    add_index :media_gallery_media_comments, [:user_id, :created_at], name: "idx_media_gallery_comments_user_created"

    add_column :media_gallery_media_items, :comments_count, :integer, null: false, default: 0
    add_column :media_gallery_media_items, :last_commented_at, :datetime
    add_index :media_gallery_media_items, :comments_count
    add_index :media_gallery_media_items, :last_commented_at
  end
end
