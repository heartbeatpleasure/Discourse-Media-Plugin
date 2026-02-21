# frozen_string_literal: true

require "cgi"
require "tempfile"
require "uri"
require "open3"

module ::MediaGallery
  class AdminForensicsIdentifyController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def show
      public_id = params[:public_id].to_s
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      raise Discourse::NotFound if item.blank?

      action_url = "/admin/plugins/media-gallery/forensics-identify/#{public_id}.json"

      html = <<~HTML
        <div class="wrap">
          <h1>Media Gallery – Forensics Identify</h1>
          <p>
            Upload a leaked copy of this video to attempt identification.
            This is best-effort and can be affected by re-encoding/cropping.
          </p>

          <ul>
            <li><strong>public_id:</strong> #{CGI.escapeHTML(public_id)}</li>
            <li><strong>media_item_id:</strong> #{item.id}</li>
          </ul>

          <form action="#{action_url}" method="post" enctype="multipart/form-data">
            <input type="hidden" name="authenticity_token" value="#{form_authenticity_token}">

            <p>
              <label>Leaked file: <input type="file" name="file" required></label>
            </p>

            <p>
              <label>Max samples (frames): <input type="number" name="max_samples" value="60" min="5" max="200"></label>
            </p>

            <p>
              <label>Max offset segments to scan: <input type="number" name="max_offset_segments" value="30" min="0" max="300"></label>
            </p>

            <p>
              <label>Layout override (optional):
                <select name="layout">
                  <option value="">auto</option>
                  <option value="v1_tiles">v1_tiles</option>
                  <option value="v2_pairs">v2_pairs</option>
                </select>
              </label>
            </p>

            <p>
              <button class="btn btn-primary" type="submit">Identify</button>
            </p>
          </form>

          <p style="opacity:0.75">
            Tip: if confidence is low, try using a copy that is closer to the original HLS download (less re-encoded).
          </p>
        </div>
      HTML

      render html: html.html_safe, layout: "no_ember"
    end

    # POST /admin/plugins/media-gallery/forensics-identify/:public_id(.json)
    # Accepts either:
    # - file: uploaded leak copy
    # - source_url: URL to a variant playlist (.m3u8) or direct media URL (admin-only helper)
    def identify
      public_id = params[:public_id].to_s
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      raise Discourse::NotFound if item.blank?

      max_samples = params[:max_samples].to_i
      max_samples = 60 if max_samples <= 0
      max_samples = [max_samples, 200].min

      max_offset = params[:max_offset_segments].to_i
      max_offset = 30 if max_offset.negative?
      max_offset = [max_offset, 300].min

      layout = params[:layout].to_s.presence

      seg = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      seg = 6 if seg <= 0

      source_url = params[:source_url].to_s.strip.presence

      temp = nil
      path = nil

      if source_url.present?
        begin
          temp = download_source_url_to_tempfile!(source_url, max_samples: max_samples, segment_seconds: seg)
          path = temp.path
        rescue => e
          # Include the reason in the error payload so the admin UI can display it.
          msg = e.message.to_s.strip
          msg = msg[0, 400] if msg.length > 400
          return render json: { errors: ["invalid_source_url", msg].compact }, status: 422
        end
      else
        file = params[:file]
        return render json: { errors: ["missing_file_or_url"] }, status: 422 if file.blank?

        path = file.respond_to?(:tempfile) ? file.tempfile&.path : nil
        return render json: { errors: ["missing_file_or_url"] }, status: 422 if path.blank? || !File.exist?(path)
      end

      result = ::MediaGallery::ForensicsIdentify.identify_from_file(
        media_item: item,
        file_path: path,
        max_samples: max_samples,
        max_offset_segments: max_offset,
        layout: layout
      )

      render_json_dump(result)
    ensure
      temp&.close! rescue nil
    end

    private

    # Keep this conservative. This feature is mainly for quickly reproducing issues by pasting
    # a playlist URL from your own site. Large external downloads are intentionally not supported.
    MAX_URL_SAMPLE_SECONDS = 1800

    # Some installs use long signed tokens in query strings. 2k is often too small.
    MAX_SOURCE_URL_LENGTH = 10_000

    def download_source_url_to_tempfile!(source_url, max_samples:, segment_seconds:)
      url = source_url.to_s.strip
      raise "source_url is blank" if url.blank?
      raise "source_url is too long" if url.length > MAX_SOURCE_URL_LENGTH

      uri = URI.parse(url) rescue nil
      raise "source_url is not a valid http(s) URL" if uri.blank? || uri.host.blank? || !%w[http https].include?(uri.scheme)

      # Security: only allow URLs on this Discourse host for now.
      # (If you later need CDN support, we can add an allowlist site setting.)
      base_host = (URI.parse(Discourse.base_url).host rescue nil)
      req_host = request&.host
      allowed_hosts = [base_host, req_host].compact.uniq

      unless allowed_hosts.include?(uri.host)
        raise "Only URLs on this site are allowed (#{allowed_hosts.join(', ')})."
      end

      seg = segment_seconds.to_i
      seg = 6 if seg <= 0

      ms = max_samples.to_i
      ms = 60 if ms <= 0
      ms = [ms, 200].min

      # Download just enough to cover the requested samples.
      target_seconds = (ms * seg) + seg
      target_seconds = 30 if target_seconds < 30
      target_seconds = [target_seconds, MAX_URL_SAMPLE_SECONDS].min

      tmp = Tempfile.new(["media_gallery_identify_", ".mp4"])
      tmp.binmode

      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-y",
        "-protocol_whitelist",
        "file,http,https,tcp,tls,crypto",
        "-i",
        url,
        "-t",
        target_seconds.to_s,
        "-c",
        "copy",
        # Only needed when remuxing AAC-in-TS into MP4. Safe to keep, but if it fails
        # on odd inputs, we can later add a re-encode fallback.
        "-bsf:a",
        "aac_adtstoasc",
        tmp.path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success? && File.size?(tmp.path)
        raise "ffmpeg download failed (tip: try the *index.m3u8* variant playlist, not master.m3u8): #{::MediaGallery::Ffmpeg.short_err(stderr)}"
      end

      tmp
    rescue => e
      tmp&.close! rescue nil
      raise e
    end
  end
end
