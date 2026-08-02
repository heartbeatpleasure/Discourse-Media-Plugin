# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidencePrivacyRequest < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_privacy_requests"

    REQUEST_TYPES = %w[access rectification erasure restriction objection other].freeze
    STATUSES = %w[open under_review resolved rejected withdrawn].freeze

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :created_by, class_name: "::User"
    belongs_to :resolved_by, class_name: "::User", optional: true

    validates :request_ref, presence: true, uniqueness: true
    validates :request_type, inclusion: { in: REQUEST_TYPES }
    validates :requester_ref, presence: true, length: { maximum: 200 }
    validates :status, inclusion: { in: STATUSES }
    validates :received_at, presence: true
    validates :due_at, presence: true
    validates :created_by_ref, presence: true

    def open?
      %w[open under_review].include?(status)
    end
  end
end
