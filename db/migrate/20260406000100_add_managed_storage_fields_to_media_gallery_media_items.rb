# frozen_string_literal: true

class AddManagedStorageFieldsToMediaGalleryMediaItems < ActiveRecord::Migration[7.0]
  def change
    change_table :media_gallery_media_items do |t|
      t.string :managed_storage_backend
      t.string :managed_storage_profile
      t.jsonb :storage_manifest, null: false, default: {}
      t.string :migration_state, null: false, default: "none"
      t.text :migration_error
      t.string :delivery_mode
      t.integer :storage_schema_version, null: false, default: 1
    end

    add_index :media_gallery_media_items, :managed_storage_backend
    add_index :media_gallery_media_items, :migration_state
  end
end
