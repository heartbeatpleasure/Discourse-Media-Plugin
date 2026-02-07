# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Jobs
  class MediaGalleryProcessItem < ::Jobs::Base
    # Default queue works out-of-the-box on most Discourse installs.
    # If you really want a dedicated queue, change to: sidekiq_options queue: "media_encoding"
    sidekiq_options queue: "default"

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
        item.update!(status: "failed", error_message: e.message.to_s.truncate(1000))
      end
      raise e
    end

    private

    def with_processing_mutex(&blk)
      # Avoid multiple ffmpeg jobs saturating CPU on small servers.
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize("media_gallery_process_mutex", validity: 2.hours, &blk)
      else
        yield
      end
    end

    def process_item!(item)
      raise "missing_original_upload" if item.original_upload.blank?

      original_upload = item.original_upload
      input_path = MediaGallery::UploadPath.local_path_for(original_upload)
      raise "original_upload_not_on_local_disk" if input_path.blank?
      raise "original_file_missing: #{input_path}" unless File.exist?(input_path)

      item.filesize_original_bytes ||= original_upload.filesize

      media_type = item.media_type.presence || infer_media_type_from_upload(original_upload)
      raise "unsupported_file_type" if media_type.blank?

      item.media_type = media_type
      item.save!

      private_mode = MediaGallery::PrivateStorage.enabled?

      Dir.mktmpdir("media-gallery") do |dir|
        ext = safe_extension(original_upload.original_filename)
        tmp_input = File.join(dir, "in#{ext}")
        FileUtils.cp(input_path, tmp_input)

        processed_tmp = nil
        thumb_tmp = nil

        case media_type
        when "video"
          processed_tmp, thumb_tmp = process_video_tmp!(item, dir, tmp_input)
        when "audio"
          processed_tmp = process_audio_tmp!(item, dir, tmp_input)
        when "image"
          processed_tmp, thumb_tmp = process_image_tmp!(item, dir, tmp_input, force_jpg: private_mode)
        else
          raise "unsupported_file_type"
        end

        raise "processed_output_missing" if processed_tmp.blank? || !File.exist?(processed_tmp)

        if private_mode
          store_private_outputs!(item, processed_tmp: processed_tmp, thumb_tmp: thumb_tmp)
        else
          store_as_uploads!(item, processed_tmp: processed_tmp, thumb_tmp: thumb_tmp)
        end

        # Export + delete original upload (Option A)
        if SiteSetting.media_gallery_delete_original_on_success
          maybe_export_original!(item, original_upload, input_path)
          destroy_upload_safely!(original_upload)
          item.original_upload_id = nil
          item.save!
        end

        item.update!(status: "ready", error_message: nil)
      end
    end

    def maybe_export_original!(item, upload, input_path)
      return unless MediaGallery::PrivateStorage.enabled?

      hours = MediaGallery::PrivateStorage.original_retention_hours
      return if hours <= 0

      # Export original to a private folder so a NAS can rsync-pull it.
      MediaGallery::PrivateStorage.export_original!(
        item: item,
        source_path: input_path,
        original_filename: upload.original_filename,
        extension: upload.extension
      )

      meta = (item.extra_metadata || {}).dup
      meta["original_exported_at"] = Time.now.utc.iso8601
      meta["original_retention_hours"] = hours
      item.extra_metadata = meta
      item.save!
    end

    def destroy_upload_safely!(upload)
      return if upload.blank?

      if defined?(::UploadDestroyer)
        ::UploadDestroyer.new(Discourse.system_user, upload).destroy
      else
        upload.destroy!
      end
    rescue => e
      Rails.logger.warn("[media_gallery] failed to destroy original upload id=#{upload&.id}: #{e.class}: #{e.message}")
    end

    # --- Processing to tmp files (no DB writes) ---

    def process_audio_tmp!(item, dir, tmp_input)
      out_path = File.join(dir, "media-#{item.public_id}.mp3")

      bitrate = SiteSetting.media_gallery_audio_bitrate_kbps.to_i
      bitrate = 128 if bitrate <= 0

      # Duration policy
      begin
        probe = MediaGallery::Ffmpeg.probe(tmp_input)
        duration = probe.dig("format", "duration").to_f
        item.duration_seconds = duration.round if duration.positive?

        max_dur = SiteSetting.media_gallery_audio_max_duration_seconds.to_i
        if max_dur.positive? && duration.positive? && duration > max_dur
          item.update!(status: "failed", error_message: "duration_exceeds_#{max_dur}_seconds")
          raise "duration_policy_failed"
        end
      rescue
        # If probe fails we still try to transcode; ffmpeg will error if unsupported.
      end

      MediaGallery::Ffmpeg.transcode_audio(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: bitrate,
      )

      out_path
    end

    def process_video_tmp!(item, dir, tmp_input)
      out_path = File.join(dir, "media-#{item.public_id}.mp4")

      max_fps = SiteSetting.media_gallery_video_max_fps.to_i
      max_fps = 30 if max_fps <= 0

      video_kbps, audio_kbps, max_bytes, duration_seconds_f, width, height = pick_video_bitrates(tmp_input)

      if width.present? && height.present?
        item.width = width
        item.height = height
      end
      item.duration_seconds = duration_seconds_f.round if duration_seconds_f.positive?

      # Duration policy
      max_dur = SiteSetting.media_gallery_video_max_duration_seconds.to_i
      if max_dur.positive? && duration_seconds_f.positive? && duration_seconds_f > max_dur
        item.update!(status: "failed", error_message: "duration_exceeds_#{max_dur}_seconds")
        raise "duration_policy_failed"
      end

      MediaGallery::Ffmpeg.transcode_video(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: video_kbps,
        max_fps: max_fps,
        audio_bitrate_kbps: audio_kbps,
      )

      enforce_max_bytes!(out_path, duration_seconds_f, max_bytes, max_fps, audio_kbps, tmp_input)

      # Thumbnail (best-effort)
      thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
      begin
        MediaGallery::Ffmpeg.extract_video_thumbnail(input_path: tmp_input, output_path: thumb_path)
      rescue
        thumb_path = nil
      end

      thumb_path = nil if thumb_path.present? && !File.exist?(thumb_path)

      [out_path, thumb_path]
    end

    def process_image_tmp!(item, dir, tmp_input, force_jpg: false)
      # In private mode we always produce a JPG to keep paths deterministic.
      transcode = force_jpg || SiteSetting.media_gallery_transcode_images_to_jpg

      if !transcode
        # Keep the original bytes, but still try to generate a JPG thumbnail.
        out_path = File.join(dir, "media-#{item.public_id}#{safe_extension(item.original_upload.original_filename)}")
        FileUtils.cp(tmp_input, out_path)

        thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
        begin
          MediaGallery::Ffmpeg.create_jpg_thumbnail(input_path: tmp_input, output_path: thumb_path)
        rescue
          thumb_path = nil
        end
        thumb_path = nil if thumb_path.present? && !File.exist?(thumb_path)
        return [out_path, thumb_path]
      end

      out_path = File.join(dir, "media-#{item.public_id}.jpg")
      MediaGallery::Ffmpeg.transcode_image_to_jpg(input_path: tmp_input, output_path: out_path)

      thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
      begin
        MediaGallery::Ffmpeg.create_jpg_thumbnail(input_path: out_path, output_path: thumb_path)
      rescue
        thumb_path = nil
      end
      thumb_path = nil if thumb_path.present? && !File.exist?(thumb_path)

      [out_path, thumb_path]
    end

    # --- Storage backends ---

    def store_private_outputs!(item, processed_tmp:, thumb_tmp:)
      # Move into /shared (private, not /uploads)
      MediaGallery::PrivateStorage.ensure_dir!(MediaGallery::PrivateStorage.item_private_dir(item.public_id))

      final_main = MediaGallery::PrivateStorage.processed_abs_path(item)
      FileUtils.rm_f(final_main)
      FileUtils.mv(processed_tmp, final_main)

      final_thumb = nil
      if thumb_tmp.present? && File.exist?(thumb_tmp)
        final_thumb = MediaGallery::PrivateStorage.thumbnail_abs_path(item)
        FileUtils.rm_f(final_thumb)
        FileUtils.mv(thumb_tmp, final_thumb)
      end

      # Persist metadata (do not rely on Upload rows)
      item.processed_upload_id = nil
      item.thumbnail_upload_id = nil

      item.filesize_processed_bytes = File.size?(final_main).to_i
      enrich_dimensions_and_duration!(item, final_main)

      meta = (item.extra_metadata || {}).dup
      meta["storage"] = "private"
      meta["processed_rel_path"] = MediaGallery::PrivateStorage.processed_rel_path(item)
      meta["thumbnail_rel_path"] = MediaGallery::PrivateStorage.thumbnail_rel_path(item) if final_thumb.present?
      item.extra_metadata = meta

      item.save!
    end

    def store_as_uploads!(item, processed_tmp:, thumb_tmp:)
      processed = create_upload_for_user(item.user_id, processed_tmp)

      item.processed_upload_id = processed.id
      item.filesize_processed_bytes = processed.filesize

      if processed.respond_to?(:width) && processed.width.present?
        item.width = processed.width
      end
      if processed.respond_to?(:height) && processed.height.present?
        item.height = processed.height
      end

      if thumb_tmp.present? && File.exist?(thumb_tmp)
        thumb = create_upload_for_user(item.user_id, thumb_tmp)
        item.thumbnail_upload_id = thumb.id
      end

      # Best-effort duration probing from processed file
      item.duration_seconds ||= probe_duration_seconds(MediaGallery::UploadPath.local_path_for(processed))
      item.save!
    end

    def enrich_dimensions_and_duration!(item, path)
      probe = MediaGallery::Ffmpeg.probe(path)

      duration_seconds_f = probe.dig("format", "duration").to_f
      item.duration_seconds = duration_seconds_f.round if duration_seconds_f.positive?

      streams = probe["streams"] || []
      vs = streams.find { |s| s["codec_type"] == "video" } || streams.first
      if vs.present?
        item.width = vs["width"] if vs["width"].present?
        item.height = vs["height"] if vs["height"].present?
      end
    rescue
      # ignore
    end

    def probe_duration_seconds(path)
      return nil if path.blank? || !File.exist?(path)

      probe = MediaGallery::Ffmpeg.probe(path)
      duration_seconds_f = probe.dig("format", "duration").to_f
      duration_seconds_f.positive? ? duration_seconds_f.round : nil
    rescue
      nil
    end

    # --- Helpers ---

    def infer_media_type_from_upload(upload)
      ext = upload.extension.to_s.downcase
      ctype = upload_mime(upload)

      return "image" if ctype.start_with?("image/") && MediaGallery::MediaItem::IMAGE_EXTS.include?(ext)
      return "audio" if ctype.start_with?("audio/") && MediaGallery::MediaItem::AUDIO_EXTS.include?(ext)
      return "video" if ctype.start_with?("video/") && MediaGallery::MediaItem::VIDEO_EXTS.include?(ext)

      return "image" if MediaGallery::MediaItem::IMAGE_EXTS.include?(ext)
      return "audio" if MediaGallery::MediaItem::AUDIO_EXTS.include?(ext)
      return "video" if MediaGallery::MediaItem::VIDEO_EXTS.include?(ext)

      nil
    end

    def upload_mime(upload)
      if upload.respond_to?(:mime_type) && upload.mime_type.present?
        upload.mime_type.to_s.downcase
      elsif upload.respond_to?(:content_type) && upload.content_type.present?
        upload.content_type.to_s.downcase
      else
        ""
      end
    end

    def pick_video_bitrates(tmp_input)
      configured_video = SiteSetting.media_gallery_video_target_bitrate_kbps.to_i
      configured_video = 5000 if configured_video <= 0

      audio_kbps = 128

      max_kb = SiteSetting.max_attachment_size_kb.to_i
      max_bytes = max_kb.positive? ? (max_kb * 1024) : nil

      duration_seconds_f = 0.0
      width = nil
      height = nil

      begin
        probe = MediaGallery::Ffmpeg.probe(tmp_input)
        duration_seconds_f = probe.dig("format", "duration").to_f

        vs = (probe["streams"] || []).find { |s| s["codec_type"] == "video" }
        if vs.present?
          width = vs["width"]
          height = vs["height"]
        end
      rescue
      end

      if max_bytes.blank? || duration_seconds_f.to_f <= 0
        return [configured_video, audio_kbps, max_bytes, duration_seconds_f, width, height]
      end

      safety = 0.92
      total_kbps_budget = ((max_bytes * 8.0 * safety) / duration_seconds_f.to_f) / 1000.0

      audio_kbps = 96 if total_kbps_budget < (audio_kbps + 128)

      video_budget = (total_kbps_budget - audio_kbps).floor
      video_budget = 64 if video_budget < 64

      [[configured_video, video_budget].min, audio_kbps, max_bytes, duration_seconds_f, width, height]
    end

    def enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input)
      return if max_bytes.blank? || max_bytes <= 0
      return if duration_seconds.blank? || duration_seconds.to_f <= 0

      out_size = File.size?(out_path).to_i
      return if out_size <= max_bytes

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
        "processed_file_too_large: out=#{out_size2}B max=#{max_bytes}B. "         "Lower 'media gallery video target bitrate kbps' and/or increase Discourse 'max attachment size kb'."
      )
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
