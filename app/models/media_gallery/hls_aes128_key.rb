# frozen_string_literal: true

module ::MediaGallery
  class HlsAes128Key < ::ActiveRecord::Base
    self.table_name = "media_gallery_hls_aes128_keys"

    belongs_to :media_item, class_name: "MediaGallery::MediaItem"

    validates :media_item_id, presence: true
    validates :key_id, presence: true, format: { with: ::MediaGallery::HlsAes128::KEY_ID_PATTERN }
    validates :variant, presence: true, format: { with: ::MediaGallery::HlsAes128::KEY_ID_PATTERN }
    validates :scheme, presence: true
    validates :key_ciphertext, presence: true
    validates :ab, format: { with: ::MediaGallery::HlsAes128::KEY_ID_PATTERN }, allow_blank: true
    validates :iv_hex, format: { with: ::MediaGallery::HlsAes128::IV_HEX_PATTERN }, allow_nil: true

    scope :active, -> { where(active: true) }

    def self.store_key!(media_item:, key_id:, key_bytes:, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: nil, iv_hex: nil, scheme: ::MediaGallery::HlsAes128::SCHEME_SINGLE_KEY_V1, key_rotation_segments: 0, metadata: {})
      raise ArgumentError, "media_item_missing" if media_item.blank? || media_item.id.blank?
      raise ArgumentError, "invalid_hls_aes128_key_bytes" unless ::MediaGallery::HlsAes128.valid_key_bytes?(key_bytes)

      normalized_key_id = ::MediaGallery::HlsAes128.normalize_key_id(key_id)
      normalized_variant = ::MediaGallery::HlsAes128.normalize_key_id(variant)
      normalized_ab = ab.to_s.presence&.downcase || ""
      normalized_iv = ::MediaGallery::HlsAes128.normalize_iv_hex(iv_hex)

      record = find_or_initialize_by(
        media_item_id: media_item.id,
        key_id: normalized_key_id,
        variant: normalized_variant,
        ab: normalized_ab
      )

      record.assign_attributes(
        key_ciphertext: ::MediaGallery::HlsAes128.encrypt_key_bytes(key_bytes),
        iv_hex: normalized_iv,
        scheme: scheme.to_s.presence || ::MediaGallery::HlsAes128::SCHEME_SINGLE_KEY_V1,
        active: true,
        key_rotation_segments: [key_rotation_segments.to_i, 0].max,
        metadata: metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      )
      record.save!
      record
    end

    def self.fetch_key_record(media_item:, key_id:, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: nil)
      return nil if media_item.blank? || media_item.id.blank?

      active.find_by(
        media_item_id: media_item.id,
        key_id: ::MediaGallery::HlsAes128.normalize_key_id(key_id),
        variant: ::MediaGallery::HlsAes128.normalize_key_id(variant),
        ab: ab.to_s.presence&.downcase || ""
      )
    rescue
      nil
    end

    def self.fetch_key_bytes(media_item:, key_id:, variant: ::MediaGallery::Hls::DEFAULT_VARIANT, ab: nil)
      record = fetch_key_record(media_item: media_item, key_id: key_id, variant: variant, ab: ab)
      record&.key_bytes
    end

    def key_bytes
      ::MediaGallery::HlsAes128.decrypt_key_ciphertext(key_ciphertext)
    end

    def public_metadata
      {
        "method" => ::MediaGallery::HlsAes128::METHOD,
        "scheme" => scheme.to_s.presence,
        "key_id" => key_id.to_s.presence,
        "variant" => variant.to_s.presence,
        "ab" => ab.to_s.presence,
        "iv_hex" => iv_hex.to_s.presence,
        "key_rotation_segments" => key_rotation_segments.to_i,
        "ready" => active?,
        "created_at" => created_at&.utc&.iso8601,
        "updated_at" => updated_at&.utc&.iso8601,
      }.compact
    end
  end
end
