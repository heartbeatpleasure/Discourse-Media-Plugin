# frozen_string_literal: true

class CreateMediaGalleryOverlaySessions < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_overlay_sessions do |t|
      t.integer :media_item_id, null: false
      t.integer :user_id, null: false
      t.string :overlay_code, null: false
      t.string :media_type, null: false
      t.string :fingerprint_id
      t.string :token_sha256
      t.string :rendered_text, limit: 500
      t.string :ip
      t.text :user_agent
      t.timestamps null: false
    end

    add_index :media_gallery_overlay_sessions, :overlay_code, name: "idx_mg_overlay_sessions_code"
    add_index :media_gallery_overlay_sessions, :media_item_id, name: "idx_mg_overlay_sessions_media"
    add_index :media_gallery_overlay_sessions, :user_id, name: "idx_mg_overlay_sessions_user"
    add_index :media_gallery_overlay_sessions, [:media_item_id, :overlay_code], name: "idx_mg_overlay_sessions_media_code"
    add_index :media_gallery_overlay_sessions, :updated_at, name: "idx_mg_overlay_sessions_updated_at"
  end
end
