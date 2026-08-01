# frozen_string_literal: true

module ::MediaGallery
  class ForensicLegalHold < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_legal_holds"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :actor, class_name: "::User", foreign_key: :actor_user_id

    validates :hold_ref, presence: true, uniqueness: true
    validates :action, inclusion: { in: %w[placed released] }
    validates :reason, presence: true, length: { maximum: 4000 }
    validates :actor_ref, presence: true
    validates :occurred_at, presence: true
  end
end
