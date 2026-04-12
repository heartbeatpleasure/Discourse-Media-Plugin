# frozen_string_literal: true

require "digest"
require "fileutils"

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


    def download_to_file!(key, destination_path)
      FileUtils.mkdir_p(File.dirname(destination_path.to_s))
      File.open(destination_path, "wb") do |file|
        client.get_object(bucket: bucket, key: normalized_key(key), response_target: file)
      end
      destination_path
    end


    def read_range(key, start_pos:, end_pos: nil)
      start_pos = start_pos.to_i
      raise RangeError, "invalid_range_start" if start_pos.negative?

      range_value = "bytes=#{start_pos}-"
      range_value << end_pos.to_i.to_s if end_pos.present?

      response = client.get_object(
        bucket: bucket,
        key: normalized_key(key),
        range: range_value,
      )
      response.body.read
    end

    def stream(key, range: nil)
      params = {
        bucket: bucket,
        key: normalized_key(key),
      }
      params[:range] = range.to_s if range.present?

      client.get_object(params) do |chunk|
        yield chunk
      end

      true
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

    def purge_key!(key)
      normalized = normalized_key(key)
      purge_entries!(keys: [normalized], prefix: nil).merge(key: denormalized_key(normalized))
    end

    def purge_prefix!(prefix)
      normalized = normalized_key(prefix)
      purge_entries!(keys: nil, prefix: normalized).merge(prefix: denormalized_key(normalized))
    end

    def same_location?(other)
      return false unless other.respond_to?(:backend) && other.respond_to?(:options)
      return false unless backend == other.backend.to_s

      comparable_options == other.send(:comparable_options)
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

    def purge_entries!(keys:, prefix:)
      ensure_available!

      version_entries, version_scan_supported = collect_version_entries(keys: keys, prefix: prefix)
      deleted_versions = 0
      deleted_delete_markers = 0
      deleted_current = 0

      if version_scan_supported
        version_entries.each do |entry|
          client.delete_object(bucket: bucket, key: entry[:key], version_id: entry[:version_id])
          if entry[:delete_marker]
            deleted_delete_markers += 1
          else
            deleted_versions += 1
          end
        end
      else
        keys_to_delete = keys || list_all_current_keys(prefix)
        keys_to_delete.each do |key_name|
          client.delete_object(bucket: bucket, key: key_name)
          deleted_current += 1
        end
      end

      if version_scan_supported
        remaining_versions = collect_version_entries(keys: keys, prefix: prefix).first.length
        remaining_current = list_remaining_current_count(keys: keys, prefix: prefix)
      else
        remaining_versions = 0
        remaining_current = list_remaining_current_count(keys: keys, prefix: prefix)
      end

      {
        ok: remaining_current.zero? && remaining_versions.zero?,
        backend: backend,
        deleted_current: deleted_current,
        deleted_versions: deleted_versions,
        deleted_delete_markers: deleted_delete_markers,
        remaining_current_count: remaining_current,
        remaining_version_entries: remaining_versions,
        version_purge_supported: version_scan_supported,
      }
    rescue => e
      {
        ok: false,
        backend: backend,
        deleted_current: deleted_current || 0,
        deleted_versions: deleted_versions || 0,
        deleted_delete_markers: deleted_delete_markers || 0,
        remaining_current_count: nil,
        remaining_version_entries: nil,
        version_purge_supported: version_scan_supported.nil? ? false : version_scan_supported,
        error: "#{e.class}: #{e.message}"
      }
    end

    def collect_version_entries(keys:, prefix:)
      entries = []
      key_filter = Array(keys).presence&.to_set
      return [entries, false] unless client.respond_to?(:list_object_versions)

      effective_prefix = prefix.presence || common_prefix_for_keys(key_filter)
      opts = { bucket: bucket }
      opts[:prefix] = effective_prefix if effective_prefix.present?
      key_marker = nil
      version_id_marker = nil

      loop do
        request = opts.dup
        request[:key_marker] = key_marker if key_marker.present?
        request[:version_id_marker] = version_id_marker if version_id_marker.present?
        result = client.list_object_versions(request)

        Array(result.versions).each do |version|
          next if key_filter.present? && !key_filter.include?(version.key.to_s)
          entries << { key: version.key.to_s, version_id: version.version_id.to_s, delete_marker: false }
        end

        Array(result.delete_markers).each do |marker|
          next if key_filter.present? && !key_filter.include?(marker.key.to_s)
          entries << { key: marker.key.to_s, version_id: marker.version_id.to_s, delete_marker: true }
        end

        break unless result.is_truncated
        key_marker = result.next_key_marker
        version_id_marker = result.next_version_id_marker
      end

      [entries, true]
    rescue ::Aws::S3::Errors::NotImplemented, ::Aws::S3::Errors::InvalidArgument, ::Aws::S3::Errors::MethodNotAllowed, ::Aws::S3::Errors::NoSuchBucket
      [[], false]
    rescue ::Aws::S3::Errors::ServiceError => e
      # Providers without version listing support may surface provider-specific service errors.
      if e.message.to_s =~ /(not implemented|unsupported|invalid request)/i
        [[], false]
      else
        raise
      end
    end

    def list_all_current_keys(prefix)
      continuation_token = nil
      keys = []
      loop do
        result = client.list_objects_v2(bucket: bucket, prefix: prefix, continuation_token: continuation_token)
        keys.concat(Array(result.contents).map(&:key))
        break unless result.is_truncated
        continuation_token = result.next_continuation_token
      end
      keys.uniq
    end

    def list_remaining_current_count(keys:, prefix:)
      if keys.present?
        Array(keys).count { |key_name| exists?(denormalized_key(key_name)) }
      else
        list_prefix(denormalized_key(prefix), limit: 1_000_000).length
      end
    end


    def common_prefix_for_keys(keys)
      list = Array(keys).compact.map(&:to_s).reject(&:empty?)
      return nil if list.empty?
      return list.first if list.length == 1

      prefix = list.first.dup
      list[1..].each do |value|
        max = [prefix.length, value.length].min
        i = 0
        i += 1 while i < max && prefix[i] == value[i]
        prefix = prefix[0...i]
        break if prefix.empty?
      end

      return nil if prefix.empty?

      if (slash = prefix.rindex('/'))
        prefix[0..slash]
      else
        nil
      end
    end

    def comparable_options
      {
        endpoint: options[:endpoint].to_s.sub(%r{/+\z}, ""),
        region: options[:region].to_s,
        bucket: bucket,
        prefix: options[:prefix].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, ""),
        force_path_style: !!options[:force_path_style],
      }
    end

    def ensure_sdk_loaded!
      require "set"
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
