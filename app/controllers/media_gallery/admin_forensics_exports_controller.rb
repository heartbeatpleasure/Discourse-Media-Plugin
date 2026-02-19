# frozen_string_literal: true

require "zlib"

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
            {
              id: e.id,
              filename: e.filename,
              cutoff_at: e.cutoff_at,
              rows_count: e.rows_count,
              sha256: e.sha256,
              created_at: e.created_at
            }
          end

      render_json_dump(exports: exports)
    end

    def download
      export = MediaGallery::MediaForensicsExport.find_by(id: params[:id].to_i)
      raise Discourse::NotFound if export.blank?

      csv = export.csv_bytes
      filename = export.filename.presence || "media_gallery_playback_sessions_export_#{export.id}.csv"

      response.headers["Cache-Control"] = "no-store"
      send_data csv, filename: filename, type: "text/csv; charset=utf-8", disposition: "attachment"
    end

    private

    def ensure_admin
      guardian.ensure_admin!
    end
  end
end
