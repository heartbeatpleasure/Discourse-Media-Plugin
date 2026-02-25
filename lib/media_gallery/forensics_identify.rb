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

    # Safety/perf: cap how many segments we will do 3-point resampling for.
    # With batch sampling we can handle many samples, but we still want to avoid
    # runaway work on very heavy encodes.
    MAX_RESAMPLED_SEGMENTS = 30

    # Heuristic: visible (burned-in) watermarks can overlap our subtle A/B tiles.
    # When that happens (especially with screen-recordings), those regions add structured noise
    # and can flip bits. For forensics extraction only, we optionally ignore tiles/pairs that
    # overlap the visible watermark area when the watermark is placed centrally.
    #
    # NOTE: This does NOT change how HLS variants are generated; it only changes sampling.
    VISIBLE_WATERMARK_EXCLUSION_POSITIONS = %w[center top_center bottom_center].freeze

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

      forensics_spec = filtered_spec_for_forensics(spec)

      obs = extract_observed_variants(
        file_path: file_path,
        segment_seconds: seg,
        spec: forensics_spec,
        max_samples: max_samples
      )

      match = match_fingerprints(
        media_item: media_item,
        observed_variants: obs[:variants],
        observed_confidences: obs[:confidences],
        max_offset_segments: max_offset_segments
      )

      matches = match[:candidates] || []
      match_meta = match[:meta] || {}

      result = {
        meta: {
          public_id: media_item.public_id,
          media_item_id: media_item.id,
          segment_seconds: seg,
          layout: spec[:layout].to_s.presence || layout,
          forensics_spec_kind: forensics_spec[:kind].to_s,
          forensics_spec_points: (forensics_spec[:kind].to_s == "pairs" ? (forensics_spec[:pairs]&.length || 0) : (forensics_spec[:tiles]&.length || 0)),
          forensics_excluded_points: (forensics_spec[:forensics_excluded_points] || 0),
          duration_seconds: obs[:duration_seconds],
          samples: obs[:variants].length,
          usable_samples: obs[:variants].count { |v| v.present? },
          variant_extraction: obs[:extraction_strategy],
          variant_threshold_score: obs[:threshold_score],
        }.merge(match_meta),
        observed: {
          variants: obs[:variants].join(""),
          confidences: obs[:confidences],
        },
        candidates: matches,
      }

      # Ensure we only return string keys so controllers can safely merge into
      # result["meta"] without creating duplicate :meta and "meta" hashes.
      result = result.deep_stringify_keys if result.respond_to?(:deep_stringify_keys)
      result
    end

    # ----------------------------------------------------------------------

    def filtered_spec_for_forensics(spec)
      return spec unless spec.is_a?(Hash)

      # Only attempt this heuristic when a visible watermark exists and is placed centrally.
      begin
        return spec unless SiteSetting.respond_to?(:media_gallery_watermark_enabled)
        return spec unless SiteSetting.media_gallery_watermark_enabled
      rescue
        return spec
      end

      pos = nil
      begin
        pos = ::MediaGallery::Watermark.global_position.to_s
      rescue
        pos = nil
      end

      return spec unless pos.present? && VISIBLE_WATERMARK_EXCLUSION_POSITIONS.include?(pos)

      rect = visible_watermark_exclusion_rect(pos)
      return spec if rect.blank?

      kind = spec[:kind].to_s
      box = spec[:box_size_frac].to_f
      box = 0.12 if box <= 0

      if kind == "pairs" && spec[:pairs].is_a?(Array)
        pairs = spec[:pairs]
        kept = []
        pairs.each do |p|
          x = p[:x].to_f
          y = p[:y].to_f
          w = box * 2.0
          h = box
          kept << p unless rects_intersect?(x1: x, y1: y, w1: w, h1: h, x2: rect[:x], y2: rect[:y], w2: rect[:w], h2: rect[:h])
        end

                # Avoid filtering too aggressively (dropping too many points can make the
        # score biased, e.g. turning many samples into all "a" or all "b").
        min_keep = [(pairs.length.to_f * 0.75).ceil, 2].max
        return spec if kept.length < min_keep

        out = spec.dup
        out[:pairs] = kept
        out[:forensics_excluded_points] = pairs.length - kept.length
        return out
      end

      if kind == "tiles" && spec[:tiles].is_a?(Array)
        tiles = spec[:tiles]
        kept = []
        tiles.each do |p|
          x = p[:x].to_f
          y = p[:y].to_f
          w = box
          h = box
          kept << p unless rects_intersect?(x1: x, y1: y, w1: w, h1: h, x2: rect[:x], y2: rect[:y], w2: rect[:w], h2: rect[:h])
        end

                min_keep = [(tiles.length.to_f * 0.75).ceil, 2].max
        return spec if kept.length < min_keep

        out = spec.dup
        out[:tiles] = kept
        out[:forensics_excluded_points] = tiles.length - kept.length
        return out
      end

      spec
    rescue
      spec
    end
    private_class_method :filtered_spec_for_forensics

    def visible_watermark_exclusion_rect(pos)
      # Rough normalized rectangles that cover common central watermark positions.
      # We intentionally overshoot a bit; losing 1-2 sampling points is preferable to
      # including corrupted ones.
      case pos.to_s
      when "center"
        { x: 0.12, y: 0.34, w: 0.76, h: 0.32 }
      when "top_center"
        { x: 0.12, y: 0.00, w: 0.76, h: 0.26 }
      when "bottom_center"
        { x: 0.12, y: 0.70, w: 0.76, h: 0.30 }
      else
        nil
      end
    end
    private_class_method :visible_watermark_exclusion_rect

    def rects_intersect?(x1:, y1:, w1:, h1:, x2:, y2:, w2:, h2:)
      return false if w1 <= 0 || h1 <= 0 || w2 <= 0 || h2 <= 0
      x1b = x1 + w1
      y1b = y1 + h1
      x2b = x2 + w2
      y2b = y2 + h2
      (x1 < x2b) && (x1b > x2) && (y1 < y2b) && (y1b > y2)
    end
    private_class_method :rects_intersect?

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
      out = symbolize_hash_keys(h)

      if out[:pairs].is_a?(Array)
        out[:pairs] = out[:pairs].map { |p| p.is_a?(Hash) ? symbolize_hash_keys(p) : p }
      end

      if out[:tiles].is_a?(Array)
        out[:tiles] = out[:tiles].map { |p| p.is_a?(Hash) ? symbolize_hash_keys(p) : p }
      end

      out
    end
    private_class_method :symbolize_spec

    def symbolize_hash_keys(h)
      out = {}
      h.each do |k, v|
        kk = k.respond_to?(:to_sym) ? k.to_sym : k
        out[kk] = v
      end
      out
    end
    private_class_method :symbolize_hash_keys


    def extract_observed_variants(file_path:, segment_seconds:, spec:, max_samples:)
      duration = probe_duration_seconds(file_path)
      duration = 0.0 if duration.nan? || duration.infinite? || duration.negative?

      # Sample at segment midpoints; cap work.
      seg = segment_seconds.to_i
      total = (duration / seg).floor
      total = 0 if total.negative?

      sample_count = [total, max_samples.to_i].min
      sample_count = 0 if sample_count.negative?

      times_mid = sample_count.times.map { |i| (i + 0.5) * seg }

      # Pass 1: sample midpoints in a single ffmpeg run.
      pass1 = sample_variants_batch_single(file_path: file_path, times: times_mid, spec: spec)
      variants = pass1.map { |r| r[:variant] }
      confidences = pass1.map { |r| r[:confidence] }
      scores = pass1.map { |r| r[:score] }

      # Pass 2: for weak samples, resample within the same segment and aggregate.
      weak_idxs = []
      variants.each_with_index do |v, i|
        c = confidences[i].to_f
        next if v.present? && c >= RESAMPLE_MIN_CONFIDENCE
        weak_idxs << i
      end
      weak_idxs = weak_idxs.first(MAX_RESAMPLED_SEGMENTS)

      if weak_idxs.present?
        seg_f = seg.to_f
        offset = (seg_f * 0.25).to_f
        offset = 0.25 if offset < 0.25

        # Build resample time list (2 extra timestamps per weak segment).
        resample_times = []
        resample_map = {} # rounded_time -> [segment_idx, ...]

        weak_idxs.each do |i|
          t_mid = times_mid[i]
          t1 = clamp_time(t_mid - offset, duration_seconds: duration)
          t2 = clamp_time(t_mid + offset, duration_seconds: duration)

          [t1, t2].each do |tt|
            key = tt.to_f.round(3)
            resample_times << tt
            (resample_map[key] ||= []) << i
          end
        end

        pass2 = sample_variants_batch_single(file_path: file_path, times: resample_times, spec: spec)

        # Aggregate per weak segment using median(score) and median(confidence).
        per_seg_scores = Hash.new { |h, k| h[k] = [] }
        per_seg_confs = Hash.new { |h, k| h[k] = [] }

        resample_times.each_with_index do |tt, idx|
          key = tt.to_f.round(3)
          seg_idxs = resample_map[key] || []
          next if seg_idxs.empty?
          seg_idxs.each do |si|
            per_seg_scores[si] << pass2[idx][:score].to_i
            per_seg_confs[si] << pass2[idx][:confidence].to_f
          end
        end

        weak_idxs.each do |i|
          all_scores = [scores[i].to_i] + per_seg_scores[i]
          all_confs = [confidences[i].to_f] + per_seg_confs[i]

          med_score = median(all_scores)
          med_conf = median(all_confs).to_f.round(4)

          v = med_score >= 0 ? "a" : "b"
          v = nil if med_conf < MIN_CONFIDENCE

          variants[i] = v
          confidences[i] = med_conf
          scores[i] = med_score
        end
      end

            # If the extracted variants are extremely skewed (e.g. all "a"), it often
      # means the raw score is dominated by scene brightness/gradients rather
      # than the watermark sign. In that case, classify variants relative to an
      # adaptive threshold (median score) instead of using score sign.
      extraction_strategy = "sign"
      threshold_score = nil

      usable_scores = []
      variants.each_with_index do |v, i|
        next if v.blank?
        s = scores[i]
        next if s.nil?
        usable_scores << s.to_i
      end

      if usable_scores.length >= 8
        a_count = variants.count { |v| v == "a" }
        b_count = variants.count { |v| v == "b" }
        total_v = a_count + b_count

        if total_v > 0
          frac = [a_count.to_f / total_v.to_f, b_count.to_f / total_v.to_f].max
          if frac >= 0.9
            threshold_score = median(usable_scores).to_i
            extraction_strategy = "adaptive_threshold"

            points =
              if spec[:kind].to_s == "pairs"
                (spec[:pairs] || []).length
              else
                (spec[:tiles] || []).length
              end
            denom = [points.to_i, 1].max * 255.0

            variants.each_with_index do |_v, i|
              c0 = confidences[i].to_f
              next if c0 < MIN_CONFIDENCE
              s = scores[i]
              next if s.nil?

              centered = s.to_f - threshold_score.to_f
              v2 = centered >= 0 ? "a" : "b"
              c2 = (centered.abs.to_f / denom).round(4)

              if c2 < MIN_CONFIDENCE
                variants[i] = nil
                confidences[i] = c2
              else
                variants[i] = v2
                confidences[i] = [c0, c2].max.round(4)
              end
            end
          end
        end
      end

      { duration_seconds: duration, variants: variants, confidences: confidences, layout: spec[:layout].to_s, extraction_strategy: extraction_strategy, threshold_score: threshold_score }
    end

    
    def match_fingerprints(media_item:, observed_variants:, observed_confidences: nil, max_offset_segments:)
      fps = ::MediaGallery::MediaFingerprint.where(media_item_id: media_item.id).includes(:user).to_a
      return { candidates: [], meta: { offset_strategy: "global" } } if fps.empty?

      max_off = max_offset_segments.to_i
      max_off = 0 if max_off.negative?

      obs = observed_variants.is_a?(Array) ? observed_variants : []
      confs = observed_confidences.is_a?(Array) ? observed_confidences : []

      # Build a compact list of usable samples:
      # [observed_index, "a"/"b", weight, confidence]
      #
      # Weighting:
      # - we always skip nil/blank bits
      # - higher confidence samples contribute more to mismatch scoring
      # - use confidence^2 to more strongly down-weight marginal readings
      samples = []
      obs.each_with_index do |v, i|
        next if v.blank?

        c = confs[i].to_f rescue 0.0
        c = 0.0 if c.nan? || c.infinite? || c.negative?

        if c > 0 && c < MIN_CONFIDENCE
          next
        end

        w = c > 0 ? (c * c) : 1.0
        next if w <= 0.0

        samples << [i, v.to_s, w.to_f, c.to_f]
      end

      return { candidates: [], meta: { offset_strategy: "global", chosen_offset_segments: 0, effective_samples: 0.0 } } if samples.empty?

      total_weight = samples.reduce(0.0) { |acc, s| acc + s[2].to_f }.to_f

      chosen_offset = 0
      best_score = nil
      best_diag = nil

      # Global offset selection:
      # We choose ONE offset for the leak clip and score all candidates using that.
      #
      # Why: letting each user pick their own best offset can overfit noise and
      # produce false positives with short clips.
      (0..max_off).each do |offset|
        top = nil
        second = nil

        fps.each do |rec|
          mism_w = 0.0
          comp_w = 0.0

          samples.each do |(i, ov, w, _c)|
            exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
              fingerprint_id: rec.fingerprint_id,
              media_item_id: media_item.id,
              segment_index: i + offset
            )

            comp_w += w
            mism_w += w if exp != ov
          end

          next if comp_w <= 0.0

          ratio_w = 1.0 - (mism_w / comp_w)

          entry = { ratio_w: ratio_w, comp_w: comp_w, rec: rec }

          if top.nil? || entry[:ratio_w] > top[:ratio_w] || (entry[:ratio_w] == top[:ratio_w] && entry[:comp_w] > top[:comp_w])
            second = top
            top = entry
          elsif second.nil? || entry[:ratio_w] > second[:ratio_w] || (entry[:ratio_w] == second[:ratio_w] && entry[:comp_w] > second[:comp_w])
            second = entry
          end
        end

        next unless top

        second_ratio = second ? second[:ratio_w].to_f : 0.0
        delta = top[:ratio_w].to_f - second_ratio

        coverage = total_weight > 0 ? (top[:comp_w].to_f / total_weight.to_f) : 0.0

        # Score prioritizes separation, then overall fit, then (slightly) prefers smaller offsets.
        score = delta + (top[:ratio_w].to_f * 0.02) + (coverage.to_f * 0.01) - (offset.to_f * 0.0002)

        if best_score.nil? || score > best_score ||
             (score == best_score && top[:ratio_w] > best_diag[:top_ratio_w])
          best_score = score
          chosen_offset = offset
          best_diag = {
            top_ratio_w: top[:ratio_w].to_f,
            second_ratio_w: second_ratio,
            delta: delta,
          }
        end
      end

      # Compute candidates at the chosen global offset.
      candidates = []
      fps.each do |rec|
        mism_w = 0.0
        comp_w = 0.0
        mism = 0
        comp = 0

        samples.each do |(i, ov, w, _c)|
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: rec.fingerprint_id,
            media_item_id: media_item.id,
            segment_index: i + chosen_offset
          )

          comp += 1
          comp_w += w
          if exp != ov
            mism += 1
            mism_w += w
          end
        end

        next if comp == 0 || comp_w <= 0.0

        raw_ratio = 1.0 - (mism.to_f / comp.to_f)
        w_ratio = 1.0 - (mism_w / comp_w)

        candidates << {
          user_id: rec.user_id,
          username: rec.user&.username,
          fingerprint_id: rec.fingerprint_id,
          best_offset_segments: chosen_offset,
          mismatches: mism,
          compared: comp,
          mismatches_weighted: mism_w.round(6),
          compared_weighted: comp_w.round(6),
          # Keep match_ratio aligned with mismatches/compared (raw), and expose
          # the weighted score separately for diagnostics.
          match_ratio: raw_ratio.round(4),
          match_ratio_weighted: w_ratio.round(4),
        }
      end

      candidates.sort_by! { |r| [r[:mismatches].to_i, -r[:compared].to_i, r[:mismatches_weighted].to_f] }
      candidates = candidates.first(10)

      # Add diagnostics: local best offset per candidate (not used for ranking).
      if max_off > 0 && candidates.present?
        rec_by_user = fps.index_by(&:user_id)
        candidates.each do |cand|
          rec = rec_by_user[cand[:user_id]]
          next unless rec

          local = best_local_offset(rec: rec, samples: samples, max_off: max_off, media_item_id: media_item.id)
          cand[:local_best_offset_segments] = local[:offset]
          cand[:local_match_ratio] = local[:match_ratio].round(4)
        end
      end

      # Estimate "effective sample count" by normalizing the weighted sum using the median confidence^2.
      conf_list = samples.map { |s| s[3].to_f }.select { |c| c > 0.0 }
      med_c = median(conf_list)
      med_c = 0.03 if med_c <= 0.0
      norm = med_c * med_c
      effective = norm > 0 ? (total_weight / norm) : samples.length.to_f
      effective = effective.round(2)

      meta = {
        offset_strategy: "global",
        chosen_offset_segments: chosen_offset,
        effective_samples: effective,
        pool_size: fps.length,
        reference_pool_size: 2000,
      }

      if best_diag
        meta[:offset_top_match_ratio] = best_diag[:top_ratio_w].round(4)
        meta[:offset_second_match_ratio] = best_diag[:second_ratio_w].round(4)
        meta[:offset_delta] = best_diag[:delta].round(4)
      end

      # Add statistical diagnostics so admins can judge how risky a "match" is when
      # the candidate pool is large (e.g. 2000+ members).
      pool_n = fps.length.to_i
      ref_n = 2000
      candidates.each do |cand|
        n = cand[:compared].to_i
        next if n <= 0

        mr = cand[:match_ratio].to_f
        # Chance baseline for a wrong candidate is ~0.5.
        z = (mr - 0.5) / Math.sqrt(0.25 / n.to_f)
        p = z.positive? ? (1.0 - normal_cdf(z)) : 1.0

        cand[:signal_z] = z.round(3)
        cand[:p_value] = p.round(10)
        cand[:expected_false_positives_pool] = (pool_n * p).round(3)
        cand[:expected_false_positives_2000] = (ref_n * p).round(3)
      end

      { candidates: candidates, meta: meta }
    end

    def best_local_offset(rec:, samples:, max_off:, media_item_id:)
      best = { offset: 0, mism_w: nil, comp_w: 0.0, match_ratio: 0.0 }

      (0..max_off).each do |offset|
        mism_w = 0.0
        comp_w = 0.0

        samples.each do |(i, ov, w, _c)|
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: rec.fingerprint_id,
            media_item_id: media_item_id,
            segment_index: i + offset
          )

          comp_w += w
          mism_w += w if exp != ov
        end

        next if comp_w <= 0.0

        if best[:mism_w].nil? || mism_w < best[:mism_w] || (mism_w == best[:mism_w] && comp_w > best[:comp_w])
          best = {
            offset: offset,
            mism_w: mism_w,
            comp_w: comp_w,
            match_ratio: 1.0 - (mism_w / comp_w),
          }
        end
      end

      { offset: best[:offset].to_i, match_ratio: best[:match_ratio].to_f }
    rescue
      { offset: 0, match_ratio: 0.0 }
    end
    private_class_method :best_local_offset

    def normal_cdf(z)
      # Standard normal CDF using erf.
      0.5 * (1.0 + Math.erf(z.to_f / Math.sqrt(2.0)))
    rescue
      0.5
    end
    private_class_method :normal_cdf


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

    # --------------------- batch sampling ---------------------------------

    def sample_variants_batch_single(file_path:, times:, spec:)
      times = Array(times).map { |t| t.to_f }.select { |t| t >= 0.0 }
      return [] if times.empty?

      kind = spec[:kind].to_s
      kind = "pairs" if kind.blank? && spec[:pairs].present?
      kind = "tiles" if kind.blank? && spec[:tiles].present?

      if kind == "pairs"
        pairs = spec[:pairs] || []
        box = spec[:box_size_frac].to_f
        box = 0.12 if box <= 0
        expected = pairs.length * 2

        raw = ffmpeg_sample_raw_multi(
          file_path: file_path,
          times: times,
          expected_bytes_per_frame: expected,
          filter_builder: lambda { |in_label| build_pair_filter(in_label: in_label, pairs: pairs, box: box) }
        )

        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          diffs = []
          pairs.length.times do |i|
            left = bytes[i * 2]
            right = bytes[i * 2 + 1]
            diffs << (left - right)
          end

          # Robust aggregation: use the median difference to avoid outliers
          # (e.g. visible watermark overlap, player overlays, etc.).
          score = median(diffs)
          conf = (median(diffs.map { |d| d.abs }).to_f / 255.0).round(4)
          variant = score.to_i >= 0 ? "a" : "b"
          variant = nil if conf < MIN_CONFIDENCE
          { variant: variant, confidence: conf, score: score }
        end
      else
        tiles = spec[:tiles] || []
        box = spec[:box_size_frac].to_f
        box = 0.12 if box <= 0
        expected = tiles.length * 2

        raw = ffmpeg_sample_raw_multi(
          file_path: file_path,
          times: times,
          expected_bytes_per_frame: expected,
          filter_builder: lambda { |in_label| build_tile_filter(in_label: in_label, tiles: tiles, box: box) }
        )

        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          diffs = []
          tiles.length.times do |i|
            inner = bytes[i * 2]
            outer_m = bytes[i * 2 + 1]
            diffs << (inner - outer_m)
          end

          score = median(diffs)
          conf = (median(diffs.map { |d| d.abs }).to_f / 255.0).round(4)
          variant = score.to_i >= 0 ? "a" : "b"
          variant = nil if conf < MIN_CONFIDENCE
          { variant: variant, confidence: conf, score: score }
        end
      end
    rescue
      times.map { { variant: nil, confidence: 0.0, score: 0 } }
    end
    private_class_method :sample_variants_batch_single

    def parse_batch_bytes(raw:, expected_bytes_per_frame:, times:)
      out = []
      bytes = raw&.bytes || []
      frame_size = expected_bytes_per_frame.to_i
      frame_size = 0 if frame_size.negative?

      times.length.times do |i|
        start = i * frame_size
        slice = bytes[start, frame_size]
        if slice.nil? || slice.length < frame_size
          out << { variant: nil, confidence: 0.0, score: 0 }
        else
          out << yield(slice)
        end
      end
      out
    end
    private_class_method :parse_batch_bytes

    def build_pair_filter(in_label:, pairs:, box:)
      pair_count = pairs.length
      return { filter: "null[out]", expected_bytes: 0 } if pair_count == 0

      pair_w = (box.to_f * 2.0).round(6)
      filters = []
      pairs.each_with_index do |p, idx|
        x = p[:x]
        y = p[:y]
        filters << "#{in_label}crop=w=iw*#{pair_w}:h=ih*#{box}:x=iw*#{x}:y=ih*#{y},scale=2:1:flags=area[p#{idx}]"
      end
      stack_inputs = (0...pair_count).map { |i| "[p#{i}]" }.join
      filters << "#{stack_inputs}hstack=inputs=#{pair_count}[out]"
      { filter: filters.join(";"), expected_bytes: pair_count * 2 }
    end
    private_class_method :build_pair_filter

    def build_tile_filter(in_label:, tiles:, box:)
      tile_count = tiles.length
      return { filter: "null[out]", expected_bytes: 0 } if tile_count == 0

      outer = (box.to_f * 1.5).round(6)
      pad = ((outer - box.to_f) / 2.0).round(6)

      filters = []
      tiles.each_with_index do |p, idx|
        x = p[:x]
        y = p[:y]

        filters << "#{in_label}crop=w=iw*#{box}:h=ih*#{box}:x=iw*#{x}:y=ih*#{y},scale=1:1:flags=area[i#{idx}]"

        ox = [[x - pad, 0.0].max, 1.0 - outer].min.round(6)
        oy = [[y - pad, 0.0].max, 1.0 - outer].min.round(6)
        filters << "#{in_label}crop=w=iw*#{outer}:h=ih*#{outer}:x=iw*#{ox}:y=ih*#{oy},scale=1:1:flags=area[o#{idx}]"
      end

      pack = []
      tiles.each_index do |idx|
        pack << "[i#{idx}]"
        pack << "[o#{idx}]"
      end
      filters << "#{pack.join}hstack=inputs=#{pack.length}[out]"
      { filter: filters.join(";"), expected_bytes: tile_count * 2 }
    end
    private_class_method :build_tile_filter

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

      diffs = []
      pair_count.times do |i|
        left = bytes[i * 2]
        right = bytes[i * 2 + 1]
        diffs << (left - right)
      end

      score = median(diffs)

      # Positive means left brighter than right (variant A in v2 by construction).
      variant = score.to_i >= 0 ? "a" : "b"
      conf = (median(diffs.map { |d| d.abs }).to_f / 255.0).round(4)
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

      diffs = []
      tile_count.times do |i|
        inner = bytes[i * 2]
        outer_m = bytes[i * 2 + 1]
        diffs << (inner - outer_m)
      end

      score = median(diffs)

      variant = score.to_i >= 0 ? "a" : "b"
      conf = (median(diffs.map { |d| d.abs }).to_f / 255.0).round(4)
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

    def ffmpeg_sample_raw_multi(file_path:, times:, expected_bytes_per_frame:, filter_builder:)
      times = Array(times).map { |t| t.to_f }
      return nil if times.empty?

      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
      ]

      times.each do |t|
        cmd += ["-ss", t.to_s, "-i", file_path]
      end

      filters = []
      out_labels = []

      times.each_with_index do |_t, idx|
        in_label = "[#{idx}:v]"
        built = filter_builder.call(in_label)
        filters << built[:filter].gsub("[out]", "[o#{idx}]")
        out_labels << "[o#{idx}]"
      end

      if out_labels.length == 1
        filters << "#{out_labels.first}copy[out]"
      else
        filters << "#{out_labels.join}concat=n=#{out_labels.length}:v=1:a=0[out]"
      end

      cmd += [
        "-filter_complex",
        filters.join(";"),
        "-map",
        "[out]",
        "-frames:v",
        times.length.to_s,
        "-f",
        "rawvideo",
        "-pix_fmt",
        "gray",
        "-",
      ]

      stdout, _stderr, status = Open3.capture3(*cmd)
      return nil unless status.success?

      need = expected_bytes_per_frame.to_i * times.length
      return nil if need > 0 && stdout.to_s.bytesize < need

      stdout
    end
    private_class_method :ffmpeg_sample_raw_multi
  end
end
