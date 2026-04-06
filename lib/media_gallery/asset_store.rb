# frozen_string_literal: true

module ::MediaGallery
  class AssetStore
    def backend
      raise NotImplementedError
    end

    def ensure_available!
      raise NotImplementedError
    end

    def put_file!(source_path, key:, content_type:, metadata: nil)
      raise NotImplementedError
    end

    def read(key)
      raise NotImplementedError
    end

    def exists?(key)
      raise NotImplementedError
    end

    def delete(key)
      raise NotImplementedError
    end

    def delete_prefix(prefix)
      raise NotImplementedError
    end

    def presigned_get_url(key, expires_in:, response_content_type: nil, response_content_disposition: nil)
      raise NotImplementedError
    end
  end
end
