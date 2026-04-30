# frozen_string_literal: true

require "csv"
require "zlib"
require "digest"
require "fileutils"
require "securerandom"
require "set"

module ::Jobs
  class MediaGalleryForensicsRetention < ::Jobs::Scheduled
    every 1.day

    BATCH_SIZE = 1_000

    def execute(args)
      return unless SiteSetting.media_gallery_enabled

      prune_exports_if_needed!
      prune_orphan_archive_files_if_needed!

      days =
        SiteSetting.respond_to?(:media_gallery_forensics_playback_session_retention_days) ?
          SiteSetting.media_gallery_forensics_playback_session_retention_days.to_i : 90

      return if days <= 0

      cutoff = Time.zone.now - days.days

      scope = ::MediaGallery::MediaPlaybackSession.where("played_at < ?", cutoff)
      total = scope.count
      return if total <= 0

      # Export BEFORE purge
      if SiteSetting.respond_to?(:media_gallery_forensics_export_enabled) &&
         SiteSetting.media_gallery_forensics_export_enabled
        create_export!(scope, cutoff_at: cutoff, total: total)
      end

      # Purge in batches (avoid loading)
      scope.in_batches(of: BATCH_SIZE).delete_all

      if defined?(::MediaGallery::PlaybackOverlay)
        ::MediaGallery::PlaybackOverlay.purge_older_than!(cutoff)
      end
    rescue => e
      Rails.logger.error("[media_gallery] forensics retention failed: #{e.class}: #{e.message}")
      raise
    end

    private

    def create_export!(scope, cutoff_at:, total:)
      mutex_key = "media_gallery_forensics_export_#{cutoff_at.to_i}"
      DistributedMutex.synchronize(mutex_key, validity: 10.minutes) do
        already =
          ::MediaGallery::MediaForensicsExport.where(cutoff_at: cutoff_at).where("rows_count > 0").exists?
        return if already

        csv = build_csv(scope)
        gzip_bytes = Zlib.gzip(csv)
        sha256 = Digest::SHA256.hexdigest(csv)

        now = Time.zone.now
        base = "media_gallery_playback_sessions_#{now.strftime("%Y%m%d_%H%M%S")}_cutoff_#{cutoff_at.strftime("%Y%m%d")}".freeze
        download_filename = "#{base}.csv"

        store_in_db =
          SiteSetting.respond_to?(:media_gallery_forensics_export_store_in_db) &&
            SiteSetting.media_gallery_forensics_export_store_in_db

        storage = store_in_db ? "db" : "file"
        file_path = nil
        file_bytes = nil
        archive_path = nil
        archive_bytes = nil
        archived_at = nil

        unless store_in_db
          root = export_root_path
          FileUtils.mkdir_p(root)

          file_path = File.join(root, "#{base}.csv.gz")
          atomic_write(file_path, gzip_bytes)
          file_bytes = File.size(file_path) rescue nil
        end

        if archive_enabled?
          root = archive_root_path
          FileUtils.mkdir_p(root)
          archive_path = File.join(root, "#{base}.csv.gz")

          if file_path.present? && File.expand_path(file_path) == File.expand_path(archive_path)
            archive_bytes = file_bytes
          else
            atomic_write(archive_path, gzip_bytes)
            archive_bytes = File.size(archive_path) rescue nil
          end

          archived_at = now
        end

        ::MediaGallery::MediaForensicsExport.create!(
          cutoff_at: cutoff_at,
          rows_count: total,
          filename: download_filename,
          sha256: sha256,
          storage: storage,
          file_path: file_path,
          file_bytes: file_bytes,
          archive_path: archive_path,
          archive_bytes: archive_bytes,
          archived_at: archived_at,
          csv_gzip: store_in_db ? gzip_bytes : nil
        )
      end
    end

    def atomic_write(path, bytes)
      tmp_path = "#{path}.tmp-#{SecureRandom.hex(8)}"
      File.open(tmp_path, "wb") { |f| f.write(bytes) }
      FileUtils.mv(tmp_path, path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path.present? && File.exist?(tmp_path)
    end

    def export_root_path
      # Prefer explicit setting. Otherwise default under existing shared export root.
      explicit =
        SiteSetting.respond_to?(:media_gallery_forensics_export_root_path) ?
          SiteSetting.media_gallery_forensics_export_root_path.to_s.strip : ""

      return explicit if explicit.present?

      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) &&
         SiteSetting.media_gallery_original_export_root_path.present?
        return File.join(SiteSetting.media_gallery_original_export_root_path, "forensics_exports")
      end

      # Last resort: keep it in private root so it is never public.
      if SiteSetting.respond_to?(:media_gallery_private_root_path) &&
         SiteSetting.media_gallery_private_root_path.present?
        return File.join(SiteSetting.media_gallery_private_root_path, "forensics_exports")
      end

      "/shared/media_gallery/forensics_exports"
    end

    def archive_root_path
      explicit =
        SiteSetting.respond_to?(:media_gallery_forensics_export_archive_root_path) ?
          SiteSetting.media_gallery_forensics_export_archive_root_path.to_s.strip : ""

      return explicit if explicit.present?

      if SiteSetting.respond_to?(:media_gallery_private_root_path) &&
         SiteSetting.media_gallery_private_root_path.present?
        return File.join(SiteSetting.media_gallery_private_root_path, "forensics_export_archive")
      end

      "/shared/media_gallery/private/forensics_export_archive"
    end

    def archive_enabled?
      !SiteSetting.respond_to?(:media_gallery_forensics_export_archive_enabled) ||
        SiteSetting.media_gallery_forensics_export_archive_enabled
    end

    def build_csv(scope)
      header = [
        "session_id",
        "played_at",
        "media_item_id",
        "media_public_id",
        "user_id",
        "username",
        "fingerprint_id",
        "token_sha256",
        "ip",
        "user_agent",
        "created_at"
      ]

      CSV.generate(force_quotes: true) do |csv|
        csv << header

        scope
          .reorder(:id)
          .includes(:user, :media_item)
          .find_in_batches(batch_size: BATCH_SIZE) do |batch|
            batch.each do |s|
              csv << [
                csv_safe_cell(s.id),
                csv_safe_cell(s.played_at&.iso8601),
                csv_safe_cell(s.media_item_id),
                csv_safe_cell(s.media_item&.public_id),
                csv_safe_cell(s.user_id),
                csv_safe_cell(s.user&.username),
                csv_safe_cell(s.fingerprint_id),
                csv_safe_cell(s.token_sha256),
                csv_safe_cell(s.ip),
                csv_safe_cell(s.user_agent),
                csv_safe_cell(s.created_at&.iso8601)
              ]
            end
          end
      end
    end

    def csv_safe_cell(value)
      return "" if value.nil?

      text = value.to_s
      return "'#{text}" if text.start_with?("=", "+", "-", "@", "\t", "\r", "\n")
      text
    end

    def prune_exports_if_needed!
      keep_days =
        SiteSetting.respond_to?(:media_gallery_forensics_export_retention_days) ?
          SiteSetting.media_gallery_forensics_export_retention_days.to_i : 90

      max_keep =
        SiteSetting.respond_to?(:media_gallery_forensics_export_max_keep) ?
          SiteSetting.media_gallery_forensics_export_max_keep.to_i : 0

      return if keep_days <= 0 && max_keep <= 0

      ids = []

      if keep_days > 0
        cutoff = Time.zone.now - keep_days.days
        ids.concat(::MediaGallery::MediaForensicsExport.where("created_at < ?", cutoff).pluck(:id))
      end

      if max_keep > 0
        ids.concat(
          ::MediaGallery::MediaForensicsExport
            .order(created_at: :desc)
            .offset(max_keep)
            .pluck(:id)
        )
      end

      ids = ids.compact.uniq
      return if ids.blank?

      ::MediaGallery::MediaForensicsExport.where(id: ids).find_each do |e|
        delete_export_files_for!(e)
      rescue => err
        Rails.logger.warn("[media_gallery] failed to delete export files for export_id=#{e.id}: #{err.class}: #{err.message}")
      ensure
        e.destroy!
      end
    end

    def prune_orphan_archive_files_if_needed!
      keep_days =
        SiteSetting.respond_to?(:media_gallery_forensics_export_retention_days) ?
          SiteSetting.media_gallery_forensics_export_retention_days.to_i : 90
      return if keep_days <= 0

      root = archive_root_path
      return if root.blank? || !Dir.exist?(root)
      return unless allowed_export_root?(root)

      cutoff = Time.zone.now - keep_days.days
      known = ::MediaGallery::MediaForensicsExport.where.not(archive_path: nil).pluck(:archive_path).map(&:to_s).to_set

      Dir.glob(File.join(root, "*.csv.gz")).each do |path|
        next if known.include?(path.to_s)
        next unless File.mtime(path) < cutoff
        delete_export_file_safely!(path)
      rescue => err
        Rails.logger.warn("[media_gallery] failed to prune orphan forensics archive #{safe_log_path(path)}: #{err.class}: #{err.message}")
      end
    rescue => e
      Rails.logger.warn("[media_gallery] prune orphan forensics archives failed: #{e.class}: #{e.message}")
    end

    def delete_export_files_for!(export)
      [export.file_path, export.respond_to?(:archive_path) ? export.archive_path : nil]
        .compact
        .map(&:to_s)
        .reject(&:blank?)
        .uniq
        .each { |path| delete_export_file_safely!(path) }
    end

    def delete_export_file_safely!(path)
      return false if path.blank? || !::File.exist?(path)
      raise "export_file_path_outside_allowed_roots" unless allowed_export_path?(path)

      ::File.delete(path)
      true
    end

    def allowed_export_path?(path)
      allowed_export_roots.any? do |candidate|
        candidate.present? && ::MediaGallery::PathSecurity.realpath_under?(path, candidate)
      end
    rescue
      false
    end

    def allowed_export_root?(path)
      allowed_export_roots.any? do |candidate|
        candidate.present? && ::MediaGallery::PathSecurity.realpath_under?(path, candidate, allow_root: true)
      end
    rescue
      false
    end

    def allowed_export_roots
      roots = [export_root_path, archive_root_path]
      if SiteSetting.respond_to?(:media_gallery_private_root_path) && SiteSetting.media_gallery_private_root_path.present?
        roots << SiteSetting.media_gallery_private_root_path
      end
      if SiteSetting.respond_to?(:media_gallery_original_export_root_path) && SiteSetting.media_gallery_original_export_root_path.present?
        roots << SiteSetting.media_gallery_original_export_root_path
      end

      roots.compact.uniq
    end

    def safe_log_path(path)
      path.to_s
    rescue
      "[unavailable]"
    end
  end
end
