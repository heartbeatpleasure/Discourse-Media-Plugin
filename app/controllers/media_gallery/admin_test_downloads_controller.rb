# frozen_string_literal: true

module ::MediaGallery
  class AdminTestDownloadsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_logged_in
    before_action :ensure_admin_user
    before_action :ensure_test_downloads_enabled

    def create
      item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank?
      raise Discourse::NotFound unless ::MediaGallery::Hls.ready?(item)

      user_id = params[:user_id].to_i
      raise Discourse::InvalidParameters.new(:user_id) if user_id <= 0

      mode = params[:mode].to_s.presence || "full"
      raise Discourse::InvalidParameters.new(:mode) unless %w[full clip random_partial].include?(mode)

      start_segment = positive_or_zero(params[:start_segment])
      segment_count = nil

      if mode == "clip"
        segment_count = positive_or_zero(params[:segment_count])
        if segment_count <= 0 && params[:duration_seconds].present?
          seg_seconds = [::MediaGallery::Hls.segment_duration_seconds.to_i, 1].max
          segment_count = (params[:duration_seconds].to_f / seg_seconds).ceil
        end
        raise Discourse::InvalidParameters.new(:segment_count) if segment_count.to_i <= 0
      end

      task_id = ::MediaGallery::TestDownloads.create_task!(
        public_id: item.public_id,
        user_id: user_id,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      Jobs.enqueue(
        :media_gallery_generate_test_download,
        task_id: task_id,
        public_id: item.public_id,
        user_id: user_id,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      render json: {
        ok: true,
        queued: true,
        task_id: task_id,
        status_url: "/admin/plugins/media-gallery/test-downloads/status/#{task_id}.json",
      }
    rescue => e
      log_error("create", e)
      render json: { ok: false, error: e.message, error_class: e.class.name }, status: error_status(e)
    end

    def status
      payload = ::MediaGallery::TestDownloads.read_task(params[:task_id].to_s)
      raise Discourse::NotFound if payload.blank?

      artifact = payload["artifact"]
      if artifact.present?
        item = ::MediaGallery::MediaItem.find_by(public_id: payload["public_id"].to_s)
        if item.present?
          user = ::User.find_by(id: artifact["user_id"].to_i)
          artifact = artifact.merge(
            "username" => artifact["username"].presence || user&.username,
            "download_url" => "/admin/plugins/media-gallery/test-downloads/#{item.public_id}/#{artifact['artifact_id']}"
          )
        end
      end

      render json: { ok: true, task: payload.except("artifact").merge("artifact" => artifact) }
    rescue => e
      log_error("status", e)
      render json: { ok: false, error: e.message, error_class: e.class.name }, status: error_status(e)
    end

    def download
      item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank?

      meta = ::MediaGallery::TestDownloads.read_meta!(item.public_id, params[:artifact_id].to_s)
      path = meta["file_path"].to_s
      raise Discourse::NotFound if path.blank? || !File.exist?(path)

      ensure_artifact_path_allowed!(path)

      username = meta["username"].presence || ::User.find_by(id: meta["user_id"].to_i)&.username || "user#{meta['user_id']}"
      basename = [
        item.public_id,
        username,
        meta["mode"],
        meta["random_clip_region"],
        "s#{meta['start_segment']}",
        "n#{meta['segment_count']}",
      ].compact.join("-").gsub(/[^a-zA-Z0-9._-]+/, "_")

      response.headers["Cache-Control"] = "no-store"
      send_data(
        File.binread(path),
        filename: "#{basename}.mp4",
        type: "video/mp4",
        disposition: "attachment"
      )
    rescue => e
      log_error("download", e)
      raise e
    end

    private

    def ensure_admin_user
      guardian.ensure_admin
    end

    def ensure_test_downloads_enabled
      raise Discourse::InvalidAccess unless ::MediaGallery::TestDownloads.enabled?
    end

    def positive_or_zero(v)
      i = v.to_i
      i.negative? ? 0 : i
    end

    def ensure_artifact_path_allowed!(path)
      rp = ::File.realpath(path) rescue nil
      raise Discourse::NotFound if rp.blank?

      root = ::MediaGallery::TestDownloads.root_path.to_s
      rr = ::File.realpath(root) rescue nil
      raise Discourse::NotFound if rr.blank?

      allowed_prefix = rr.end_with?("/") ? rr : rr + "/"
      raise Discourse::NotFound unless rp.start_with?(allowed_prefix)
    end

    def error_status(exception)
      case exception
      when Discourse::NotFound
        404
      when Discourse::InvalidParameters, Discourse::InvalidAccess
        422
      else
        500
      end
    end

    def log_error(where, exception)
      Rails.logger.warn("[media_gallery] admin test download #{where} failed error=#{exception.class}: #{exception.message}")
      Rails.logger.warn(exception.backtrace.first(30).join("\n")) if exception.backtrace.present?
    end
  end
end
