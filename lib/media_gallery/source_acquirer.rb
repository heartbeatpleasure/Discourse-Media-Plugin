# frozen_string_literal: true

require "fileutils"

module ::MediaGallery
  class SourceAcquirer
    def initialize(upload_path: ::MediaGallery::UploadPath, discourse_store: nil)
      @upload_path = upload_path
      @discourse_store = discourse_store
    end

    def acquire!(upload:, workspace:)
      raise "missing_original_upload" if upload.blank?

      ext = safe_extension_for(upload)
      dest = workspace.path("source#{ext}")

      return dest if copy_from_local_path(upload, dest)
      return dest if download_from_store(upload, dest)

      raise "original_upload_unavailable"
    end

    private

    attr_reader :upload_path

    def safe_extension_for(upload)
      ext = File.extname(upload.original_filename.to_s).downcase
      ext = ".bin" if ext.blank? || ext.length > 12
      ext
    end

    def discourse_store
      return @discourse_store if defined?(@discourse_store) && @discourse_store
      @discourse_store = defined?(Discourse) && Discourse.respond_to?(:store) ? Discourse.store : nil
    end

    def copy_from_local_path(upload, dest)
      source_path = upload_path.local_path_for(upload)
      return false if source_path.blank? || !File.exist?(source_path)

      FileUtils.cp(source_path, dest)
      true
    rescue => e
      Rails.logger.warn("[media_gallery] source acquire local copy failed upload_id=#{upload&.id} error=#{e.class}: #{e.message}")
      false
    end

    def download_from_store(upload, dest)
      store = discourse_store
      return false if store.blank?

      download_inputs_for(upload).each do |input|
        DOWNLOAD_METHODS.each do |method_name|
          next unless store.respond_to?(method_name)

          DOWNLOAD_ARGUMENT_PATTERNS.each do |pattern|
            FileUtils.rm_f(dest)
            result = invoke_download(store, method_name, pattern.map { |value| value == :input ? input : dest })
            next if result == :argument_error
            return true if persist_download_result!(result, dest)
          end
        end
      end

      false
    rescue => e
      Rails.logger.warn("[media_gallery] source acquire download failed upload_id=#{upload&.id} error=#{e.class}: #{e.message}")
      false
    end

    DOWNLOAD_METHODS = %i[download! download].freeze
    DOWNLOAD_ARGUMENT_PATTERNS = [[:input, :dest], [:input], [:dest, :input]].freeze

    def download_inputs_for(upload)
      inputs = [upload]
      url = upload.respond_to?(:url) ? upload.url.to_s.presence : nil
      inputs << url if url.present?
      inputs.uniq
    end

    def invoke_download(store, method_name, args)
      store.public_send(method_name, *args)
    rescue ArgumentError
      :argument_error
    end

    def persist_download_result!(result, dest)
      return File.exist?(dest) if result.nil? && File.exist?(dest)

      path = extract_path_from_result(result)
      if path.present? && File.exist?(path)
        FileUtils.cp(path, dest) unless same_path?(path, dest)
        return true
      end

      return false unless result.respond_to?(:read)

      result.rewind if result.respond_to?(:rewind)
      File.open(dest, "wb") { |file| IO.copy_stream(result, file) }
      true
    rescue => e
      Rails.logger.warn("[media_gallery] source acquire persist failed dest=#{dest} error=#{e.class}: #{e.message}")
      false
    ensure
      if result.respond_to?(:close!)
        result.close!
      elsif result.respond_to?(:close) && !path_like_result?(result)
        result.close
      end
    end

    def extract_path_from_result(result)
      return result if result.is_a?(String)
      return result.path if result.respond_to?(:path)

      nil
    end

    def path_like_result?(result)
      result.is_a?(String) || result.respond_to?(:path)
    end

    def same_path?(first, second)
      File.expand_path(first.to_s) == File.expand_path(second.to_s)
    rescue
      false
    end
  end
end
