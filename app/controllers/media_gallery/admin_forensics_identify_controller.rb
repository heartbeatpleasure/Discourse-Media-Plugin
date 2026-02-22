# frozen_string_literal: true

require "cgi"
require "tempfile"
require "uri"
require "open3"
require "net/http"

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
          temp = download_source_url_to_tempfile!(
            source_url,
            max_samples: max_samples,
            segment_seconds: seg,
            media_item: item
          )
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

    def download_source_url_to_tempfile!(source_url, max_samples:, segment_seconds:, media_item:)
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

      playlist_tmp = nil
      input = url

      # If the URL points at our own authenticated HLS endpoints, avoid making an HTTP
      # request entirely. Those endpoints require a logged-in user session *and* validate
      # the token against current_user (and sometimes IP). When an admin pastes a playback
      # URL, the server-side fetch won't have the member's browser session cookies, which
      # results in redirects/login HTML and ffmpeg failures.
      #
      # Instead, we build a local playlist directly from the packaged files on disk.
      # If the URL isn't one of our HLS endpoints, fall back to a conservative HTTP playlist rewrite.
      if uri.path.to_s.downcase.end_with?(".m3u8")
        begin
          playlist_tmp = localize_hls_playlist_to_tempfile!(uri, media_item: media_item)
        rescue => e
          if e.message.to_s == "unsupported_hls_url"
            playlist_tmp = rewrite_hls_playlist_to_tempfile!(uri)
          else
            raise e
          end
        end
        input = playlist_tmp.path
      end

      tmp = Tempfile.new(["media_gallery_identify_", ".mp4"])
      tmp.binmode

      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-y",
        "-protocol_whitelist",
        "file,http,https,tcp,tls,crypto",
        "-allowed_extensions",
        "ALL",
        "-i",
        input,
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
        tip = "tip: try the *index.m3u8* variant playlist (not master.m3u8)"
        tip << "; if it still fails, the auth token may not be applied to segment URLs" if uri.path.to_s.downcase.end_with?(".m3u8")
        raise "ffmpeg download failed (#{tip}): #{::MediaGallery::Ffmpeg.short_err(stderr)}"
      end

      tmp
    rescue => e
      playlist_tmp&.close! rescue nil
      tmp&.close! rescue nil
      raise e
    end

    # Downloads the playlist text and rewrites all referenced URIs to absolute URLs.
    # If the incoming playlist URL has a `token=...` query param, it will be appended
    # to any referenced URIs that don't already have it.
    def rewrite_hls_playlist_to_tempfile!(playlist_uri)
      token = extract_token_param(playlist_uri)

      body = http_get_text!(playlist_uri)
      raise "playlist did not look like M3U8" unless body.lstrip.start_with?("#EXTM3U")

      base = playlist_uri.dup
      base.fragment = nil
      base.query = nil
      base.path = base.path.to_s.sub(%r{[^/]+\z}, "")

      rewritten = body.each_line.map do |line|
        raw = line.to_s.strip
        next "" if raw.blank?

        if raw.start_with?("#")
          rewrite_quoted_uris_in_tag_line(raw, base, token)
        else
          rewrite_uri_line(raw, base, token)
        end
      end.join("\n")

      tmp = Tempfile.new(["media_gallery_identify_playlist_", ".m3u8"])
      tmp.binmode
      tmp.write(rewritten)
      tmp.write("\n") unless rewritten.end_with?("\n")
      tmp.flush
      tmp
    end

    # Build a local M3U8 that points at absolute files on disk.
    # Supports Discourse-Media-Plugin's HLS URLs, e.g.:
    #   /media/hls/:public_id/v/:variant/index.m3u8?token=...
    #
    # Why this exists:
    # - /media/hls/* endpoints require ensure_logged_in and also validate token vs current_user.
    # - Server-side fetching the URL (Net::HTTP / ffmpeg) does not carry the member's cookies.
    # - So the request often redirects to login HTML, and the playlist "doesn't look like M3U8".
    #
    # Admin-only identify can safely read the packaged HLS files from private storage.
    def localize_hls_playlist_to_tempfile!(playlist_uri, media_item:)
      path = playlist_uri.path.to_s

      # Variant playlist URL
      m = path.match(%r{\A/media/hls/(?<public_id>[\w\-]+)/v/(?<variant>[^/]+)/index\.m3u8\z}i)

      # Master playlist URL (we'll pick a variant from disk)
      master = path.match(%r{\A/media/hls/(?<public_id>[\w\-]+)/master\.m3u8\z}i)

      if m.blank? && master.blank?
        raise "unsupported_hls_url"
      end

      public_id = (m ? m[:public_id] : master[:public_id]).to_s
      variant = m ? m[:variant].to_s : nil

      if public_id != media_item.public_id.to_s
        raise "public_id_mismatch"
      end

      token = extract_token_param(playlist_uri)
      payload = token.present? ? (MediaGallery::Token.verify(token, purpose: "hls") rescue nil) : nil
      fingerprint_id = payload.is_a?(Hash) ? payload["fingerprint_id"].presence : nil
      token_media_item_id = payload.is_a?(Hash) ? payload["media_item_id"].presence : nil

      if token_media_item_id.present? && token_media_item_id.to_i != media_item.id
        raise "token_item_mismatch"
      end

      if variant.blank?
        master_abs = MediaGallery::PrivateStorage.hls_master_abs_path(media_item)
        raise "master_playlist_not_found" if master_abs.blank? || !File.exist?(master_abs)

        master_raw = File.read(master_abs)
        picked = nil
        master_raw.to_s.each_line do |line|
          l = line.to_s.strip
          next if l.blank? || l.start_with?("#")
          v = l.split("/").first.to_s
          if MediaGallery::Hls.variant_allowed?(v)
            picked = v
            break
          end
        end
        raise "no_variant_found_in_master" if picked.blank?
        variant = picked
      end

      abs = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(public_id, variant)
      raise "variant_playlist_not_found" if abs.blank? || !File.exist?(abs)

      raw = File.read(abs)

      rewritten = []
      seg_counter = 0

      raw.to_s.each_line do |line|
        l = line.to_s.rstrip
        if l.blank? || l.start_with?("#")
          # Handle EXT-X-MAP URI for fMP4
          if l.include?("URI=\"")
            rewritten << l.gsub(/URI=\"([^\"]+)\"/) do
              uri_str = Regexp.last_match(1).to_s
              file = File.basename(uri_str)
              local = resolve_segment_abs_path(public_id, variant, file, fingerprint_id: fingerprint_id, media_item_id: media_item.id)
              "URI=\"#{local}\""
            end
          else
            rewritten << l
          end
          next
        end

        seg = File.basename(l)
        if seg =~ /\A[\w\-.]+\.(ts|m4s)\z/i
          local = resolve_segment_abs_path(public_id, variant, seg, fingerprint_id: fingerprint_id, media_item_id: media_item.id, seg_counter: seg_counter)
          seg_counter += 1
          rewritten << local
        else
          # Unknown line type; keep as-is.
          rewritten << l
        end
      end

      out = rewritten.join("\n") + "\n"
      raise "playlist did not look like M3U8" unless out.lstrip.start_with?("#EXTM3U")

      tmp = Tempfile.new(["media_gallery_identify_local_", ".m3u8"])
      tmp.binmode
      tmp.write(out)
      tmp.flush
      tmp
    end

    def resolve_segment_abs_path(public_id, variant, segment, fingerprint_id: nil, media_item_id: nil, seg_counter: nil)
      seg = segment.to_s

      # Prefer A/B-specific files when fingerprinting is enabled and the token contains a fingerprint_id.
      if MediaGallery::Fingerprinting.enabled? && fingerprint_id.present? && media_item_id.present?
        idx = MediaGallery::Fingerprinting.segment_index_from_filename(seg)
        idx ||= seg_counter
        if idx.present?
          ab = MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: fingerprint_id,
            media_item_id: media_item_id,
            segment_index: idx
          )

          if ab.present?
            ab_abs = File.join(MediaGallery::PrivateStorage.private_root, public_id.to_s, "hls", ab.to_s, variant.to_s, seg)
            return ab_abs if File.exist?(ab_abs)
          end
        end
      end

      # Fallback to legacy packaging.
      MediaGallery::PrivateStorage.hls_segment_abs_path(public_id, variant, seg)
    end

    def http_get_text!(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = "DiscourseMediaGalleryForensicsIdentify/1.0"

      # If the URL requires authentication (e.g. ensure_logged_in), forward cookies from
      # the admin's browser session. This makes URL-mode usable for protected endpoints.
      cookie = request&.headers&.[]("Cookie").to_s
      req["Cookie"] = cookie if cookie.present?
      req["Accept"] = "application/vnd.apple.mpegurl, */*"

      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise "playlist HTTP #{res.code}"
      end

      res.body.to_s
    end

    def extract_token_param(uri)
      qs = CGI.parse(uri.query.to_s)
      qs["token"]&.first.presence
    end

    def rewrite_uri_line(value, base_uri, token)
      abs = absolutize_uri(value, base_uri)
      add_token(abs, token)
    end

    # Rewrites URI="..." occurrences in HLS tag lines like EXT-X-KEY, EXT-X-MAP, EXT-X-MEDIA.
    def rewrite_quoted_uris_in_tag_line(line, base_uri, token)
      line.gsub(/URI="([^"]+)"/) do
        original = Regexp.last_match(1)
        abs = absolutize_uri(original, base_uri)
        rewritten = add_token(abs, token)
        "URI=\"#{rewritten}\""
      end
    end

    def absolutize_uri(value, base_uri)
      v = value.to_s
      begin
        u = URI.parse(v)
        if u.scheme.present? && u.host.present?
          u
        else
          URI.join(base_uri.to_s, v)
        end
      rescue
        URI.join(base_uri.to_s, v)
      end
    end

    def add_token(uri, token)
      return uri.to_s if token.blank?

      u = uri.is_a?(URI) ? uri.dup : URI.parse(uri.to_s)
      q = CGI.parse(u.query.to_s)
      q["token"] ||= [token]
      u.query = URI.encode_www_form(q.flat_map { |k, vs| vs.map { |v| [k, v] } })
      u.to_s
    rescue
      uri.to_s
    end
  end
end
