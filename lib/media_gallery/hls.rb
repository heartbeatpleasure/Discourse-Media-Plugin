# frozen_string_literal: true

require "fileutils"
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

      master.present? && File.exist?(master) && complete.present? && File.exist?(complete)
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

      hls_root = MediaGallery::PrivateStorage.hls_root_abs_dir(public_id)
      variant_dir = MediaGallery::PrivateStorage.hls_variant_abs_dir(public_id, variant)

      # Clean old outputs to avoid stale segments.
      FileUtils.rm_rf(hls_root) if hls_root.present? && Dir.exist?(hls_root)
      MediaGallery::PrivateStorage.ensure_dir!(variant_dir)

      MediaGallery::Ffmpeg.package_hls_single_variant(
        input_path: input_path,
        output_dir: variant_dir,
        segment_seconds: segment_duration_seconds
      )

      write_master_playlist!(item: item, variant: variant)

      File.write(MediaGallery::PrivateStorage.hls_complete_abs_path(public_id), Time.now.utc.iso8601)

      {
        "ready" => true,
        "variant" => variant,
        "segment_duration_seconds" => segment_duration_seconds,
        "generated_at" => Time.now.utc.iso8601
      }
    rescue => e
      Rails.logger.warn("[media_gallery] HLS packaging failed public_id=#{item&.public_id} error=#{e.class}: #{e.message}")
      nil
    end

    def write_master_playlist!(item:, variant:)
      public_id = item.public_id.to_s
      path = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      dir = File.dirname(path)
      MediaGallery::PrivateStorage.ensure_dir!(dir)

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
      content = <<~M3U
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:#{res}BANDWIDTH=#{bps},AVERAGE-BANDWIDTH=#{bps}
        #{variant}/index.m3u8
      M3U

      File.write(path, content)
    end
    private_class_method :write_master_playlist!
  end
end
