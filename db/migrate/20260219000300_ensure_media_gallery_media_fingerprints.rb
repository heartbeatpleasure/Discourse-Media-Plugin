# frozen_string_literal: true

class EnsureMediaGalleryMediaFingerprints < ActiveRecord::Migration[7.0]
  def up
    create_table :media_gallery_media_fingerprints, if_not_exists: true do |t|
      t.integer :user_id, null: false
      t.integer :media_item_id, null: false
      t.string :fingerprint_id, null: false
      t.string :ip
      t.datetime :last_seen_at
      t.timestamps
    end

    execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS idx_mg_fprints_user_media
      ON media_gallery_media_fingerprints (user_id, media_item_id);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_fprints_media_fp
      ON media_gallery_media_fingerprints (media_item_id, fingerprint_id);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_mg_fprints_last_seen
      ON media_gallery_media_fingerprints (last_seen_at);
    SQL
  end

  def down
    # keep data by default; no-op
  end
end
