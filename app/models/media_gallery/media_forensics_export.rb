# frozen_string_literal: true

require "zlib"

module ::MediaGallery
  class MediaForensicsExport < ::ActiveRecord::Base
    self.table_name = "media_gallery_forensics_exports"

    validates :cutoff_at, presence: true
    validates :rows_count, presence: true

    validate :has_export_payload

    def file_exists?
      readable_path_for_download.present?
    end

    def archive_exists?
      archive_path.present? && file_path_allowed?(archive_path) && ::File.exist?(archive_path)
    rescue
      false
    end

    def readable_path_for_download
      [file_path, archive_path].each do |path|
        next if path.blank?
        next unless file_path_allowed?(path)
        return path if ::File.exist?(path)
      end
      nil
    rescue
      nil
    end

    def csv_bytes
      if csv_gzip.present?
        return ::Zlib.gunzip(csv_gzip)
      end

      path = readable_path_for_download
      raise Discourse::NotFound if path.blank?

      bytes = ::File.binread(path)
      if path.end_with?(".gz")
        ::Zlib.gunzip(bytes)
      else
        bytes
      end
    end

    def gzip_bytes
      return csv_gzip if csv_gzip.present?

      path = readable_path_for_download
      raise Discourse::NotFound if path.blank?
      ::File.binread(path)
    end

    def download_filename
      filename.presence || "media_gallery_playback_sessions_export_#{id}.csv"
    end

    private

    def file_path_allowed?(path)
      return false if path.blank?

      allowed_export_roots.any? do |root|
        root.present? && ::MediaGallery::PathSecurity.realpath_under?(path, root)
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
      if SiteSetting.respond_to?(:media_gallery_forensics_export_archive_root_path)
        archive = SiteSetting.media_gallery_forensics_export_archive_root_path.to_s.strip
        roots << archive if archive.present?
      end
      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) && SiteSetting.media_gallery_original_export_root_path.present?
        roots << File.join(SiteSetting.media_gallery_original_export_root_path, "forensics_exports")
        roots << SiteSetting.media_gallery_original_export_root_path
      end
      if SiteSetting.respond_to?(:media_gallery_private_root_path) && SiteSetting.media_gallery_private_root_path.present?
        roots << File.join(SiteSetting.media_gallery_private_root_path, "forensics_exports")
        roots << File.join(SiteSetting.media_gallery_private_root_path, "forensics_export_archive")
        roots << SiteSetting.media_gallery_private_root_path
      end
      roots << "/shared/media_gallery/forensics_exports"
      roots << "/shared/media_gallery/private/forensics_export_archive"

      roots.compact.uniq
    end

    def has_export_payload
      if csv_gzip.blank? && file_path.blank? && archive_path.blank?
        errors.add(:base, "export must have csv_gzip, file_path, or archive_path")
      end
    end
  end
end
