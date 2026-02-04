# frozen_string_literal: true

module ::MediaGallery
  module UploadPath
    module_function

    def local_path_for(upload)
      raise ArgumentError, "upload is required" if upload.nil?

      store = Discourse.store
      if store.respond_to?(:path_for)
        path = store.path_for(upload)
        return path if path.present? && File.exist?(path)
      end

      # Fallbacks (best-effort)
      if upload.respond_to?(:files) && upload.files.present?
        candidate = upload.files.first
        return candidate if candidate.present? && File.exist?(candidate)
      end

      raise "Unable to resolve local path for upload #{upload.id}. Ensure local storage is enabled."
    end
  end
end
