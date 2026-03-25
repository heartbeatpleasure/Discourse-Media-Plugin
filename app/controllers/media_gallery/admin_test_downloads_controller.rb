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
      unless %w[full clip random_partial].include?(mode)
        raise Discourse::InvalidParameters.new(:mode)
      end

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

      meta = ::MediaGallery::TestDownloads.build_artifact!(
        item: item,
        user_id: user_id,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      user = ::User.find_by(id: user_id)
      artifact = meta.merge(
        "username" => user&.username,
        "download_url" => "/admin/plugins/media-gallery/test-downloads/#{item.public_id}/#{meta['artifact_id']}",
      )

      render_json_dump(ok: true, artifact: artifact)
    rescue => e
      render_json_error(e)
    end

    def download
      item = ::MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank?

      meta = ::MediaGallery::TestDownloads.read_meta!(item.public_id, params[:artifact_id].to_s)
      path = meta["file_path"].to_s
      raise Discourse::NotFound if path.blank? || !File.exist?(path)

      username = meta["username"].presence || ::User.find_by(id: meta["user_id"].to_i)&.username || "user#{meta['user_id']}"
      basename = [item.public_id, username, meta["mode"], meta["random_clip_region"], "s#{meta['start_segment']}", "n#{meta['segment_count']}"]
        .compact.join("-")
        .gsub(/[^a-zA-Z0-9._-]+/, "_")

      data = File.binread(path)
      send_data data,
                type: "video/mp4",
                disposition: "attachment",
                filename: "#{basename}.mp4"
    rescue => e
      Rails.logger.warn("[media_gallery] admin test download fetch failed error=#{e.class}: #{e.message}")
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

    def render_json_error(error)
      Rails.logger.warn("[media_gallery] admin test download failed error=#{error.class}: #{error.message}")
      render json: { ok: false, error: error.message, error_class: error.class.name }, status: 422
    end
  end
end
