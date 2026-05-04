# frozen_string_literal: true

require "active_support/key_generator"
require "active_support/message_encryptor"
require "base64"
require "fileutils"
require "securerandom"
require "time"

module ::MediaGallery
  # Helper for HLS AES-128 packaging preparation and server-side key handling.
  #
  # This module still does not change playback by itself. It provides validated
  # key material helpers, FFmpeg keyinfo files and encrypted DB storage helpers.
  # Later iterations wire these pieces into packaging, playlist rewriting and
  # the tokenized key endpoint.
  module HlsAes128
    module_function

    METHOD = "AES-128"
    SCHEME_SINGLE_KEY_V1 = "hls_aes128_single_key_v1"
    DEFAULT_KEY_ID = "v0"
    KEY_BYTES = 16
    KEY_ID_PATTERN = /\A[a-zA-Z0-9_-]+\z/
    IV_HEX_PATTERN = /\A[0-9a-fA-F]{32}\z/
    ENCRYPTOR_SALT = "media_gallery_hls_aes128_key_v1"

    def enabled?
      ::MediaGallery::Hls.respond_to?(:aes128_enabled?) && ::MediaGallery::Hls.aes128_enabled?
    rescue
      false
    end

    def required?
      ::MediaGallery::Hls.respond_to?(:aes128_required?) && ::MediaGallery::Hls.aes128_required?
    rescue
      false
    end

    def key_rotation_segments
      if ::MediaGallery::Hls.respond_to?(:aes128_key_rotation_segments)
        ::MediaGallery::Hls.aes128_key_rotation_segments.to_i
      else
        0
      end
    rescue
      0
    end

    def normalize_key_id(key_id = DEFAULT_KEY_ID)
      key_id = key_id.to_s.presence || DEFAULT_KEY_ID
      raise ArgumentError, "invalid_hls_aes128_key_id" unless key_id.match?(KEY_ID_PATTERN)

      key_id
    end

    def key_uri_placeholder(key_id = DEFAULT_KEY_ID)
      "enc_#{normalize_key_id(key_id)}.key"
    end

    def key_id_from_placeholder_uri(uri)
      uri = uri.to_s.strip
      return nil if uri.blank?

      # FFmpeg writes the first line of the keyinfo file into EXT-X-KEY as-is.
      # We intentionally only rewrite our own neutral placeholders. Absolute
      # URLs or arbitrary filenames are left untouched by the playlist rewriter.
      path = uri.split("?", 2).first.to_s
      file = File.basename(path)
      match = file.match(/\Aenc_([a-zA-Z0-9_-]+)\.key\z/)
      return nil unless match

      normalize_key_id(match[1])
    rescue
      nil
    end

    def keyinfo_filename(key_id = DEFAULT_KEY_ID)
      "enc_#{normalize_key_id(key_id)}.keyinfo"
    end

    def generate_key_bytes
      SecureRandom.bytes(KEY_BYTES)
    end

    def valid_key_bytes?(key_bytes)
      key_bytes.is_a?(String) && key_bytes.bytesize == KEY_BYTES
    end

    def normalize_iv_hex(iv_hex)
      return nil if iv_hex.nil? || iv_hex.to_s.blank?

      iv_hex = iv_hex.to_s.delete_prefix("0x").delete_prefix("0X")
      raise ArgumentError, "invalid_hls_aes128_iv" unless iv_hex.match?(IV_HEX_PATTERN)

      iv_hex.downcase
    end

    def generate_key_material(key_id: DEFAULT_KEY_ID, iv_hex: nil)
      key_id = normalize_key_id(key_id)

      {
        "method" => METHOD,
        "scheme" => SCHEME_SINGLE_KEY_V1,
        "key_id" => key_id,
        "key_bytes" => generate_key_bytes,
        # Keep IV optional. For the first production wiring we prefer no fixed
        # IV so HLS clients use the media sequence number as IV per segment.
        # This is also the least disruptive approach for current A/B playlist
        # mixing, where both A and B segment sets must be decryptable from the
        # same rewritten media playlist.
        "iv_hex" => normalize_iv_hex(iv_hex),
        "key_rotation_segments" => key_rotation_segments,
        "generated_at" => Time.now.utc.iso8601,
        "ready" => true,
      }.compact
    end

    def public_metadata_for(material)
      material = material.to_h.deep_stringify_keys

      {
        "method" => METHOD,
        "scheme" => material["scheme"].to_s.presence || SCHEME_SINGLE_KEY_V1,
        "key_id" => normalize_key_id(material["key_id"]),
        "iv_hex" => normalize_iv_hex(material["iv_hex"]),
        "key_rotation_segments" => material["key_rotation_segments"].to_i,
        "generated_at" => material["generated_at"].to_s.presence,
        "ready" => ActiveModel::Type::Boolean.new.cast(material["ready"]),
      }.compact
    end

    def key_info_content(key_uri:, key_path:, iv_hex: nil)
      key_uri = key_uri.to_s
      key_path = key_path.to_s
      raise ArgumentError, "hls_aes128_key_uri_missing" if key_uri.blank?
      raise ArgumentError, "hls_aes128_key_path_missing" if key_path.blank?

      lines = [key_uri, key_path]
      normalized_iv = normalize_iv_hex(iv_hex)
      lines << normalized_iv if normalized_iv.present?
      "#{lines.join("\n")}\n"
    end

    def write_key_files!(workspace_dir:, key_id: DEFAULT_KEY_ID, key_bytes:, iv_hex: nil)
      workspace_dir = workspace_dir.to_s
      raise ArgumentError, "hls_aes128_workspace_missing" if workspace_dir.blank?
      raise ArgumentError, "invalid_hls_aes128_key_bytes" unless valid_key_bytes?(key_bytes)

      key_id = normalize_key_id(key_id)
      FileUtils.mkdir_p(workspace_dir)

      key_path = File.join(workspace_dir, key_uri_placeholder(key_id))
      keyinfo_path = File.join(workspace_dir, keyinfo_filename(key_id))

      File.binwrite(key_path, key_bytes)
      File.chmod(0o600, key_path) rescue nil

      File.write(
        keyinfo_path,
        key_info_content(
          key_uri: key_uri_placeholder(key_id),
          key_path: key_path,
          iv_hex: iv_hex
        )
      )
      File.chmod(0o600, keyinfo_path) rescue nil

      {
        key_path: key_path,
        keyinfo_path: keyinfo_path,
        key_uri: key_uri_placeholder(key_id),
      }
    end

    def hls_key_artifact_rel_path?(rel_path)
      base = File.basename(rel_path.to_s)
      base.match?(/\Aenc_[a-zA-Z0-9_-]+\.(?:key|keyinfo)\z/)
    rescue
      false
    end

    def encrypt_key_bytes(key_bytes)
      raise ArgumentError, "invalid_hls_aes128_key_bytes" unless valid_key_bytes?(key_bytes)

      encryptor.encrypt_and_sign(Base64.strict_encode64(key_bytes))
    end

    def decrypt_key_ciphertext(ciphertext)
      ciphertext = ciphertext.to_s
      raise ArgumentError, "hls_aes128_key_ciphertext_missing" if ciphertext.blank?

      key_bytes = Base64.strict_decode64(encryptor.decrypt_and_verify(ciphertext))
      raise ArgumentError, "invalid_hls_aes128_key_bytes" unless valid_key_bytes?(key_bytes)

      key_bytes
    end

    def store_key!(item:, material:, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: nil)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?
      raise ArgumentError, "hls_aes128_key_model_unavailable" unless defined?(::MediaGallery::HlsAes128Key)

      material = material.to_h.deep_stringify_keys
      ::MediaGallery::HlsAes128Key.store_key!(
        media_item: item,
        key_id: normalize_key_id(material["key_id"]),
        variant: variant,
        ab: ab,
        key_bytes: material["key_bytes"],
        iv_hex: normalize_iv_hex(material["iv_hex"]),
        scheme: material["scheme"].to_s.presence || SCHEME_SINGLE_KEY_V1,
        key_rotation_segments: material["key_rotation_segments"].to_i,
        metadata: public_metadata_for(material).except("key_id", "iv_hex", "scheme", "key_rotation_segments")
      )
    end

    def fetch_key_bytes(item:, key_id:, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: nil)
      return nil if item.blank? || item.id.blank?
      return nil unless defined?(::MediaGallery::HlsAes128Key)

      ::MediaGallery::HlsAes128Key.fetch_key_bytes(
        media_item: item,
        key_id: normalize_key_id(key_id),
        variant: variant,
        ab: ab
      )
    rescue
      nil
    end

    def encryptor
      secret = Rails.application.secret_key_base.to_s.presence
      raise "hls_aes128_secret_key_base_missing" if secret.blank?

      key_len = ActiveSupport::MessageEncryptor.key_len("aes-256-gcm")
      key = ActiveSupport::KeyGenerator.new(secret, iterations: 1000).generate_key(ENCRYPTOR_SALT, key_len)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
    private_class_method :encryptor
  end
end
