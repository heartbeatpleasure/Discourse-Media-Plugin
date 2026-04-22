# frozen_string_literal: true

require "securerandom"
require "timeout"

module ::MediaGallery
  module ForensicsIdentifyFileRunner
    module_function

    DEFAULT_FILEMODE_SOFT_TIME_BUDGET_SECONDS = 24
    DEFAULT_FILEMODE_ENGINE_TIME_BUDGET_SECONDS = 22

    FILEMODE_AUTOCAP_MB_1 = 60
    FILEMODE_AUTOCAP_MB_2 = 120
    FILEMODE_AUTOCAP_MB_3 = 250

    ASYNC_MIN_SOFT_BUDGET_MB_1 = 120
    ASYNC_MIN_ENGINE_BUDGET_MB_1 = 105
    ASYNC_MIN_SOFT_BUDGET_MB_2 = 300
    ASYNC_MIN_ENGINE_BUDGET_MB_2 = 285
    ASYNC_MIN_SOFT_BUDGET_MB_3 = 420
    ASYNC_MIN_ENGINE_BUDGET_MB_3 = 390

    DEFAULT_POLICY_MIN_USABLE_STRONG = 12
    DEFAULT_POLICY_MIN_MATCH_STRONG = 0.85
    DEFAULT_POLICY_MIN_DELTA_STRONG = 0.15
    DEFAULT_POLICY_MAX_MISMATCH_RATE_STRONG = 0.20
    DEFAULT_POLICY_MIN_USABLE_LIKELY = 8
    DEFAULT_POLICY_MIN_MATCH_LIKELY = 0.75
    DEFAULT_POLICY_MIN_DELTA_LIKELY = 0.10
    DEFAULT_POLICY_MIN_USABLE_ANY = 5

    def run(media_item:, file_path:, max_samples:, max_offset_segments:, layout: nil, async_mode: false)
      raise Discourse::InvalidParameters.new(:file) if file_path.blank? || !File.exist?(file_path)

      max_samples = max_samples.to_i
      max_samples = 60 if max_samples <= 0
      max_samples = [max_samples, 200].min

      max_offset = max_offset_segments.to_i
      max_offset = 30 if max_offset.negative?
      max_offset = [max_offset, 300].min

      file_bytes = (File.size(file_path) rescue 0).to_i
      file_mb = (file_bytes / (1024.0 * 1024.0)).round(1)

      budgets = effective_budgets(file_mb: file_mb, async_mode: async_mode)
      soft_budget = budgets[:soft]
      engine_budget = budgets[:engine]

      capped_max_samples = max_samples
      if file_mb >= FILEMODE_AUTOCAP_MB_3
        capped_max_samples = [capped_max_samples, (async_mode ? 55 : 25)].min
      elsif file_mb >= FILEMODE_AUTOCAP_MB_2
        capped_max_samples = [capped_max_samples, (async_mode ? 60 : 35)].min
      elsif file_mb >= FILEMODE_AUTOCAP_MB_1
        capped_max_samples = [capped_max_samples, (async_mode ? 55 : 45)].min
      end

      base_meta = {
        requested_max_samples: max_samples,
        max_offset_segments: max_offset,
        configured_filemode_soft_time_budget_seconds: soft_budget,
        configured_filemode_engine_time_budget_seconds: engine_budget,
        file_size_mb: file_mb,
        max_samples_autocapped: (capped_max_samples != max_samples),
        effective_max_samples: capped_max_samples,
      }

      identify_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil

      begin
        Timeout.timeout(soft_budget) do
          result = ::MediaGallery::ForensicsIdentify.identify_from_file(
            media_item: media_item,
            file_path: file_path,
            max_samples: capped_max_samples,
            max_offset_segments: max_offset,
            layout: layout,
            time_budget_seconds: engine_budget,
          )
        end
      rescue Timeout::Error
        result = {
          meta: {
            public_id: media_item.public_id,
            media_item_id: media_item.id,
            decision: "timeout",
            conclusive: false,
            timeout_kind: async_mode ? "filemode_async_soft_budget" : "filemode_soft_budget",
            likely_timeout_layer: async_mode ? "background_job_budget" : "discourse_web_worker_or_reverse_proxy",
            recommendation: async_mode ? "raise_filemode_budgets" : "raise_filemode_budget_or_infrastructure_timeouts",
            user_message: if async_mode
              "Analysis reached the configured background job time limit (soft=#{soft_budget}s, engine=#{engine_budget}s). Increase the file-mode budgets in plugin settings for larger uploads."
            else
              "Analysis reached the configured file-mode time limit (soft=#{soft_budget}s, engine=#{engine_budget}s). In production, the Discourse backend timeout is often around 30s; only raise these budgets together with your infrastructure timeouts (for example Unicorn/web worker and any reverse proxy)."
            end,
          },
          observed: { variants: "", confidences: [] },
          candidates: [],
        }
      rescue => e
        debug_id = "mgfi_#{SecureRandom.hex(6)}"
        Rails.logger.error(
          "[media_gallery] forensics identify failed debug_id=#{debug_id} public_id=#{media_item.public_id} #{e.class}: #{e.message}\n" \
          "#{Array(e.backtrace).first(20).join("\n")}" \
        ) rescue nil

        result = {
          meta: {
            public_id: media_item.public_id,
            media_item_id: media_item.id,
            decision: "error",
            conclusive: false,
            debug_id: debug_id,
            recommendation: "check_server_logs",
            user_message: "Internal error during analysis (debug_id=#{debug_id}). Check production.log for details.",
          },
          observed: { variants: "", confidences: [] },
          candidates: [],
        }
      ensure
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - identify_started_at).to_f
        base_meta[:filemode_elapsed_seconds] = elapsed.round(3)
        base_meta[:attempts] = 1
        base_meta[:auto_extended] = false
        base_meta[:max_samples_used] = capped_max_samples
        base_meta[:async_mode] = async_mode
      end

      result = result.deep_stringify_keys if result.respond_to?(:deep_stringify_keys)
      result["meta"] ||= {}
      base_meta.each { |k, v| result["meta"][k.to_s] = v }

      apply_no_signal_guard!(result)
      apply_decision_policy!(result)
      result
    end

    def effective_budgets(file_mb:, async_mode: false)
      soft = setting_filemode_soft_time_budget_seconds
      engine = setting_filemode_engine_time_budget_seconds(soft_budget_seconds: soft)

      if async_mode
        if file_mb >= FILEMODE_AUTOCAP_MB_2
          soft = [soft, ASYNC_MIN_SOFT_BUDGET_MB_2].max
          engine = [engine, ASYNC_MIN_ENGINE_BUDGET_MB_2].max
        elsif file_mb >= FILEMODE_AUTOCAP_MB_1
          soft = [soft, ASYNC_MIN_SOFT_BUDGET_MB_1].max
          engine = [engine, ASYNC_MIN_ENGINE_BUDGET_MB_1].max
        end

        if file_mb >= FILEMODE_AUTOCAP_MB_3
          soft = [soft, ASYNC_MIN_SOFT_BUDGET_MB_3].max
          engine = [engine, ASYNC_MIN_ENGINE_BUDGET_MB_3].max
        end
      end

      engine = [engine, [soft - 1, 1].max].min
      { soft: soft, engine: engine }
    end

    def setting_filemode_soft_time_budget_seconds
      v = SiteSetting.media_gallery_forensics_identify_filemode_soft_time_budget_seconds.to_i
      v = DEFAULT_FILEMODE_SOFT_TIME_BUDGET_SECONDS if v <= 0
      v
    end

    def setting_filemode_engine_time_budget_seconds(soft_budget_seconds: nil)
      v = SiteSetting.media_gallery_forensics_identify_filemode_engine_time_budget_seconds.to_i
      v = DEFAULT_FILEMODE_ENGINE_TIME_BUDGET_SECONDS if v <= 0

      soft = soft_budget_seconds.to_i
      soft = setting_filemode_soft_time_budget_seconds if soft <= 0
      max_engine = [soft - 1, 1].max
      [v, max_engine].min
    end

    def setting_policy_min_usable_any
      v = SiteSetting.media_gallery_forensics_identify_policy_min_usable_any.to_i
      v = DEFAULT_POLICY_MIN_USABLE_ANY if v <= 0
      v
    end

    def setting_policy_min_usable_strong
      v = SiteSetting.media_gallery_forensics_identify_policy_min_usable_strong.to_i
      v = DEFAULT_POLICY_MIN_USABLE_STRONG if v <= 0
      v
    end

    def setting_policy_min_match_strong_ratio
      pct = SiteSetting.media_gallery_forensics_identify_policy_min_match_strong_percent.to_i
      pct = (DEFAULT_POLICY_MIN_MATCH_STRONG * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def setting_policy_min_delta_strong_ratio
      pct = SiteSetting.media_gallery_forensics_identify_policy_min_delta_strong_percent.to_i
      pct = (DEFAULT_POLICY_MIN_DELTA_STRONG * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def setting_policy_max_mismatch_rate_strong_ratio
      pct = SiteSetting.media_gallery_forensics_identify_policy_max_mismatch_rate_strong_percent.to_i
      pct = (DEFAULT_POLICY_MAX_MISMATCH_RATE_STRONG * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def setting_policy_min_usable_likely
      v = SiteSetting.media_gallery_forensics_identify_policy_min_usable_likely.to_i
      v = DEFAULT_POLICY_MIN_USABLE_LIKELY if v <= 0
      v
    end

    def setting_policy_min_match_likely_ratio
      pct = SiteSetting.media_gallery_forensics_identify_policy_min_match_likely_percent.to_i
      pct = (DEFAULT_POLICY_MIN_MATCH_LIKELY * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def setting_policy_min_delta_likely_ratio
      pct = SiteSetting.media_gallery_forensics_identify_policy_min_delta_likely_percent.to_i
      pct = (DEFAULT_POLICY_MIN_DELTA_LIKELY * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def filemode_observable_capacity(result)
      meta = result.is_a?(Hash) ? (result["meta"] || {}) : {}
      observed = result.is_a?(Hash) ? (result["observed"] || {}) : {}
      counts = []
      counts << meta["sampled_packaged_segments"].to_i
      counts << meta["estimated_clip_segments"].to_i
      counts << meta["effective_max_samples"].to_i
      counts << meta["samples"].to_i
      counts << Array(observed["segment_indices"]).length
      counts << Array(observed["variants_array"]).length
      counts << result.dig("candidates", 0, "compared").to_i
      counts.select! { |v| v.to_i > 0 }
      counts.max.to_i
    rescue
      0
    end

    def decision_policy_thresholds_for(result)
      thresholds = {
        min_usable_any: setting_policy_min_usable_any,
        min_usable_strong: setting_policy_min_usable_strong,
        min_match_strong: setting_policy_min_match_strong_ratio,
        min_delta_strong: setting_policy_min_delta_strong_ratio,
        max_mismatch_rate_strong: setting_policy_max_mismatch_rate_strong_ratio,
        min_usable_likely: setting_policy_min_usable_likely,
        min_match_likely: setting_policy_min_match_likely_ratio,
        min_delta_likely: setting_policy_min_delta_likely_ratio,
        filemode_hardened: true,
        short_clip_adapted: false,
        observable_capacity: 0,
        v8_pairwise_margin_conclusive: 10.0,
        v8_pairwise_wins_conclusive: 6,
        v8_rank_gap_conclusive: 12.0,
        v8_evidence_gap_conclusive: 8.0,
        v8_sync_anchor_ratio_conclusive: 0.54,
        v8_min_clip_coverage_conclusive: 0.97,
        v8_max_mismatch_rate_conclusive: 0.40,
        v8_pairwise_margin_anchorless_conclusive: 11.5,
        v8_pairwise_wins_anchorless_conclusive: 6,
        v8_rank_gap_anchorless_conclusive: 24.0,
        v8_evidence_gap_anchorless_conclusive: 10.0,
        v8_match_delta_anchorless_conclusive: 0.12,
        v8_weighted_delta_anchorless_conclusive: 0.09,
        v8_second_match_anchorless_max: 0.52,
        v8_min_consistent_chunks_anchorless_conclusive: 3,
        v8_second_evidence_anchorless_max: -4.0,
        v8_min_top_evidence_anchorless_conclusive: 4.5,
        v8_pairwise_margin_dominant_conclusive: 14.0,
        v8_pairwise_wins_dominant_conclusive: 7,
        v8_rank_gap_dominant_conclusive: 30.0,
        v8_evidence_gap_dominant_conclusive: 9.0,
        v8_match_delta_dominant_conclusive: 0.22,
        v8_weighted_delta_dominant_conclusive: 0.20,
        v8_second_match_dominant_max: 0.42,
        v8_min_top_ratio_dominant_conclusive: 0.60,
        v8_max_second_evidence_dominant: 0.5,
        v8_min_top_evidence_dominant_conclusive: -2.0,
        v8_pairwise_margin_asymmetric_conclusive: 18.0,
        v8_pairwise_wins_asymmetric_conclusive: 7,
        v8_rank_gap_asymmetric_conclusive: 35.0,
        v8_evidence_gap_asymmetric_conclusive: 12.0,
        v8_match_delta_asymmetric_conclusive: 0.24,
        v8_weighted_delta_asymmetric_conclusive: 0.24,
        v8_second_match_asymmetric_max: 0.40,
        v8_min_top_ratio_asymmetric_conclusive: 0.62,
        v8_max_second_evidence_asymmetric: 0.25,
        v8_pairwise_margin_sparse_longform_conclusive: 18.0,
        v8_pairwise_wins_sparse_longform_conclusive: 6,
        v8_rank_gap_sparse_longform_conclusive: 45.0,
        v8_evidence_gap_sparse_longform_conclusive: 12.0,
        v8_min_top_evidence_sparse_longform_conclusive: 2.5,
        v8_min_consistent_chunks_sparse_longform_conclusive: 3,
        v8_max_second_evidence_sparse_longform: -8.0,
        v8_min_top_ratio_sparse_longform_conclusive: 0.55,
        v8_second_match_sparse_longform_max: 0.54,
        v8_max_mismatch_rate_sparse_longform: 0.45,
        v8_min_observable_capacity_sparse_longform_conclusive: 180,
        v8_sync_anchor_ratio_recovery_conclusive: 0.34,
        v8_pairwise_margin_recovery_conclusive: 8.5,
        v8_pairwise_wins_recovery_conclusive: 5,
        v8_rank_gap_recovery_conclusive: 24.0,
        v8_evidence_gap_recovery_conclusive: 8.0,
        v8_match_delta_recovery_conclusive: 0.22,
        v8_weighted_delta_recovery_conclusive: 0.22,
        v8_second_match_recovery_max: 0.43,
        v8_min_top_ratio_recovery_conclusive: 0.64,
        v8_max_mismatch_rate_recovery: 0.37,
        v8_min_top_evidence_recovery_conclusive: 1.0,
        v8_pairwise_margin_unanimous_conclusive: 16.0,
        v8_pairwise_wins_unanimous_conclusive: 7,
        v8_rank_gap_unanimous_conclusive: 40.0,
        v8_evidence_gap_unanimous_conclusive: 10.0,
        v8_match_delta_unanimous_conclusive: 0.30,
        v8_weighted_delta_unanimous_conclusive: 0.30,
        v8_second_match_unanimous_max: 0.40,
        v8_min_top_ratio_unanimous_conclusive: 0.68,
        v8_max_mismatch_rate_unanimous: 0.35,
        v8_max_second_evidence_unanimous: -8.0,
        v8_min_top_evidence_unanimous_conclusive: -0.5,
      }

      thresholds[:min_usable_strong] = [thresholds[:min_usable_strong], 16].max
      thresholds[:min_match_strong] = [thresholds[:min_match_strong], 0.90].max
      thresholds[:min_delta_strong] = [thresholds[:min_delta_strong], 0.18].max
      thresholds[:max_mismatch_rate_strong] = [thresholds[:max_mismatch_rate_strong], 0.15].min
      thresholds[:min_usable_likely] = [thresholds[:min_usable_likely], 12].max
      thresholds[:min_match_likely] = [thresholds[:min_match_likely], 0.82].max
      thresholds[:min_delta_likely] = [thresholds[:min_delta_likely], 0.14].max

      available = filemode_observable_capacity(result)
      thresholds[:observable_capacity] = available
      if available > 0
        adaptive_strong = [[(available * 0.70).ceil, thresholds[:min_usable_any] + 2].max, available].min
        adaptive_likely = [[(available * 0.50).ceil, thresholds[:min_usable_any]].max, available].min
        if adaptive_strong < thresholds[:min_usable_strong] || adaptive_likely < thresholds[:min_usable_likely]
          thresholds[:short_clip_adapted] = true
        end
        thresholds[:min_usable_strong] = [thresholds[:min_usable_strong], adaptive_strong].min
        thresholds[:min_usable_likely] = [thresholds[:min_usable_likely], adaptive_likely].min
      end

      thresholds
    rescue
      thresholds
    end

    def apply_no_signal_guard!(result)
      return unless result.is_a?(Hash)
      meta = result["meta"]
      return unless meta.is_a?(Hash)

      preset = meta["decision"].to_s
      return if %w[timeout error].include?(preset)
      return if meta["source_mode"].to_s == "hls_playlist"

      eff = meta["effective_samples"].to_f
      usable = meta["usable_samples"].to_i
      top_ratio = meta["offset_top_match_ratio"].to_f

      cand0 = (result["candidates"].is_a?(Array) ? result["candidates"].first : nil)
      comp_w = 0.0
      comp = 0
      if cand0.is_a?(Hash)
        comp_w = cand0["compared_weighted"].to_f
        comp_w = cand0[:compared_weighted].to_f if comp_w <= 0.0 && cand0.key?(:compared_weighted)
        comp = cand0["compared"].to_i
        comp = cand0[:compared].to_i if comp <= 0 && cand0.key?(:compared)
      end

      observed_variants = result.dig("observed", "variants_array")
      observed_variants = result.dig("observed", "variants").to_s.chars if observed_variants.blank?
      observed_non_null = Array(observed_variants).count { |v| v.present? && v != "." && v != "?" }

      confs = result.dig("observed", "confidences")
      confs = Array(confs).map { |c| c.to_f }.select { |c| c.finite? && c >= 0 }
      conf_med = confs.empty? ? 0.0 : confs.sort[confs.length / 2]

      soft_budget = meta["configured_filemode_soft_time_budget_seconds"].to_f
      engine_budget = meta["configured_filemode_engine_time_budget_seconds"].to_f
      budget_exhausted =
        meta["filemode_budget_exhausted"] == true ||
          meta["phase_search_budget_exhausted"] == true ||
          meta["budget_exhausted"] == true

      has_partial_signal =
        eff > 0.5 ||
          usable >= setting_policy_min_usable_any ||
          observed_non_null >= setting_policy_min_usable_any ||
          comp_w >= 1.0 ||
          comp >= setting_policy_min_usable_any ||
          top_ratio > 0.0 ||
          conf_med >= 0.005

      meta["guard_observed_non_null"] = observed_non_null
      meta["guard_candidate_compared_weighted"] = comp_w.round(4)
      meta["guard_candidate_compared"] = comp
      meta["guard_offset_top_match_ratio"] = top_ratio.round(4)
      meta["guard_has_partial_signal"] = has_partial_signal

      unless has_partial_signal
        if budget_exhausted
          meta["decision"] = "timeout"
          meta["conclusive"] = false
          meta["timeout_kind"] ||= "filemode_engine_budget"
          meta["likely_timeout_layer"] ||= meta["async_mode"] ? "background_job_budget" : "plugin_budget_before_full_signal"
          meta["recommendation"] = meta["async_mode"] ? "raise_filemode_budgets" : "raise_filemode_budget_or_infrastructure_timeouts"
          meta["user_message"] ||= begin
            msg = "Analysis stopped before enough watermark signal was accumulated"
            parts = []
            parts << "engine=#{engine_budget.to_i}s" if engine_budget > 0
            parts << "soft=#{soft_budget.to_i}s" if soft_budget > 0
            msg += " (#{parts.join(', ')})" if parts.present?
            msg + if meta["async_mode"]
              ". This more often points to a configured job limit than to a wrong public_id. Increase the file-mode budgets in plugin settings for larger uploads."
            else
              ". This more often points to a timeout than to a wrong public_id. Increase the file-mode budgets in plugin settings first; only go towards ~30s or higher if you also increase the Discourse/web-worker timeout and any reverse-proxy timeout."
            end
          end
          result["candidates"] = []
          return
        end

        meta["decision"] = "no_signal"
        meta["conclusive"] = false
        meta["recommendation"] = "check_public_id_or_use_hls_url"
        meta["user_message"] =
          "No reliable watermark signal was found for this public_id. This usually means the public_id is wrong, or the upload is not derived from this video (or has been heavily re-encoded/cropped). Try: (1) the correct public_id, (2) a clip closer to the original HLS download, or (3) HLS URL mode."

        result["candidates"] = []
      end
    rescue
      nil
    end

    def v8_layout_result?(result)
      result.dig("meta", "layout").to_s == "v8_microgrid"
    rescue
      false
    end

    def v8_artifact_like_result?(result, thresholds:)
      return false unless v8_layout_result?(result)
      return false if result.dig("meta", "source_mode").to_s == "hls_playlist"

      coverage = result.dig("meta", "clip_segment_coverage_ratio").to_f
      effective_max_offset = result.dig("meta", "effective_max_offset_segments").to_i
      chosen_offset = result.dig("meta", "chosen_offset_segments").to_i
      return false if coverage < thresholds[:v8_min_clip_coverage_conclusive].to_f
      return false if effective_max_offset > 1
      return false if chosen_offset.abs > 1

      true
    rescue
      false
    end

    def v8_pairwise_conclusive_info(result, thresholds:, top_cand:, second_cand:, mismatch_rate:)
      return { used: false, basis: nil, reason: nil } unless v8_artifact_like_result?(result, thresholds: thresholds)
      return { used: false, basis: nil, reason: nil } unless Array(result["candidates"]).length >= 2
      return { used: false, basis: nil, reason: nil } unless result.dig("meta", "pairwise_chunk_decoder_used") == true

      top_margin = top_cand["pairwise_chunk_margin_total"].to_f
      top_wins = top_cand["pairwise_chunks_won"].to_i
      top_losses = top_cand["pairwise_chunks_lost"].to_i
      rank_gap = result.dig("meta", "shortlist_rank_gap").to_f
      evidence_gap = result.dig("meta", "shortlist_evidence_gap").to_f
      top_rank = top_cand["rank_score"].to_f
      second_rank = second_cand["rank_score"].to_f
      top_evidence = top_cand["evidence_score"].to_f
      second_evidence = second_cand["evidence_score"].to_f
      top_consistent = top_cand["evidence_consistent_chunks"].to_i
      second_consistent = second_cand["evidence_consistent_chunks"].to_i
      top_ratio = top_cand["match_ratio"].to_f
      second_ratio = second_cand["match_ratio"].to_f
      weighted_delta = result.dig("meta", "offset_delta").to_f
      raw_delta = top_ratio - second_ratio
      sync_ratio = result.dig("meta", "sync_anchor_best_ratio").to_f
      sync_used = result.dig("meta", "sync_anchor_used") == true
      discriminative_used = result.dig("meta", "discriminative_shortlist_decoder_used") == true
      discriminative_margin = top_cand["discriminative_margin_total"].to_f

      return { used: false, basis: nil, reason: nil } if top_margin < thresholds[:v8_pairwise_margin_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if top_wins < thresholds[:v8_pairwise_wins_conclusive].to_i
      return { used: false, basis: nil, reason: nil } if top_wins < (top_losses + 4)
      return { used: false, basis: nil, reason: nil } if rank_gap < thresholds[:v8_rank_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if evidence_gap < thresholds[:v8_evidence_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if top_rank < thresholds[:v8_evidence_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if second_rank > 0.0 && second_evidence > 0.0
      return { used: false, basis: nil, reason: nil } if discriminative_used && discriminative_margin < -0.25

      if sync_used && mismatch_rate <= thresholds[:v8_max_mismatch_rate_conclusive].to_f && sync_ratio >= thresholds[:v8_sync_anchor_ratio_conclusive].to_f
        return {
          used: true,
          basis: "sync_anchor_pairwise",
          reason: "v8_pairwise_artifact_policy_passed",
        }
      end

      anchorless_ok = true
      anchorless_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_conclusive].to_f)
      anchorless_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_anchorless_conclusive].to_f)
      anchorless_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_anchorless_conclusive].to_i)
      anchorless_ok &&= (top_losses <= 1)
      anchorless_ok &&= (rank_gap >= thresholds[:v8_rank_gap_anchorless_conclusive].to_f)
      anchorless_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_anchorless_conclusive].to_f)
      anchorless_ok &&= (raw_delta >= thresholds[:v8_match_delta_anchorless_conclusive].to_f)
      anchorless_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_anchorless_conclusive].to_f)
      anchorless_ok &&= (second_ratio <= thresholds[:v8_second_match_anchorless_max].to_f)
      anchorless_ok &&= (top_consistent >= thresholds[:v8_min_consistent_chunks_anchorless_conclusive].to_i)
      anchorless_ok &&= (second_consistent <= 1)
      anchorless_ok &&= (second_evidence <= thresholds[:v8_second_evidence_anchorless_max].to_f)
      anchorless_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_anchorless_conclusive].to_f)

      if anchorless_ok
        return {
          used: true,
          basis: "anchorless_pairwise_strong",
          reason: "v8_pairwise_anchorless_policy_passed",
        }
      end

      dominant_ok = true
      dominant_ok &&= !sync_used
      dominant_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_conclusive].to_f)
      dominant_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_dominant_conclusive].to_f)
      dominant_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_dominant_conclusive].to_i)
      dominant_ok &&= (top_losses <= 2)
      dominant_ok &&= (rank_gap >= thresholds[:v8_rank_gap_dominant_conclusive].to_f)
      dominant_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_dominant_conclusive].to_f)
      dominant_ok &&= (raw_delta >= thresholds[:v8_match_delta_dominant_conclusive].to_f)
      dominant_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_dominant_conclusive].to_f)
      dominant_ok &&= (second_ratio <= thresholds[:v8_second_match_dominant_max].to_f)
      dominant_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_dominant_conclusive].to_f)
      dominant_ok &&= (top_consistent >= 1)
      dominant_ok &&= (second_consistent <= 2)
      dominant_ok &&= (second_evidence <= thresholds[:v8_max_second_evidence_dominant].to_f)
      dominant_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_dominant_conclusive].to_f)

      if dominant_ok
        return {
          used: true,
          basis: "anchorless_pairwise_dominant",
          reason: "v8_pairwise_dominant_policy_passed",
        }
      end

      recovery_ok = true
      recovery_ok &&= sync_used
      recovery_ok &&= (sync_ratio >= thresholds[:v8_sync_anchor_ratio_recovery_conclusive].to_f)
      recovery_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_recovery].to_f)
      recovery_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_recovery_conclusive].to_f)
      recovery_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_recovery_conclusive].to_i)
      recovery_ok &&= (top_wins >= (top_losses + 3))
      recovery_ok &&= (top_losses <= 2)
      recovery_ok &&= (rank_gap >= thresholds[:v8_rank_gap_recovery_conclusive].to_f)
      recovery_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_recovery_conclusive].to_f)
      recovery_ok &&= (raw_delta >= thresholds[:v8_match_delta_recovery_conclusive].to_f)
      recovery_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_recovery_conclusive].to_f)
      recovery_ok &&= (second_ratio <= thresholds[:v8_second_match_recovery_max].to_f)
      recovery_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_recovery_conclusive].to_f)
      recovery_ok &&= (top_consistent >= 2)
      recovery_ok &&= (second_consistent <= 2)
      recovery_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_recovery_conclusive].to_f)
      recovery_ok &&= (second_evidence <= -6.0)

      if recovery_ok
        return {
          used: true,
          basis: "sync_anchor_pairwise_recovery",
          reason: "v8_pairwise_recovery_policy_passed",
        }
      end

      unanimous_ok = true
      unanimous_ok &&= !sync_used
      unanimous_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_unanimous].to_f)
      unanimous_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_unanimous_conclusive].to_f)
      unanimous_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_unanimous_conclusive].to_i)
      unanimous_ok &&= (top_losses == 0)
      unanimous_ok &&= (rank_gap >= thresholds[:v8_rank_gap_unanimous_conclusive].to_f)
      unanimous_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_unanimous_conclusive].to_f)
      unanimous_ok &&= (raw_delta >= thresholds[:v8_match_delta_unanimous_conclusive].to_f)
      unanimous_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_unanimous_conclusive].to_f)
      unanimous_ok &&= (second_ratio <= thresholds[:v8_second_match_unanimous_max].to_f)
      unanimous_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_unanimous_conclusive].to_f)
      unanimous_ok &&= (second_evidence <= thresholds[:v8_max_second_evidence_unanimous].to_f)
      unanimous_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_unanimous_conclusive].to_f)

      if unanimous_ok
        return {
          used: true,
          basis: "anchorless_pairwise_unanimous",
          reason: "v8_pairwise_unanimous_policy_passed",
        }
      end

      sparse_longform_ok = true
      sparse_longform_ok &&= !sync_used
      sparse_longform_ok &&= (thresholds[:observable_capacity].to_i >= thresholds[:v8_min_observable_capacity_sparse_longform_conclusive].to_i)
      sparse_longform_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_sparse_longform_conclusive].to_f)
      sparse_longform_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_sparse_longform_conclusive].to_i)
      sparse_longform_ok &&= (top_losses <= 2)
      sparse_longform_ok &&= (rank_gap >= thresholds[:v8_rank_gap_sparse_longform_conclusive].to_f)
      sparse_longform_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_sparse_longform_conclusive].to_f)
      sparse_longform_ok &&= (top_consistent >= thresholds[:v8_min_consistent_chunks_sparse_longform_conclusive].to_i)
      sparse_longform_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_sparse_longform_conclusive].to_f)
      sparse_longform_ok &&= (second_evidence <= thresholds[:v8_max_second_evidence_sparse_longform].to_f)
      sparse_longform_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_sparse_longform_conclusive].to_f)
      sparse_longform_ok &&= (second_ratio <= thresholds[:v8_second_match_sparse_longform_max].to_f)
      sparse_longform_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_sparse_longform].to_f)

      if sparse_longform_ok
        return {
          used: true,
          basis: "anchorless_pairwise_sparse_longform",
          reason: "v8_pairwise_sparse_longform_policy_passed",
        }
      end

      asymmetric_ok = true
      asymmetric_ok &&= !sync_used
      asymmetric_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_conclusive].to_f)
      asymmetric_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_asymmetric_conclusive].to_i)
      asymmetric_ok &&= (top_losses <= 2)
      asymmetric_ok &&= (rank_gap >= thresholds[:v8_rank_gap_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (raw_delta >= thresholds[:v8_match_delta_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (second_ratio <= thresholds[:v8_second_match_asymmetric_max].to_f)
      asymmetric_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_asymmetric_conclusive].to_f)
      asymmetric_ok &&= (top_consistent >= 1)
      asymmetric_ok &&= (second_evidence <= thresholds[:v8_max_second_evidence_asymmetric].to_f)

      if asymmetric_ok
        return {
          used: true,
          basis: "anchorless_pairwise_asymmetric",
          reason: "v8_pairwise_asymmetric_policy_passed",
        }
      end

      { used: false, basis: nil, reason: nil }
    rescue
      { used: false, basis: nil, reason: nil }
    end

    def apply_decision_policy!(result)
      result["meta"] ||= {}

      preset = result.dig("meta", "decision").to_s
      if %w[no_signal timeout error].include?(preset)
        result["meta"]["conclusive"] = false
        result["meta"]["top_match_ratio"] ||= 0.0
        result["meta"]["second_match_ratio"] ||= 0.0
        result["meta"]["match_delta"] ||= 0.0
        result["meta"]["top_mismatches"] ||= 0
        result["meta"]["top_compared"] ||= 0
        result["meta"]["top_mismatch_rate"] ||= 1.0

        thresholds = decision_policy_thresholds_for(result)
        result["meta"]["policy"] ||= {
          "min_usable_any" => thresholds[:min_usable_any],
          "min_usable_strong" => thresholds[:min_usable_strong],
          "min_match_strong" => thresholds[:min_match_strong],
          "min_delta_strong" => thresholds[:min_delta_strong],
          "max_mismatch_rate_strong" => thresholds[:max_mismatch_rate_strong],
          "min_usable_likely" => thresholds[:min_usable_likely],
          "min_match_likely" => thresholds[:min_match_likely],
          "min_delta_likely" => thresholds[:min_delta_likely],
          "filemode_hardened" => thresholds[:filemode_hardened],
          "short_clip_adapted" => thresholds[:short_clip_adapted],
          "observable_capacity" => thresholds[:observable_capacity],
          "v8_pairwise_margin_conclusive" => thresholds[:v8_pairwise_margin_conclusive],
          "v8_pairwise_wins_conclusive" => thresholds[:v8_pairwise_wins_conclusive],
          "v8_rank_gap_conclusive" => thresholds[:v8_rank_gap_conclusive],
          "v8_evidence_gap_conclusive" => thresholds[:v8_evidence_gap_conclusive],
          "v8_pairwise_margin_anchorless_conclusive" => thresholds[:v8_pairwise_margin_anchorless_conclusive],
          "v8_pairwise_wins_anchorless_conclusive" => thresholds[:v8_pairwise_wins_anchorless_conclusive],
          "v8_rank_gap_anchorless_conclusive" => thresholds[:v8_rank_gap_anchorless_conclusive],
          "v8_evidence_gap_anchorless_conclusive" => thresholds[:v8_evidence_gap_anchorless_conclusive],
          "v8_match_delta_anchorless_conclusive" => thresholds[:v8_match_delta_anchorless_conclusive],
          "v8_weighted_delta_anchorless_conclusive" => thresholds[:v8_weighted_delta_anchorless_conclusive],
          "v8_second_match_anchorless_max" => thresholds[:v8_second_match_anchorless_max],
          "v8_min_consistent_chunks_anchorless_conclusive" => thresholds[:v8_min_consistent_chunks_anchorless_conclusive],
          "v8_second_evidence_anchorless_max" => thresholds[:v8_second_evidence_anchorless_max],
          "v8_min_top_evidence_anchorless_conclusive" => thresholds[:v8_min_top_evidence_anchorless_conclusive],
          "v8_pairwise_margin_dominant_conclusive" => thresholds[:v8_pairwise_margin_dominant_conclusive],
          "v8_pairwise_wins_dominant_conclusive" => thresholds[:v8_pairwise_wins_dominant_conclusive],
          "v8_rank_gap_dominant_conclusive" => thresholds[:v8_rank_gap_dominant_conclusive],
          "v8_evidence_gap_dominant_conclusive" => thresholds[:v8_evidence_gap_dominant_conclusive],
          "v8_match_delta_dominant_conclusive" => thresholds[:v8_match_delta_dominant_conclusive],
          "v8_weighted_delta_dominant_conclusive" => thresholds[:v8_weighted_delta_dominant_conclusive],
          "v8_second_match_dominant_max" => thresholds[:v8_second_match_dominant_max],
          "v8_min_top_ratio_dominant_conclusive" => thresholds[:v8_min_top_ratio_dominant_conclusive],
          "v8_max_second_evidence_dominant" => thresholds[:v8_max_second_evidence_dominant],
          "v8_min_top_evidence_dominant_conclusive" => thresholds[:v8_min_top_evidence_dominant_conclusive],
        }

        result["meta"]["recommendation"] ||= "gather_longer_sample_or_try_url_mode"
        return
      end

      result["meta"].delete("v8_pairwise_conclusive_used")
      result["meta"].delete("v8_pairwise_conclusive_basis")
      result["meta"].delete("v8_pairwise_conclusive_reason")
      decision = classify_decision(result)
      top = result.dig("candidates", 0, "match_ratio").to_f
      second = result.dig("candidates", 1, "match_ratio").to_f
      delta = top - second
      mismatches = result.dig("candidates", 0, "mismatches").to_i
      compared = result.dig("candidates", 0, "compared").to_i
      mismatch_rate = compared > 0 ? (mismatches.to_f / compared.to_f) : 1.0

      result["meta"]["decision"] = decision
      result["meta"]["conclusive"] = (decision == "conclusive_match")
      result["meta"]["top_match_ratio"] = top
      result["meta"]["second_match_ratio"] = second
      result["meta"]["match_delta"] = delta
      result["meta"]["top_mismatches"] = mismatches
      result["meta"]["top_compared"] = compared
      result["meta"]["top_mismatch_rate"] = mismatch_rate

      thresholds = decision_policy_thresholds_for(result)
      result["meta"]["policy"] = {
        "min_usable_any" => thresholds[:min_usable_any],
        "min_usable_strong" => thresholds[:min_usable_strong],
        "min_match_strong" => thresholds[:min_match_strong],
        "min_delta_strong" => thresholds[:min_delta_strong],
        "max_mismatch_rate_strong" => thresholds[:max_mismatch_rate_strong],
        "min_usable_likely" => thresholds[:min_usable_likely],
        "min_match_likely" => thresholds[:min_match_likely],
        "min_delta_likely" => thresholds[:min_delta_likely],
        "filemode_hardened" => thresholds[:filemode_hardened],
        "short_clip_adapted" => thresholds[:short_clip_adapted],
        "observable_capacity" => thresholds[:observable_capacity],
        "v8_pairwise_margin_conclusive" => thresholds[:v8_pairwise_margin_conclusive],
        "v8_pairwise_wins_conclusive" => thresholds[:v8_pairwise_wins_conclusive],
        "v8_rank_gap_conclusive" => thresholds[:v8_rank_gap_conclusive],
        "v8_evidence_gap_conclusive" => thresholds[:v8_evidence_gap_conclusive],
        "v8_pairwise_margin_anchorless_conclusive" => thresholds[:v8_pairwise_margin_anchorless_conclusive],
        "v8_pairwise_wins_anchorless_conclusive" => thresholds[:v8_pairwise_wins_anchorless_conclusive],
        "v8_rank_gap_anchorless_conclusive" => thresholds[:v8_rank_gap_anchorless_conclusive],
        "v8_evidence_gap_anchorless_conclusive" => thresholds[:v8_evidence_gap_anchorless_conclusive],
        "v8_match_delta_anchorless_conclusive" => thresholds[:v8_match_delta_anchorless_conclusive],
        "v8_weighted_delta_anchorless_conclusive" => thresholds[:v8_weighted_delta_anchorless_conclusive],
        "v8_second_match_anchorless_max" => thresholds[:v8_second_match_anchorless_max],
        "v8_min_consistent_chunks_anchorless_conclusive" => thresholds[:v8_min_consistent_chunks_anchorless_conclusive],
        "v8_second_evidence_anchorless_max" => thresholds[:v8_second_evidence_anchorless_max],
        "v8_min_top_evidence_anchorless_conclusive" => thresholds[:v8_min_top_evidence_anchorless_conclusive],
        "v8_pairwise_margin_dominant_conclusive" => thresholds[:v8_pairwise_margin_dominant_conclusive],
        "v8_pairwise_wins_dominant_conclusive" => thresholds[:v8_pairwise_wins_dominant_conclusive],
        "v8_rank_gap_dominant_conclusive" => thresholds[:v8_rank_gap_dominant_conclusive],
        "v8_evidence_gap_dominant_conclusive" => thresholds[:v8_evidence_gap_dominant_conclusive],
        "v8_match_delta_dominant_conclusive" => thresholds[:v8_match_delta_dominant_conclusive],
        "v8_weighted_delta_dominant_conclusive" => thresholds[:v8_weighted_delta_dominant_conclusive],
        "v8_second_match_dominant_max" => thresholds[:v8_second_match_dominant_max],
        "v8_min_top_ratio_dominant_conclusive" => thresholds[:v8_min_top_ratio_dominant_conclusive],
        "v8_max_second_evidence_dominant" => thresholds[:v8_max_second_evidence_dominant],
        "v8_min_top_evidence_dominant_conclusive" => thresholds[:v8_min_top_evidence_dominant_conclusive],
        "v8_pairwise_margin_asymmetric_conclusive" => thresholds[:v8_pairwise_margin_asymmetric_conclusive],
        "v8_pairwise_wins_asymmetric_conclusive" => thresholds[:v8_pairwise_wins_asymmetric_conclusive],
        "v8_rank_gap_asymmetric_conclusive" => thresholds[:v8_rank_gap_asymmetric_conclusive],
        "v8_evidence_gap_asymmetric_conclusive" => thresholds[:v8_evidence_gap_asymmetric_conclusive],
        "v8_match_delta_asymmetric_conclusive" => thresholds[:v8_match_delta_asymmetric_conclusive],
        "v8_weighted_delta_asymmetric_conclusive" => thresholds[:v8_weighted_delta_asymmetric_conclusive],
        "v8_second_match_asymmetric_max" => thresholds[:v8_second_match_asymmetric_max],
        "v8_min_top_ratio_asymmetric_conclusive" => thresholds[:v8_min_top_ratio_asymmetric_conclusive],
        "v8_max_second_evidence_asymmetric" => thresholds[:v8_max_second_evidence_asymmetric],
        "v8_pairwise_margin_sparse_longform_conclusive" => thresholds[:v8_pairwise_margin_sparse_longform_conclusive],
        "v8_pairwise_wins_sparse_longform_conclusive" => thresholds[:v8_pairwise_wins_sparse_longform_conclusive],
        "v8_rank_gap_sparse_longform_conclusive" => thresholds[:v8_rank_gap_sparse_longform_conclusive],
        "v8_evidence_gap_sparse_longform_conclusive" => thresholds[:v8_evidence_gap_sparse_longform_conclusive],
        "v8_min_top_evidence_sparse_longform_conclusive" => thresholds[:v8_min_top_evidence_sparse_longform_conclusive],
        "v8_min_consistent_chunks_sparse_longform_conclusive" => thresholds[:v8_min_consistent_chunks_sparse_longform_conclusive],
        "v8_max_second_evidence_sparse_longform" => thresholds[:v8_max_second_evidence_sparse_longform],
        "v8_min_top_ratio_sparse_longform_conclusive" => thresholds[:v8_min_top_ratio_sparse_longform_conclusive],
        "v8_second_match_sparse_longform_max" => thresholds[:v8_second_match_sparse_longform_max],
        "v8_max_mismatch_rate_sparse_longform" => thresholds[:v8_max_mismatch_rate_sparse_longform],
        "v8_min_observable_capacity_sparse_longform_conclusive" => thresholds[:v8_min_observable_capacity_sparse_longform_conclusive],
        "v8_sync_anchor_ratio_recovery_conclusive" => thresholds[:v8_sync_anchor_ratio_recovery_conclusive],
        "v8_pairwise_margin_recovery_conclusive" => thresholds[:v8_pairwise_margin_recovery_conclusive],
        "v8_pairwise_wins_recovery_conclusive" => thresholds[:v8_pairwise_wins_recovery_conclusive],
        "v8_rank_gap_recovery_conclusive" => thresholds[:v8_rank_gap_recovery_conclusive],
        "v8_evidence_gap_recovery_conclusive" => thresholds[:v8_evidence_gap_recovery_conclusive],
        "v8_match_delta_recovery_conclusive" => thresholds[:v8_match_delta_recovery_conclusive],
        "v8_weighted_delta_recovery_conclusive" => thresholds[:v8_weighted_delta_recovery_conclusive],
        "v8_second_match_recovery_max" => thresholds[:v8_second_match_recovery_max],
        "v8_min_top_ratio_recovery_conclusive" => thresholds[:v8_min_top_ratio_recovery_conclusive],
        "v8_max_mismatch_rate_recovery" => thresholds[:v8_max_mismatch_rate_recovery],
        "v8_min_top_evidence_recovery_conclusive" => thresholds[:v8_min_top_evidence_recovery_conclusive],
        "v8_pairwise_margin_unanimous_conclusive" => thresholds[:v8_pairwise_margin_unanimous_conclusive],
        "v8_pairwise_wins_unanimous_conclusive" => thresholds[:v8_pairwise_wins_unanimous_conclusive],
        "v8_rank_gap_unanimous_conclusive" => thresholds[:v8_rank_gap_unanimous_conclusive],
        "v8_evidence_gap_unanimous_conclusive" => thresholds[:v8_evidence_gap_unanimous_conclusive],
        "v8_match_delta_unanimous_conclusive" => thresholds[:v8_match_delta_unanimous_conclusive],
        "v8_weighted_delta_unanimous_conclusive" => thresholds[:v8_weighted_delta_unanimous_conclusive],
        "v8_second_match_unanimous_max" => thresholds[:v8_second_match_unanimous_max],
        "v8_min_top_ratio_unanimous_conclusive" => thresholds[:v8_min_top_ratio_unanimous_conclusive],
        "v8_max_mismatch_rate_unanimous" => thresholds[:v8_max_mismatch_rate_unanimous],
        "v8_max_second_evidence_unanimous" => thresholds[:v8_max_second_evidence_unanimous],
        "v8_min_top_evidence_unanimous_conclusive" => thresholds[:v8_min_top_evidence_unanimous_conclusive],
      }

      result["meta"]["recommendation"] =
        case decision
        when "conclusive_match"
          "ok"
        when "likely_match"
          "gather_longer_sample_to_confirm"
        when "ambiguous"
          "gather_longer_sample_or_try_url_mode"
        when "insufficient_samples"
          "gather_longer_sample"
        when "no_match"
          "try_longer_or_closer_to_original"
        else
          "try_longer_or_closer_to_original"
        end
    end

    def classify_decision(result)
      usable = result.dig("meta", "usable_samples").to_i
      cands = result["candidates"]
      has_cands = cands.is_a?(Array) && cands.present?

      thresholds = decision_policy_thresholds_for(result)
      return "insufficient_samples" if usable < thresholds[:min_usable_any]
      return "no_match" unless has_cands

      top_cand = cands[0].is_a?(Hash) ? cands[0] : {}
      second_cand = cands[1].is_a?(Hash) ? cands[1] : {}
      top = top_cand["match_ratio"].to_f
      second = second_cand["match_ratio"].to_f
      delta = top - second

      mismatches = top_cand["mismatches"].to_i
      compared = top_cand["compared"].to_i
      mismatch_rate = compared > 0 ? (mismatches.to_f / compared.to_f) : 1.0

      v8_pairwise_info = v8_pairwise_conclusive_info(result, thresholds: thresholds, top_cand: top_cand, second_cand: second_cand, mismatch_rate: mismatch_rate)
      if v8_pairwise_info[:used]
        result["meta"] ||= {}
        result["meta"]["v8_pairwise_conclusive_used"] = true
        result["meta"]["v8_pairwise_conclusive_basis"] = v8_pairwise_info[:basis]
        result["meta"]["v8_pairwise_conclusive_reason"] = v8_pairwise_info[:reason]
        return "conclusive_match"
      end

      if usable >= thresholds[:min_usable_strong] &&
           top >= thresholds[:min_match_strong] &&
           delta >= thresholds[:min_delta_strong] &&
           mismatch_rate <= thresholds[:max_mismatch_rate_strong]
        return "conclusive_match"
      end

      if usable >= thresholds[:min_usable_likely] &&
           top >= thresholds[:min_match_likely] &&
           delta >= thresholds[:min_delta_likely]
        return "likely_match"
      end

      "ambiguous"
    end
  end
end
