# frozen_string_literal: true

require "digest/sha1"
require "fileutils"
require "json"
require "find"
require "securerandom"
require "set"
require "time"

module ::MediaGallery
  module ChunkedUploads
    module_function

    Error = Class.new(StandardError) do
      attr_reader :code, :status, :details

      def initialize(code, message = nil, status: 422, details: nil)
        @code = code.to_s
        @status = status.to_i
        @details = details
        super(message.presence || @code)
      end
    end

    META_FILENAME = "metadata.json"
    LOCK_FILENAME = "complete.lock"
    GLOBAL_LOCK_FILENAME = ".global.lock"
    PARTS_DIRNAME = "parts"
    FINAL_DIRNAME = "final"
    SESSION_ID_RE = /\A[a-f0-9]{32}\z/.freeze
    MIN_CHUNK_SIZE_MB = 1
    MAX_CHUNK_SIZE_MB = 95
    MIN_THRESHOLD_MB = 1
    MAX_ACTIVE_SESSIONS_FALLBACK = 3
    MAX_ACTIVE_SESSIONS_GLOBAL_FALLBACK = 20
    MAX_TEMP_STORAGE_MB_FALLBACK = 4096
    STORE_NAMESPACE = "media_gallery_chunked_uploads"
    LAST_CLEANUP_KEY = "last_cleanup"

    def enabled?
      SiteSetting.respond_to?(:media_gallery_chunked_uploads_enabled) &&
        SiteSetting.media_gallery_chunked_uploads_enabled
    rescue
      false
    end

    def policy_payload
      {
        enabled: enabled?,
        threshold_mb: threshold_mb,
        threshold_bytes: threshold_bytes,
        chunk_size_mb: chunk_size_mb,
        chunk_size_bytes: chunk_size_bytes,
        session_ttl_minutes: session_ttl_minutes,
        max_active_sessions_per_user: max_active_sessions_per_user,
        max_active_sessions_global: max_active_sessions_global,
        max_temp_storage_mb: max_temp_storage_mb,
        max_temp_storage_bytes: max_temp_storage_bytes
      }
    end

    def start!(user:, filename:, filesize:, content_type: nil)
      raise_error("chunked_uploads_disabled", "Chunked uploads are not enabled.", status: 404) unless enabled?
      raise_error("not_logged_in", "You must be logged in to upload.", status: 403) if user.blank?

      safe_filename = sanitized_filename(filename)
      size = filesize.to_i
      raise_error("invalid_file", "The selected file is invalid.") if safe_filename.blank? || size <= 0

      inferred_type = infer_media_type(filename: safe_filename, content_type: content_type)
      validate_extension!(safe_filename, inferred_type)
      validate_size!(filesize: size, media_type: inferred_type)

      root = root_path
      FileUtils.mkdir_p(root)

      with_global_lock do
        cleanup_expired!(source: "start_guard")
        enforce_global_active_session_limit!
        enforce_active_session_limit!(user)
        enforce_temp_storage_limit!(
          additional_bytes: reserved_bytes_for_filesize(size),
          code: "chunked_upload_temp_storage_limit_reached",
          message: "The server is temporarily low on upload workspace. Please try again later."
        )

        session_id = SecureRandom.hex(16)
        FileUtils.mkdir_p(parts_path(session_id))
        FileUtils.mkdir_p(final_path(session_id))

        now = Time.now.utc
        meta = {
          "session_id" => session_id,
          "user_id" => user.id.to_i,
          "filename" => safe_filename,
          "filesize" => size,
          "content_type" => content_type.to_s.presence,
          "media_type" => inferred_type,
          "chunk_size_bytes" => chunk_size_bytes,
          "total_parts" => [(size.to_f / chunk_size_bytes.to_f).ceil, 1].max,
          "created_at" => now.iso8601,
          "updated_at" => now.iso8601,
          "expires_at" => (now + session_ttl_seconds).iso8601,
          "completed" => false
        }

        write_meta!(session_id, meta)
        Rails.logger.info("[media_gallery] chunked upload started session_id=#{session_id} user_id=#{user.id} bytes=#{size} parts=#{meta["total_parts"]}")
        record_log_event(
          event_type: "media_gallery_chunked_upload_started",
          severity: "info",
          user: user,
          message: "Chunked upload session started.",
          details: {
            session_id: session_id,
            bytes: size,
            parts: meta["total_parts"],
            media_type: inferred_type,
            chunk_size_mb: chunk_size_mb,
            threshold_mb: threshold_mb
          }
        )
        meta.merge("uploaded_parts" => [], "uploaded_parts_count" => 0)
      end
    rescue Error
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload start failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
      raise_error("chunked_upload_start_failed", "Chunked upload could not be started.", status: 500)
    end

    def write_part!(session_id:, user:, part_number:, upload:)
      raise_error("chunked_uploads_disabled", "Chunked uploads are not enabled.", status: 404) unless enabled?

      sid = normalize_session_id!(session_id)
      meta = read_meta!(sid)
      ensure_owned_and_open!(meta, user)

      part_no = part_number.to_i
      total_parts = meta["total_parts"].to_i
      raise_error("invalid_part_number", "Invalid upload chunk number.") if part_no <= 0 || part_no > total_parts

      io, original_size = uploaded_io_and_size(upload)
      raise_error("missing_chunk", "Upload chunk is missing.") if io.blank?

      max_size = meta["chunk_size_bytes"].to_i
      size = original_size.to_i
      raise_error("empty_chunk", "Upload chunk is empty.") if size <= 0
      raise_error("chunk_too_large", "Upload chunk is too large.", details: { max_chunk_bytes: max_size }) if size > max_size

      expected_last_size = meta["filesize"].to_i - (max_size * (total_parts - 1))
      if part_no == total_parts && expected_last_size.positive? && size > expected_last_size
        raise_error("chunk_too_large", "Upload chunk is larger than expected.", details: { expected_bytes: expected_last_size })
      end

      enforce_temp_storage_limit!(
        code: "chunked_upload_temp_storage_limit_reached",
        message: "The server is temporarily low on upload workspace. Please try again later."
      )

      part_path = part_file_path(sid, part_no)
      tmp_path = "#{part_path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"

      File.open(tmp_path, "wb") do |out|
        copy_io(io, out)
      end

      written = File.size?(tmp_path).to_i
      if written != size
        FileUtils.rm_f(tmp_path)
        raise_error("chunk_size_mismatch", "Upload chunk size did not match the request.", details: { expected_bytes: size, actual_bytes: written })
      end

      FileUtils.mv(tmp_path, part_path)
      refresh_session!(sid, meta)

      uploaded_parts = uploaded_part_numbers(sid, total_parts)
      {
        session_id: sid,
        part_number: part_no,
        uploaded_parts_count: uploaded_parts.length,
        total_parts: total_parts,
        complete: uploaded_parts.length == total_parts
      }
    rescue Error
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload part failed session_id=#{session_id} user_id=#{user&.id} error=#{e.class}: #{e.message}")
      raise_error("chunk_upload_failed", "Upload chunk could not be saved.", status: 500)
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path.present? && File.exist?(tmp_path)
    end

    def complete!(session_id:, user:)
      raise_error("chunked_uploads_disabled", "Chunked uploads are not enabled.", status: 404) unless enabled?

      sid = normalize_session_id!(session_id)

      with_session_lock(sid) do
        meta = read_meta!(sid)
        ensure_owned_and_open!(meta, user)

        total_parts = meta["total_parts"].to_i
        missing = missing_part_numbers(sid, total_parts)
        if missing.any?
          raise_error("missing_upload_chunks", "Upload is incomplete. Please try again.", details: { missing_parts: missing.first(20), missing_count: missing.length })
        end

        enforce_temp_storage_limit!(
          code: "chunked_upload_temp_storage_limit_reached",
          message: "The server is temporarily low on upload workspace. Please try again later."
        )

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        final_file = assemble_final_file!(sid, meta)
        actual_size = File.size?(final_file).to_i
        expected_size = meta["filesize"].to_i
        if actual_size != expected_size
          raise_error("assembled_file_size_mismatch", "The uploaded file was incomplete. Please try again.", details: { expected_bytes: expected_size, actual_bytes: actual_size })
        end

        upload = create_discourse_upload!(user_id: user.id, path: final_file, filename: meta["filename"].to_s)

        meta["completed"] = true
        meta["completed_at"] = Time.now.utc.iso8601
        meta["upload_id"] = upload.id
        write_meta!(sid, meta)

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round
        Rails.logger.info("[media_gallery] chunked upload completed session_id=#{sid} user_id=#{user.id} upload_id=#{upload.id} bytes=#{actual_size} parts=#{total_parts} elapsed_ms=#{elapsed_ms}")
        record_log_event(
          event_type: "media_gallery_chunked_upload_completed",
          severity: "success",
          user: user,
          message: "Chunked upload completed and was stored as a Discourse upload.",
          details: {
            session_id: sid,
            upload_id: upload.id,
            bytes: actual_size,
            parts: total_parts,
            elapsed_ms: elapsed_ms
          }
        )

        begin
          cleanup_session!(sid)
        rescue => cleanup_error
          Rails.logger.warn("[media_gallery] chunked upload completed but cleanup failed session_id=#{sid} user_id=#{user&.id} error=#{cleanup_error.class}: #{cleanup_error.message}")
          record_log_event(
            event_type: "media_gallery_chunked_upload_cleanup_failed",
            severity: "warning",
            user: user,
            message: "Chunked upload completed but temporary cleanup failed.",
            details: { session_id: sid, upload_id: upload.id, error: "#{cleanup_error.class}: #{cleanup_error.message}".truncate(300) }
          )
        end

        upload
      end
    rescue Error
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload complete failed session_id=#{session_id} user_id=#{user&.id} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
      record_log_event(
        event_type: "media_gallery_chunked_upload_complete_failed",
        severity: "danger",
        user: user,
        message: "Chunked upload finalization failed.",
        details: { session_id: session_id.to_s, error: "#{e.class}: #{e.message}".truncate(300) }
      )
      raise_error("chunked_upload_complete_failed", "Upload could not be completed. Please try again.", status: 500)
    end

    def status!(session_id:, user:)
      sid = normalize_session_id!(session_id)
      meta = read_meta!(sid)
      ensure_owned!(meta, user)

      total_parts = meta["total_parts"].to_i
      uploaded_parts = uploaded_part_numbers(sid, total_parts)
      meta.merge(
        "uploaded_parts" => uploaded_parts,
        "uploaded_parts_count" => uploaded_parts.length,
        "missing_parts_count" => [total_parts - uploaded_parts.length, 0].max
      )
    end

    def abort!(session_id:, user:)
      sid = normalize_session_id!(session_id)
      meta = read_meta!(sid)
      ensure_owned!(meta, user)
      result = cleanup_session!(sid)
      if result.is_a?(Hash)
        Rails.logger.info("[media_gallery] chunked upload aborted session_id=#{sid} user_id=#{user.id} bytes_removed=#{result[:bytes].to_i}")
        record_log_event(
          event_type: "media_gallery_chunked_upload_aborted",
          severity: "info",
          user: user,
          message: "Chunked upload session was aborted.",
          details: { session_id: sid, bytes_removed: result[:bytes].to_i }
        )
      end
      true
    rescue Error
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload abort failed session_id=#{session_id} user_id=#{user&.id} error=#{e.class}: #{e.message}")
      record_log_event(
        event_type: "media_gallery_chunked_upload_abort_failed",
        severity: "warning",
        user: user,
        message: "Chunked upload abort failed.",
        details: { session_id: session_id.to_s, error: "#{e.class}: #{e.message}".truncate(300) }
      )
      false
    end

    def cleanup_expired!(source: "manual")
      root = root_path
      unless Dir.exist?(root)
        result = cleanup_result_payload(scanned: 0, removed: 0, bytes_removed: 0, source: source)
        store_last_cleanup!(result)
        return result
      end

      now = Time.now.utc
      scanned = 0
      removed = 0
      bytes_removed = 0
      skipped = 0
      skipped_errors = []

      Dir.children(root).each do |name|
        next unless name.match?(SESSION_ID_RE)
        scanned += 1

        sid = name.to_s
        meta = read_meta(sid)
        session_dir = session_path(sid)
        expired = session_expired_for_cleanup?(meta, session_dir, now)

        next unless expired

        cleanup_result = cleanup_session!(sid)
        removed += 1
        bytes_removed += cleanup_result[:bytes].to_i if cleanup_result.is_a?(Hash)
      rescue => e
        skipped += 1
        skipped_errors << { session_id: name.to_s, error: "#{e.class}: #{e.message}".truncate(300) } if skipped_errors.length < 10
        Rails.logger.warn("[media_gallery] chunked upload cleanup skipped #{name}: #{e.class}: #{e.message}")
      end

      result = cleanup_result_payload(
        scanned: scanned,
        removed: removed,
        bytes_removed: bytes_removed,
        skipped: skipped,
        skipped_errors: skipped_errors,
        source: source
      )
      store_last_cleanup!(result)
      record_log_event(
        event_type: "media_gallery_chunked_upload_cleanup",
        severity: skipped.positive? ? "warning" : "info",
        message: removed.positive? ? "Expired chunked upload sessions cleaned up." : "Chunked upload cleanup completed.",
        details: result
      ) if removed.positive? || skipped.positive?
      result
    rescue => e
      result = cleanup_result_payload(scanned: 0, removed: 0, bytes_removed: 0, skipped: 1, skipped_errors: [{ error: "#{e.class}: #{e.message}".truncate(300) }], source: source)
      store_last_cleanup!(result)
      raise
    end

    def workspace_summary
      root = root_path
      exists = Dir.exist?(root)
      sessions = []
      scan_errors = []
      now = Time.now.utc

      if exists
        Dir.children(root).each do |name|
          next unless name.match?(SESSION_ID_RE)

          sessions << session_summary_row(name.to_s, now)
        rescue => e
          scan_errors << { session_id: name.to_s, error: "#{e.class}: #{e.message}".truncate(300) } if scan_errors.length < 10
        end
      end

      active = sessions.select { |row| row[:active] }
      expired = sessions.select { |row| row[:expired] }
      completed = sessions.select { |row| row[:completed] }
      actual_bytes = sessions.sum { |row| row[:bytes].to_i }
      projected_bytes = projected_temp_storage_bytes
      max_bytes = max_temp_storage_bytes
      usage_percent = max_bytes.positive? ? ((projected_bytes.to_f / max_bytes.to_f) * 100.0).round(1) : nil
      oldest_active = active.filter_map { |row| row[:created_at] }.min

      {
        enabled: enabled?,
        root_path: root,
        root_exists: exists,
        root_writable: workspace_root_writable?(root),
        total_sessions: sessions.length,
        active_sessions: active.length,
        expired_sessions: expired.length,
        completed_sessions: completed.length,
        actual_temp_storage_bytes: actual_bytes,
        projected_temp_storage_bytes: projected_bytes,
        max_temp_storage_mb: max_temp_storage_mb,
        max_temp_storage_bytes: max_bytes,
        temp_storage_usage_percent: usage_percent,
        chunk_size_mb: chunk_size_mb,
        threshold_mb: threshold_mb,
        session_ttl_minutes: session_ttl_minutes,
        max_active_sessions_per_user: max_active_sessions_per_user,
        max_active_sessions_global: max_active_sessions_global,
        oldest_active_session_created_at: oldest_active&.iso8601,
        oldest_active_session_age_seconds: oldest_active.present? ? [now - oldest_active, 0].max.to_i : nil,
        examples: sessions.sort_by { |row| [row[:active] ? 0 : 1, row[:expired] ? 0 : 1, row[:updated_at] || Time.at(0)] }.first(10),
        scan_errors: scan_errors,
        last_cleanup: last_cleanup_summary
      }
    rescue => e
      {
        enabled: enabled?,
        root_path: (root rescue nil),
        root_exists: false,
        root_writable: false,
        total_sessions: 0,
        active_sessions: 0,
        expired_sessions: 0,
        completed_sessions: 0,
        actual_temp_storage_bytes: 0,
        projected_temp_storage_bytes: 0,
        max_temp_storage_mb: max_temp_storage_mb,
        max_temp_storage_bytes: max_temp_storage_bytes,
        temp_storage_usage_percent: nil,
        chunk_size_mb: chunk_size_mb,
        threshold_mb: threshold_mb,
        session_ttl_minutes: session_ttl_minutes,
        max_active_sessions_per_user: max_active_sessions_per_user,
        max_active_sessions_global: max_active_sessions_global,
        examples: [],
        scan_errors: [{ error: "#{e.class}: #{e.message}".truncate(300) }],
        last_cleanup: last_cleanup_summary
      }
    end

    def last_cleanup_summary
      value = ::PluginStore.get(STORE_NAMESPACE, LAST_CLEANUP_KEY)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    rescue
      {}
    end

    def cleanup_result_payload(scanned:, removed:, bytes_removed:, source:, skipped: 0, skipped_errors: [])
      now = Time.now.utc
      {
        source: source.to_s.presence || "manual",
        scanned: scanned.to_i,
        removed: removed.to_i,
        skipped: skipped.to_i,
        bytes_removed: bytes_removed.to_i,
        skipped_errors: Array(skipped_errors).first(10),
        ran_at: now.iso8601,
        ran_at_label: now.strftime("%Y-%m-%d %H:%M:%S")
      }
    end

    def store_last_cleanup!(result)
      ::PluginStore.set(STORE_NAMESPACE, LAST_CLEANUP_KEY, result.deep_stringify_keys)
      true
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload cleanup state store failed: #{e.class}: #{e.message}")
      false
    end

    def session_expired_for_cleanup?(meta, session_dir, now)
      if meta.present?
        expires_at = parse_time(meta["expires_at"])
        expires_at.blank? || expires_at <= now || meta["completed"] == true
      else
        begin
          File.mtime(session_dir) < (now - session_ttl_seconds)
        rescue
          true
        end
      end
    end

    def session_summary_row(session_id, now = Time.now.utc)
      sid = normalize_session_id!(session_id)
      session_dir = session_path(sid)
      meta = read_meta(sid)
      total_parts = meta.present? ? meta["total_parts"].to_i : 0
      uploaded_parts = total_parts.positive? ? uploaded_part_numbers(sid, total_parts) : []
      created_at = parse_time(meta && meta["created_at"]) || safe_mtime(session_dir)
      updated_at = parse_time(meta && meta["updated_at"]) || safe_mtime(session_dir)
      expires_at = parse_time(meta && meta["expires_at"])
      active = active_session_meta?(meta, now)
      expired = session_expired_for_cleanup?(meta, session_dir, now)
      bytes = directory_size(session_dir)
      filename = meta && meta["filename"].to_s.presence

      {
        session_id: sid,
        label: filename || sid,
        status: active ? "active" : (expired ? "expired" : "inactive"),
        user_id: meta && meta["user_id"].to_i,
        filename: filename,
        media_type: meta && meta["media_type"].to_s.presence,
        filesize: meta && meta["filesize"].to_i,
        total_parts: total_parts,
        uploaded_parts_count: uploaded_parts.length,
        bytes: bytes,
        active: active,
        expired: expired,
        completed: meta && meta["completed"] == true,
        created_at: created_at,
        updated_at: updated_at,
        expires_at: expires_at,
        age_seconds: created_at.present? ? [now - created_at, 0].max.to_i : nil,
        detail: chunked_session_detail(sid, meta, uploaded_parts.length, total_parts, bytes, expires_at)
      }.compact
    end

    def chunked_session_detail(session_id, meta, uploaded_count, total_parts, bytes, expires_at)
      parts = total_parts.to_i.positive? ? "#{uploaded_count}/#{total_parts} parts" : "metadata missing"
      user = meta.present? ? "user_id=#{meta["user_id"].to_i}" : "metadata missing"
      expiry = expires_at.present? ? "expires_at=#{expires_at.iso8601}" : "expires_at missing"
      "session_id=#{session_id}; #{user}; #{parts}; bytes=#{bytes.to_i}; #{expiry}"
    rescue
      "session_id=#{session_id}"
    end

    def safe_mtime(path)
      return nil unless path.present? && File.exist?(path)

      File.mtime(path).utc
    rescue
      nil
    end

    def workspace_root_writable?(path)
      target = path.to_s
      dir = Dir.exist?(target) ? target : nearest_existing_parent(target)
      dir.present? && File.directory?(dir) && File.writable?(dir)
    rescue
      false
    end

    def nearest_existing_parent(path)
      current = path.to_s
      loop do
        parent = File.dirname(current)
        return current if Dir.exist?(current)
        return nil if parent.blank? || parent == current

        current = parent
      end
    rescue
      nil
    end

    def threshold_mb
      value = if SiteSetting.respond_to?(:media_gallery_chunked_upload_threshold_mb)
        SiteSetting.media_gallery_chunked_upload_threshold_mb.to_i
      else
        80
      end
      [[value, MIN_THRESHOLD_MB].max, 10_240].min
    rescue
      80
    end

    def threshold_bytes
      threshold_mb * 1024 * 1024
    end

    def chunk_size_mb
      value = if SiteSetting.respond_to?(:media_gallery_chunk_size_mb)
        SiteSetting.media_gallery_chunk_size_mb.to_i
      else
        25
      end
      [[value, MIN_CHUNK_SIZE_MB].max, MAX_CHUNK_SIZE_MB].min
    rescue
      25
    end

    def chunk_size_bytes
      chunk_size_mb * 1024 * 1024
    end

    def session_ttl_minutes
      value = if SiteSetting.respond_to?(:media_gallery_chunked_upload_session_ttl_minutes)
        SiteSetting.media_gallery_chunked_upload_session_ttl_minutes.to_i
      else
        120
      end
      [[value, 10].max, 1440].min
    rescue
      120
    end

    def session_ttl_seconds
      session_ttl_minutes * 60
    end

    def max_active_sessions_per_user
      value = if SiteSetting.respond_to?(:media_gallery_chunked_upload_max_active_sessions_per_user)
        SiteSetting.media_gallery_chunked_upload_max_active_sessions_per_user.to_i
      else
        MAX_ACTIVE_SESSIONS_FALLBACK
      end
      [[value, 1].max, 20].min
    rescue
      MAX_ACTIVE_SESSIONS_FALLBACK
    end

    def max_active_sessions_global
      value = if SiteSetting.respond_to?(:media_gallery_chunked_upload_max_active_sessions_global)
        SiteSetting.media_gallery_chunked_upload_max_active_sessions_global.to_i
      else
        MAX_ACTIVE_SESSIONS_GLOBAL_FALLBACK
      end
      [[value, 0].max, 200].min
    rescue
      MAX_ACTIVE_SESSIONS_GLOBAL_FALLBACK
    end

    def max_temp_storage_mb
      value = if SiteSetting.respond_to?(:media_gallery_chunked_upload_max_temp_storage_mb)
        SiteSetting.media_gallery_chunked_upload_max_temp_storage_mb.to_i
      else
        MAX_TEMP_STORAGE_MB_FALLBACK
      end
      [[value, 0].max, 102_400].min
    rescue
      MAX_TEMP_STORAGE_MB_FALLBACK
    end

    def max_temp_storage_bytes
      mb = max_temp_storage_mb
      return 0 unless mb.positive?

      mb * 1024 * 1024
    end

    def root_path
      base = if SiteSetting.respond_to?(:media_gallery_processing_root_path)
        SiteSetting.media_gallery_processing_root_path.to_s.presence
      end
      base ||= "/shared/media_gallery/tmp"

      ::MediaGallery::PathSecurity.safe_join!(base, "chunked_uploads", allow_root: true)
    end

    def session_path(session_id)
      ::MediaGallery::PathSecurity.safe_join!(root_path, normalize_session_id!(session_id), allow_root: true)
    end

    def parts_path(session_id)
      ::MediaGallery::PathSecurity.safe_join!(session_path(session_id), PARTS_DIRNAME, allow_root: true)
    end

    def final_path(session_id)
      ::MediaGallery::PathSecurity.safe_join!(session_path(session_id), FINAL_DIRNAME, allow_root: true)
    end

    def meta_path(session_id)
      ::MediaGallery::PathSecurity.safe_join!(session_path(session_id), META_FILENAME)
    end

    def lock_path(session_id)
      ::MediaGallery::PathSecurity.safe_join!(session_path(session_id), LOCK_FILENAME)
    end

    def global_lock_path
      ::MediaGallery::PathSecurity.safe_join!(root_path, GLOBAL_LOCK_FILENAME)
    end

    def part_file_path(session_id, part_number)
      part = format("%06d.part", part_number.to_i)
      ::MediaGallery::PathSecurity.safe_join!(parts_path(session_id), part)
    end

    def normalize_session_id!(session_id)
      sid = session_id.to_s.strip.downcase
      raise_error("invalid_upload_session", "Invalid upload session.") unless sid.match?(SESSION_ID_RE)
      sid
    end

    def read_meta!(session_id)
      meta = read_meta(session_id)
      raise_error("upload_session_not_found", "Upload session was not found or expired.", status: 404) if meta.blank?
      meta
    end

    def read_meta(session_id)
      sid = normalize_session_id!(session_id)
      path = meta_path(sid)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue Error
      raise
    rescue
      nil
    end

    def write_meta!(session_id, meta)
      sid = normalize_session_id!(session_id)
      path = meta_path(sid)
      tmp_path = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(tmp_path, JSON.pretty_generate(meta))
      FileUtils.mv(tmp_path, path)
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path.present? && File.exist?(tmp_path)
    end

    def ensure_owned!(meta, user)
      raise_error("not_logged_in", "You must be logged in to upload.", status: 403) if user.blank?
      unless meta["user_id"].to_i == user.id.to_i
        raise_error("upload_session_not_found", "Upload session was not found or expired.", status: 404)
      end
    end

    def ensure_owned_and_open!(meta, user)
      ensure_owned!(meta, user)
      if meta["completed"] == true
        raise_error("upload_session_completed", "Upload session is already completed.")
      end

      expires_at = parse_time(meta["expires_at"])
      if expires_at.blank? || expires_at <= Time.now.utc
        cleanup_session!(meta["session_id"])
        raise_error("upload_session_expired", "Upload session expired. Please start the upload again.", status: 410)
      end
    end

    def refresh_session!(session_id, meta)
      meta = meta.dup
      now = Time.now.utc
      meta["updated_at"] = now.iso8601
      meta["expires_at"] = (now + session_ttl_seconds).iso8601
      write_meta!(session_id, meta)
    end

    def enforce_active_session_limit!(user)
      max = max_active_sessions_per_user
      return if max <= 0

      active = active_session_metas.count { |(_, meta)| meta["user_id"].to_i == user.id.to_i }
      return if active < max

      raise_error(
        "too_many_active_upload_sessions",
        "Too many uploads are already active for your account. Please wait or cancel another upload first.",
        status: 429,
        details: { max_active_sessions_per_user: max }
      )
    end

    def enforce_global_active_session_limit!
      max = max_active_sessions_global
      return if max <= 0

      active = active_session_metas.length
      return if active < max

      raise_error(
        "too_many_global_upload_sessions",
        "Too many large uploads are already active. Please wait and try again.",
        status: 429,
        details: { max_active_sessions_global: max, active_sessions: active }
      )
    end

    def enforce_temp_storage_limit!(additional_bytes: 0, exclude_session_id: nil, code: "chunked_upload_temp_storage_limit_reached", message: nil)
      max_bytes = max_temp_storage_bytes
      return if max_bytes <= 0

      projected = projected_temp_storage_bytes(exclude_session_id: exclude_session_id) + additional_bytes.to_i
      return if projected <= max_bytes

      raise_error(
        code,
        message.presence || "The server is temporarily low on upload workspace. Please try again later.",
        status: 507,
        details: {
          max_temp_storage_mb: max_temp_storage_mb,
          max_temp_storage_bytes: max_bytes,
          projected_temp_storage_bytes: projected,
          additional_bytes: additional_bytes.to_i
        }
      )
    end

    def active_session_metas
      now = Time.now.utc
      metas = []
      each_session_meta do |sid, meta|
        next unless active_session_meta?(meta, now)

        metas << [sid, meta]
      end
      metas
    end

    def active_session_meta?(meta, now = Time.now.utc)
      return false unless meta.present?
      return false if meta["completed"] == true

      expires_at = parse_time(meta["expires_at"])
      expires_at.present? && expires_at > now
    end

    def each_session_meta
      return enum_for(:each_session_meta) unless block_given?

      root = root_path
      return unless Dir.exist?(root)

      Dir.children(root).each do |name|
        next unless name.match?(SESSION_ID_RE)

        meta = read_meta(name)
        yield name.to_s, meta if meta.present?
      rescue
        next
      end
    end

    def projected_temp_storage_bytes(exclude_session_id: nil)
      excluded = exclude_session_id.present? ? normalize_session_id!(exclude_session_id) : nil
      now = Time.now.utc
      total = 0
      root = root_path
      return 0 unless Dir.exist?(root)

      Dir.children(root).each do |name|
        next unless name.match?(SESSION_ID_RE)
        sid = name.to_s
        next if excluded.present? && sid == excluded

        dir = session_path(sid)
        actual = directory_size(dir)
        meta = read_meta(sid)

        if active_session_meta?(meta, now)
          reserved = reserved_bytes_for_filesize(meta["filesize"].to_i)
          total += [actual, reserved].max
        else
          total += actual
        end
      rescue
        next
      end

      total
    end

    def reserved_bytes_for_filesize(filesize)
      # During finalization the chunk files and assembled final file can briefly coexist.
      [filesize.to_i * 2, 0].max
    end

    def uploaded_part_numbers(session_id, total_parts)
      parts_dir = parts_path(session_id)
      return [] unless Dir.exist?(parts_dir)

      (1..total_parts.to_i).select { |n| File.file?(part_file_path(session_id, n)) }
    end

    def missing_part_numbers(session_id, total_parts)
      uploaded = uploaded_part_numbers(session_id, total_parts).to_set
      (1..total_parts.to_i).reject { |n| uploaded.include?(n) }
    end

    def assemble_final_file!(session_id, meta)
      sid = normalize_session_id!(session_id)
      safe_filename = sanitized_filename(meta["filename"])
      final_dir = final_path(sid)
      FileUtils.mkdir_p(final_dir)

      final_file = ::MediaGallery::PathSecurity.safe_join!(final_dir, safe_filename)
      tmp_path = "#{final_file}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
      total_parts = meta["total_parts"].to_i

      File.open(tmp_path, "wb") do |out|
        (1..total_parts).each do |part_no|
          part_path = part_file_path(sid, part_no)
          File.open(part_path, "rb") { |input| IO.copy_stream(input, out) }
        end
      end

      FileUtils.mv(tmp_path, final_file)
      final_file
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path.present? && File.exist?(tmp_path)
    end

    def create_discourse_upload!(user_id:, path:, filename:)
      size = File.size?(path).to_i
      raise_error("assembled_file_missing", "Upload file was missing after assembly.", status: 500) if size <= 0

      file = File.open(path, "rb")
      upload = begin
        ::UploadCreator.new(file, filename, upload_type: "composer").create_for(user_id)
      rescue ArgumentError
        file.close rescue nil
        file = File.open(path, "rb")
        ::UploadCreator.new(file, filename, type: "composer").create_for(user_id)
      end

      unless upload&.persisted?
        errors = upload&.errors&.full_messages || []
        message = errors.present? ? errors.join(", ") : "Upload could not be saved."
        raise_error("discourse_upload_failed", message, details: { errors: errors })
      end

      upload
    ensure
      file&.close
    end

    def uploaded_io_and_size(upload)
      if upload.respond_to?(:tempfile) && upload.tempfile.present?
        return [upload.tempfile, upload.size.to_i]
      end

      if upload.respond_to?(:read)
        size = upload.respond_to?(:size) ? upload.size.to_i : 0
        return [upload, size]
      end

      [nil, 0]
    end

    def copy_io(input, output)
      input.rewind if input.respond_to?(:rewind)
      IO.copy_stream(input, output)
    end

    def sanitized_filename(filename)
      raw = filename.to_s.delete("\u0000").tr("\\", "/").split("/").last.to_s.strip
      raw = "upload.bin" if raw.blank?
      raw = raw.gsub(/[\r\n\t]/, " ").squeeze(" ").strip
      raw = raw.gsub(/[^A-Za-z0-9._()\- +]/, "_")
      raw = raw.gsub(/\A[. ]+/, "")
      raw = "upload.bin" if raw.blank?

      ext = File.extname(raw)
      if ext.present? && ext.length <= 16 && raw.length > 180
        base = File.basename(raw, ext)
        raw = "#{base[0, 180 - ext.length]}#{ext}"
      elsif raw.length > 180
        raw = raw[0, 180]
      end

      ext = File.extname(raw)
      if ext.blank?
        raw = "#{raw}.bin"
      elsif ext.length > 16
        raw = "#{File.basename(raw, ext)[0, 160]}.bin"
      end

      raw
    end

    def file_extension(filename)
      File.extname(filename.to_s).downcase.sub(/\A\./, "")
    end

    def infer_media_type(filename:, content_type: nil)
      ct = content_type.to_s.downcase
      ext = file_extension(filename)

      return "image" if ct.start_with?("image/")
      return "audio" if ct.start_with?("audio/")
      return "video" if ct.start_with?("video/")

      return "image" if allowed_extension_list_for_type("image").include?(ext)
      return "audio" if allowed_extension_list_for_type("audio").include?(ext)
      return "video" if allowed_extension_list_for_type("video").include?(ext)

      nil
    end

    def validate_extension!(filename, media_type)
      ext = file_extension(filename)
      raise_error("unsupported_file_type", "This file type is not supported.", details: { extension: ext.presence }) if media_type.blank?

      allowed = allowed_extension_list_for_type(media_type)
      return if ext.present? && allowed.include?(ext)

      raise_error(
        "unsupported_file_extension",
        "This file extension is not supported for #{media_type} uploads.",
        details: { media_type: media_type, extension: ext.presence, allowed_extensions: allowed }
      )
    end

    def validate_size!(filesize:, media_type:)
      size = filesize.to_i
      candidates = []

      site_max = site_max_upload_mb
      candidates << { scope: "site", max_mb: site_max } if site_max.to_f.positive?

      plugin_max = plugin_max_upload_mb
      candidates << { scope: "plugin", max_mb: plugin_max } if plugin_max.to_i.positive?

      type_max = type_size_limit_mb_for(media_type)
      candidates << { scope: media_type.to_s, max_mb: type_max } if type_max.to_i.positive?

      limiting = candidates.min_by { |candidate| candidate[:max_mb].to_f }
      return if limiting.blank?

      max_bytes = (limiting[:max_mb].to_f * 1024 * 1024).floor
      return if size <= max_bytes

      code = case limiting[:scope]
      when "site", "plugin" then "upload_too_large"
      when "video" then "video_too_large"
      when "audio" then "audio_too_large"
      when "image" then "image_too_large"
      else "upload_too_large"
      end

      raise_error(
        code,
        "This file is too large (#{rounded_mb(size)} MB). The maximum allowed size is #{limiting[:max_mb]} MB.",
        details: {
          scope: limiting[:scope],
          media_type: media_type,
          actual_bytes: size,
          actual_mb: rounded_mb(size),
          max_mb: limiting[:max_mb]
        }
      )
    end

    def allowed_extension_list_for_type(media_type)
      allowed = case media_type.to_s
      when "image"
        ::MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_image_extensions)
      when "audio"
        ::MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_audio_extensions)
      when "video"
        ::MediaGallery::Permissions.list_setting(SiteSetting.media_gallery_allowed_video_extensions)
      else
        []
      end

      allowed = case media_type.to_s
      when "image" then ::MediaGallery::MediaItem::IMAGE_EXTS
      when "audio" then ::MediaGallery::MediaItem::AUDIO_EXTS
      when "video" then ::MediaGallery::MediaItem::VIDEO_EXTS
      else []
      end if allowed.blank? && defined?(::MediaGallery::MediaItem)

      allowed.map { |ext| ext.to_s.downcase.sub(/\A\./, "") }.reject(&:blank?).uniq
    end

    def site_max_upload_mb
      kb = SiteSetting.respond_to?(:max_attachment_size_kb) ? SiteSetting.max_attachment_size_kb.to_i : 0
      return nil unless kb.positive?

      (kb.to_f / 1024.0).round(1)
    end

    def plugin_max_upload_mb
      SiteSetting.respond_to?(:media_gallery_max_upload_size_mb) ? SiteSetting.media_gallery_max_upload_size_mb.to_i : 0
    end

    def type_size_limit_mb_for(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_max_video_size_mb) ? SiteSetting.media_gallery_max_video_size_mb.to_i : 0
      when "audio"
        SiteSetting.respond_to?(:media_gallery_max_audio_size_mb) ? SiteSetting.media_gallery_max_audio_size_mb.to_i : 0
      when "image"
        SiteSetting.respond_to?(:media_gallery_max_image_size_mb) ? SiteSetting.media_gallery_max_image_size_mb.to_i : 0
      else
        0
      end
    end

    def rounded_mb(bytes)
      return 0 if bytes.to_i <= 0

      (bytes.to_f / (1024.0 * 1024.0)).round(1)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue
      nil
    end

    def cleanup_session!(session_id)
      sid = normalize_session_id!(session_id)
      dir = session_path(sid)
      return { removed: false, bytes: 0 } unless Dir.exist?(dir)

      bytes = directory_size(dir)
      ::MediaGallery::PathSecurity.remove_tree_under!(dir, root_path)
      { removed: true, bytes: bytes }
    end

    def with_global_lock
      FileUtils.mkdir_p(root_path)

      File.open(global_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock&.flock(File::LOCK_UN) rescue nil
      end
    end

    def with_session_lock(session_id)
      sid = normalize_session_id!(session_id)
      FileUtils.mkdir_p(session_path(sid))

      File.open(lock_path(sid), File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise_error("upload_session_busy", "This upload is already being finalized. Please wait.", status: 409)
        end

        yield
      ensure
        lock&.flock(File::LOCK_UN) rescue nil
      end
    end

    def directory_size(path)
      return 0 unless path.present? && Dir.exist?(path)

      total = 0
      Find.find(path) do |entry|
        next unless File.file?(entry)
        next if File.symlink?(entry)

        total += File.size(entry)
      rescue
        next
      end
      total
    rescue
      0
    end

    def record_log_event(event_type:, severity: "info", user: nil, message: nil, details: nil)
      return unless defined?(::MediaGallery::LogEvents)

      ::MediaGallery::LogEvents.record(
        event_type: event_type,
        severity: severity,
        category: "chunked_uploads",
        user: user,
        message: message,
        details: details || {}
      )
    rescue => e
      Rails.logger.warn("[media_gallery] chunked upload log event failed type=#{event_type} error=#{e.class}: #{e.message}")
      nil
    end

    def raise_error(code, message = nil, status: 422, details: nil)
      raise Error.new(code, message, status: status, details: details)
    end
  end
end
