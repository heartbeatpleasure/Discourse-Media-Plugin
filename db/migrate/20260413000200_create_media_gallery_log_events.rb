# frozen_string_literal: true

class CreateMediaGalleryLogEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_log_events do |t|
      t.string :event_type, null: false
      t.string :severity, null: false, default: "info"
      t.string :category, null: false, default: "general"
      t.string :message
      t.integer :user_id
      t.integer :media_item_id
      t.string :media_public_id
      t.string :overlay_code
      t.string :fingerprint_id
      t.string :ip
      t.string :request_id
      t.string :path
      t.string :method
      t.string :user_agent_hash
      t.jsonb :details, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_log_events, :created_at
    add_index :media_gallery_log_events, :event_type
    add_index :media_gallery_log_events, :severity
    add_index :media_gallery_log_events, :user_id
    add_index :media_gallery_log_events, :media_item_id
    add_index :media_gallery_log_events, :media_public_id
    add_index :media_gallery_log_events, :overlay_code
    add_index :media_gallery_log_events, :ip
  end
end
