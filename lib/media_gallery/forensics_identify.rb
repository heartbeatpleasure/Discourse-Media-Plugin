# frozen_string_literal: true

require "open3"
require "json"

module ::MediaGallery
  # Admin-only helper to identify which fingerprint/user likely leaked a video.
  #
  # Workflow:
  # 1) Admin uploads a leaked copy (any common container/codec).
  # 2) We sample frames at segment midpoints and try to classify each segment as variant A or B
  #    using the watermark layout.
  # 3) We compare the observed A/B pattern against all known fingerprint_ids for this media_item.
  #
  # This is NOT DRM; it is best-effort forensics. Re-encoding/cropping can reduce confidence.
  module ForensicsIdentify
    module_function

    DEFAULT_MAX_SAMPLES = 60
    DEFAULT_MAX_OFFSET_SEGMENTS = 30

    # If the signal is too weak, we return nil bits for that sample.
    MIN_CONFIDENCE = 0.005

    # If a single-frame sample is weak, we automatically resample nearby frames
    # (still within the same segment) and aggregate.
    RESAMPLE_MIN_CONFIDENCE = 0.012

    def identify_from_file(media_item:, file_path:, max_samples: DEFAULT_MAX_SAMPLES, max_offset_segments: DEFAULT_MAX_OFFSET_SEGMENTS, layout: nil)
      raise ArgumentError, "missing media_item" if media_item.blank?
      raise ArgumentError, "missing file" if file_path.blank? || !File.exist?(file_path)

      seg = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      seg = 6 if seg <= 0

      packaged = packaged_fingerprint_spec_for(media_item: media_item)
      if packaged
        # Prefer packaged metadata so identify keeps working even if SiteSettings change.
        seg = packaged[:segment_seconds].to_i if packaged[:segment_seconds].to_i > 0
        layout ||= packaged[:layout].to_s.presence
      end

      layout ||= detect_layout_for(media_item: media_item)

      spec =
        if packaged && packaged[:spec].is_a?(Hash) && packaged[:layout].to_s == layout.to_s
          packaged[:spec]
        else
          ::MediaGallery::FingerprintWatermark.spec_for(media_item_id: media_item.id, layout: layout)
        end

      obs = extract_observed_variants(
        file_path: file_path,
        segment_seconds: seg,
        spec: spec,
        max_samples: max_samples
      )

      matches = match_fingerprints(
        media_item: media_item,
        observed_variants: obs[:variants],
        max_offset_segments: max_offset_segments
      )

      {
        meta: {
          public_id: media_item.public_id,
          media_item_id: media_item.id,
          segment_seconds: seg,
          layout: spec[:layout].to_s.presence || layout,
          duration_seconds: obs[:duration_seconds],
          samples: obs[:variants].length,
          usable_samples: obs[:variants].count { |v| v.present? },
        },
        observed: {
          variants: obs[:variants].join(""),
          confidences: obs[:confidences],
        },
        candidates: matches,
      }
    end

    # ----------------------------------------------------------------------

    def detect_layout_for(media_item:)
      # Prefer the metadata file written during packaging.
      begin
        root = ::MediaGallery::PrivateStorage.hls_root_abs_dir(media_item.public_id)
        meta_path = File.join(root, "fingerprint_meta.json")
        if File.exist?(meta_path)
          j = JSON.parse(File.read(meta_path))
          v = j["layout"].to_s
          return v if v.present?
        end
      rescue
        # ignore
      end

      ::MediaGallery::FingerprintWatermark.layout_mode
    end

    def packaged_fingerprint_spec_for(media_item:)
      root = ::MediaGallery::PrivateStorage.hls_root_abs_dir(media_item.public_id)
      meta_path = File.join(root, "fingerprint_meta.json")
      return nil unless File.exist?(meta_path)

      j = JSON.parse(File.read(meta_path)) rescue nil
      return nil unless j.is_a?(Hash)

      spec = j["watermark_spec"]
      spec = symbolize_spec(spec) if spec.is_a?(Hash)
      return nil unless spec.is_a?(Hash) && spec[:layout].to_s.present?

      {
        layout: j["layout"].to_s.presence || spec[:layout].to_s,
        segment_seconds: j["segment_seconds"],
        spec: spec,
      }
    rescue
      nil
    end
    private_class_method :packaged_fingerprint_spec_for

    def symbolize_spec(h)
      out = {}
      h.each { |k, v| out[k.to_sym] = v }

      if out[:pairs].is_a?(Array)
        out[:pairs] = out[:pairs].map { |p| p.is_a?(Hash) ? p.transform_keys(&:to_sym) : p }
      end

      if out[:tiles].is_a?(Array)
        out[:tiles] = out[:tiles].map { |p| p.is_a?(Hash) ? p.transform_keys(&:to_sym) : p }
      end

      out
    end
    private_class_method :symbolize_spec

    def extract_observed_variants(file_path:, segment_seconds:, spec:, max_samples:)
      duration = probe_duration_seconds(file_path)
      duration = 0.0 if duration.nan? || duration.infinite? || duration.negative?

      # Sample at segment midpoints; cap work.
      seg = segment_seconds.to_i
      total = (duration / seg).floor
      total = 0 if total.negative?

      sample_count = [total, max_samples.to_i].min
      sample_count = 0 if sample_count.negative?

      variants = []
      confidences = []

      sample_count.times do |i|
        t = (i + 0.5) * seg
        res = sample_variant_robust(
          file_path: file_path,
          t_mid: t,
          segment_seconds: seg,
          duration_seconds: duration,
          spec: spec
        )

        variants << res[:variant]
        confidences << res[:confidence]
      end

      { duration_seconds: duration, variants: variants, confidences: confidences, layout: spec[:layout].to_s }
    end

    def match_fingerprints(media_item:, observed_variants:, max_offset_segments:)
      fps = ::MediaGallery::MediaFingerprint.where(media_item_id: media_item.id).includes(:user).to_a
      return [] if fps.empty?

      max_off = max_offset_segments.to_i
      max_off = 0 if max_off.negative?

      results = []

      fps.each do |rec|
        best = nil

        (0..max_off).each do |offset|
          mismatches = 0
          compared = 0

          observed_variants.each_with_index do |obs, i|
            next if obs.blank?

            exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
              fingerprint_id: rec.fingerprint_id,
              media_item_id: media_item.id,
              segment_index: i + offset
            )

            compared += 1
            mismatches += 1 if exp != obs
          end

          next if compared == 0

          ratio = mismatches.to_f / compared
          candidate = {
            user_id: rec.user_id,
            username: rec.user&.username,
            fingerprint_id: rec.fingerprint_id,
            best_offset_segments: offset,
            mismatches: mismatches,
            compared: compared,
            match_ratio: (1.0 - ratio).round(4),
          }

          if best.nil? || candidate[:mismatches] < best[:mismatches] ||
               (candidate[:mismatches] == best[:mismatches] && candidate[:compared] > best[:compared])
            best = candidate
          end
        end

        results << best if best
      end

      results.sort_by { |r| [r[:mismatches], -r[:compared]] }.first(10)
    end

    # ----------------------------------------------------------------------

    def probe_duration_seconds(file_path)
      j = ::MediaGallery::Ffmpeg.probe(file_path)
      j.dig("format", "duration").to_f
    rescue
      0.0
    end
    private_class_method :probe_duration_seconds

    def sample_variant_robust(file_path:, t_mid:, segment_seconds:, duration_seconds:, spec:)
      # Fast path: sample once at the midpoint.
      first = sample_variant_single(file_path: file_path, t: t_mid, spec: spec)
      return first if first[:variant].present? && first[:confidence].to_f >= RESAMPLE_MIN_CONFIDENCE

      # Resample nearby points within the segment and aggregate.
      seg = segment_seconds.to_f
      offset = (seg * 0.25).to_f
      offset = 0.25 if offset < 0.25

      times = [t_mid - offset, t_mid, t_mid + offset]
      times = times.map { |t| clamp_time(t, duration_seconds: duration_seconds) }.uniq

      samples = times.map { |t| sample_variant_single(file_path: file_path, t: t, spec: spec) }

      scores = samples.map { |s| s[:score].to_i }
      confs = samples.map { |s| s[:confidence].to_f }

      med_score = median(scores)
      med_conf = median(confs).round(4)

      variant = med_score >= 0 ? "a" : "b"
      variant = nil if med_conf < MIN_CONFIDENCE

      { variant: variant, confidence: med_conf, score: med_score }
    rescue
      { variant: nil, confidence: 0.0, score: 0 }
    end
    private_class_method :sample_variant_robust

    def clamp_time(t, duration_seconds:)
      tt = t.to_f
      tt = 0.0 if tt.negative?
      if duration_seconds.to_f > 0
        max_t = [duration_seconds.to_f - 0.05, 0.0].max
        tt = max_t if tt > max_t
      end
      tt
    end
    private_class_method :clamp_time

    def median(arr)
      a = arr.compact.sort
      return 0 if a.empty?
      a[a.length / 2]
    end
    private_class_method :median

    def sample_variant_single(file_path:, t:, spec:)
      kind = spec[:kind].to_s
      kind = "pairs" if kind.blank? && spec[:pairs].present?
      kind = "tiles" if kind.blank? && spec[:tiles].present?

      if kind == "pairs"
        sample_pair_score(
          file_path: file_path,
          t: t,
          pairs: spec[:pairs] || [],
          box: spec[:box_size_frac].to_f
        )
      else
        sample_tile_score(
          file_path: file_path,
          t: t,
          tiles: spec[:tiles] || [],
          box: spec[:box_size_frac].to_f
        )
      end
    end
    private_class_method :sample_variant_single

    # --------------------- v2 (pairs) --------------------------------------

    def sample_pair_score(file_path:, t:, pairs:, box:)
      pair_count = pairs.length
      return { variant: nil, confidence: 0.0, score: 0 } if pair_count == 0

      box = box.to_f
      box = 0.12 if box <= 0
      pair_w = (box * 2.0).round(6)

      filters = []
      pairs.each_with_index do |p, idx|
        x = p[:x]
        y = p[:y]
        filters << "[0:v]crop=w=iw*#{pair_w}:h=ih*#{box}:x=iw*#{x}:y=ih*#{y},scale=2:1:flags=area[p#{idx}]"
      end

      stack_inputs = (0...pair_count).map { |i| "[p#{i}]" }.join
      filters << "#{stack_inputs}hstack=inputs=#{pair_count}[out]"

      raw = ffmpeg_sample_raw(file_path: file_path, t: t, filter_complex: filters.join(";"))
      bytes = raw&.bytes || []

      expected = pair_count * 2
      return { variant: nil, confidence: 0.0, score: 0 } if bytes.length < expected

      score = 0
      pair_count.times do |i|
        left = bytes[i * 2]
        right = bytes[i * 2 + 1]
        score += (left - right)
      end

      # Positive means left brighter than right (variant A in v2 by construction).
      variant = score >= 0 ? "a" : "b"
      conf = (score.abs.to_f / (pair_count * 255.0)).round(4)
      variant = nil if conf < MIN_CONFIDENCE

      { variant: variant, confidence: conf, score: score }
    rescue
      { variant: nil, confidence: 0.0, score: 0 }
    end
    private_class_method :sample_pair_score

    # --------------------- v1 (tiles) --------------------------------------

    def sample_tile_score(file_path:, t:, tiles:, box:)
      tile_count = tiles.length
      return { variant: nil, confidence: 0.0, score: 0 } if tile_count == 0

      box = box.to_f
      box = 0.12 if box <= 0
      outer = (box * 1.5).round(6)
      pad = ((outer - box) / 2.0).round(6)

      filters = []
      tiles.each_with_index do |p, idx|
        x = p[:x]
        y = p[:y]

        # Inner box mean (1x1 pixel)
        filters << "[0:v]crop=w=iw*#{box}:h=ih*#{box}:x=iw*#{x}:y=ih*#{y},scale=1:1:flags=area[i#{idx}]"

        # Outer neighborhood mean (bigger crop around the box)
        ox = [[x - pad, 0.0].max, 1.0 - outer].min.round(6)
        oy = [[y - pad, 0.0].max, 1.0 - outer].min.round(6)
        filters << "[0:v]crop=w=iw*#{outer}:h=ih*#{outer}:x=iw*#{ox}:y=ih*#{oy},scale=1:1:flags=area[o#{idx}]"
      end

      # Pack into a strip: i0 o0 i1 o1 ...
      pack = []
      tiles.each_index do |idx|
        pack << "[i#{idx}]"
        pack << "[o#{idx}]"
      end

      filters << "#{pack.join}hstack=inputs=#{pack.length}[out]"

      raw = ffmpeg_sample_raw(file_path: file_path, t: t, filter_complex: filters.join(";"))
      bytes = raw&.bytes || []

      expected = tile_count * 2
      return { variant: nil, confidence: 0.0, score: 0 } if bytes.length < expected

      score = 0
      tile_count.times do |i|
        inner = bytes[i * 2]
        outer_m = bytes[i * 2 + 1]
        score += (inner - outer_m)
      end

      variant = score >= 0 ? "a" : "b"
      conf = (score.abs.to_f / (tile_count * 255.0)).round(4)
      variant = nil if conf < MIN_CONFIDENCE

      { variant: variant, confidence: conf, score: score }
    rescue
      { variant: nil, confidence: 0.0, score: 0 }
    end
    private_class_method :sample_tile_score

    # --------------------- ffmpeg runner -----------------------------------

    def ffmpeg_sample_raw(file_path:, t:, filter_complex:)
      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
        "-ss",
        t.to_f.to_s,
        "-i",
        file_path,
        "-frames:v",
        "1",
        "-filter_complex",
        filter_complex,
        "-map",
        "[out]",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "gray",
        "-",
      ]

      stdout, _stderr, status = Open3.capture3(*cmd)
      return nil unless status.success?

      stdout
    end
    private_class_method :ffmpeg_sample_raw
  end
end
