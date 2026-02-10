# frozen_string_literal: true

module ::MediaGallery
  # Best-effort detection of the *actual* media type using ffprobe output.
  #
  # We keep extension/mime based inference as the primary signal (cheap + predictable),
  # but we use ffprobe as a verifier to catch mismatches (e.g. wrong MIME, renamed files)
  # and to prevent the processing job from attempting the wrong pipeline.
  #
  # NOTE: ffprobe reports still images as a "video" stream (e.g. format_name: jpeg_pipe/png_pipe),
  # so we classify images via format_name heuristics and absence of audio streams.
  class TypeDetector
    IMAGE_FORMAT_TOKENS = %w[
      image2
      image2pipe
      jpeg_pipe
      png_pipe
      webp_pipe
      bmp_pipe
      tiff_pipe
      gif_pipe
      apng_pipe
    ].freeze

    class << self
      # Returns "image" | "audio" | "video" | nil
      def infer_from_path(path)
        return nil if path.blank? || !File.exist?(path)

        probe = MediaGallery::Ffmpeg.probe(path)
        infer_from_probe(probe)
      rescue
        nil
      end

      # Returns "image" | "audio" | "video" | nil
      def infer_from_probe(probe)
        streams = probe["streams"] || []
        format_name = probe.dig("format", "format_name").to_s

        audio_streams = streams.select { |s| s["codec_type"] == "audio" }

        # Ignore cover art (attached_pic) which appears as a video stream in audio files.
        video_streams =
          streams.select do |s|
            next false unless s["codec_type"] == "video"
            s.dig("disposition", "attached_pic").to_i != 1
          end

        has_audio = audio_streams.any?
        has_video = video_streams.any?

        if has_audio && !has_video
          return "audio"
        end

        if has_video
          # If it looks like an image container (jpeg_pipe/png_pipe/image2 etc) and has no audio,
          # treat it as an image.
          if !has_audio && looks_like_image_format?(format_name)
            return "image"
          end

          # A/V container (or video-only)
          return "video"
        end

        # Edge-case: no non-attached video streams but has audio
        return "audio" if has_audio

        nil
      end

      def extension_allowed_for_type?(ext, media_type)
        e = ext.to_s.downcase.sub(/\A\./, "")

        allowed =
          case media_type
          when "image" then MediaGallery::MediaItem::IMAGE_EXTS
          when "audio" then MediaGallery::MediaItem::AUDIO_EXTS
          when "video" then MediaGallery::MediaItem::VIDEO_EXTS
          else []
          end

        allowed.include?(e)
      end

      private

      def looks_like_image_format?(format_name)
        names = format_name.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?)
        return false if names.blank?

        names.any? do |n|
          IMAGE_FORMAT_TOKENS.any? { |tok| n.start_with?(tok) } || n.end_with?("_pipe")
        end
      end
    end
  end
end
