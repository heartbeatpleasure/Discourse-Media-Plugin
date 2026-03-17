# frozen_string_literal: true

require "open3"
require "json"
require "digest"

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

    # Soft time budget for file-mode work (sampling + reference calibration) to avoid proxy timeouts.
    # If we hit this budget, we return partial results rather than getting killed at ~30s.
    FILEMODE_TIME_BUDGET_SECONDS = 22

    # ffmpeg_sample_raw_multi uses one input per timestamp; too many inputs gets slow.
    # We sample in chunks to keep commands small and to allow early cutoff by time budget.
    FILEMODE_SAMPLE_CHUNK = 15

    # File-mode phase search samples a dense score timeline once and then evaluates
    # multiple sub-segment phase candidates against that same data.
    DENSE_SAMPLE_STEP_DEFAULT = 1.0
    DENSE_SAMPLE_STEP_FINE = 0.5
    PHASE_SEARCH_WINDOW_RATIO = 0.35
    PHASE_SEARCH_WINDOW_MAX_SECONDS = 1.25
    PHASE_SEARCH_MIN_SECONDS = 0.5

    def identify_from_file(media_item:, file_path:, max_samples: DEFAULT_MAX_SAMPLES, max_offset_segments: DEFAULT_MAX_OFFSET_SEGMENTS, layout: nil, sample_times: nil)
      raise ArgumentError, "missing media_item" if media_item.blank?
      raise ArgumentError, "missing file" if file_path.blank? || !File.exist?(file_path)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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

      # When available, prefer the *packaged* HLS playlist timing for sampling.
      # Real HLS segments are not always exactly `segment_seconds` long (frame rounding),
      # and drift can cause us to sample near boundaries (hurts A/B detection).
      #
      # Using playlist-derived midpoints tends to reduce bit flips and increase separation.
      sample_times ||= packaged_segment_midpoints_for(media_item: media_item)

      file_size_bytes = (File.size(file_path) rescue nil)
      obs, match = identify_with_phase_search(
        media_item: media_item,
        file_path: file_path,
        segment_seconds: seg,
        spec: spec,
        max_samples: max_samples,
        sample_times: sample_times,
        file_size_bytes: file_size_bytes,
        started_at: started_at,
        time_budget_seconds: FILEMODE_TIME_BUDGET_SECONDS,
        max_offset_segments: max_offset_segments
      )

      if obs.blank? || match.blank?
        obs = extract_observed_variants(
          file_path: file_path,
          segment_seconds: seg,
          spec: spec,
          max_samples: max_samples,
          sample_times: sample_times,
          file_size_bytes: file_size_bytes,
          started_at: started_at,
          time_budget_seconds: FILEMODE_TIME_BUDGET_SECONDS
        )

        match = match_fingerprints(
          media_item: media_item,
          observed_variants: obs[:variants],
          observed_confidences: obs[:confidences],
          observed_scores: obs[:scores],
          spec: spec,
          max_offset_segments: max_offset_segments
        )
      end

      matches = match[:candidates] || []
      match_meta = match[:meta] || {}

      # If reference-calibrated matching computed a more reliable A/B sequence, prefer it for display.
      if match_meta.is_a?(Hash) && match_meta[:reference_observed_variants].is_a?(Array)
        obs[:variants] = match_meta[:reference_observed_variants]
        obs[:confidences] = match_meta[:reference_observed_confidences] if match_meta[:reference_observed_confidences].is_a?(Array)
      end

      result = {
        meta: {
          public_id: media_item.public_id,
          media_item_id: media_item.id,
          segment_seconds: seg,
          layout: spec[:layout].to_s.presence || layout,
          duration_seconds: obs[:duration_seconds],
          samples: obs[:variants].length,
          usable_samples: obs[:variants].count { |v| v.present? },
          filemode_elapsed_seconds: obs[:elapsed_seconds],
          filemode_truncated: obs[:truncated],
          effective_max_samples: obs[:effective_max_samples],
        }.merge(match_meta),
        observed: {
          variants: format_variant_sequence(obs[:variants]),
          variants_compact: Array(obs[:variants]).compact.join(""),
          variants_array: Array(obs[:variants]),
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

    def identify_with_phase_search(media_item:, file_path:, segment_seconds:, spec:, max_samples:, sample_times:, file_size_bytes:, started_at:, time_budget_seconds:, max_offset_segments:)
      duration = probe_duration_seconds(file_path)
      duration = 0.0 if duration.nan? || duration.infinite? || duration.negative?

      base_times, effective_cap = build_filemode_sample_times(
        duration_seconds: duration,
        segment_seconds: segment_seconds,
        sample_times: sample_times,
        max_samples: max_samples,
        file_size_bytes: file_size_bytes
      )
      return [nil, nil] if base_times.blank?

      coarse = run_phase_search_pass(
        media_item: media_item,
        file_path: file_path,
        segment_seconds: segment_seconds,
        spec: spec,
        base_times: base_times,
        duration_seconds: duration,
        effective_max_samples: effective_cap,
        started_at: started_at,
        time_budget_seconds: time_budget_seconds,
        max_offset_segments: max_offset_segments,
        dense_step_seconds: DENSE_SAMPLE_STEP_DEFAULT
      )

      best_obs = coarse[:obs]
      best_match = coarse[:match]
      best_score = phase_result_score(match: best_match)

      if phase_search_needs_refinement?(match: best_match) && time_remaining_seconds(started_at: started_at, budget_seconds: time_budget_seconds) >= 5.0
        fine = run_phase_search_pass(
          media_item: media_item,
          file_path: file_path,
          segment_seconds: segment_seconds,
          spec: spec,
          base_times: base_times,
          duration_seconds: duration,
          effective_max_samples: effective_cap,
          started_at: started_at,
          time_budget_seconds: time_budget_seconds,
          max_offset_segments: max_offset_segments,
          dense_step_seconds: DENSE_SAMPLE_STEP_FINE
        )

        fine_score = phase_result_score(match: fine[:match])
        if fine_score >= best_score
          best_obs = fine[:obs]
          best_match = fine[:match]
          best_score = fine_score
        end
      end

      [best_obs, best_match]
    rescue
      [nil, nil]
    end
    private_class_method :identify_with_phase_search

    def run_phase_search_pass(media_item:, file_path:, segment_seconds:, spec:, base_times:, duration_seconds:, effective_max_samples:, started_at:, time_budget_seconds:, max_offset_segments:, dense_step_seconds:)
      dense = extract_dense_observed_variants(
        file_path: file_path,
        spec: spec,
        base_times: base_times,
        duration_seconds: duration_seconds,
        effective_max_samples: effective_max_samples,
        segment_seconds: segment_seconds,
        step_seconds: dense_step_seconds,
        started_at: started_at,
        time_budget_seconds: time_budget_seconds
      )

      phase_candidates = build_phase_candidates(segment_seconds: segment_seconds, dense_step_seconds: dense_step_seconds)
      phase_results = []

      phase_candidates.each do |phase_seconds|
        obs = build_phase_observation_from_dense(
          dense: dense,
          base_times: base_times,
          duration_seconds: duration_seconds,
          phase_seconds: phase_seconds,
          segment_seconds: segment_seconds,
          effective_max_samples: effective_max_samples
        )
        next if obs.blank?

        match = match_fingerprints(
          media_item: media_item,
          observed_variants: obs[:variants],
          observed_confidences: obs[:confidences],
          observed_scores: obs[:scores],
          spec: spec,
          max_offset_segments: max_offset_segments
        )

        meta = match[:meta] || {}
        meta[:phase_search_used] = true
        meta[:chosen_phase_seconds] = phase_seconds.round(3)
        meta[:phase_candidates_seconds] ||= phase_candidates.map { |v| v.round(3) }
        meta[:dense_step_seconds] = dense_step_seconds.round(3)
        meta[:dense_samples] = Array(dense[:times]).length
        meta[:phase_search_refined] = (dense_step_seconds.to_f <= DENSE_SAMPLE_STEP_FINE.to_f)
        match[:meta] = meta

        phase_results << { obs: obs, match: match }
      end

      best = phase_results.max_by { |entry| phase_result_score(match: entry[:match]) }
      best || { obs: nil, match: nil }
    end
    private_class_method :run_phase_search_pass

    def extract_dense_observed_variants(file_path:, spec:, base_times:, duration_seconds:, effective_max_samples:, segment_seconds:, step_seconds:, started_at:, time_budget_seconds:)
      step = step_seconds.to_f
      step = DENSE_SAMPLE_STEP_DEFAULT.to_f if step <= 0.0

      budget = time_budget_seconds.to_f
      budget = FILEMODE_TIME_BUDGET_SECONDS.to_f if budget <= 0.0

      max_target_time = Array(base_times).last.to_f
      phase_window = phase_search_window_seconds(segment_seconds)
      dense_end = [max_target_time + phase_window + step, duration_seconds.to_f].min
      dense_end = duration_seconds.to_f if dense_end <= 0.0

      times = []
      t = 0.0
      while t <= dense_end + 0.001
        times << t.round(3)
        t += step
      end
      times << dense_end.round(3) if times.empty? || times.last.to_f < dense_end.to_f - 0.05
      times.uniq!

      chunk_size = FILEMODE_SAMPLE_CHUNK.to_i
      chunk_size = 15 if chunk_size <= 0

      budget_exceeded = lambda do
        next false if started_at.blank?
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f) > budget
      end

      sampled = []
      used_times = []
      times.each_slice(chunk_size) do |chunk|
        break if budget_exceeded.call
        res = sample_variants_batch_single(file_path: file_path, times: chunk, spec: spec)
        sampled.concat(Array(res))
        used_times.concat(chunk.first(Array(res).length))
      end

      elapsed = nil
      if started_at.present?
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f).round(3)
      end

      {
        duration_seconds: duration_seconds,
        times: used_times,
        variants: sampled.map { |r| r[:variant] },
        confidences: sampled.map { |r| r[:confidence] },
        scores: sampled.map { |r| r[:score] },
        dense_step_seconds: step,
        truncated: used_times.length < times.length,
        effective_max_samples: effective_max_samples,
        layout: spec[:layout].to_s,
        elapsed_seconds: elapsed,
      }
    end
    private_class_method :extract_dense_observed_variants

    def build_phase_observation_from_dense(dense:, base_times:, duration_seconds:, phase_seconds:, segment_seconds:, effective_max_samples:)
      variants = []
      confidences = []
      scores = []
      used_times = []

      Array(base_times).each do |t_base|
        target_time = clamp_time(t_base.to_f + phase_seconds.to_f, duration_seconds: duration_seconds)
        sample = interpolate_dense_sample(dense: dense, target_time: target_time)
        used_times << target_time.round(3)

        if sample.blank?
          variants << nil
          confidences << 0.0
          scores << 0.0
          next
        end

        score = sample[:score].to_f
        conf = sample[:confidence].to_f
        conf = 0.0 if conf.nan? || conf.infinite? || conf.negative?
        variant = score >= 0 ? "a" : "b"
        variant = nil if conf < MIN_CONFIDENCE

        variants << variant
        confidences << conf.round(4)
        scores << score
      end

      elapsed = nil
      if dense[:elapsed_seconds].present?
        elapsed = dense[:elapsed_seconds]
      end

      {
        duration_seconds: duration_seconds,
        variants: variants,
        confidences: confidences,
        scores: scores,
        times: used_times,
        layout: dense[:layout].to_s,
        truncated: !!dense[:truncated],
        elapsed_seconds: elapsed,
        effective_max_samples: effective_max_samples,
        phase_seconds: phase_seconds.to_f,
        dense_step_seconds: dense[:dense_step_seconds].to_f,
      }
    end
    private_class_method :build_phase_observation_from_dense

    def interpolate_dense_sample(dense:, target_time:)
      times = Array(dense[:times]).map(&:to_f)
      return nil if times.empty?

      idx = times.bsearch_index { |tt| tt >= target_time.to_f }
      if idx.nil?
        idx = times.length - 1
      elsif idx == 0 || times[idx].to_f == target_time.to_f
        score = Array(dense[:scores])[idx].to_f
        conf = Array(dense[:confidences])[idx].to_f
        return { score: score, confidence: conf }
      end

      left_idx = idx - 1
      right_idx = idx
      t0 = times[left_idx].to_f
      t1 = times[right_idx].to_f
      return nil if t1 <= t0

      ratio = (target_time.to_f - t0) / (t1 - t0)
      ratio = 0.0 if ratio < 0.0
      ratio = 1.0 if ratio > 1.0

      s0 = Array(dense[:scores])[left_idx].to_f
      s1 = Array(dense[:scores])[right_idx].to_f
      c0 = Array(dense[:confidences])[left_idx].to_f
      c1 = Array(dense[:confidences])[right_idx].to_f

      {
        score: (s0 + ((s1 - s0) * ratio)),
        confidence: (c0 + ((c1 - c0) * ratio)),
      }
    rescue
      nil
    end
    private_class_method :interpolate_dense_sample

    def build_phase_candidates(segment_seconds:, dense_step_seconds:)
      window = phase_search_window_seconds(segment_seconds)
      step = (dense_step_seconds.to_f / 2.0)
      step = 0.25 if step <= 0.0

      out = [0.0]
      cur = step
      while cur <= window + 0.001
        out << cur
        out << -cur
        cur += step
      end

      out.map { |v| v.round(3) }.uniq.sort
    end
    private_class_method :build_phase_candidates

    def phase_search_window_seconds(segment_seconds)
      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      window = seg * PHASE_SEARCH_WINDOW_RATIO.to_f
      window = PHASE_SEARCH_MIN_SECONDS.to_f if window < PHASE_SEARCH_MIN_SECONDS.to_f
      window = PHASE_SEARCH_WINDOW_MAX_SECONDS.to_f if window > PHASE_SEARCH_WINDOW_MAX_SECONDS.to_f
      window
    end
    private_class_method :phase_search_window_seconds

    def phase_search_needs_refinement?(match:)
      return false if match.blank?
      meta = match[:meta] || {}
      cands = Array(match[:candidates])
      top_ratio = cands[0] ? cands[0][:match_ratio].to_f : 0.0
      delta = meta[:offset_delta].to_f
      effective = meta[:effective_samples].to_f
      effective < 8.0 || delta < 0.12 || top_ratio < 0.72
    rescue
      false
    end
    private_class_method :phase_search_needs_refinement?

    def phase_result_score(match:)
      return -Float::INFINITY if match.blank?
      meta = match[:meta] || {}
      cands = Array(match[:candidates])
      top = cands[0]
      second = cands[1]
      top_ratio = top ? top[:match_ratio_weighted].to_f : 0.0
      top_ratio = cands[0][:match_ratio].to_f if top_ratio <= 0.0 && cands[0]
      second_ratio = second ? second[:match_ratio_weighted].to_f : 0.0
      second_ratio = cands[1][:match_ratio].to_f if second_ratio <= 0.0 && cands[1]
      delta = meta[:offset_delta].to_f
      delta = (top_ratio - second_ratio) if delta <= 0.0
      effective = meta[:effective_samples].to_f
      phase_penalty = meta[:chosen_phase_seconds].to_f.abs * 0.001
      (delta * 1.0) + (top_ratio * 0.05) + (effective * 0.0025) - phase_penalty
    rescue
      -Float::INFINITY
    end
    private_class_method :phase_result_score

    def build_filemode_sample_times(duration_seconds:, segment_seconds:, sample_times:, max_samples:, file_size_bytes: nil)
      seg = segment_seconds.to_i
      seg = 6 if seg <= 0

      times_mid = nil
      if sample_times.present?
        times = Array(sample_times).map { |t| t.to_f }.select { |t| t >= 0.0 }
        times_mid = times
      end

      if times_mid.present?
        times_mid = times_mid.select { |t| t < duration_seconds.to_f + 0.05 }
      else
        total = (duration_seconds.to_f / seg).floor
        total = 0 if total.negative?
        sample_count = [total, max_samples.to_i].min
        sample_count = 0 if sample_count.negative?
        times_mid = sample_count.times.map { |i| (i + 0.5) * seg }
      end

      cap = filemode_sample_cap_for(max_samples: max_samples, duration_seconds: duration_seconds, file_size_bytes: file_size_bytes)
      cap = 5 if cap < 5 && times_mid.length >= 5
      times_mid = times_mid.first(cap) if cap > 0

      [times_mid, cap]
    end
    private_class_method :build_filemode_sample_times

    def filemode_sample_cap_for(max_samples:, duration_seconds:, file_size_bytes: nil)
      cap = max_samples.to_i
      cap = 0 if cap.negative?

      if duration_seconds.to_f > 0
        if duration_seconds.to_f > 900
          cap = [cap, 18].min
        elsif duration_seconds.to_f > 480
          cap = [cap, 24].min
        elsif duration_seconds.to_f > 240
          cap = [cap, 30].min
        elsif duration_seconds.to_f > 120
          cap = [cap, 40].min
        end
      end

      fs = file_size_bytes.to_i
      if fs > 0
        if fs > 250 * 1024 * 1024
          cap = [cap, 18].min
        elsif fs > 150 * 1024 * 1024
          cap = [cap, 24].min
        elsif fs > 100 * 1024 * 1024
          cap = [cap, 30].min
        elsif fs > 70 * 1024 * 1024
          cap = [cap, 40].min
        end
      end

      cap
    end
    private_class_method :filemode_sample_cap_for

    def time_remaining_seconds(started_at:, budget_seconds:)
      return budget_seconds.to_f if started_at.blank?
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f
      budget_seconds.to_f - elapsed.to_f
    rescue
      0.0
    end
    private_class_method :time_remaining_seconds

    def format_variant_sequence(arr)
      Array(arr).map { |v| v.present? ? v.to_s : "." }.join("")
    end
    private_class_method :format_variant_sequence

    def extract_observed_variants(file_path:, segment_seconds:, spec:, max_samples:, sample_times: nil, file_size_bytes: nil, started_at: nil, time_budget_seconds: nil)
  duration = probe_duration_seconds(file_path)
  duration = 0.0 if duration.nan? || duration.infinite? || duration.negative?

  seg = segment_seconds.to_i
  seg = 6 if seg <= 0

  budget = time_budget_seconds.to_f
  budget = FILEMODE_TIME_BUDGET_SECONDS.to_f if budget <= 0.0
  chunk_size = FILEMODE_SAMPLE_CHUNK.to_i
  chunk_size = 15 if chunk_size <= 0

  budget_exceeded = lambda do
    next false if started_at.blank?
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f) > budget
  end

  times_mid, cap = build_filemode_sample_times(
    duration_seconds: duration,
    segment_seconds: seg,
    sample_times: sample_times,
    max_samples: max_samples,
    file_size_bytes: file_size_bytes
  )

  pass1 = []
  used_times = []
  times_mid.each_slice(chunk_size) do |chunk|
    break if budget_exceeded.call
    res = sample_variants_batch_single(file_path: file_path, times: chunk, spec: spec)
    pass1.concat(res)
    used_times.concat(chunk)
  end

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

  if weak_idxs.present? && !budget_exceeded.call
    seg_f = seg.to_f
    offset = (seg_f * 0.25).to_f
    offset = 0.25 if offset < 0.25

    resample_times = []
    resample_map = {} # rounded_time -> [segment_idx, ...]

    weak_idxs.each do |i|
      t_mid = used_times[i]
      t1 = clamp_time(t_mid - offset, duration_seconds: duration)
      t2 = clamp_time(t_mid + offset, duration_seconds: duration)

      [t1, t2].each do |tt|
        key = tt.to_f.round(3)
        resample_times << tt
        (resample_map[key] ||= []) << i
      end
    end

    pass2 = []
    resample_times.each_slice(chunk_size) do |chunk|
      break if budget_exceeded.call
      pass2.concat(sample_variants_batch_single(file_path: file_path, times: chunk, spec: spec))
    end

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

  elapsed = nil
  if started_at.present?
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f).round(3)
  end

  {
    duration_seconds: duration,
    variants: variants,
    confidences: confidences,
    scores: scores,
    times: used_times,
    layout: spec[:layout].to_s,
    truncated: used_times.length < times_mid.length || budget_exceeded.call,
    elapsed_seconds: elapsed,
    effective_max_samples: cap
  }
