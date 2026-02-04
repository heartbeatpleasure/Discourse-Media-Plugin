# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Jobs
  class MediaGalleryProcessItem < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      item = MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      item.update!(status: "processing", error_message: nil)

      with_processing_mutex do
        process_item!(item)
      end
    rescue => e
      if item&.persisted?
        item.update!(status: "failed", error_message: e.message.truncate(1000))
      end
      raise e
    end

    private

    def with_processing_mutex(&blk)
      # Avoid multiple ffmpeg jobs saturating CPU on small servers.
      # Discourse provides DistributedMutex via Redis.
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize("media_gallery_process_mutex", validity: 2.hours, &blk)
      else
        yield
      end
    end

    def process_item!(item)
      raise "missing_original_upload" if item.original_upload.blank?

      input_path = MediaGallery::UploadPath.local_path_for(item.original_upload)
      raise "original_upload_not_on_local_disk" if input_path.blank?
      raise "original_file_missing: #{input_path}" unless File.exist?(input_path)

      probe = MediaGallery::Ffmpeg.probe(input_path)

      duration_seconds = probe.dig("format", "duration").to_f
      item.duration_seconds = duration_seconds if duration_seconds.positive?

      stream = (probe["streams"] || []).find { |s| s["codec_type"] == "video" }
      if stream.present?
        item.width = stream["width"]
        item.height = stream["height"]
      end

      Dir.mktmpdir("media-gallery") do |dir|
        ext = safe_extension(item.original_upload.original_filename)
        tmp_input = File.join(dir, "in#{ext}")
        FileUtils.cp(input_path, tmp_input)

        if video?(probe)
          processed = process_video!(item, dir, tmp_input, duration_seconds)
        elsif audio?(probe)
          processed = process_audio!(item, dir, tmp_input)
        else
          raise "unsupported_media_type"
        end

        item.processed_upload_id = processed.id

        if SiteSetting.media_gallery_delete_original_on_success
          item.original_upload.destroy!
        end

        item.status = "ready"
        item.error_message = nil
        item.save!
      end
    end

    def process_audio!(item, dir, tmp_input)
      out_path = File.join(dir, "media-#{item.public_id}.mp3")

      bitrate = SiteSetting.media_gallery_audio_bitrate_kbps.to_i
      bitrate = 192 if bitrate <= 0

      MediaGallery::Ffmpeg.transcode_audio(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: bitrate,
      )

      create_upload_for_user(item.user_id, out_path)
    end

    def process_video!(item, dir, tmp_input, duration_seconds)
      out_path = File.join(dir, "media-#{item.public_id}.mp4")

      max_fps = SiteSetting.media_gallery_video_max_fps.to_i
      max_fps = 30 if max_fps <= 0

      video_kbps, audio_kbps, max_bytes = pick_video_bitrates(duration_seconds)

      MediaGallery::Ffmpeg.transcode_video(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: video_kbps,
        max_fps: max_fps,
        audio_bitrate_kbps: audio_kbps,
      )

      enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input, item)

      thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
      begin
        MediaGallery::Ffmpeg.extract_video_thumbnail(input_path: tmp_input, output_path: thumb_path)
        item.thumbnail_upload_id = create_upload_for_user(item.user_id, thumb_path).id if File.exist?(thumb_path)
      rescue => _e
        # Thumbnail is best-effort; do not fail the whole job.
      end

      create_upload_for_user(item.user_id, out_path)
    end

    def enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input, item)
      return if max_bytes.blank? || max_bytes <= 0
      return if duration_seconds.blank? || duration_seconds <= 0

      out_size = File.size?(out_path).to_i
      return if out_size <= max_bytes

      # One retry with lower video bitrate based on observed overshoot.
      # This usually fixes "UploadCreator failed" when Discourse rejects by size.
      ratio = max_bytes.to_f / out_size.to_f
      current_video_kbps = estimated_video_kbps_from_file(out_size, duration_seconds, audio_kbps)
      new_video_kbps = [(current_video_kbps * ratio * 0.9).floor, 64].max

      MediaGallery::Ffmpeg.transcode_video(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: new_video_kbps,
        max_fps: max_fps,
        audio_bitrate_kbps: audio_kbps,
      )

      out_size2 = File.size?(out_path).to_i
      return if out_size2 <= max_bytes

      raise(
        "processed_file_too_large: out=#{out_size2}B max=#{max_bytes}B. " \
        "Lower 'media gallery video target bitrate kbps' and/or increase Discourse 'max attachment size kb'."
      )
    end

    def pick_video_bitrates(duration_seconds)
      configured_video = SiteSetting.media_gallery_video_target_bitrate_kbps.to_i
      configured_video = 2500 if configured_video <= 0

      # We use a lower default audio bitrate to make it easier to stay within Discourse limits.
      audio_kbps = 96

      max_kb = SiteSetting.max_attachment_size_kb.to_i
      max_bytes = max_kb.positive? ? (max_kb * 1024) : nil

      return [configured_video, audio_kbps, max_bytes] if max_bytes.blank? || duration_seconds.blank? || duration_seconds <= 0

      safety = 0.92
      total_kbps_budget = ((max_bytes * 8.0 * safety) / duration_seconds) / 1000.0

      # If budget is tight, drop audio first.
      audio_kbps = 48 if total_kbps_budget < (audio_kbps + 96)

      video_budget = (total_kbps_budget - audio_kbps).floor
      video_budget = 64 if video_budget < 64

      [ [configured_video, video_budget].min, audio_kbps, max_bytes ]
    end

    def estimated_video_kbps_from_file(bytes, duration_seconds, audio_kbps)
      return 500 if duration_seconds.to_f <= 0
      total_kbps = ((bytes.to_f * 8.0) / duration_seconds.to_f) / 1000.0
      v = (total_kbps - audio_kbps.to_f).floor
      v < 64 ? 64 : v
    end

    def create_upload_for_user(user_id, path)
      filename = File.basename(path)
      size = File.size?(path).to_i
      raise "processed_file_missing: #{filename}" if size <= 0

      file = File.open(path, "rb")

      # Ensure the same upload rules as /uploads.json type=composer.
      upload = ::UploadCreator.new(file, filename, type: "composer").create_for(user_id)

      unless upload&.persisted?
        errors = (upload&.errors&.full_messages || []).join(", ")
        extra = []
        extra << "bytes=#{size}"
        extra << "errors=#{errors}" if errors.present?
        raise "UploadCreator failed for #{filename} (#{extra.join(" ")})"
      end

      upload
    ensure
      file&.close
    end

    def video?(probe)
      (probe["streams"] || []).any? { |s| s["codec_type"] == "video" }
    end

    def audio?(probe)
      !video?(probe) && (probe["streams"] || []).any? { |s| s["codec_type"] == "audio" }
    end

    def safe_extension(name)
      ext = File.extname(name.to_s).downcase
      ext = ".bin" if ext.blank? || ext.length > 8
      ext
    end
  end
end
