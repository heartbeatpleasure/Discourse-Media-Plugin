# frozen_string_literal: true

class CreateMediaGalleryForensicsExports < ActiveRecord::Migration[7.0]
  def change
    create_table :media_gallery_forensics_exports do |t|
      t.datetime :cutoff_at, null: false
      t.integer :rows_count, null: false, default: 0
      t.string :filename
      t.string :sha256
      t.binary :csv_gzip, null: false
      t.timestamps
    end

    add_index :media_gallery_forensics_exports, :created_at, name: "idx_mg_forensics_exports_created_at"
    add_index :media_gallery_forensics_exports, :cutoff_at, name: "idx_mg_forensics_exports_cutoff_at"
  end
end
