# frozen_string_literal: true

class EnsureMediaGalleryLogEvents < ActiveRecord::Migration[7.0]
  def change
    unless table_exists?(:media_gallery_log_events)
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
    end

    add_column :media_gallery_log_events, :event_type, :string, null: false unless column_exists?(:media_gallery_log_events, :event_type)
    add_column :media_gallery_log_events, :severity, :string, null: false, default: "info" unless column_exists?(:media_gallery_log_events, :severity)
    add_column :media_gallery_log_events, :category, :string, null: false, default: "general" unless column_exists?(:media_gallery_log_events, :category)
    add_column :media_gallery_log_events, :message, :string unless column_exists?(:media_gallery_log_events, :message)
    add_column :media_gallery_log_events, :user_id, :integer unless column_exists?(:media_gallery_log_events, :user_id)
    add_column :media_gallery_log_events, :media_item_id, :integer unless column_exists?(:media_gallery_log_events, :media_item_id)
    add_column :media_gallery_log_events, :media_public_id, :string unless column_exists?(:media_gallery_log_events, :media_public_id)
    add_column :media_gallery_log_events, :overlay_code, :string unless column_exists?(:media_gallery_log_events, :overlay_code)
    add_column :media_gallery_log_events, :fingerprint_id, :string unless column_exists?(:media_gallery_log_events, :fingerprint_id)
    add_column :media_gallery_log_events, :ip, :string unless column_exists?(:media_gallery_log_events, :ip)
    add_column :media_gallery_log_events, :request_id, :string unless column_exists?(:media_gallery_log_events, :request_id)
    add_column :media_gallery_log_events, :path, :string unless column_exists?(:media_gallery_log_events, :path)
    add_column :media_gallery_log_events, :method, :string unless column_exists?(:media_gallery_log_events, :method)
    add_column :media_gallery_log_events, :user_agent_hash, :string unless column_exists?(:media_gallery_log_events, :user_agent_hash)
    add_column :media_gallery_log_events, :details, :jsonb, null: false, default: {} unless column_exists?(:media_gallery_log_events, :details)
    add_timestamps :media_gallery_log_events, null: false unless column_exists?(:media_gallery_log_events, :created_at)

    add_index :media_gallery_log_events, :created_at, if_not_exists: true
    add_index :media_gallery_log_events, :event_type, if_not_exists: true
    add_index :media_gallery_log_events, :severity, if_not_exists: true
    add_index :media_gallery_log_events, :user_id, if_not_exists: true
    add_index :media_gallery_log_events, :media_item_id, if_not_exists: true
    add_index :media_gallery_log_events, :media_public_id, if_not_exists: true
    add_index :media_gallery_log_events, :overlay_code, if_not_exists: true
    add_index :media_gallery_log_events, :ip, if_not_exists: true
  end
end
