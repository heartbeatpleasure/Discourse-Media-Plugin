# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module ::MediaGallery
  module TempWorkspaceCleanup
    module_function

    PREFIXES = %w[media-gallery media_gallery_verify media_gallery_test_download media_gallery_forensics_hls_].freeze

    def enabled?
      !SiteSetting.respond_to?(:media_gallery_temp_cleanup_enabled) || SiteSetting.media_gallery_temp_cleanup_enabled
    rescue
      true
    end

    def retention_hours
      value = SiteSetting.respond_to?(:media_gallery_temp_cleanup_retention_hours) ? SiteSetting.media_gallery_temp_cleanup_retention_hours.to_i : 24
      value.positive? ? value : 24
    rescue
      24
    end

    def summary
      candidates = stale_candidates
      {
        enabled: enabled?,
        retention_hours: retention_hours,
        roots: cleanup_roots,
        stale_count: candidates.length,
        stale_bytes: candidates.sum { |row| row[:bytes].to_i },
        examples: candidates.first(10),
        generated_at: Time.now.utc.iso8601,
      }
    rescue => e
      { enabled: enabled?, retention_hours: retention_hours, stale_count: 0, stale_bytes: 0, error: "#{e.class}: #{e.message}".truncate(500) }
    end

    def cleanup!(dry_run: false)
      return summary.merge(skipped: true, reason: "disabled") unless enabled?
      candidates = stale_candidates
      removed = []
      candidates.each do |row|
        next if dry_run
        FileUtils.rm_rf(row[:path]) if safe_candidate_path?(row[:path])
        removed << row.merge(removed: true)
      rescue => e
        removed << row.merge(removed: false, error: "#{e.class}: #{e.message}".truncate(300))
      end
      summary.merge(dry_run: !!dry_run, attempted_count: candidates.length, removed_count: removed.count { |r| r[:removed] }, removed: removed.first(20))
    end

    def stale_candidates
      cutoff = retention_hours.hours.ago
      cleanup_roots.flat_map do |root|
        next [] unless root.present? && Dir.exist?(root)
        Dir.children(root).filter_map do |name|
          path = File.join(root, name)
          next unless File.directory?(path)
          next unless PREFIXES.any? { |prefix| name.start_with?(prefix) }
          mtime = File.mtime(path) rescue nil
          next if mtime.blank? || mtime > cutoff
          { path: path, name: name, mtime: mtime.utc.iso8601, age_hours: ((Time.now - mtime) / 3600.0).round(1), bytes: directory_size(path, limit: 100.megabytes) }
        end
      end.compact.sort_by { |row| row[:mtime].to_s }
    end

    def cleanup_roots
      roots = []
      configured = ::MediaGallery::StorageSettingsResolver.processing_root_path rescue nil
      roots << configured if configured.present?
      roots << Dir.tmpdir
      roots.compact.uniq
    end

    def directory_size(path, limit: 100.megabytes)
      total = 0
      Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).each do |entry|
        next if [".", ".."].include?(File.basename(entry))
        next unless File.file?(entry)
        total += File.size(entry) rescue 0
        break if total >= limit
      end
      total
    rescue
      0
    end
    private_class_method :directory_size

    def safe_candidate_path?(path)
      path = File.expand_path(path.to_s)
      cleanup_roots.any? do |root|
        root_path = File.expand_path(root.to_s)
        path.start_with?(root_path + File::SEPARATOR) && PREFIXES.any? { |prefix| File.basename(path).start_with?(prefix) }
      end
    rescue
      false
    end
    private_class_method :safe_candidate_path?
  end
end