end
    # Attempts to derive accurate segment midpoints from the packaged (template) HLS playlist on disk.
    # This avoids assuming fixed `segment_seconds` and reduces drift-related sampling errors.
    def packaged_segment_midpoints_for(media_item:)
      return nil if media_item.blank?
      return nil unless defined?(::MediaGallery::PrivateStorage) && ::MediaGallery::PrivateStorage.enabled?
      return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

      public_id = media_item.public_id.to_s
      return nil if public_id.blank?

      variant = ::MediaGallery::Hls.variants.first.to_s
      variant = "v0" if variant.blank?

      pl = ::MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(public_id, variant)
      return nil if pl.blank? || !File.exist?(pl)

      midpoints = []
      cursor = 0.0
      last_extinf = nil

      File.read(pl).to_s.each_line do |line|
        l = line.to_s.strip
        next if l.blank?

        if l.start_with?("#EXTINF:")
          dur_s = l.sub("#EXTINF:", "").split(",").first.to_s
          dur = dur_s.to_f
          last_extinf = (dur > 0.0 ? dur : nil)
          next
        end

        # Segment URI line
        next if l.start_with?("#")
        next if last_extinf.blank?

        midpoints << (cursor + (last_extinf.to_f / 2.0))
        cursor += last_extinf.to_f
        last_extinf = nil
      end

      midpoints.present? ? midpoints : nil
    rescue
      nil
    end
    private_class_method :packaged_segment_midpoints_for

    # Parses the packaged template playlist (/hls/<variant>/index.m3u8) and returns an array of
    # { uri: "seg_00000.ts", duration: 3.012 } in segment order.
    def packaged_segments_for(media_item:)
      return nil if media_item.blank?
      return nil unless defined?(::MediaGallery::PrivateStorage) && ::MediaGallery::PrivateStorage.enabled?
      return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

      public_id = media_item.public_id.to_s
      return nil if public_id.blank?

      variant = ::MediaGallery::Hls.variants.first.to_s
      variant = "v0" if variant.blank?

      pl = ::MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(public_id, variant)
      return nil if pl.blank? || !File.exist?(pl)

      out = []
      last_extinf = nil

      File.read(pl).to_s.each_line do |line|
        l = line.to_s.strip
        next if l.blank?

        if l.start_with?("#EXTINF:")
          dur_s = l.sub("#EXTINF:", "").split(",").first.to_s
          dur = dur_s.to_f
          last_extinf = (dur > 0.0 ? dur : nil)
          next
        end

        next if l.start_with?("#")
        next if last_extinf.blank?

        out << { uri: l, duration: last_extinf.to_f }
        last_extinf = nil
      end

      out.present? ? out : nil
    rescue
      nil
    end
    private_class_method :packaged_segments_for

    # Builds (and caches) per-segment reference thresholds derived from the packaged A/B variants.
    # This makes A/B classification much more robust for re-encodes/screen recordings, because we
    # compare the leak score against the content-matched A and B scores for the *same* segment.
    def reference_tables_for(media_item:, spec:, needed_count:)
  return nil if media_item.blank? || spec.blank?
  return nil unless defined?(::MediaGallery::PrivateStorage) && ::MediaGallery::PrivateStorage.enabled?
  return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

  root = ::MediaGallery::PrivateStorage.hls_root_abs_dir(media_item.public_id)
  return nil if root.blank? || !Dir.exist?(root)

  segs = packaged_segments_for(media_item: media_item)
  return nil if segs.blank?

  needed = needed_count.to_i
  needed = 0 if needed.negative?
  needed = [needed, segs.length].min
  return nil if needed <= 0

  spec_hash =
    begin
      base = spec.slice(:layout, :kind, :box_size_frac, :pairs, :tiles)
      base = base.deep_stringify_keys if base.respond_to?(:deep_stringify_keys)
      Digest::SHA256.hexdigest(JSON.dump(base))[0, 16]
    rescue
      "na"
    end

  cache_path = File.join(root, "forensics_reference_v2_#{spec[:layout].to_s.presence || 'layout'}.json")
  cache = (JSON.parse(File.read(cache_path)) rescue nil) if File.exist?(cache_path)

  if cache.is_a?(Hash) && cache["spec_hash"].to_s == spec_hash && cache["thr"].is_a?(Array) && cache["delta"].is_a?(Array)
    thr = cache["thr"]
    delta = cache["delta"]
    if thr.length >= needed && delta.length >= needed
      med = cache["delta_median"].to_f
      med = 1.0 if med <= 0
      return { thr: thr, delta: delta, delta_median: med }
    end
  end

  variant = ::MediaGallery::Hls.variants.first.to_s
  variant = "v0" if variant.blank?

  a_pl = File.join(root, "a", variant, "index.m3u8")
  b_pl = File.join(root, "b", variant, "index.m3u8")
  return nil unless File.exist?(a_pl) && File.exist?(b_pl)

  # Absolute midpoints for the first `needed` segments using template durations.
  times = []
  cursor = 0.0
  needed.times do |i|
    dur = segs[i][:duration].to_f
    dur = 0.0 if dur.nan? || dur.infinite? || dur <= 0.0
    times << (cursor + (dur / 2.0))
    cursor += dur
  end

  thr = []
  delta = []

  scores_a = []
  scores_b = []
  chunk = 25

  times.each_slice(chunk) do |slice|
    sa = Array(sample_scores_batch_single(file_path: a_pl, times: slice, spec: spec))
    sb = Array(sample_scores_batch_single(file_path: b_pl, times: slice, spec: spec))
    slice.length.times do |k|
      scores_a << (sa[k] || 0).to_f
      scores_b << (sb[k] || 0).to_f
    end
  end

  needed.times do |i|
    sa = scores_a[i].to_f
    sb = scores_b[i].to_f
    thr << ((sa + sb) / 2.0)
    delta << ((sa - sb) / 2.0)
  end

  deltas_abs = delta.map { |d| d.to_f.abs }.select { |d| d > 0 }
  delta_median = deltas_abs.empty? ? 1.0 : deltas_abs.sort[deltas_abs.length / 2].to_f
  delta_median = 1.0 if delta_median <= 0

  begin
    File.write(
      cache_path,
      JSON.pretty_generate({
        "layout" => spec[:layout].to_s,
        "spec_hash" => spec_hash,
        "thr" => thr,
        "delta" => delta,
        "delta_median" => delta_median,
        "generated_at" => Time.now.utc.iso8601
      })
    )
  rescue
    # ignore cache write errors
  end

  { thr: thr, delta: delta, delta_median: delta_median }
