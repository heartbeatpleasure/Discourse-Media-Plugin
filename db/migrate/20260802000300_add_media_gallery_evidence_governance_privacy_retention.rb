# frozen_string_literal: true

class AddMediaGalleryEvidenceGovernancePrivacyRetention < ActiveRecord::Migration[7.0]
  def up
    add_case_governance_columns
    add_legal_hold_review_column
    create_retention_reviews
    create_privacy_requests
    create_identity_annexes
  end

  def down
    drop_table :media_gallery_evidence_identity_annexes, if_exists: true
    drop_table :media_gallery_evidence_privacy_requests, if_exists: true
    drop_table :media_gallery_evidence_retention_reviews, if_exists: true

    if table_exists?(:media_gallery_evidence_legal_holds)
      remove_column :media_gallery_evidence_legal_holds, :review_due_at, if_exists: true
    end

    return unless table_exists?(:media_gallery_evidence_cases)

    remove_index :media_gallery_evidence_cases, name: "idx_mg_evidence_cases_governance_ref", if_exists: true
    remove_index :media_gallery_evidence_cases, name: "idx_mg_evidence_cases_retention_review", if_exists: true
    remove_index :media_gallery_evidence_cases, name: "idx_mg_evidence_cases_privacy_open", if_exists: true
    remove_column :media_gallery_evidence_cases, :governance_profile_ref, if_exists: true
    remove_column :media_gallery_evidence_cases, :governance_snapshot, if_exists: true
    remove_column :media_gallery_evidence_cases, :retention_class, if_exists: true
    remove_column :media_gallery_evidence_cases, :retention_reviewed_at, if_exists: true
    remove_column :media_gallery_evidence_cases, :retention_review_due_at, if_exists: true
    remove_column :media_gallery_evidence_cases, :processing_restricted, if_exists: true
    remove_column :media_gallery_evidence_cases, :privacy_request_open, if_exists: true
  end

  private

  def add_case_governance_columns
    return unless table_exists?(:media_gallery_evidence_cases)

    add_column :media_gallery_evidence_cases, :governance_profile_ref, :string unless column_exists?(:media_gallery_evidence_cases, :governance_profile_ref)
    add_column :media_gallery_evidence_cases, :governance_snapshot, :jsonb, null: false, default: {} unless column_exists?(:media_gallery_evidence_cases, :governance_snapshot)
    add_column :media_gallery_evidence_cases, :retention_class, :string, null: false, default: "incomplete" unless column_exists?(:media_gallery_evidence_cases, :retention_class)
    add_column :media_gallery_evidence_cases, :retention_reviewed_at, :datetime unless column_exists?(:media_gallery_evidence_cases, :retention_reviewed_at)
    add_column :media_gallery_evidence_cases, :retention_review_due_at, :datetime unless column_exists?(:media_gallery_evidence_cases, :retention_review_due_at)
    add_column :media_gallery_evidence_cases, :processing_restricted, :boolean, null: false, default: false unless column_exists?(:media_gallery_evidence_cases, :processing_restricted)
    add_column :media_gallery_evidence_cases, :privacy_request_open, :boolean, null: false, default: false unless column_exists?(:media_gallery_evidence_cases, :privacy_request_open)

    add_index :media_gallery_evidence_cases, :governance_profile_ref, name: "idx_mg_evidence_cases_governance_ref" unless index_exists?(:media_gallery_evidence_cases, :governance_profile_ref, name: "idx_mg_evidence_cases_governance_ref")
    add_index :media_gallery_evidence_cases, :retention_review_due_at, name: "idx_mg_evidence_cases_retention_review" unless index_exists?(:media_gallery_evidence_cases, :retention_review_due_at, name: "idx_mg_evidence_cases_retention_review")
    add_index :media_gallery_evidence_cases, :privacy_request_open, name: "idx_mg_evidence_cases_privacy_open" unless index_exists?(:media_gallery_evidence_cases, :privacy_request_open, name: "idx_mg_evidence_cases_privacy_open")

    execute <<~SQL
      UPDATE media_gallery_evidence_cases
      SET retention_review_due_at = COALESCE(retention_review_due_at, retention_due_at)
      WHERE retention_review_due_at IS NULL
    SQL

    execute <<~SQL
      UPDATE media_gallery_evidence_cases AS evidence_case
      SET retention_class = CASE
        WHEN evidence_case.status IN ('withdrawn', 'superseded') THEN 'rejected'
        WHEN evidence_case.status IN ('packaged', 'sealed', 'released')
          OR EXISTS (
            SELECT 1
            FROM media_gallery_evidence_packages AS package
            WHERE package.evidence_case_id = evidence_case.id
          ) THEN 'sealed_released'
        WHEN evidence_case.decision = 'conclusive_match' THEN 'conclusive'
        WHEN evidence_case.decision IN ('likely_match', 'ambiguous', 'no_match') THEN 'non_conclusive'
        ELSE 'incomplete'
      END
    SQL
  end

  def add_legal_hold_review_column
    return unless table_exists?(:media_gallery_evidence_legal_holds)

    add_column :media_gallery_evidence_legal_holds, :review_due_at, :datetime unless column_exists?(:media_gallery_evidence_legal_holds, :review_due_at)
    execute <<~SQL
      UPDATE media_gallery_evidence_legal_holds
      SET review_due_at = occurred_at + INTERVAL '180 days'
      WHERE action = 'placed' AND review_due_at IS NULL
    SQL
  end

  def create_retention_reviews
    return if table_exists?(:media_gallery_evidence_retention_reviews)

    create_table :media_gallery_evidence_retention_reviews do |t|
      t.integer :evidence_case_id, null: false
      t.string :review_ref, null: false
      t.string :action, null: false
      t.string :retention_class, null: false
      t.datetime :previous_due_at
      t.datetime :next_due_at
      t.text :reason, null: false
      t.integer :actor_user_id, null: false
      t.string :actor_ref, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_retention_reviews, :review_ref, unique: true, name: "idx_mg_evidence_retention_reviews_ref"
    add_index :media_gallery_evidence_retention_reviews, [:evidence_case_id, :occurred_at], name: "idx_mg_evidence_retention_reviews_case_time"
  end

  def create_privacy_requests
    return if table_exists?(:media_gallery_evidence_privacy_requests)

    create_table :media_gallery_evidence_privacy_requests do |t|
      t.integer :evidence_case_id, null: false
      t.string :request_ref, null: false
      t.string :request_type, null: false
      t.string :requester_ref, null: false
      t.string :status, null: false, default: "open"
      t.datetime :received_at, null: false
      t.datetime :due_at, null: false
      t.boolean :processing_restricted, null: false, default: false
      t.text :decision
      t.text :reason
      t.integer :created_by_id, null: false
      t.string :created_by_ref, null: false
      t.integer :resolved_by_id
      t.string :resolved_by_ref
      t.datetime :resolved_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_privacy_requests, :request_ref, unique: true, name: "idx_mg_evidence_privacy_requests_ref"
    add_index :media_gallery_evidence_privacy_requests, [:evidence_case_id, :status], name: "idx_mg_evidence_privacy_requests_case_status"
    add_index :media_gallery_evidence_privacy_requests, :due_at, name: "idx_mg_evidence_privacy_requests_due"
  end

  def create_identity_annexes
    return if table_exists?(:media_gallery_evidence_identity_annexes)

    create_table :media_gallery_evidence_identity_annexes do |t|
      t.integer :evidence_case_id, null: false
      t.string :annex_ref, null: false
      t.integer :version, null: false
      t.string :status, null: false, default: "draft"
      t.text :ciphertext, null: false
      t.string :iv, null: false
      t.string :auth_tag, null: false
      t.string :key_id, null: false
      t.string :payload_sha256, null: false
      t.jsonb :categories, null: false, default: []
      t.string :necessity_reason_sha256, null: false
      t.integer :created_by_id, null: false
      t.string :created_by_ref, null: false
      t.integer :senior_approved_by_id
      t.string :senior_approved_by_ref
      t.datetime :senior_approved_at
      t.integer :privacy_approved_by_id
      t.string :privacy_approved_by_ref
      t.datetime :privacy_approved_at
      t.datetime :last_viewed_at
      t.datetime :last_exported_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :media_gallery_evidence_identity_annexes, :annex_ref, unique: true, name: "idx_mg_evidence_identity_annexes_ref"
    add_index :media_gallery_evidence_identity_annexes, [:evidence_case_id, :version], unique: true, name: "idx_mg_evidence_identity_annexes_case_ver"
    add_index :media_gallery_evidence_identity_annexes, [:evidence_case_id, :status], name: "idx_mg_evidence_identity_annexes_case_status"
  end
end
