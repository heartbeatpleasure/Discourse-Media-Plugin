# frozen_string_literal: true

module ::MediaGallery
  class ForensicIdentifySnapshot < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_identify_snapshots"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :raw_result_object, class_name: "MediaGallery::ForensicEvidenceObject"
    belongs_to :attributed_user, class_name: "::User", optional: true
    belongs_to :created_by, class_name: "::User"

    validates :run_ref, presence: true, uniqueness: true
    validates :run_kind, inclusion: { in: %w[production diagnostic] }
    validates :decision, inclusion: { in: MediaGallery::ForensicEvidenceCase::DECISIONS - ["pending"] }
    validates :raw_result_sha256, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :immutable_at, presence: true
    validate :raw_result_case_matches

    private

    def raw_result_case_matches
      return if raw_result_object.blank? || raw_result_object.evidence_case_id == evidence_case_id

      errors.add(:raw_result_object, "must_belong_to_same_evidence_case")
    end
  end
end
