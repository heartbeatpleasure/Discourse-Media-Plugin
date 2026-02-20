# frozen_string_literal: true

require "csv"
require "zlib"
require "digest"
require "fileutils"

module ::Jobs
  class MediaGalleryForensicsRetention < ::Jobs::Scheduled
    every 1.day

    BATCH_SIZE = 1_000

    def execute(args)
      return unless SiteSetting.media_gallery_enabled

      days =
        SiteSetting.respond_to?(:media_gallery_forensics_playback_session_retention_days) ?
          SiteSetting.media_gallery_forensics_playback_session_retention_days.to_i : 0

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

      prune_exports_if_needed!
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

        unless store_in_db
          root = export_root_path
          FileUtils.mkdir_p(root)

          file_path = File.join(root, "#{base}.csv.gz")
          tmp_path = file_path + ".tmp"

          File.open(tmp_path, "wb") { |f| f.write(gzip_bytes) }
          FileUtils.mv(tmp_path, file_path)

          file_bytes = File.size(file_path) rescue nil
        end

        ::MediaGallery::MediaForensicsExport.create!(
          cutoff_at: cutoff_at,
          rows_count: total,
          filename: download_filename,
          sha256: sha256,
          storage: storage,
          file_path: file_path,
          file_bytes: file_bytes,
          csv_gzip: store_in_db ? gzip_bytes : nil
        )
      end
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
                s.id,
                s.played_at&.iso8601,
                s.media_item_id,
                s.media_item&.public_id,
                s.user_id,
                s.user&.username,
                s.fingerprint_id,
                s.token_sha256,
                s.ip,
                s.user_agent,
                s.created_at&.iso8601
              ]
            end
          end
      end
    end

    def prune_exports_if_needed!
      keep_days =
        SiteSetting.respond_to?(:media_gallery_forensics_export_retention_days) ?
          SiteSetting.media_gallery_forensics_export_retention_days.to_i : 0

      max_keep =
        SiteSetting.respond_to?(:media_gallery_forensics_export_max_keep) ?
          SiteSetting.media_gallery_forensics_export_max_keep.to_i : 0

      return if keep_days <= 0 && max_keep <= 0

      delete_scope = ::MediaGallery::MediaForensicsExport.none

      if keep_days > 0
        cutoff = Time.zone.now - keep_days.days
        delete_scope = delete_scope.or(::MediaGallery::MediaForensicsExport.where("created_at < ?", cutoff))
      end

      if max_keep > 0
        ids =
          ::MediaGallery::MediaForensicsExport
            .order(created_at: :desc)
            .offset(max_keep)
            .pluck(:id)
        delete_scope = delete_scope.or(::MediaGallery::MediaForensicsExport.where(id: ids)) if ids.present?
      end

      return if delete_scope.blank?

      delete_scope.find_each do |e|
        if e.csv_gzip.blank? && e.file_path.present?
          ::File.delete(e.file_path) if ::File.exist?(e.file_path)
        end
      rescue => err
        Rails.logger.warn("[media_gallery] failed to delete export file #{e.file_path}: #{err.class}: #{err.message}")
      ensure
        e.destroy!
      end
    end
  end
end