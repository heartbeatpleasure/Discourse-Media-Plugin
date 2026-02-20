# frozen_string_literal: true

module ::MediaGallery
  class AdminForensicsExportsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_logged_in
    before_action :ensure_admin

    def index
      limit = [params[:limit].to_i, 200].reject(&:zero?).min || 50

      exports =
        MediaGallery::MediaForensicsExport
          .order(created_at: :desc)
          .limit(limit)
          .map do |e|
            storage = e.csv_gzip.present? ? "db" : "file"
            {
              id: e.id,
              filename: e.download_filename,
              cutoff_at: e.cutoff_at,
              rows_count: e.rows_count,
              sha256: e.sha256,
              storage: storage,
              file_path: e.file_path,
              file_bytes: e.file_bytes,
              file_exists: e.file_exists?,
              created_at: e.created_at
            }
          end

      render_json_dump(exports: exports)
    end

    def download
      export = MediaGallery::MediaForensicsExport.find_by(id: params[:id].to_i)
      raise Discourse::NotFound if export.blank?

      wants_gz = params[:gz].to_s == "1"

      # If file-based export is configured, ensure the stored file path stays within an allowed root.
      if export.csv_gzip.blank? && export.file_path.present?
        ensure_export_path_allowed!(export.file_path)
      end

      response.headers["Cache-Control"] = "no-store"

      if wants_gz
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

    def ensure_admin
      raise Discourse::InvalidAccess.new unless guardian.is_admin?
    end

    def ensure_export_path_allowed!(path)
      rp = ::File.realpath(path) rescue nil
      raise Discourse::NotFound if rp.blank?

      roots = []
      if SiteSetting.respond_to?(:media_gallery_forensics_export_root_path) &&
         SiteSetting.media_gallery_forensics_export_root_path.present?
        roots << SiteSetting.media_gallery_forensics_export_root_path
      end

      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) &&
         SiteSetting.media_gallery_original_export_root_path.present?
        roots << SiteSetting.media_gallery_original_export_root_path
      end

      if SiteSetting.respond_to?(:media_gallery_private_root_path) &&
         SiteSetting.media_gallery_private_root_path.present?
        roots << SiteSetting.media_gallery_private_root_path
      end

      allowed = roots.compact.uniq.any? do |root|
        rr = ::File.realpath(root) rescue nil
        rr.present? && rp.start_with?(rr.end_with?("/") ? rr : rr + "/")
      end

      raise Discourse::NotFound unless allowed
    end
  end
end
