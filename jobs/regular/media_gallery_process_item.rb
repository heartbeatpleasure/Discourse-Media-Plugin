# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Jobs
  class MediaGalleryProcessItem < ::Jobs::Base
    # Spec: dedicated queue
    sidekiq_options queue: "media_encoding"

    def execute(args)
      item = MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      # Only process queued/processing items
      return unless item.status == "queued" || item.status == "processing"

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

      # Fill original size if missing
      item.filesize_original_bytes ||= item.original_upload.filesize

      probe = MediaGallery::Ffmpeg.probe(input_path)

      duration_seconds_f = probe.dig("format", "duration").to_f
      duration_seconds_i = duration_seconds_f.positive? ? duration_seconds_f.round : nil

      streams = probe["streams"] || []
      video_stream = streams.find { |s| s["codec_type"] == "video" }
      audio_stream = streams.find { |s| s["codec_type"] == "audio" }

      if video_stream.present?
        item.media_type = "video"
        item.width = video_stream["width"]
        item.height = video_stream["height"]
        item.duration_seconds = duration_seconds_i if duration_seconds_i
      elsif audio_stream.present?
        item.media_type = "audio"
        item.duration_seconds = duration_seconds_i if duration_seconds_i
      else
        item.update!(status: "failed", error_message: "unsupported_media_type")
        return
      end

      # Policy checks (spec)
      if item.media_type == "video"
        max_dur = SiteSetting.media_gallery_video_max_duration_seconds.to_i
        if max_dur.positive? && duration_seconds_f.positive? && duration_seconds_f > max_dur
          item.update!(status: "failed", error_message: "duration_exceeds_#{max_dur}_seconds")
          return
        end
      end

      if item.media_type == "audio"
        max_dur = SiteSetting.media_gallery_audio_max_duration_seconds.to_i
        if max_dur.positive? && duration_seconds_f.positive? && duration_seconds_f > max_dur
          item.update!(status: "failed", error_message: "duration_exceeds_#{max_dur}_seconds")
          return
        end
      end

      item.save!

      Dir.mktmpdir("media-gallery") do |dir|
        ext = safe_extension(item.original_upload.original_filename)
        tmp_input = File.join(dir, "in#{ext}")
        FileUtils.cp(input_path, tmp_input)

        processed_upload =
          if item.media_type == "video"
            process_video!(item, dir, tmp_input, duration_seconds_f)
          else
            process_audio!(item, dir, tmp_input)
          end

        item.processed_upload_id = processed_upload.id
        item.filesize_processed_bytes = processed_upload.filesize

        # Best-effort: probe processed output to store final dimensions
        begin
          out_path = MediaGallery::UploadPath.local_path_for(processed_upload)
          if out_path.present? && File.exist?(out_path)
            out_probe = MediaGallery::Ffmpeg.probe(out_path)
            out_vs = (out_probe["streams"] || []).find { |s| s["codec_type"] == "video" }
            if out_vs.present?
              item.width = out_vs["width"]
              item.height = out_vs["height"]
            end
          end
        rescue => _e
        end

        if SiteSetting.media_gallery_delete_original_on_success
          original = item.original_upload
          item.original_upload_id = nil
          item.save!
          original.destroy!
        end

        item.status = "ready"
        item.error_message = nil
        item.save!
      end
    end

    def process_audio!(item, dir, tmp_input)
      out_path = File.join(dir, "media-#{item.public_id}.mp3")

      bitrate = SiteSetting.media_gallery_audio_bitrate_kbps.to_i
      bitrate = 128 if bitrate <= 0

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

      enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input)

      thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
      begin
        MediaGallery::Ffmpeg.extract_video_thumbnail(input_path: tmp_input, output_path: thumb_path)
        if File.exist?(thumb_path)
          item.thumbnail_upload_id = create_upload_for_user(item.user_id, thumb_path).id
          item.save!
        end
      rescue => _e
        # Thumbnail is best-effort; do not fail the whole job.
      end

      create_upload_for_user(item.user_id, out_path)
    end

    def enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input)
      return if max_bytes.blank? || max_bytes <= 0
      return if duration_seconds.blank? || duration_seconds.to_f <= 0

      out_size = File.size?(out_path).to_i
      return if out_size <= max_bytes

      # One retry with lower video bitrate based on observed overshoot.
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
      configured_video = 5000 if configured_video <= 0

      audio_kbps = 128

      max_kb = SiteSetting.max_attachment_size_kb.to_i
      max_bytes = max_kb.positive? ? (max_kb * 1024) : nil

      return [configured_video, audio_kbps, max_bytes] if max_bytes.blank? || duration_seconds.to_f <= 0

      safety = 0.92
      total_kbps_budget = ((max_bytes * 8.0 * safety) / duration_seconds.to_f) / 1000.0

      # If budget is tight, drop audio first.
      audio_kbps = 96 if total_kbps_budget < (audio_kbps + 128)

      video_budget = (total_kbps_budget - audio_kbps).floor
      video_budget = 64 if video_budget < 64

      [[configured_video, video_budget].min, audio_kbps, max_bytes]
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

    def safe_extension(name)
      ext = File.extname(name.to_s).downcase
      ext = ".bin" if ext.blank? || ext.length > 8
      ext
    end
  end
end
