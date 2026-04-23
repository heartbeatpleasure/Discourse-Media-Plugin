# frozen_string_literal: true

require "open3"
require "json"
require "digest"
require "fileutils"
require "tmpdir"

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

    # Inverted polarity is a useful rescue path for some screen recordings,
    # but we only want to use it when it is clearly better than normal polarity.
    POLARITY_SWITCH_MIN_TOP_RATIO = 0.62
    POLARITY_SWITCH_MIN_RATIO_GAIN = 0.03
    POLARITY_SWITCH_MIN_DELTA_GAIN = 0.03
    POLARITY_SWITCH_MIN_SCORE_GAIN = 0.01
    POLARITY_SWITCH_MAX_DELTA_REGRESSION = 0.015

    # Chunked re-sync: for longer leaked clips, one global offset/phase can drift.
    # We therefore allow local offset re-selection per chunk and aggregate the chunks.
    CHUNKED_RESYNC_WINDOW_SEGMENTS = 8
    CHUNKED_RESYNC_MIN_TOTAL_SAMPLES = 12
    CHUNKED_RESYNC_MIN_LOCAL_USABLE = 4

    # Iteration 1: prefer shortlist evidence that remains stable across local windows
    # instead of relying on one global agreement ratio only.
    CANDIDATE_EVIDENCE_CHUNK_SIZE = 8
    SHORTLIST_LIMIT = 10
    SHORTLIST_VERIFY_LIMIT = 4
    CANDIDATE_EVIDENCE_LOCAL_OFFSET_RADIUS = 6
    CANDIDATE_EVIDENCE_LOCAL_OFFSET_PENALTY = 0.02
    ANCHORED_SHORTLIST_STRONG_TRUST = 0.72
    ANCHORED_SHORTLIST_MODERATE_TRUST = 0.45
    ANCHORED_SHORTLIST_STRONG_WINDOW_SEGMENTS = 12
    ANCHORED_SHORTLIST_MODERATE_WINDOW_SEGMENTS = 24
    CANDIDATE_ANCHOR_SHIFT_PENALTY = 0.05
    CANDIDATE_POLARITY_REVIEW_MAX_SCORE_DELTA = 0.02

    # Standard chunk-comparison decoder for file-mode: instead of relying only on
    # absolute per-candidate evidence, compare shortlist candidates chunk-by-chunk
    # and aggregate the relative margins. This is especially helpful when two users
    # look globally close but separate better in local windows.
    PAIRWISE_CHUNK_DECODER_MIN_ENTRIES = 10
    PAIRWISE_CHUNK_DECODER_CHUNK_SIZE = 8
    PAIRWISE_CHUNK_DECODER_CHUNK_STEP = 4
    PAIRWISE_CHUNK_DECODER_MIN_CHUNKS = 2
    PAIRWISE_CHUNK_DECODER_LOCAL_OFFSET_RADIUS = 10
    PAIRWISE_CHUNK_DECODER_MARGIN_WEIGHT = 0.9
    PAIRWISE_CHUNK_DECODER_WIN_WEIGHT = 0.22
    PAIRWISE_CHUNK_DECODER_LOSS_WEIGHT = 0.18
    PAIRWISE_OVERTURN_MIN_CHUNKS = 4
    PAIRWISE_OVERTURN_MIN_MARGIN = 1.35
    PAIRWISE_OVERTURN_MAX_EVIDENCE_GAP = 0.08

    DISCRIMINATIVE_SHORTLIST_MAX_CANDIDATES = 2
    DISCRIMINATIVE_SHORTLIST_MIN_ENTRIES = 10
    DISCRIMINATIVE_SHORTLIST_MIN_DIFF_POSITIONS = 6
    DISCRIMINATIVE_SHORTLIST_MARGIN_WEIGHT = 1.15
    DISCRIMINATIVE_SHORTLIST_WIN_WEIGHT = 0.28
    DISCRIMINATIVE_SHORTLIST_LOSS_WEIGHT = 0.22
    DISCRIMINATIVE_SHORTLIST_TIE_THRESHOLD = 0.04
    DISCRIMINATIVE_SHORTLIST_MAX_EVIDENCE_GAP = 4.0
    DISCRIMINATIVE_SHORTLIST_MAX_RANK_GAP = 6.0
    DISCRIMINATIVE_SHORTLIST_OVERTURN_MIN_MARGIN = 0.9
    PAIRWISE_CHUNK_DECODER_MIN_REMAINING_SECONDS = 12.0
    DISCRIMINATIVE_SHORTLIST_MIN_REMAINING_SECONDS = 8.0
    PAIRWISE_CHUNK_DECODER_MAX_CANDIDATES = 3
    TARGETED_FILL_MIN_REMAINING_SECONDS = 5.0
    TARGETED_FILL_MAX_SEGMENTS = 15
    TARGETED_FILL_MIN_IMPROVEMENT = 0.12
    TARGETED_FILL_FLIP_MIN_PAIRWISE_MARGIN = 10.0
    TARGETED_FILL_FLIP_MIN_PAIRWISE_WINS = 6
    TARGETED_FILL_FLIP_MIN_RANK_GAP = 18.0
    TARGETED_FILL_FLIP_MIN_EVIDENCE_GAP = 6.0
    TARGETED_FILL_FLIP_MIN_MATCH_DELTA = 0.18
    TARGETED_FILL_FLIP_MIN_WEIGHTED_DELTA = 0.16
    TARGETED_FILL_FLIP_MIN_TOP_EVIDENCE = 2.0
    TARGETED_FILL_FLIP_MAX_SECOND_MATCH = 0.46
    TARGETED_FILL_FLIP_MAX_SECOND_EVIDENCE = -4.0
    TARGETED_FILL_FLIP_MIN_SYNC_RATIO = 0.45
    TARGETED_FILL_LOW_CONFIDENCE = 0.42
    TARGETED_FILL_NEIGHBORHOOD = 1
    TARGETED_FILL_MIN_DIFF_POSITIONS = 4
    TARGETED_FILL_TAIL_RESERVE = 4
    TARGETED_FILL_TAIL_FRACTION = 0.28

    FILEMODE_AUTO_MAX_OFFSET_MARGIN_SEGMENTS = 8
    FILEMODE_AUTO_MAX_OFFSET_HARD_CAP = 720

    def normalize_filemode_time_budget_seconds(value)
      v = value.to_f
      v = FILEMODE_TIME_BUDGET_SECONDS.to_f if v <= 0.0
      v
    end
    private_class_method :normalize_filemode_time_budget_seconds

    def identify_from_file(media_item:, file_path:, max_samples: DEFAULT_MAX_SAMPLES, max_offset_segments: DEFAULT_MAX_OFFSET_SEGMENTS, layout: nil, sample_times: nil, time_budget_seconds: nil)
      raise ArgumentError, "missing media_item" if media_item.blank?
      raise ArgumentError, "missing file" if file_path.blank? || !File.exist?(file_path)

      with_packaged_hls_context(media_item: media_item) do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        filemode_budget_seconds = normalize_filemode_time_budget_seconds(time_budget_seconds)

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

        codebook_scheme = ::MediaGallery::Fingerprinting.codebook_scheme_for(
          layout: spec[:layout].to_s.presence || layout.to_s
        )
        previous_codebook_scheme = ::MediaGallery::Fingerprinting.current_thread_codebook_scheme
        Thread.current[:media_gallery_fingerprint_codebook_scheme] = codebook_scheme
        begin
          file_size_bytes = (File.size(file_path) rescue nil)
          probed_duration_seconds = probe_duration_seconds(file_path)

          packaged_midpoints = sample_times.presence || packaged_segment_midpoints_for(media_item: media_item)
          packaged_duration_seconds = packaged_total_duration_for(media_item: media_item)
          inferred_sample_plan =
            if sample_times.present?
              nil
            else
              file_keyframe_segment_sample_plan(
                file_path: file_path,
                duration_seconds: probed_duration_seconds,
                segment_seconds: seg,
                packaged_sample_times: packaged_midpoints
              )
            end

          keyframe_plan_rejected_reason = nil
          use_inferred_sample_plan = false
          if inferred_sample_plan&.dig(:usable)
            if packaged_midpoints.present?
              keyframe_plan_rejected_reason = "packaged_playlist_midpoints_preferred"
            elsif packaged_duration_seconds.to_f > 0.0 && probed_duration_seconds.to_f > 0.0 &&
                  probed_duration_seconds.to_f >= (packaged_duration_seconds.to_f * 0.9)
              keyframe_plan_rejected_reason = "near_full_clip_prefers_packaged_timing"
            else
              use_inferred_sample_plan = true
            end
          elsif inferred_sample_plan.present?
            keyframe_plan_rejected_reason = inferred_sample_plan[:reason].to_s.presence || "keyframe_plan_not_usable"
          end

          sample_times = use_inferred_sample_plan ? inferred_sample_plan[:points] : packaged_midpoints

          offset_window_profile = filemode_offset_window_profile(
            requested_max_offset_segments: max_offset_segments,
            sample_times: sample_times,
            duration_seconds: probed_duration_seconds,
            segment_seconds: seg
          )
          effective_max_offset_segments = offset_window_profile[:effective].to_i

          obs, match = identify_with_phase_search(
            media_item: media_item,
            file_path: file_path,
            segment_seconds: seg,
            spec: spec,
            max_samples: max_samples,
            sample_times: sample_times,
            file_size_bytes: file_size_bytes,
            started_at: started_at,
            time_budget_seconds: filemode_budget_seconds,
            max_offset_segments: effective_max_offset_segments
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
              time_budget_seconds: filemode_budget_seconds
            )

            match = match_fingerprints(
              media_item: media_item,
              observed_variants: obs[:variants],
              observed_confidences: obs[:confidences],
              observed_scores: obs[:scores],
              observed_sync_variants: obs[:sync_variants],
              observed_sync_confidences: obs[:sync_confidences],
              observed_segment_indices: obs[:segment_indices],
              observed_quality_hints: obs[:quality_hints],
              spec: spec,
              max_offset_segments: effective_max_offset_segments,
              started_at: started_at,
              time_budget_seconds: filemode_budget_seconds
            )
          end

          match[:meta] ||= {}
          match[:meta][:file_sample_time_source] ||= if use_inferred_sample_plan
            inferred_sample_plan[:source].to_s.presence || "file_keyframe_midpoints"
          elsif packaged_midpoints.present?
            "packaged_playlist_midpoints"
          else
            "uniform_segment_midpoints"
          end
          if inferred_sample_plan.present?
            match[:meta][:file_keyframe_plan_considered] = true
            match[:meta][:file_keyframe_count] = inferred_sample_plan[:keyframe_count].to_i if inferred_sample_plan[:keyframe_count]
            match[:meta][:file_keyframe_interval_median] = inferred_sample_plan[:interval_median].to_f.round(4) if inferred_sample_plan[:interval_median]
            match[:meta][:file_keyframe_interval_consistency] = inferred_sample_plan[:interval_consistency].to_f.round(4) if inferred_sample_plan[:interval_consistency]
            match[:meta][:file_keyframe_plan_points] = Array(inferred_sample_plan[:points]).length if inferred_sample_plan[:points]
            match[:meta][:file_keyframe_plan_expanded] = (inferred_sample_plan[:expanded] == true)
            match[:meta][:file_keyframe_plan_used] = use_inferred_sample_plan
            match[:meta][:file_keyframe_plan_rejected_reason] = keyframe_plan_rejected_reason if keyframe_plan_rejected_reason.present?
          end

          refined = maybe_refine_filemode_observations(
            media_item: media_item,
            file_path: file_path,
            obs: obs,
            match: match,
            segment_seconds: seg,
            spec: spec,
            started_at: started_at,
            time_budget_seconds: filemode_budget_seconds,
            max_offset_segments: effective_max_offset_segments
          )

          if refined.present?
            obs = refined[:obs] if refined[:obs].present?
            match = refined[:match] if refined[:match].present?
          end

          targeted_fill = maybe_targeted_fill_filemode_observations(
            media_item: media_item,
            file_path: file_path,
            obs: obs,
            match: match,
            segment_seconds: seg,
            spec: spec,
            sample_times: sample_times,
            started_at: started_at,
            time_budget_seconds: filemode_budget_seconds,
            max_offset_segments: effective_max_offset_segments
          )
          if targeted_fill.present?
            obs = targeted_fill[:obs] if targeted_fill[:obs].present?
            match = targeted_fill[:match] if targeted_fill[:match].present?
          end

          match[:meta] ||= {}
          match[:meta][:offset_expansion_applied] = (effective_max_offset_segments.to_i > max_offset_segments.to_i)
          match[:meta][:offset_window_autocapped] = (effective_max_offset_segments.to_i < max_offset_segments.to_i)
          match[:meta][:offset_expansion_reason] = if effective_max_offset_segments.to_i > max_offset_segments.to_i
            "auto_expanded_to_cover_partial_or_shifted_clip"
          else
            offset_window_profile[:reason].to_s
          end
          match[:meta][:offset_window_reason] = offset_window_profile[:reason].to_s
          match[:meta][:estimated_clip_segments] = offset_window_profile[:estimated_clip_segments].to_i
          match[:meta][:sampled_packaged_segments] = offset_window_profile[:total_segments].to_i
          match[:meta][:clip_segment_coverage_ratio] = offset_window_profile[:coverage_ratio].to_f.round(4)

          unless match[:meta].key?(:multisample_refine_used)
            multisample_diag = filemode_multisample_refine_diagnostics(
              obs: obs,
              match: match,
              started_at: started_at,
              budget_seconds: filemode_budget_seconds
            )
            match[:meta][:multisample_refine_used] = false
            match[:meta][:multisample_refine_applied] = false
            match[:meta][:multisample_refine_reason] = multisample_diag[:reason]
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
              sync_period: Array(spec[:sync_pattern]).length,
              sync_pairs_count: Array(spec[:sync_pairs]).length,
              ecc_scheme: codebook_scheme.to_s.presence || (::MediaGallery::Fingerprinting.respond_to?(:ecc_profile) ? ::MediaGallery::Fingerprinting.ecc_profile[:scheme] : "none"),
              duration_seconds: obs[:duration_seconds],
              samples: obs[:variants].length,
              usable_samples: obs[:variants].count { |v| v.present? },
              filemode_elapsed_seconds: obs[:elapsed_seconds],
              filemode_truncated: obs[:truncated],
              effective_max_samples: obs[:effective_max_samples],
              configured_filemode_engine_time_budget_seconds: filemode_budget_seconds,
              filemode_budget_exhausted: (obs[:budget_exhausted] == true || match_meta[:phase_search_budget_exhausted] == true || match_meta[:budget_exhausted] == true),
              requested_max_offset_segments: max_offset_segments.to_i,
              effective_max_offset_segments: effective_max_offset_segments.to_i,
            }.merge(match_meta),
            observed: {
              variants: format_variant_sequence(obs[:variants]),
              variants_compact: Array(obs[:variants]).compact.join(""),
              variants_array: Array(obs[:variants]),
              segment_indices: Array(obs[:segment_indices]),
              confidences: obs[:confidences],
            },
            candidates: matches,
          }

          # Ensure we only return string keys so controllers can safely merge into
          # result["meta"] without creating duplicate :meta and "meta" hashes.
          result = result.deep_stringify_keys if result.respond_to?(:deep_stringify_keys)
          result
        ensure
          Thread.current[:media_gallery_fingerprint_codebook_scheme] = previous_codebook_scheme
        end
      end
    end

    def with_packaged_hls_context(media_item:)
      context = build_packaged_hls_context(media_item: media_item)
      previous = Thread.current[:media_gallery_forensics_identify_packaged_hls_context]
      Thread.current[:media_gallery_forensics_identify_packaged_hls_context] = context if context.present?

      yield
    ensure
      Thread.current[:media_gallery_forensics_identify_packaged_hls_context] = previous
      cleanup_packaged_hls_context!(context) if context.present? && context != previous
    end
    private_class_method :with_packaged_hls_context

    def build_packaged_hls_context(media_item:)
      access = managed_hls_access_for(media_item)
      return nil unless access.present?

      prefix = access.dig(:role, "key_prefix").to_s.presence
      return nil if prefix.blank?

      keys = Array(access[:store].list_prefix(prefix)).compact.map(&:to_s).uniq.sort
      return nil if keys.blank?

      root = build_packaged_hls_workspace_root
      keys.each do |key|
        next if key.blank?

        rel = key.sub(%r{\A#{Regexp.escape(prefix)}/?}, "")
        next if rel.blank?

        destination = File.join(root, rel)
        access[:store].download_to_file!(key, destination)
      end

      {
        public_id: media_item.public_id.to_s,
        root: root,
        source: "managed",
        backend: access[:store].backend.to_s,
        profile_key: media_item.try(:managed_storage_profile).to_s.presence,
      }
    rescue => e
      begin
        Rails.logger.warn(
          "[media_gallery] forensics identify staged HLS context failed public_id=#{media_item&.public_id} "           "error=#{e.class}: #{e.message}"
        )
      rescue
        nil
      end
      cleanup_packaged_hls_context!({ root: root }) if root.present?
      nil
    end
    private_class_method :build_packaged_hls_context

    def build_packaged_hls_workspace_root
      configured_root = ::MediaGallery::StorageSettingsResolver.processing_root_path
      if configured_root.present?
        FileUtils.mkdir_p(configured_root)
        Dir.mktmpdir("media-gallery-forensics-hls", configured_root)
      else
        Dir.mktmpdir("media-gallery-forensics-hls")
      end
    end
    private_class_method :build_packaged_hls_workspace_root

    def cleanup_packaged_hls_context!(context)
      root = context.is_a?(Hash) ? context[:root].to_s : nil
      return if root.blank? || !Dir.exist?(root)

      FileUtils.rm_rf(root)
    rescue
      nil
    end
    private_class_method :cleanup_packaged_hls_context!

    def managed_hls_access_for(media_item)
      return nil if media_item.blank?

      role = ::MediaGallery::Hls.managed_role_for(media_item)
      return nil unless role.present?
      return nil unless ::MediaGallery::Hls.managed_role_ready?(media_item, role)

      store = ::MediaGallery::Hls.store_for_managed_role(media_item, role)
      return nil if store.blank?

      { role: role.deep_stringify_keys, store: store }
    rescue => e
      begin
        Rails.logger.warn(
          "[media_gallery] forensics identify managed HLS access failed public_id=#{media_item&.public_id} "           "error=#{e.class}: #{e.message}"
        )
      rescue
        nil
      end
      nil
    end
    private_class_method :managed_hls_access_for

    def packaged_hls_root_for(media_item:)
      context = Thread.current[:media_gallery_forensics_identify_packaged_hls_context]
      if context.is_a?(Hash) && context[:public_id].to_s == media_item.public_id.to_s
        root = context[:root].to_s
        return root if root.present? && Dir.exist?(root)
      end

      return nil unless defined?(::MediaGallery::PrivateStorage)

      root = ::MediaGallery::PrivateStorage.hls_root_abs_dir(media_item.public_id)
      return root if root.present? && Dir.exist?(root)

      nil
    rescue
      nil
    end
    private_class_method :packaged_hls_root_for

    def packaged_variant_playlist_path_for(media_item:, variant:)
      root = packaged_hls_root_for(media_item: media_item)
      return nil if root.blank?

      path = File.join(root, variant.to_s, "index.m3u8")
      File.exist?(path) ? path : nil
    rescue
      nil
    end
    private_class_method :packaged_variant_playlist_path_for

    # ----------------------------------------------------------------------

    def detect_layout_for(media_item:)
      # Prefer the metadata file written during packaging.
      begin
        root = packaged_hls_root_for(media_item: media_item)
        meta_path = File.join(root, "fingerprint_meta.json") if root.present?
        if meta_path.present? && File.exist?(meta_path)
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
      root = packaged_hls_root_for(media_item: media_item)
      return nil if root.blank?

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
      deep_symbolize(h)
    end
    private_class_method :symbolize_spec

    def deep_symbolize(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          kk = k.respond_to?(:to_sym) ? k.to_sym : k
          acc[kk] = deep_symbolize(v)
        end
      when Array
        value.map { |v| deep_symbolize(v) }
      else
        value
      end
    end
    private_class_method :deep_symbolize

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

      base_points, effective_cap = build_filemode_sample_points(
        duration_seconds: duration,
        segment_seconds: segment_seconds,
        sample_times: sample_times,
        max_samples: max_samples,
        file_size_bytes: file_size_bytes,
        time_budget_seconds: time_budget_seconds
      )
      return [nil, nil] if base_points.blank?

      coarse = run_phase_search_pass(
        media_item: media_item,
        file_path: file_path,
        segment_seconds: segment_seconds,
        spec: spec,
        base_points: base_points,
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

      refinement = phase_search_refinement_decision(
        match: best_match,
        remaining_seconds: time_remaining_seconds(started_at: started_at, budget_seconds: time_budget_seconds)
      )

      if refinement[:run]
        fine = run_phase_search_pass(
          media_item: media_item,
          file_path: file_path,
          segment_seconds: segment_seconds,
          spec: spec,
          base_points: base_points,
          duration_seconds: duration,
          effective_max_samples: effective_cap,
          started_at: started_at,
          time_budget_seconds: time_budget_seconds,
          max_offset_segments: max_offset_segments,
          dense_step_seconds: DENSE_SAMPLE_STEP_FINE
        )

        fine_score = phase_result_score(match: fine[:match])
        use_fine = fine_score >= best_score
        if use_fine
          best_obs = fine[:obs]
          best_match = fine[:match]
          best_score = fine_score
        end

        best_match[:meta] ||= {}
        best_match[:meta][:phase_search_refinement_attempted] = true
        best_match[:meta][:phase_search_refinement_applied] = use_fine
        best_match[:meta][:phase_search_refinement_reason] = refinement[:reason]
        best_match[:meta][:phase_search_coarse_score] = coarse[:match].present? ? phase_result_score(match: coarse[:match]).round(4) : nil
        best_match[:meta][:phase_search_fine_score] = fine[:match].present? ? fine_score.round(4) : nil
        best_match[:meta][:phase_search_refinement_rejected_reason] = (use_fine ? nil : "coarse_score_better")
      else
        best_match[:meta] ||= {}
        best_match[:meta][:phase_search_refinement_attempted] = false
        best_match[:meta][:phase_search_refinement_applied] = false
        best_match[:meta][:phase_search_refinement_reason] = refinement[:reason]
      end

      [best_obs, best_match]
    rescue
      [nil, nil]
    end
    private_class_method :identify_with_phase_search

    def run_phase_search_pass(media_item:, file_path:, segment_seconds:, spec:, base_points:, duration_seconds:, effective_max_samples:, started_at:, time_budget_seconds:, max_offset_segments:, dense_step_seconds:)
      dense = extract_dense_observed_variants(
        file_path: file_path,
        spec: spec,
        base_points: base_points,
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
          base_points: base_points,
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
          observed_sync_variants: obs[:sync_variants],
          observed_sync_confidences: obs[:sync_confidences],
          observed_segment_indices: obs[:segment_indices],
          spec: spec,
          max_offset_segments: max_offset_segments,
          started_at: started_at,
          time_budget_seconds: time_budget_seconds
        )

        meta = match[:meta] || {}
        meta[:phase_search_used] = true
        meta[:chosen_phase_seconds] = phase_seconds.round(3)
        meta[:phase_candidates_seconds] ||= phase_candidates.map { |v| v.round(3) }
        meta[:dense_step_seconds] = dense_step_seconds.round(3)
        meta[:dense_samples] = Array(dense[:times]).length
        meta[:phase_search_refined] = (dense_step_seconds.to_f <= DENSE_SAMPLE_STEP_FINE.to_f)
        meta[:phase_search_budget_exhausted] = (dense[:budget_exhausted] == true)
        meta[:phase_multiframe_points_per_segment] = obs[:phase_multiframe_points_per_segment].to_i
        meta[:phase_multiframe_offset_seconds] = obs[:phase_multiframe_offset_seconds].to_f.round(3)
        match[:meta] = meta

        obs[:budget_exhausted] = (dense[:budget_exhausted] == true)
        phase_results << { obs: obs, match: match }
      end

      best = phase_results.max_by { |entry| phase_result_score(match: entry[:match]) }
      best || { obs: nil, match: nil }
    end
    private_class_method :run_phase_search_pass

    def extract_dense_observed_variants(file_path:, spec:, base_points:, duration_seconds:, effective_max_samples:, segment_seconds:, step_seconds:, started_at:, time_budget_seconds:)
      step = step_seconds.to_f
      step = DENSE_SAMPLE_STEP_DEFAULT.to_f if step <= 0.0

      budget = time_budget_seconds.to_f
      budget = FILEMODE_TIME_BUDGET_SECONDS.to_f if budget <= 0.0

      max_target_time = Array(base_points).map { |p| p[:time].to_f }.max.to_f
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
        budget_exhausted: budget_exceeded.call,
      }
    end
    private_class_method :extract_dense_observed_variants

    def build_phase_observation_from_dense(dense:, base_points:, duration_seconds:, phase_seconds:, segment_seconds:, effective_max_samples:)
      variants = []
      confidences = []
      scores = []
      used_times = []
      segment_indices = []
      voting_points = 1
      voting_offset_seconds = 0.0

      Array(base_points).each do |point|
        target_time = clamp_time(point[:time].to_f + phase_seconds.to_f, duration_seconds: duration_seconds)
        sample = aggregate_dense_phase_sample(
          dense: dense,
          target_time: target_time,
          duration_seconds: duration_seconds,
          segment_seconds: segment_seconds
        )
        used_times << target_time.round(3)
        segment_indices << point[:segment_index].to_i

        if sample.blank?
          variants << nil
          confidences << 0.0
          scores << 0.0
          next
        end

        voting_points = [voting_points, sample[:points_used].to_i].max
        voting_offset_seconds = [voting_offset_seconds, sample[:offset_seconds].to_f].max

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
        segment_indices: segment_indices,
        layout: dense[:layout].to_s,
        truncated: !!dense[:truncated],
        elapsed_seconds: elapsed,
        effective_max_samples: effective_max_samples,
        phase_seconds: phase_seconds.to_f,
        dense_step_seconds: dense[:dense_step_seconds].to_f,
        phase_multiframe_points_per_segment: voting_points,
        phase_multiframe_offset_seconds: voting_offset_seconds.round(3),
      }
    end
    private_class_method :build_phase_observation_from_dense

    def aggregate_dense_phase_sample(dense:, target_time:, duration_seconds:, segment_seconds:)
      offsets = dense_phase_vote_offsets(segment_seconds: segment_seconds, dense_step_seconds: dense[:dense_step_seconds])
      samples = offsets.filter_map do |delta|
        tt = clamp_time(target_time.to_f + delta.to_f, duration_seconds: duration_seconds)
        interpolate_dense_sample(dense: dense, target_time: tt)
      end
      return nil if samples.empty?

      {
        score: median(samples.map { |sample| sample[:score].to_f }).to_f,
        confidence: median(samples.map { |sample| sample[:confidence].to_f }).to_f,
        points_used: samples.length,
        offset_seconds: offsets.map(&:abs).max.to_f,
      }
    rescue
      interpolate_dense_sample(dense: dense, target_time: target_time)
    end
    private_class_method :aggregate_dense_phase_sample

    def dense_phase_vote_offsets(segment_seconds:, dense_step_seconds:)
      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      dense_step = dense_step_seconds.to_f
      dense_step = DENSE_SAMPLE_STEP_DEFAULT.to_f if dense_step <= 0.0

      offset = [seg * 0.18, dense_step].max
      offset = [offset, seg * 0.32].min
      offset = [offset, 0.25].max

      [-offset.round(3), 0.0, offset.round(3)].uniq
    rescue
      [0.0]
    end
    private_class_method :dense_phase_vote_offsets

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

    def phase_search_refinement_decision(match:, remaining_seconds:)
      return { run: false, reason: "no_match_available" } if match.blank?
      return { run: false, reason: "insufficient_time_budget" } if remaining_seconds.to_f < 5.0

      if phase_search_needs_refinement?(match: match)
        { run: true, reason: "coarse_result_needs_more_alignment_precision" }
      else
        { run: false, reason: "coarse_result_already_stable" }
      end
    rescue
      { run: false, reason: "phase_refinement_decision_failed" }
    end
    private_class_method :phase_search_refinement_decision

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


    def should_run_filemode_multisample_refine?(obs:, match:, started_at:, budget_seconds:)
      filemode_multisample_refine_diagnostics(obs: obs, match: match, started_at: started_at, budget_seconds: budget_seconds)[:run]
    rescue
      false
    end
    private_class_method :should_run_filemode_multisample_refine?

    def filemode_multisample_refine_diagnostics(obs:, match:, started_at:, budget_seconds:)
      return { run: false, reason: "missing_observation_or_match" } if obs.blank? || match.blank?

      times = Array(obs[:times])
      return { run: false, reason: "missing_sample_times" } if times.blank?

      remaining = time_remaining_seconds(started_at: started_at, budget_seconds: budget_seconds)
      return { run: false, reason: "insufficient_time_budget" } if remaining < 8.0

      meta = match[:meta] || {}
      cands = Array(match[:candidates])
      usable = Array(obs[:variants]).count { |v| v.present? }
      return { run: false, reason: "too_few_usable_samples", usable: usable } if usable < 8

      top_ratio = cands[0] ? cands[0][:match_ratio_weighted].to_f : 0.0
      top_ratio = cands[0][:match_ratio].to_f if top_ratio <= 0.0 && cands[0]
      delta = meta[:offset_delta].to_f
      delta = top_ratio - (cands[1] ? cands[1][:match_ratio_weighted].to_f : 0.0) if delta <= 0.0

      if meta[:polarity_flip_used] == true
        return { run: true, reason: "polarity_flip_needs_verification", usable: usable, top_ratio: top_ratio.round(4), delta: delta.round(4) }
      end

      if top_ratio < 0.86
        return { run: true, reason: "top_ratio_still_weak", usable: usable, top_ratio: top_ratio.round(4), delta: delta.round(4) }
      end

      if delta < 0.45
        return { run: true, reason: "top2_separation_still_weak", usable: usable, top_ratio: top_ratio.round(4), delta: delta.round(4) }
      end

      { run: false, reason: "current_result_already_stable", usable: usable, top_ratio: top_ratio.round(4), delta: delta.round(4) }
    rescue
      { run: false, reason: "multisample_refine_decision_failed" }
    end
    private_class_method :filemode_multisample_refine_diagnostics

    def refine_observed_variants_multi_sample(file_path:, obs:, segment_seconds:, spec:, duration_seconds:, started_at:, time_budget_seconds:)
      times = Array(obs[:times])
      return nil if times.blank?

      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      delta = seg * 0.20
      delta = 0.40 if delta < 0.40
      delta = 0.90 if delta > 0.90

      chunk_size = FILEMODE_SAMPLE_CHUNK.to_i
      chunk_size = 15 if chunk_size <= 0
      budget = normalize_filemode_time_budget_seconds(time_budget_seconds)
      total_duration = duration_seconds.to_f
      total_duration = 0.0 if total_duration.nan? || total_duration.infinite? || total_duration.negative?

      budget_exceeded = lambda do
        next false if started_at.blank?
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f) > budget
      end

      sample_points = Array(obs[:sample_points])
      extra_times = []
      mappings = []
      times.each_with_index do |t_mid, i|
        next if t_mid.blank?
        point = sample_points[i]
        window = sample_point_window(point: point, segment_seconds: seg, duration_seconds: total_duration, center_time: t_mid.to_f)

        local_times = []
        if window.present?
          start_t = window[0].to_f
          end_t = window[1].to_f
          span = end_t - start_t
          if span > 0.18
            local_times << (start_t + (span * 0.32))
            local_times << (start_t + (span * 0.68))
          end
        end

        if local_times.blank?
          local_times << clamp_time(t_mid.to_f - delta, duration_seconds: total_duration)
          local_times << clamp_time(t_mid.to_f + delta, duration_seconds: total_duration)
        end

        local_times.each_with_index do |tt, side|
          extra_times << tt
          mappings << [i, side]
        end
      end

      sampled = []
      used_map = []
      extra_times.each_slice(chunk_size).with_index do |chunk, batch_idx|
        break if budget_exceeded.call
        res = sample_variants_batch_single(file_path: file_path, times: chunk, spec: spec)
        sampled.concat(res)
        start = batch_idx * chunk_size
        used_map.concat(mappings[start, chunk.length])
      end

      return nil if sampled.empty?

      variants = Array(obs[:variants]).dup
      confidences = Array(obs[:confidences]).dup
      scores = Array(obs[:scores]).dup

      per_idx_scores = Hash.new { |h, k| h[k] = [] }
      per_idx_confs = Hash.new { |h, k| h[k] = [] }
      used_map.each_with_index do |(idx, _side), j|
        r = sampled[j] || {}
        per_idx_scores[idx] << r[:score].to_i
        per_idx_confs[idx] << r[:confidence].to_f
      end

      times.each_with_index do |_t, i|
        all_scores = [scores[i].to_i] + per_idx_scores[i]
        all_confs = [confidences[i].to_f] + per_idx_confs[i]
        next if all_scores.empty?

        med_score = median(all_scores)
        med_conf = median(all_confs).to_f.round(4)
        v = med_score >= 0 ? "a" : "b"
        v = nil if med_conf < MIN_CONFIDENCE

        variants[i] = v
        confidences[i] = med_conf
        scores[i] = med_score
      end

      {
        duration_seconds: obs[:duration_seconds],
        variants: variants,
        confidences: confidences,
        scores: scores,
        times: times,
        segment_indices: Array(obs[:segment_indices]).dup,
        layout: obs[:layout],
        truncated: obs[:truncated],
        elapsed_seconds: obs[:elapsed_seconds],
        effective_max_samples: obs[:effective_max_samples],
        budget_exhausted: (obs[:budget_exhausted] == true || budget_exceeded.call),
        multisample_refine_used: true,
        multisample_refine_offset_seconds: delta.round(3),
        multisample_refine_points_per_segment: 3,
        sample_points: sample_points,
      }
    rescue
      nil
    end
    private_class_method :refine_observed_variants_multi_sample

    def maybe_refine_filemode_observations(media_item:, file_path:, obs:, match:, segment_seconds:, spec:, started_at:, time_budget_seconds:, max_offset_segments:)
      decision = filemode_multisample_refine_diagnostics(
        obs: obs,
        match: match,
        started_at: started_at,
        budget_seconds: time_budget_seconds
      )
      return nil unless decision[:run]

      refined_obs = refine_observed_variants_multi_sample(
        file_path: file_path,
        obs: obs,
        segment_seconds: segment_seconds,
        spec: spec,
        duration_seconds: obs[:duration_seconds],
        started_at: started_at,
        time_budget_seconds: time_budget_seconds
      )
      return nil if refined_obs.blank?

      refined_match = match_fingerprints(
        media_item: media_item,
        observed_variants: refined_obs[:variants],
        observed_confidences: refined_obs[:confidences],
        observed_scores: refined_obs[:scores],
        observed_sync_variants: refined_obs[:sync_variants],
        observed_sync_confidences: refined_obs[:sync_confidences],
        observed_segment_indices: refined_obs[:segment_indices],
        observed_quality_hints: refined_obs[:quality_hints],
        spec: spec,
        max_offset_segments: max_offset_segments,
        started_at: started_at,
        time_budget_seconds: time_budget_seconds
      )

      orig_score = phase_result_score(match: match)
      refined_score = phase_result_score(match: refined_match)
      use_refined = refined_score >= (orig_score + 0.005)

      refined_positions = materially_changed_refine_segment_indices(base_obs: obs, refined_obs: refined_obs)
      if use_refined
        refined_obs[:quality_hints] = merge_observation_quality_hints(
          base_obs: obs,
          refined_segment_indices: refined_positions,
        )
      end
      chosen_obs = use_refined ? refined_obs : obs
      chosen_obs[:quality_hints] ||= obs[:quality_hints] if chosen_obs.is_a?(Hash)
      chosen_match = use_refined ? refined_match : match
      chosen_meta = chosen_match[:meta] || {}
      chosen_meta[:multisample_refine_used] = true
      chosen_meta[:multisample_refine_applied] = use_refined
      chosen_meta[:multisample_refine_reason] = decision[:reason]
      chosen_meta[:multisample_refine_score_gain] = (refined_score - orig_score).round(4)
      chosen_meta[:multisample_refine_offset_seconds] = refined_obs[:multisample_refine_offset_seconds]
      chosen_meta[:multisample_refine_points_per_segment] = refined_obs[:multisample_refine_points_per_segment]
      chosen_meta[:multisample_refine_rejected_reason] = (use_refined ? nil : "original_score_better")
      chosen_match[:meta] = chosen_meta

      { obs: chosen_obs, match: chosen_match }
    rescue
      nil
    end
    private_class_method :maybe_refine_filemode_observations

    def targeted_fill_result_score(match:, observed_variants: nil)
      meta = match[:meta] || {}
      cands = Array(match[:candidates])
      top = cands[0] || {}
      second = cands[1] || {}
      rank_gap = meta[:shortlist_rank_gap].to_f
      ev_gap = meta[:shortlist_evidence_gap].to_f
      top_rank = top[:rank_score].to_f
      top_rank = top[:evidence_score].to_f if top_rank <= 0.0
      hard_delta = top[:match_ratio_weighted].to_f - second[:match_ratio_weighted].to_f
      hard_delta = top[:match_ratio].to_f - second[:match_ratio].to_f if hard_delta == 0.0
      usable = Array(observed_variants).count { |v| v.present? }
      (rank_gap * 0.75) + (ev_gap * 0.45) + (hard_delta * 1.8) + (top_rank * 0.03) + (usable * 0.02)
    rescue
      -Float::INFINITY
    end
    private_class_method :targeted_fill_result_score

    def targeted_fill_top_fingerprint_id(match)
      Array(match[:candidates]).first.to_h[:fingerprint_id].to_s
    rescue
      ""
    end
    private_class_method :targeted_fill_top_fingerprint_id

    def targeted_fill_candidate_flip_corroborated?(orig_match:, merged_match:)
      orig_fp = targeted_fill_top_fingerprint_id(orig_match)
      merged_fp = targeted_fill_top_fingerprint_id(merged_match)
      return true if orig_fp.blank? || merged_fp.blank? || orig_fp == merged_fp

      cands = Array(merged_match[:candidates])
      top = cands[0] || {}
      second = cands[1] || {}
      meta = merged_match[:meta] || {}

      pairwise_margin = top[:pairwise_chunk_margin_total].to_f
      pairwise_wins = top[:pairwise_chunks_won].to_i
      pairwise_losses = top[:pairwise_chunks_lost].to_i
      rank_gap = meta[:shortlist_rank_gap].to_f
      evidence_gap = meta[:shortlist_evidence_gap].to_f
      raw_delta = top[:match_ratio].to_f - second[:match_ratio].to_f
      weighted_delta = top[:match_ratio_weighted].to_f - second[:match_ratio_weighted].to_f
      top_evidence = top[:evidence_score].to_f
      second_evidence = second[:evidence_score].to_f
      second_ratio = second[:match_ratio].to_f
      sync_used = meta[:sync_anchor_used] == true
      sync_ratio = meta[:sync_anchor_best_ratio].to_f

      pairwise_corroborated =
        pairwise_margin >= TARGETED_FILL_FLIP_MIN_PAIRWISE_MARGIN &&
          pairwise_wins >= TARGETED_FILL_FLIP_MIN_PAIRWISE_WINS &&
          pairwise_wins >= (pairwise_losses + 3) &&
          rank_gap >= TARGETED_FILL_FLIP_MIN_RANK_GAP &&
          evidence_gap >= TARGETED_FILL_FLIP_MIN_EVIDENCE_GAP &&
          raw_delta >= TARGETED_FILL_FLIP_MIN_MATCH_DELTA &&
          weighted_delta >= TARGETED_FILL_FLIP_MIN_WEIGHTED_DELTA &&
          top_evidence >= TARGETED_FILL_FLIP_MIN_TOP_EVIDENCE &&
          second_ratio <= TARGETED_FILL_FLIP_MAX_SECOND_MATCH &&
          second_evidence <= TARGETED_FILL_FLIP_MAX_SECOND_EVIDENCE

      sync_corroborated =
        sync_used &&
          sync_ratio >= TARGETED_FILL_FLIP_MIN_SYNC_RATIO &&
          rank_gap >= TARGETED_FILL_FLIP_MIN_RANK_GAP &&
          evidence_gap >= TARGETED_FILL_FLIP_MIN_EVIDENCE_GAP &&
          raw_delta >= TARGETED_FILL_FLIP_MIN_MATCH_DELTA &&
          weighted_delta >= TARGETED_FILL_FLIP_MIN_WEIGHTED_DELTA &&
          top_evidence >= TARGETED_FILL_FLIP_MIN_TOP_EVIDENCE &&
          second_ratio <= TARGETED_FILL_FLIP_MAX_SECOND_MATCH

      unanimous_pairwise =
        pairwise_wins >= 7 &&
          pairwise_losses == 0 &&
          rank_gap >= (TARGETED_FILL_FLIP_MIN_RANK_GAP + 10.0) &&
          raw_delta >= (TARGETED_FILL_FLIP_MIN_MATCH_DELTA + 0.08) &&
          weighted_delta >= (TARGETED_FILL_FLIP_MIN_WEIGHTED_DELTA + 0.08)

      pairwise_corroborated || sync_corroborated || unanimous_pairwise
    rescue
      false
    end
    private_class_method :targeted_fill_candidate_flip_corroborated?

    def should_run_targeted_filemode_fill?(obs:, match:, started_at:, budget_seconds:)
      return { run: false, reason: "missing_observation_or_match" } if obs.blank? || match.blank?

      remaining = time_remaining_seconds(started_at: started_at, budget_seconds: budget_seconds)
      return { run: false, reason: "insufficient_time_budget" } if remaining < TARGETED_FILL_MIN_REMAINING_SECONDS

      cands = Array(match[:candidates])
      return { run: false, reason: "no_candidates" } if cands.blank?

      variants = Array(obs[:variants])
      confidences = Array(obs[:confidences])
      nil_or_weak = variants.each_index.count do |i|
        variants[i].blank? || confidences[i].to_f < TARGETED_FILL_LOW_CONFIDENCE
      end
      minimum_uncertain = (cands.length < 2 ? 2 : 4)
      return { run: false, reason: "too_few_uncertain_positions" } if nil_or_weak < minimum_uncertain

      meta = match[:meta] || {}
      rank_gap = meta[:shortlist_rank_gap].to_f
      ev_gap = meta[:shortlist_evidence_gap].to_f
      hard_delta = if cands.length >= 2
        cands[0][:match_ratio].to_f - cands[1][:match_ratio].to_f
      else
        0.0
      end

      if cands.length < 2
        top_compared = cands[0][:compared].to_i
        top_ratio = cands[0][:match_ratio].to_f
        usable = variants.count(&:present?)
        run = usable < [top_compared, Array(obs[:segment_indices]).length].max || top_ratio >= 0.85
        return {
          run: run,
          reason: (run ? "single_candidate_missing_signal" : "single_candidate_already_filled"),
          remaining_seconds: remaining.round(3),
          uncertain_positions: nil_or_weak,
        }
      end

      run = rank_gap < 3.2 || ev_gap < 1.4 || hard_delta.abs < 0.16
      {
        run: run,
        reason: (run ? "weak_separation_with_missing_signal" : "current_result_already_separated"),
        remaining_seconds: remaining.round(3),
        uncertain_positions: nil_or_weak,
      }
    rescue
      { run: false, reason: "targeted_fill_decision_failed" }
    end
    private_class_method :should_run_targeted_filemode_fill?

    def expected_variant_for_candidate_local_segment(candidate:, media_item_id:, local_segment_index:)
      fp = candidate[:fingerprint_id].to_s
      return nil if fp.blank?
      offset = candidate[:best_offset_segments].to_i
      variant = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
        fingerprint_id: fp,
        media_item_id: media_item_id,
        segment_index: local_segment_index.to_i + offset
      )
      if candidate[:polarity_flip_used] == true || candidate[:variant_polarity].to_s == "inverted"
        variant = invert_variant(variant)
      end
      variant
    rescue
      nil
    end
    private_class_method :expected_variant_for_candidate_local_segment

    def build_targeted_fill_segment_indices(obs:, match:, media_item:, segment_seconds:, sample_times: nil)
      cands = Array(match[:candidates])
      top = cands[0] || {}
      second = cands[1] || {}
      return [] if top.blank?

      duration = obs[:duration_seconds].to_f
      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      total_segments = if sample_times.is_a?(Array) && sample_times.present?
        Array(sample_times).each_with_index.count { |t, _i| sample_point_time_value(t) < duration + 0.05 }
      else
        observed_max = Array(obs[:segment_indices]).compact.map(&:to_i).max
        [((duration / seg).ceil), observed_max.to_i + 1].max
      end
      return [] if total_segments <= 0

      conf_by_seg = {}
      Array(obs[:segment_indices]).each_with_index do |seg_idx, idx|
        next if seg_idx.blank?
        conf_by_seg[seg_idx.to_i] = [conf_by_seg[seg_idx.to_i].to_f, Array(obs[:confidences])[idx].to_f].max
      end

      priorities = []
      total_segments.times do |local_seg|
        conf = conf_by_seg[local_seg].to_f
        next if conf >= 0.75

        score = 5.0 - (conf * 4.0)
        score += 1.0 if conf <= 0.0

        if second.present?
          top_v = expected_variant_for_candidate_local_segment(candidate: top, media_item_id: media_item.id, local_segment_index: local_seg)
          second_v = expected_variant_for_candidate_local_segment(candidate: second, media_item_id: media_item.id, local_segment_index: local_seg)
          next if top_v.blank? || second_v.blank? || top_v == second_v
          score += 0.5 if (local_seg % [Array(match.dig(:meta, :phase_candidates_seconds)).length, 4].max).zero? rescue false
        else
          score += 0.8 if conf <= 0.0
          score += 0.35 if local_seg <= 2 || local_seg >= (total_segments - 3)
        end

        priorities << [score, local_seg]
      end

      min_positions = second.present? ? TARGETED_FILL_MIN_DIFF_POSITIONS : 2
      return [] if priorities.length < min_positions

      selected = []
      seen = {}
      priorities.sort_by { |score, seg_idx| [-score, seg_idx] }.each do |_score, seg_idx|
        neighborhood = second.present? ? TARGETED_FILL_NEIGHBORHOOD : 0
        ((seg_idx - neighborhood)..(seg_idx + neighborhood)).each do |probe|
          next if probe < 0 || probe >= total_segments
          next if seen[probe]
          seen[probe] = true
          selected << probe
          break if selected.length >= TARGETED_FILL_MAX_SEGMENTS
        end
        break if selected.length >= TARGETED_FILL_MAX_SEGMENTS
      end

      tail_start = [(total_segments * (1.0 - TARGETED_FILL_TAIL_FRACTION)).floor, 0].max
      tail_added = 0
      tail_candidates = (tail_start...total_segments).to_a.reverse
      tail_candidates.each do |seg_idx|
        break if selected.length >= TARGETED_FILL_MAX_SEGMENTS
        break if tail_added >= TARGETED_FILL_TAIL_RESERVE
        next if seen[seg_idx]
        conf = conf_by_seg[seg_idx].to_f
        next if conf >= TARGETED_FILL_LOW_CONFIDENCE
        seen[seg_idx] = true
        selected << seg_idx
        tail_added += 1
      end

      selected.sort
    rescue
      []
    end
    private_class_method :build_targeted_fill_segment_indices

    def extract_targeted_filemode_segments(file_path:, segment_indices:, segment_seconds:, spec:, duration_seconds:, phase_seconds:, started_at:, time_budget_seconds:)
      segs = Array(segment_indices).map(&:to_i).uniq.sort
      return nil if segs.blank?

      budget = normalize_filemode_time_budget_seconds(time_budget_seconds)
      remaining = time_remaining_seconds(started_at: started_at, budget_seconds: budget)
      return nil if remaining < TARGETED_FILL_MIN_REMAINING_SECONDS

      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      delta = [[seg * 0.18, 0.35].max, 0.90].min
      chunk_size = FILEMODE_SAMPLE_CHUNK.to_i
      chunk_size = 15 if chunk_size <= 0
      use_dense_points = spec.to_h[:layout].to_s == "v8_microgrid" || spec.dig(:analysis, :mode).to_s == "templated_pair_grid_v1"
      point_offsets = if use_dense_points
        [-delta, -(delta * 0.5), 0.0, (delta * 0.5), delta].map { |v| v.round(3) }.uniq
      else
        [-delta, 0.0, delta].map { |v| v.round(3) }.uniq
      end

      times = []
      mapping = []
      segs.each do |seg_idx|
        mid = ((seg_idx.to_f + 0.5) * seg) + phase_seconds.to_f
        mid = clamp_time(mid, duration_seconds: duration_seconds)
        point_offsets.each_with_index do |offset_value, point_idx|
          tt = clamp_time(mid + offset_value.to_f, duration_seconds: duration_seconds)
          times << tt
          mapping << [seg_idx, point_idx, mid]
        end
      end

      sampled = []
      used_mapping = []
      times.each_slice(chunk_size).with_index do |chunk, batch_idx|
        break if time_remaining_seconds(started_at: started_at, budget_seconds: budget) <= 1.0
        res = sample_variants_batch_single(file_path: file_path, times: chunk, spec: spec)
        sampled.concat(Array(res))
        start = batch_idx * chunk_size
        used_mapping.concat(mapping[start, Array(res).length])
      end
      return nil if sampled.blank?

      per_seg_scores = Hash.new { |h, k| h[k] = [] }
      per_seg_confs = Hash.new { |h, k| h[k] = [] }
      per_seg_sync_scores = Hash.new { |h, k| h[k] = [] }
      per_seg_sync_confs = Hash.new { |h, k| h[k] = [] }
      per_seg_mid = {}
      used_mapping.each_with_index do |entry, idx|
        seg_idx, _point_idx, mid = entry
        r = sampled[idx] || {}
        per_seg_scores[seg_idx] << r[:score].to_f
        per_seg_confs[seg_idx] << r[:confidence].to_f
        per_seg_sync_scores[seg_idx] << r[:sync_score].to_f
        per_seg_sync_confs[seg_idx] << r[:sync_confidence].to_f
        per_seg_mid[seg_idx] ||= mid
      end

      variants = []
      confidences = []
      scores = []
      sync_scores = []
      sync_confidences = []
      sync_variants = []
      mids = []
      out_indices = []
      segs.each do |seg_idx|
        sc = per_seg_scores[seg_idx]
        cf = per_seg_confs[seg_idx]
        next if sc.blank?
        med_score = median(sc).to_f
        med_conf = median(cf).to_f.round(4)
        variant = med_score >= 0.0 ? "a" : "b"
        variant = nil if med_conf < MIN_CONFIDENCE
        variants << variant
        confidences << med_conf
        scores << med_score.round(4)
        med_sync_score = median(per_seg_sync_scores[seg_idx]).to_f
        med_sync_conf = median(per_seg_sync_confs[seg_idx]).to_f.round(4)
        sync_scores << med_sync_score.round(4)
        sync_confidences << med_sync_conf
        sync_variants << (med_sync_conf >= MIN_CONFIDENCE ? (med_sync_score >= 0.0 ? "a" : "b") : nil)
        mids << per_seg_mid[seg_idx].to_f.round(3)
        out_indices << seg_idx
      end

      return nil if out_indices.blank?

      {
        duration_seconds: duration_seconds,
        variants: variants,
        confidences: confidences,
        scores: scores,
        sync_scores: sync_scores,
        sync_confidences: sync_confidences,
        sync_variants: sync_variants,
        times: mids,
        segment_indices: out_indices,
        layout: spec[:layout].to_s,
        truncated: false,
        effective_max_samples: out_indices.length,
        budget_exhausted: false,
        targeted_fill_points_per_segment: point_offsets.length,
      }
    rescue
      nil
    end
    private_class_method :extract_targeted_filemode_segments

    def merge_filemode_observations(base_obs:, extra_obs:)
      combined = {}

      [base_obs, extra_obs].each do |src|
        Array(src[:segment_indices]).each_with_index do |seg_idx, idx|
          next if seg_idx.blank?
          key = seg_idx.to_i
          entry = {
            segment_index: key,
            variant: Array(src[:variants])[idx],
            confidence: Array(src[:confidences])[idx].to_f,
            score: Array(src[:scores])[idx].to_f,
            sync_score: Array(src[:sync_scores])[idx].to_f,
            sync_confidence: Array(src[:sync_confidences])[idx].to_f,
            sync_variant: Array(src[:sync_variants])[idx],
            time: Array(src[:times])[idx].to_f,
          }
          current = combined[key]
          if current.nil? || entry[:confidence].to_f > current[:confidence].to_f || (current[:variant].blank? && entry[:variant].present?)
            combined[key] = entry
          end
        end
      end

      ordered = combined.keys.sort.map { |k| combined[k] }
      return nil if ordered.blank?

      {
        duration_seconds: extra_obs[:duration_seconds].presence || base_obs[:duration_seconds],
        variants: ordered.map { |e| e[:variant] },
        confidences: ordered.map { |e| e[:confidence].round(4) },
        scores: ordered.map { |e| e[:score] },
        sync_scores: ordered.map { |e| e[:sync_score].to_f.round(4) },
        sync_confidences: ordered.map { |e| e[:sync_confidence].to_f.round(4) },
        sync_variants: ordered.map { |e| e[:sync_variant] },
        times: ordered.map { |e| e[:time].round(3) },
        segment_indices: ordered.map { |e| e[:segment_index] },
        layout: extra_obs[:layout].presence || base_obs[:layout],
        truncated: (base_obs[:truncated] == true || extra_obs[:truncated] == true),
        elapsed_seconds: base_obs[:elapsed_seconds],
        effective_max_samples: [Array(base_obs[:segment_indices]).length, ordered.length].max,
        budget_exhausted: (base_obs[:budget_exhausted] == true || extra_obs[:budget_exhausted] == true),
      }
    rescue
      nil
    end
    private_class_method :merge_filemode_observations

    def maybe_targeted_fill_filemode_observations(media_item:, file_path:, obs:, match:, segment_seconds:, spec:, sample_times:, started_at:, time_budget_seconds:, max_offset_segments:)
      decision = should_run_targeted_filemode_fill?(obs: obs, match: match, started_at: started_at, budget_seconds: time_budget_seconds)
      return nil unless decision[:run]

      positions = build_targeted_fill_segment_indices(
        obs: obs,
        match: match,
        media_item: media_item,
        segment_seconds: segment_seconds,
        sample_times: sample_times
      )
      return nil if positions.blank?

      extra_obs = extract_targeted_filemode_segments(
        file_path: file_path,
        segment_indices: positions,
        segment_seconds: segment_seconds,
        spec: spec,
        duration_seconds: obs[:duration_seconds],
        phase_seconds: match.dig(:meta, :chosen_phase_seconds).to_f,
        started_at: started_at,
        time_budget_seconds: time_budget_seconds
      )
      return nil if extra_obs.blank?

      merged_obs = merge_filemode_observations(base_obs: obs, extra_obs: extra_obs)
      return nil if merged_obs.blank?

      merged_match = match_fingerprints(
        media_item: media_item,
        observed_variants: merged_obs[:variants],
        observed_confidences: merged_obs[:confidences],
        observed_scores: merged_obs[:scores],
        observed_sync_variants: merged_obs[:sync_variants],
        observed_sync_confidences: merged_obs[:sync_confidences],
        observed_segment_indices: merged_obs[:segment_indices],
        observed_quality_hints: merged_obs[:quality_hints],
        spec: spec,
        max_offset_segments: max_offset_segments,
        started_at: started_at,
        time_budget_seconds: time_budget_seconds
      )

      orig_score = targeted_fill_result_score(match: match, observed_variants: obs[:variants])
      merged_score = targeted_fill_result_score(match: merged_match, observed_variants: merged_obs[:variants])
      flip_corroborated = targeted_fill_candidate_flip_corroborated?(orig_match: match, merged_match: merged_match)
      use_merged = merged_score >= (orig_score + TARGETED_FILL_MIN_IMPROVEMENT) && flip_corroborated

      if use_merged
        merged_obs[:quality_hints] = merge_observation_quality_hints(
          base_obs: obs,
          added_segment_indices: positions,
        )
      end
      chosen_obs = use_merged ? merged_obs : obs
      chosen_obs[:quality_hints] ||= obs[:quality_hints] if chosen_obs.is_a?(Hash)
      chosen_match = use_merged ? merged_match : match
      chosen_meta = chosen_match[:meta] || {}
      chosen_meta[:targeted_fill_used] = true
      chosen_meta[:targeted_fill_applied] = use_merged
      chosen_meta[:targeted_fill_reason] = decision[:reason]
      chosen_meta[:targeted_fill_segments_added] = positions.length
      chosen_meta[:targeted_fill_positions] = positions
      chosen_meta[:targeted_fill_score_gain] = (merged_score - orig_score).round(4)
      chosen_meta[:targeted_fill_points_per_segment] = extra_obs[:targeted_fill_points_per_segment].to_i
      chosen_meta[:targeted_fill_rejected_reason] = if use_merged
        nil
      elsif merged_score < (orig_score + TARGETED_FILL_MIN_IMPROVEMENT)
        "original_result_better"
      else
        "candidate_flip_requires_stronger_corroboration"
      end
      chosen_meta[:targeted_fill_candidate_flip_guard_used] = (targeted_fill_top_fingerprint_id(match) != targeted_fill_top_fingerprint_id(merged_match))
      chosen_match[:meta] = chosen_meta

      { obs: chosen_obs, match: chosen_match }
    rescue
      nil
    end
    private_class_method :maybe_targeted_fill_filemode_observations

    def sample_point_time_value(point)
      if point.is_a?(Hash)
        raw = point[:time]
        raw = point["time"] if raw.blank?
        raw.to_f
      else
        point.to_f
      end
    rescue
      0.0
    end
    private_class_method :sample_point_time_value

    def normalize_filemode_sample_points(sample_times)
      Array(sample_times).each_with_index.map do |entry, idx|
        if entry.is_a?(Hash)
          t = sample_point_time_value(entry)
          next if t.nan? || t.infinite? || t.negative?

          seg_idx = entry[:segment_index]
          seg_idx = entry["segment_index"] if seg_idx.blank?
          seg_idx = idx if seg_idx.blank?

          start_t = entry[:start_time]
          start_t = entry["start_time"] if start_t.blank?
          end_t = entry[:end_time]
          end_t = entry["end_time"] if end_t.blank?

          point = {
            segment_index: seg_idx.to_i,
            time: t.to_f,
          }

          st = start_t.to_f
          et = end_t.to_f
          point[:start_time] = st.round(6) if !st.nan? && !st.infinite? && st >= 0.0
          point[:end_time] = et.round(6) if !et.nan? && !et.infinite? && et > t.to_f
          point
        else
          tt = entry.to_f
          next if tt.nan? || tt.infinite? || tt.negative?
          { segment_index: idx.to_i, time: tt }
        end
      end.compact
    rescue
      []
    end
    private_class_method :normalize_filemode_sample_points

    def sample_point_window(point:, segment_seconds:, duration_seconds:, center_time: nil)
      center = center_time.to_f
      center = sample_point_time_value(point) if center <= 0.0
      if point.is_a?(Hash)
        st = point[:start_time]
        st = point["start_time"] if st.blank?
        et = point[:end_time]
        et = point["end_time"] if et.blank?
        start_t = st.to_f
        end_t = et.to_f
        if !start_t.nan? && !end_t.nan? && end_t > start_t
          return [clamp_time(start_t, duration_seconds: duration_seconds), clamp_time(end_t, duration_seconds: duration_seconds)]
        end
      end

      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0
      half = seg / 2.0
      [
        clamp_time(center - half, duration_seconds: duration_seconds),
        clamp_time(center + half, duration_seconds: duration_seconds),
      ]
    rescue
      nil
    end
    private_class_method :sample_point_window

    def file_keyframe_segment_sample_plan(file_path:, duration_seconds:, segment_seconds:, packaged_sample_times: nil)
      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0

      keyframes = ::MediaGallery::Ffmpeg.probe_keyframe_times(input_path: file_path)
      keyframes = Array(keyframes).map(&:to_f).select { |t| t >= 0.0 && t <= (duration_seconds.to_f + 1.0) }.uniq.sort
      return { usable: false, source: "packaged_playlist_midpoints", reason: "no_keyframes_detected" } if keyframes.length < 3

      first = keyframes.first.to_f
      keyframes.unshift(0.0) if first > 0.08 && first <= [seg * 0.45, 1.0].max

      intervals = keyframes.each_cons(2).map { |a, b| (b.to_f - a.to_f) }.select { |v| v > 0.05 }
      return { usable: false, source: "packaged_playlist_midpoints", reason: "insufficient_keyframe_intervals" } if intervals.length < 2

      median_interval = median(intervals).to_f
      return { usable: false, source: "packaged_playlist_midpoints", reason: "invalid_keyframe_interval" } if median_interval <= 0.0

      consistency_tol = [[seg * 0.22, 0.16].max, 0.75].min
      consistency = intervals.count { |iv| (iv.to_f - median_interval).abs <= consistency_tol }.to_f / intervals.length.to_f

      expanded = false
      if median_interval > 0.0
        expanded_keyframes = [keyframes.first]
        keyframes.each_cons(2) do |a, b|
          gap = b.to_f - a.to_f
          approx_segments = (gap / median_interval).round
          if approx_segments >= 2 && ((gap / median_interval) - approx_segments).abs <= 0.22
            expanded = true
            (1...approx_segments).each do |k|
              expanded_keyframes << (a.to_f + (median_interval * k.to_f)).round(6)
            end
          end
          expanded_keyframes << b.to_f
        end
        keyframes = expanded_keyframes.uniq.sort
      end

      expected_segments = if packaged_sample_times.is_a?(Array) && packaged_sample_times.present?
        packaged_sample_times.length
      else
        (duration_seconds.to_f / seg).floor
      end
      expected_segments = 0 if expected_segments.negative?

      keyframe_intervals = keyframes.each_cons(2).map { |a, b| b.to_f - a.to_f }.select { |v| v > 0.05 }
      median_interval = median(keyframe_intervals).to_f if keyframe_intervals.present?
      consistency = if keyframe_intervals.present?
        keyframe_intervals.count { |iv| (iv.to_f - median_interval).abs <= consistency_tol }.to_f / keyframe_intervals.length.to_f
      else
        consistency
      end

      near_expected = expected_segments <= 0 || (keyframes.length >= [expected_segments * 0.55, 3].max && keyframes.length <= (expected_segments + 3))
      interval_ok = median_interval >= (seg * 0.60) && median_interval <= (seg * 1.40)
      consistency_ok = consistency >= 0.55
      return { usable: false, source: "packaged_playlist_midpoints", reason: "keyframe_timing_not_hls_like", keyframe_count: keyframes.length, interval_median: median_interval, interval_consistency: consistency } unless interval_ok && consistency_ok && near_expected

      points = []
      keyframes.each_with_index do |start_t, idx|
        end_t = keyframes[idx + 1].to_f
        end_t = duration_seconds.to_f if end_t <= start_t.to_f
        span = end_t - start_t.to_f
        next if span <= 0.08

        mid = start_t.to_f + (span / 2.0)
        points << {
          segment_index: idx.to_i,
          time: mid.round(6),
          start_time: start_t.to_f.round(6),
          end_time: end_t.to_f.round(6),
        }
      end

      return { usable: false, source: "packaged_playlist_midpoints", reason: "no_segment_points_from_keyframes" } if points.blank?

      {
        usable: true,
        source: "file_keyframe_midpoints",
        points: points,
        keyframe_count: keyframes.length,
        interval_median: median_interval,
        interval_consistency: consistency,
        expanded: expanded,
      }
    rescue
      { usable: false, source: "packaged_playlist_midpoints", reason: "keyframe_probe_failed" }
    end
    private_class_method :file_keyframe_segment_sample_plan

    def build_filemode_sample_points(duration_seconds:, segment_seconds:, sample_times:, max_samples:, file_size_bytes: nil, time_budget_seconds: nil)
      seg = segment_seconds.to_i
      seg = 6 if seg <= 0

      points = nil
      if sample_times.present?
        points = normalize_filemode_sample_points(sample_times)
      end

      if points.present?
        points = points.select { |p| p[:time].to_f < duration_seconds.to_f + 0.05 }
      else
        total = (duration_seconds.to_f / seg).floor
        total = 0 if total.negative?
        sample_count = [total, max_samples.to_i].min
        sample_count = 0 if sample_count.negative?
        points = sample_count.times.map do |i|
          { segment_index: i.to_i, time: ((i + 0.5) * seg).to_f }
        end
      end

      cap = filemode_sample_cap_for(
        max_samples: max_samples,
        duration_seconds: duration_seconds,
        file_size_bytes: file_size_bytes,
        time_budget_seconds: time_budget_seconds
      )
      cap = 5 if cap < 5 && points.length >= 5
      points = evenly_spaced_subset(points, cap) if cap > 0

      [points, cap]
    end
    private_class_method :build_filemode_sample_points

    def build_filemode_sample_times(duration_seconds:, segment_seconds:, sample_times:, max_samples:, file_size_bytes: nil, time_budget_seconds: nil)
      points, cap = build_filemode_sample_points(
        duration_seconds: duration_seconds,
        segment_seconds: segment_seconds,
        sample_times: sample_times,
        max_samples: max_samples,
        file_size_bytes: file_size_bytes,
        time_budget_seconds: time_budget_seconds
      )
      [Array(points).map { |p| p[:time].to_f }, cap]
    end
    private_class_method :build_filemode_sample_times

    def evenly_spaced_subset(values, cap)
      arr = Array(values)
      return arr if cap.to_i <= 0 || arr.length <= cap.to_i
      return [arr.first] if cap.to_i == 1

      last_index = arr.length - 1
      pick_indices = []
      seen = {}

      add_index = lambda do |idx|
        idx = idx.to_i
        idx = 0 if idx < 0
        idx = last_index if idx > last_index
        return if seen[idx]
        seen[idx] = true
        pick_indices << idx
      end

      if cap.to_i >= 16 && arr.length >= (cap.to_i + 8)
        tail_cap = [[(cap.to_f * 0.28).round, 3].max, cap.to_i - 4].min
        base_cap = [cap.to_i - tail_cap, 2].max

        base_step = last_index.to_f / (base_cap - 1).to_f
        base_cap.times do |i|
          add_index.call((i * base_step).round)
        end

        tail_start = (last_index * 0.68).floor
        tail_span = [last_index - tail_start, 1].max
        if tail_cap > 0
          tail_step = tail_span.to_f / [tail_cap, 1].max.to_f
          tail_cap.times do |i|
            add_index.call(tail_start + (i * tail_step).round)
          end
        end
      else
        step = last_index.to_f / (cap.to_i - 1).to_f
        cap.to_i.times do |i|
          add_index.call((i * step).round)
        end
      end

      if pick_indices.length < cap.to_i
        arr.each_with_index do |_val, idx|
          add_index.call(idx)
          break if pick_indices.length >= cap.to_i
        end
      elsif pick_indices.length > cap.to_i
        pick_indices = pick_indices.sort.first(cap.to_i)
      end

      picked = pick_indices.sort.map { |idx| arr[idx] }
      picked.sort_by do |val|
        if val.is_a?(Hash)
          val[:time].to_f
        else
          val.to_f
        end
      end
    end
    private_class_method :evenly_spaced_subset

    def filemode_offset_window_profile(requested_max_offset_segments:, sample_times:, duration_seconds:, segment_seconds:)
      requested = requested_max_offset_segments.to_i
      requested = 0 if requested.negative?

      total_segments = Array(sample_times).length
      return {
        effective: requested,
        requested: requested,
        total_segments: total_segments,
        estimated_clip_segments: 0,
        coverage_ratio: 0.0,
        reason: "requested_offset_window_kept"
      } if total_segments <= 0

      seg = segment_seconds.to_f
      seg = 6.0 if seg <= 0.0

      raw_clip_segments = duration_seconds.to_f / seg
      est_clip_segments = raw_clip_segments.round
      est_clip_segments = raw_clip_segments.ceil if est_clip_segments <= 0 && raw_clip_segments.positive?
      est_clip_segments = 1 if est_clip_segments < 1
      est_clip_segments = [est_clip_segments, total_segments].min

      max_possible = [total_segments - 1, 0].max
      hard_cap = [FILEMODE_AUTO_MAX_OFFSET_HARD_CAP, max_possible].min
      start_uncertainty = [total_segments - est_clip_segments, 0].max
      coverage_ratio = total_segments > 0 ? (est_clip_segments.to_f / total_segments.to_f) : 0.0

      cushion =
        if coverage_ratio >= 0.92
          0
        elsif coverage_ratio >= 0.80
          1
        elsif coverage_ratio >= 0.65
          2
        elsif coverage_ratio >= 0.50
          3
        else
          FILEMODE_AUTO_MAX_OFFSET_MARGIN_SEGMENTS
        end

      auto_cap = start_uncertainty + cushion
      auto_cap = 0 if auto_cap.negative?
      auto_cap = [auto_cap, hard_cap].min

      effective = if requested > 0
        [requested, auto_cap].min
      else
        auto_cap
      end
      effective = [effective, hard_cap].min

      reason =
        if effective < requested
          if coverage_ratio >= 0.92
            "auto_capped_near_full_clip"
          elsif coverage_ratio >= 0.80
            "auto_capped_long_clip"
          else
            "auto_capped_by_clip_coverage"
          end
        else
          "requested_offset_window_kept"
        end

      {
        effective: effective,
        requested: requested,
        total_segments: total_segments,
        estimated_clip_segments: est_clip_segments,
        coverage_ratio: coverage_ratio,
        reason: reason
      }
    end
    private_class_method :filemode_offset_window_profile

    def effective_filemode_max_offset_segments(requested_max_offset_segments:, sample_times:, duration_seconds:, segment_seconds:)
      filemode_offset_window_profile(
        requested_max_offset_segments: requested_max_offset_segments,
        sample_times: sample_times,
        duration_seconds: duration_seconds,
        segment_seconds: segment_seconds
      )[:effective].to_i
    end
    private_class_method :effective_filemode_max_offset_segments

    def filemode_sample_cap_for(max_samples:, duration_seconds:, file_size_bytes: nil, time_budget_seconds: nil)
      cap = max_samples.to_i
      cap = 0 if cap.negative?

      budget = normalize_filemode_time_budget_seconds(time_budget_seconds)
      relaxed_budget = budget >= 150.0

      if duration_seconds.to_f > 0
        if duration_seconds.to_f > 900
          cap = [cap, (relaxed_budget ? 32 : 24)].min
        elsif duration_seconds.to_f > 480
          cap = [cap, (relaxed_budget ? 45 : 32)].min
        elsif duration_seconds.to_f > 240
          cap = [cap, (relaxed_budget ? 55 : 45)].min
        elsif duration_seconds.to_f > 120
          cap = [cap, (relaxed_budget ? 60 : 50)].min
        end
      end

      fs = file_size_bytes.to_i
      if fs > 0
        if fs > 250 * 1024 * 1024
          cap = [cap, (relaxed_budget ? 36 : 24)].min
        elsif fs > 150 * 1024 * 1024
          cap = [cap, (relaxed_budget ? 45 : 32)].min
        elsif fs > 100 * 1024 * 1024
          cap = [cap, (relaxed_budget ? 50 : 40)].min
        elsif fs > 70 * 1024 * 1024
          cap = [cap, (relaxed_budget ? 55 : 45)].min
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

    def analysis_pairs_for_spec(spec)
      return [] unless spec.is_a?(Hash)

      main = Array(spec[:pairs])
      sync = Array(spec[:sync_pairs])
      main + sync
    rescue
      Array(spec[:pairs])
    end
    private_class_method :analysis_pairs_for_spec

    def main_pair_count_for_spec(spec)
      Array(spec[:pairs]).length
    rescue
      0
    end
    private_class_method :main_pair_count_for_spec

    def ecc_grouped_samples(samples:, offset:)
      arr = Array(samples)
      return [] if arr.empty?

      groups = {}
      arr.each do |entry|
        obs_idx = entry[0].to_i
        base_seg_idx = entry[1].to_i
        ov = entry[2].to_s
        w = entry[3].to_f
        c = entry[4].to_f
        adaptive_w = entry[5].to_f
        adaptive_w = w if adaptive_w <= 0.0
        next if ov.blank? || w <= 0.0

        seg_idx = base_seg_idx + offset.to_i
        slot = if ::MediaGallery::Fingerprinting.respond_to?(:logical_slot_for_segment)
          ::MediaGallery::Fingerprinting.logical_slot_for_segment(segment_index: seg_idx)
        else
          { block_index: 0, logical_index: seg_idx }
        end

        key = [slot[:block_index].to_i, slot[:logical_index].to_i]
        g = (groups[key] ||= { rep_obs_idx: obs_idx, rep_base_seg_idx: base_seg_idx, rep_seg: seg_idx, a_w: 0.0, b_w: 0.0, raw_weight: 0.0, adaptive_weight: 0.0, raw_conf: [], raw_count: 0 })
        if ov == "a"
          g[:a_w] += w
        else
          g[:b_w] += w
        end
        g[:raw_weight] += w
        g[:adaptive_weight] += adaptive_w
        g[:raw_conf] << c if c > 0.0
        g[:raw_count] += 1
        if seg_idx < g[:rep_seg].to_i
          g[:rep_seg] = seg_idx
          g[:rep_obs_idx] = obs_idx
          g[:rep_base_seg_idx] = base_seg_idx
        end
      end

      groups.map do |_key, g|
        total = g[:raw_weight].to_f
        next if total <= 0.0

        diff = (g[:a_w].to_f - g[:b_w].to_f)
        ov = diff >= 0.0 ? "a" : "b"
        margin = diff.abs / [total, 1e-6].max
        w = total * (0.65 + (0.35 * margin))
        adaptive_total = g[:adaptive_weight].to_f
        adaptive_w = adaptive_total * (0.65 + (0.35 * margin))
        adaptive_w = w if adaptive_w <= 0.0
        c = median(g[:raw_conf])
        [g[:rep_obs_idx].to_i, g[:rep_base_seg_idx].to_i, ov, w.to_f, c.to_f, g[:raw_count].to_i, margin.to_f, adaptive_w.to_f]
      end.compact
    rescue
      arr
    end
    private_class_method :ecc_grouped_samples

    def ecc_grouped_reference_usable(usable:, offset:)
      arr = Array(usable)
      return { usable: [], comp_w: 0.0, usable_count: 0 } if arr.empty?

      groups = {}
      arr.each do |entry|
        obs_idx = entry[0].to_i
        base_seg_idx = entry[1].to_i
        ov = entry[2].to_s
        w = entry[3].to_f
        margin = entry[4].to_f
        ratio = entry[5].to_f
        next if ov.blank? || w <= 0.0

        seg_idx = base_seg_idx + offset.to_i
        slot = if ::MediaGallery::Fingerprinting.respond_to?(:logical_slot_for_segment)
          ::MediaGallery::Fingerprinting.logical_slot_for_segment(segment_index: seg_idx)
        else
          { block_index: 0, logical_index: seg_idx }
        end

        key = [slot[:block_index].to_i, slot[:logical_index].to_i]
        g = (groups[key] ||= { rep_obs_idx: obs_idx, rep_base_seg_idx: base_seg_idx, rep_seg: seg_idx, a_w: 0.0, b_w: 0.0, raw_weight: 0.0, margins: [], ratios: [], raw_count: 0 })
        if ov == "a"
          g[:a_w] += w
        else
          g[:b_w] += w
        end
        g[:raw_weight] += w
        g[:margins] << margin
        g[:ratios] << ratio
        g[:raw_count] += 1
        if seg_idx < g[:rep_seg].to_i
          g[:rep_seg] = seg_idx
          g[:rep_obs_idx] = obs_idx
          g[:rep_base_seg_idx] = base_seg_idx
        end
      end

      usable_out = []
      comp_w = 0.0
      margins = []
      ratios = []

      groups.each do |_key, g|
        total = g[:raw_weight].to_f
        next if total <= 0.0

        diff = g[:a_w].to_f - g[:b_w].to_f
        ov = diff >= 0.0 ? "a" : "b"
        consensus = diff.abs / [total, 1e-6].max
        margin = [median(g[:margins]).to_f, consensus].max
        ratio = median(g[:ratios]).to_f
        weight = total * (0.65 + (0.35 * consensus))

        usable_out << [g[:rep_obs_idx].to_i, g[:rep_base_seg_idx].to_i, ov, weight.to_f, margin.to_f, ratio.to_f, g[:rep_seg].to_i, g[:raw_count].to_i]
        comp_w += weight.to_f
        margins << margin.to_f
        ratios << ratio.to_f
      end

      {
        usable: usable_out,
        comp_w: comp_w.to_f,
        median_ratio: median(ratios).to_f,
        median_margin: median(margins).to_f,
        usable_count: usable_out.length
      }
    rescue
      { usable: arr, comp_w: arr.reduce(0.0) { |acc, e| acc + e[3].to_f }, usable_count: arr.length }
    end
    private_class_method :ecc_grouped_reference_usable

    def quantile_value(values, q)
      arr = Array(values).map { |v| v.to_f }.select { |v| v.finite? }.sort
      return 0.0 if arr.empty?

      idx = ((arr.length - 1) * q.to_f).round
      idx = 0 if idx.negative?
      idx = arr.length - 1 if idx >= arr.length
      arr[idx].to_f
    rescue
      0.0
    end
    private_class_method :quantile_value

    def build_reference_adaptive_context(usable:)
      entries = Array(usable)
      segs = entries.map { |entry| entry[6].to_i }.sort
      nearest_gap = {}
      density_12 = {}
      density_24 = {}

      segs.each_with_index do |seg, idx|
        prev_gap = idx > 0 ? (seg - segs[idx - 1]).abs : nil
        next_gap = idx + 1 < segs.length ? (segs[idx + 1] - seg).abs : nil
        nearest_gap[seg] = [prev_gap, next_gap].compact.min
        density_12[seg] = segs.count { |other| other != seg && (other - seg).abs <= 12 }
        density_24[seg] = segs.count { |other| other != seg && (other - seg).abs <= 24 }
      end

      margins = entries.map { |entry| entry[4].to_f }.select { |v| v.positive? && v.finite? }
      weights = entries.map { |entry| entry[3].to_f }.select { |v| v.positive? && v.finite? }

      {
        nearest_gap: nearest_gap,
        density_12: density_12,
        density_24: density_24,
        margin_p35: quantile_value(margins, 0.35),
        margin_p60: quantile_value(margins, 0.60),
        weight_p60: quantile_value(weights, 0.60),
        high_quality_factor_threshold: 1.08,
        density_window_segments: 12,
      }
    rescue
      {
        nearest_gap: {},
        density_12: {},
        density_24: {},
        margin_p35: 0.0,
        margin_p60: 0.0,
        weight_p60: 0.0,
        high_quality_factor_threshold: 1.08,
        density_window_segments: 12,
      }
    end
    private_class_method :build_reference_adaptive_context

    def reference_sample_weight_factor(entry:, adaptive_ctx:)
      weight = entry[3].to_f
      margin = entry[4].to_f
      seg_idx = entry[6].to_i
      raw_count = entry[7].to_i

      factor = 1.0
      dense_12 = adaptive_ctx[:density_12][seg_idx].to_i
      dense_24 = adaptive_ctx[:density_24][seg_idx].to_i
      nearest_gap = adaptive_ctx[:nearest_gap][seg_idx]

      factor *= 1.12 if dense_12 >= 3
      factor *= 1.06 if dense_12 == 2
      factor *= 1.05 if dense_24 >= 5
      factor *= 1.08 if raw_count >= 2
      factor *= 1.04 if raw_count >= 3
      factor *= 1.05 if margin >= adaptive_ctx[:margin_p60].to_f && adaptive_ctx[:margin_p60].to_f > 0.0
      factor *= 1.04 if weight >= adaptive_ctx[:weight_p60].to_f && adaptive_ctx[:weight_p60].to_f > 0.0
      factor *= 0.90 if dense_12 == 0 && raw_count <= 1
      factor *= 0.94 if nearest_gap.present? && nearest_gap >= 20
      factor *= 0.90 if margin > 0.0 && margin < adaptive_ctx[:margin_p35].to_f

      [[factor, 1.35].min, 0.60].max
    rescue
      1.0
    end
    private_class_method :reference_sample_weight_factor

    def annotate_reference_usable_with_adaptive(usable:)
      entries = Array(usable)
      adaptive_ctx = build_reference_adaptive_context(usable: entries)
      factor_threshold = adaptive_ctx[:high_quality_factor_threshold].to_f

      adaptive_total_weight = 0.0
      high_quality_weight = 0.0
      usable_with_adaptive = entries.map do |entry|
        factor = reference_sample_weight_factor(entry: entry, adaptive_ctx: adaptive_ctx)
        adaptive_w = entry[3].to_f * factor
        adaptive_total_weight += adaptive_w
        high_quality_weight += adaptive_w if factor >= factor_threshold
        entry + [adaptive_w.to_f, factor.to_f]
      end

      {
        usable: usable_with_adaptive,
        adaptive_total_weight: adaptive_total_weight.to_f,
        high_quality_weight: high_quality_weight.to_f,
        high_quality_factor_threshold: factor_threshold,
        density_window_segments: adaptive_ctx[:density_window_segments].to_i,
      }
    rescue
      {
        usable: entries.map { |entry| entry + [entry[3].to_f, 1.0] },
        adaptive_total_weight: entries.reduce(0.0) { |acc, entry| acc + entry[3].to_f },
        high_quality_weight: 0.0,
        high_quality_factor_threshold: 1.08,
        density_window_segments: 12,
      }
    end
    private_class_method :annotate_reference_usable_with_adaptive

    def invert_variant(v)
      return nil if v.blank?

      vv = v.to_s
      return "b" if vv == "a"
      return "a" if vv == "b"

      vv
    end
    private_class_method :invert_variant

    def invert_variant_sequence(arr)
      Array(arr).map { |v| invert_variant(v) }
    end
    private_class_method :invert_variant_sequence

    def candidate_observed_variant(candidate:, observed_variant:, observed_polarity_flip: false)
      flip = candidate[:polarity_flip_used] ? true : false
      flip == observed_polarity_flip ? observed_variant.to_s : invert_variant(observed_variant)
    rescue
      observed_variant.to_s
    end
    private_class_method :candidate_observed_variant

    def select_polarity_result(normal_result:, inverted_result:)
      normal_diag = normal_result.is_a?(Hash) ? (normal_result[:diag] || {}) : {}
      inverted_diag = inverted_result.is_a?(Hash) ? (inverted_result[:diag] || {}) : {}

      normal_score = normal_result&.dig(:score).to_f
      inverted_score = inverted_result&.dig(:score).to_f
      normal_ratio = normal_diag[:top_ratio_w].to_f
      inverted_ratio = inverted_diag[:top_ratio_w].to_f
      normal_delta = normal_diag[:delta].to_f
      inverted_delta = inverted_diag[:delta].to_f

      ratio_gain = inverted_ratio - normal_ratio
      delta_gain = inverted_delta - normal_delta
      score_gain = inverted_score - normal_score

      gate_passed =
        inverted_result.present? &&
          inverted_ratio >= POLARITY_SWITCH_MIN_TOP_RATIO &&
          delta_gain >= -POLARITY_SWITCH_MAX_DELTA_REGRESSION &&
          (
            score_gain >= POLARITY_SWITCH_MIN_SCORE_GAIN ||
              ratio_gain >= POLARITY_SWITCH_MIN_RATIO_GAIN ||
              delta_gain >= POLARITY_SWITCH_MIN_DELTA_GAIN
          )

      chosen_flip = gate_passed
      chosen = chosen_flip ? inverted_result : normal_result
      fallback = chosen_flip ? normal_result : inverted_result

      {
        chosen: chosen,
        chosen_flip: chosen_flip,
        gate_passed: gate_passed,
        ratio_gain: ratio_gain.round(4),
        delta_gain: delta_gain.round(4),
        score_gain: score_gain.round(4),
        chosen_score: chosen&.dig(:score),
        fallback_score: fallback&.dig(:score),
      }
    end
    private_class_method :select_polarity_result

    def chunked_resync_position_windows(usable_by_offset:, observed_segment_indices: nil, scores_length: nil)
      positions = Array(observed_segment_indices).each_with_index.filter_map do |seg_idx, obs_idx|
        if seg_idx.present?
          seg_idx.to_i
        elsif scores_length.to_i > 0
          obs_idx.to_i
        end
      end.uniq.sort

      if positions.empty?
        positions = Array(usable_by_offset.values)
          .flat_map { |u| Array(u[:usable]).map { |entry| entry[1].to_i } }
          .uniq
          .sort
      end

      return [] if positions.empty?

      win = CHUNKED_RESYNC_WINDOW_SEGMENTS.to_i
      win = 8 if win <= 0
      win = [win, positions.length].min
      step = [win / 2, 1].max

      windows = []
      start = 0
      while start < positions.length
        slice = positions.slice(start, win)
        break if slice.blank?
        windows << slice.dup
        break if start + win >= positions.length
        start += step
      end

      if windows.length < 2 && positions.length >= [CHUNKED_RESYNC_MIN_LOCAL_USABLE.to_i, 4].max
        tail_start = [positions.length - win, 0].max
        tail = positions.slice(tail_start, win)
        windows << tail.dup if tail.present?
      end

      windows.uniq { |slice| [slice.first, slice.last, slice.length] }
    rescue
      []
    end
    private_class_method :chunked_resync_position_windows

    def summarize_reference_window(usable_entries:, positions: nil)
      wanted = Array(positions).map(&:to_i)
      return nil if wanted.empty?

      wanted_set = wanted.each_with_object({}) { |idx, acc| acc[idx] = true }
      entries = Array(usable_entries).select do |entry|
        wanted_set[entry[1].to_i] || wanted_set[entry[0].to_i]
      end
      return nil if entries.empty?

      comp_w = entries.reduce(0.0) { |acc, e| acc + e[3].to_f }.to_f
      return nil if comp_w <= 0.0

      {
        usable: entries,
        comp_w: comp_w,
        usable_count: entries.length,
        median_margin: median(entries.map { |e| e[4].to_f }).to_f,
        median_ratio: median(entries.map { |e| e[5].to_f }).to_f,
      }
    rescue
      nil
    end
    private_class_method :summarize_reference_window

    def chunked_resync_should_run?(scores_length:, global_usable_count:)
      scores_length.to_i >= CHUNKED_RESYNC_MIN_TOTAL_SAMPLES.to_i && global_usable_count.to_i >= 8
    rescue
      false
    end
    private_class_method :chunked_resync_should_run?

    def chunked_resync_score(top_ratio:, second_ratio:, usable_count:, median_margin:)
      delta = top_ratio.to_f - second_ratio.to_f
      delta + (top_ratio.to_f * 0.03) + (usable_count.to_f * 0.003) + (median_margin.to_f * 0.02)
    end
    private_class_method :chunked_resync_score

    def build_chunked_reference_result(fps:, media_item:, scores_length:, max_off:, polarity_flip:, build_usable:, observed_segment_indices: nil)
      usable_by_offset = {}
      (0..max_off).each do |offset|
        u = build_usable.call(offset, polarity_flip)
        next if u.blank? || Array(u[:usable]).empty? || u[:comp_w].to_f <= 0.0
        usable_by_offset[offset] = u
      end
      return nil if usable_by_offset.empty?

      windows = chunked_resync_position_windows(
        usable_by_offset: usable_by_offset,
        observed_segment_indices: observed_segment_indices,
        scores_length: scores_length
      )
      return nil if windows.length < 2

      chosen_chunks = []
      ref_obs = Array.new(scores_length)
      ref_conf = Array.new(scores_length, 0.0)

      windows.each do |positions|
        best = nil

        usable_by_offset.each do |offset, u|
          summary = summarize_reference_window(usable_entries: u[:usable], positions: positions)
          min_local_usable = CHUNKED_RESYNC_MIN_LOCAL_USABLE.to_i
          min_local_usable = 3 if u[:usable_count].to_i <= 12
          min_local_usable = [min_local_usable, 3].min if u[:usable_count].to_i <= 18
          next if summary.blank? || summary[:usable_count].to_i < min_local_usable

          top = nil
          second = nil
          fps.each do |rec|
            mism_w = 0.0
            summary[:usable].each do |(_obs_idx, base_seg_idx, ov, w, _m, _r, _seg_idx, _raw_count)|
              exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
                fingerprint_id: rec.fingerprint_id,
                media_item_id: media_item.id,
                segment_index: base_seg_idx.to_i + offset
              )
              mism_w += w if exp != ov
            end

            ratio_w = 1.0 - (mism_w / summary[:comp_w])
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
          score = chunked_resync_score(
            top_ratio: top[:ratio_w].to_f,
            second_ratio: second_ratio,
            usable_count: summary[:usable_count],
            median_margin: summary[:median_margin]
          )

          entry = {
            range: positions,
            offset: offset,
            usable: summary[:usable],
            comp_w: summary[:comp_w].to_f,
            usable_count: summary[:usable_count].to_i,
            median_margin: summary[:median_margin].to_f,
            median_ratio: summary[:median_ratio].to_f,
            top_ratio_w: top[:ratio_w].to_f,
            second_ratio_w: second_ratio,
            top_user_id: top.dig(:rec, :user_id),
            score: score,
          }

          if best.nil? || entry[:score] > best[:score] ||
               (entry[:score] == best[:score] && entry[:usable_count].to_i > best[:usable_count].to_i)
            best = entry
          end
        end

        next if best.blank?
        chosen_chunks << best
        best[:usable].each do |(obs_idx, _base_seg_idx, ov, _w, margin, ratio, _seg_idx, _raw_count)|
          ref_obs[obs_idx] = ov
          c = margin.to_f
          c *= 0.5 if ratio.to_f > 1.0
          ref_conf[obs_idx] = c.round(4)
        end
      end

      return nil if chosen_chunks.length < 2

      candidates = []
      fps.each do |rec|
        mism_w = 0.0
        comp_w = 0.0
        mism = 0
        comp = 0

        chosen_chunks.each do |chunk|
          off = chunk[:offset].to_i
          chunk[:usable].each do |(_obs_idx, base_seg_idx, ov, w, _m, _r, _seg_idx, _raw_count)|
            exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
              fingerprint_id: rec.fingerprint_id,
              media_item_id: media_item.id,
              segment_index: base_seg_idx.to_i + off
            )
            comp += 1
            comp_w += w.to_f
            if exp != ov
              mism += 1
              mism_w += w.to_f
            end
          end
        end

        next if comp <= 0 || comp_w <= 0.0

        candidates << {
          user_id: rec.user_id,
          username: rec.user&.username,
          fingerprint_id: rec.fingerprint_id,
          best_offset_segments: chosen_chunks.first[:offset].to_i,
          mismatches: mism,
          compared: comp,
          mismatches_weighted: mism_w.round(6),
          compared_weighted: comp_w.round(6),
          match_ratio: (1.0 - (mism.to_f / comp.to_f)).round(4),
          match_ratio_weighted: (1.0 - (mism_w / comp_w)).round(4),
          local_best_offset_segments: chosen_chunks.first[:offset].to_i,
          local_match_ratio: (1.0 - (mism_w / comp_w)).round(4),
          polarity_flip_used: polarity_flip,
          variant_polarity: (polarity_flip ? "inverted" : "normal"),
        }
      end

      prefilter_info = apply_shortlist_prefilter(
        candidates: candidates,
        observed_count: usable_count
      )
      candidates = prefilter_info[:candidates]

      enrich_candidates_with_evidence!(
        candidates: candidates,
        observed_variants: ref_obs,
        observed_confidences: ref_conf,
        observed_segment_indices: Array(observed_segment_indices).presence || Array.new(scores_length) { |idx| idx },
        media_item_id: media_item.id
      )
      top = candidates[0]
      second = candidates[1]
      top_ratio = top&.dig(:match_ratio_weighted).to_f
      second_ratio = second&.dig(:match_ratio_weighted).to_f
      usable_count = chosen_chunks.reduce(0) { |acc, c| acc + c[:usable_count].to_i }
      median_margin = median(chosen_chunks.map { |c| c[:median_margin].to_f }).to_f

      {
        candidates: candidates,
        meta: {
          offset_strategy: "chunked_reference",
          chosen_offset_segments: chosen_chunks.first[:offset].to_i,
          effective_samples: usable_count.to_f.round(2),
          offset_top_match_ratio: top_ratio.round(4),
          offset_second_match_ratio: second_ratio.round(4),
          offset_delta: (top_ratio - second_ratio).round(4),
          reference_observed_variants: ref_obs,
          reference_observed_confidences: ref_conf,
          chunked_resync_used: true,
          chunked_resync_chunks_used: chosen_chunks.length,
          chunked_resync_window_segments: CHUNKED_RESYNC_WINDOW_SEGMENTS,
          chunked_resync_offsets: chosen_chunks.map { |c| c[:offset].to_i },
          chunked_resync_ranges: chosen_chunks.map { |c| "#{Array(c[:range]).first}-#{Array(c[:range]).last}" },
          chunked_resync_score: chunked_resync_score(
            top_ratio: top_ratio,
            second_ratio: second_ratio,
            usable_count: usable_count,
            median_margin: median_margin
          ).round(4),
          chunked_resync_top_user_ids: chosen_chunks.map { |c| c[:top_user_id] }.compact,
          candidate_population_count: fps.length,
          candidate_prefilter_used: prefilter_info[:used],
          candidate_prefilter_limit: prefilter_info[:limit],
          candidate_prefilter_kept: prefilter_info[:kept],
          candidate_prefilter_cutoff_weighted_ratio: prefilter_info[:cutoff_weighted_ratio],
        },
        score: chunked_resync_score(
          top_ratio: top_ratio,
          second_ratio: second_ratio,
          usable_count: usable_count,
          median_margin: median_margin
        ),
      }
    rescue
      nil
    end
    private_class_method :build_chunked_reference_result

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

      sample_points, cap = build_filemode_sample_points(
        duration_seconds: duration,
        segment_seconds: seg,
        sample_times: sample_times,
        max_samples: max_samples,
        file_size_bytes: file_size_bytes,
        time_budget_seconds: time_budget_seconds
      )

      pass1 = []
      used_times = []
      used_segment_indices = []
      used_sample_points = []
      sample_points.each_slice(chunk_size) do |chunk|
        break if budget_exceeded.call
        chunk_times = chunk.map { |p| p[:time].to_f }
        res = sample_variants_batch_single(file_path: file_path, times: chunk_times, spec: spec)
        pass1.concat(res)
        used_times.concat(chunk_times.first(Array(res).length))
        used_segment_indices.concat(chunk.first(Array(res).length).map { |p| p[:segment_index].to_i })
        used_sample_points.concat(chunk.first(Array(res).length))
      end

      variants = pass1.map { |r| r[:variant] }
      confidences = pass1.map { |r| r[:confidence] }
      scores = pass1.map { |r| r[:score] }
      sync_scores = pass1.map { |r| r[:sync_score].to_f }
      sync_confidences = pass1.map { |r| r[:sync_confidence].to_f }
      sync_variants = pass1.map { |r| r[:sync_variant] }

      # Pass 2: for weak samples, resample nearby frames and aggregate.
      weak_idxs = []
      variants.each_with_index do |v, i|
        c = confidences[i].to_f
        next if v.present? && c >= RESAMPLE_MIN_CONFIDENCE
        weak_idxs << i
      end
      weak_idxs = weak_idxs.first(MAX_RESAMPLED_SEGMENTS)

      if weak_idxs.present? && !budget_exceeded.call
        seg_f = seg.to_f
        default_offset = (seg_f * 0.25).to_f
        default_offset = 0.25 if default_offset < 0.25

        resample_times = []
        resample_map = {} # rounded_time -> [segment_idx, ...]

        weak_idxs.each do |i|
          t_mid = used_times[i].to_f
          point = used_sample_points[i]
          window = sample_point_window(point: point, segment_seconds: seg_f, duration_seconds: duration, center_time: t_mid)

          local_times = []
          if window.present?
            start_t = window[0].to_f
            end_t = window[1].to_f
            span = end_t - start_t

            if span > 0.18
              [0.28, 0.42, 0.58, 0.72].each do |ratio|
                local_times << (start_t + (span * ratio))
              end
            end
          end

          if local_times.blank?
            local_times = [
              clamp_time(t_mid - default_offset, duration_seconds: duration),
              clamp_time(t_mid + default_offset, duration_seconds: duration),
            ]
          end

          local_times.uniq.each do |tt|
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
        per_seg_sync_scores = Hash.new { |h, k| h[k] = [] }
        per_seg_sync_confs = Hash.new { |h, k| h[k] = [] }

        resample_times.each_with_index do |tt, idx|
          key = tt.to_f.round(3)
          seg_idxs = resample_map[key] || []
          next if seg_idxs.empty?
          seg_idxs.each do |si|
            next if pass2[idx].blank?
            per_seg_scores[si] << pass2[idx][:score].to_f
            per_seg_confs[si] << pass2[idx][:confidence].to_f
            per_seg_sync_scores[si] << pass2[idx][:sync_score].to_f
            per_seg_sync_confs[si] << pass2[idx][:sync_confidence].to_f
          end
        end

        weak_idxs.each do |i|
          all_scores = [scores[i].to_f] + per_seg_scores[i]
          all_confs = [confidences[i].to_f] + per_seg_confs[i]
          all_sync_scores = [sync_scores[i].to_f] + per_seg_sync_scores[i]
          all_sync_confs = [sync_confidences[i].to_f] + per_seg_sync_confs[i]

          med_score = median(all_scores).to_f
          med_conf = median(all_confs).to_f.round(4)
          med_sync_score = median(all_sync_scores).to_f
          med_sync_conf = median(all_sync_confs).to_f.round(4)

          v = med_score >= 0 ? "a" : "b"
          v = nil if med_conf < MIN_CONFIDENCE

          variants[i] = v
          confidences[i] = med_conf
          scores[i] = med_score
          sync_scores[i] = med_sync_score
          sync_confidences[i] = med_sync_conf
          sync_variants[i] = (med_sync_conf >= MIN_CONFIDENCE ? (med_sync_score >= 0 ? "a" : "b") : nil)
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
        sync_scores: sync_scores,
        sync_confidences: sync_confidences,
        sync_variants: sync_variants,
        times: used_times,
        segment_indices: used_segment_indices,
        layout: spec[:layout].to_s,
        truncated: used_times.length < sample_points.length || budget_exceeded.call,
        elapsed_seconds: elapsed,
        effective_max_samples: cap,
        budget_exhausted: budget_exceeded.call,
        sample_points: used_sample_points,
        quality_hints: {},
      }
    end
    # Attempts to derive accurate segment midpoints from the packaged (template) HLS playlist on disk.
    # This avoids assuming fixed `segment_seconds` and reduces drift-related sampling errors.
    def packaged_total_duration_for(media_item:)
      segments = packaged_segments_for(media_item: media_item)
      return nil if segments.blank?

      total = Array(segments).sum { |entry| entry[:duration].to_f }
      total > 0.0 ? total : nil
    rescue
      nil
    end
    private_class_method :packaged_total_duration_for

    def packaged_segment_midpoints_for(media_item:)
      return nil if media_item.blank?
      return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

      variant = ::MediaGallery::Hls.variants.first.to_s
      variant = "v0" if variant.blank?

      pl = packaged_variant_playlist_path_for(media_item: media_item, variant: variant)
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
      return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

      variant = ::MediaGallery::Hls.variants.first.to_s
      variant = "v0" if variant.blank?

      pl = packaged_variant_playlist_path_for(media_item: media_item, variant: variant)
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
  return nil unless defined?(::MediaGallery::Hls) && ::MediaGallery::Hls.respond_to?(:variants)

  root = packaged_hls_root_for(media_item: media_item)
  return nil if root.blank? || !Dir.exist?(root)

  segs = packaged_segments_for(media_item: media_item)
  return nil if segs.blank?

  needed = needed_count.to_i
  needed = 0 if needed.negative?
  needed = [needed, segs.length].min
  return nil if needed <= 0

  spec_hash =
    begin
      base = deep_symbolize(spec)
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



    def annotate_candidate_debugs!(candidates:, observed_variants:, media_item_id:, observed_segment_indices: nil)
      obs = Array(observed_variants)
      seg_indices = Array(observed_segment_indices)
      return if candidates.blank? || obs.empty?

      candidates.each do |cand|
        offset = cand[:best_offset_segments].to_i
        expected = Array.new(obs.length)
        indices = Array.new(obs.length)
        mismatches = []

        obs.each_with_index do |ov, i|
          base_seg_idx = seg_indices[i].present? ? seg_indices[i].to_i : i
          seg_idx = base_seg_idx + offset
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
      meta[:top_candidate_why] = top[:why] if top[:why].present?
      meta
    rescue
      meta
    end
    private_class_method :apply_top_candidate_debug_to_meta!

    def chunk_observation_entries(observed_variants:, observed_confidences:, observed_segment_indices: nil, layout: nil)
      obs = Array(observed_variants)
      confs = Array(observed_confidences)
      seg_indices = Array(observed_segment_indices)
      v8_layout = layout.to_s == "v8_microgrid"

      entries = []
      obs.each_with_index do |ov, i|
        next if ov.blank?

        conf = confs[i].to_f
        conf = 0.0 if conf.nan? || conf.infinite? || conf.negative?
        next if conf > 0.0 && conf < MIN_CONFIDENCE

        weight = if conf > 0.0
          base_weight = conf * conf
          if v8_layout
            base_weight *= conf
            base_weight *= 0.35 if conf < 0.75
          end
          base_weight
        else
          1.0
        end
        next if weight <= 0.0

        base_seg_idx = seg_indices[i].present? ? seg_indices[i].to_i : i
        entries << [i, base_seg_idx, ov.to_s, weight.to_f]
      end

      entries
    rescue
      []
    end
    private_class_method :chunk_observation_entries

    def v8_layout_name(layout)
      layout.to_s == "v8_microgrid" ? "v8_microgrid" : layout.to_s
    rescue
      layout.to_s
    end
    private_class_method :v8_layout_name

    def score_candidate_chunk_at_offset(candidate:, chunk:, media_item_id:, offset:, observed_polarity_flip: false)
      comp_w = 0.0
      match_w = 0.0

      chunk.each do |(_obs_idx, base_seg_idx, ov, weight)|
        seg_idx = base_seg_idx.to_i + offset.to_i
        exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: candidate[:fingerprint_id],
          media_item_id: media_item_id,
          segment_index: seg_idx
        )
        candidate_flip = candidate[:polarity_flip_used] ? true : false
        observed_variant = (candidate_flip == observed_polarity_flip ? ov : invert_variant(ov))

        comp_w += weight.to_f
        match_w += weight.to_f if exp == observed_variant
      end

      return nil if comp_w <= 0.0

      ratio = match_w / comp_w
      llr = comp_w * Math.log(([ratio, 1.0e-6].max) / 0.5)
      {
        ratio: ratio,
        comp_w: comp_w,
        llr: llr,
      }
    rescue
      nil
    end
    private_class_method :score_candidate_chunk_at_offset

    def best_candidate_chunk_alignment(candidate:, chunk:, media_item_id:, base_offset:, local_offset_radius:, offset_floor:, offset_ceil:, observed_polarity_flip: false)
      floor = offset_floor.to_i
      ceil = offset_ceil.to_i
      floor = 0 if floor.negative?
      ceil = floor if ceil < floor

      base = base_offset.to_i
      base = floor if base < floor
      base = ceil if base > ceil

      radius = local_offset_radius.to_i
      radius = 0 if radius.negative?

      lo = radius > 0 ? [base - radius, floor].max : base
      hi = radius > 0 ? [base + radius, ceil].min : base
      hi = lo if hi < lo

      best = nil
      (lo..hi).each do |offset|
        scored = score_candidate_chunk_at_offset(
          candidate: candidate,
          chunk: chunk,
          media_item_id: media_item_id,
          offset: offset,
          observed_polarity_flip: observed_polarity_flip
        )
        next if scored.blank?

        distance = (offset.to_i - base).abs
        search_score = scored[:llr].to_f - (distance.to_f * CANDIDATE_EVIDENCE_LOCAL_OFFSET_PENALTY)
        entry = scored.merge(
          offset: offset.to_i,
          search_score: search_score,
          offset_distance: distance.to_i,
        )

        if best.nil? || entry[:search_score].to_f > best[:search_score].to_f ||
             (entry[:search_score].to_f == best[:search_score].to_f && entry[:ratio].to_f > best[:ratio].to_f) ||
             (entry[:search_score].to_f == best[:search_score].to_f && entry[:ratio].to_f == best[:ratio].to_f && entry[:comp_w].to_f > best[:comp_w].to_f)
          best = entry
        end
      end

      best
    rescue
      score_candidate_chunk_at_offset(
        candidate: candidate,
        chunk: chunk,
        media_item_id: media_item_id,
        offset: base_offset,
        observed_polarity_flip: observed_polarity_flip
      )
    end
    private_class_method :best_candidate_chunk_alignment

    def reference_candidate_match_stats(candidate:, usable_result:, media_item_id:, offset:)
      usable = Array(usable_result[:usable])
      comp_w = usable_result[:comp_w].to_f
      return nil if usable.empty? || comp_w <= 0.0

      mism_w = 0.0
      mism = 0
      comp = 0

      usable.each do |(_obs_idx, base_seg_idx, ov, w, _m, _r, _seg_idx, _raw_count)|
        exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: candidate[:fingerprint_id],
          media_item_id: media_item_id,
          segment_index: base_seg_idx.to_i + offset.to_i
        )
        comp += 1
        if exp != ov
          mism += 1
          mism_w += w.to_f
        end
      end

      return nil if comp <= 0 || comp_w <= 0.0

      ratio_w = 1.0 - (mism_w / comp_w)
      llr = comp_w * Math.log(([ratio_w, 1.0e-6].max) / 0.5)

      {
        offset: offset.to_i,
        mismatches: mism,
        compared: comp,
        mismatches_weighted: mism_w,
        compared_weighted: comp_w,
        match_ratio: 1.0 - (mism.to_f / comp.to_f),
        match_ratio_weighted: ratio_w,
        llr: llr,
        usable_count: usable_result[:usable_count].to_i,
        median_margin: usable_result[:median_margin].to_f,
      }
    rescue
      nil
    end
    private_class_method :reference_candidate_match_stats

    def candidate_local_offset_radius(max_off:, observed_count:)
      return 0 if max_off.to_i <= 0 || observed_count.to_i < 8

      radius = CANDIDATE_EVIDENCE_LOCAL_OFFSET_RADIUS.to_i
      radius = 0 if radius.negative?
      radius = [radius, max_off.to_i].min
      radius = [radius, [observed_count.to_i / 2, 1].max].min
      radius
    rescue
      0
    end
    private_class_method :candidate_local_offset_radius


    def clamp_unit_interval(value)
      v = value.to_f
      return 0.0 if v.nan? || v.infinite?
      return 0.0 if v <= 0.0
      return 1.0 if v >= 1.0

      v
    rescue
      0.0
    end
    private_class_method :clamp_unit_interval

    def reference_anchor_trust(top_ratio:, delta:, median_ratio:, median_margin:, usable_count:, budget_exhausted: false)
      trust = 0.0
      trust += clamp_unit_interval((top_ratio.to_f - 0.72) / 0.18) * 0.35
      trust += clamp_unit_interval((delta.to_f - 0.12) / 0.28) * 0.30
      trust += clamp_unit_interval((median_ratio.to_f - 0.90) / 0.90) * 0.20
      trust += clamp_unit_interval((usable_count.to_f - 12.0) / 12.0) * 0.10
      trust += clamp_unit_interval((median_margin.to_f - 0.08) / 0.20) * 0.05
      trust *= 0.75 if budget_exhausted
      clamp_unit_interval(trust)
    rescue
      0.0
    end
    private_class_method :reference_anchor_trust

    def shortlist_offset_search_bounds(anchor_offset:, anchor_trust:, max_off:)
      floor = 0
      ceil = max_off.to_i
      ceil = floor if ceil < floor

      trust = clamp_unit_interval(anchor_trust)
      center = anchor_offset.to_i
      center = floor if center < floor
      center = ceil if center > ceil

      if trust >= ANCHORED_SHORTLIST_STRONG_TRUST.to_f
        radius = [ANCHORED_SHORTLIST_STRONG_WINDOW_SEGMENTS.to_i, CANDIDATE_EVIDENCE_LOCAL_OFFSET_RADIUS.to_i * 2].max
        mode = "anchored_strong"
      elsif trust >= ANCHORED_SHORTLIST_MODERATE_TRUST.to_f
        radius = [ANCHORED_SHORTLIST_MODERATE_WINDOW_SEGMENTS.to_i, CANDIDATE_EVIDENCE_LOCAL_OFFSET_RADIUS.to_i * 3].max
        mode = "anchored_moderate"
      else
        radius = ceil
        mode = "global_fallback"
      end

      lo = [center - radius, floor].max
      hi = [center + radius, ceil].min
      hi = lo if hi < lo

      {
        floor: lo,
        ceil: hi,
        mode: mode,
        radius: radius,
      }
    rescue
      {
        floor: 0,
        ceil: [max_off.to_i, 0].max,
        mode: "global_fallback",
        radius: [max_off.to_i, 0].max,
      }
    end
    private_class_method :shortlist_offset_search_bounds

    def shortlist_should_review_both_polarities?(anchor_trust:, polarity_score_delta:, polarity_gate_passed:)
      trust = clamp_unit_interval(anchor_trust)
      score_delta = polarity_score_delta.to_f.abs
      return true unless polarity_gate_passed
      return true if trust < 0.35
      return true if score_delta <= CANDIDATE_POLARITY_REVIEW_MAX_SCORE_DELTA.to_f

      false
    rescue
      true
    end
    private_class_method :shortlist_should_review_both_polarities?

    def build_candidate_evidence!(candidate:, observed_variants:, observed_confidences:, media_item_id:, observed_segment_indices: nil, local_offset_radius: 0, offset_floor: 0, offset_ceil: nil, anchor_offset: nil, anchor_trust: 0.0, observed_polarity_flip: false, layout: nil)
      entries = chunk_observation_entries(
        observed_variants: observed_variants,
        observed_confidences: observed_confidences,
        observed_segment_indices: observed_segment_indices,
        layout: layout
      )
      return candidate if entries.empty?

      offset = candidate[:best_offset_segments].to_i
      chunk_size = CANDIDATE_EVIDENCE_CHUNK_SIZE.to_i
      chunk_size = 8 if chunk_size <= 0

      max_offset = offset_ceil.nil? ? offset : offset_ceil.to_i
      max_offset = offset if max_offset < offset

      chunk_scores = []
      chosen_offsets = []
      offset_distances = []
      entries.each_slice(chunk_size) do |chunk|
        alignment = best_candidate_chunk_alignment(
          candidate: candidate,
          chunk: chunk,
          media_item_id: media_item_id,
          base_offset: offset,
          local_offset_radius: local_offset_radius,
          offset_floor: offset_floor,
          offset_ceil: max_offset,
          observed_polarity_flip: observed_polarity_flip
        )
        next if alignment.blank? || alignment[:comp_w].to_f <= 0.0

        chunk_scores << {
          ratio: alignment[:ratio].to_f,
          comp_w: alignment[:comp_w].to_f,
          llr: alignment[:llr].to_f,
          usable: chunk.length,
          offset: alignment[:offset].to_i,
          offset_distance: alignment[:offset_distance].to_i,
        }
        chosen_offsets << alignment[:offset].to_i
        offset_distances << alignment[:offset_distance].to_i
      end

      return candidate if chunk_scores.empty?

      ratios = chunk_scores.map { |row| row[:ratio].to_f }
      total_llr = chunk_scores.sum { |row| row[:llr].to_f }
      consistent_chunks = chunk_scores.count { |row| row[:ratio].to_f >= 0.70 }
      weak_chunks = chunk_scores.count { |row| row[:ratio].to_f < 0.55 }

      local_offset_bonus = 0.0
      stable_local_chunks = nil
      if local_offset_radius.to_i > 0 && chosen_offsets.present?
        median_offset = median(chosen_offsets).to_f
        stable_local_chunks = chosen_offsets.count { |off| (off.to_f - median_offset).abs <= 1.0 }
        spread = chosen_offsets.max.to_i - chosen_offsets.min.to_i
        local_offset_bonus = (stable_local_chunks.to_f * 0.2) - ([spread - local_offset_radius.to_i, 0].max * 0.03)

        candidate[:evidence_offset_mode] = "local_chunk_search"
        candidate[:evidence_local_offset_radius] = local_offset_radius.to_i
        candidate[:evidence_local_offsets] = chosen_offsets
        candidate[:evidence_local_offset_median] = median_offset.round(2)
        candidate[:evidence_local_offset_spread] = spread.to_i
        candidate[:evidence_local_offset_stable_chunks] = stable_local_chunks.to_i
        candidate[:evidence_local_offset_mean_distance] = median(offset_distances).to_f.round(2)
      else
        candidate[:evidence_offset_mode] = "fixed_offset"
      end

      evidence_score = total_llr + (median(ratios).to_f * 2.0) + (consistent_chunks.to_f * 0.5) - (weak_chunks.to_f * 0.75) + local_offset_bonus

      anchor_shift_penalty = 0.0
      anchor_distance = nil
      if !anchor_offset.nil?
        anchor_distance = (candidate[:best_offset_segments].to_i - anchor_offset.to_i).abs
        anchor_shift_penalty = anchor_distance.to_f * clamp_unit_interval(anchor_trust) * CANDIDATE_ANCHOR_SHIFT_PENALTY.to_f
      end
      rank_score = evidence_score - anchor_shift_penalty

      candidate[:evidence_chunks] = chunk_scores.length
      candidate[:evidence_consistent_chunks] = consistent_chunks
      candidate[:evidence_inconsistent_chunks] = weak_chunks
      candidate[:chunk_match_ratio_median] = median(ratios).to_f.round(4)
      candidate[:chunk_match_ratio_min] = ratios.min.to_f.round(4)
      candidate[:chunk_match_ratio_max] = ratios.max.to_f.round(4)
      candidate[:chunk_llr_total] = total_llr.round(4)
      candidate[:evidence_score] = evidence_score.round(4)
      candidate[:rank_score] = rank_score.round(4)
      unless anchor_distance.nil?
        candidate[:anchor_offset_segments] = anchor_offset.to_i
        candidate[:anchor_offset_distance] = anchor_distance.to_i
        candidate[:anchor_shift_penalty] = anchor_shift_penalty.round(4)
        candidate[:anchor_trust] = clamp_unit_interval(anchor_trust).round(4)
      end

      why_parts = [
        "score=#{candidate[:evidence_score]}",
        "rank=#{candidate[:rank_score]}",
        "llr=#{candidate[:chunk_llr_total]}",
        "median_chunk=#{candidate[:chunk_match_ratio_median]}",
        "stable_chunks=#{consistent_chunks}/#{chunk_scores.length}",
        "weighted_match=#{candidate[:match_ratio_weighted]}"
      ]
      if local_offset_radius.to_i > 0 && chosen_offsets.present?
        why_parts << "local_offsets=#{chosen_offsets.uniq.join('/')}"
        why_parts << "local_stable=#{stable_local_chunks}/#{chunk_scores.length}"
      end
      if !anchor_distance.nil?
        why_parts << "anchor_dist=#{anchor_distance}"
        why_parts << "anchor_penalty=#{anchor_shift_penalty.round(4)}" if anchor_shift_penalty > 0.0
      end
      candidate[:why] = why_parts.join(", ")

      candidate
    rescue
      candidate
    end
    private_class_method :build_candidate_evidence!

    def verify_shortlist_candidates_with_local_offsets!(candidates:, media_item:, build_usable:, polarity_flip:, max_off:, shortlist_limit: SHORTLIST_VERIFY_LIMIT, anchor_trust: 0.0, polarity_score_delta: nil, polarity_gate_passed: true)
      arr = Array(candidates)
      return arr if arr.empty?

      limit = [shortlist_limit.to_i, arr.length].min
      return arr if limit <= 0

      arr.first(limit).each do |candidate|
        original_offset = candidate[:best_offset_segments].to_i
        best = nil
        bounds = shortlist_offset_search_bounds(
          anchor_offset: original_offset,
          anchor_trust: anchor_trust,
          max_off: max_off
        )
        flips_to_try = if shortlist_should_review_both_polarities?(
          anchor_trust: anchor_trust,
          polarity_score_delta: polarity_score_delta,
          polarity_gate_passed: polarity_gate_passed
        )
          [polarity_flip ? true : false, !(polarity_flip ? true : false)].uniq
        else
          [polarity_flip ? true : false]
        end

        flips_to_try.each do |candidate_polarity_flip|
          (bounds[:floor].to_i..bounds[:ceil].to_i).each do |offset|
            usable_result = build_usable.call(offset, candidate_polarity_flip)
            next if usable_result.blank? || Array(usable_result[:usable]).empty? || usable_result[:comp_w].to_f <= 0.0

            stats = reference_candidate_match_stats(
              candidate: candidate,
              usable_result: usable_result,
              media_item_id: media_item.id,
              offset: offset
            )
            next if stats.blank?

            shift_distance = (offset.to_i - original_offset.to_i).abs
            shift_penalty = shift_distance.to_f * clamp_unit_interval(anchor_trust) * 0.03
            polarity_penalty = (candidate_polarity_flip == polarity_flip ? 0.0 : (clamp_unit_interval(anchor_trust) * 0.2))

            score = stats[:llr].to_f +
              (stats[:match_ratio_weighted].to_f * 0.35) +
              (stats[:usable_count].to_f * 0.02) +
              (stats[:median_margin].to_f * 0.2) -
              (offset.to_f * 0.0002) -
              shift_penalty -
              polarity_penalty

            entry = stats.merge(
              score: score,
              polarity_flip_used: candidate_polarity_flip,
              search_mode: bounds[:mode],
              search_floor: bounds[:floor].to_i,
              search_ceil: bounds[:ceil].to_i,
              shift_penalty: shift_penalty,
              polarity_penalty: polarity_penalty
            )
            if best.nil? || entry[:score].to_f > best[:score].to_f ||
                 (entry[:score].to_f == best[:score].to_f && entry[:match_ratio_weighted].to_f > best[:match_ratio_weighted].to_f) ||
                 (entry[:score].to_f == best[:score].to_f && entry[:match_ratio_weighted].to_f == best[:match_ratio_weighted].to_f && entry[:compared].to_i > best[:compared].to_i)
              best = entry
            end
          end
        end

        next if best.blank?

        candidate[:retrieval_offset_segments] = original_offset
        candidate[:best_offset_segments] = best[:offset].to_i
        candidate[:mismatches] = best[:mismatches].to_i
        candidate[:compared] = best[:compared].to_i
        candidate[:mismatches_weighted] = best[:mismatches_weighted].to_f.round(6)
        candidate[:compared_weighted] = best[:compared_weighted].to_f.round(6)
        candidate[:match_ratio] = best[:match_ratio].to_f.round(4)
        candidate[:match_ratio_weighted] = best[:match_ratio_weighted].to_f.round(4)
        candidate[:local_best_offset_segments] = best[:offset].to_i
        candidate[:local_match_ratio] = best[:match_ratio_weighted].to_f.round(4)
        candidate[:candidate_offset_llr] = best[:llr].to_f.round(4)
        candidate[:candidate_offset_score] = best[:score].to_f.round(4)
        candidate[:candidate_offset_shift] = (best[:offset].to_i - original_offset.to_i)
        candidate[:polarity_flip_used] = best[:polarity_flip_used] ? true : false
        candidate[:variant_polarity] = (best[:polarity_flip_used] ? "inverted" : "normal")
        candidate[:candidate_offset_search_mode] = best[:search_mode]
        candidate[:candidate_offset_search_bounds] = [best[:search_floor].to_i, best[:search_ceil].to_i]
        candidate[:candidate_offset_shift_penalty] = best[:shift_penalty].to_f.round(4)
        candidate[:candidate_offset_polarity_penalty] = best[:polarity_penalty].to_f.round(4)
      end

      arr
    rescue
      Array(candidates)
    end
    private_class_method :verify_shortlist_candidates_with_local_offsets!

    def heavy_decoder_time_allows?(started_at:, budget_seconds:, min_remaining_seconds:)
      return true if started_at.blank? || budget_seconds.to_f <= 0.0
      time_remaining_seconds(started_at: started_at, budget_seconds: budget_seconds) >= min_remaining_seconds.to_f
    rescue
      true
    end
    private_class_method :heavy_decoder_time_allows?

    def heavy_decoder_ranking_pool(candidates:, max_candidates:)
      arr = Array(candidates)
      limit = max_candidates.to_i
      return [arr, []] if limit <= 0 || arr.length <= limit
      [arr.first(limit), arr.drop(limit)]
    rescue
      [Array(candidates), []]
    end
    private_class_method :heavy_decoder_ranking_pool

    def pairwise_chunk_decoder_chunks(entries:)
      arr = Array(entries)
      return [] if arr.length < [PAIRWISE_CHUNK_DECODER_MIN_ENTRIES / 2, 4].max

      chunk_size = PAIRWISE_CHUNK_DECODER_CHUNK_SIZE.to_i
      chunk_size = 8 if chunk_size <= 0
      chunk_size = [chunk_size, arr.length].min

      step = PAIRWISE_CHUNK_DECODER_CHUNK_STEP.to_i
      step = [chunk_size / 2, 1].max if step <= 0

      chunks = []
      start = 0
      while start < arr.length
        chunk = arr.slice(start, chunk_size)
        break if chunk.blank?
        chunks << chunk
        break if start + chunk_size >= arr.length
        start += step
      end

      chunks.uniq { |chunk| [chunk.first[0], chunk.last[0], chunk.length] }
    rescue
      []
    end
    private_class_method :pairwise_chunk_decoder_chunks

    def pairwise_chunk_decoder_should_run?(candidates:, entries:)
      Array(candidates).length >= 2 && Array(entries).length >= PAIRWISE_CHUNK_DECODER_MIN_ENTRIES.to_i
    rescue
      false
    end
    private_class_method :pairwise_chunk_decoder_should_run?

    def apply_pairwise_chunk_decoder!(candidates:, observed_variants:, observed_confidences:, media_item_id:, observed_segment_indices: nil, max_off:, anchor_offset:, anchor_trust: 0.0, observed_polarity_flip: false, started_at: nil, budget_seconds: nil, layout: nil)
      return { used: false, reason: "skipped_low_remaining_time" } unless heavy_decoder_time_allows?(started_at: started_at, budget_seconds: budget_seconds, min_remaining_seconds: PAIRWISE_CHUNK_DECODER_MIN_REMAINING_SECONDS)

      full_arr = Array(candidates)
      ranking_pool, ranking_tail = heavy_decoder_ranking_pool(candidates: full_arr, max_candidates: PAIRWISE_CHUNK_DECODER_MAX_CANDIDATES)
      arr = ranking_pool
      entries = chunk_observation_entries(
        observed_variants: observed_variants,
        observed_confidences: observed_confidences,
        observed_segment_indices: observed_segment_indices,
        layout: layout
      )
      return { used: false, reason: "not_enough_entries_or_candidates" } unless pairwise_chunk_decoder_should_run?(candidates: arr, entries: entries)

      chunks = pairwise_chunk_decoder_chunks(entries: entries)
      return { used: false, reason: "not_enough_chunks" } if chunks.length < PAIRWISE_CHUNK_DECODER_MIN_CHUNKS.to_i

      original_order = arr.map { |candidate| candidate[:fingerprint_id] }
      evidence_top = arr[0]
      evidence_second = arr[1]
      evidence_gap = if evidence_top && evidence_second
        evidence_top[:evidence_score].to_f - evidence_second[:evidence_score].to_f
      else
        0.0
      end

      per_candidate_rows = {}
      arr.each do |candidate|
        base_offset = candidate[:best_offset_segments].to_i
        bounds = shortlist_offset_search_bounds(
          anchor_offset: base_offset,
          anchor_trust: anchor_trust,
          max_off: max_off
        )
        local_radius = [PAIRWISE_CHUNK_DECODER_LOCAL_OFFSET_RADIUS.to_i, max_off.to_i].min
        local_radius = [local_radius, [chunks.first.length / 2, 2].max].max

        rows = chunks.map do |chunk|
          best_candidate_chunk_alignment(
            candidate: candidate,
            chunk: chunk,
            media_item_id: media_item_id,
            base_offset: base_offset,
            local_offset_radius: local_radius,
            offset_floor: bounds[:floor].to_i,
            offset_ceil: bounds[:ceil].to_i,
            observed_polarity_flip: observed_polarity_flip
          )
        end

        per_candidate_rows[candidate[:fingerprint_id]] = rows
      end

      return { used: false, reason: "no_chunk_alignments" } if per_candidate_rows.blank?

      arr.each do |candidate|
        rows = Array(per_candidate_rows[candidate[:fingerprint_id]])
        next if rows.blank?

        margins = []
        won = 0
        lost = 0
        tied = 0
        used_rows = []

        rows.each_with_index do |row, idx|
          next if row.blank?

          competitors = arr.filter_map do |other|
            next if other[:fingerprint_id] == candidate[:fingerprint_id]
            other_row = Array(per_candidate_rows[other[:fingerprint_id]])[idx]
            other_row.present? ? other_row[:search_score].to_f : nil
          end
          next if competitors.empty?

          best_other = competitors.max.to_f
          margin = row[:search_score].to_f - best_other
          margins << margin
          used_rows << row

          if margin > 0.05
            won += 1
          elsif margin < -0.05
            lost += 1
          else
            tied += 1
          end
        end

        next if used_rows.empty?

        pairwise_margin_total = margins.sum.to_f
        pairwise_margin_median = median(margins).to_f
        pairwise_bonus = (pairwise_margin_total * PAIRWISE_CHUNK_DECODER_MARGIN_WEIGHT.to_f) +
          (won.to_f * PAIRWISE_CHUNK_DECODER_WIN_WEIGHT.to_f) -
          (lost.to_f * PAIRWISE_CHUNK_DECODER_LOSS_WEIGHT.to_f)

        candidate[:base_rank_score] = candidate[:rank_score].to_f.round(4)
        candidate[:pairwise_chunk_margin_total] = pairwise_margin_total.round(4)
        candidate[:pairwise_chunk_margin_median] = pairwise_margin_median.round(4)
        candidate[:pairwise_chunks_won] = won
        candidate[:pairwise_chunks_lost] = lost
        candidate[:pairwise_chunks_tied] = tied
        candidate[:pairwise_chunk_offsets] = used_rows.map { |row| row[:offset].to_i }
        candidate[:pairwise_chunk_score_bonus] = pairwise_bonus.round(4)
        candidate[:rank_score] = (candidate[:rank_score].to_f + pairwise_bonus).round(4)
        candidate[:why] = [candidate[:why].to_s.presence, "pairwise_margin=#{candidate[:pairwise_chunk_margin_total]}", "pairwise_wins=#{won}/#{used_rows.length}", ("pairwise_losses=#{lost}" if lost > 0)].compact.join(", ")
      end

      arr.sort_by! do |candidate|
        [
          -candidate[:rank_score].to_f,
          -candidate[:pairwise_chunk_margin_total].to_f,
          -candidate[:evidence_score].to_f,
          -candidate[:match_ratio_weighted].to_f,
          -candidate[:compared].to_i,
          candidate[:mismatches].to_i,
        ]
      end

      top = arr[0]
      second = arr[1]
      if evidence_top.present? && top.present? && top[:fingerprint_id] != evidence_top[:fingerprint_id]
        top_chunks = [top[:pairwise_chunks_won].to_i + top[:pairwise_chunks_lost].to_i + top[:pairwise_chunks_tied].to_i, 0].max
        top_margin = top[:pairwise_chunk_margin_total].to_f
        evidence_anchor_dist = evidence_top[:anchor_offset_distance].to_i
        top_anchor_dist = top[:anchor_offset_distance].to_i

        evidence_should_prevail =
          top_chunks < PAIRWISE_OVERTURN_MIN_CHUNKS.to_i ||
          top_margin < PAIRWISE_OVERTURN_MIN_MARGIN.to_f ||
          evidence_gap > PAIRWISE_OVERTURN_MAX_EVIDENCE_GAP.to_f ||
          top[:pairwise_chunks_won].to_i <= top[:pairwise_chunks_lost].to_i ||
          (anchor_trust.to_f >= 0.55 && evidence_anchor_dist <= top_anchor_dist)

        if evidence_should_prevail
          arr.sort_by! do |candidate|
            [
              -candidate[:evidence_score].to_f,
              -candidate[:match_ratio_weighted].to_f,
              -(candidate[:candidate_offset_llr].to_f),
              candidate[:anchor_offset_distance].to_i,
              -candidate[:compared].to_i,
              candidate[:mismatches].to_i,
              original_order.index(candidate[:fingerprint_id]) || 9999,
            ]
          end
          combined = arr + ranking_tail
          full_arr.replace(combined)
          full_arr.each_with_index { |candidate, idx| candidate[:shortlist_rank] = idx + 1 }
          return {
            used: false,
            reason: "pairwise_overturn_blocked_evidence_preferred",
            chunks: chunks.length,
            top_margin: top ? top[:pairwise_chunk_margin_total].to_f.round(4) : 0.0,
            second_margin: second ? second[:pairwise_chunk_margin_total].to_f.round(4) : 0.0,
            top_bonus: top ? top[:pairwise_chunk_score_bonus].to_f.round(4) : 0.0,
          }
        end
      end

      combined = arr + ranking_tail
      full_arr.replace(combined)
      full_arr.each_with_index { |candidate, idx| candidate[:shortlist_rank] = idx + 1 }

      top = arr[0]
      second = arr[1]
      {
        used: true,
        reason: "pairwise_chunk_margin_applied",
        chunks: chunks.length,
        top_margin: top ? top[:pairwise_chunk_margin_total].to_f.round(4) : 0.0,
        second_margin: second ? second[:pairwise_chunk_margin_total].to_f.round(4) : 0.0,
        top_bonus: top ? top[:pairwise_chunk_score_bonus].to_f.round(4) : 0.0,
      }
    rescue
      { used: false, reason: "pairwise_chunk_decoder_failed" }
    end
    private_class_method :apply_pairwise_chunk_decoder!

    def apply_discriminative_shortlist_decoder!(candidates:, observed_variants:, observed_confidences:, media_item_id:, observed_segment_indices: nil, observed_polarity_flip: false, started_at: nil, budget_seconds: nil, layout: nil)
      return { used: false, reason: "skipped_low_remaining_time" } unless heavy_decoder_time_allows?(started_at: started_at, budget_seconds: budget_seconds, min_remaining_seconds: DISCRIMINATIVE_SHORTLIST_MIN_REMAINING_SECONDS)

      arr = Array(candidates)
      return { used: false, reason: "not_enough_candidates" } if arr.length < 2

      top = arr[0]
      second = arr[1]
      rank_gap = (top[:rank_score].to_f - second[:rank_score].to_f)
      evidence_gap = (top[:evidence_score].to_f - second[:evidence_score].to_f)
      if evidence_gap > DISCRIMINATIVE_SHORTLIST_MAX_EVIDENCE_GAP.to_f && rank_gap > DISCRIMINATIVE_SHORTLIST_MAX_RANK_GAP.to_f
        return { used: false, reason: "existing_separation_already_sufficient" }
      end

      entries = chunk_observation_entries(
        observed_variants: observed_variants,
        observed_confidences: observed_confidences,
        observed_segment_indices: observed_segment_indices,
        layout: layout
      )
      return { used: false, reason: "not_enough_entries" } if entries.length < DISCRIMINATIVE_SHORTLIST_MIN_ENTRIES.to_i

      chunks = pairwise_chunk_decoder_chunks(entries: entries)
      return { used: false, reason: "not_enough_chunks" } if chunks.length < 2

      candidate_a = top
      candidate_b = second
      offsets_a = Array(candidate_a[:evidence_local_offsets])
      offsets_b = Array(candidate_b[:evidence_local_offsets])
      base_a = candidate_a[:local_best_offset_segments].presence || candidate_a[:best_offset_segments]
      base_b = candidate_b[:local_best_offset_segments].presence || candidate_b[:best_offset_segments]

      margins = []
      diff_positions = 0
      chunk_offsets_a = []
      chunk_offsets_b = []
      won = 0
      lost = 0
      tied = 0

      chunks.each_with_index do |chunk, idx|
        off_a = (offsets_a[idx].presence || base_a).to_i
        off_b = (offsets_b[idx].presence || base_b).to_i
        chunk_offsets_a << off_a
        chunk_offsets_b << off_b

        chunk_margin = 0.0
        chunk_comp_w = 0.0

        chunk.each do |(_obs_idx, base_seg_idx, ov, weight)|
          exp_a = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: candidate_a[:fingerprint_id],
            media_item_id: media_item_id,
            segment_index: base_seg_idx.to_i + off_a
          )
          exp_b = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: candidate_b[:fingerprint_id],
            media_item_id: media_item_id,
            segment_index: base_seg_idx.to_i + off_b
          )
          next if exp_a == exp_b

          obs_a = candidate_observed_variant(candidate: candidate_a, observed_variant: ov, observed_polarity_flip: observed_polarity_flip)
          obs_b = candidate_observed_variant(candidate: candidate_b, observed_variant: ov, observed_polarity_flip: observed_polarity_flip)
          w = weight.to_f
          next if w <= 0.0

          diff_positions += 1
          chunk_comp_w += w
          if obs_a == exp_a && obs_b != exp_b
            chunk_margin += w
          elsif obs_b == exp_b && obs_a != exp_a
            chunk_margin -= w
          end
        end

        next if chunk_comp_w <= 0.0
        norm_margin = chunk_margin / chunk_comp_w
        margins << norm_margin
        if norm_margin > DISCRIMINATIVE_SHORTLIST_TIE_THRESHOLD.to_f
          won += 1
        elsif norm_margin < -DISCRIMINATIVE_SHORTLIST_TIE_THRESHOLD.to_f
          lost += 1
        else
          tied += 1
        end
      end

      return { used: false, reason: "not_enough_discriminative_positions" } if diff_positions < DISCRIMINATIVE_SHORTLIST_MIN_DIFF_POSITIONS.to_i || margins.empty?

      total_margin = margins.sum.to_f
      median_margin = median(margins).to_f
      bonus = (total_margin * DISCRIMINATIVE_SHORTLIST_MARGIN_WEIGHT.to_f) +
        (won.to_f * DISCRIMINATIVE_SHORTLIST_WIN_WEIGHT.to_f) -
        (lost.to_f * DISCRIMINATIVE_SHORTLIST_LOSS_WEIGHT.to_f)

      candidate_a[:discriminative_margin_total] = total_margin.round(4)
      candidate_a[:discriminative_margin_median] = median_margin.round(4)
      candidate_a[:discriminative_positions] = diff_positions
      candidate_a[:discriminative_chunks_won] = won
      candidate_a[:discriminative_chunks_lost] = lost
      candidate_a[:discriminative_chunks_tied] = tied
      candidate_a[:discriminative_chunk_offsets] = chunk_offsets_a
      candidate_a[:discriminative_bonus] = bonus.round(4)
      candidate_a[:rank_score] = (candidate_a[:rank_score].to_f + bonus).round(4)
      candidate_a[:why] = [candidate_a[:why].to_s.presence, "disc_margin=#{candidate_a[:discriminative_margin_total]}", "disc_diff=#{diff_positions}", "disc_wins=#{won}/#{margins.length}", ("disc_losses=#{lost}" if lost > 0)].compact.join(", ")

      candidate_b[:discriminative_margin_total] = (-total_margin).round(4)
      candidate_b[:discriminative_margin_median] = (-median_margin).round(4)
      candidate_b[:discriminative_positions] = diff_positions
      candidate_b[:discriminative_chunks_won] = lost
      candidate_b[:discriminative_chunks_lost] = won
      candidate_b[:discriminative_chunks_tied] = tied
      candidate_b[:discriminative_chunk_offsets] = chunk_offsets_b
      candidate_b[:discriminative_bonus] = (-bonus).round(4)
      candidate_b[:rank_score] = (candidate_b[:rank_score].to_f - bonus).round(4)
      candidate_b[:why] = [candidate_b[:why].to_s.presence, "disc_margin=#{candidate_b[:discriminative_margin_total]}", "disc_diff=#{diff_positions}", "disc_wins=#{lost}/#{margins.length}", ("disc_losses=#{won}" if won > 0)].compact.join(", ")

      original_top_id = top[:fingerprint_id]
      arr.sort_by! do |candidate|
        [
          -candidate[:rank_score].to_f,
          -candidate[:discriminative_margin_total].to_f,
          -candidate[:evidence_score].to_f,
          -candidate[:match_ratio_weighted].to_f,
          -candidate[:compared].to_i,
          candidate[:mismatches].to_i,
        ]
      end

      new_top = arr[0]
      if new_top && new_top[:fingerprint_id] != original_top_id && total_margin.abs < DISCRIMINATIVE_SHORTLIST_OVERTURN_MIN_MARGIN.to_f
        arr.sort_by! do |candidate|
          [
            -candidate[:evidence_score].to_f,
            -candidate[:rank_score].to_f,
            -candidate[:match_ratio_weighted].to_f,
            -candidate[:compared].to_i,
            candidate[:mismatches].to_i,
          ]
        end
        arr.each_with_index { |candidate, idx| candidate[:shortlist_rank] = idx + 1 }
        return {
          used: false,
          reason: "discriminative_overturn_blocked_margin_too_small",
          diff_positions: diff_positions,
          total_margin: total_margin.round(4),
          bonus: bonus.round(4),
        }
      end

      arr.each_with_index { |candidate, idx| candidate[:shortlist_rank] = idx + 1 }
      {
        used: true,
        reason: "discriminative_shortlist_margin_applied",
        diff_positions: diff_positions,
        total_margin: total_margin.round(4),
        bonus: bonus.round(4),
      }
    rescue
      { used: false, reason: "discriminative_shortlist_decoder_failed" }
    end
    private_class_method :apply_discriminative_shortlist_decoder!

    def enrich_candidates_with_evidence!(candidates:, observed_variants:, observed_confidences:, media_item_id:, observed_segment_indices: nil, local_offset_radius: 0, offset_floor: 0, offset_ceil: nil, anchor_offset: nil, anchor_trust: 0.0, observed_polarity_flip: false, layout: nil)
      arr = Array(candidates)
      return arr if arr.empty?

      arr.each do |candidate|
        build_candidate_evidence!(
          candidate: candidate,
          observed_variants: observed_variants,
          observed_confidences: observed_confidences,
          media_item_id: media_item_id,
          observed_segment_indices: observed_segment_indices,
          local_offset_radius: local_offset_radius,
          offset_floor: offset_floor,
          offset_ceil: offset_ceil,
          anchor_offset: anchor_offset,
          anchor_trust: anchor_trust,
          observed_polarity_flip: observed_polarity_flip,
          layout: layout
        )
      end

      arr.sort_by! do |candidate|
        [
          -candidate[:rank_score].to_f,
          -candidate[:evidence_score].to_f,
          -candidate[:match_ratio_weighted].to_f,
          -candidate[:compared].to_i,
          candidate[:mismatches].to_i,
        ]
      end

      arr.each_with_index { |candidate, idx| candidate[:shortlist_rank] = idx + 1 }
      arr
    rescue
      Array(candidates)
    end
    private_class_method :enrich_candidates_with_evidence!

    def shortlist_prefilter_limit(total_candidates:, observed_count:)
      total = total_candidates.to_i
      return total if total <= SHORTLIST_LIMIT

      observed = observed_count.to_i
      adaptive = [
        SHORTLIST_PREFILTER_MIN,
        SHORTLIST_LIMIT + 2,
        (Math.sqrt(total.to_f) * SHORTLIST_PREFILTER_POP_SQRT_FACTOR).ceil,
        (observed.to_f / SHORTLIST_PREFILTER_OBSERVED_DIVISOR).ceil,
      ].max

      [[adaptive, SHORTLIST_PREFILTER_MAX].min, total].min
    rescue
      [SHORTLIST_PREFILTER_MIN, total_candidates.to_i].min
    end
    private_class_method :shortlist_prefilter_limit

    def merge_observation_quality_hints(base_obs:, added_segment_indices: nil, refined_segment_indices: nil)
      existing = (base_obs.is_a?(Hash) ? (base_obs[:quality_hints] || base_obs["quality_hints"]) : nil) || {}
      fill = Set.new(Array(existing[:filled_segment_indices] || existing["filled_segment_indices"]).map(&:to_i))
      refined = Set.new(Array(existing[:refined_segment_indices] || existing["refined_segment_indices"]).map(&:to_i))
      Array(added_segment_indices).each { |v| fill << v.to_i }
      Array(refined_segment_indices).each { |v| refined << v.to_i }
      {
        filled_segment_indices: fill.to_a.sort,
        refined_segment_indices: refined.to_a.sort,
      }
    rescue
      { filled_segment_indices: [], refined_segment_indices: [] }
    end
    private_class_method :merge_observation_quality_hints

    def materially_changed_refine_segment_indices(base_obs:, refined_obs:)
      base_idx = Array(base_obs[:segment_indices])
      ref_idx = Array(refined_obs[:segment_indices])
      return [] if base_idx.blank? || ref_idx.blank?

      out = []
      [base_idx.length, ref_idx.length].min.times do |i|
        next unless base_idx[i].to_i == ref_idx[i].to_i
        base_variant = Array(base_obs[:variants])[i].presence
        ref_variant = Array(refined_obs[:variants])[i].presence
        base_conf = Array(base_obs[:confidences])[i].to_f
        ref_conf = Array(refined_obs[:confidences])[i].to_f
        base_score = Array(base_obs[:scores])[i].to_f
        ref_score = Array(refined_obs[:scores])[i].to_f
        changed = false
        changed ||= (base_variant != ref_variant)
        changed ||= ((ref_conf - base_conf).abs >= 0.12)
        changed ||= ((ref_score - base_score).abs >= 0.75)
        out << ref_idx[i].to_i if changed
      end
      out.uniq.sort
    rescue
      []
    end
    private_class_method :materially_changed_refine_segment_indices

    def build_adaptive_weight_context(observed_scores:, observed_sync_confidences:, observed_segment_indices:, observed_quality_hints: nil)
      scores = Array(observed_scores).map { |v| v.to_f }
      syncs = Array(observed_sync_confidences).map { |v| v.to_f }
      segs = Array(observed_segment_indices)
      abs_scores = scores.map { |v| v.abs }.select { |v| v > 0.0 && !v.nan? && !v.infinite? }.sort
      low_score = abs_scores.empty? ? 0.0 : abs_scores[(abs_scores.length * 0.35).floor]
      high_score = abs_scores.empty? ? 0.0 : abs_scores[(abs_scores.length * 0.70).floor]
      low_score = 0.0 if low_score.nan? || low_score.infinite?
      high_score = low_score if high_score.nan? || high_score.infinite?
      filled = Set.new(Array((observed_quality_hints || {})[:filled_segment_indices] || (observed_quality_hints || {})["filled_segment_indices"]).map(&:to_i))
      refined = Set.new(Array((observed_quality_hints || {})[:refined_segment_indices] || (observed_quality_hints || {})["refined_segment_indices"]).map(&:to_i))
      usable_segment_indices = segs.compact.map(&:to_i).uniq.sort
      nearest_gap = {}
      usable_segment_indices.each_with_index do |seg, idx|
        prev_gap = idx > 0 ? (seg - usable_segment_indices[idx - 1]).abs : nil
        next_gap = idx + 1 < usable_segment_indices.length ? (usable_segment_indices[idx + 1] - seg).abs : nil
        nearest_gap[seg] = [prev_gap, next_gap].compact.min
      end
      {
        low_score_threshold: low_score.to_f,
        high_score_threshold: high_score.to_f,
        filled_segment_indices: filled,
        refined_segment_indices: refined,
        nearest_gap: nearest_gap,
        syncs: syncs,
        scores: scores,
      }
    rescue
      {
        low_score_threshold: 0.0,
        high_score_threshold: 0.0,
        filled_segment_indices: Set.new,
        refined_segment_indices: Set.new,
        nearest_gap: {},
        syncs: [],
        scores: [],
      }
    end
    private_class_method :build_adaptive_weight_context

    def adaptive_sample_weight_factor(obs_idx:, base_seg_idx:, confidence:, adaptive_ctx:)
      factor = 1.0
      conf = confidence.to_f
      score = Array(adaptive_ctx[:scores])[obs_idx].to_f.abs
      sync_conf = Array(adaptive_ctx[:syncs])[obs_idx].to_f
      nearest_gap = adaptive_ctx[:nearest_gap][base_seg_idx.to_i]
      filled = adaptive_ctx[:filled_segment_indices].include?(base_seg_idx.to_i)
      refined = adaptive_ctx[:refined_segment_indices].include?(base_seg_idx.to_i)
      low_score = adaptive_ctx[:low_score_threshold].to_f
      high_score = adaptive_ctx[:high_score_threshold].to_f

      factor *= 0.82 if conf > 0.0 && conf < 0.55
      factor *= 1.06 if conf >= 0.82

      if high_score > 0.0
        factor *= 1.10 if score >= high_score
        factor *= 0.85 if score > 0.0 && score < low_score
      end

      factor *= 1.06 if sync_conf >= 0.55
      factor *= 0.92 if sync_conf > 0.0 && sync_conf < 0.22

      if nearest_gap.present?
        factor *= 0.84 if nearest_gap >= 18
        factor *= 0.92 if nearest_gap >= 10 && nearest_gap < 18
        factor *= 1.03 if nearest_gap <= 4
      end

      if filled
        factor *= conf >= 0.75 ? 0.88 : 0.72
      elsif refined
        factor *= 0.96 if conf < 0.60
      end

      [[factor, 1.28].min, 0.45].max
    rescue
      1.0
    end
    private_class_method :adaptive_sample_weight_factor

    def candidate_prefilter_sort_tuple(candidate)
      c = candidate.is_a?(Hash) ? candidate : {}
      adaptive_weighted = (c[:match_ratio_adaptive_weighted] || c["match_ratio_adaptive_weighted"]).to_f
      weighted = (c[:match_ratio_weighted] || c["match_ratio_weighted"]).to_f
      raw = (c[:match_ratio] || c["match_ratio"]).to_f
      adaptive_compared = (c[:compared_adaptive_weighted] || c["compared_adaptive_weighted"]).to_f
      compared_weighted = (c[:compared_weighted] || c["compared_weighted"]).to_f
      compared = (c[:compared] || c["compared"]).to_i
      mismatches = (c[:mismatches] || c["mismatches"]).to_i
      [-(adaptive_weighted.round(6)), -(weighted.round(6)), -(raw.round(6)), -(adaptive_compared.round(6)), -(compared_weighted.round(6)), -compared, mismatches]
    rescue
      [0.0, 0.0, 0.0, 0.0, 0.0, 0, 0]
    end
    private_class_method :candidate_prefilter_sort_tuple

    def apply_shortlist_prefilter(candidates:, observed_count:)
      arr = Array(candidates).dup
      total = arr.length
      return { candidates: arr, used: false, total: total, kept: total, limit: total, cutoff_weighted_ratio: 0.0 } if total <= SHORTLIST_LIMIT

      arr.sort_by! { |candidate| candidate_prefilter_sort_tuple(candidate) }
      limit = shortlist_prefilter_limit(total_candidates: total, observed_count: observed_count)
      limit = [[limit, SHORTLIST_LIMIT].max, total].min

      cutoff_weighted_ratio = arr[limit - 1] ? (arr[limit - 1][:match_ratio_weighted] || arr[limit - 1]["match_ratio_weighted"]).to_f : 0.0
      cutoff_raw_ratio = arr[limit - 1] ? (arr[limit - 1][:match_ratio] || arr[limit - 1]["match_ratio"]).to_f : 0.0

      kept = []
      arr.each_with_index do |candidate, idx|
        weighted = (candidate[:match_ratio_weighted] || candidate["match_ratio_weighted"]).to_f
        raw = (candidate[:match_ratio] || candidate["match_ratio"]).to_f
        keep = idx < limit
        unless keep
          keep ||= weighted >= (cutoff_weighted_ratio - SHORTLIST_PREFILTER_TIE_EPSILON)
          keep ||= raw >= (cutoff_raw_ratio - (SHORTLIST_PREFILTER_TIE_EPSILON * 0.5))
        end
        kept << candidate if keep
        break if kept.length >= SHORTLIST_PREFILTER_MAX
      end

      {
        candidates: kept,
        used: true,
        total: total,
        kept: kept.length,
        limit: limit,
        cutoff_weighted_ratio: cutoff_weighted_ratio.round(4),
      }
    rescue
      { candidates: arr, used: false, total: total, kept: total, limit: total, cutoff_weighted_ratio: 0.0 }
    end
    private_class_method :apply_shortlist_prefilter

    def apply_shortlist_meta!(meta:, candidates:)
      return meta unless meta.is_a?(Hash)

      arr = Array(candidates)
      top = arr[0]
      second = arr[1]
      third = arr[2]
      fourth = arr[3]
      meta[:shortlist_metric] = meta[:shortlist_metric].presence || "rank_score"
      meta[:shortlist_count] = arr.length
      meta[:shortlist_top_rank_score] = top ? top[:rank_score].to_f.round(4) : 0.0
      meta[:shortlist_second_rank_score] = second ? second[:rank_score].to_f.round(4) : 0.0
      meta[:shortlist_third_rank_score] = third ? third[:rank_score].to_f.round(4) : 0.0
      meta[:shortlist_fourth_rank_score] = fourth ? fourth[:rank_score].to_f.round(4) : 0.0
      meta[:shortlist_rank_gap] = ((top ? top[:rank_score].to_f : 0.0) - (second ? second[:rank_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_vs_third_rank_gap] = ((top ? top[:rank_score].to_f : 0.0) - (third ? third[:rank_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_vs_fourth_rank_gap] = ((top ? top[:rank_score].to_f : 0.0) - (fourth ? fourth[:rank_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_evidence_score] = top ? top[:evidence_score].to_f.round(4) : 0.0
      meta[:shortlist_second_evidence_score] = second ? second[:evidence_score].to_f.round(4) : 0.0
      meta[:shortlist_third_evidence_score] = third ? third[:evidence_score].to_f.round(4) : 0.0
      meta[:shortlist_fourth_evidence_score] = fourth ? fourth[:evidence_score].to_f.round(4) : 0.0
      meta[:shortlist_evidence_gap] = ((top ? top[:evidence_score].to_f : 0.0) - (second ? second[:evidence_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_vs_third_evidence_gap] = ((top ? top[:evidence_score].to_f : 0.0) - (third ? third[:evidence_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_vs_fourth_evidence_gap] = ((top ? top[:evidence_score].to_f : 0.0) - (fourth ? fourth[:evidence_score].to_f : 0.0)).round(4)
      meta[:shortlist_top_match_ratio] = top ? (top[:match_ratio] || top["match_ratio"]).to_f.round(4) : 0.0
      meta[:shortlist_second_match_ratio] = second ? (second[:match_ratio] || second["match_ratio"]).to_f.round(4) : 0.0
      meta[:shortlist_third_match_ratio] = third ? (third[:match_ratio] || third["match_ratio"]).to_f.round(4) : 0.0
      meta[:shortlist_fourth_match_ratio] = fourth ? (fourth[:match_ratio] || fourth["match_ratio"]).to_f.round(4) : 0.0
      meta[:shortlist_top_vs_third_match_delta] = ((top ? (top[:match_ratio] || top["match_ratio"]).to_f : 0.0) - (third ? (third[:match_ratio] || third["match_ratio"]).to_f : 0.0)).round(4)
      meta[:shortlist_top_vs_fourth_match_delta] = ((top ? (top[:match_ratio] || top["match_ratio"]).to_f : 0.0) - (fourth ? (fourth[:match_ratio] || fourth["match_ratio"]).to_f : 0.0)).round(4)
      meta[:shortlist_top_why] = top[:why] if top&.dig(:why).present?
      meta[:shortlist_second_why] = second[:why] if second&.dig(:why).present?
      meta
    rescue
      meta
    end
    private_class_method :apply_shortlist_meta!

    def match_fingerprints(media_item:, observed_variants:, observed_confidences: nil, observed_scores: nil, observed_sync_variants: nil, observed_sync_confidences: nil, observed_segment_indices: nil, observed_quality_hints: nil, spec: nil, max_offset_segments:, started_at: nil, time_budget_seconds: nil)
      fps = ::MediaGallery::MediaFingerprint.where(media_item_id: media_item.id).includes(:user).to_a
      return { candidates: [], meta: { offset_strategy: "global" } } if fps.empty?

      # Reference-calibrated matching path (for screen recordings / re-encodes):
      # If we have per-sample numeric scores (from pixel extraction) AND can read the packaged A/B segments,
      # we can classify each sample by comparing it against the packaged A/B reference for the corresponding segment index.
      #
      # This greatly reduces scene-bias (e.g. long runs of 'aaaaa...') and improves separation between users.
      if observed_scores.is_a?(Array) && observed_scores.present? && spec.is_a?(Hash)
        begin
          seg_indices = Array(observed_segment_indices)
          max_observed_segment = if seg_indices.present?
            seg_indices.compact.map(&:to_i).max.to_i
          else
            observed_scores.length.to_i - 1
          end
          needed_ref = max_observed_segment.to_i + max_offset_segments.to_i + 2
          ref = reference_tables_for(media_item: media_item, spec: spec, needed_count: needed_ref)

          if ref && ref[:thr].is_a?(Array) && ref[:delta].is_a?(Array)
            return match_fingerprints_with_reference(
              fps: fps,
              media_item: media_item,
              scores: observed_scores,
              confidences: (observed_confidences.is_a?(Array) ? observed_confidences : []),
              observed_segment_indices: (observed_segment_indices.is_a?(Array) ? observed_segment_indices : []),
              sync_variants: (observed_sync_variants.is_a?(Array) ? observed_sync_variants : []),
              sync_confidences: (observed_sync_confidences.is_a?(Array) ? observed_sync_confidences : []),
              spec: spec,
              ref_thr: ref[:thr],
              ref_delta: ref[:delta],
              delta_median: ref[:delta_median].to_f,
              max_offset_segments: max_offset_segments.to_i,
              started_at: started_at,
              time_budget_seconds: time_budget_seconds
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
      seg_indices = observed_segment_indices.is_a?(Array) ? observed_segment_indices : []

      # Build a compact list of usable samples:
      # [observed_index, base_segment_index, "a"/"b", weight, confidence]
      #
      # Weighting:
      # - we always skip nil/blank bits
      # - higher confidence samples contribute more to mismatch scoring
      # - use confidence^2 to more strongly down-weight marginal readings
      adaptive_ctx = build_adaptive_weight_context(
        observed_scores: observed_scores,
        observed_sync_confidences: observed_sync_confidences,
        observed_segment_indices: seg_indices,
        observed_quality_hints: observed_quality_hints,
      )

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

        base_seg_idx = seg_indices[i].present? ? seg_indices[i].to_i : i
        adaptive_factor = adaptive_sample_weight_factor(
          obs_idx: i,
          base_seg_idx: base_seg_idx,
          confidence: c,
          adaptive_ctx: adaptive_ctx,
        )
        adaptive_w = (w.to_f * adaptive_factor.to_f)
        adaptive_w = w.to_f if adaptive_w <= 0.0
        samples << [i, base_seg_idx, v.to_s, w.to_f, c.to_f, adaptive_w.to_f, adaptive_factor.to_f]
      end

      return { candidates: [], meta: { offset_strategy: "global", chosen_offset_segments: 0, effective_samples: 0.0 } } if samples.empty?

      total_weight = samples.reduce(0.0) { |acc, s| acc + s[3].to_f }.to_f

      polarity_sets = [
        {
          flip: false,
          samples: samples,
          observed_variants: obs,
        }
      ]

      polarity_sets << {
        flip: true,
        samples: samples.map { |(obs_idx, base_seg_idx, ov, w, c)| [obs_idx, base_seg_idx, invert_variant(ov), w, c] },
        observed_variants: invert_variant_sequence(obs),
      }

      chosen_offset = 0
      chosen_polarity_flip = false
      chosen_samples = samples
      chosen_obs = obs
      best_score = nil
      best_diag = nil
      polarity_best_scores = { false => -Float::INFINITY, true => -Float::INFINITY }
      best_by_polarity = {}

      # Global offset selection:
      # We choose ONE offset for the leak clip and score all candidates using that.
      #
      # Why: letting each user pick their own best offset can overfit noise and
      # produce false positives with short clips.
      polarity_sets.each do |pol|
        pol_samples = pol[:samples]
        next if pol_samples.blank?

        raw_total_weight = pol_samples.reduce(0.0) { |acc, s| acc + s[3].to_f }.to_f

        (0..max_off).each do |offset|
          grouped_samples = ecc_grouped_samples(samples: pol_samples, offset: offset)
          next if grouped_samples.blank?

          grouped_total_weight = grouped_samples.reduce(0.0) { |acc, s| acc + s[3].to_f }.to_f
          next if grouped_total_weight <= 0.0

          top = nil
          second = nil

          fps.each do |rec|
            mism_w = 0.0
            comp_w = 0.0

            grouped_samples.each do |(_obs_idx, base_seg_idx, ov, w, _c, _raw_count, _margin)|
              exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
                fingerprint_id: rec.fingerprint_id,
                media_item_id: media_item.id,
                segment_index: base_seg_idx.to_i + offset
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

          coverage = raw_total_weight > 0 ? (grouped_total_weight.to_f / raw_total_weight.to_f) : 0.0

          # Score prioritizes separation, then overall fit, then coverage, then (slightly) prefers smaller offsets.
          # We still apply a small inverted-penalty here, but the final polarity choice is gated
          # separately so normal polarity remains the default unless inverted is clearly better.
          score = delta + (top[:ratio_w].to_f * 0.02) + (coverage.to_f * 0.01) - (offset.to_f * 0.0002) - (pol[:flip] ? 0.0025 : 0.0)
          polarity_best_scores[pol[:flip]] = score if score > polarity_best_scores[pol[:flip]]

          current_best = best_by_polarity[pol[:flip]]
          if current_best.nil? || score > current_best[:score] ||
               (score == current_best[:score] && top[:ratio_w].to_f > current_best.dig(:diag, :top_ratio_w).to_f)
            best_by_polarity[pol[:flip]] = {
              score: score,
              offset: offset,
              flip: pol[:flip],
              samples: grouped_samples,
              observed_variants: pol[:observed_variants],
              diag: {
                top_ratio_w: top[:ratio_w].to_f,
                second_ratio_w: second_ratio,
                delta: delta,
                coverage: coverage,
                ecc_groups: grouped_samples.length
              }
            }
          end
        end
      end

      polarity_choice = select_polarity_result(
        normal_result: best_by_polarity[false],
        inverted_result: best_by_polarity[true]
      )
      chosen_result = polarity_choice[:chosen] || best_by_polarity[false] || best_by_polarity[true]

      if chosen_result.present?
        best_score = chosen_result[:score]
        chosen_offset = chosen_result[:offset].to_i
        chosen_polarity_flip = chosen_result[:flip] ? true : false
        chosen_samples = chosen_result[:samples] || ecc_grouped_samples(samples: samples, offset: chosen_offset)
        chosen_obs = chosen_result[:observed_variants] || obs
        best_diag = chosen_result[:diag] || {}
      end

      # Compute candidates at the chosen global offset.
      candidates = []
      fps.each do |rec|
        mism_w = 0.0
        comp_w = 0.0
        mism_aw = 0.0
        comp_aw = 0.0
        mism = 0
        comp = 0
        high_q_mismatches = 0
        high_q_compared = 0

        chosen_samples.each do |(_obs_idx, base_seg_idx, ov, w, _c, _raw_count, _margin, adaptive_w, adaptive_factor)|
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: rec.fingerprint_id,
            media_item_id: media_item.id,
            segment_index: base_seg_idx.to_i + chosen_offset
          )

          comp += 1
          comp_w += w
          aw = adaptive_w.to_f > 0.0 ? adaptive_w.to_f : w.to_f
          comp_aw += aw
          high_q_compared += 1 if adaptive_factor.to_f >= 1.0
          if exp != ov
            mism += 1
            mism_w += w
            mism_aw += aw
            high_q_mismatches += 1 if adaptive_factor.to_f >= 1.0
          end
        end

        next if comp == 0 || comp_w <= 0.0

        raw_ratio = 1.0 - (mism.to_f / comp.to_f)
        w_ratio = 1.0 - (mism_w / comp_w)
        aw_ratio = comp_aw > 0.0 ? (1.0 - (mism_aw / comp_aw)) : w_ratio
        high_q_ratio = high_q_compared > 0 ? (1.0 - (high_q_mismatches.to_f / high_q_compared.to_f)) : raw_ratio

        candidates << {
          user_id: rec.user_id,
          username: rec.user&.username,
          fingerprint_id: rec.fingerprint_id,
          best_offset_segments: chosen_offset,
          mismatches: mism,
          compared: comp,
          mismatches_weighted: mism_w.round(6),
          compared_weighted: comp_w.round(6),
          mismatches_adaptive_weighted: mism_aw.round(6),
          compared_adaptive_weighted: comp_aw.round(6),
          match_ratio: raw_ratio.round(4),
          match_ratio_weighted: w_ratio.round(4),
          match_ratio_adaptive_weighted: aw_ratio.round(4),
          high_quality_matches: [high_q_compared - high_q_mismatches, 0].max,
          high_quality_compared: high_q_compared,
          high_quality_match_ratio: high_q_ratio.round(4),
          polarity_flip_used: chosen_polarity_flip,
          variant_polarity: (chosen_polarity_flip ? "inverted" : "normal"),
        }
      end

      prefilter_info = apply_shortlist_prefilter(
        candidates: candidates,
        observed_count: chosen_samples.length
      )
      candidates = prefilter_info[:candidates]

      enrich_candidates_with_evidence!(
        candidates: candidates,
        observed_variants: chosen_obs,
        observed_confidences: confs,
        observed_segment_indices: seg_indices,
        media_item_id: media_item.id,
        layout: v8_layout_name(spec&.dig(:layout) || spec&.[](:layout))
      )
      candidates = candidates.first(SHORTLIST_LIMIT)

      # Add diagnostics: local best offset per candidate (not used for ranking).
      if max_off > 0 && candidates.present?
        rec_by_user = fps.index_by(&:user_id)
        candidates.each do |cand|
          rec = rec_by_user[cand[:user_id]]
          next unless rec

          local = best_local_offset(rec: rec, samples: chosen_samples, max_off: max_off, media_item_id: media_item.id)
          cand[:local_best_offset_segments] = local[:offset]
          cand[:local_match_ratio] = local[:match_ratio].round(4)
        end
      end

      # Estimate "effective sample count" by normalizing the weighted sum using the median confidence^2.
      conf_list = chosen_samples.map { |s| s[4].to_f }.select { |c| c > 0.0 }
      med_c = median(conf_list)
      med_c = 0.03 if med_c <= 0.0
      norm = med_c * med_c
      chosen_total_weight = chosen_samples.reduce(0.0) { |acc, s| acc + s[3].to_f }.to_f
      chosen_adaptive_total_weight = chosen_samples.reduce(0.0) { |acc, s| acc + (s[7].to_f > 0.0 ? s[7].to_f : s[3].to_f) }.to_f
      effective = norm > 0 ? (chosen_total_weight / norm) : chosen_samples.length.to_f
      adaptive_effective = norm > 0 ? (chosen_adaptive_total_weight / norm) : chosen_samples.length.to_f
      effective = effective.round(2)
      adaptive_effective = adaptive_effective.round(2)
      quality_hints = observed_quality_hints.is_a?(Hash) ? observed_quality_hints : {}
      filled_set = Set.new(Array(quality_hints[:filled_segment_indices] || quality_hints["filled_segment_indices"]).map(&:to_i))
      high_quality_weight = chosen_samples.reduce(0.0) do |acc, s|
        aw = (s[7].to_f > 0.0 ? s[7].to_f : s[3].to_f)
        factor = s[6].to_f
        acc + ((factor >= 1.0) ? aw : 0.0)
      end.to_f
      adaptive_high_quality_support_ratio = chosen_adaptive_total_weight > 0.0 ? (high_quality_weight / chosen_adaptive_total_weight) : 0.0
      filled_count = chosen_samples.count { |s| filled_set.include?(s[1].to_i) }
      adaptive_filled_segment_ratio = chosen_samples.length > 0 ? (filled_count.to_f / chosen_samples.length.to_f) : 0.0

      meta = {
        offset_strategy: "global",
        chosen_offset_segments: chosen_offset,
        effective_samples: effective,
        polarity_flip_used: chosen_polarity_flip,
        variant_polarity: (chosen_polarity_flip ? "inverted" : "normal"),
        polarity_selection_strategy: "prefer_normal_unless_inverted_clearly_better",
        polarity_gate_passed: polarity_choice[:gate_passed],
        polarity_ratio_gain: polarity_choice[:ratio_gain],
        polarity_delta_gain: polarity_choice[:delta_gain],
        polarity_score_gain: polarity_choice[:score_gain],
        ecc_scheme: (::MediaGallery::Fingerprinting.respond_to?(:ecc_profile) ? ::MediaGallery::Fingerprinting.ecc_profile[:scheme] : "none"),
        ecc_groups_used: chosen_samples.length,
        candidate_population_count: fps.length,
        candidate_prefilter_used: prefilter_info[:used],
        candidate_prefilter_limit: prefilter_info[:limit],
        candidate_prefilter_kept: prefilter_info[:kept],
        candidate_prefilter_cutoff_weighted_ratio: prefilter_info[:cutoff_weighted_ratio],
        adaptive_weighting_used: true,
        adaptive_effective_samples: adaptive_effective,
        adaptive_high_quality_support_ratio: adaptive_high_quality_support_ratio.round(4),
        adaptive_filled_segment_ratio: adaptive_filled_segment_ratio.round(4),
      }

      if best_diag
        meta[:offset_top_match_ratio] = best_diag[:top_ratio_w].round(4)
        meta[:offset_second_match_ratio] = best_diag[:second_ratio_w].round(4)
        meta[:offset_delta] = best_diag[:delta].round(4)
        meta[:offset_coverage] = best_diag[:coverage].round(4) if best_diag[:coverage]
      end

      other_score = polarity_best_scores[!chosen_polarity_flip]
      if other_score && other_score.finite? && best_score && best_score.finite?
        meta[:polarity_score_delta] = (best_score - other_score).round(4)
      end

      annotate_candidate_debugs!(candidates: candidates, observed_variants: chosen_obs, observed_segment_indices: seg_indices, media_item_id: media_item.id)
      apply_shortlist_meta!(meta: meta, candidates: candidates)
      apply_top_candidate_debug_to_meta!(meta: meta, candidates: candidates)

      { candidates: candidates, meta: meta }
    end

    def best_local_offset(rec:, samples:, max_off:, media_item_id:)
      best = { offset: 0, mism_w: nil, comp_w: 0.0, match_ratio: 0.0 }

      (0..max_off).each do |offset|
        mism_w = 0.0
        comp_w = 0.0

        samples.each do |(_obs_idx, base_seg_idx, ov, w, _c)|
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: rec.fingerprint_id,
            media_item_id: media_item_id,
            segment_index: base_seg_idx.to_i + offset
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

    def robust_pair_channel_metrics(diffs)
      arr = Array(diffs).map { |v| v.to_f }
      return { score: 0.0, confidence: 0.0, consensus: 0.0, strength: 0.0, kept_count: 0 } if arr.empty?

      abs_vals = arr.map(&:abs)
      med_abs = median(abs_vals).to_f
      mean_abs = (abs_vals.sum.to_f / [abs_vals.length, 1].max.to_f)
      strong_floor = [med_abs * 0.60, mean_abs * 0.45, 2.0].max
      kept = arr.select { |d| d.abs >= strong_floor }
      min_keep = [[(arr.length * 0.5).ceil, 3].max, arr.length].min
      if kept.length < min_keep
        kept = arr.sort_by { |d| d.abs }.last(min_keep)
      end
      kept = arr if kept.blank?

      pos_w = kept.select { |d| d >= 0.0 }.sum { |d| d.abs }
      neg_w = kept.select { |d| d < 0.0 }.sum { |d| d.abs }
      total_w = pos_w + neg_w
      total_w = 1.0 if total_w <= 0.0

      consensus = (pos_w - neg_w) / total_w
      vote_margin = ((kept.count { |d| d >= 0.0 } - kept.count { |d| d < 0.0 }).abs.to_f / [kept.length, 1].max.to_f)
      strength = median(kept.map { |d| d.abs }).to_f
      conf = ((strength / 255.0) * (0.45 + (consensus.abs * 0.35) + (vote_margin * 0.20))).round(4)
      score = (consensus * strength * kept.length.to_f).round(4)

      {
        score: score,
        confidence: conf,
        consensus: consensus.to_f.round(4),
        strength: strength.to_f.round(4),
        kept_count: kept.length,
      }
    rescue
      { score: 0.0, confidence: 0.0, consensus: 0.0, strength: 0.0, kept_count: 0 }
    end
    private_class_method :robust_pair_channel_metrics

    def pair_analysis_config(spec:, box:)
      analysis = spec.is_a?(Hash) && spec[:analysis].is_a?(Hash) ? spec[:analysis] : {}
      mode = analysis[:mode].to_s
      if mode == "templated_pair_grid_v1" || mode == "templated_pair_grid_v2"
        {
          mode: mode,
          sample_grid_w: [analysis[:sample_grid_w].to_i, 4].max,
          sample_grid_h: [analysis[:sample_grid_h].to_i, 3].max,
          template_grid_w: [analysis[:template_grid_w].to_i, 2].max,
          template_grid_h: [analysis[:template_grid_h].to_i, 2].max,
          pad_frac: [[analysis[:pad_frac].to_f, 0.0].max, 0.35].min,
          template_variants: Array(analysis[:template_variants]),
          legacy_template_variants: Array(analysis[:legacy_template_variants]),
          score_mode: analysis[:score_mode].to_s,
        }
      else
        {
          mode: "pair_avg_2x1",
          sample_grid_w: 2,
          sample_grid_h: 1,
          template_grid_w: 2,
          template_grid_h: 1,
          pad_frac: 0.0,
          template_variants: [],
          score_mode: "",
        }
      end
    rescue
      {
        mode: "pair_avg_2x1",
        sample_grid_w: 2,
        sample_grid_h: 1,
        template_grid_w: 2,
        template_grid_h: 1,
        pad_frac: 0.0,
        template_variants: [],
        score_mode: "",
      }
    end
    private_class_method :pair_analysis_config

    def template_cells_for_pair(pair:, config:, variants_key: :template_variants)
      variants = Array(config[variants_key]).select { |entry| entry.is_a?(Array) }
      positives = if variants.present?
        idx = pair.is_a?(Hash) ? pair[:template_variant].to_i : 0
        Array(variants[idx % variants.length]).map { |cell| [Array(cell)[0].to_i, Array(cell)[1].to_i] }
      else
        [[0, 0], [0, config[:template_grid_h].to_i - 1]]
      end
      width = [config[:template_grid_w].to_i, 2].max
      negatives = positives.map { |x, y| [(width - 1) - x.to_i, y.to_i] }
      { positive: positives, negative: negatives }
    rescue
      { positive: [[0, 0]], negative: [[1, 0]] }
    end
    private_class_method :template_cells_for_pair

    def template_cell_sets_for_pair(pair:, config:)
      sets = []
      primary = template_cells_for_pair(pair: pair, config: config, variants_key: :template_variants)
      sets << primary if primary[:positive].present? && primary[:negative].present?

      legacy_variants = Array(config[:legacy_template_variants]).select { |entry| entry.is_a?(Array) }
      if legacy_variants.present?
        legacy = template_cells_for_pair(pair: pair, config: config, variants_key: :legacy_template_variants)
        duplicate = sets.any? do |entry|
          entry[:positive] == legacy[:positive] && entry[:negative] == legacy[:negative]
        end
        sets << legacy unless duplicate
      end

      sets = [{ positive: [[0, 0]], negative: [[1, 0]] }] if sets.blank?
      sets
    rescue
      [{ positive: [[0, 0]], negative: [[1, 0]] }]
    end
    private_class_method :template_cell_sets_for_pair

    def connected_template_groups(cells)
      coords = Array(cells).map { |cell| [Array(cell)[0].to_i, Array(cell)[1].to_i] }.uniq
      return [] if coords.blank?

      remaining = coords.each_with_object({}) { |coord, memo| memo[coord] = true }
      groups = []

      until remaining.empty?
        seed = remaining.keys.first
        queue = [seed]
        remaining.delete(seed)
        group = []

        until queue.empty?
          x, y = queue.shift
          group << [x, y]
          [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
            neighbor = [x + dx, y + dy]
            next unless remaining.delete(neighbor)
            queue << neighbor
          end
        end

        groups << group
      end

      groups
    rescue
      []
    end
    private_class_method :connected_template_groups

    def pair_score_from_grid(chunk:, config:, pair:)
      gw = [config[:sample_grid_w].to_i, 1].max
      gh = [config[:sample_grid_h].to_i, 1].max
      needed = gw * gh
      return 0.0 if chunk.nil? || chunk.length < needed

      if config[:mode].to_s != "templated_pair_grid_v1" && config[:mode].to_s != "templated_pair_grid_v2"
        return chunk[0].to_f - chunk[1].to_f
      end

      tw = [[config[:template_grid_w].to_i, 1].max, gw].min
      th = [[config[:template_grid_h].to_i, 1].max, gh].min
      max_x = [gw - tw, 0].max
      max_y = [gh - th, 0].max
      cell_sets = template_cell_sets_for_pair(pair: pair, config: config)
      score_mode = config[:score_mode].to_s
      candidate_scores = []
      center_ox = max_x / 2.0
      center_oy = max_y / 2.0

      (0..max_y).each do |oy|
        (0..max_x).each do |ox|
          vals = []
          th.times do |yy|
            row = ((oy + yy) * gw) + ox
            tw.times do |xx|
              vals << chunk[row + xx].to_f
            end
          end
          next if vals.empty?

          local_mean = vals.sum.to_f / vals.length.to_f
          local_var = vals.sum { |v| (v - local_mean) ** 2 } / vals.length.to_f
          local_std = Math.sqrt(local_var)
          local_std = 1.0 if local_std < 1.0

          if score_mode == "bar_consensus_zscore"
            z_for = lambda do |cx, cy|
              idx = ((oy + cy.to_i) * gw) + ox + cx.to_i
              (chunk[idx].to_f - local_mean) / local_std
            end

            center_dx = center_ox.positive? ? ((ox - center_ox).abs / center_ox) : 0.0
            center_dy = center_oy.positive? ? ((oy - center_oy).abs / center_oy) : 0.0
            center_penalty = 1.0 - ([center_dx, 1.0].min * 0.10) - ([center_dy, 1.0].min * 0.08)
            center_penalty = 0.74 if center_penalty < 0.74
            contrast_bonus = [[local_std / 16.0, 1.0].min, 0.55].max

            cell_sets.each do |cells|
              pos_groups = connected_template_groups(cells[:positive])
              neg_groups = connected_template_groups(cells[:negative])
              pos_groups = [Array(cells[:positive])] if pos_groups.blank?
              neg_groups = [Array(cells[:negative])] if neg_groups.blank?

              pos_scores = pos_groups.map do |group|
                group.sum { |cx, cy| z_for.call(cx, cy) } / [group.length, 1].max.to_f
              end
              neg_scores = neg_groups.map do |group|
                group.sum { |cx, cy| z_for.call(cx, cy) } / [group.length, 1].max.to_f
              end

              raw_sum = pos_scores.sum.to_f - neg_scores.sum.to_f
              pos_median = median(pos_scores).to_f
              neg_median = median(neg_scores).to_f
              support_hits = pos_scores.count { |s| s.positive? } + neg_scores.count { |s| s.negative? }
              support = support_hits.to_f / [pos_scores.length + neg_scores.length, 1].max.to_f
              worst_guard = [pos_scores.min.to_f, (-neg_scores.max.to_f)].min
              worst_guard = 0.0 if worst_guard.negative?
              structure_score = (raw_sum * 0.60) + ((pos_median - neg_median) * 0.95) + (worst_guard * 0.45)
              support_bonus = 0.62 + (support * 0.46)
              weighted = structure_score * center_penalty * contrast_bonus * support_bonus
              candidate_scores << {
                weighted: weighted.to_f,
                raw: structure_score.to_f,
                std: local_std.to_f,
                support: support.to_f,
              }
            end
          else
            cell_sets.each do |cells|
              score = 0.0
              if score_mode == "center_biased_zscore"
                cells[:positive].each do |cx, cy|
                  idx = ((oy + cy.to_i) * gw) + ox + cx.to_i
                  score += ((chunk[idx].to_f - local_mean) / local_std)
                end
                cells[:negative].each do |cx, cy|
                  idx = ((oy + cy.to_i) * gw) + ox + cx.to_i
                  score -= ((chunk[idx].to_f - local_mean) / local_std)
                end
                center_dx = center_ox.positive? ? ((ox - center_ox).abs / center_ox) : 0.0
                center_dy = center_oy.positive? ? ((oy - center_oy).abs / center_oy) : 0.0
                center_penalty = 1.0 - ([center_dx, 1.0].min * 0.12) - ([center_dy, 1.0].min * 0.10)
                center_penalty = 0.70 if center_penalty < 0.70
                contrast_bonus = [[local_std / 18.0, 1.0].min, 0.35].max
                weighted = score * center_penalty * contrast_bonus
                candidate_scores << { weighted: weighted.to_f, raw: score.to_f, std: local_std.to_f, support: 0.5 }
              else
                cells[:positive].each do |cx, cy|
                  score += (chunk[((oy + cy.to_i) * gw) + ox + cx.to_i].to_f - local_mean)
                end
                cells[:negative].each do |cx, cy|
                  score -= (chunk[((oy + cy.to_i) * gw) + ox + cx.to_i].to_f - local_mean)
                end
                candidate_scores << { weighted: score.to_f, raw: score.to_f, std: local_std.to_f, support: 0.5 }
              end
            end
          end
        end
      end

      return 0.0 if candidate_scores.empty?
      best = candidate_scores.max_by { |entry| entry[:weighted].to_f.abs }
      best_abs = best[:weighted].to_f.abs
      alt_abs = candidate_scores.reject { |entry| entry.equal?(best) }.map { |entry| entry[:weighted].to_f.abs }.max.to_f
      separation = best_abs > 0.0 ? ((best_abs - alt_abs) / best_abs) : 0.0
      separation = 0.0 if separation.negative?
      reliability = 0.58 + ([separation, 1.0].min * 0.72)
      if score_mode == "center_biased_zscore"
        reliability *= [[best[:std].to_f / 14.0, 1.0].min, 0.55].max
      elsif score_mode == "bar_consensus_zscore"
        reliability *= [[best[:std].to_f / 13.0, 1.0].min, 0.60].max
        reliability *= (0.70 + (best[:support].to_f * 0.45))
      end
      (best[:raw].to_f * reliability).round(4)
    rescue
      0.0
    end
    private_class_method :pair_score_from_grid

    def decode_pair_frame_bytes(bytes:, main_pair_count:, pairs:, spec:, box:)
      pair_list = Array(pairs)
      total = pair_list.length
      total = 0 if total.negative?
      main_count = main_pair_count.to_i
      main_count = 0 if main_count.negative?
      main_count = [main_count, total].min
      config = pair_analysis_config(spec: spec, box: box)
      bytes_per_pair = [config[:sample_grid_w].to_i, 1].max * [config[:sample_grid_h].to_i, 1].max

      main_diffs = []
      sync_diffs = []
      total.times do |i|
        start = i * bytes_per_pair
        chunk = bytes[start, bytes_per_pair]
        diff = pair_score_from_grid(chunk: chunk, config: config, pair: pair_list[i])
        if i < main_count
          main_diffs << diff
        else
          sync_diffs << diff
        end
      end

      main_metrics = robust_pair_channel_metrics(main_diffs)
      sync_metrics = robust_pair_channel_metrics(sync_diffs)

      payload_score = main_metrics[:score].to_f
      payload_variant = payload_score >= 0.0 ? "a" : "b"
      payload_confidence = main_metrics[:confidence].to_f
      payload_confidence += [sync_metrics[:confidence].to_f * 0.05, 0.025].min if sync_diffs.present? && main_metrics[:strength].to_f > 0.0
      payload_confidence = [payload_confidence, 1.0].min.round(4)

      sync_score = sync_metrics[:score].to_f
      sync_variant = nil
      if sync_diffs.present? && sync_metrics[:strength].to_f > 0.0
        sync_variant = sync_score >= 0.0 ? "a" : "b"
        sync_variant = nil if sync_metrics[:confidence].to_f < MIN_CONFIDENCE
      end

      {
        variant: payload_variant,
        confidence: payload_confidence,
        score: payload_score.round(4),
        payload_score: payload_score.round(4),
        payload_confidence: payload_confidence,
        sync_score: sync_score.round(4),
        sync_confidence: sync_metrics[:confidence].to_f.round(4),
        sync_variant: sync_variant,
        main_consensus: main_metrics[:consensus],
        sync_consensus: sync_metrics[:consensus],
      }
    rescue
      { variant: nil, confidence: 0.0, score: 0.0, payload_score: 0.0, payload_confidence: 0.0, sync_score: 0.0, sync_confidence: 0.0, sync_variant: nil, main_consensus: 0.0, sync_consensus: 0.0 }
    end
    private_class_method :decode_pair_frame_bytes

    # --------------------- batch sampling ---------------------------------

    # Returns an Array of numeric scores (one per time). Does not apply confidence gating.
    def sample_scores_batch_single(file_path:, times:, spec:)
      times = Array(times).map { |t| t.to_f }.select { |t| t >= 0.0 }
      return [] if times.empty?

      kind = spec[:kind].to_s
      kind = "pairs" if kind.blank? && spec[:pairs].present?
      kind = "tiles" if kind.blank? && spec[:tiles].present?

      if kind == "pairs"
        main_pairs = Array(spec[:pairs])
        pairs = analysis_pairs_for_spec(spec)
        box = spec[:box_size_frac].to_f
        box = 0.12 if box <= 0
        pair_filter = build_pair_filter(in_label: nil, pairs: pairs, box: box, spec: spec)
        expected = pair_filter[:expected_bytes]

        raw = ffmpeg_sample_raw_multi(
          file_path: file_path,
          times: times,
          expected_bytes_per_frame: expected,
          filter_builder: lambda { |in_label| build_pair_filter(in_label: in_label, pairs: pairs, box: box, spec: spec) }
        )

        out = []
        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          decoded = decode_pair_frame_bytes(bytes: bytes, main_pair_count: main_pairs.length, pairs: pairs, spec: spec, box: box)
          out << decoded[:payload_score].to_f
          { variant: nil, confidence: decoded[:payload_confidence].to_f, score: decoded[:payload_score].to_f }
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
        main_pairs = Array(spec[:pairs])
        pairs = analysis_pairs_for_spec(spec)
        box = spec[:box_size_frac].to_f
        box = 0.12 if box <= 0
        pair_filter = build_pair_filter(in_label: nil, pairs: pairs, box: box, spec: spec)
        expected = pair_filter[:expected_bytes]

        raw = ffmpeg_sample_raw_multi(
          file_path: file_path,
          times: times,
          expected_bytes_per_frame: expected,
          filter_builder: lambda { |in_label| build_pair_filter(in_label: in_label, pairs: pairs, box: box, spec: spec) }
        )

        parse_batch_bytes(raw: raw, expected_bytes_per_frame: expected, times: times) do |bytes|
          decoded = decode_pair_frame_bytes(bytes: bytes, main_pair_count: main_pairs.length, pairs: pairs, spec: spec, box: box)
          variant = decoded[:variant]
          variant = nil if decoded[:payload_confidence].to_f < MIN_CONFIDENCE
          {
            variant: variant,
            confidence: decoded[:payload_confidence].to_f,
            score: decoded[:payload_score].to_f,
            sync_score: decoded[:sync_score].to_f,
            sync_confidence: decoded[:sync_confidence].to_f,
            sync_variant: decoded[:sync_variant]
          }
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

    def build_pair_filter(in_label:, pairs:, box:, spec:)
      pair_count = pairs.length
      return { filter: "null[out]", expected_bytes: 0 } if pair_count == 0

      config = pair_analysis_config(spec: spec, box: box)
      sample_w = [config[:sample_grid_w].to_i, 1].max
      sample_h = [config[:sample_grid_h].to_i, 1].max
      pad_frac = config[:pad_frac].to_f
      pair_w = (box.to_f * 2.0).round(6)
      pad_x = (box.to_f * pad_frac).round(6)
      pad_y = (box.to_f * pad_frac).round(6)
      crop_w = (pair_w + (pad_x * 2.0)).round(6)
      crop_h = (box.to_f + (pad_y * 2.0)).round(6)
      filters = []
      label = in_label.presence || "[0:v]"

      pairs.each_with_index do |p, idx|
        x = p[:x].to_f
        y = p[:y].to_f
        cx = [[x - pad_x, 0.0].max, 1.0 - crop_w].min.round(6)
        cy = [[y - pad_y, 0.0].max, 1.0 - crop_h].min.round(6)
        filters << "#{label}crop=w=iw*#{crop_w}:h=ih*#{crop_h}:x=iw*#{cx}:y=ih*#{cy},scale=#{sample_w}:#{sample_h}:flags=area[p#{idx}]"
      end
      stack_inputs = (0...pair_count).map { |i| "[p#{i}]" }.join
      filters << "#{stack_inputs}hstack=inputs=#{pair_count}[out]"
      { filter: filters.join(";"), expected_bytes: pair_count * sample_w * sample_h }
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

    
    def expected_sync_variant_for_segment(segment_index:, spec:)
      pattern = Array(spec.is_a?(Hash) ? spec[:sync_pattern] : nil).map { |v| v.to_s }
      return nil if pattern.blank?
      idx = segment_index.to_i
      idx = 0 if idx.negative?
      variant = pattern[idx % pattern.length]
      return nil unless %w[a b].include?(variant)
      variant
    rescue
      nil
    end
    private_class_method :expected_sync_variant_for_segment

    def build_sync_offset_prior(sync_variants:, sync_confidences:, observed_segment_indices:, spec:, max_offset_segments:)
      pattern = Array(spec.is_a?(Hash) ? spec[:sync_pattern] : nil)
      return nil if pattern.blank?

      seg_indices = Array(observed_segment_indices)
      obs = Array(sync_variants)
      confs = Array(sync_confidences)
      return nil if obs.blank?

      by_offset = []
      (0..max_offset_segments.to_i).each do |offset|
        agree = 0.0
        disagree = 0.0
        obs.each_with_index do |v, i|
          next if v.blank?
          conf = confs[i].to_f
          next if conf <= 0.0
          base_seg_idx = seg_indices[i].present? ? seg_indices[i].to_i : i
          exp = expected_sync_variant_for_segment(segment_index: base_seg_idx + offset, spec: spec)
          next if exp.blank?
          if exp == v.to_s
            agree += conf
          else
            disagree += conf
          end
        end
        total = agree + disagree
        ratio = total > 0.0 ? (agree / total) : 0.0
        by_offset << { offset: offset, ratio: ratio, total: total }
      end

      usable = by_offset.select { |e| e[:total].to_f > 0.0 }
      return nil if usable.blank?
      sorted = usable.sort_by { |e| [-e[:ratio].to_f, -e[:total].to_f, e[:offset].to_i] }
      top = sorted[0]
      second = sorted[1]
      delta = top[:ratio].to_f - second.to_h[:ratio].to_f
      trust = [[delta * 1.8, 0.0].max, 0.65].min
      {
        best_offset: top[:offset].to_i,
        best_ratio: top[:ratio].to_f,
        second_ratio: second.to_h[:ratio].to_f,
        delta: delta.to_f,
        trust: trust.to_f.round(4),
      }
    rescue
      nil
    end
    private_class_method :build_sync_offset_prior

    def match_fingerprints_with_reference(fps:, media_item:, scores:, confidences:, observed_segment_indices:, sync_variants: nil, sync_confidences: nil, spec: nil, ref_thr:, ref_delta:, delta_median:, max_offset_segments:, started_at: nil, time_budget_seconds: nil)
  ::MediaGallery::Fingerprinting.with_expected_variant_cache do
  max_off = max_offset_segments.to_i
  max_off = 0 if max_off.negative?

  delta_med = delta_median.to_f
  delta_med = 1.0 if delta_med <= 0.0

  # Require a minimum A/B separation.
  min_delta = [delta_med * 0.10, 6.0].max

  # Robustly scale leak confidence (do not square; confidences are small by design).
  conf_list = Array(confidences).map { |c| c.to_f }.select { |c| c > 0.0 && !c.nan? && !c.infinite? }
  seg_indices = Array(observed_segment_indices)
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

  usable_cache = {}

  build_usable = lambda do |offset, polarity_flip = false|
    cache_key = [offset.to_i, polarity_flip ? 1 : 0]
    if usable_cache.key?(cache_key)
      return usable_cache[cache_key]
    end

    usable = []
    ratios = []
    margins = []
    comp_w = 0.0

    scores.each_with_index do |s, i|
      base_seg_idx = seg_indices[i].present? ? seg_indices[i].to_i : i
      j = base_seg_idx + offset
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

      v = invert_variant(v) if polarity_flip

      ratio = d_cl / (sep + eps)
      margin = (d_ot - d_cl) / (sep + eps)

      next if margin < 0.05

      w = margin * leak_scale[i]
      next if w <= 0.0 || w.nan? || w.infinite?

      usable << [i, base_seg_idx, v, w, margin, ratio]
      comp_w += w
      ratios << ratio
      margins << margin
    end

    usable_cache[cache_key] = ecc_grouped_reference_usable(usable: usable, offset: offset).merge(
      raw_usable_count: usable.length,
      raw_comp_w: comp_w.to_f
    )
  end

  sync_prior = build_sync_offset_prior(
    sync_variants: sync_variants,
    sync_confidences: sync_confidences,
    observed_segment_indices: seg_indices,
    spec: spec,
    max_offset_segments: max_off
  )

  best_offset = 0
  best_polarity_flip = false
  best_score = nil
  best_diag = nil
  polarity_best_scores = { false => -Float::INFINITY, true => -Float::INFINITY }
  best_by_polarity = {}

  [false, true].each do |polarity_flip|
    (0..max_off).each do |offset|
      u = build_usable.call(offset, polarity_flip)
      next if u[:usable].empty? || u[:comp_w] <= 0.0

      top = nil
      second = nil

      fps.each do |rec|
        mism_w = 0.0
        u[:usable].each do |(_obs_idx, base_seg_idx, ov, w, _m, _r, _seg_idx, _raw_count)|
          exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: rec.fingerprint_id,
            media_item_id: media_item.id,
            segment_index: base_seg_idx.to_i + offset
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

      sync_anchor_bonus = 0.0
      if sync_prior.present? && sync_prior[:trust].to_f > 0.0
        dist = (offset.to_i - sync_prior[:best_offset].to_i).abs
        local = [1.0 - (dist.to_f / 6.0), 0.0].max
        sync_anchor_bonus = local * (0.035 + (sync_prior[:delta].to_f * 0.08)) * sync_prior[:trust].to_f
      end

      score = delta + (top[:ratio_w].to_f * 0.03) + (u[:median_margin].to_f * 0.02) + sync_anchor_bonus - (offset.to_f * 0.0002) - (polarity_flip ? 0.0025 : 0.0)
      polarity_best_scores[polarity_flip] = score if score > polarity_best_scores[polarity_flip]

      current_best = best_by_polarity[polarity_flip]
      if current_best.nil? || score > current_best[:score] ||
           (score == current_best[:score] && top[:ratio_w].to_f > current_best.dig(:diag, :top_ratio_w).to_f)
        best_by_polarity[polarity_flip] = {
          score: score,
          offset: offset,
          flip: polarity_flip,
          diag: {
            top_ratio_w: top[:ratio_w].to_f,
            second_ratio_w: second_ratio,
            delta: delta,
            comp_w: u[:comp_w],
            usable_count: u[:usable_count],
            median_ratio: u[:median_ratio],
            median_margin: u[:median_margin],
            raw_usable_count: u[:raw_usable_count],
            raw_comp_w: u[:raw_comp_w]
          }
        }
      end
    end
  end

  polarity_choice = select_polarity_result(
    normal_result: best_by_polarity[false],
    inverted_result: best_by_polarity[true]
  )
  chosen_result = polarity_choice[:chosen] || best_by_polarity[false] || best_by_polarity[true]

  if chosen_result.present?
    best_score = chosen_result[:score]
    best_offset = chosen_result[:offset].to_i
    best_polarity_flip = chosen_result[:flip] ? true : false
    best_diag = chosen_result[:diag] || {}
  end

  u = build_usable.call(best_offset, best_polarity_flip)
  reference_adaptive = annotate_reference_usable_with_adaptive(usable: u[:usable])
  scored_reference_usable = reference_adaptive[:usable]
  adaptive_total_weight = reference_adaptive[:adaptive_total_weight].to_f
  high_quality_weight = reference_adaptive[:high_quality_weight].to_f
  anchor_trust = reference_anchor_trust(
    top_ratio: (best_diag ? best_diag[:top_ratio_w].to_f : 0.0),
    delta: (best_diag ? best_diag[:delta].to_f : 0.0),
    median_ratio: (best_diag ? best_diag[:median_ratio].to_f : 0.0),
    median_margin: (best_diag ? best_diag[:median_margin].to_f : 0.0),
    usable_count: u[:usable_count].to_i,
    budget_exhausted: false
  )

  chunked = nil
  if chunked_resync_should_run?(scores_length: scores.length, global_usable_count: u[:usable_count].to_i)
    chunked = build_chunked_reference_result(
      fps: fps,
      media_item: media_item,
      scores_length: scores.length,
      max_off: max_off,
      polarity_flip: best_polarity_flip,
      build_usable: build_usable,
      observed_segment_indices: seg_indices
    )
  end

  use_chunked = false
  if chunked.present?
    global_score = chunked_resync_score(
      top_ratio: (best_diag ? best_diag[:top_ratio_w].to_f : 0.0),
      second_ratio: (best_diag ? best_diag[:second_ratio_w].to_f : 0.0),
      usable_count: u[:usable_count].to_i,
      median_margin: (best_diag ? best_diag[:median_margin].to_f : 0.0)
    )
    chunked_score = chunked[:score].to_f
    global_top = (best_diag ? best_diag[:top_ratio_w].to_f : 0.0)
    chunked_top = chunked.dig(:meta, :offset_top_match_ratio).to_f
    global_delta = (best_diag ? best_diag[:delta].to_f : 0.0)
    chunked_delta = chunked.dig(:meta, :offset_delta).to_f

    use_chunked =
      chunked_score >= (global_score + 0.01) ||
      (chunked_top >= (global_top - 0.01) && chunked_delta >= (global_delta + 0.05))
  end

  if use_chunked
    candidates = Array(chunked[:candidates]).first(10)
    ref_obs = chunked.dig(:meta, :reference_observed_variants) || Array.new(scores.length)
    ref_conf = chunked.dig(:meta, :reference_observed_confidences) || Array.new(scores.length, 0.0)
  else
    # Build reference-derived observed variants/confidences first so evidence scoring
    # can use the same calibrated sequence that is shown in the admin UI.
    ref_obs = Array.new(scores.length)
    ref_conf = Array.new(scores.length, 0.0)
    u[:usable].each do |(obs_idx, _base_seg_idx, ov, _w, margin, ratio, _seg_idx, _raw_count)|
      ref_obs[obs_idx] = ov
      c = margin.to_f
      c *= 0.5 if ratio.to_f > 1.0
      ref_conf[obs_idx] = c.round(4)
    end

    candidates = []
    fps.each do |rec|
      mism_w = 0.0
      mism = 0
      comp = 0

      mism_aw = 0.0
      comp_aw = 0.0
      high_q_mismatches = 0
      high_q_compared = 0
      high_q_mismatches_w = 0.0
      high_q_compared_w = 0.0

      scored_reference_usable.each do |(_obs_idx, base_seg_idx, ov, w, _m, _r, _seg_idx, _raw_count, adaptive_w, adaptive_factor)|
        exp = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: rec.fingerprint_id,
          media_item_id: media_item.id,
          segment_index: base_seg_idx.to_i + best_offset
        )
        comp += 1
        comp_aw += adaptive_w.to_f
        if adaptive_factor.to_f >= reference_adaptive[:high_quality_factor_threshold].to_f
          high_q_compared += 1
          high_q_compared_w += adaptive_w.to_f
        end
        if exp != ov
          mism += 1
          mism_w += w
          mism_aw += adaptive_w.to_f
          if adaptive_factor.to_f >= reference_adaptive[:high_quality_factor_threshold].to_f
            high_q_mismatches += 1
            high_q_mismatches_w += adaptive_w.to_f
          end
        end
      end

      next if comp == 0 || u[:comp_w] <= 0.0

      raw_ratio = 1.0 - (mism.to_f / comp.to_f)
      weighted_ratio = 1.0 - (mism_w / u[:comp_w])
      adaptive_ratio = comp_aw > 0.0 ? (1.0 - (mism_aw / comp_aw)) : weighted_ratio
      high_q_ratio = high_q_compared > 0 ? (1.0 - (high_q_mismatches.to_f / high_q_compared.to_f)) : raw_ratio
      high_q_weighted_ratio = high_q_compared_w > 0.0 ? (1.0 - (high_q_mismatches_w / high_q_compared_w)) : high_q_ratio

      candidates << {
        user_id: rec.user_id,
        username: rec.user&.username,
        fingerprint_id: rec.fingerprint_id,
        best_offset_segments: best_offset,
        mismatches: mism,
        compared: comp,
        mismatches_weighted: mism_w.round(6),
        compared_weighted: u[:comp_w].round(6),
        mismatches_adaptive_weighted: mism_aw.round(6),
        compared_adaptive_weighted: comp_aw.round(6),
        match_ratio: raw_ratio.round(4),
        match_ratio_weighted: weighted_ratio.round(4),
        match_ratio_adaptive_weighted: adaptive_ratio.round(4),
        high_quality_matches: [high_q_compared - high_q_mismatches, 0].max,
        high_quality_compared: high_q_compared,
        high_quality_match_ratio: high_q_ratio.round(4),
        high_quality_compared_weighted: high_q_compared_w.round(6),
        high_quality_match_ratio_weighted: high_q_weighted_ratio.round(4),
        local_best_offset_segments: best_offset,
        local_match_ratio: weighted_ratio.round(4),
        polarity_flip_used: best_polarity_flip,
        variant_polarity: (best_polarity_flip ? "inverted" : "normal"),
      }
    end

    candidates.sort_by! { |candidate| candidate_prefilter_sort_tuple(candidate) }
  end

  prefilter_info = if use_chunked
    {
      candidates: Array(candidates),
      used: (fps.length > Array(candidates).length),
      total: fps.length,
      kept: Array(candidates).length,
      limit: Array(candidates).length,
      cutoff_weighted_ratio: (Array(candidates).last ? (Array(candidates).last[:match_ratio_weighted] || Array(candidates).last["match_ratio_weighted"]).to_f.round(4) : 0.0),
    }
  else
    apply_shortlist_prefilter(
      candidates: candidates,
      observed_count: u[:usable_count].to_i
    )
  end
  candidates = prefilter_info[:candidates]

  local_evidence_radius = candidate_local_offset_radius(
    max_off: max_off,
    observed_count: u[:usable_count].to_i
  )
  shortlist_verification_used = false
  shortlist_verification_reason = if use_chunked
    "skipped_for_chunked_reference"
  elsif candidates.blank?
    "no_candidates"
  elsif local_evidence_radius <= 0
    "local_offset_radius_zero"
  else
    previous_top_user_id = candidates.first&.dig(:user_id)
    verify_shortlist_candidates_with_local_offsets!(
      candidates: candidates,
      media_item: media_item,
      build_usable: build_usable,
      polarity_flip: best_polarity_flip,
      max_off: max_off,
      shortlist_limit: SHORTLIST_VERIFY_LIMIT,
      anchor_trust: anchor_trust,
      polarity_score_delta: polarity_choice[:score_gain],
      polarity_gate_passed: polarity_choice[:gate_passed]
    )
    shortlist_verification_used = true
    new_top_user_id = candidates.first&.dig(:user_id)
    previous_top_user_id == new_top_user_id ? "candidate_specific_offset_verification_applied" : "top_candidate_changed_after_local_verification"
  end

  enrich_candidates_with_evidence!(
    candidates: candidates,
    observed_variants: ref_obs,
    observed_confidences: ref_conf,
    observed_segment_indices: seg_indices,
    media_item_id: media_item.id,
    local_offset_radius: (use_chunked ? 0 : local_evidence_radius),
    offset_floor: 0,
    offset_ceil: max_off,
    anchor_offset: best_offset,
    anchor_trust: (use_chunked ? 0.0 : anchor_trust),
    observed_polarity_flip: best_polarity_flip,
    layout: v8_layout_name(spec&.dig(:layout) || spec&.[](:layout))
  )

  pairwise_chunk_decoder = if use_chunked
    { used: false, reason: "skipped_for_chunked_reference" }
  else
    apply_pairwise_chunk_decoder!(
      candidates: candidates,
      observed_variants: ref_obs,
      observed_confidences: ref_conf,
      observed_segment_indices: seg_indices,
      media_item_id: media_item.id,
      max_off: max_off,
      anchor_offset: best_offset,
      anchor_trust: anchor_trust,
      observed_polarity_flip: best_polarity_flip,
      started_at: started_at,
      budget_seconds: time_budget_seconds,
      layout: v8_layout_name(spec&.dig(:layout) || spec&.[](:layout))
    )
  end

  discriminative_shortlist_decoder = if use_chunked
    { used: false, reason: "skipped_for_chunked_reference" }
  else
    apply_discriminative_shortlist_decoder!(
      candidates: candidates,
      observed_variants: ref_obs,
      observed_confidences: ref_conf,
      observed_segment_indices: seg_indices,
      media_item_id: media_item.id,
      observed_polarity_flip: best_polarity_flip,
      started_at: started_at,
      budget_seconds: time_budget_seconds,
      layout: v8_layout_name(spec&.dig(:layout) || spec&.[](:layout))
    )
  end

  top = candidates[0]
  second = candidates[1]

  observed_indices_used = Array.new(scores.length)
  u[:usable].each do |(obs_idx, base_seg_idx, _ov, _w, _margin, _ratio, _seg_idx, _raw_count)|
    next if obs_idx.blank?
    observed_indices_used[obs_idx.to_i] = base_seg_idx.to_i
  end

  adaptive_support_ratio = adaptive_total_weight > 0.0 ? (high_quality_weight / adaptive_total_weight) : 0.0
  adaptive_effective = u[:usable_count].to_f
  if u[:comp_w].to_f > 0.0
    adaptive_effective *= (adaptive_total_weight / u[:comp_w].to_f)
  end

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
    reference_observed_confidences: ref_conf,
    polarity_flip_used: best_polarity_flip,
    variant_polarity: (best_polarity_flip ? "inverted" : "normal"),
    polarity_selection_strategy: "prefer_normal_unless_inverted_clearly_better",
    polarity_gate_passed: polarity_choice[:gate_passed],
    polarity_ratio_gain: polarity_choice[:ratio_gain],
    polarity_delta_gain: polarity_choice[:delta_gain],
    polarity_score_gain: polarity_choice[:score_gain],
    ecc_scheme: (::MediaGallery::Fingerprinting.respond_to?(:ecc_profile) ? ::MediaGallery::Fingerprinting.ecc_profile[:scheme] : "none"),
    ecc_groups_used: u[:usable_count],
    ecc_raw_usable_samples: u[:raw_usable_count],
    reference_anchor_trust: anchor_trust.round(4),
    sync_anchor_used: sync_prior.present?,
    sync_anchor_offset_segments: sync_prior.to_h[:best_offset],
    sync_anchor_best_ratio: sync_prior.to_h[:best_ratio].to_f.round(4),
    sync_anchor_second_ratio: sync_prior.to_h[:second_ratio].to_f.round(4),
    sync_anchor_delta: sync_prior.to_h[:delta].to_f.round(4),
    sync_anchor_trust: sync_prior.to_h[:trust].to_f.round(4),
    observed_segment_indices_used: observed_indices_used,
    candidate_population_count: fps.length,
    candidate_prefilter_used: prefilter_info[:used],
    candidate_prefilter_limit: prefilter_info[:limit],
    candidate_prefilter_kept: prefilter_info[:kept],
    candidate_prefilter_cutoff_weighted_ratio: prefilter_info[:cutoff_weighted_ratio],
    adaptive_weighting_used: true,
    adaptive_effective_samples: adaptive_effective.round(2),
    adaptive_high_quality_support_ratio: adaptive_support_ratio.round(4),
    reference_high_quality_factor_threshold: reference_adaptive[:high_quality_factor_threshold].to_f.round(4),
    reference_adaptive_density_window_segments: reference_adaptive[:density_window_segments].to_i
  }

  unless use_chunked
    meta[:chunked_resync_used] = false
    meta[:chunked_resync_reason] = if !chunked_resync_should_run?(scores_length: scores.length, global_usable_count: u[:usable_count].to_i)
      "not_enough_usable_groups_for_local_resync"
    elsif chunked.blank?
      "chunked_resync_candidate_build_failed"
    else
      "global_alignment_scored_better"
    end
  end

  if use_chunked && chunked.is_a?(Hash)
    meta[:offset_strategy] = "chunked_reference"
    meta[:chosen_offset_segments] = chunked.dig(:meta, :chosen_offset_segments).to_i
    meta[:effective_samples] = chunked.dig(:meta, :effective_samples).to_f.round(2)
    meta[:offset_top_match_ratio] = chunked.dig(:meta, :offset_top_match_ratio).to_f.round(4)
    meta[:offset_second_match_ratio] = chunked.dig(:meta, :offset_second_match_ratio).to_f.round(4)
    meta[:offset_delta] = chunked.dig(:meta, :offset_delta).to_f.round(4)
    meta[:reference_observed_variants] = ref_obs
    meta[:reference_observed_confidences] = ref_conf
    meta[:chunked_resync_used] = true
    meta[:chunked_resync_chunks_used] = chunked.dig(:meta, :chunked_resync_chunks_used)
    meta[:chunked_resync_window_segments] = chunked.dig(:meta, :chunked_resync_window_segments)
    meta[:chunked_resync_offsets] = chunked.dig(:meta, :chunked_resync_offsets)
    meta[:chunked_resync_ranges] = chunked.dig(:meta, :chunked_resync_ranges)
    meta[:chunked_resync_score] = chunked.dig(:meta, :chunked_resync_score)
    meta[:chunked_resync_reason] = "chunked_alignment_scored_better"
  end

  meta[:shortlist_verification_used] = shortlist_verification_used
  meta[:shortlist_verification_reason] = shortlist_verification_reason
  meta[:shortlist_verification_candidates] = [SHORTLIST_VERIFY_LIMIT, candidates.length].min
  meta[:shortlist_verification_local_offset_radius] = local_evidence_radius
  meta[:pairwise_chunk_decoder_used] = (pairwise_chunk_decoder[:used] == true)
  meta[:pairwise_chunk_decoder_reason] = pairwise_chunk_decoder[:reason]
  meta[:pairwise_chunk_decoder_chunks] = pairwise_chunk_decoder[:chunks] if pairwise_chunk_decoder[:chunks]
  meta[:pairwise_chunk_decoder_top_margin] = pairwise_chunk_decoder[:top_margin] if pairwise_chunk_decoder.key?(:top_margin)
  meta[:pairwise_chunk_decoder_second_margin] = pairwise_chunk_decoder[:second_margin] if pairwise_chunk_decoder.key?(:second_margin)
  meta[:pairwise_chunk_decoder_top_bonus] = pairwise_chunk_decoder[:top_bonus] if pairwise_chunk_decoder.key?(:top_bonus)
  meta[:discriminative_shortlist_decoder_used] = (discriminative_shortlist_decoder[:used] == true)
  meta[:discriminative_shortlist_decoder_reason] = discriminative_shortlist_decoder[:reason]
  meta[:discriminative_shortlist_diff_positions] = discriminative_shortlist_decoder[:diff_positions] if discriminative_shortlist_decoder[:diff_positions]
  meta[:discriminative_shortlist_total_margin] = discriminative_shortlist_decoder[:total_margin] if discriminative_shortlist_decoder.key?(:total_margin)
  meta[:discriminative_shortlist_bonus] = discriminative_shortlist_decoder[:bonus] if discriminative_shortlist_decoder.key?(:bonus)

  other_score = polarity_best_scores[!best_polarity_flip]
  if other_score && other_score.finite? && best_score && best_score.finite?
    meta[:polarity_score_delta] = (best_score - other_score).round(4)
  end

  meta[:shortlist_metric] = "pairwise_chunk_rank_score" if pairwise_chunk_decoder[:used] == true
  meta[:shortlist_metric] = "discriminative_shortlist_rank_score" if discriminative_shortlist_decoder[:used] == true
  annotate_candidate_debugs!(candidates: candidates, observed_variants: ref_obs, observed_segment_indices: seg_indices, media_item_id: media_item.id)
  apply_shortlist_meta!(meta: meta, candidates: candidates)
  apply_top_candidate_debug_to_meta!(meta: meta, candidates: candidates)

  { candidates: candidates, meta: meta }
  end
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
          pairs: analysis_pairs_for_spec(spec),
          main_pair_count: main_pair_count_for_spec(spec),
          box: spec[:box_size_frac].to_f,
          spec: spec
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

    def sample_pair_score(file_path:, t:, pairs:, main_pair_count:, box:, spec:)
      pair_count = pairs.length
      return { variant: nil, confidence: 0.0, score: 0 } if pair_count == 0

      box = box.to_f
      box = 0.12 if box <= 0
      filter_spec = build_pair_filter(in_label: "[0:v]", pairs: pairs, box: box, spec: spec)
      raw = ffmpeg_sample_raw(file_path: file_path, t: t, filter_complex: filter_spec[:filter])
      bytes = raw&.bytes || []

      expected = filter_spec[:expected_bytes].to_i
      return { variant: nil, confidence: 0.0, score: 0 } if bytes.length < expected

      decoded = decode_pair_frame_bytes(bytes: bytes, main_pair_count: main_pair_count, pairs: pairs, spec: spec, box: box)
      variant = decoded[:variant]
      variant = nil if decoded[:payload_confidence].to_f < MIN_CONFIDENCE

      {
        variant: variant,
        confidence: decoded[:payload_confidence].to_f,
        score: decoded[:payload_score].to_f,
        sync_score: decoded[:sync_score].to_f,
        sync_confidence: decoded[:sync_confidence].to_f,
        sync_variant: decoded[:sync_variant]
      }
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
