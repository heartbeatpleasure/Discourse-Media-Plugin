# frozen_string_literal: true

require "open3"
require "fileutils"

module MediaGallery
  class Ffmpeg
    def self.ffmpeg_path
      SiteSetting.media_gallery_ffmpeg_path.presence || "ffmpeg"
    end

    def self.ffprobe_path
      SiteSetting.media_gallery_ffprobe_path.presence || "ffprobe"
    end

    # Keep stderr clean so we don't drown the real error in ffmpeg banners/config output.
    def self.ffmpeg_common_args
      ["-hide_banner", "-loglevel", "error", "-nostats"]
    end

    def self.short_err(stderr)
      s = stderr.to_s
      return "unknown error" if s.blank?

      # Normalize and strip ffmpeg banners/noise (some builds still print headers on failure).
      lines = s.lines.map { |l| l.rstrip }

      lines.reject! do |l|
        l.blank? ||
          l =~ /^ffmpeg version\b/i ||
          l =~ /^\s*built with\b/i ||
          l =~ /^\s*configuration:\b/i ||
          l =~ /^\s*lib\w+\s+\d+/i
      end

      # Keep tail; most relevant error is usually at the end.
      out = lines.last(20).join("\n").strip
      out = out[0, 800] if out.length > 800
      out.presence || "unknown error"
    end

    def self.probe(input_path)
      cmd = [
        ffprobe_path,
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        input_path,
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffprobe_failed: #{short_err(stderr)}" unless status.success?

      JSON.parse(stdout)
    end

    # Audio profile: MP3, 44.1kHz, stereo
    def self.transcode_audio(input_path:, output_path:, bitrate_kbps:)
      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:a:0",
        "-vn",
        "-sn",
        "-dn",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "#{bitrate_kbps}k",
        "-ar",
        "44100",
        "-ac",
        "2",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_audio_failed: #{short_err(stderr)}" unless status.success?
    end

    # Video profile: MP4, H.264 Main@4.1, max 1080p, max 30fps, target bitrate, AAC 128kbps
    #
    # When hls_segment_seconds is provided, keyframes are forced on segment boundaries.
    # This enables clean HLS packaging via stream copy.
    def self.transcode_video(
      input_path:,
      output_path:,
      bitrate_kbps:,
      max_fps:,
      audio_bitrate_kbps: 128,
      extra_vf: nil,
      hls_segment_seconds: nil
    )
      buf_kbps = [bitrate_kbps.to_i * 2, 256].max

      # IMPORTANT: enforce even dimensions for yuv420p/x264
      # (prevents failures on odd-width/odd-height sources like 853x480 etc.)
      vf =
        "scale='if(gte(iw,ih),min(1920,iw),min(1080,iw))':'if(gte(iw,ih),min(1080,ih),min(1920,ih))':force_original_aspect_ratio=decrease," \
        "scale=trunc(iw/2)*2:trunc(ih/2)*2," \
        "fps=fps=#{max_fps}"

      vf = "#{vf},#{extra_vf}" if extra_vf.present?  

      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?", # optional audio (won't fail if source has no audio)
        "-sn",
        "-dn",
        "-movflags",
        "+faststart",
        "-vf",
        vf,
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-profile:v",
        "main",
        "-level",
        "4.1",
        "-pix_fmt",
        "yuv420p",
        "-b:v",
        "#{bitrate_kbps}k",
        "-maxrate",
        "#{bitrate_kbps}k",
        "-bufsize",
        "#{buf_kbps}k",
      ]

      # Force GOP alignment for HLS packaging (milestone 1).
      seg = hls_segment_seconds.to_i
      if seg > 0
        fps_i = [max_fps.to_i, 1].max
        gop = fps_i * seg

        cmd += [
          "-g",
          gop.to_s,
          "-keyint_min",
          gop.to_s,
          "-sc_threshold",
          "0",
          "-force_key_frames",
          "expr:gte(t,n_forced*#{seg})",
        ]
      end

      cmd += [
        "-c:a",
        "aac",
        "-b:a",
        "#{audio_bitrate_kbps}k",
        "-ac",
        "2",
        "-ar",
        "48000",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_video_failed: #{short_err(stderr)}" unless status.success?
    end

    # Milestone 1: package a processed MP4 into a single HLS variant.
    # Produces: output_dir/index.m3u8 + output_dir/seg_XXXXX.ts
    def self.package_hls_single_variant(input_path:, output_dir:, segment_seconds:)
      FileUtils.mkdir_p(output_dir)
      seg = segment_seconds.to_i
      seg = 6 if seg <= 0

      playlist_path = File.join(output_dir, "index.m3u8")
      segment_pattern = File.join(output_dir, "seg_%05d.ts")

      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-c",
        "copy",
        "-f",
        "hls",
        "-hls_time",
        seg.to_s,
        "-hls_playlist_type",
        "vod",
        "-hls_flags",
        "independent_segments",
        "-hls_list_size",
        "0",
        "-hls_segment_filename",
        segment_pattern,
        playlist_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_hls_failed: #{short_err(stderr)}" unless status.success?
    end

    # Image standardization: JPG, max 1920x1080 (no upscale), keep aspect.
    def self.transcode_image_to_jpg(input_path:, output_path:, extra_vf: nil)
      vf = "scale='if(gte(iw,ih),min(1920,iw),min(1080,iw))':'if(gte(iw,ih),min(1080,ih),min(1920,ih))':force_original_aspect_ratio=decrease"
      vf = "#{vf},#{extra_vf}" if extra_vf.present?

      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-vf",
        vf,
        "-frames:v",
        "1",
        "-q:v",
        "3",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_image_failed: #{short_err(stderr)}" unless status.success?
    end

    def self.create_jpg_thumbnail(input_path:, output_path:)
      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-vf",
        "scale=640:-2",
        "-q:v",
        "4",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_thumb_failed: #{short_err(stderr)}" unless status.success?
    end

    def self.extract_video_thumbnail(input_path:, output_path:)
      cmd = [
        ffmpeg_path,
        *ffmpeg_common_args,
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-ss",
        "00:00:01.000",
        "-vframes",
        "1",
        "-vf",
        "scale=640:-2",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_thumb_failed: #{short_err(stderr)}" unless status.success?
    end
  end
end
