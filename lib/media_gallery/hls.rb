# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

module ::MediaGallery
  # HLS packaging + simple readiness helpers.
  #
  # Milestone 1: single variant (v0) without A/B fingerprinting.
  # Future: store multiple variants and dynamically assemble playlists.
  module Hls
    module_function

    DEFAULT_VARIANT = "v0"

    def enabled?
      SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled
    end

    def segment_duration_seconds
      s = 0
      begin
        s = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      rescue
        s = 0
      end

      # Clamp to a sane range.
      s = 6 if s <= 0
      s = 2 if s < 2
      s = 10 if s > 10
      s
    end

    # For now, a single packaged set.
    def variants
      [DEFAULT_VARIANT]
    end

    def variant_allowed?(variant)
      variants.include?(variant.to_s)
    end

    # Readiness is file-based (avoids depending on DB metadata).
    def ready?(item)
      return false unless enabled?
      return false unless MediaGallery::PrivateStorage.enabled?
      return false unless item&.public_id.present?

      master = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      complete = MediaGallery::PrivateStorage.hls_complete_abs_path(item.public_id)

      return false if master.blank? || complete.blank?
      return false unless File.exist?(master) && File.exist?(complete)

      # Extra safety checks (prevents advertising HLS when only the marker exists).
      variants.all? do |v|
        pl = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, v)
        next false if pl.blank? || !File.exist?(pl)

        vdir = MediaGallery::PrivateStorage.hls_variant_abs_dir(item.public_id, v)
        next false if vdir.blank? || !Dir.exist?(vdir)

        # At least one segment must exist.
        Dir.glob(File.join(vdir, "*.ts")).any? || Dir.glob(File.join(vdir, "*.m4s")).any?
      end
    end

    # Generates HLS files for a processed MP4.
    # Returns metadata Hash on success, nil on failure.
    def package_video!(item, input_path:)
      return nil unless enabled?
      return nil unless MediaGallery::PrivateStorage.enabled?
      return nil unless item&.media_type.to_s == "video"
      return nil if input_path.blank? || !File.exist?(input_path)

      public_id = item.public_id.to_s
      variant = DEFAULT_VARIANT

      final_root = MediaGallery::PrivateStorage.hls_root_abs_dir(public_id)
      item_root = MediaGallery::PrivateStorage.item_private_dir(public_id)

      # Build into a temp folder first. This avoids destroying a previously valid HLS
      # set when repackaging fails (e.g. ffmpeg error, disk full).
      MediaGallery::PrivateStorage.ensure_dir!(item_root)
      tmp_root = File.join(item_root, "hls__tmp_#{SecureRandom.hex(8)}")
      tmp_variant_dir = File.join(tmp_root, variant)

      FileUtils.rm_rf(tmp_root) if Dir.exist?(tmp_root)
      MediaGallery::PrivateStorage.ensure_dir!(tmp_variant_dir)

      MediaGallery::Ffmpeg.package_hls_single_variant(
        input_path: input_path,
        output_dir: tmp_variant_dir,
        segment_seconds: segment_duration_seconds
      )

      tmp_master = File.join(tmp_root, "master.m3u8")
      File.write(tmp_master, master_playlist_content(item: item, variant: variant))

      tmp_complete = File.join(tmp_root, ".complete")
      File.write(tmp_complete, Time.now.utc.iso8601)

      # Sanity check before swapping into place.
      tmp_variant_pl = File.join(tmp_variant_dir, "index.m3u8")
      unless File.exist?(tmp_master) && File.exist?(tmp_variant_pl) && File.exist?(tmp_complete)
        raise "hls_outputs_incomplete"
      end

      swap_in_packaged_hls!(final_root: final_root, tmp_root: tmp_root, item_root: item_root)

      {
        "ready" => true,
        "variant" => variant,
        "segment_duration_seconds" => segment_duration_seconds,
        "generated_at" => Time.now.utc.iso8601
      }
    rescue => e
      Rails.logger.warn("[media_gallery] HLS packaging failed public_id=#{item&.public_id} error=#{e.class}: #{e.message}")

      # Best-effort cleanup of temp folders (if any).
      begin
        if item&.public_id.present?
          item_root = MediaGallery::PrivateStorage.item_private_dir(item.public_id)
          Dir.glob(File.join(item_root.to_s, "hls__tmp_*")) do |p|
            FileUtils.rm_rf(p) if p.to_s.include?("hls__tmp_")
          end
        end
      rescue
        # ignore
      end

      nil
    end

    # Cleanup temp/old build artifacts left behind by repackaging.
    # Called by a scheduled job (hourly).
    def cleanup_build_artifacts!
      return unless MediaGallery::PrivateStorage.enabled?

      root = MediaGallery::PrivateStorage.private_root.to_s
      return if root.blank? || !Dir.exist?(root)

      # Keep old HLS folders around long enough for in-flight tokens to finish.
      ttl = SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
      keep_seconds = [ttl + 300, 30.minutes.to_i].max
      cutoff = Time.now - keep_seconds

      patterns = [
        File.join(root, "*", "hls__tmp_*"),
        File.join(root, "*", "hls__old_*"),
      ]

      patterns.each do |glob|
        Dir.glob(glob).each do |path|
          next unless File.directory?(path)

          begin
            m = File.mtime(path)
          rescue
            next
          end

          next if m > cutoff
          FileUtils.rm_rf(path)
        end
      end

      true
    rescue => e
      Rails.logger.warn("[media_gallery] HLS cleanup_build_artifacts failed: #{e.class}: #{e.message}")
      false
    end

    def swap_in_packaged_hls!(final_root:, tmp_root:, item_root:)
      return if final_root.blank? || tmp_root.blank? || item_root.blank?

      old_root = nil
      if Dir.exist?(final_root)
        old_root = File.join(item_root, "hls__old_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}_#{SecureRandom.hex(4)}")
        FileUtils.mv(final_root, old_root)
      end

      FileUtils.mv(tmp_root, final_root)
      true
    rescue => e
      # If the swap fails, try to restore the previous HLS folder.
      begin
        FileUtils.rm_rf(final_root) if final_root.present? && Dir.exist?(final_root)
        FileUtils.mv(old_root, final_root) if old_root.present? && Dir.exist?(old_root)
      rescue
        # ignore
      end
      raise e
    end
    private_class_method :swap_in_packaged_hls!

    def master_playlist_content(item:, variant:)
      # Best-effort bandwidth estimation.
      dur = item.duration_seconds.to_i
      bytes = item.filesize_processed_bytes.to_i
      bps = (dur > 0 && bytes > 0) ? ((bytes * 8) / dur) : 5_000_000
      bps = 500_000 if bps < 500_000

      w = item.width.to_i
      h = item.height.to_i
      res = (w > 0 && h > 0) ? "RESOLUTION=#{w}x#{h}," : ""

      # Master playlist references the variant playlist via a relative path.
      # Our controller rewrites that URI into an authenticated endpoint.
      <<~M3U
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:#{res}BANDWIDTH=#{bps},AVERAGE-BANDWIDTH=#{bps}
        #{variant}/index.m3u8
      M3U
    end
    private_class_method :master_playlist_content
  end
end
