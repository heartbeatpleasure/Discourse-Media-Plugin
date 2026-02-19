# frozen_string_literal: true

class CreateMediaGalleryPlaybackSessions < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_playback_sessions do |t|
      t.integer :user_id, null: false
      t.integer :media_item_id, null: false
      t.string :fingerprint_id, null: false
      t.string :token_sha256
      t.string :ip
      t.string :user_agent
      t.datetime :played_at
      t.timestamps
    end

    add_index :media_gallery_playback_sessions, :media_item_id, name: "idx_mg_play_sessions_media"
    add_index :media_gallery_playback_sessions, :fingerprint_id, name: "idx_mg_play_sessions_fp"
    add_index :media_gallery_playback_sessions, :played_at, name: "idx_mg_play_sessions_played_at"
    add_index :media_gallery_playback_sessions, [:user_id, :media_item_id, :played_at],
              name: "idx_mg_play_sessions_user_media_time"
  end
end
