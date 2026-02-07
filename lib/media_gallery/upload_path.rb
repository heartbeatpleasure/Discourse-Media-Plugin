# frozen_string_literal: true

module ::MediaGallery
  module UploadPath
    module_function

    # Returns an absolute local filesystem path for an Upload when using local storage.
    # Returns nil when the path can't be resolved.
    def local_path_for(upload)
      return nil if upload.nil?

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

      nil
    rescue => _e
      nil
    end
  end
end
