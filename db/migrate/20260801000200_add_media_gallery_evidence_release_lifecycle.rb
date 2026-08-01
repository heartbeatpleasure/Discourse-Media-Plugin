# frozen_string_literal: true

class AddMediaGalleryEvidenceReleaseLifecycle < ActiveRecord::Migration[7.0]
  def up
    add_case_lifecycle_columns
    create_evidence_disclosures
  end

  def down
    drop_table :media_gallery_evidence_disclosures, if_exists: true

    if table_exists?(:media_gallery_evidence_cases)
      remove_index :media_gallery_evidence_cases, name: "idx_mg_evidence_cases_supersedes", if_exists: true
      remove_index :media_gallery_evidence_cases, name: "idx_mg_evidence_cases_superseded_by", if_exists: true
      remove_column :media_gallery_evidence_cases, :supersedes_case_id, if_exists: true
      remove_column :media_gallery_evidence_cases, :superseded_by_case_id, if_exists: true
      remove_column :media_gallery_evidence_cases, :lifecycle_reason, if_exists: true
      remove_column :media_gallery_evidence_cases, :closed_at, if_exists: true
      remove_column :media_gallery_evidence_cases, :pre_legal_hold_status, if_exists: true
    end
  end

  private

  def add_case_lifecycle_columns
    return unless table_exists?(:media_gallery_evidence_cases)

    add_column :media_gallery_evidence_cases, :supersedes_case_id, :integer unless column_exists?(:media_gallery_evidence_cases, :supersedes_case_id)
    add_column :media_gallery_evidence_cases, :superseded_by_case_id, :integer unless column_exists?(:media_gallery_evidence_cases, :superseded_by_case_id)
    add_column :media_gallery_evidence_cases, :lifecycle_reason, :text unless column_exists?(:media_gallery_evidence_cases, :lifecycle_reason)
    add_column :media_gallery_evidence_cases, :closed_at, :datetime unless column_exists?(:media_gallery_evidence_cases, :closed_at)
    add_column :media_gallery_evidence_cases, :pre_legal_hold_status, :string unless column_exists?(:media_gallery_evidence_cases, :pre_legal_hold_status)

    add_index :media_gallery_evidence_cases, :supersedes_case_id, unique: true, name: "idx_mg_evidence_cases_supersedes" unless index_exists?(:media_gallery_evidence_cases, :supersedes_case_id, name: "idx_mg_evidence_cases_supersedes")
    add_index :media_gallery_evidence_cases, :superseded_by_case_id, unique: true, name: "idx_mg_evidence_cases_superseded_by" unless index_exists?(:media_gallery_evidence_cases, :superseded_by_case_id, name: "idx_mg_evidence_cases_superseded_by")
  end

  def create_evidence_disclosures
    return if table_exists?(:media_gallery_evidence_disclosures)

    create_table :media_gallery_evidence_disclosures do |t|
      t.integer :evidence_case_id, null: false
      t.integer :evidence_package_id, null: false
      t.string :disclosure_ref, null: false
      t.string :recipient_ref, null: false
      t.text :purpose, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.integer :max_downloads, null: false, default: 1
      t.integer :download_count, null: false, default: 0
      t.integer :released_by_id, null: false
      t.datetime :released_at, null: false
      t.datetime :first_downloaded_at
      t.datetime :last_downloaded_at
      t.datetime :revoked_at
      t.integer :revoked_by_id
      t.text :revocation_reason
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_disclosures, :disclosure_ref, unique: true, name: "idx_mg_evidence_disclosures_ref"
    add_index :media_gallery_evidence_disclosures, :token_digest, unique: true, name: "idx_mg_evidence_disclosures_token"
    add_index :media_gallery_evidence_disclosures, [:evidence_case_id, :created_at], name: "idx_mg_evidence_disclosures_case_created"
    add_index :media_gallery_evidence_disclosures, [:evidence_package_id, :created_at], name: "idx_mg_evidence_disclosures_package_created"
    add_index :media_gallery_evidence_disclosures, :expires_at, name: "idx_mg_evidence_disclosures_expiry"
  end
end
