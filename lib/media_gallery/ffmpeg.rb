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
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_audio_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end

    # audio_bitrate_kbps added to allow adaptive sizing vs. Discourse max attachment limits
    def self.transcode_video(input_path:, output_path:, bitrate_kbps:, max_fps:, audio_bitrate_kbps: 96)
      buf_kbps = [bitrate_kbps.to_i * 2, 256].max

      cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        input_path,
        "-movflags",
        "+faststart",
        "-vf",
        "fps=fps=#{max_fps}",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-profile:v",
        "main",
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
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_video_failed: #{stderr.presence || "unknown error"}" unless status.success?
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
        output_path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise "ffmpeg_thumb_failed: #{stderr.presence || "unknown error"}" unless status.success?
    end
  end
end
