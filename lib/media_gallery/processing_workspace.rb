# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module ::MediaGallery
  class ProcessingWorkspace
    attr_reader :root

    def self.open(prefix: "media-gallery")
      configured_root = ::MediaGallery::StorageSettingsResolver.processing_root_path
      dir =
        if configured_root.present?
          FileUtils.mkdir_p(configured_root)
          Dir.mktmpdir(prefix, configured_root)
        else
          Dir.mktmpdir(prefix)
        end

      workspace = new(dir)
      return workspace unless block_given?

      begin
        yield workspace
      ensure
        workspace.cleanup!
      end
    end

    def initialize(root)
      @root = root
      FileUtils.mkdir_p(@root)
    end

    def path(*parts)
      File.join(@root, *parts.map(&:to_s))
    end

    def ensure_dir!(*parts)
      dir = path(*parts)
      FileUtils.mkdir_p(dir)
      dir
    end

    def cleanup!
      FileUtils.rm_rf(@root) if @root.present? && Dir.exist?(@root)
    rescue
      # ignore cleanup errors
    end
  end
end
