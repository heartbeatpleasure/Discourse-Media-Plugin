# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceCase < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_cases"

    STATUSES = %w[
      draft intake_verified source_captured evidence_acquired identified review_pending reviewed
      claimant_confirmed approved_for_seal packaged sealed released legal_hold superseded withdrawn
    ].freeze
    CLASSIFICATIONS = %w[internal confidential restricted].freeze
    DECISIONS = %w[pending conclusive_match likely_match ambiguous no_match].freeze

    belongs_to :media_item, class_name: "MediaGallery::MediaItem", optional: true
    belongs_to :created_by, class_name: "::User"
    belongs_to :updated_by, class_name: "::User", optional: true
    belongs_to :supersedes_case, class_name: "MediaGallery::ForensicEvidenceCase", optional: true
    belongs_to :superseded_by_case, class_name: "MediaGallery::ForensicEvidenceCase", optional: true

    has_many :evidence_objects,
             class_name: "MediaGallery::ForensicEvidenceObject",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :identify_snapshots,
             class_name: "MediaGallery::ForensicIdentifySnapshot",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :reviews,
             class_name: "MediaGallery::ForensicEvidenceReview",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :chain_events,
             class_name: "MediaGallery::ForensicChainEvent",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :reports,
             class_name: "MediaGallery::ForensicEvidenceReport",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :packages,
             class_name: "MediaGallery::ForensicEvidencePackage",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :legal_holds,
             class_name: "MediaGallery::ForensicLegalHold",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :disclosures,
             class_name: "MediaGallery::ForensicEvidenceDisclosure",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :retention_reviews,
             class_name: "MediaGallery::ForensicEvidenceRetentionReview",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :privacy_requests,
             class_name: "MediaGallery::ForensicEvidencePrivacyRequest",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error
    has_many :identity_annexes,
             class_name: "MediaGallery::ForensicEvidenceIdentityAnnex",
             foreign_key: :evidence_case_id,
             dependent: :restrict_with_error

    validates :case_ref, presence: true, uniqueness: true
    validates :claimant_ref, presence: true, length: { maximum: 200 }
    validates :research_question, presence: true, length: { maximum: 4000 }
    validates :status, inclusion: { in: STATUSES }
    validates :classification, inclusion: { in: CLASSIFICATIONS }
    validates :decision, inclusion: { in: DECISIONS }
    validates :report_language, inclusion: { in: %w[en] }
    validates :retention_class, inclusion: { in: %w[incomplete rejected non_conclusive conclusive sealed_released] }, allow_blank: true

    before_validation :ensure_case_ref, on: :create

    def ensure_case_ref
      self.case_ref ||= ::MediaGallery::EvidenceReference.case_ref
    end

    def latest_identify_snapshot
      identify_snapshots.order(created_at: :desc, id: :desc).first
    end

    def latest_report
      reports.order(version: :desc).first
    end

    def latest_package
      packages.order(version: :desc).first
    end

    def sealed?
      status == "sealed"
    end

    def mutable?
      return false if %w[packaged sealed released superseded withdrawn].include?(status)
      return false if status == "legal_hold" && packages.exists?

      true
    end
  end
end
