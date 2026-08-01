# frozen_string_literal: true

module ::MediaGallery
  class ForensicEvidenceDisclosure < ::ActiveRecord::Base
    self.table_name = "media_gallery_evidence_disclosures"

    belongs_to :evidence_case, class_name: "MediaGallery::ForensicEvidenceCase"
    belongs_to :evidence_package, class_name: "MediaGallery::ForensicEvidencePackage"
    belongs_to :released_by, class_name: "::User"
    belongs_to :revoked_by, class_name: "::User", optional: true

    validates :disclosure_ref, presence: true, uniqueness: true
    validates :recipient_ref, presence: true, length: { maximum: 200 }
    validates :purpose, presence: true, length: { maximum: 4000 }
    validates :token_digest, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/i }
    validates :expires_at, :released_at, presence: true
    validates :max_downloads, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 20 }
    validates :download_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :package_case_matches
    validate :revocation_fields_consistent
    validate :immutable_release_fields, on: :update
    validate :monotonic_release_state, on: :update

    scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.now.utc).where("download_count < max_downloads") }

    def revoked?
      revoked_at.present?
    end

    def expired?(at: Time.now.utc)
      expires_at <= at
    end

    def consumed?
      download_count >= max_downloads
    end

    def active?(at: Time.now.utc)
      !revoked? && !expired?(at: at) && !consumed?
    end

    def status(at: Time.now.utc)
      return "revoked" if revoked?
      return "expired" if expired?(at: at)
      return "consumed" if consumed?
      return "downloaded" if download_count.positive?

      "active"
    end

    private

    IMMUTABLE_RELEASE_FIELDS = %w[
      evidence_case_id evidence_package_id disclosure_ref recipient_ref purpose token_digest expires_at
      max_downloads released_by_id released_at metadata
    ].freeze

    def immutable_release_fields
      IMMUTABLE_RELEASE_FIELDS.each do |field|
        errors.add(field, "is_immutable") if will_save_change_to_attribute?(field)
      end
    end

    def monotonic_release_state
      previous_count = attribute_in_database("download_count").to_i
      errors.add(:download_count, "cannot_decrease") if download_count.to_i < previous_count
      errors.add(:download_count, "cannot_exceed_max_downloads") if download_count.to_i > max_downloads.to_i

      previous_first = attribute_in_database("first_downloaded_at")
      if previous_first.present? && will_save_change_to_first_downloaded_at?
        errors.add(:first_downloaded_at, "is_immutable_once_set")
      end

      previous_last = attribute_in_database("last_downloaded_at")
      if previous_last.present? && last_downloaded_at.present? && last_downloaded_at < previous_last
        errors.add(:last_downloaded_at, "cannot_move_backwards")
      end

      previous_revoked_at = attribute_in_database("revoked_at")
      if previous_revoked_at.present? && (will_save_change_to_revoked_at? || will_save_change_to_revoked_by_id? || will_save_change_to_revocation_reason?)
        errors.add(:revoked_at, "is_immutable_once_set")
      end
    end

    def package_case_matches
      return if evidence_package.blank? || evidence_case.blank?
      return if evidence_package.evidence_case_id == evidence_case_id

      errors.add(:evidence_package, "must_belong_to_same_evidence_case")
    end

    def revocation_fields_consistent
      if revoked_at.present? && revoked_by_id.blank?
        errors.add(:revoked_by, "must_be_present_when_revoked")
      end
    end
  end
end
