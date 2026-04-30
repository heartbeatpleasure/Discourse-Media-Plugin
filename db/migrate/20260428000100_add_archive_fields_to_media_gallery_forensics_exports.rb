# frozen_string_literal: true

class AddArchiveFieldsToMediaGalleryForensicsExports < ActiveRecord::Migration[7.0]
  def up
    add_column :media_gallery_forensics_exports, :archive_path, :string unless column_exists?(:media_gallery_forensics_exports, :archive_path)
    add_column :media_gallery_forensics_exports, :archive_bytes, :bigint unless column_exists?(:media_gallery_forensics_exports, :archive_bytes)
    add_column :media_gallery_forensics_exports, :archived_at, :datetime unless column_exists?(:media_gallery_forensics_exports, :archived_at)

    add_index :media_gallery_forensics_exports, :archived_at, name: "idx_mg_forensics_exports_archived_at" unless index_exists?(:media_gallery_forensics_exports, :archived_at, name: "idx_mg_forensics_exports_archived_at")
  end

  def down
    remove_index :media_gallery_forensics_exports, name: "idx_mg_forensics_exports_archived_at" if index_exists?(:media_gallery_forensics_exports, name: "idx_mg_forensics_exports_archived_at")

    remove_column :media_gallery_forensics_exports, :archived_at if column_exists?(:media_gallery_forensics_exports, :archived_at)
    remove_column :media_gallery_forensics_exports, :archive_bytes if column_exists?(:media_gallery_forensics_exports, :archive_bytes)
    remove_column :media_gallery_forensics_exports, :archive_path if column_exists?(:media_gallery_forensics_exports, :archive_path)
  end
end