rescue
  nil
end

    private_class_method :reference_tables_for



    def annotate_candidate_debugs!(candidates:, observed_variants:, media_item_id:)
      obs = Array(observed_variants)
      return if candidates.blank? || obs.empty?

      candidates.each do |cand|
        offset = cand[:best_offset_segments].to_i
        expected = Array.new(obs.length)
        indices = Array.new(obs.length)
        mismatches = []

        obs.each_with_index do |ov, i|
          seg_idx = i + offset
          next if ov.blank?

          indices[i] = seg_idx
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: cand[:fingerprint_id],
            media_item_id: media_item_id,
            segment_index: seg_idx
          )
          expected[i] = exp
          mismatches << i if exp != ov
        end

        cand[:reference_segment_indices_used] = indices
        cand[:expected_variants] = format_variant_sequence(expected)
        cand[:mismatch_positions] = mismatches
      end
    rescue
      nil
    end
    private_class_method :annotate_candidate_debugs!

    def apply_top_candidate_debug_to_meta!(meta:, candidates:)
      return meta unless meta.is_a?(Hash)
      top = Array(candidates).first
      return meta if top.blank?

      meta[:reference_segment_indices_used] = top[:reference_segment_indices_used] if top[:reference_segment_indices_used].present?
      meta[:expected_variants_top_candidate] = top[:expected_variants].to_s if top[:expected_variants].present?
      meta[:mismatch_positions] = top[:mismatch_positions] if top[:mismatch_positions].present?
      meta
    rescue
      meta
    end
    private_class_method :apply_top_candidate_debug_to_meta!

    def match_fingerprints(media_item:, observed_variants:, observed_confidences: nil, observed_scores: nil, spec: nil, max_offset_segments:)
      fps = ::MediaGallery::MediaFingerprint.where(media_item_id: media_item.id).includes(:user).to_a
      return { candidates: [], meta: { offset_strategy: "global" } } if fps.empty?

      # Reference-calibrated matching path (for screen recordings / re-encodes):
      # If we have per-sample numeric scores (from pixel extraction) AND can read the packaged A/B segments,
      # we can classify each sample by comparing it against the packaged A/B reference for the corresponding segment index.
      #
      # This greatly reduces scene-bias (e.g. long runs of 'aaaaa...') and improves separation between users.
      if observed_scores.is_a?(Array) && observed_scores.present? && spec.is_a?(Hash)
        begin
          needed_ref = observed_scores.length.to_i + max_offset_segments.to_i + 2
          ref = reference_tables_for(media_item: media_item, spec: spec, needed_count: needed_ref)

          if ref && ref[:thr].is_a?(Array) && ref[:delta].is_a?(Array)
            return match_fingerprints_with_reference(
              fps: fps,
              media_item: media_item,
              scores: observed_scores,
              confidences: (observed_confidences.is_a?(Array) ? observed_confidences : []),
              ref_thr: ref[:thr],
              ref_delta: ref[:delta],
              delta_median: ref[:delta_median].to_f,
              max_offset_segments: max_offset_segments.to_i
            )
          end
        rescue
          # fall back to the legacy path
        end
      end


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
      }

      if best_diag
        meta[:offset_top_match_ratio] = best_diag[:top_ratio_w].round(4)
        meta[:offset_second_match_ratio] = best_diag[:second_ratio_w].round(4)
        meta[:offset_delta] = best_diag[:delta].round(4)
      end

      annotate_candidate_debugs!(candidates: candidates, observed_variants: obs, media_item_id: media_item.id)
      apply_top_candidate_debug_to_meta!(meta: meta, candidates: candidates)

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

    
    # Returns an Array of numeric scores (one per time). Does not apply confidence gating.
    def sample_scores_batch_single(file_path:, times:, spec:)
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

        out = []
        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          score = 0
          pairs.length.times do |i|
            left = bytes[i * 2]
            right = bytes[i * 2 + 1]
            score += (left - right)
          end
          out << score
          { variant: nil, confidence: 0.0, score: score }
        end
        out
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

        out = []
        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          score = 0
          tiles.length.times do |i|
            inner = bytes[i * 2]
            outer_m = bytes[i * 2 + 1]
            score += (inner - outer_m)
          end
          out << score
          { variant: nil, confidence: 0.0, score: score }
        end
        out
      end
    rescue
      []
    end
    private_class_method :sample_scores_batch_single

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
          score = 0
          pairs.length.times do |i|
            left = bytes[i * 2]
            right = bytes[i * 2 + 1]
            score += (left - right)
          end
          conf = (score.abs.to_f / (pairs.length * 255.0)).round(4)
          variant = score >= 0 ? "a" : "b"
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
          score = 0
          tiles.length.times do |i|
            inner = bytes[i * 2]
            outer_m = bytes[i * 2 + 1]
            score += (inner - outer_m)
          end
          conf = (score.abs.to_f / (tiles.length * 255.0)).round(4)
          variant = score >= 0 ? "a" : "b"
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

    
    def match_fingerprints_with_reference(fps:, media_item:, scores:, confidences:, ref_thr:, ref_delta:, delta_median:, max_offset_segments:)
  max_off = max_offset_segments.to_i
  max_off = 0 if max_off.negative?

  delta_med = delta_median.to_f
  delta_med = 1.0 if delta_med <= 0.0

  # Require a minimum A/B separation.
  min_delta = [delta_med * 0.10, 6.0].max

  # Robustly scale leak confidence (do not square; confidences are small by design).
  conf_list = Array(confidences).map { |c| c.to_f }.select { |c| c > 0.0 && !c.nan? && !c.infinite? }
  med_conf = median(conf_list)
  med_conf = 0.02 if med_conf <= 0.0

  leak_scale = []
  scores.length.times do |i|
    c = confidences[i].to_f rescue 0.0
    c = 0.0 if c.nan? || c.infinite? || c.negative?
    s = (c / med_conf)
    s = 0.5 if s < 0.5
    s = 2.0 if s > 2.0
    leak_scale << s
  end

  eps = 1e-6

  build_usable = lambda do |offset|
    usable = []
    ratios = []
    margins = []
    comp_w = 0.0

    scores.each_with_index do |s, i|
      j = i + offset
      next if j >= ref_thr.length || j >= ref_delta.length

      d = ref_delta[j].to_f
      da = d.abs
      next if da < min_delta

      thr = ref_thr[j].to_f
      a = thr + d
      b = thr - d
      sep = (a - b).abs
      sep = 2.0 * da if sep <= 0.0

      sl = s.to_f
      da_l = (sl - a).abs
      db_l = (sl - b).abs

      if da_l <= db_l
        v = "a"
        d_cl = da_l
        d_ot = db_l
      else
        v = "b"
        d_cl = db_l
        d_ot = da_l
      end

      ratio = d_cl / (sep + eps)
      margin = (d_ot - d_cl) / (sep + eps)

      next if margin < 0.05

      w = margin * leak_scale[i]
      next if w <= 0.0 || w.nan? || w.infinite?

      usable << [i, v, w, margin, ratio]
      comp_w += w
      ratios << ratio
      margins << margin
    end

    {
      usable: usable,
      comp_w: comp_w,
      median_ratio: median(ratios).to_f,
      median_margin: median(margins).to_f,
      usable_count: usable.length
    }
  end

  best_offset = 0
  best_score = nil
  best_diag = nil

  (0..max_off).each do |offset|
    u = build_usable.call(offset)
    next if u[:usable].empty? || u[:comp_w] <= 0.0

    top = nil
    second = nil

    fps.each do |rec|
      mism_w = 0.0
      u[:usable].each do |(i, ov, w, _m, _r)|
        exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: rec.fingerprint_id,
          media_item_id: media_item.id,
          segment_index: i + offset
        )
        mism_w += w if exp != ov
      end

      ratio_w = 1.0 - (mism_w / u[:comp_w])
      entry = { ratio_w: ratio_w, rec: rec }

      if top.nil? || ratio_w > top[:ratio_w]
        second = top
        top = entry
      elsif second.nil? || ratio_w > second[:ratio_w]
        second = entry
      end
    end

    next unless top
    second_ratio = second ? second[:ratio_w].to_f : 0.0
    delta = top[:ratio_w].to_f - second_ratio

    score = delta + (top[:ratio_w].to_f * 0.03) + (u[:median_margin].to_f * 0.02) - (offset.to_f * 0.0002)

    if best_score.nil? || score > best_score
      best_score = score
      best_offset = offset
      best_diag = {
        top_ratio_w: top[:ratio_w].to_f,
        second_ratio_w: second_ratio,
        delta: delta,
        comp_w: u[:comp_w],
        usable_count: u[:usable_count],
        median_ratio: u[:median_ratio],
        median_margin: u[:median_margin]
      }
    end
  end

  u = build_usable.call(best_offset)

  candidates = []
  fps.each do |rec|
    mism_w = 0.0
    mism = 0
    comp = 0

    u[:usable].each do |(i, ov, w, _m, _r)|
      exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
        fingerprint_id: rec.fingerprint_id,
        media_item_id: media_item.id,
        segment_index: i + best_offset
      )
      comp += 1
      if exp != ov
        mism += 1
        mism_w += w
      end
    end

    next if comp == 0 || u[:comp_w] <= 0.0

    candidates << {
      user_id: rec.user_id,
      username: rec.user&.username,
      fingerprint_id: rec.fingerprint_id,
      best_offset_segments: best_offset,
      mismatches: mism,
      compared: comp,
      mismatches_weighted: mism_w.round(6),
      compared_weighted: u[:comp_w].round(6),
      match_ratio: (1.0 - (mism.to_f / comp.to_f)).round(4),
      match_ratio_weighted: (1.0 - (mism_w / u[:comp_w])).round(4),
      local_best_offset_segments: best_offset,
      local_match_ratio: (1.0 - (mism_w / u[:comp_w])).round(4),
    }
  end

  candidates.sort_by! { |c| [-c[:match_ratio_weighted].to_f, -c[:compared].to_i] }

  # Reference-derived observed variants/confidences (for UI).
  ref_obs = Array.new(scores.length)
  ref_conf = Array.new(scores.length, 0.0)
  u[:usable].each do |(i, ov, _w, margin, ratio)|
    ref_obs[i] = ov
    c = margin.to_f
    c *= 0.5 if ratio.to_f > 1.0
    ref_conf[i] = c.round(4)
  end

  top = candidates[0]
  second = candidates[1]

  meta = {
    offset_strategy: "global_reference",
    chosen_offset_segments: best_offset,
    reference_used: true,
    reference_delta_median: delta_med.round(4),
    reference_min_delta: min_delta.round(4),
    reference_median_margin: (best_diag ? best_diag[:median_margin].to_f : 0.0).round(4),
    reference_median_ratio: (best_diag ? best_diag[:median_ratio].to_f : 0.0).round(4),
    effective_samples: u[:usable_count].to_f.round(2),
    offset_top_match_ratio: (best_diag ? best_diag[:top_ratio_w].to_f : top&.dig(:match_ratio_weighted).to_f).round(4),
    offset_second_match_ratio: (best_diag ? best_diag[:second_ratio_w].to_f : second&.dig(:match_ratio_weighted).to_f).round(4),
    offset_delta: (best_diag ? best_diag[:delta].to_f : (top&.dig(:match_ratio_weighted).to_f - second&.dig(:match_ratio_weighted).to_f)).round(4),
    reference_observed_variants: ref_obs,
    reference_observed_confidences: ref_conf
  }

  annotate_candidate_debugs!(candidates: candidates, observed_variants: ref_obs, media_item_id: media_item.id)
  apply_top_candidate_debug_to_meta!(meta: meta, candidates: candidates)

  { candidates: candidates, meta: meta }
end

    private_class_method :match_fingerprints_with_reference

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
