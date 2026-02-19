# frozen_string_literal: true

require "base64"

module ::MediaGallery
  module Token
    module_function

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

      if SiteSetting.media_gallery_bind_stream_to_user && user&.id
        payload["user_id"] = user.id
      end

      if SiteSetting.media_gallery_bind_stream_to_ip && request&.remote_ip.present?
        payload["ip"] = request.remote_ip
      end

      payload
    end
  end
end
