# frozen_string_literal: true

require "digest"
require "securerandom"
require "fileutils"

module ::MediaGallery
  class LocalAssetStore < AssetStore
    attr_reader :root_path

    def initialize(root_path:)
      @root_path = root_path.to_s
    end

    def backend
      "local"
    end

    def ensure_available!
      return true if defined?(@available) && @available
      raise "local_asset_root_path_missing" if @root_path.blank?

      FileUtils.mkdir_p(@root_path)
      test_path = File.join(@root_path, ".write_test_#{SecureRandom.hex(6)}")
      File.write(test_path, "ok")
      FileUtils.rm_f(test_path)
      @available = true
      true
    end

    def put_file!(source_path, key:, content_type:, metadata: nil)
      ensure_available!
      raise "source_file_missing" if source_path.blank? || !File.exist?(source_path)

      abs = absolute_path_for(key)
      FileUtils.mkdir_p(File.dirname(abs))
      FileUtils.cp(source_path, abs)

      build_result(abs, content_type: content_type, metadata: metadata)
    end

    def read(key)
      abs = absolute_path_for(key)
      raise Errno::ENOENT, abs unless File.exist?(abs)
      File.binread(abs)
    end

    def exists?(key)
      File.exist?(absolute_path_for(key))
    end


    def object_info(key)
      abs = absolute_path_for(key)
      return { exists: false, backend: backend, key: key.to_s.sub(%r{\A/+}, "") } unless File.exist?(abs)

      {
        exists: true,
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        bytes: File.size(abs),
        content_type: nil,
        checksum_sha256: Digest::SHA256.file(abs).hexdigest
      }
    rescue => e
      {
        exists: false,
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        error: "#{e.class}: #{e.message}"
      }
    end


    def download_to_file!(key, destination_path)
      abs = absolute_path_for(key)
      raise Errno::ENOENT, abs unless File.exist?(abs)

      FileUtils.mkdir_p(File.dirname(destination_path.to_s))
      FileUtils.cp(abs, destination_path)
      destination_path
    end


    def read_range(key, start_pos:, end_pos: nil)
      abs = absolute_path_for(key)
      raise Errno::ENOENT, abs unless File.exist?(abs)

      start_pos = start_pos.to_i
      raise RangeError, "invalid_range_start" if start_pos.negative?

      file_size = File.size(abs)
      raise RangeError, "range_not_satisfiable" if start_pos >= file_size

      finish = end_pos.nil? ? (file_size - 1) : end_pos.to_i
      finish = file_size - 1 if finish >= file_size
      raise RangeError, "range_not_satisfiable" if finish < start_pos

      length = (finish - start_pos) + 1
      IO.binread(abs, length, start_pos)
    end

    def stream(key, range: nil)
      abs = absolute_path_for(key)
      raise Errno::ENOENT, abs unless File.exist?(abs)

      start_pos = 0
      finish = nil
      if range.present?
        match = range.to_s.match(/\Abytes=(\d+)-(\d*)\z/i)
        raise RangeError, "invalid_range_header" if match.blank?

        start_pos = match[1].to_i
        finish = match[2].present? ? match[2].to_i : nil
      end

      File.open(abs, "rb") do |io|
        io.seek(start_pos, IO::SEEK_SET) if start_pos.positive?
        remaining = finish.present? ? ((finish - start_pos) + 1) : nil

        loop do
          break if remaining == 0

          chunk_size = remaining.present? ? [remaining, 512.kilobytes].min : 512.kilobytes
          chunk = io.read(chunk_size)
          break if chunk.blank?

          yield chunk
          remaining -= chunk.bytesize if remaining.present?
        end
      end

      true
    end

    def delete(key)
      abs = absolute_path_for(key)
      FileUtils.rm_f(abs)
      cleanup_empty_parents(File.dirname(abs))
      true
    rescue
      false
    end

    def delete_prefix(prefix)
      dir = absolute_path_for(prefix)
      FileUtils.rm_rf(dir) if dir.present? && Dir.exist?(dir)
      true
    rescue
      false
    end

    def list_prefix(prefix, limit: nil)
      dir = absolute_path_for(prefix)
      return [] unless Dir.exist?(dir)

      entries = []
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
        next if File.directory?(path)

        entries << relative_key_for(path)
        break if limit.present? && limit.to_i > 0 && entries.length >= limit.to_i
      end
      entries
    end


    def purge_key!(key)
      abs = absolute_path_for(key)
      existed = File.exist?(abs)
      FileUtils.rm_f(abs)
      cleanup_empty_parents(File.dirname(abs))

      {
        ok: true,
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        existed: existed,
        deleted_current: existed ? 1 : 0,
        deleted_versions: 0,
        deleted_delete_markers: 0,
        remaining_current_count: exists?(key) ? 1 : 0,
        remaining_version_entries: 0,
        version_purge_supported: true,
      }
    rescue => e
      { ok: false, backend: backend, key: key.to_s.sub(%r{\A/+}, ""), error: "#{e.class}: #{e.message}" }
    end

    def purge_prefix!(prefix)
      dir = absolute_path_for(prefix)
      existing_files = Dir.exist?(dir) ? Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).count { |p| File.file?(p) } : 0
      FileUtils.rm_rf(dir) if dir.present? && Dir.exist?(dir)
      cleanup_empty_parents(File.dirname(dir)) if dir.present?

      {
        ok: true,
        backend: backend,
        prefix: prefix.to_s.sub(%r{\A/+}, ""),
        existed: existing_files.positive?,
        deleted_current: existing_files,
        deleted_versions: 0,
        deleted_delete_markers: 0,
        remaining_current_count: list_prefix(prefix, limit: 1).length,
        remaining_version_entries: 0,
        version_purge_supported: true,
      }
    rescue => e
      { ok: false, backend: backend, prefix: prefix.to_s.sub(%r{\A/+}, ""), error: "#{e.class}: #{e.message}" }
    end

    def same_location?(other)
      return false unless other.respond_to?(:backend) && other.respond_to?(:root_path)
      backend == other.backend.to_s && File.expand_path(root_path.to_s) == File.expand_path(other.root_path.to_s)
    rescue
      false
    end

    def presigned_get_url(key, expires_in:, response_content_type: nil, response_content_disposition: nil)
      nil
    end

    def absolute_path_for(key)
      rel = key.to_s.sub(%r{\A/+}, "")
      File.join(@root_path, rel)
    end

    private

    def build_result(path, content_type:, metadata: nil)
      {
        backend: backend,
        key: relative_key_for(path),
        bytes: File.size(path),
        checksum_sha256: Digest::SHA256.file(path).hexdigest,
        content_type: content_type,
        metadata: metadata || {}
      }
    end

    def relative_key_for(path)
      path.to_s.sub(%r{\A#{Regexp.escape(@root_path.to_s.chomp('/'))}/?}, "")
    end

    def cleanup_empty_parents(path)
      root = @root_path.to_s.chomp("/")
      current = path.to_s
      while current.present? && current.start_with?(root) && current != root
        break unless Dir.exist?(current)
        break unless Dir.empty?(current)

        Dir.rmdir(current)
        current = File.dirname(current)
      end
    rescue
      # ignore
    end
  end
end
