# frozen_string_literal: true

require "base64"
require "digest"
require "json"

module ::MediaGallery
  module Token
    module_function

    ASSET_BINDING_VERSION = 1

    # Uses Rails secret_key_base under the hood; scoped by purpose.
    #
    # We keep the historical verifier name "media_gallery_stream" for backwards compatibility,
    # and introduce a separate verifier for HLS so an HLS token cannot be reused against
    # /media/stream/:token.
    def verifier(purpose: "stream")
      case purpose.to_s
      when "stream"
        Rails.application.message_verifier("media_gallery_stream")
      when "hls"
        Rails.application.message_verifier("media_gallery_hls")
      else
        Rails.application.message_verifier("media_gallery_stream")
      end
    end

    def ttl_seconds
      SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
    end

    def generate(payload, purpose: "stream")
      signed = verifier(purpose: purpose).generate(payload)
      Base64.urlsafe_encode64(signed, padding: false)
    end

    # Returns the decoded payload Hash if valid, otherwise nil.
    # Enforces signature + expiration.
    def verify(token, purpose: "stream")
      signed = Base64.urlsafe_decode64(token.to_s)
      payload = verifier(purpose: purpose).verify(signed)

      return nil unless payload.is_a?(Hash)

      exp = payload["exp"].to_i
      return nil if exp <= 0
      return nil if Time.now.to_i > exp

      payload
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    # Tries all known purposes and returns the first valid payload.
    # Adds "_purpose" so callers can optionally branch.
    def verify_any(token, purposes: %w[stream hls])
      Array(purposes).each do |p|
        payload = verify(token, purpose: p)
        return payload.merge("_purpose" => p.to_s) if payload.present?
      end
      nil
    end

    # upload_id is optional. When omitted, StreamController will resolve the file from MediaItem + kind.
    def build_stream_payload(media_item:, kind:, user:, request:, upload_id: nil, fingerprint_id: nil)
      exp = Time.now.to_i + ttl_seconds

      payload = {
        "media_item_id" => media_item.id,
        "kind" => kind,
        "exp" => exp
      }

      payload["upload_id"] = upload_id if upload_id.present?
      payload["fingerprint_id"] = fingerprint_id if fingerprint_id.present?

      asset_binding = current_asset_binding(media_item: media_item, kind: kind)
      payload["asset_binding"] = asset_binding if asset_binding.present?

      if SiteSetting.media_gallery_bind_stream_to_user && user&.id
        payload["user_id"] = user.id
      end

      if SiteSetting.media_gallery_bind_stream_to_ip && request&.remote_ip.present?
        payload["ip"] = request.remote_ip
      end

      payload
    end

    def asset_binding_valid?(media_item:, kind:, payload:)
      return false if media_item.blank? || payload.blank?

      bound = payload["asset_binding"].to_s
      return true if bound.blank? # backwards-compatible for pre-binding tokens

      expected = current_asset_binding(media_item: media_item, kind: kind).to_s
      return false if expected.blank?
      return false if bound.bytesize != expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(bound, expected)
    rescue
      false
    end

    def current_asset_binding(media_item:, kind:)
      return nil if media_item.blank?

      role_name = role_name_for_kind(kind)
      role = ::MediaGallery::AssetManifest.role_for(media_item, role_name)
      return nil unless role.is_a?(Hash)

      manifest = media_item.respond_to?(:storage_manifest_hash) ? media_item.storage_manifest_hash : (media_item.storage_manifest.is_a?(Hash) ? media_item.storage_manifest : {})
      payload = {
        version: ASSET_BINDING_VERSION,
        media_item_id: media_item.id,
        role_name: role_name,
        managed_storage_backend: media_item.try(:managed_storage_backend).to_s,
        managed_storage_profile: media_item.try(:managed_storage_profile).to_s,
        storage_schema_version: media_item.try(:storage_schema_version).to_i,
        manifest_generated_at: manifest["generated_at"].to_s,
        role: compact_binding_role(role)
      }

      "v#{ASSET_BINDING_VERSION}:#{Digest::SHA256.hexdigest(canonical_json(payload))}"
    rescue
      nil
    end

    def role_name_for_kind(kind)
      case kind.to_s
      when "thumbnail", "thumb"
        "thumbnail"
      when "hls"
        "hls"
      else
        "main"
      end
    end
    private_class_method :role_name_for_kind

    def compact_binding_role(role)
      {
        backend: role["backend"].to_s,
        upload_id: role["upload_id"].to_i.nonzero?,
        key: role["key"].to_s.presence,
        key_prefix: role["key_prefix"].to_s.presence,
        master_key: role["master_key"].to_s.presence,
        complete_key: role["complete_key"].to_s.presence,
        fingerprint_meta_key: role["fingerprint_meta_key"].to_s.presence,
        variant_playlist_key_template: role["variant_playlist_key_template"].to_s.presence,
        segment_key_template: role["segment_key_template"].to_s.presence,
        ab_segment_key_template: role["ab_segment_key_template"].to_s.presence,
        ab_fingerprint: !!role["ab_fingerprint"],
        variants: Array(role["variants"]).map(&:to_s).reject(&:blank?).sort,
        content_type: role["content_type"].to_s.presence,
        legacy: !!role["legacy"]
      }.compact
    end
    private_class_method :compact_binding_role

    def canonical_json(value)
      case value
      when Hash
        "{" + value.keys.map(&:to_s).sort.map { |key| "#{JSON.generate(key)}:#{canonical_json(value[key] || value[key.to_sym])}" }.join(",") + "}"
      when Array
        "[" + value.map { |entry| canonical_json(entry) }.join(",") + "]"
      else
        JSON.generate(value)
      end
    end
    private_class_method :canonical_json
  end
end
