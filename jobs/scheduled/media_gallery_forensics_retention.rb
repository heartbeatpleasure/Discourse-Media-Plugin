# frozen_string_literal: true

require "csv"
require "zlib"
require "digest"

module ::Jobs
  class MediaGalleryForensicsRetention < ::Jobs::Scheduled
    every 1.day

    BATCH_SIZE = 1_000

    def execute(args)
      return unless SiteSetting.media_gallery_enabled

      days = SiteSetting.respond_to?(:media_gallery_forensics_playback_session_retention_days) ?
        SiteSetting.media_gallery_forensics_playback_session_retention_days.to_i : 0

      return if days <= 0

      cutoff = Time.zone.now - days.days

      scope = ::MediaGallery::MediaPlaybackSession.where("played_at < ?", cutoff)
      total = scope.count
      return if total <= 0

      # Export BEFORE purge (stored in DB to be included in backups)
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
        # Re-check to avoid double export when multiple workers race
        already =
          ::MediaGallery::MediaForensicsExport.where(cutoff_at: cutoff_at).where("rows_count > 0").exists?
        return if already

        csv = build_csv(scope)

        gzip_bytes = Zlib.gzip(csv)
        sha256 = Digest::SHA256.hexdigest(csv)
        now = Time.zone.now
        filename = "media_gallery_playback_sessions_#{now.strftime("%Y%m%d_%H%M%S")}_cutoff_#{cutoff_at.strftime("%Y%m%d")}.csv"

        ::MediaGallery::MediaForensicsExport.create!(
          cutoff_at: cutoff_at,
          rows_count: total,
          filename: filename,
          sha256: sha256,
          csv_gzip: gzip_bytes
        )
      end
    end

    def build_csv(scope)
      # We do minimal joins to keep it fast and avoid N+1.
      # Include public_id and username for easier later investigation.
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
      # Optional retention for stored exports. Defaults keep forever.
      keep_days = SiteSetting.respond_to?(:media_gallery_forensics_export_retention_days) ?
        SiteSetting.media_gallery_forensics_export_retention_days.to_i : 0

      max_keep = SiteSetting.respond_to?(:media_gallery_forensics_export_max_keep) ?
        SiteSetting.media_gallery_forensics_export_max_keep.to_i : 0

      if keep_days > 0
        cutoff = Time.zone.now - keep_days.days
        ::MediaGallery::MediaForensicsExport.where("created_at < ?", cutoff).delete_all
      end

      if max_keep > 0
        ids =
          ::MediaGallery::MediaForensicsExport
            .order(created_at: :desc)
            .offset(max_keep)
            .pluck(:id)
        ::MediaGallery::MediaForensicsExport.where(id: ids).delete_all if ids.present?
      end
    end
  end
end
