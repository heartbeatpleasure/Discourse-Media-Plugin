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
    # - v3_pairs: more (smaller) pairs for higher SNR / robustness on short clips
    LAYOUT_V1 = "v1_tiles"
    LAYOUT_V2 = "v2_pairs"
    LAYOUT_V3 = "v3_pairs"
    LAYOUT_V4 = "v4_pairs"
    LAYOUT_V5 = "v5_screen_safe"
    LAYOUT_V6 = "v6_local_sync"

    # Conservative defaults; intentionally subtle.
    V1_BOX_COUNT = 6
    V1_BOX_SIZE_FRAC = 0.12 # 12% of width/height
    V2_PAIR_COUNT = 3
    V2_BOX_SIZE_FRAC = 0.12
    # v3 uses more redundancy + a slightly stronger alpha, but smaller boxes.
    V3_PAIR_COUNT = 8
    V3_BOX_SIZE_FRAC = 0.085

    # v4: "edge biased" pairs to avoid the common visible watermark band (center)
    # and reduce content-bias flips on screen recordings.
    V4_PAIR_COUNT = 16
    V4_BOX_SIZE_FRAC = 0.065

    # v5: screen-safe layout with more distributed payload cells and a denser,
    # separate sync channel in safe side/top/bottom zones.
    V5_PAIR_COUNT = 20
    V5_BOX_SIZE_FRAC = 0.058

    V6_PAIR_COUNT = 24
    V6_BOX_SIZE_FRAC = 0.054

    # Periodic sync beacons, identical in A and B, used to make reference-based
    # alignment more robust without sacrificing user-specific A/B capacity.
    #
    # We keep these away from the extreme corners and away from the common visible
    # watermark band in the center. The pattern repeats, so trimmed clips can still
    # lock onto the next beacon cycle later in the video.
    V4_SYNC_PAIR_COUNT = 4
    V4_SYNC_OPACITY = 0.006
    V4_SYNC_PATTERN = %w[a a a b b a b a b b a].freeze

    V5_SYNC_PAIR_COUNT = 6
    V5_SYNC_OPACITY = 0.0085
    V5_SYNC_PATTERN = %w[a a b b a b a a].freeze

    V6_SYNC_PAIR_COUNT = 8
    V6_SYNC_OPACITY = 0.0092
    V6_SYNC_PATTERN = %w[a a b b a b a a b a b b].freeze

    V2_OPACITY = 0.006 # 0.6% alpha
    V3_OPACITY = 0.010 # 1.0% alpha
    V4_OPACITY = 0.010 # 1.0% alpha
    V5_OPACITY = 0.011 # 1.1% alpha
    V6_OPACITY = 0.0115 # 1.15% alpha

    # Keep away from the borders so mild crops don't remove everything.
    V1_MARGIN = 0.06
    V2_MARGIN = 0.06
    V3_MARGIN = 0.08
    V4_MARGIN = 0.07
    V5_MARGIN = 0.065
    V6_MARGIN = 0.06

    def allowed_layouts
      [LAYOUT_V1, LAYOUT_V2, LAYOUT_V3, LAYOUT_V4, LAYOUT_V5, LAYOUT_V6]
    end
    private_class_method :allowed_layouts

    def layout_mode
      if SiteSetting.respond_to?(:media_gallery_fingerprint_watermark_layout)
        v = SiteSetting.media_gallery_fingerprint_watermark_layout.to_s
        return v if allowed_layouts.include?(v)
      end

      LAYOUT_V1
    rescue
      LAYOUT_V1
    end

    def vf_for(media_item_id:, variant:)
      v = variant.to_s.downcase
      v = "a" unless %w[a b].include?(v)

      mode = layout_mode
      if mode == LAYOUT_V2 || mode == LAYOUT_V3 || mode == LAYOUT_V4 || mode == LAYOUT_V5 || mode == LAYOUT_V6
        vf_pairs(media_item_id: media_item_id, variant: v, layout: mode)
      else
        vf_tiles(media_item_id: media_item_id, variant: v)
      end
    end

    # Exposed for forensic extraction (server-side).
    # Returns a Hash with layout + normalized coordinates.
    def spec_for(media_item_id:, layout: nil)
      mode = layout.to_s.presence || layout_mode
      mode = layout_mode unless allowed_layouts.include?(mode)

      case mode
      when LAYOUT_V2
        {
          layout: mode,
          kind: "pairs",
          opacity: V2_OPACITY,
          box_size_frac: V2_BOX_SIZE_FRAC,
          margin: V2_MARGIN,
          pairs: v2_pairs_for(media_item_id: media_item_id)
        }
      when LAYOUT_V3
        {
          layout: mode,
          kind: "pairs",
          opacity: V3_OPACITY,
          box_size_frac: V3_BOX_SIZE_FRAC,
          margin: V3_MARGIN,
          pairs: v3_pairs_for(media_item_id: media_item_id)
        }
      when LAYOUT_V4
        {
          layout: mode,
          kind: "pairs",
          opacity: V4_OPACITY,
          box_size_frac: V4_BOX_SIZE_FRAC,
          margin: V4_MARGIN,
          pairs: v4_pairs_for(media_item_id: media_item_id),
          sync_pairs: v4_sync_pairs,
          sync_pattern: v4_sync_pattern,
          sync_period: v4_sync_pattern.length,
          sync_opacity: V4_SYNC_OPACITY,
          sync_box_size_frac: V4_BOX_SIZE_FRAC
        }
      when LAYOUT_V5
        {
          layout: mode,
          kind: "pairs",
          opacity: V5_OPACITY,
          box_size_frac: V5_BOX_SIZE_FRAC,
          margin: V5_MARGIN,
          pairs: v5_pairs_for(media_item_id: media_item_id),
          sync_pairs: v5_sync_pairs,
          sync_pattern: v5_sync_pattern,
          sync_period: v5_sync_pattern.length,
          sync_opacity: V5_SYNC_OPACITY,
          sync_box_size_frac: V5_BOX_SIZE_FRAC
        }
      when LAYOUT_V6
        {
          layout: mode,
          kind: "pairs",
          opacity: V6_OPACITY,
          box_size_frac: V6_BOX_SIZE_FRAC,
          margin: V6_MARGIN,
          pairs: v6_pairs_for(media_item_id: media_item_id),
          sync_pairs: v6_sync_pairs,
          sync_pattern: v6_sync_pattern,
          sync_period: v6_sync_pattern.length,
          sync_opacity: V6_SYNC_OPACITY,
          sync_box_size_frac: V6_BOX_SIZE_FRAC
        }
      else
        {
          layout: mode,
          kind: "tiles",
          opacity: V2_OPACITY,
          box_size_frac: V1_BOX_SIZE_FRAC,
          margin: V1_MARGIN,
          tiles: v1_tiles_for(media_item_id: media_item_id)
        }
      end
    end

    # ---- v1 ---------------------------------------------------------------

    def vf_tiles(media_item_id:, variant:)
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}", V1_BOX_COUNT * 8)

      color = (variant == "a") ? "white" : "black"
      alpha = V2_OPACITY

      tiles = v1_tiles_for(media_item_id: media_item_id, seed_bytes: seed_bytes)
      tiles.map do |t|
        "drawbox=x=iw*#{t[:x]}:y=ih*#{t[:y]}:w=iw*#{V1_BOX_SIZE_FRAC}:h=ih*#{V1_BOX_SIZE_FRAC}:color=#{color}@#{alpha}:t=fill"
      end.join(",")
    end
    private_class_method :vf_tiles

    def v1_tiles_for(media_item_id:, seed_bytes: nil)
      secret = fingerprint_secret
      seed_bytes ||= prng_bytes(secret, "wm|#{SALT}|#{media_item_id}", V1_BOX_COUNT * 8)

      max_x = 1.0 - V1_MARGIN - V1_BOX_SIZE_FRAC
      max_y = 1.0 - V1_MARGIN - V1_BOX_SIZE_FRAC
      span_x = [max_x - V1_MARGIN, 0.001].max
      span_y = [max_y - V1_MARGIN, 0.001].max

      out = []
      V1_BOX_COUNT.times do |i|
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (V1_MARGIN + span_x * x_r).round(6)
        y = (V1_MARGIN + span_y * y_r).round(6)

        out << { x: x, y: y }
      end
      out
    end
    private_class_method :v1_tiles_for

    # ---- v2 ---------------------------------------------------------------

    def vf_pairs(media_item_id:, variant:, layout:)
      layout = layout.to_s
      layout = LAYOUT_V2 unless [LAYOUT_V2, LAYOUT_V3, LAYOUT_V4, LAYOUT_V5, LAYOUT_V6].include?(layout)

      alpha = if layout == LAYOUT_V6
        V6_OPACITY
      elsif layout == LAYOUT_V5
        V5_OPACITY
      elsif layout == LAYOUT_V4
        V4_OPACITY
      elsif layout == LAYOUT_V3
        V3_OPACITY
      else
        V2_OPACITY
      end
      box = if layout == LAYOUT_V6
        V6_BOX_SIZE_FRAC
      elsif layout == LAYOUT_V5
        V5_BOX_SIZE_FRAC
      elsif layout == LAYOUT_V4
        V4_BOX_SIZE_FRAC
      elsif layout == LAYOUT_V3
        V3_BOX_SIZE_FRAC
      else
        V2_BOX_SIZE_FRAC
      end
      pairs = if layout == LAYOUT_V6
        v6_pairs_for(media_item_id: media_item_id)
      elsif layout == LAYOUT_V5
        v5_pairs_for(media_item_id: media_item_id)
      elsif layout == LAYOUT_V4
        v4_pairs_for(media_item_id: media_item_id)
      elsif layout == LAYOUT_V3
        v3_pairs_for(media_item_id: media_item_id)
      else
        v2_pairs_for(media_item_id: media_item_id)
      end

      # v2: each pair is two adjacent boxes; variant decides which side is light/dark.
      light = "white"
      dark = "black"

      filters = []
      pairs.each do |p|
        left_color = (variant == "a") ? light : dark
        right_color = (variant == "a") ? dark : light

        x = p[:x]
        y = p[:y]
        w = box
        h = box

        # left box
        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=#{left_color}@#{alpha}:t=fill"
        # right box (adjacent)
        filters << "drawbox=x=iw*#{(x + w).round(6)}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=#{right_color}@#{alpha}:t=fill"
      end

      if layout == LAYOUT_V4 || layout == LAYOUT_V5 || layout == LAYOUT_V6
        filters.concat(sync_filters_for_layout(layout: layout, box: box))
      end

      filters.join(",")
    end
    private_class_method :vf_pairs

    def v2_pairs_for(media_item_id:)
      # For v2 we keep the same PRNG seed, but we place PAIRS (two boxes wide).
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v2", V2_PAIR_COUNT * 8)

      pair_w = (V2_BOX_SIZE_FRAC * 2.0)
      max_x = 1.0 - V2_MARGIN - pair_w
      max_y = 1.0 - V2_MARGIN - V2_BOX_SIZE_FRAC
      span_x = [max_x - V2_MARGIN, 0.001].max
      span_y = [max_y - V2_MARGIN, 0.001].max

      out = []
      V2_PAIR_COUNT.times do |i|
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (V2_MARGIN + span_x * x_r).round(6)
        y = (V2_MARGIN + span_y * y_r).round(6)

        out << { x: x, y: y }
      end
      out
    end
    private_class_method :v2_pairs_for

    def v3_pairs_for(media_item_id:)
      # Like v2, but with more (smaller) pairs and a slightly larger margin.
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v3", V3_PAIR_COUNT * 8)

      pair_w = (V3_BOX_SIZE_FRAC * 2.0)
      max_x = 1.0 - V3_MARGIN - pair_w
      max_y = 1.0 - V3_MARGIN - V3_BOX_SIZE_FRAC
      span_x = [max_x - V3_MARGIN, 0.001].max
      span_y = [max_y - V3_MARGIN, 0.001].max

      out = []
      V3_PAIR_COUNT.times do |i|
        x_r = u32_to_unit(seed_bytes, i * 8)
        y_r = u32_to_unit(seed_bytes, i * 8 + 4)

        x = (V3_MARGIN + span_x * x_r).round(6)
        y = (V3_MARGIN + span_y * y_r).round(6)

        out << { x: x, y: y }
      end
      out
    end
    private_class_method :v3_pairs_for

    def v4_pairs_for(media_item_id:)
      # v4: place many small pairs near the top/bottom bands to avoid the common visible watermark region (center),
      # and to reduce content-bias flips on screen recordings.
      #
      # We sample within two "safe" Y bands by default:
      # - top:    ~[V4_MARGIN .. 0.30]
      # - bottom: ~[0.70 .. 1 - V4_MARGIN - box]
      #
      # Additionally, we exclude a coarse region based on the visible watermark position setting.
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v4", V4_PAIR_COUNT * 12)

      box = V4_BOX_SIZE_FRAC
      pair_w = (box * 2.0)

      # X range (leave margins + room for full pair width)
      max_x = 1.0 - V4_MARGIN - pair_w
      span_x = [max_x - V4_MARGIN, 0.001].max

      # Safe Y bands
      top_min = V4_MARGIN
      top_max = 0.30 - box
      bot_min = 0.70
      bot_max = 1.0 - V4_MARGIN - box

      top_span = [top_max - top_min, 0.001].max
      bot_span = [bot_max - bot_min, 0.001].max

      excluded = visible_watermark_exclusion_rects(box: box, pair_w: pair_w)
      excluded += v4_sync_pairs.map { |p| { x: p[:x], y: p[:y], w: pair_w, h: box } }

      out = []
      occupied = []

      V4_PAIR_COUNT.times do |i|
        # We allow a few retries to avoid exclusions/overlaps.
        placed = false
        12.times do |try|
          # use different offsets into seed bytes for retries
          off = (i * 12) + (try % 3) * 4

          x_r = u32_to_unit(seed_bytes, off)
          y_r = u32_to_unit(seed_bytes, off + 4)
          j_r = u32_to_unit(seed_bytes, off + 8)

          x = (V4_MARGIN + span_x * x_r).round(6)

          # Choose band by y_r, jitter inside band by j_r
          if y_r < 0.5
            y = (top_min + top_span * j_r).round(6)
          else
            y = (bot_min + bot_span * j_r).round(6)
          end

          # Clamp
          x = [[x, V4_MARGIN].max, max_x].min.round(6)
          y = [[y, V4_MARGIN].max, 1.0 - V4_MARGIN - box].min.round(6)

          rect = { x: x, y: y, w: pair_w, h: box }

          next if rect_overlaps_any?(rect, excluded)

          # Avoid overlapping with previously placed pairs (simple AABB overlap with small padding)
          pad = (box * 0.20).round(6)
          padded = { x: (x - pad), y: (y - pad), w: (pair_w + 2 * pad), h: (box + 2 * pad) }
          next if rect_overlaps_any?(padded, occupied)

          occupied << rect
          out << { x: x, y: y }
          placed = true
          break
        end

        # Fallback: if we couldn't place, just place deterministically in the bands.
        unless placed
          x = (V4_MARGIN + span_x * (i.to_f / [V4_PAIR_COUNT - 1, 1].max)).round(6)
          y = (i.even? ? (top_min + top_span * 0.5) : (bot_min + bot_span * 0.5)).round(6)
          out << { x: x, y: y }
        end
      end

      out
    end
    private_class_method :v4_pairs_for

    def v5_pairs_for(media_item_id:)
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v5", V5_PAIR_COUNT * 12)

      box = V5_BOX_SIZE_FRAC
      pair_w = (box * 2.0)
      margin = V5_MARGIN

      excluded = visible_watermark_exclusion_rects(box: box, pair_w: pair_w)
      excluded += v5_sync_pairs.map { |p| { x: p[:x], y: p[:y], w: pair_w, h: box } }

      bands = [
        { x_min: margin, x_max: 0.40 - pair_w, y_min: margin, y_max: 0.20 - box },
        { x_min: 0.60, x_max: 1.0 - margin - pair_w, y_min: margin, y_max: 0.20 - box },
        { x_min: margin, x_max: 0.26 - pair_w, y_min: 0.34, y_max: 0.48 - box },
        { x_min: 0.74, x_max: 1.0 - margin - pair_w, y_min: 0.34, y_max: 0.48 - box },
        { x_min: margin, x_max: 0.40 - pair_w, y_min: 0.72, y_max: 1.0 - margin - box },
        { x_min: 0.60, x_max: 1.0 - margin - pair_w, y_min: 0.72, y_max: 1.0 - margin - box }
      ].map do |band|
        band.merge(
          x_max: [band[:x_max], band[:x_min] + 0.001].max,
          y_max: [band[:y_max], band[:y_min] + 0.001].max
        )
      end

      occupied = []
      out = []

      V5_PAIR_COUNT.times do |i|
        placed = false
        16.times do |try|
          off = (i * 12) + ((try % 3) * 4)
          band = bands[(i + try) % bands.length]
          x_r = u32_to_unit(seed_bytes, off)
          y_r = u32_to_unit(seed_bytes, off + 4)

          span_x = [band[:x_max] - band[:x_min], 0.001].max
          span_y = [band[:y_max] - band[:y_min], 0.001].max
          x = (band[:x_min] + span_x * x_r).round(6)
          y = (band[:y_min] + span_y * y_r).round(6)
          rect = { x: x, y: y, w: pair_w, h: box }
          next if rect_overlaps_any?(rect, excluded)

          pad = (box * 0.18).round(6)
          padded = { x: (x - pad), y: (y - pad), w: (pair_w + 2 * pad), h: (box + 2 * pad) }
          next if rect_overlaps_any?(padded, occupied)

          occupied << rect
          out << { x: x, y: y }
          placed = true
          break
        end

        next if placed

        band = bands[i % bands.length]
        x = (band[:x_min] + ([band[:x_max] - band[:x_min], 0.001].max * 0.5)).round(6)
        y = (band[:y_min] + ([band[:y_max] - band[:y_min], 0.001].max * 0.5)).round(6)
        out << { x: x, y: y }
      end

      out
    end
    private_class_method :v5_pairs_for

    def v6_pairs_for(media_item_id:)
      secret = fingerprint_secret
      seed_bytes = prng_bytes(secret, "wm|#{SALT}|#{media_item_id}|v6", V6_PAIR_COUNT * 12)

      box = V6_BOX_SIZE_FRAC
      pair_w = (box * 2.0)
      margin = V6_MARGIN

      excluded = visible_watermark_exclusion_rects(box: box, pair_w: pair_w)
      excluded += v6_sync_pairs.map { |p| { x: p[:x], y: p[:y], w: pair_w, h: box } }

      bands = [
        { x_min: margin, x_max: 0.34 - pair_w, y_min: margin, y_max: 0.18 - box },
        { x_min: 0.40, x_max: 0.60 - pair_w, y_min: margin, y_max: 0.18 - box },
        { x_min: 0.66, x_max: 1.0 - margin - pair_w, y_min: margin, y_max: 0.18 - box },
        { x_min: margin, x_max: 0.22 - pair_w, y_min: 0.28, y_max: 0.48 - box },
        { x_min: 0.78, x_max: 1.0 - margin - pair_w, y_min: 0.28, y_max: 0.48 - box },
        { x_min: margin, x_max: 0.22 - pair_w, y_min: 0.58, y_max: 0.80 - box },
        { x_min: 0.78, x_max: 1.0 - margin - pair_w, y_min: 0.58, y_max: 0.80 - box },
        { x_min: margin, x_max: 0.34 - pair_w, y_min: 0.84 - box, y_max: 1.0 - margin - box },
        { x_min: 0.40, x_max: 0.60 - pair_w, y_min: 0.84 - box, y_max: 1.0 - margin - box },
        { x_min: 0.66, x_max: 1.0 - margin - pair_w, y_min: 0.84 - box, y_max: 1.0 - margin - box }
      ].map do |band|
        band.merge(
          x_max: [band[:x_max], band[:x_min] + 0.001].max,
          y_max: [band[:y_max], band[:y_min] + 0.001].max
        )
      end

      occupied = []
      out = []

      V6_PAIR_COUNT.times do |i|
        placed = false
        18.times do |try|
          off = (i * 12) + ((try % 3) * 4)
          band = bands[(i + try) % bands.length]
          x_r = u32_to_unit(seed_bytes, off)
          y_r = u32_to_unit(seed_bytes, off + 4)

          span_x = [band[:x_max] - band[:x_min], 0.001].max
          span_y = [band[:y_max] - band[:y_min], 0.001].max
          x = (band[:x_min] + span_x * x_r).round(6)
          y = (band[:y_min] + span_y * y_r).round(6)
          rect = { x: x, y: y, w: pair_w, h: box }
          next if rect_overlaps_any?(rect, excluded)

          pad = (box * 0.16).round(6)
          padded = { x: (x - pad), y: (y - pad), w: (pair_w + 2 * pad), h: (box + 2 * pad) }
          next if rect_overlaps_any?(padded, occupied)

          occupied << rect
          out << { x: x, y: y }
          placed = true
          break
        end

        next if placed

        band = bands[i % bands.length]
        x = (band[:x_min] + ([band[:x_max] - band[:x_min], 0.001].max * 0.5)).round(6)
        y = (band[:y_min] + ([band[:y_max] - band[:y_min], 0.001].max * 0.5)).round(6)
        out << { x: x, y: y }
      end

      out
    end
    private_class_method :v6_pairs_for

    def v4_sync_pairs
      [
        { x: 0.16, y: 0.17 },
        { x: 0.68, y: 0.17 },
        { x: 0.16, y: 0.76 },
        { x: 0.68, y: 0.76 }
      ]
    end
    private_class_method :v4_sync_pairs

    def v4_sync_pattern
      V4_SYNC_PATTERN
    end
    private_class_method :v4_sync_pattern

    def sync_segment_seconds
      seg = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      seg = 6 if seg <= 0
      seg
    rescue
      6
    end
    private_class_method :sync_segment_seconds

    def v5_sync_pairs
      [
        { x: 0.12, y: 0.14 },
        { x: 0.68, y: 0.14 },
        { x: 0.08, y: 0.40 },
        { x: 0.78, y: 0.40 },
        { x: 0.12, y: 0.80 },
        { x: 0.68, y: 0.80 }
      ]
    end

    def v6_sync_pairs
      [
        { x: 0.10, y: 0.12 },
        { x: 0.42, y: 0.12 },
        { x: 0.74, y: 0.12 },
        { x: 0.06, y: 0.42 },
        { x: 0.82, y: 0.42 },
        { x: 0.06, y: 0.78 },
        { x: 0.42, y: 0.78 },
        { x: 0.74, y: 0.78 }
      ]
    end
    private_class_method :v5_sync_pairs

    def v5_sync_pattern
      V5_SYNC_PATTERN
    end

    def v6_sync_pattern
      V6_SYNC_PATTERN
    end
    private_class_method :v5_sync_pattern

    def sync_pairs_for_layout(layout)
      case layout.to_s
      when LAYOUT_V6
        v6_sync_pairs
      when LAYOUT_V5
        v5_sync_pairs
      else
        v4_sync_pairs
      end
    end
    private_class_method :sync_pairs_for_layout

    def sync_pattern_for_layout(layout)
      case layout.to_s
      when LAYOUT_V6
        v6_sync_pattern
      when LAYOUT_V5
        v5_sync_pattern
      else
        v4_sync_pattern
      end
    end
    private_class_method :sync_pattern_for_layout

    def sync_opacity_for_layout(layout)
      case layout.to_s
      when LAYOUT_V6
        V6_SYNC_OPACITY
      when LAYOUT_V5
        V5_SYNC_OPACITY
      else
        V4_SYNC_OPACITY
      end
    end
    private_class_method :sync_opacity_for_layout

    def sync_enable_expr_for_layout(layout:, sync_variant:)
      pattern = sync_pattern_for_layout(layout)
      mods = []
      pattern.each_with_index do |vv, idx|
        mods << idx if vv.to_s == sync_variant.to_s
      end
      return nil if mods.empty?

      seg = sync_segment_seconds
      period = pattern.length
      checks = mods.map { |m| "eq(mod(floor(t/#{seg}),#{period}),#{m})" }
      checks.join("+")
    end
    private_class_method :sync_enable_expr_for_layout

    def sync_filters_for_layout(layout:, box:)
      w = box.to_f.round(6)
      h = w
      alpha = sync_opacity_for_layout(layout)
      enable_a = sync_enable_expr_for_layout(layout: layout, sync_variant: "a")
      enable_b = sync_enable_expr_for_layout(layout: layout, sync_variant: "b")
      return [] if enable_a.blank? || enable_b.blank?

      filters = []
      sync_pairs_for_layout(layout).each do |p|
        x = p[:x].to_f.round(6)
        y = p[:y].to_f.round(6)
        xr = (x + w).round(6)

        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=white@#{alpha}:t=fill:enable='#{enable_a}'"
        filters << "drawbox=x=iw*#{xr}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=black@#{alpha}:t=fill:enable='#{enable_a}'"
        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=black@#{alpha}:t=fill:enable='#{enable_b}'"
        filters << "drawbox=x=iw*#{xr}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=white@#{alpha}:t=fill:enable='#{enable_b}'"
      end

      filters
    end
    private_class_method :sync_filters_for_layout

    def sync_enable_expr(sync_variant)
      mods = []
      v4_sync_pattern.each_with_index do |vv, idx|
        mods << idx if vv.to_s == sync_variant.to_s
      end
      return nil if mods.empty?

      seg = sync_segment_seconds
      period = v4_sync_pattern.length
      checks = mods.map { |m| "eq(mod(floor(t/#{seg}),#{period}),#{m})" }
      checks.join("+")
    end
    private_class_method :sync_enable_expr

    def v4_sync_filters(box:)
      w = box.to_f.round(6)
      h = w
      alpha = V4_SYNC_OPACITY
      enable_a = sync_enable_expr("a")
      enable_b = sync_enable_expr("b")
      return [] if enable_a.blank? || enable_b.blank?

      filters = []
      v4_sync_pairs.each do |p|
        x = p[:x].to_f.round(6)
        y = p[:y].to_f.round(6)
        xr = (x + w).round(6)

        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=white@#{alpha}:t=fill:enable='#{enable_a}'"
        filters << "drawbox=x=iw*#{xr}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=black@#{alpha}:t=fill:enable='#{enable_a}'"
        filters << "drawbox=x=iw*#{x}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=black@#{alpha}:t=fill:enable='#{enable_b}'"
        filters << "drawbox=x=iw*#{xr}:y=ih*#{y}:w=iw*#{w}:h=ih*#{h}:color=white@#{alpha}:t=fill:enable='#{enable_b}'"
      end

      filters
    end
    private_class_method :v4_sync_filters

    def visible_watermark_exclusion_rects(box:, pair_w:)
      # Coarse exclusion rectangles based on the visible watermark position.
      # We intentionally keep this conservative: the goal is to reduce overlap risk, not perfectly model drawtext bounds.
      pos = nil
      begin
        pos = SiteSetting.media_gallery_watermark_position.to_s
      rescue
        pos = nil
      end

      rects = []
      case pos
      when "center"
        rects << { x: 0.0, y: 0.35, w: 1.0, h: 0.30 }
      when "top_center"
        rects << { x: 0.0, y: 0.0, w: 1.0, h: 0.25 }
      when "bottom_center"
        rects << { x: 0.0, y: 0.75, w: 1.0, h: 0.25 }
      when "top_left"
        rects << { x: 0.0, y: 0.0, w: 0.45, h: 0.30 }
      when "top_right"
        rects << { x: 0.55, y: 0.0, w: 0.45, h: 0.30 }
      when "bottom_left"
        rects << { x: 0.0, y: 0.70, w: 0.45, h: 0.30 }
      when "bottom_right"
        rects << { x: 0.55, y: 0.70, w: 0.45, h: 0.30 }
      else
        # no exclusion
      end

      rects
    end
    private_class_method :visible_watermark_exclusion_rects

    def rect_overlaps_any?(rect, rects)
      rects.any? do |r|
        rects_overlap?(rect, r)
      end
    end
    private_class_method :rect_overlaps_any?

    def rects_overlap?(a, b)
      ax1 = a[:x].to_f
      ay1 = a[:y].to_f
      ax2 = ax1 + a[:w].to_f
      ay2 = ay1 + a[:h].to_f

      bx1 = b[:x].to_f
      by1 = b[:y].to_f
      bx2 = bx1 + b[:w].to_f
      by2 = by1 + b[:h].to_f

      return false if ax2 <= bx1 || bx2 <= ax1
      return false if ay2 <= by1 || by2 <= ay1
      true
    end
    private_class_method :rects_overlap?

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
