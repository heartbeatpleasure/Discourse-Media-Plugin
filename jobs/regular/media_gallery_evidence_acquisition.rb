# frozen_string_literal: true

module Jobs
  class MediaGalleryEvidenceAcquisition < ::Jobs::Base
    sidekiq_options queue: "default", retry: 2

    def execute(args)
      record = ::MediaGallery::ForensicEvidenceObject.find_by(id: args[:evidence_object_id].to_i)
      return if record.blank?

      ::MediaGallery::EvidenceAcquisition.process!(
        record,
        requested_by_id: args[:requested_by_id].presence&.to_i,
        inspection_only: ActiveModel::Type::Boolean.new.cast(args[:inspection_only]),
      )
    end
  end
end
