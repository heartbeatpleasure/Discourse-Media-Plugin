# frozen_string_literal: true

class EnsureMediaGalleryLogEvents < ActiveRecord::Migration[7.0]
  def up
    create_table :media_gallery_log_events, if_not_exists: true do |t|
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

    ensure_column :media_gallery_log_events, :event_type, :string, null: false
    ensure_column :media_gallery_log_events, :severity, :string, null: false, default: "info"
    ensure_column :media_gallery_log_events, :category, :string, null: false, default: "general"
    ensure_column :media_gallery_log_events, :message, :string
    ensure_column :media_gallery_log_events, :user_id, :integer
    ensure_column :media_gallery_log_events, :media_item_id, :integer
    ensure_column :media_gallery_log_events, :media_public_id, :string
    ensure_column :media_gallery_log_events, :overlay_code, :string
    ensure_column :media_gallery_log_events, :fingerprint_id, :string
    ensure_column :media_gallery_log_events, :ip, :string
    ensure_column :media_gallery_log_events, :request_id, :string
    ensure_column :media_gallery_log_events, :path, :string
    ensure_column :media_gallery_log_events, :method, :string
    ensure_column :media_gallery_log_events, :user_agent_hash, :string
    ensure_column :media_gallery_log_events, :details, :jsonb, null: false, default: {}
    ensure_column :media_gallery_log_events, :created_at, :datetime, null: false
    ensure_column :media_gallery_log_events, :updated_at, :datetime, null: false

    add_index :media_gallery_log_events, :created_at, if_not_exists: true
    add_index :media_gallery_log_events, :event_type, if_not_exists: true
    add_index :media_gallery_log_events, :severity, if_not_exists: true
    add_index :media_gallery_log_events, :user_id, if_not_exists: true
    add_index :media_gallery_log_events, :media_item_id, if_not_exists: true
    add_index :media_gallery_log_events, :media_public_id, if_not_exists: true
    add_index :media_gallery_log_events, :overlay_code, if_not_exists: true
    add_index :media_gallery_log_events, :ip, if_not_exists: true
  end

  def down
    # keep data by default; no-op
  end

  private

  def ensure_column(table, column, type, **options)
    return if column_exists?(table, column)

    add_column(table, column, type, **options)
  end
end
