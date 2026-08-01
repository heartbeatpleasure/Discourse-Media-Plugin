# frozen_string_literal: true

module ::MediaGallery
  module EvidenceImmutableRecord
    extend ActiveSupport::Concern

    included do
      before_update :prevent_evidence_mutation
      before_destroy :prevent_evidence_mutation
    end

    private

    def prevent_evidence_mutation
      errors.add(:base, "immutable_evidence_record")
      throw(:abort)
    end
  end
end
