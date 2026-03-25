# frozen_string_literal: true

module ::MediaGallery
  class AdminTestDownloadsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    before_action :ensure_test_downloads_enabled

    rescue_from StandardError, with: :render_test_download_error

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
            "download_url" => "/admin/plugins/media-gallery/test-downloads/#{item.public_id}/#{artifact['artifact_id']}",
          )
        end
      end

      render json: {
        ok: true,
        task: payload.except("artifact").merge("artifact" => artifact),
      }
    end

    def download
      item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank?

      meta = ::MediaGallery::TestDownloads.read_meta!(item.public_id, params[:artifact_id].to_s)
      path = meta["file_path"].to_s
      raise Discourse::NotFound if path.blank? || !File.exist?(path)

      username = meta["username"].presence || ::User.find_by(id: meta["user_id"].to_i)&.username || "user#{meta['user_id']}"
      basename = [
        item.public_id,
        username,
        meta["mode"],
        meta["random_clip_region"],
        "s#{meta['start_segment']}",
        "n#{meta['segment_count']}",
      ].compact.join("-").gsub(/[^a-zA-Z0-9._-]+/, "_")

      send_data(
        File.binread(path),
        type: "video/mp4",
        disposition: "attachment",
        filename: "#{basename}.mp4",
      )
    end

    private

    def ensure_test_downloads_enabled
      raise Discourse::InvalidAccess unless ::MediaGallery::TestDownloads.enabled?
    end

    def positive_or_zero(v)
      i = v.to_i
      i.negative? ? 0 : i
    end

    def render_test_download_error(exception)
      Rails.logger.warn("[media_gallery] admin test download controller failed error=#{exception.class}: #{exception.message}")
      Rails.logger.warn(exception.backtrace.first(30).join("\n")) if exception.backtrace.present?

      status =
        case exception
        when Discourse::NotFound
          404
        when Discourse::InvalidParameters, Discourse::InvalidAccess
          422
        else
          500
        end

      render json: {
        ok: false,
        error: exception.message,
        error_class: exception.class.name,
      }, status: status
    end
  end
end
