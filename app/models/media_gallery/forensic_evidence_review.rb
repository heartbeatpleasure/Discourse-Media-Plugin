# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceReview < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_reviews"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :reviewer, class_name: "::User", foreign_key: :reviewer_user_id

    validates :review_ref, presence: true, uniqueness: true
    validates :review_kind, inclusion: { in: %w[technical senior privacy] }
    validates :reviewer_role, inclusion: { in: %w[staff_reviewer senior_staff_reviewer privacy_legal_approver] }
    validates :reviewer_ref, presence: true
    validates :outcome, inclusion: { in: %w[approved rejected] }
    validates :reviewed_at, presence: true
  end
end
