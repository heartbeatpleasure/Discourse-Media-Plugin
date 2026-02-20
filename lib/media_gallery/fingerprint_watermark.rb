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

    # Layout modes:
    # - v1_tiles: 6 independent tiles spread across the frame (legacy)
    # - v2_pairs: 3 adjacent tile-pairs (one light, one dark) for easier forensic extraction
    LAYOUT_V1 = "v1_tiles"
    LAYOUT_V2 = "v2_pairs"

    # Conservative defaults; intentionally subtle.
    V1_BOX_COUNT = 6
    V1_BOX_SIZE_FRAC = 0.12 # 12% of width/height
    V2_PAIR_COUNT = 3
    V2_BOX_SIZE_FRAC = 0.12
    OPACITY = 0.006 # 0.6% alpha

    # Keep away from the borders so mild crops don't remove everything.
    MARGIN = 0.06

    def layout_mode
      if SiteSetting.respond_to?(:media_gallery_fingerprint_watermark_layout)
        v = SiteSetting.media_gallery_fingerprint_watermark_layout.to_s
        return v if [LAYOUT_V1, LAYOUT_V2].include?(v)
      end

      LAYOUT_V1
    rescue
      LAYOUT_V1
    end

    def vf_for(media_item_id:, variant:)
      v = variant.to_s.downcase
      v = "a" unless %w[a b].include?(v)

      mode = layout_mode
      if mode == LAYOUT_V2
        vf_pairs(media_item_id: media_item_id, variant: v)
      else
        vf_tiles(media_item_id: media_item_id, variant: v)
      end
    end

    # Exposed for forensic extraction (server-side).
    # Returns a Hash with layout + normalized coordinates.
    def spec_for(media_item_id:)
      mode = layout_mode
      if mode == LAYOUT_V2
        { layout: mode, pairs: v2_pairs_for(media_item_id: media_item_id) }
      else
        { layout: mode, tiles: v1_tiles_for(media_item_id: media_item_id) }
      end
    end

    # ---- v1 ---------------------------------------------------------------

    def vf_tiles(media_item_id:, variant:)
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}", V1_BOX_COUNT * 8)

      color = (variant == "a") ? "white" : "black"
      alpha = OPACITY

      tiles = v1_tiles_for(media_item_id: media_item_id, seed_bytes: seed_bytes)
      tiles.map do |t|
        "drawbox=x=iw*#{t[:x]}:y=ih*#{t[:y]}:w=iw*#{V1_BOX_SIZE_FRAC}:h=ih*#{V1_BOX_SIZE_FRAC}:color=#{color}@#{alpha}:t=fill"
      end.join(",")
    end
    private_class_method :vf_tiles

    def v1_tiles_for(media_item_id:, seed_bytes: nil)
      secret = fingerprint_secret
      seed_bytes ||= prng_bytes(secret, "wm|#{SALT}|#{media_item_id}", V1_BOX_COUNT * 8)

      max_x = 1.0 - MARGIN - V1_BOX_SIZE_FRAC
      max_y = 1.0 - MARGIN - V1_BOX_SIZE_FRAC
      span_x = [max_x - MARGIN, 0.001].max
      span_y = [max_y - MARGIN, 0.001].max

      out = []
      V1_BOX_COUNT.times do |i|
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (MARGIN + span_x * x_r).round(6)
        y = (MARGIN + span_y * y_r).round(6)

        out << { x: x, y: y }
      end
      out
    end
    private_class_method :v1_tiles_for

    # ---- v2 ---------------------------------------------------------------

    def vf_pairs(media_item_id:, variant:)
      alpha = OPACITY
      pairs = v2_pairs_for(media_item_id: media_item_id)

      # v2: each pair is two adjacent boxes; variant decides which side is light/dark.
      light = "white"
      dark = "black"

      filters = []
      pairs.each do |p|
        left_color = (variant == "a") ? light : dark
        right_color = (variant == "a") ? dark : light

        x = p[:x]
        y = p[:y]
        w = V2_BOX_SIZE_FRAC
        h = V2_BOX_SIZE_FRAC

        # left box
        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=#{left_color}@#{alpha}:t=fill"
        # right box (adjacent)
        filters << "drawbox=x=iw*#{(x + w).round(6)}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=#{right_color}@#{alpha}:t=fill"
      end

      filters.join(",")
    end
    private_class_method :vf_pairs

    def v2_pairs_for(media_item_id:)
      # For v2 we keep the same PRNG seed, but we place PAIRS (two boxes wide).
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v2", V2_PAIR_COUNT * 8)

      pair_w = (V2_BOX_SIZE_FRAC * 2.0)
      max_x = 1.0 - MARGIN - pair_w
      max_y = 1.0 - MARGIN - V2_BOX_SIZE_FRAC
      span_x = [max_x - MARGIN, 0.001].max
      span_y = [max_y - MARGIN, 0.001].max

      out = []
      V2_PAIR_COUNT.times do |i|
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (MARGIN + span_x * x_r).round(6)
        y = (MARGIN + span_y * y_r).round(6)

        out << { x: x, y: y }
      end
      out
    end
    private_class_method :v2_pairs_for

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
