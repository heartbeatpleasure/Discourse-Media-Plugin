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
    ASYNC_MIN_SOFT_BUDGET_MB_2 = 180
    ASYNC_MIN_ENGINE_BUDGET_MB_2 = 165
    ASYNC_MIN_SOFT_BUDGET_MB_3 = 300
    ASYNC_MIN_ENGINE_BUDGET_MB_3 = 285

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
        capped_max_samples = [capped_max_samples, 25].min
      elsif file_mb >= FILEMODE_AUTOCAP_MB_2
        capped_max_samples = [capped_max_samples, 35].min
      elsif file_mb >= FILEMODE_AUTOCAP_MB_1
        capped_max_samples = [capped_max_samples, 45].min
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
              "Analyse bereikte de ingestelde background job tijdslimiet (soft=#{soft_budget}s, engine=#{engine_budget}s). Verhoog de file-mode budgets in plugin settings voor grotere uploads."
            else
              "Analyse bereikte de ingestelde file-mode tijdslimiet (soft=#{soft_budget}s, engine=#{engine_budget}s). Op Discourse is de backend-timeout in productie vaak ~30s; verhoog deze budgets alleen samen met je infrastructuur-timeouts (bijv. Unicorn/web worker en eventuele reverse proxy)."
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
            user_message: "Interne fout tijdens analyse (debug_id=#{debug_id}). Kijk in production.log voor details.",
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
            msg = "Analyse stopte voordat er genoeg watermark-signaal was opgebouwd"
            parts = []
            parts << "engine=#{engine_budget.to_i}s" if engine_budget > 0
            parts << "soft=#{soft_budget.to_i}s" if soft_budget > 0
            msg += " (#{parts.join(', ')})" if parts.present?
            msg + if meta["async_mode"]
              ". Dit wijst vaker op een ingestelde job-limiet dan op een verkeerd public_id. Verhoog de file-mode budgets in plugin settings voor grotere uploads."
            else
              ". Dit wijst vaker op een tijdslimiet dan op een verkeerd public_id. Verhoog eerst de file-mode budgets in plugin settings; ga alleen richting ~30s of hoger als je ook de Discourse/web-worker timeout en eventuele reverse-proxy timeout verhoogt."
            end
          end
          result["candidates"] = []
          return
        end

        meta["decision"] = "no_signal"
        meta["conclusive"] = false
        meta["recommendation"] = "check_public_id_or_use_hls_url"
        meta["user_message"] =
          "Geen betrouwbaar watermark-signaal gevonden voor deze public_id. Dit betekent meestal een verkeerd public_id, of dat de upload geen afgeleide is van deze video (of zwaar ge-reencode/cropped). Probeer: (1) juiste public_id, (2) clip dichter bij originele HLS download, of (3) HLS URL-mode."

        result["candidates"] = []
      end
    rescue
      nil
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

        result["meta"]["policy"] ||= {
          "min_usable_any" => setting_policy_min_usable_any,
          "min_usable_strong" => setting_policy_min_usable_strong,
          "min_match_strong" => setting_policy_min_match_strong_ratio,
          "min_delta_strong" => setting_policy_min_delta_strong_ratio,
          "max_mismatch_rate_strong" => setting_policy_max_mismatch_rate_strong_ratio,
          "min_usable_likely" => setting_policy_min_usable_likely,
          "min_match_likely" => setting_policy_min_match_likely_ratio,
          "min_delta_likely" => setting_policy_min_delta_likely_ratio,
        }

        result["meta"]["recommendation"] ||= "gather_longer_sample_or_try_url_mode"
        return
      end

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

      result["meta"]["policy"] = {
        "min_usable_any" => setting_policy_min_usable_any,
        "min_usable_strong" => setting_policy_min_usable_strong,
        "min_match_strong" => setting_policy_min_match_strong_ratio,
        "min_delta_strong" => setting_policy_min_delta_strong_ratio,
        "max_mismatch_rate_strong" => setting_policy_max_mismatch_rate_strong_ratio,
        "min_usable_likely" => setting_policy_min_usable_likely,
        "min_match_likely" => setting_policy_min_match_likely_ratio,
        "min_delta_likely" => setting_policy_min_delta_likely_ratio,
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

      return "insufficient_samples" if usable < setting_policy_min_usable_any
      return "no_match" unless has_cands

      top = cands[0].is_a?(Hash) ? cands[0]["match_ratio"].to_f : 0.0
      second = cands[1].is_a?(Hash) ? cands[1]["match_ratio"].to_f : 0.0
      delta = top - second

      mismatches = cands[0].is_a?(Hash) ? cands[0]["mismatches"].to_i : 0
      compared = cands[0].is_a?(Hash) ? cands[0]["compared"].to_i : 0
      mismatch_rate = compared > 0 ? (mismatches.to_f / compared.to_f) : 1.0

      if usable >= setting_policy_min_usable_strong &&
           top >= setting_policy_min_match_strong_ratio &&
           delta >= setting_policy_min_delta_strong_ratio &&
           mismatch_rate <= setting_policy_max_mismatch_rate_strong_ratio
        return "conclusive_match"
      end

      if usable >= setting_policy_min_usable_likely &&
           top >= setting_policy_min_match_likely_ratio &&
           delta >= setting_policy_min_delta_likely_ratio
        return "likely_match"
      end

      "ambiguous"
    end
  end
end
