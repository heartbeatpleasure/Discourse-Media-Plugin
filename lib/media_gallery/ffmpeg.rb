# frozen_string_literal: true

require "json"
require "open3"

module ::MediaGallery
  class FfmpegError < StandardError; end

  module Ffmpeg
    module_function

    def ffmpeg_path
      SiteSetting.media_gallery_ffmpeg_path.presence || "ffmpeg"
    end

    def ffprobe_path
      SiteSetting.media_gallery_ffprobe_path.presence || "ffprobe"
    end

    def probe(input_path)
      cmd = [
        ffprobe_path,
        "-v", "error",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        input_path
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      raise FfmpegError, "ffprobe failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise FfmpegError, "ffprobe JSON parse failed: #{e.message}"
    end

    def transcode_video(input_path, output_path, bitrate_kbps:, max_fps:)
      scale = "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease"
      cmd = [
        ffmpeg_path,
        "-y",
        "-i", input_path,
        "-vf", scale,
        "-r", max_fps.to_s,
        "-c:v", "libx264",
        "-profile:v", "main",
        "-level", "4.1",
        "-b:v", "#{bitrate_kbps}k",
        "-maxrate", "#{bitrate_kbps}k",
        "-bufsize", "#{bitrate_kbps * 2}k",
        "-preset", "veryfast",
        "-movflags", "+faststart",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        output_path
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise FfmpegError, "ffmpeg video failed: #{stderr}" unless status.success?
      true
    end

    def transcode_audio(input_path, output_path, bitrate_kbps:)
      cmd = [
        ffmpeg_path,
        "-y",
        "-i", input_path,
        "-vn",
        "-c:a", "libmp3lame",
        "-b:a", "#{bitrate_kbps}k",
        "-ar", "44100",
        "-ac", "2",
        output_path
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise FfmpegError, "ffmpeg audio failed: #{stderr}" unless status.success?
      true
    end

    def extract_video_thumbnail(input_path, output_path)
      cmd = [
        ffmpeg_path,
        "-y",
        "-ss", "2",
        "-i", input_path,
        "-frames:v", "1",
        "-vf", "scale=512:-1",
        output_path
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise FfmpegError, "ffmpeg thumbnail failed: #{stderr}" unless status.success?
      true
    end
  end
end
