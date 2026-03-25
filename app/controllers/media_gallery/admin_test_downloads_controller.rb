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

      render json: { ok: true, artifact: artifact }
    rescue => e
      Rails.logger.warn("[media_gallery] admin test download create failed error=#{e.class}: #{e.message}")
      Rails.logger.warn(e.backtrace.first(20).join("\n")) if e.backtrace.present?
      render json: { ok: false, error: e.message, error_class: e.class.name }, status: 422
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
      return send_file path,
                       filename: "#{basename}.mp4",
                       type: "video/mp4",
                       disposition: "attachment"
    end

    private

    def ensure_admin_user
      guardian.ensure_admin
    end

    def ensure_test_downloads_enabled
      raise Discourse::InvalidAccess unless ::MediaGallery::TestDownloads.enabled?
    end

    def ensure_artifact_path_allowed!(path)
      rp = ::File.realpath(path) rescue nil
      raise Discourse::NotFound if rp.blank?

      root = ::MediaGallery::TestDownloads.root_path
      rr = ::File.realpath(root) rescue nil
      raise Discourse::NotFound if rr.blank?

      allowed_prefix = rr.end_with?("/") ? rr : rr + "/"
      raise Discourse::NotFound unless rp.start_with?(allowed_prefix)
    end

    def positive_or_zero(v)
      i = v.to_i
      i.negative? ? 0 : i
    end
  end
end
