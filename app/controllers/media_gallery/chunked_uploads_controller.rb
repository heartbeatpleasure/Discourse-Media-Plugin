# frozen_string_literal: true

module ::MediaGallery
  class ChunkedUploadsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in
    before_action :ensure_can_upload
    before_action :ensure_secure_write_request!
    after_action :set_sensitive_json_headers!

    def start
      session = ::MediaGallery::ChunkedUploads.start!(
        user: current_user,
        filename: params[:filename],
        filesize: params[:filesize],
        content_type: params[:content_type]
      )

      render_json_dump(
        session_id: session["session_id"],
        filename: session["filename"],
        filesize: session["filesize"],
        media_type: session["media_type"],
        chunk_size_bytes: session["chunk_size_bytes"],
        total_parts: session["total_parts"],
        expires_at: session["expires_at"]
      )
    rescue ::MediaGallery::ChunkedUploads::Error => e
      render_chunked_upload_error(e)
    rescue => e
      Rails.logger.warn("[media_gallery] chunked start controller failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_error("chunked_upload_start_failed", status: 500, message: "Chunked upload could not be started.")
    end

    def part
      result = ::MediaGallery::ChunkedUploads.write_part!(
        session_id: params[:session_id],
        user: current_user,
        part_number: params[:part_number],
        upload: params[:chunk]
      )

      render_json_dump(ok: true, **result)
    rescue ::MediaGallery::ChunkedUploads::Error => e
      render_chunked_upload_error(e)
    rescue => e
      Rails.logger.warn("[media_gallery] chunked part controller failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_error("chunk_upload_failed", status: 500, message: "Upload chunk could not be saved.")
    end

    def complete
      upload = ::MediaGallery::ChunkedUploads.complete!(session_id: params[:session_id], user: current_user)

      render_json_dump(
        ok: true,
        upload_id: upload.id,
        id: upload.id,
        filename: upload.original_filename,
        filesize: upload.filesize
      )
    rescue ::MediaGallery::ChunkedUploads::Error => e
      render_chunked_upload_error(e)
    rescue => e
      Rails.logger.warn("[media_gallery] chunked complete controller failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_error("chunked_upload_complete_failed", status: 500, message: "Upload could not be completed. Please try again.")
    end

    def status
      result = ::MediaGallery::ChunkedUploads.status!(session_id: params[:session_id], user: current_user)

      render_json_dump(
        session_id: result["session_id"],
        filename: result["filename"],
        filesize: result["filesize"],
        media_type: result["media_type"],
        chunk_size_bytes: result["chunk_size_bytes"],
        total_parts: result["total_parts"],
        uploaded_parts: result["uploaded_parts"],
        uploaded_parts_count: result["uploaded_parts_count"],
        missing_parts_count: result["missing_parts_count"],
        expires_at: result["expires_at"]
      )
    rescue ::MediaGallery::ChunkedUploads::Error => e
      render_chunked_upload_error(e)
    rescue => e
      Rails.logger.warn("[media_gallery] chunked status controller failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_error("upload_session_not_found", status: 404, message: "Upload session was not found or expired.")
    end

    def abort
      ::MediaGallery::ChunkedUploads.abort!(session_id: params[:session_id], user: current_user)
      render_json_dump(ok: true)
    rescue ::MediaGallery::ChunkedUploads::Error => e
      render_chunked_upload_error(e)
    rescue => e
      Rails.logger.warn("[media_gallery] chunked abort controller failed request_id=#{request.request_id} error=#{e.class}: #{e.message}")
      render_json_dump(ok: true)
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_can_upload
      raise Discourse::NotFound unless ::MediaGallery::Permissions.can_upload?(guardian)
    end

    def ensure_secure_write_request!
      return if ::MediaGallery::RequestSecurity.secure_write_request?(self)

      set_sensitive_json_headers!
      render_json_error("forbidden", status: 403, message: "Forbidden")
    end

    def render_chunked_upload_error(error)
      render_json_error(
        error.code,
        status: error.status,
        message: error.message,
        extra: error.details.present? ? { details: error.details } : nil
      )
    end

    def render_json_error(error_code, status: 422, message: nil, extra: nil)
      payload = {
        errors: [message.presence || error_code.to_s],
        error_type: "media_gallery_error",
        error_code: error_code.to_s,
        request_id: request&.request_id
      }
      payload.merge!(extra) if extra.is_a?(Hash)
      render json: payload, status: status
    end

    def set_sensitive_json_headers!
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"
      response.headers["X-Content-Type-Options"] = "nosniff"
      ::MediaGallery::ResponseSecurityHeaders.apply!(response.headers, include_corp: true)
    rescue
      nil
    end
  end
end
