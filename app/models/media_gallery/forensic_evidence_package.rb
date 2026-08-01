# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidencePackage < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_packages"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :evidence_report, class_name: "MediaGallery::ForensicEvidenceReport"
    belongs_to :created_by, class_name: "::User"

    validates :package_ref, presence: true, uniqueness: true
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :status, inclusion: { in: %w[integrity_only cms_signed sealed verification_failed] }
    validates :package_sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :manifest_sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :seal_method, inclusion: { in: %w[integrity_only cms_detached] }
    validates :timestamp_status, inclusion: { in: %w[not_configured present_unverified verified] }
    validates :immutable_at, presence: true
    validate :report_case_matches

    private

    def report_case_matches
      return if evidence_report.blank? || evidence_report.evidence_case_id == evidence_case_id

      errors.add(:evidence_report, "must_belong_to_same_evidence_case")
    end
  end
end
