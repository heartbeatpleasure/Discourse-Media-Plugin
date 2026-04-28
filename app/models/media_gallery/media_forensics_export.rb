# frozen_string_literal: true

require "zlib"

module ::MediaGallery
  class MediaForensicsExport < ::ActiveRecord::Base
    self.table_name = "media_gallery_forensics_exports"

    validates :cutoff_at, presence: true
    validates :rows_count, presence: true

    validate :has_export_payload

    def file_exists?
      file_path.present? && file_path_allowed? && ::File.exist?(file_path)
    end

    def csv_bytes
      if csv_gzip.present?
        return ::Zlib.gunzip(csv_gzip)
      end

      raise Discourse::NotFound if file_path.blank?
      ensure_file_path_allowed!

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

    def ensure_file_path_allowed!
      raise Discourse::NotFound unless file_path_allowed?
    end

    def file_path_allowed?
      return false if file_path.blank?

      allowed_export_roots.any? do |root|
        root.present? && ::MediaGallery::PathSecurity.realpath_under?(file_path, root)
      end
    rescue
      false
    end

    def allowed_export_roots
      roots = []
      if SiteSetting.respond_to?(:media_gallery_forensics_export_root_path)
        explicit = SiteSetting.media_gallery_forensics_export_root_path.to_s.strip
        roots << explicit if explicit.present?
      end
      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) && SiteSetting.media_gallery_original_export_root_path.present?
        roots << File.join(SiteSetting.media_gallery_original_export_root_path, "forensics_exports")
        roots << SiteSetting.media_gallery_original_export_root_path
      end
      if SiteSetting.respond_to?(:media_gallery_private_root_path) && SiteSetting.media_gallery_private_root_path.present?
        roots << File.join(SiteSetting.media_gallery_private_root_path, "forensics_exports")
        roots << SiteSetting.media_gallery_private_root_path
      end
      roots << "/shared/media_gallery/forensics_exports"

      roots.compact.uniq
    end

    def has_export_payload
      if csv_gzip.blank? && file_path.blank?
        errors.add(:base, "export must have csv_gzip or file_path")
      end
    end
  end
end
