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
        next if File.basename(path).start_with?(".")

        entries << relative_key_for(path)
        break if limit.present? && limit.to_i > 0 && entries.length >= limit.to_i
      end
      entries
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
