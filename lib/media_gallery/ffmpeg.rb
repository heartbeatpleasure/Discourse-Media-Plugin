# frozen_string_literal: true

require "open3"

module MediaGallery
  class Ffmpeg
    def self.ffmpeg_path
      SiteSetting.media_gallery_ffmpeg_path.presence || "ffmpeg"
    end

    def self.ffprobe_path
      SiteSetting.media_gallery_ffprobe_path.presence || "ffprobe"
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
      raise "ffprobe_failed: #{stderr.presence || "unknown error"}" unless status.success?

      JSON.parse(stdout)
    end

    # Audio profile: MP3 128 kbps, 44.1kHz, stereo
    def self.transcode_audio(input_path:, output_path:, bitrate_kbps:)
      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
        "-vn",
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
      raise "ffmpeg_audio_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end

    # Video profile: MP4, H.264 Main@4.1, max 1080p, max 30fps, ~5Mbps, AAC 128kbps
    def self.transcode_video(input_path:, output_path:, bitrate_kbps:, max_fps:, audio_bitrate_kbps: 128)
      buf_kbps = [bitrate_kbps.to_i * 2, 256].max

      vf = "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease,fps=fps=#{max_fps}"

      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
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
      raise "ffmpeg_video_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end

    # Image standardization: JPG, max 1920x1080 (no upscale), keep aspect.
    def self.transcode_image_to_jpg(input_path:, output_path:)
      vf = "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease"

      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
        "-vf",
        vf,
        "-frames:v",
        "1",
        "-q:v",
        "3",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_image_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end

    def self.create_jpg_thumbnail(input_path:, output_path:)
      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
        "-frames:v",
        "1",
        "-vf",
        "scale=640:-2",
        "-q:v",
        "4",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_thumb_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end

    def self.extract_video_thumbnail(input_path:, output_path:)
      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
        "-ss",
        "00:00:01.000",
        "-vframes",
        "1",
        "-vf",
        "scale=640:-2",
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_thumb_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end
  end
end
