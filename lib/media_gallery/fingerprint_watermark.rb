# frozen_string_literal: true

require "openssl"

module ::MediaGallery
  # Creates *subtle* per-video watermark differences for A/B HLS variants.
  #
  # Design goals:
  # - Not "visibly" obvious during normal playback
  # - Deterministic (recomputable later) using the fingerprint secret + media_item_id
  # - Resolution-agnostic (positions expressed as fractions of iw/ih)
  #
  # NOTE: This is not DRM. It's a lightweight forensic signal.
  module FingerprintWatermark
    module_function

    SALT = "media_gallery_fingerprint_watermark_v1"

    # Conservative defaults; intentionally tiny.
    BOX_COUNT = 6
    BOX_SIZE_FRAC = 0.12 # 12% of width/height
    OPACITY = 0.006      # 0.6% alpha

    # Keep away from the borders so mild crops don't remove everything.
    MARGIN = 0.06

    def vf_for(media_item_id:, variant:)
      v = variant.to_s.downcase
      v = "a" unless %w[a b].include?(v)

      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}", BOX_COUNT * 8)

      color = (v == "a") ? "white" : "black"
      alpha = OPACITY

      # Spread boxes across the frame deterministically.
      filters = []
      max_x = 1.0 - MARGIN - BOX_SIZE_FRAC
      max_y = 1.0 - MARGIN - BOX_SIZE_FRAC
      span_x = [max_x - MARGIN, 0.001].max
      span_y = [max_y - MARGIN, 0.001].max

      BOX_COUNT.times do |i|
        # 4 bytes -> x, 4 bytes -> y
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (MARGIN + span_x * x_r).round(6)
        y = (MARGIN + span_y * y_r).round(6)

        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{BOX_SIZE_FRAC}:h=ih*#{BOX_SIZE_FRAC}:color=#{color}@#{alpha}:t=fill"
      end

      filters.join(",")
    end

    # ---- helpers -----------------------------------------------------------

    def fingerprint_secret
      if defined?(::MediaGallery::Fingerprinting) && ::MediaGallery::Fingerprinting.respond_to?(:secret)
        ::MediaGallery::Fingerprinting.secret.to_s
      else
        Rails.application.secret_key_base.to_s
      end
    rescue
      Rails.application.secret_key_base.to_s
    end
    private_class_method :fingerprint_secret

    def prng_bytes(secret, label, needed)
      out = +""
      ctr = 0
      while out.bytesize < needed
        out << OpenSSL::HMAC.digest("SHA256", secret, "#{label}|#{ctr}")
        ctr += 1
      end
      out.byteslice(0, needed)
    end
    private_class_method :prng_bytes

    def u32_to_unit(bytes, offset)
      b = bytes.byteslice(offset, 4)
      return 0.0 if b.nil? || b.bytesize < 4

      n = b.unpack1("N") # unsigned 32-bit big-endian
      n.to_f / 4_294_967_296.0
    end
    private_class_method :u32_to_unit
  end
end
