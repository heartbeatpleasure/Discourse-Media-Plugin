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
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"

      if wants_gz
        path = export.readable_path_for_download
        if export.csv_gzip.blank? && path.present?
          ensure_export_path_allowed!(path)

          filename = export.download_filename
          filename += ".gz" unless filename.end_with?(".gz")

          return send_file path,
                           filename: filename,
                           type: "application/gzip",
                           disposition: "attachment"
        end

        gz_bytes = export.gzip_bytes
        filename = export.download_filename
        filename += ".gz" unless filename.end_with?(".gz")

        send_data gz_bytes,
                  filename: filename,
                  type: "application/gzip",
                  disposition: "attachment"
      else
        csv = export.csv_bytes

        ::MediaGallery::OperationLogger.audit("forensics_export_downloaded", operation: "forensics_export_download", user: current_user, request: request, result: "downloaded", data: { export_id: export.id, filename: export.filename, storage_location: storage_location_label_for(export, stored_in_db: export.csv_gzip.present?, archive_exists: export.archive_exists?) })
      send_data csv,
                  filename: export.download_filename,
                  type: "text/csv; charset=utf-8",
                  disposition: "attachment"
      end
    end

    def destroy
      export = MediaGallery::MediaForensicsExport.find_by(id: params[:id].to_i)
      raise Discourse::NotFound if export.blank?

      deleted_files = delete_export_files_safely!(export)
      export.destroy!

      render_json_dump(deleted: true, id: params[:id].to_i, deleted_files: deleted_files)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] forensics export delete failed id=#{params[:id].to_i}: #{e.class}: #{e.message}")
      render_json_error("delete_failed", status: 500, message: "Export deletion failed. Please try again.")
    end

    private

    def serialize_export(export)
      stored_in_db = export.csv_gzip.present?
      gzip_bytes = gzip_size_for(export)
      csv_sha256 = export.sha256.presence
      csv_bytes = safe_csv_bytes(export)
      archive_exists = export.archive_exists?

      {
        id: export.id,
        filename: export.download_filename,
        cutoff_at: export.cutoff_at,
        created_at: export.created_at,
        archived_at: export.respond_to?(:archived_at) ? export.archived_at : nil,
        rows_count: export.rows_count,
        storage_mode: stored_in_db ? "db" : "file",
        storage_location: storage_location_label_for(export, stored_in_db: stored_in_db, archive_exists: archive_exists),
        file_exists: export.file_exists?,
        archive_exists: archive_exists,
        download_ready: stored_in_db || export.file_exists?,
        csv_sha256: csv_sha256,
        csv_bytes: csv_bytes&.bytesize,
        gzip_sha256: safe_gzip_sha256_for(export),
        gzip_bytes: gzip_bytes,
        archive_bytes: export.respond_to?(:archive_bytes) ? export.archive_bytes : nil,
      }
    end

    def storage_location_label_for(export, stored_in_db:, archive_exists:)
      if stored_in_db && archive_exists
        "database+archive"
      elsif stored_in_db
        "database"
      elsif archive_exists && export.file_path.blank?
        "archive"
      elsif archive_exists
        "local+archive"
      else
        "local"
      end
    rescue
      stored_in_db ? "database" : "local"
    end

    def safe_csv_bytes(export)
      export.csv_bytes
    rescue => _e
      nil
    end

    def gzip_size_for(export)
      return export.csv_gzip.bytesize if export.csv_gzip.present?
      return export.file_bytes if export.file_bytes.present?
      return export.archive_bytes if export.respond_to?(:archive_bytes) && export.archive_bytes.present?
      path = export.readable_path_for_download
      return (::File.size(path) rescue nil) if path.present?

      nil
    end

    def safe_gzip_sha256_for(export)
      if export.csv_gzip.present?
        return Digest::SHA256.hexdigest(export.csv_gzip)
      end

      path = export.readable_path_for_download
      return nil if path.blank? || !::File.exist?(path)

      ensure_export_path_allowed!(path)
      Digest::SHA256.file(path).hexdigest
    rescue => _e
      nil
    end

    def ensure_admin
      raise Discourse::InvalidAccess.new unless guardian.is_admin?
    end

    def delete_export_files_safely!(export)
      paths = [export.file_path, export.respond_to?(:archive_path) ? export.archive_path : nil].compact.map(&:to_s).reject(&:blank?).uniq
      deleted = 0

      paths.each do |path|
        next unless ::File.exist?(path)
        ensure_export_path_allowed!(path)
        ::File.delete(path)
        deleted += 1
      end

      deleted
    end

    def ensure_export_path_allowed!(path)
      rp = ::File.realpath(path) rescue nil
      raise Discourse::NotFound if rp.blank?

      roots = allowed_export_roots

      allowed = roots.compact.uniq.any? do |root|
        rr = ::File.realpath(root) rescue nil
        rr.present? && rp.start_with?(rr.end_with?("/") ? rr : rr + "/")
      end

      raise Discourse::NotFound unless allowed
    end

    def allowed_export_roots
      roots = [computed_export_root_path, computed_archive_root_path]

      if SiteSetting.respond_to?(:media_gallery_private_root_path) && SiteSetting.media_gallery_private_root_path.present?
        roots << SiteSetting.media_gallery_private_root_path
        roots << ::File.join(SiteSetting.media_gallery_private_root_path, "forensics_export_archive")
      end

      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) && SiteSetting.media_gallery_original_export_root_path.present?
        roots << SiteSetting.media_gallery_original_export_root_path
      end

      roots << "/shared/media_gallery/private/forensics_export_archive"
      roots.compact.uniq
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

    def computed_archive_root_path
      if SiteSetting.respond_to?(:media_gallery_forensics_export_archive_root_path)
        v = SiteSetting.media_gallery_forensics_export_archive_root_path.to_s.presence
        return v if v
      end

      if SiteSetting.respond_to?(:media_gallery_private_root_path)
        v = SiteSetting.media_gallery_private_root_path.to_s.presence
        return ::File.join(v, "forensics_export_archive") if v
      end

      "/shared/media_gallery/private/forensics_export_archive"
    end
  end
end
