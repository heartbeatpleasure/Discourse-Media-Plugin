# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceReport < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_reports"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :created_by, class_name: "::User"
    belongs_to :supersedes, class_name: "MediaGallery::ForensicEvidenceReport", optional: true

    validates :report_ref, presence: true, uniqueness: true
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :status, inclusion: { in: %w[draft final_unsealed final_sealed superseded withdrawn] }
    validates :pdf_sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :report_data_sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :immutable_at, presence: true
    validate :supersedes_case_matches

    private

    def supersedes_case_matches
      return if supersedes.blank? || supersedes.evidence_case_id == evidence_case_id

      errors.add(:supersedes, "must_belong_to_same_evidence_case")
    end
  end
end
