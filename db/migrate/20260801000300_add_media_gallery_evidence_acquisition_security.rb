# frozen_string_literal: true

class AddMediaGalleryEvidenceAcquisitionSecurity < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:media_gallery_evidence_objects)

    add_column :media_gallery_evidence_objects, :scan_metadata, :jsonb, null: false, default: {} unless column_exists?(:media_gallery_evidence_objects, :scan_metadata)
    add_column :media_gallery_evidence_objects, :inspection_metadata, :jsonb, null: false, default: {} unless column_exists?(:media_gallery_evidence_objects, :inspection_metadata)
    add_column :media_gallery_evidence_objects, :scan_started_at, :datetime unless column_exists?(:media_gallery_evidence_objects, :scan_started_at)
    add_column :media_gallery_evidence_objects, :scan_completed_at, :datetime unless column_exists?(:media_gallery_evidence_objects, :scan_completed_at)
    add_column :media_gallery_evidence_objects, :inspected_at, :datetime unless column_exists?(:media_gallery_evidence_objects, :inspected_at)

    add_index :media_gallery_evidence_objects, :quarantine_status, name: "idx_mg_evidence_objects_quarantine" unless index_exists?(:media_gallery_evidence_objects, :quarantine_status, name: "idx_mg_evidence_objects_quarantine")
  end

  def down
    return unless table_exists?(:media_gallery_evidence_objects)

    remove_index :media_gallery_evidence_objects, name: "idx_mg_evidence_objects_quarantine", if_exists: true
    remove_column :media_gallery_evidence_objects, :inspected_at, if_exists: true
    remove_column :media_gallery_evidence_objects, :scan_completed_at, if_exists: true
    remove_column :media_gallery_evidence_objects, :scan_started_at, if_exists: true
    remove_column :media_gallery_evidence_objects, :inspection_metadata, if_exists: true
    remove_column :media_gallery_evidence_objects, :scan_metadata, if_exists: true
  end
end
