# frozen_string_literal: true

class AddFileStorageToMediaGalleryForensicsExports < ActiveRecord::Migration[7.0]
  def up
    if column_exists?(:media_gallery_forensics_exports, :csv_gzip)
      change_column_null :media_gallery_forensics_exports, :csv_gzip, true
    end

    add_column :media_gallery_forensics_exports, :storage, :string, null: false, default: "db" unless column_exists?(:media_gallery_forensics_exports, :storage)
    add_column :media_gallery_forensics_exports, :file_path, :string unless column_exists?(:media_gallery_forensics_exports, :file_path)
    add_column :media_gallery_forensics_exports, :file_bytes, :bigint unless column_exists?(:media_gallery_forensics_exports, :file_bytes)

    add_index :media_gallery_forensics_exports, :storage, name: "idx_mg_forensics_exports_storage" unless index_exists?(:media_gallery_forensics_exports, :storage, name: "idx_mg_forensics_exports_storage")
  end

  def down
    remove_index :media_gallery_forensics_exports, name: "idx_mg_forensics_exports_storage" if index_exists?(:media_gallery_forensics_exports, :storage, name: "idx_mg_forensics_exports_storage")

    remove_column :media_gallery_forensics_exports, :file_bytes if column_exists?(:media_gallery_forensics_exports, :file_bytes)
    remove_column :media_gallery_forensics_exports, :file_path if column_exists?(:media_gallery_forensics_exports, :file_path)
    remove_column :media_gallery_forensics_exports, :storage if column_exists?(:media_gallery_forensics_exports, :storage)

    change_column_null :media_gallery_forensics_exports, :csv_gzip, false if column_exists?(:media_gallery_forensics_exports, :csv_gzip)
  end
end
