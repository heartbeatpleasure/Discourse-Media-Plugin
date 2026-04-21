# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "time"

module Jobs
  class MediaGalleryProcessItem < ::Jobs::Base
    # Default queue works out-of-the-box on most Discourse installs.
    # If you really want a dedicated queue, change to: sidekiq_options queue: "media_encoding"
    sidekiq_options queue: "default"

    def execute(args)
      @current_processing_stage = "boot"
      @current_run_token = SecureRandom.hex(16)
      item = MediaGallery::MediaItem.find_by(id: args[:media_item_id])
      return if item.blank?

      with_processing_mutex do
        item.reload
        return if item.blank? || item.ready?
        return unless processable_now?(item, args)

        stale_recovery = item.status == "processing" && processing_stale?(item)
        mark_processing_started!(
          item,
          force_run: ActiveModel::Type::Boolean.new.cast(args[:force_run]),
          run_token: @current_run_token,
          recovered_stale_processing: stale_recovery
        )
        process_item!(item)
      end
    rescue => e
      handle_processing_failure!(item, e)
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

    def processable_now?(item, args)
      force_run = ActiveModel::Type::Boolean.new.cast(args[:force_run])

      if attempt_limit_reached?(item, force_run: force_run)
        mark_attempt_limit_reached!(item)
        return false
      end

      return true if item.status == "queued"
      return true if force_run && item.status == "failed"
      return true if item.status == "processing" && processing_stale?(item)

      false
    end

    def mark_processing_started!(item, force_run: false, run_token: nil, recovered_stale_processing: false)
      @current_processing_stage = "started"
      now = Time.now.utc.iso8601

      meta = processing_meta_for(item)
      meta["attempt_count"] = meta["attempt_count"].to_i + 1
      meta["current_stage"] = @current_processing_stage
      meta["last_started_at"] = now
      meta["last_force_run"] = force_run
      meta["current_run_token"] = run_token if run_token.present?
      meta["current_run_started_at"] = now
      meta["current_run_stale_after_minutes"] = processing_stale_after_minutes
      meta["current_run_recovered_stale_processing"] = recovered_stale_processing
      meta["current_run_job_class"] = self.class.name
      meta.delete("attempt_limit_reached_at")
      meta.delete("last_error_class")
      meta.delete("last_error_message")
      meta.delete("last_error_at")
      meta.delete("last_failed_stage")
      meta.delete("last_backtrace")

      assign_processing_meta!(item, meta)
      item.status = "processing"
      item.error_message = nil
      item.save!
    end

    def mark_processing_succeeded!(item)
      @current_processing_stage = "ready"
      meta = processing_meta_for(item)
      meta["current_stage"] = @current_processing_stage
      meta["last_succeeded_at"] = Time.now.utc.iso8601
      meta["last_finished_at"] = meta["last_succeeded_at"]
      clear_current_run_state!(meta)
      assign_processing_meta!(item, meta)
      item.update!(status: "ready", error_message: nil)
    end

    def handle_processing_failure!(item, error)
      backtrace_lines = Array(error.backtrace).first(40)
      Rails.logger.error(
        <<~LOG
          [media_gallery] processing failed item_id=#{item&.id} public_id=#{item&.public_id} stage=#{@current_processing_stage} error=#{error.class}: #{error.message}
          #{backtrace_lines.join("\n")}
        LOG
      )

      if item&.persisted?
        item.reload
        meta = processing_meta_for(item)
        meta["current_stage"] = "failed"
        meta["last_failed_stage"] = @current_processing_stage.to_s
        meta["last_error_class"] = error.class.to_s
        meta["last_error_message"] = error.message.to_s.truncate(1000)
        meta["last_error_at"] = Time.now.utc.iso8601
        meta["last_finished_at"] = meta["last_error_at"]
        backtrace = Array(error.backtrace).first(8)
        meta["last_backtrace"] = backtrace if backtrace.present?
        clear_current_run_state!(meta)
        assign_processing_meta!(item, meta)

        # Preserve any explicit failure reason set during processing (e.g. duration policy, type mismatch).
        if item.status != "failed" || item.error_message.blank?
          item.status = "failed"
          item.error_message = error.message.to_s.truncate(1000)
          item.save!
        else
          item.save!
        end
      end

      raise error if SiteSetting.respond_to?(:media_gallery_processing_raise_to_sidekiq_retry) && SiteSetting.media_gallery_processing_raise_to_sidekiq_retry
      nil
    end

    def processing_meta_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      value = meta["processing"]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def assign_processing_meta!(item, processing_meta)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta["processing"] = processing_meta
      item.extra_metadata = meta
    end


    def processing_stale?(item)
      meta = processing_meta_for(item)
      started_at = meta["current_run_started_at"].presence || meta["last_started_at"].presence
      return false if started_at.blank?

      started_time = Time.iso8601(started_at)
      started_time < processing_stale_after_minutes.minutes.ago
    rescue ArgumentError, TypeError
      false
    end

    def processing_stale_after_minutes
      if SiteSetting.respond_to?(:media_gallery_processing_stale_after_minutes)
        value = SiteSetting.media_gallery_processing_stale_after_minutes.to_i
        value.positive? ? value : 240
      else
        240
      end
    end

    def processing_max_attempts
      if SiteSetting.respond_to?(:media_gallery_processing_max_attempts)
        value = SiteSetting.media_gallery_processing_max_attempts.to_i
        value.positive? ? value : 5
      else
        5
      end
    end

    def attempt_limit_reached?(item, force_run: false)
      return false if force_run

      processing_meta_for(item)["attempt_count"].to_i >= processing_max_attempts
    end

    def mark_attempt_limit_reached!(item)
      meta = processing_meta_for(item)
      meta["current_stage"] = "failed"
      meta["attempt_limit_reached_at"] = Time.now.utc.iso8601
      meta["attempt_limit"] = processing_max_attempts
      clear_current_run_state!(meta)
      assign_processing_meta!(item, meta)
      item.update!(status: "failed", error_message: "processing_attempt_limit_reached") unless item.status == "failed" && item.error_message == "processing_attempt_limit_reached"
    end

    def clear_current_run_state!(processing_meta)
      processing_meta.delete("current_run_token")
      processing_meta.delete("current_run_started_at")
      processing_meta.delete("current_run_stale_after_minutes")
      processing_meta.delete("current_run_recovered_stale_processing")
      processing_meta.delete("current_run_job_class")
    end

    def process_item!(item)
      raise "missing_original_upload" if item.original_upload.blank?

      @current_processing_stage = "load_original"
      original_upload = item.original_upload
      managed_mode = ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?
      ::MediaGallery::StorageSettingsResolver.validate_active_backend! if managed_mode

      item.filesize_original_bytes ||= original_upload.filesize

      declared_type = item.media_type.presence || infer_media_type_from_upload(original_upload)
      raise "unsupported_file_type" if declared_type.blank?

      # Persist the declared type (based on ext/mime) first.
      # We may refine/correct it later using ffprobe once we have a local temp file.
      item.media_type = declared_type
      item.save!

      ::MediaGallery::ProcessingWorkspace.open do |workspace|
        @current_processing_stage = "source_acquired"
        tmp_input = ::MediaGallery::SourceAcquirer.new.acquire!(upload: original_upload, workspace: workspace)

        processed_tmp = nil
        thumb_tmp = nil

        # Verify/correct the media type using ffprobe. This catches cases where the
        # declared type (based on extension/mime) does not match the actual container.
        media_type = declared_type
        begin
          detected_type = MediaGallery::TypeDetector.infer_from_path(tmp_input)
          if detected_type.present? && detected_type != declared_type
            ext = original_upload.extension.to_s

            if MediaGallery::TypeDetector.extension_allowed_for_type?(ext, detected_type)
              Rails.logger.info(
                "[media_gallery] media type corrected item_id=#{item.id} public_id=#{item.public_id} from=#{declared_type} to=#{detected_type} ext=#{ext}"
              )
              media_type = detected_type
              item.media_type = detected_type
              item.save!
            else
              item.update!(status: "failed", error_message: "file_content_mismatch")
              raise "file_content_mismatch"
            end
          end
        rescue => e
          # If detection fails, fall back to declared type.
          # But if we explicitly flagged mismatch, keep the failure.
          raise e if e.message.to_s == "file_content_mismatch"
        end

        @current_processing_stage = "transcoding"
        case media_type
        when "video"
          processed_tmp, thumb_tmp = process_video_tmp!(item, workspace.root, tmp_input)
        when "audio"
          processed_tmp = process_audio_tmp!(item, workspace.root, tmp_input)
        when "image"
          processed_tmp, thumb_tmp = process_image_tmp!(item, workspace.root, tmp_input, force_jpg: managed_mode)
        else
          raise "unsupported_file_type"
        end

        raise "processed_output_missing" if processed_tmp.blank? || !File.exist?(processed_tmp)

        @current_processing_stage = "store_outputs"
        if managed_mode
          store_managed_outputs!(item, processed_tmp: processed_tmp, thumb_tmp: thumb_tmp)
        else
          store_as_uploads!(item, processed_tmp: processed_tmp, thumb_tmp: thumb_tmp)
        end

        # Optional: package video into HLS (milestone 1). Best-effort.
        if managed_mode &&
             item.media_type.to_s == "video" &&
             SiteSetting.respond_to?(:media_gallery_hls_enabled) &&
             SiteSetting.media_gallery_hls_enabled
          begin
            @current_processing_stage = "package_hls"
            input_for_hls = processed_tmp
            hls_meta = MediaGallery::Hls.package_video!(item, input_path: input_for_hls, workspace: workspace)
            if hls_meta.present?
              hls_role = MediaGallery::Hls.publish_packaged_video!(
                item,
                store: ::MediaGallery::StorageSettingsResolver.build_store,
                hls_meta: hls_meta
              )
              persist_hls_role!(item, hls_role: hls_role)
              meta = (item.extra_metadata || {}).dup
              meta["hls"] = hls_meta
              item.extra_metadata = meta
              item.save!
            end
          rescue => e
            Rails.logger.warn("[media_gallery] HLS post-process failed public_id=#{item.public_id} error=#{e.class}: #{e.message}")
            begin
              meta = (item.extra_metadata || {}).dup
              meta["hls_error"] = {
                "message" => e.message.to_s,
                "class" => e.class.to_s,
                "failed_at" => Time.now.utc.iso8601
              }
              item.update_column(:extra_metadata, meta)
            rescue
            end
          end
        end

        # Export + delete original upload (Option A)
        @current_processing_stage = "finalize_original"
        if SiteSetting.media_gallery_delete_original_on_success
          export_result = maybe_export_original!(item, original_upload, tmp_input)

          # If we intended to retain originals (retention_hours > 0) but export failed,
          # keep the original upload to avoid data loss (fail-open).
          keep_original =
            ::MediaGallery::StorageSettingsResolver.managed_storage_enabled? &&
              MediaGallery::PrivateStorage.original_retention_hours > 0 &&
              export_result == :failed

          unless keep_original
            destroy_upload_safely!(original_upload)
            item.original_upload_id = nil
            item.save!
          end
        end

        mark_processing_succeeded!(item)
      end
    end

    def maybe_export_original!(item, upload, input_path)
      return :skipped unless ::MediaGallery::StorageSettingsResolver.managed_storage_enabled?

      hours = MediaGallery::PrivateStorage.original_retention_hours
      return :skipped if hours <= 0

      # Export original to a private folder so a NAS can rsync-pull it.
      begin
        MediaGallery::PrivateStorage.export_original!(
          item: item,
          source_path: input_path,
          original_filename: upload.original_filename,
          extension: upload.extension
        )
      rescue => e
        Rails.logger.warn(
          "[media_gallery] original export failed item_id=#{item.id} public_id=#{item.public_id} error=#{e.class}: #{e.message}"
        )

        meta = (item.extra_metadata || {}).dup
        meta["original_export_failed_at"] = Time.now.utc.iso8601
        meta["original_export_error"] = "#{e.class}: #{e.message}"[0, 500]
        meta["original_retention_hours"] = hours
        item.extra_metadata = meta
        item.save!
        return :failed
      end

      meta = (item.extra_metadata || {}).dup
      meta["original_exported_at"] = Time.now.utc.iso8601
      meta["original_retention_hours"] = hours
      item.extra_metadata = meta
      item.save!
      :success
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
      max_dur = SiteSetting.media_gallery_audio_max_duration_seconds.to_i

      probe = nil
      duration = 0.0

      begin
        probe = MediaGallery::Ffmpeg.probe(tmp_input)
        duration = probe.dig("format", "duration").to_f
        item.duration_seconds = duration.round if duration.positive?
      rescue
        probe = nil
      end

      if max_dur.positive?
        # Fail-closed when a max duration policy is enabled.
        # If we cannot determine duration reliably, we reject the file.
        if probe.nil? || !duration.positive?
          item.update!(status: "failed", error_message: "duration_probe_failed")
          raise "duration_probe_failed"
        end

        if duration > max_dur
          item.update!(status: "failed", error_message: "duration_exceeds_#{max_dur}_seconds")
          raise "duration_policy_failed"
        end
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

      wm_vf = MediaGallery::Watermark.vf_for(item: item, tmpdir: dir)
      MediaGallery::Ffmpeg.transcode_video(
        input_path: tmp_input,
        output_path: out_path,
        bitrate_kbps: video_kbps,
        max_fps: max_fps,
        audio_bitrate_kbps: audio_kbps,
        extra_vf: wm_vf,
        hls_segment_seconds: (SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled ? MediaGallery::Hls.segment_duration_seconds : nil),
      )

      enforce_max_bytes!(out_path, duration_seconds_f, max_bytes, max_fps, audio_kbps, tmp_input, wm_vf)  # NEW

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
      # Best-effort: capture dimensions early so watermark sizing can clamp safely.
      begin
        probe = MediaGallery::Ffmpeg.probe(tmp_input)
        streams = probe["streams"] || []
        vs = streams.find { |s| s["codec_type"] == "video" } || streams.first
        if vs
          item.width ||= vs["width"] if vs["width"].present?
          item.height ||= vs["height"] if vs["height"].present?
        end
      rescue
        # ignore
      end

      # Watermark (burned into the processed image).
      wm_vf = MediaGallery::Watermark.vf_for(item: item, tmpdir: dir)

      # In private mode we always produce a JPG to keep paths deterministic.
      # Also, if watermarking is enabled for this item we must re-encode (so force JPG).
      transcode_setting = force_jpg || SiteSetting.media_gallery_transcode_images_to_jpg
      transcode = transcode_setting || wm_vf.present?

      if !transcode
        # Keep the original bytes, but still try to generate a JPG thumbnail.
        out_path = File.join(dir, "media-#{item.public_id}#{safe_extension(item.original_upload.original_filename)}")
        FileUtils.cp(tmp_input, out_path)
      else
        out_path = File.join(dir, "media-#{item.public_id}.jpg")
        MediaGallery::Ffmpeg.transcode_image_to_jpg(input_path: tmp_input, output_path: out_path, extra_vf: wm_vf)
      end

      # Thumbnail (best-effort). Keep thumbnails unwatermarked to match the video pipeline.
      thumb_path = File.join(dir, "thumb-#{item.public_id}.jpg")
      begin
        MediaGallery::Ffmpeg.create_jpg_thumbnail(input_path: tmp_input, output_path: thumb_path)
      rescue
        thumb_path = nil
      end
      thumb_path = nil if thumb_path.present? && !File.exist?(thumb_path)

      [out_path, thumb_path]
    end

    # --- Storage backends ---

    def store_managed_outputs!(item, processed_tmp:, thumb_tmp:)
      store = ::MediaGallery::StorageSettingsResolver.build_store
      raise "managed_store_unavailable" if store.blank?
      store.ensure_available!

      main_key = ::MediaGallery::PrivateStorage.processed_rel_path(item)
      thumb_key = ::MediaGallery::PrivateStorage.thumbnail_rel_path(item)
      main_content_type = processed_content_type_for(item)

      main_role = store.put_file!(processed_tmp, key: main_key, content_type: main_content_type)
      thumb_role = nil
      if thumb_tmp.present? && File.exist?(thumb_tmp)
        thumb_role = store.put_file!(thumb_tmp, key: thumb_key, content_type: "image/jpeg")
      end

      item.processed_upload_id = nil
      item.thumbnail_upload_id = nil
      item.managed_storage_backend = store.backend
      item.managed_storage_profile = ::MediaGallery::StorageSettingsResolver.active_profile_key
      item.delivery_mode = delivery_mode_for_backend(store.backend)
      item.storage_schema_version = ::MediaGallery::AssetManifest::SCHEMA_VERSION
      item.filesize_processed_bytes = main_role[:bytes].to_i
      enrich_dimensions_and_duration!(item, processed_tmp)

      manifest = ::MediaGallery::AssetManifest.build(
        item: item,
        main_role: main_role,
        thumbnail_role: thumb_role,
        hls_role: existing_manifest_role(item, "hls")
      )
      item.storage_manifest = manifest

      meta = (item.extra_metadata || {}).dup
      meta["storage"] = store.backend
      meta["processed_rel_path"] = main_key
      if thumb_role.present?
        meta["thumbnail_rel_path"] = thumb_key
      else
        meta.delete("thumbnail_rel_path")
      end
      item.extra_metadata = meta

      item.save!
    end

    def persist_hls_role!(item, hls_role:)
      return if hls_role.blank?

      manifest = item.storage_manifest_hash.deep_dup
      manifest = { "roles" => {} } unless manifest.is_a?(Hash)
      manifest["schema_version"] = ::MediaGallery::AssetManifest::SCHEMA_VERSION
      manifest["public_id"] = item.public_id.to_s
      manifest["generated_at"] = Time.now.utc.iso8601
      manifest["roles"] ||= {}
      manifest["roles"]["hls"] = hls_role.deep_stringify_keys
      item.storage_manifest = manifest
      item.save!
    end

    def existing_manifest_role(item, role_name)
      ::MediaGallery::AssetManifest.role_for(item, role_name)
    end

    def processed_content_type_for(item)
      case item.media_type.to_s
      when "video" then "video/mp4"
      when "audio" then "audio/mpeg"
      when "image" then "image/jpeg"
      else "application/octet-stream"
      end
    end

    def delivery_mode_for_backend(backend)
      if backend.to_s == "s3"
        "s3_redirect"
      else
        mode = ::MediaGallery::StorageSettingsResolver.default_delivery_mode
        mode == "x_accel" ? "x_accel" : "local_stream"
      end
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

      item.managed_storage_backend = nil
      item.managed_storage_profile = nil
      item.delivery_mode = nil
      item.storage_manifest = {}
      item.storage_schema_version = ::MediaGallery::AssetManifest::SCHEMA_VERSION

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

    def normalized_upload_extension(upload)
      ext = upload&.extension.to_s.downcase.sub(/\A\./, "")
      return ext if ext.present?

      filename = upload&.original_filename.to_s
      fallback = File.extname(filename).to_s.downcase.sub(/\A\./, "")
      fallback.presence.to_s
    end

    def infer_media_type_from_upload(upload)
      ext = normalized_upload_extension(upload)
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

        # Scale the *target* bitrate down for smaller outputs so we avoid wasting bits on
        # low-resolution sources. We never scale above the configured target.
        #
        # Note: our transcode policy outputs at most Full HD in either orientation:
        #   - landscape/square: <=1920x1080
        #   - portrait:         <=1080x1920
        #
        # Both 1920x1080 and 1080x1920 have the same pixel count, so portrait is not
        # penalized compared to landscape.
        if width.present? && height.present?
          out_w, out_h = expected_video_output_dims(width.to_i, height.to_i)
          if out_w > 0 && out_h > 0
            baseline_px = 1920.0 * 1080.0
            ratio = ((out_w * out_h).to_f / baseline_px)
            scaled = (configured_video.to_f * ratio).round
            # Keep a sane floor so tiny videos don't become unreadable.
            scaled = 800 if scaled < 800
            scaled = configured_video if scaled > configured_video
            configured_video = scaled
          end
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


    def expected_video_output_dims(in_w, in_h)
      w = in_w.to_i
      h = in_h.to_i
      return [0, 0] if w <= 0 || h <= 0

      # Mirror MediaGallery::Ffmpeg.transcode_video scaling policy
      # (no upscale, preserve aspect):
      #  - landscape/square: fit within 1920x1080
      #  - portrait:         fit within 1080x1920
      if h > w
        max_w = 1080.0
        max_h = 1920.0
      else
        max_w = 1920.0
        max_h = 1080.0
      end

      scale = [max_w / w.to_f, max_h / h.to_f, 1.0].min
      out_w = (w.to_f * scale).floor
      out_h = (h.to_f * scale).floor

      # Video output enforces even dimensions for yuv420p/x264.
      out_w = (out_w / 2) * 2
      out_h = (out_h / 2) * 2

      out_w = 2 if out_w < 2
      out_h = 2 if out_h < 2
      [out_w, out_h]
    end

    def enforce_max_bytes!(out_path, duration_seconds, max_bytes, max_fps, audio_kbps, tmp_input, extra_vf = nil)
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
        extra_vf: extra_vf,
        hls_segment_seconds: (SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled ? MediaGallery::Hls.segment_duration_seconds : nil),
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

      upload = begin
        ::UploadCreator.new(file, filename, upload_type: "composer").create_for(user_id)
      rescue ArgumentError
        # Older Discourse versions used the "type" keyword.
        ::UploadCreator.new(file, filename, type: "composer").create_for(user_id)
      end

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
