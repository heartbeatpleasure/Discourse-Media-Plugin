# frozen_string_literal: true

require "digest"

module ::MediaGallery
  class S3AssetStore < AssetStore
    attr_reader :options

    def initialize(options)
      @options = (options || {}).dup.symbolize_keys
      ensure_sdk_loaded!
    end

    def backend
      "s3"
    end

    def ensure_available!
      return true if defined?(@available) && @available
      raise "s3_endpoint_missing" if options[:endpoint].to_s.blank?
      raise "s3_bucket_missing" if options[:bucket].to_s.blank?
      raise "s3_access_key_id_missing" if options[:access_key_id].to_s.blank?
      raise "s3_secret_access_key_missing" if options[:secret_access_key].to_s.blank?

      head_bucket!
      @available = true
      true
    end

    def put_file!(source_path, key:, content_type:, metadata: nil)
      ensure_available!
      raise "source_file_missing" if source_path.blank? || !File.exist?(source_path)

      normalized = normalized_key(key)
      body = File.open(source_path, "rb")
      client.put_object(
        bucket: bucket,
        key: normalized,
        body: body,
        content_type: content_type,
        metadata: stringify_metadata(metadata),
      )

      {
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        bytes: File.size(source_path),
        checksum_sha256: Digest::SHA256.file(source_path).hexdigest,
        content_type: content_type,
        metadata: metadata || {}
      }
    ensure
      body&.close
    end

    def read(key)
      response = client.get_object(bucket: bucket, key: normalized_key(key))
      response.body.read
    end

    def exists?(key)
      client.head_object(bucket: bucket, key: normalized_key(key))
      true
    rescue ::Aws::S3::Errors::NotFound, ::Aws::S3::Errors::NoSuchKey
      false
    end


    def object_info(key)
      response = client.head_object(bucket: bucket, key: normalized_key(key))
      {
        exists: true,
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        bytes: response.content_length.to_i,
        content_type: response.content_type.to_s.presence,
        etag: response.etag.to_s.delete('"')
      }
    rescue ::Aws::S3::Errors::NotFound, ::Aws::S3::Errors::NoSuchKey
      { exists: false, backend: backend, key: key.to_s.sub(%r{\A/+}, "") }
    rescue => e
      {
        exists: false,
        backend: backend,
        key: key.to_s.sub(%r{\A/+}, ""),
        error: "#{e.class}: #{e.message}"
      }
    end

    def delete(key)
      client.delete_object(bucket: bucket, key: normalized_key(key))
      true
    rescue
      false
    end

    def delete_prefix(prefix)
      pref = normalized_key(prefix)
      continuation_token = nil

      loop do
        result = client.list_objects_v2(bucket: bucket, prefix: pref, continuation_token: continuation_token)
        keys = Array(result.contents).map(&:key)
        break if keys.empty?

        client.delete_objects(
          bucket: bucket,
          delete: { objects: keys.map { |k| { key: k } }, quiet: true }
        )

        break unless result.is_truncated
        continuation_token = result.next_continuation_token
      end

      true
    rescue
      false
    end

    def list_prefix(prefix, limit: nil)
      pref = normalized_key(prefix)
      keys = []
      continuation_token = nil
      max_keys = nil
      if limit.present? && limit.to_i > 0
        max_keys = [limit.to_i, 1000].min
      end

      loop do
        result = client.list_objects_v2(
          bucket: bucket,
          prefix: pref,
          continuation_token: continuation_token,
          max_keys: max_keys,
        )

        Array(result.contents).each do |obj|
          keys << denormalized_key(obj.key)
          return keys if limit.present? && limit.to_i > 0 && keys.length >= limit.to_i
        end

        break unless result.is_truncated
        continuation_token = result.next_continuation_token
      end

      keys
    end

    def presigned_get_url(key, expires_in:, response_content_type: nil, response_content_disposition: nil)
      params = { bucket: bucket, key: normalized_key(key) }
      params[:response_content_type] = response_content_type if response_content_type.present?
      params[:response_content_disposition] = response_content_disposition if response_content_disposition.present?

      presigner.presigned_url(:get_object, params.merge(expires_in: expires_in.to_i))
    end

    private

    def ensure_sdk_loaded!
      require "aws-sdk-s3"
    rescue LoadError
      raise "missing_aws_sdk_s3_gem"
    end

    def bucket
      options[:bucket].to_s
    end

    def client
      @client ||= ::Aws::S3::Client.new(client_options)
    end

    def presigner
      @presigner ||= ::Aws::S3::Presigner.new(client: client)
    end

    def head_bucket!
      client.head_bucket(bucket: bucket)
    end

    def client_options
      {
        endpoint: options[:endpoint],
        region: options[:region].presence || "auto",
        credentials: ::Aws::Credentials.new(options[:access_key_id], options[:secret_access_key]),
        force_path_style: !!options[:force_path_style]
      }
    end

    def normalized_key(key)
      rel = key.to_s.sub(%r{\A/+}, "")
      pref = normalized_prefix
      return rel if pref.blank?
      return rel if rel == pref || rel.start_with?("#{pref}/")
      return pref if rel.blank?

      "#{pref}/#{rel}"
    end

    def denormalized_key(key)
      full = key.to_s.sub(%r{\A/+}, "")
      pref = normalized_prefix
      return full if pref.blank?
      return "" if full == pref
      full.sub(%r{\A#{Regexp.escape(pref)}/*}, "")
    end

    def normalized_prefix
      options[:prefix].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
    end

    def stringify_metadata(metadata)
      return {} unless metadata.is_a?(Hash)
      metadata.each_with_object({}) { |(k, v), memo| memo[k.to_s] = v.to_s }
    end
  end
end
