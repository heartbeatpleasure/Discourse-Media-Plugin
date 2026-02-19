# frozen_string_literal: true

module ::MediaGallery
  class MediaForensicsExport < ::ActiveRecord::Base
    self.table_name = "media_gallery_forensics_exports"

    validates :cutoff_at, presence: true
    validates :rows_count, presence: true
    validates :csv_gzip, presence: true

    def csv_bytes
      ::Zlib.gunzip(csv_gzip)
    end
  end
end
