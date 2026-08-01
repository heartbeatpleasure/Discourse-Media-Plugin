# frozen_string_literal: true

class CreateMediaGalleryEvidenceReporting < ActiveRecord::Migration[7.0]
  def up
    create_evidence_cases
    create_evidence_objects
    create_identify_snapshots
    create_reviews
    create_chain_events
    create_reports
    create_packages
    create_legal_holds
  end

  def down
    drop_table :media_gallery_evidence_legal_holds, if_exists: true
    drop_table :media_gallery_evidence_packages, if_exists: true
    drop_table :media_gallery_evidence_reports, if_exists: true
    drop_table :media_gallery_evidence_chain_events, if_exists: true
    drop_table :media_gallery_evidence_reviews, if_exists: true
    drop_table :media_gallery_evidence_identify_snapshots, if_exists: true
    drop_table :media_gallery_evidence_objects, if_exists: true
    drop_table :media_gallery_evidence_cases, if_exists: true
  end

  private

  def create_evidence_cases
    return if table_exists?(:media_gallery_evidence_cases)

    create_table :media_gallery_evidence_cases do |t|
      t.string :case_ref, null: false
      t.integer :media_item_id
      t.string :claimant_ref, null: false
      t.text :research_question, null: false
      t.string :status, null: false, default: "draft"
      t.string :classification, null: false, default: "confidential"
      t.string :decision, null: false, default: "pending"
      t.string :jurisdiction_context, null: false, default: "international"
      t.string :report_language, null: false, default: "en"
      t.text :external_url
      t.string :external_url_sha256
      t.string :external_platform
      t.string :external_username
      t.datetime :external_observed_at
      t.string :external_displayed_at
      t.datetime :rights_statement_received_at
      t.string :rights_statement_ref
      t.boolean :claimant_confirmed, null: false, default: false
      t.datetime :claimant_confirmed_at
      t.boolean :legal_hold, null: false, default: false
      t.datetime :retention_due_at
      t.integer :created_by_id, null: false
      t.integer :updated_by_id
      t.jsonb :media_snapshot, null: false, default: {}
      t.jsonb :settings_snapshot, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_cases, :case_ref, unique: true, name: "idx_mg_evidence_cases_ref"
    add_index :media_gallery_evidence_cases, :media_item_id, name: "idx_mg_evidence_cases_media"
    add_index :media_gallery_evidence_cases, [:status, :created_at], name: "idx_mg_evidence_cases_status_created"
    add_index :media_gallery_evidence_cases, :retention_due_at, name: "idx_mg_evidence_cases_retention"
  end

  def create_evidence_objects
    return if table_exists?(:media_gallery_evidence_objects)

    create_table :media_gallery_evidence_objects do |t|
      t.integer :evidence_case_id, null: false
      t.integer :parent_id
      t.string :object_ref, null: false
      t.string :role, null: false
      t.string :storage_kind, null: false, default: "file"
      t.text :storage_path
      t.text :vault_reference
      t.string :original_filename
      t.string :mime_type
      t.bigint :size_bytes, null: false, default: 0
      t.string :sha256, null: false
      t.string :quarantine_status, null: false, default: "pending"
      t.boolean :include_in_package, null: false, default: false
      t.datetime :immutable_at, null: false
      t.integer :created_by_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_objects, :object_ref, unique: true, name: "idx_mg_evidence_objects_ref"
    add_index :media_gallery_evidence_objects, [:evidence_case_id, :role], name: "idx_mg_evidence_objects_case_role"
    add_index :media_gallery_evidence_objects, :sha256, name: "idx_mg_evidence_objects_sha"
  end

  def create_identify_snapshots
    return if table_exists?(:media_gallery_evidence_identify_snapshots)

    create_table :media_gallery_evidence_identify_snapshots do |t|
      t.integer :evidence_case_id, null: false
      t.integer :raw_result_object_id, null: false
      t.string :run_ref, null: false
      t.string :run_kind, null: false, default: "production"
      t.string :decision, null: false
      t.boolean :conclusive, null: false, default: false
      t.boolean :synthetic_population, null: false, default: false
      t.integer :candidate_population_count, null: false, default: 0
      t.integer :attributed_user_id
      t.string :attributed_username
      t.string :attributed_account_ref
      t.string :fingerprint_id
      t.datetime :fingerprint_assigned_at
      t.string :layout
      t.string :raw_result_sha256, null: false
      t.jsonb :summary, null: false, default: {}
      t.jsonb :account_snapshot, null: false, default: {}
      t.jsonb :fingerprint_snapshot, null: false, default: {}
      t.jsonb :software_snapshot, null: false, default: {}
      t.jsonb :analysis_settings, null: false, default: {}
      t.jsonb :sanity_checks, null: false, default: []
      t.datetime :immutable_at, null: false
      t.integer :created_by_id, null: false
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_identify_snapshots, :run_ref, unique: true, name: "idx_mg_evidence_identify_run_ref"
    add_index :media_gallery_evidence_identify_snapshots, [:evidence_case_id, :created_at], name: "idx_mg_evidence_identify_case_created"
  end

  def create_reviews
    return if table_exists?(:media_gallery_evidence_reviews)

    create_table :media_gallery_evidence_reviews do |t|
      t.integer :evidence_case_id, null: false
      t.string :review_ref, null: false
      t.string :review_kind, null: false
      t.string :reviewer_role, null: false
      t.integer :reviewer_user_id, null: false
      t.string :reviewer_ref, null: false
      t.string :outcome, null: false
      t.text :reason
      t.jsonb :checklist, null: false, default: {}
      t.datetime :reviewed_at, null: false
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_reviews, :review_ref, unique: true, name: "idx_mg_evidence_reviews_ref"
    add_index :media_gallery_evidence_reviews, [:evidence_case_id, :review_kind, :reviewed_at], name: "idx_mg_evidence_reviews_case_kind"
  end

  def create_chain_events
    return if table_exists?(:media_gallery_evidence_chain_events)

    create_table :media_gallery_evidence_chain_events do |t|
      t.integer :evidence_case_id, null: false
      t.string :event_ref, null: false
      t.string :event_type, null: false
      t.string :actor_type, null: false
      t.integer :actor_user_id
      t.string :actor_ref, null: false
      t.string :object_ref
      t.text :reason
      t.string :previous_event_hash
      t.string :event_hash, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_chain_events, :event_ref, unique: true, name: "idx_mg_evidence_chain_ref"
    add_index :media_gallery_evidence_chain_events, [:evidence_case_id, :occurred_at, :id], name: "idx_mg_evidence_chain_case_time"
  end

  def create_reports
    return if table_exists?(:media_gallery_evidence_reports)

    create_table :media_gallery_evidence_reports do |t|
      t.integer :evidence_case_id, null: false
      t.string :report_ref, null: false
      t.integer :version, null: false
      t.string :status, null: false
      t.text :file_path, null: false
      t.string :pdf_sha256, null: false
      t.string :report_data_sha256, null: false
      t.bigint :size_bytes, null: false, default: 0
      t.integer :supersedes_id
      t.datetime :immutable_at, null: false
      t.integer :created_by_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_reports, :report_ref, unique: true, name: "idx_mg_evidence_reports_ref"
    add_index :media_gallery_evidence_reports, [:evidence_case_id, :version], unique: true, name: "idx_mg_evidence_reports_case_ver"
  end

  def create_packages
    return if table_exists?(:media_gallery_evidence_packages)

    create_table :media_gallery_evidence_packages do |t|
      t.integer :evidence_case_id, null: false
      t.integer :evidence_report_id, null: false
      t.string :package_ref, null: false
      t.integer :version, null: false
      t.string :status, null: false
      t.text :file_path, null: false
      t.string :package_sha256, null: false
      t.string :manifest_sha256, null: false
      t.bigint :size_bytes, null: false, default: 0
      t.string :seal_method, null: false, default: "integrity_only"
      t.string :seal_key_id
      t.boolean :signature_verified, null: false, default: false
      t.string :timestamp_status, null: false, default: "not_configured"
      t.datetime :immutable_at, null: false
      t.integer :created_by_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_packages, :package_ref, unique: true, name: "idx_mg_evidence_packages_ref"
    add_index :media_gallery_evidence_packages, [:evidence_case_id, :version], unique: true, name: "idx_mg_evidence_packages_case_ver"
  end

  def create_legal_holds
    return if table_exists?(:media_gallery_evidence_legal_holds)

    create_table :media_gallery_evidence_legal_holds do |t|
      t.integer :evidence_case_id, null: false
      t.string :hold_ref, null: false
      t.string :action, null: false
      t.text :reason, null: false
      t.string :authority_ref
      t.integer :actor_user_id, null: false
      t.string :actor_ref, null: false
      t.datetime :occurred_at, null: false
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_legal_holds, :hold_ref, unique: true, name: "idx_mg_evidence_holds_ref"
    add_index :media_gallery_evidence_legal_holds, [:evidence_case_id, :occurred_at], name: "idx_mg_evidence_holds_case_time"
  end
end
