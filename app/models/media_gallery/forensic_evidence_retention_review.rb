# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceRetentionReview < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_retention_reviews"

    include ::MediaGallery::EvidenceImmutableRecord

    ACTIONS = %w[retain request_disposal cancel_disposal].freeze

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :actor, class_name: "::User", foreign_key: :actor_user_id

    validates :review_ref, presence: true, uniqueness: true
    validates :action, inclusion: { in: ACTIONS }
    validates :retention_class, presence: true
    validates :reason, presence: true, length: { maximum: 4000 }
    validates :actor_ref, presence: true
    validates :occurred_at, presence: true
  end
end
