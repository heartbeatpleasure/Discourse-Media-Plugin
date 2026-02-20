# frozen_string_literal: true

require "zlib"

module ::MediaGallery
  class MediaForensicsExport < ::ActiveRecord::Base
    self.table_name = "media_gallery_forensics_exports"

    validates :cutoff_at, presence: true
    validates :rows_count, presence: true

    validate :has_export_payload

    def file_exists?
      file_path.present? && ::File.exist?(file_path)
    end

    def csv_bytes
      if csv_gzip.present?
        return ::Zlib.gunzip(csv_gzip)
      end

      raise Discourse::NotFound if file_path.blank?

      bytes = ::File.binread(file_path)
      if file_path.end_with?(".gz")
        ::Zlib.gunzip(bytes)
      else
        bytes
      end
    end

    def download_filename
      filename.presence || "media_gallery_playback_sessions_export_#{id}.csv"
    end

    private

    def has_export_payload
      if csv_gzip.blank? && file_path.blank?
        errors.add(:base, "export must have csv_gzip or file_path")
      end
    end
  end
end
