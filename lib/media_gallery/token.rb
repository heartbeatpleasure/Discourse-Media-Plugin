# frozen_string_literal: true

require "base64"

module ::MediaGallery
  module Token
    module_function

    def verifier
      # Uses Rails secret_key_base under the hood; scoped by purpose.
      Rails.application.message_verifier("media_gallery_stream")
    end

    def ttl_seconds
      SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
    end

    def generate(payload)
      signed = verifier.generate(payload)
      Base64.urlsafe_encode64(signed, padding: false)
    end

    # Returns the decoded payload Hash if valid, otherwise nil.
    # Enforces signature + expiration.
    def verify(token)
      signed = Base64.urlsafe_decode64(token.to_s)
      payload = verifier.verify(signed)

      return nil unless payload.is_a?(Hash)

      exp = payload["exp"].to_i
      return nil if exp <= 0
      return nil if Time.now.to_i > exp

      payload
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def build_stream_payload(media_item:, upload_id:, kind:, user:, request:)
      exp = Time.now.to_i + ttl_seconds

      payload = {
        "media_item_id" => media_item.id,
        "upload_id" => upload_id,
        "kind" => kind,
        "exp" => exp
      }

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
