# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

module ::MediaGallery
  # Small, side-effect-free helper for HLS AES-128 packaging preparation.
  #
  # This module deliberately does not store keys and does not change playback.
  # It only creates validated in-workspace key artifacts that FFmpeg can consume
  # through -hls_key_info_file. Later iterations wire this into packaging,
  # server-side key storage, playlist rewriting and the tokenized key endpoint.
  module HlsAes128
    module_function

    METHOD = "AES-128"
    SCHEME_SINGLE_KEY_V1 = "hls_aes128_single_key_v1"
    DEFAULT_KEY_ID = "v0"
    KEY_BYTES = 16
    KEY_ID_PATTERN = /\A[a-zA-Z0-9_-]+\z/
    IV_HEX_PATTERN = /\A[0-9a-fA-F]{32}\z/

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
  end
end
