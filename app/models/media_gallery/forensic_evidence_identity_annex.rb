# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceIdentityAnnex < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_identity_annexes"

    STATUSES = %w[draft pending_approval approved exported withdrawn].freeze

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :created_by, class_name: "::User"
    belongs_to :senior_approved_by, class_name: "::User", optional: true
    belongs_to :privacy_approved_by, class_name: "::User", optional: true

    validates :annex_ref, presence: true, uniqueness: true
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :status, inclusion: { in: STATUSES }
    validates :ciphertext, :iv, :auth_tag, :key_id, :payload_sha256, presence: true
    validates :key_id, length: { maximum: 200 }
    validates :necessity_reason_sha256, :payload_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :categories, presence: true
    validate :categories_are_supported
    validates :created_by_ref, presence: true

    def fully_approved?
      senior_approved_at.present? && privacy_approved_at.present?
    end

    private

    def categories_are_supported
      values = categories.is_a?(Array) ? categories.map(&:to_s) : []
      errors.add(:categories, "contains unsupported values") unless values.present? && (values - ::MediaGallery::EvidenceIdentityAnnex::CATEGORIES).empty?
    end
  end
end
