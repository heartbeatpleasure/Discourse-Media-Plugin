# frozen_string_literal: true

class AddHlsDeliveryReceiptToMediaGalleryPlaybackSessions < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:media_gallery_playback_sessions)

    add_column :media_gallery_playback_sessions, :hls_variant, :string unless column_exists?(:media_gallery_playback_sessions, :hls_variant)
    add_column :media_gallery_playback_sessions, :hls_variant_sequence, :text unless column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence)
    add_column :media_gallery_playback_sessions, :hls_variant_sequence_sha256, :string unless column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence_sha256)
    add_column :media_gallery_playback_sessions, :hls_variant_sequence_length, :integer unless column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence_length)
    add_column :media_gallery_playback_sessions, :hls_manifest_sha256, :string unless column_exists?(:media_gallery_playback_sessions, :hls_manifest_sha256)
    add_column :media_gallery_playback_sessions, :hls_delivery_signature, :string unless column_exists?(:media_gallery_playback_sessions, :hls_delivery_signature)
    add_column :media_gallery_playback_sessions, :hls_delivery_meta, :jsonb, null: false, default: {} unless column_exists?(:media_gallery_playback_sessions, :hls_delivery_meta)

    add_index :media_gallery_playback_sessions, :hls_variant_sequence_sha256,
              name: "idx_mg_play_sessions_hls_seq_sha",
              if_not_exists: true
    add_index :media_gallery_playback_sessions, :hls_manifest_sha256,
              name: "idx_mg_play_sessions_hls_manifest_sha",
              if_not_exists: true
  end

  def down
    return unless table_exists?(:media_gallery_playback_sessions)

    remove_index :media_gallery_playback_sessions, name: "idx_mg_play_sessions_hls_manifest_sha" if index_exists?(:media_gallery_playback_sessions, name: "idx_mg_play_sessions_hls_manifest_sha")
    remove_index :media_gallery_playback_sessions, name: "idx_mg_play_sessions_hls_seq_sha" if index_exists?(:media_gallery_playback_sessions, name: "idx_mg_play_sessions_hls_seq_sha")

    remove_column :media_gallery_playback_sessions, :hls_delivery_meta if column_exists?(:media_gallery_playback_sessions, :hls_delivery_meta)
    remove_column :media_gallery_playback_sessions, :hls_delivery_signature if column_exists?(:media_gallery_playback_sessions, :hls_delivery_signature)
    remove_column :media_gallery_playback_sessions, :hls_manifest_sha256 if column_exists?(:media_gallery_playback_sessions, :hls_manifest_sha256)
    remove_column :media_gallery_playback_sessions, :hls_variant_sequence_length if column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence_length)
    remove_column :media_gallery_playback_sessions, :hls_variant_sequence_sha256 if column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence_sha256)
    remove_column :media_gallery_playback_sessions, :hls_variant_sequence if column_exists?(:media_gallery_playback_sessions, :hls_variant_sequence)
    remove_column :media_gallery_playback_sessions, :hls_variant if column_exists?(:media_gallery_playback_sessions, :hls_variant)
  end
end
