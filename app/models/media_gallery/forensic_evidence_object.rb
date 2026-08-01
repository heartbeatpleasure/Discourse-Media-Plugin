# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceObject < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_objects"

    ROLES = %w[
      external_original working_copy source_screenshot source_html source_warc source_headers
      rights_statement identify_raw_json reference_snapshot report_pdf package other
    ].freeze
    STORAGE_KINDS = %w[file vault_reference].freeze
    QUARANTINE_STATUSES = %w[pending clean rejected not_applicable].freeze

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :parent, class_name: "MediaGallery::ForensicEvidenceObject", optional: true
    belongs_to :created_by, class_name: "::User"

    validates :object_ref, presence: true, uniqueness: true
    validates :role, inclusion: { in: ROLES }
    validates :storage_kind, inclusion: { in: STORAGE_KINDS }
    validates :sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :quarantine_status, inclusion: { in: QUARANTINE_STATUSES }
    validates :immutable_at, presence: true
    validate :storage_locator_present
    validate :parent_case_matches
    before_update :allow_only_quarantine_transition
    before_destroy :prevent_destroy

    private

    def allow_only_quarantine_transition
      allowed = %w[quarantine_status updated_at]
      forbidden = changes.keys.map(&:to_s) - allowed
      return if forbidden.empty?

      errors.add(:base, "immutable_evidence_object")
      throw(:abort)
    end

    def prevent_destroy
      errors.add(:base, "immutable_evidence_object")
      throw(:abort)
    end

    def parent_case_matches
      return if parent.blank? || parent.evidence_case_id == evidence_case_id

      errors.add(:parent, "must_belong_to_same_evidence_case")
    end

    def storage_locator_present
      return if storage_kind == "file" && storage_path.present?
      return if storage_kind == "vault_reference" && vault_reference.present?

      errors.add(:base, "evidence_storage_locator_missing")
    end
  end
end
