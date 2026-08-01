# frozen_string_literal: true

module ::MediaGallery
  class ForensicChainEvent < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_chain_events"

    include ::MediaGallery::EvidenceImmutableRecord

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :actor_user, class_name: "::User", optional: true

    validates :event_ref, presence: true, uniqueness: true
    validates :event_type, presence: true
    validates :actor_type, inclusion: { in: %w[system staff senior_staff privacy_approver] }
    validates :actor_ref, presence: true
    validates :event_hash, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :occurred_at, presence: true
  end
end
