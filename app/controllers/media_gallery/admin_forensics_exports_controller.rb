# frozen_string_literal: true

require "digest"

module ::MediaGallery
  class AdminForensicsExportsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_logged_in
    before_action :ensure_admin

    def index
      limit = params[:limit].to_i
      limit = 50 if limit <= 0
      limit = 200 if limit > 200

      exports =
        MediaGallery::MediaForensicsExport
          .order(created_at: :desc)
          .limit(limit)
          .map { |export| serialize_export(export) }

      render_json_dump(exports: exports)
    end

    def download
      export = MediaGallery::MediaForensicsExport.find_by(id: params[:id].to_i)
      raise Discourse::NotFound if export.blank?

      wants_gz = params[:gz].to_s == "1"

      if export.csv_gzip.blank? && export.file_path.present?
        ensure_export_path_allowed!(export.file_path)
      end

      response.headers["Cache-Control"] = "no-store"

      if wants_gz
        if export.csv_gzip.blank? && export.file_path.present? && ::File.exist?(export.file_path)
          ensure_export_path_allowed!(export.file_path)

          filename = export.download_filename
          filename += ".gz" unless filename.end_with?(".gz")

          return send_file export.file_path,
                           filename: filename,
                           type: "application/gzip",
                           disposition: "attachment"
        end

        gz_bytes = export.csv_gzip.presence || ::File.binread(export.file_path)
        filename = export.download_filename
        filename += ".gz" unless filename.end_with?(".gz")

        send_data gz_bytes,
                  filename: filename,
                  type: "application/gzip",
                  disposition: "attachment"
      else
        csv = export.csv_bytes

        send_data csv,
                  filename: export.download_filename,
                  type: "text/csv; charset=utf-8",
                  disposition: "attachment"
      end
    end

    private

    def serialize_export(export)
      stored_in_db = export.csv_gzip.present?
      gzip_bytes = gzip_size_for(export)
      csv_sha256 = export.sha256.presence
      csv_bytes = safe_csv_bytes(export)

      {
        id: export.id,
        filename: export.download_filename,
        cutoff_at: export.cutoff_at,
        created_at: export.created_at,
        rows_count: export.rows_count,
        storage_mode: stored_in_db ? "db" : "file",
        storage_location: stored_in_db ? "database" : "local",
        file_exists: export.file_exists?,
        download_ready: stored_in_db || export.file_exists?,
        csv_sha256: csv_sha256,
        csv_bytes: csv_bytes&.bytesize,
        gzip_sha256: safe_gzip_sha256_for(export),
        gzip_bytes: gzip_bytes,
      }
    end

    def safe_csv_bytes(export)
      export.csv_bytes
    rescue => _e
      nil
    end

    def gzip_size_for(export)
      return export.csv_gzip.bytesize if export.csv_gzip.present?
      return export.file_bytes if export.file_bytes.present?
      return (::File.size(export.file_path) rescue nil) if export.file_path.present?

      nil
    end

    def safe_gzip_sha256_for(export)
      if export.csv_gzip.present?
        return Digest::SHA256.hexdigest(export.csv_gzip)
      end

      return nil if export.file_path.blank? || !::File.exist?(export.file_path)

      ensure_export_path_allowed!(export.file_path)
      Digest::SHA256.file(export.file_path).hexdigest
    rescue => _e
      nil
    end

    def ensure_admin
      raise Discourse::InvalidAccess.new unless guardian.is_admin?
    end

    def ensure_export_path_allowed!(path)
      rp = ::File.realpath(path) rescue nil
      raise Discourse::NotFound if rp.blank?

      roots = [computed_export_root_path]

      if SiteSetting.respond_to?(:media_gallery_private_root_path) && SiteSetting.media_gallery_private_root_path.present?
        roots << SiteSetting.media_gallery_private_root_path
      end

      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) && SiteSetting.media_gallery_original_export_root_path.present?
        roots << SiteSetting.media_gallery_original_export_root_path
      end

      allowed = roots.compact.uniq.any? do |root|
        rr = ::File.realpath(root) rescue nil
        rr.present? && rp.start_with?(rr.end_with?("/") ? rr : rr + "/")
      end

      raise Discourse::NotFound unless allowed
    end

    def computed_export_root_path
      if SiteSetting.respond_to?(:media_gallery_forensics_export_root_path)
        v = SiteSetting.media_gallery_forensics_export_root_path.to_s.presence
        return v if v
      end

      if SiteSetting.respond_to?(:media_gallery_original_export_root_path)
        v = SiteSetting.media_gallery_original_export_root_path.to_s.presence
        return ::File.join(v, "forensics_exports") if v
      end

      if SiteSetting.respond_to?(:media_gallery_private_root_path)
        v = SiteSetting.media_gallery_private_root_path.to_s.presence
        return ::File.join(v, "forensics_exports") if v
      end

      "/shared/media_gallery/forensics_exports"
    end
    private :computed_export_root_path
  end
end
