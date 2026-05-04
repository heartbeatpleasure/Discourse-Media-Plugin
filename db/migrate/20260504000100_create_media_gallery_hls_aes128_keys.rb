# frozen_string_literal: true

class CreateMediaGalleryHlsAes128Keys < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_hls_aes128_keys do |t|
      t.integer :media_item_id, null: false
      t.string :key_id, null: false
      t.string :variant, null: false, default: "v0"
      t.string :ab, null: false, default: ""
      t.text :key_ciphertext, null: false
      t.string :iv_hex
      t.string :scheme, null: false, default: "hls_aes128_single_key_v1"
      t.boolean :active, null: false, default: true
      t.integer :key_rotation_segments, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :media_gallery_hls_aes128_keys,
              [:media_item_id, :key_id, :variant, :ab],
              unique: true,
              name: "idx_media_gallery_hls_aes128_keys_unique_lookup"
    add_index :media_gallery_hls_aes128_keys,
              [:media_item_id, :active],
              name: "idx_media_gallery_hls_aes128_keys_item_active"
  end
end
