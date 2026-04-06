# frozen_string_literal: true

require "fileutils"

module ::MediaGallery
  class SourceAcquirer
    def initialize(upload_path: ::MediaGallery::UploadPath)
      @upload_path = upload_path
    end

    def acquire!(upload:, workspace:)
      raise "missing_original_upload" if upload.blank?

      source_path = @upload_path.local_path_for(upload)
      raise "original_upload_not_on_local_disk" if source_path.blank?
      raise "original_file_missing: #{source_path}" unless File.exist?(source_path)

      ext = File.extname(upload.original_filename.to_s).downcase
      ext = ".bin" if ext.blank? || ext.length > 12

      dest = workspace.path("source#{ext}")
      FileUtils.cp(source_path, dest)
      dest
    end
  end
end
