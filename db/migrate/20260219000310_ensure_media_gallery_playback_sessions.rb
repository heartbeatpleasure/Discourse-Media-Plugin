# frozen_string_literal: true

class EnsureMediaGalleryPlaybackSessions < ActiveRecord::Migration[7.0]
  def up
    create_table :media_gallery_playback_sessions, if_not_exists: true do |t|
      t.integer :user_id, null: false
      t.integer :media_item_id, null: false
      t.string :fingerprint_id, null: false
      t.string :token_sha256
      t.string :ip
      t.string :user_agent
      t.datetime :played_at
      t.timestamps
    end

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_play_sessions_media
      ON media_gallery_playback_sessions (media_item_id);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_play_sessions_fp
      ON media_gallery_playback_sessions (fingerprint_id);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_play_sessions_played_at
      ON media_gallery_playback_sessions (played_at);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_play_sessions_user_media_time
      ON media_gallery_playback_sessions (user_id, media_item_id, played_at);
    SQL
  end

  def down
    # keep data by default; no-op
  end
end
