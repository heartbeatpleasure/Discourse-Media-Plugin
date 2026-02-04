# frozen_string_literal: true

module ::Jobs
  class MediaGalleryProcessItem < ::Jobs::Base
    sidekiq_options queue: "media_gallery_encoding"

    def execute(args)
      media_item_id = args[:media_item_id].to_i
      item = ::MediaGallery::MediaItem.find_by(id: media_item_id)
      return if item.nil?

      return if item.status == "ready" || item.status == "failed"

      item.update!(status: "processing", error_message: nil)

      original = ::Upload.find_by(id: item.original_upload_id)
      raise "Original upload not found" if original.nil?

      input_path = ::MediaGallery::UploadPath.local_path_for(original)

      meta = ::MediaGallery::Ffmpeg.probe(input_path)
      streams = meta["streams"] || []
      format = meta["format"] || {}

      has_video = streams.any? { |s| s["codec_type"] == "video" }
      has_audio = streams.any? { |s| s["codec_type"] == "audio" }

      duration = (format["duration"] || "0").to_f
      duration_seconds = (duration > 0) ? duration.round : nil

      width = nil
      height = nil
      if has_video
        v = streams.find { |s| s["codec_type"] == "video" }
        width = v["width"].to_i if v && v["width"]
        height = v["height"].to_i if v && v["height"]
      end

      media_type =
        if has_video
          "video"
        elsif has_audio
          "audio"
        else
          # If neither audio nor video streams exist, treat as image (best-effort).
          "image"
        end

      item.update!(
        media_type: media_type,
        duration_seconds: duration_seconds,
        width: width,
        height: height
      )

      # Policy checks
      if media_type == "video" && duration_seconds && duration_seconds > SiteSetting.media_gallery_video_max_duration_seconds.to_i
        item.update!(status: "failed", error_message: "duration_exceeds_video_limit")
        return
      end

      if media_type == "audio" && duration_seconds && duration_seconds > SiteSetting.media_gallery_audio_max_duration_seconds.to_i
        item.update!(status: "failed", error_message: "duration_exceeds_audio_limit")
        return
      end

      # No transcode needed for images in this version
      if media_type == "image"
        item.update!(
          processed_upload_id: original.id,
          filesize_processed_bytes: original.filesize,
          status: "ready"
        )
        return
      end

      Dir.mktmpdir("media_gallery") do |dir|
        if media_type == "video"
          out_path = File.join(dir, "media-#{item.public_id}.mp4")
          thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")

          ::MediaGallery::Ffmpeg.transcode_video(
            input_path,
            out_path,
            bitrate_kbps: SiteSetting.media_gallery_video_target_bitrate_kbps.to_i,
            max_fps: SiteSetting.media_gallery_video_max_fps.to_i
          )

          begin
            ::MediaGallery::Ffmpeg.extract_video_thumbnail(input_path, thumb_path)
          rescue ::MediaGallery::FfmpegError
            thumb_path = nil
          end

          processed_upload = create_upload_for_user(item.user_id, out_path, "video/mp4")
          thumb_upload = thumb_path && File.exist?(thumb_path) ? create_upload_for_user(item.user_id, thumb_path, "image/jpeg") : nil

          finalize_success(item, original, processed_upload, thumb_upload)
        elsif media_type == "audio"
          out_path = File.join(dir, "media-#{item.public_id}.mp3")

          ::MediaGallery::Ffmpeg.transcode_audio(
            input_path,
            out_path,
            bitrate_kbps: SiteSetting.media_gallery_audio_bitrate_kbps.to_i
          )

          processed_upload = create_upload_for_user(item.user_id, out_path, "audio/mpeg")
          finalize_success(item, original, processed_upload, nil)
        else
          item.update!(status: "failed", error_message: "unsupported_media_type")
        end
      end
    rescue ::MediaGallery::FfmpegError => e
      item&.update(status: "failed", error_message: "ffmpeg_error: #{truncate_error(e.message)}")
    rescue StandardError => e
      item&.update(status: "failed", error_message: "processing_error: #{truncate_error(e.message)}")
      raise e
    end

    private

    def create_upload_for_user(user_id, path, _content_type_hint)
      filename = File.basename(path)
      file = File.open(path, "rb")

      upload = ::UploadCreator.new(file, filename).create_for(user_id)
      raise "UploadCreator failed for #{filename}" unless upload&.persisted?

      upload
    ensure
      file&.close
    end

    def finalize_success(item, original, processed_upload, thumb_upload)
      item.update!(
        processed_upload_id: processed_upload.id,
        thumbnail_upload_id: thumb_upload&.id,
        filesize_processed_bytes: processed_upload.filesize,
        status: "ready"
      )

      if SiteSetting.media_gallery_delete_original_on_success
        delete_original_upload(item, original)
      end
    end

    def delete_original_upload(item, upload)
      user = ::User.find_by(id: item.user_id) || Discourse.system_user
      if defined?(::UploadDestroyer)
        ::UploadDestroyer.new(user, upload).destroy
      else
        upload.destroy!
      end

      item.update!(original_upload_id: nil)
    rescue StandardError
      # Best-effort. If deletion fails, keep the reference.
    end

    def truncate_error(msg)
      msg.to_s.gsub(/\s+/, " ")[0, 500]
    end
  end
end
