# frozen_string_literal: true

require "cgi"
require "tempfile"
require "uri"
require "open3"
require "net/http"
require "timeout"
require "securerandom"

module ::MediaGallery
  class AdminForensicsIdentifyController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # Keep file-mode requests below common request timeout thresholds.
    # Many installs run into the Discourse production web timeout (~30s) before a reverse proxy does.
    DEFAULT_FILEMODE_SOFT_TIME_BUDGET_SECONDS = 24
    DEFAULT_FILEMODE_ENGINE_TIME_BUDGET_SECONDS = 22

    # Auto-cap sampling for large uploads to avoid timeouts.
    FILEMODE_AUTOCAP_MB_1 = 60
    FILEMODE_AUTOCAP_MB_2 = 120
    FILEMODE_AUTOCAP_MB_3 = 250

    def show
      public_id = params[:public_id].to_s
      public_id = public_id.sub(/\.(json|html)\z/i, "")
      public_id = public_id.strip
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      if item.blank?
        return render json: { errors: ["unknown_public_id", public_id] }, status: 422
      end

      action_url = "/admin/plugins/media-gallery/forensics-identify/#{public_id}.json"

      html = <<~HTML
        <div class="wrap">
          <h1>Media Gallery – Forensics Identify</h1>
          <p>
            Upload a leaked copy of this video to attempt identification.
            This is best-effort and can be affected by re-encoding/cropping.
          </p>

          <ul>
            <li><strong>public_id:</strong> #{CGI.escapeHTML(public_id)}</li>
            <li><strong>media_item_id:</strong> #{item.id}</li>
          </ul>

          <form action="#{action_url}" method="post" enctype="multipart/form-data">
            <input type="hidden" name="authenticity_token" value="#{form_authenticity_token}">

            <p>
              <label>Leaked file: <input type="file" name="file" required></label>
            </p>

            <p>
              <label>Max samples (frames): <input type="number" name="max_samples" value="60" min="5" max="200"></label>
            </p>

            <p>
              <label>Max offset segments to scan: <input type="number" name="max_offset_segments" value="30" min="0" max="300"></label>
            </p>

            <p>
              <label>Layout override (optional):
                <select name="layout">
                  <option value="">auto</option>
                  <option value="v1_tiles">v1_tiles</option>
                  <option value="v2_pairs">v2_pairs</option>
                  <option value="v3_pairs">v3_pairs</option>
                </select>
              </label>
            </p>

            <p>
              <button class="btn btn-primary" type="submit">Identify</button>
            </p>
          </form>

          <p style="opacity:0.75">
            Tip: if confidence is low, try using a copy that is closer to the original HLS download (less re-encoded).
          </p>
        </div>
      HTML

      render html: html.html_safe, layout: "no_ember"
    end


    # POST /admin/plugins/media-gallery/forensics-identify/:public_id/queue(.json)
    # Queues file-mode identification in a background job to avoid web/proxy timeouts.
    def queue
      public_id = params[:public_id].to_s
      public_id = public_id.sub(/\.(json|html)\z/i, "")
      public_id = public_id.strip
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      if item.blank?
        return render json: { ok: false, error: "unknown_public_id", error_class: "Discourse::NotFound" }, status: 422
      end

      file = params[:file]
      return render json: { ok: false, error: "missing_file", error_class: "Discourse::InvalidParameters" }, status: 422 if file.blank?

      max_samples = params[:max_samples].to_i
      max_samples = 60 if max_samples <= 0
      max_samples = [max_samples, 200].min

      max_offset = params[:max_offset_segments].to_i
      max_offset = 30 if max_offset.negative?
      max_offset = [max_offset, 300].min

      layout = params[:layout].to_s.presence

      task_id = ::MediaGallery::ForensicsIdentifyTasks.create_file_task!(
        public_id: item.public_id,
        media_item_id: item.id,
        upload: file,
        max_samples: max_samples,
        max_offset_segments: max_offset,
        layout: layout,
      )

      ::Jobs.enqueue(:media_gallery_forensics_identify_job, task_id: task_id)

      render_json_dump(
        ok: true,
        task_id: task_id,
        status: "queued",
        status_url: "/admin/plugins/media-gallery/forensics-identify/status/#{task_id}",
      )
    rescue => e
      debug_id = "mgfiq_#{SecureRandom.hex(6)}"
      begin
        Rails.logger.error("[media_gallery] forensics identify queue failed debug_id=#{debug_id} public_id=#{params[:public_id]} #{e.class}: #{e.message}")
        Rails.logger.error(Array(e.backtrace).first(20).join("
")) if e.backtrace.present?
      rescue
        nil
      end
      render json: { ok: false, error: "#{e.class}: #{e.message}", error_class: e.class.name, debug_id: debug_id }, status: 500
    end

    # GET /admin/plugins/media-gallery/forensics-identify/status/:task_id(.json)
    def status
      task = ::MediaGallery::ForensicsIdentifyTasks.read_task(params[:task_id].to_s)
      raise Discourse::NotFound if task.blank?

      render_json_dump(
        ok: true,
        task_id: task["task_id"] || params[:task_id].to_s,
        status: task["status"].presence || "queued",
        result: task["result"],
        error: task["error"],
        public_id: task["public_id"],
      )
    rescue => e
      render json: { ok: false, error: "#{e.class}: #{e.message}", error_class: e.class.name }, status: 404
    end

    # POST /admin/plugins/media-gallery/forensics-identify/:public_id(.json)
    # Accepts either:
    # - file: uploaded leak copy
    # - source_url: URL to a variant playlist (.m3u8) or direct media URL (admin-only helper)
    def identify
      public_id = params[:public_id].to_s
      public_id = public_id.sub(/\.(json|html)\z/i, "")
      public_id = public_id.strip
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      if item.blank?
        return render json: { errors: ["unknown_public_id", public_id] }, status: 422
      end

      max_samples = params[:max_samples].to_i
      max_samples = 60 if max_samples <= 0
      max_samples = [max_samples, 200].min

      max_offset = params[:max_offset_segments].to_i
      max_offset = 30 if max_offset.negative?
      max_offset = [max_offset, 300].min

      layout = params[:layout].to_s.presence

      # Admin convenience: if URL mode is used and the initial result is weak,
      # we can automatically retry with a longer sample / more samples.
      auto_extend = params[:auto_extend].to_s
      auto_extend = (auto_extend == "1" || auto_extend.casecmp("true").zero?)

      seg = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      seg = 6 if seg <= 0

      source_url = params[:source_url].to_s.strip.presence

      temps = []
      result = nil
      filemode_soft_budget_seconds = setting_filemode_soft_time_budget_seconds
      filemode_engine_budget_seconds = setting_filemode_engine_time_budget_seconds(soft_budget_seconds: filemode_soft_budget_seconds)

      base_meta = {
        requested_max_samples: max_samples,
        max_offset_segments: max_offset,
        configured_filemode_soft_time_budget_seconds: filemode_soft_budget_seconds,
        configured_filemode_engine_time_budget_seconds: filemode_engine_budget_seconds,
      }

      if source_url.present?
        begin
          result, meta_patch, temps = identify_from_source_url(
            source_url,
            media_item: item,
            max_samples: max_samples,
            max_offset_segments: max_offset,
            layout: layout,
            segment_seconds: seg,
            auto_extend: auto_extend
          )

          meta_patch = base_meta.merge(meta_patch || {})
        rescue => e
          # Include the reason in the error payload so the admin UI can display it.
          msg = e.message.to_s.strip
          msg = msg[0, 400] if msg.length > 400
          return render json: { errors: ["invalid_source_url", msg].compact }, status: 422
        end
      else
        file = params[:file]
        return render json: { errors: ["missing_file_or_url"] }, status: 422 if file.blank?

        path = file.respond_to?(:tempfile) ? file.tempfile&.path : nil
        return render json: { errors: ["missing_file_or_url"] }, status: 422 if path.blank? || !File.exist?(path)

        file_bytes = (File.size(path) rescue 0).to_i
        file_mb = (file_bytes / (1024.0 * 1024.0)).round(1)

        capped_max_samples = max_samples
        if file_mb >= FILEMODE_AUTOCAP_MB_3
          capped_max_samples = [capped_max_samples, 25].min
        elsif file_mb >= FILEMODE_AUTOCAP_MB_2
          capped_max_samples = [capped_max_samples, 35].min
        elsif file_mb >= FILEMODE_AUTOCAP_MB_1
          capped_max_samples = [capped_max_samples, 45].min
        end

        identify_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          Timeout.timeout(filemode_soft_budget_seconds) do
            result = ::MediaGallery::ForensicsIdentify.identify_from_file(
              media_item: item,
              file_path: path,
              max_samples: capped_max_samples,
              max_offset_segments: max_offset,
              layout: layout,
              time_budget_seconds: filemode_engine_budget_seconds
            )
          end
        rescue Timeout::Error
          result = {
            meta: {
              public_id: item.public_id,
              media_item_id: item.id,
              decision: "timeout",
              conclusive: false,
              timeout_kind: "filemode_soft_budget",
              likely_timeout_layer: "discourse_web_worker_or_reverse_proxy",
              recommendation: "raise_filemode_budget_or_infrastructure_timeouts",
              user_message: "Analyse bereikte de ingestelde file-mode tijdslimiet (soft=#{filemode_soft_budget_seconds}s, engine=#{filemode_engine_budget_seconds}s). Op Discourse is de backend-timeout in productie vaak ~30s; verhoog deze budgets alleen samen met je infrastructuur-timeouts (bijv. Unicorn/web worker en eventuele reverse proxy).",
            },
            observed: { variants: "", confidences: [] },
            candidates: [],
          }
        rescue => e
          debug_id = "mgfi_#{SecureRandom.hex(6)}"
          Rails.logger.error(
            "[media_gallery] forensics identify failed debug_id=#{debug_id} public_id=#{public_id} #{e.class}: #{e.message}\n" \
            "#{Array(e.backtrace).first(20).join("\n")}" \
          ) rescue nil

          # Return 200 with structured error for inline display.
          result = {
            meta: {
              public_id: item.public_id,
              media_item_id: item.id,
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
          base_meta[:file_size_mb] = file_mb
          base_meta[:max_samples_autocapped] = (capped_max_samples != max_samples)
          base_meta[:effective_max_samples] = capped_max_samples
          base_meta[:filemode_elapsed_seconds] = elapsed.round(3)
        end

        meta_patch = base_meta.merge(
          attempts: 1,
          auto_extended: false,
          max_samples_used: base_meta[:effective_max_samples] || max_samples
        )
      end

      result = result.deep_stringify_keys if result.respond_to?(:deep_stringify_keys)
      result["meta"] ||= {}
      meta_patch.each { |k, v| result["meta"][k.to_s] = v }

      apply_no_signal_guard!(result)

      begin
        apply_decision_policy!(result)
      rescue => e
        debug_id = "mgfi_policy_#{SecureRandom.hex(6)}"
        Rails.logger.error("[media_gallery] forensics policy failed debug_id=#{debug_id} #{e.class}: #{e.message}") rescue nil
        result["meta"]["decision"] = "error"
        result["meta"]["conclusive"] = false
        result["meta"]["debug_id"] = debug_id
        result["meta"]["user_message"] ||= "Interne fout tijdens scoreberekening (debug_id=#{debug_id})."
      end

      begin
        render_json_dump(result)
      rescue => e
        debug_id = "mgfi_render_#{SecureRandom.hex(6)}"
        Rails.logger.error("[media_gallery] forensics render failed debug_id=#{debug_id} #{e.class}: #{e.message}") rescue nil
        render json: result, status: 200
      end
    ensure
      temps&.each { |t| t&.close! rescue nil }
    end

    private

    # Defaults used if site settings are unset/invalid.
    DEFAULT_MAX_URL_SAMPLE_SECONDS = 1800
    DEFAULT_MAX_AUTO_EXTEND_SAMPLES = 200
    DEFAULT_AUTO_EXTEND_MIN_USABLE = 12
    DEFAULT_AUTO_EXTEND_MIN_MATCH = 0.85
    DEFAULT_AUTO_EXTEND_MIN_DELTA = 0.15

    DEFAULT_POLICY_MIN_USABLE_STRONG = 12
    DEFAULT_POLICY_MIN_MATCH_STRONG = 0.85
    DEFAULT_POLICY_MIN_DELTA_STRONG = 0.15
    DEFAULT_POLICY_MAX_MISMATCH_RATE_STRONG = 0.20
    DEFAULT_POLICY_MIN_USABLE_LIKELY = 8
    DEFAULT_POLICY_MIN_MATCH_LIKELY = 0.75
    DEFAULT_POLICY_MIN_DELTA_LIKELY = 0.10
    DEFAULT_POLICY_MIN_USABLE_ANY = 5

    # Some installs use long signed tokens in query strings. 2k is often too small.
    DEFAULT_MAX_SOURCE_URL_LENGTH = 10_000

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

    def setting_max_source_url_length
      v = SiteSetting.media_gallery_forensics_identify_max_source_url_length.to_i
      v = DEFAULT_MAX_SOURCE_URL_LENGTH if v <= 0
      v
    end

    def apply_no_signal_guard!(result)
      return unless result.is_a?(Hash)
      meta = result["meta"]
      return unless meta.is_a?(Hash)

      # Keep terminal outcomes intact.
      preset = meta["decision"].to_s
      return if %w[timeout error].include?(preset)

      # Do not apply to playlist URL-mode: it is exact and should always be conclusive.
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

      # After phase-search / polarity / ECC we can already have meaningful evidence
      # even if one individual guard signal is weak. Only collapse to no-signal when
      # *all* evidence channels are effectively empty.
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
          meta["likely_timeout_layer"] ||= "plugin_budget_before_full_signal"
          meta["recommendation"] = "raise_filemode_budget_or_infrastructure_timeouts"
          meta["user_message"] ||= begin
            msg = "Analyse stopte voordat er genoeg watermark-signaal was opgebouwd"
            parts = []
            parts << "engine=#{engine_budget.to_i}s" if engine_budget > 0
            parts << "soft=#{soft_budget.to_i}s" if soft_budget > 0
            msg += " (#{parts.join(', ')})" if parts.present?
            msg + ". Dit wijst vaker op een tijdslimiet dan op een verkeerd public_id. Verhoog eerst de file-mode budgets in plugin settings; ga alleen richting ~30s of hoger als je ook de Discourse/web-worker timeout en eventuele reverse-proxy timeout verhoogt."
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
    private :apply_no_signal_guard!

    def setting_max_url_sample_seconds
      v = SiteSetting.media_gallery_forensics_identify_max_url_sample_seconds.to_i
      v = DEFAULT_MAX_URL_SAMPLE_SECONDS if v <= 0
      v
    end

    def setting_max_auto_extend_samples
      v = SiteSetting.media_gallery_forensics_identify_max_auto_extend_samples.to_i
      v = DEFAULT_MAX_AUTO_EXTEND_SAMPLES if v <= 0
      v
    end

    def setting_auto_extend_min_usable_samples
      v = SiteSetting.media_gallery_forensics_identify_auto_extend_min_usable_samples.to_i
      v = DEFAULT_AUTO_EXTEND_MIN_USABLE if v.negative?
      v
    end

    def setting_auto_extend_min_match_ratio
      pct = SiteSetting.media_gallery_forensics_identify_auto_extend_min_match_percent.to_i
      pct = (DEFAULT_AUTO_EXTEND_MIN_MATCH * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
    end

    def setting_auto_extend_min_delta_ratio
      pct = SiteSetting.media_gallery_forensics_identify_auto_extend_min_delta_percent.to_i
      pct = (DEFAULT_AUTO_EXTEND_MIN_DELTA * 100).round if pct <= 0
      [[pct, 0].max, 100].min / 100.0
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

    def identify_from_source_url(source_url, media_item:, max_samples:, max_offset_segments:, layout:, segment_seconds:, auto_extend:)
      max_ext = setting_max_auto_extend_samples

      ms = [max_samples.to_i, max_ext].min
      ms = 60 if ms <= 0

      temps = []
      attempts = 0
      best = nil
      best_ms = ms
      started_ms = ms
      best_score = -Float::INFINITY

      # Fast path for fingerprinted HLS playlists:
      # Our authenticated variant playlists embed A/B choices in the segment URLs:
      #   /media/hls/:public_id/seg/:variant/:ab/:seg.ts?token=...
      #
      # If we can parse those choices, we can match fingerprints WITHOUT decoding video.
      # This is both faster and far more robust than pixel sampling, and avoids issues
      # from screen recording, overlays, or re-encoding.
      playlist_variants = nil
      playlist_tmp = nil
      begin
        uri = URI.parse(source_url.to_s.strip) rescue nil
        if uri&.path.to_s.downcase.end_with?(".m3u8")
          begin
            playlist_tmp = localize_hls_playlist_to_tempfile!(uri, media_item: media_item)
          rescue => e
            if e.message.to_s == "unsupported_hls_url"
              playlist_tmp = rewrite_hls_playlist_to_tempfile!(uri)
            else
              raise e
            end
          end
          temps << playlist_tmp if playlist_tmp
          playlist_variants = parse_ab_variants_from_playlist_file(playlist_tmp.path)
          playlist_variants = nil if playlist_variants.blank? || playlist_variants.none?(&:present?)
        end
      rescue
        playlist_variants = nil
      end

      # Up to 3 attempts: requested, doubled, then capped.
      while attempts < 3
        attempts += 1

        begin
          res = nil

          # Prefer playlist-based extraction when available.
          if playlist_variants.present?
            sliced = playlist_variants.first(ms.to_i)
            res = identify_from_observed_variants(
              media_item: media_item,
              observed_variants: sliced,
              max_offset_segments: max_offset_segments,
              layout: layout,
              segment_seconds: segment_seconds,
              source_mode: "hls_playlist"
            )
          else
            tmp = download_source_url_to_tempfile!(
              source_url,
              max_samples: ms,
              segment_seconds: segment_seconds,
              media_item: media_item
            )
            temps << tmp

            res = ::MediaGallery::ForensicsIdentify.identify_from_file(
              media_item: media_item,
              file_path: tmp.path,
              max_samples: ms,
              max_offset_segments: max_offset_segments,
              layout: layout
            )
          end

          score = score_result(res)
          if score > best_score
            best = res
            best_score = score
            best_ms = ms
          end

          # Stop early if we already have a conclusive match.
          break if conclusive_match?(res)

          # Decide whether to retry with more samples.
          break unless auto_extend
          break if ms >= max_ext
          break unless should_auto_extend?(res)

          ms = [ms * 2, max_ext].min
        rescue => e
          # If the first attempt fails, surface the error (so the UI gets a 422 with a reason).
          raise e if best.nil?

          # Otherwise, keep the best we have so far.
          break
        end
      end

      meta_patch = {
        attempts: attempts,
        auto_extended: (attempts > 1 && best_ms != started_ms),
        max_samples_used: best_ms,
      }

      [best, meta_patch, temps]
    end

    def identify_from_observed_variants(media_item:, observed_variants:, max_offset_segments:, layout:, segment_seconds:, source_mode:)
      lay = layout.presence || (::MediaGallery::ForensicsIdentify.detect_layout_for(media_item: media_item) rescue nil)
      lay = lay.presence || "auto"

      match = ::MediaGallery::ForensicsIdentify.match_fingerprints(
        media_item: media_item,
        observed_variants: observed_variants,
        observed_confidences: nil,
        max_offset_segments: max_offset_segments
      )

      meta_from_match = match[:meta] || {}
      if meta_from_match.respond_to?(:deep_stringify_keys)
        meta_from_match = meta_from_match.deep_stringify_keys
      end

      variants = Array(observed_variants)
      usable = variants.count { |v| v.present? }

      result = {
        "meta" => {
          "public_id" => media_item.public_id,
          "media_item_id" => media_item.id,
          "segment_seconds" => segment_seconds.to_i,
          "layout" => lay,
          "duration_seconds" => nil,
          "samples" => variants.length,
          "usable_samples" => usable,
          "source_mode" => source_mode.to_s,
        }.merge(meta_from_match),
        "observed" => {
          "variants" => variants.map { |v| v.presence || "?" }.join,
          "confidences" => [],
        },
        "candidates" => (match[:candidates] || []),
      }

      result
    end

    def parse_ab_variants_from_playlist_file(path)
      raw = File.read(path.to_s)
      return [] if raw.blank?

      out = []

      raw.each_line do |line|
        l = line.to_s.strip
        next if l.blank?

        if l.start_with?("#")
          # Handle EXT-X-MAP (fMP4) if present.
          if l.include?("URI=\"")
            uri = l[/URI=\"([^\"]+)\"/, 1].to_s
            _v = ab_from_path(uri)
            # we do not treat init segments as samples
          end
          next
        end

        out << ab_from_path(l)
      end

      out
    rescue
      []
    end

    def ab_from_path(path)
      p = path.to_s
      m = p.match(%r{/seg/[^/]+/(?<ab>a|b)/}i)
      return m[:ab].to_s.downcase if m

      m = p.match(%r{/hls/(?<ab>a|b)/}i)
      return m[:ab].to_s.downcase if m

      nil
    end

    def score_result(result)
      usable = result.dig("meta", "effective_samples").to_f
      usable = result.dig("meta", "usable_samples").to_i if usable <= 0
      top, second = top_two_match_ratios(result)
      delta = top - second

      # Heuristic score: prioritize higher match ratio, then clearer separation,
      # then more usable samples.
      (top * 100.0) + (delta * 40.0) + (usable * 1.0)
    end

    def should_auto_extend?(result)
      # If we already have a conclusive match, do not extend.
      return false if conclusive_match?(result)

      usable = result.dig("meta", "usable_samples").to_i
      top, second = top_two_match_ratios(result)
      delta = top - second

      return true if usable < setting_auto_extend_min_usable_samples
      return true if top < setting_auto_extend_min_match_ratio
      return true if delta < setting_auto_extend_min_delta_ratio
      false
    end

    def conclusive_match?(result)
      classify_decision(result) == "conclusive_match"
    end

    def apply_decision_policy!(result)
      result["meta"] ||= {}

      # If an earlier guardrail already produced a terminal decision (e.g. no-signal/timeout/error),
      # keep it and avoid overwriting with the normal match policy.
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

    def top_two_match_ratios(result)
      cands = result["candidates"]
      return [0.0, 0.0] unless cands.is_a?(Array) && cands.present?

      top = cands[0].is_a?(Hash) ? cands[0]["match_ratio"].to_f : 0.0
      second = cands[1].is_a?(Hash) ? cands[1]["match_ratio"].to_f : 0.0
      [top, second]
    end

    def download_source_url_to_tempfile!(source_url, max_samples:, segment_seconds:, media_item:)
      url = source_url.to_s.strip
      raise "source_url is blank" if url.blank?
      raise "source_url is too long" if url.length > setting_max_source_url_length

      uri = URI.parse(url) rescue nil
      raise "source_url is not a valid http(s) URL" if uri.blank? || uri.host.blank? || !%w[http https].include?(uri.scheme)

      # Security: only allow URLs on this Discourse host for now.
      # (If you later need CDN support, we can add an allowlist site setting.)
      base_host = (URI.parse(Discourse.base_url).host rescue nil)
      req_host = request&.host
      allowed_hosts = [base_host, req_host].compact.uniq

      unless allowed_hosts.include?(uri.host)
        raise "Only URLs on this site are allowed (#{allowed_hosts.join(', ')})."
      end

      seg = segment_seconds.to_i
      seg = 6 if seg <= 0

      ms = max_samples.to_i
      ms = 60 if ms <= 0
      ms = [ms, 200].min

      # Download just enough to cover the requested samples.
      target_seconds = (ms * seg) + seg
      target_seconds = 30 if target_seconds < 30
      target_seconds = [target_seconds, setting_max_url_sample_seconds].min

      playlist_tmp = nil
      input = url

      # If the URL points at our own authenticated HLS endpoints, avoid making an HTTP
      # request entirely. Those endpoints require a logged-in user session *and* validate
      # the token against current_user (and sometimes IP). When an admin pastes a playback
      # URL, the server-side fetch won't have the member's browser session cookies, which
      # results in redirects/login HTML and ffmpeg failures.
      #
      # Instead, we build a local playlist directly from the packaged files on disk.
      # If the URL isn't one of our HLS endpoints, fall back to a conservative HTTP playlist rewrite.
      if uri.path.to_s.downcase.end_with?(".m3u8")
        begin
          playlist_tmp = localize_hls_playlist_to_tempfile!(uri, media_item: media_item)
        rescue => e
          if e.message.to_s == "unsupported_hls_url"
            playlist_tmp = rewrite_hls_playlist_to_tempfile!(uri)
          else
            raise e
          end
        end
        input = playlist_tmp.path
      end

      tmp = Tempfile.new(["media_gallery_identify_", ".mp4"])
      tmp.binmode

      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-y",
        "-protocol_whitelist",
        "file,http,https,tcp,tls,crypto",
        "-allowed_extensions",
        "ALL",
        "-i",
        input,
        "-t",
        target_seconds.to_s,
        "-c",
        "copy",
        # Only needed when remuxing AAC-in-TS into MP4. Safe to keep, but if it fails
        # on odd inputs, we can later add a re-encode fallback.
        "-bsf:a",
        "aac_adtstoasc",
        tmp.path,
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success? && File.size?(tmp.path)
        tip = "tip: try the *index.m3u8* variant playlist (not master.m3u8)"
        tip << "; if it still fails, the auth token may not be applied to segment URLs" if uri.path.to_s.downcase.end_with?(".m3u8")
        raise "ffmpeg download failed (#{tip}): #{::MediaGallery::Ffmpeg.short_err(stderr)}"
      end

      tmp
    rescue => e
      playlist_tmp&.close! rescue nil
      tmp&.close! rescue nil
      raise e
    end

    # Downloads the playlist text and rewrites all referenced URIs to absolute URLs.
    # If the incoming playlist URL has a `token=...` query param, it will be appended
    # to any referenced URIs that don't already have it.
    def rewrite_hls_playlist_to_tempfile!(playlist_uri)
      token = extract_token_param(playlist_uri)

      body = http_get_text!(playlist_uri)
      raise "playlist did not look like M3U8" unless body.lstrip.start_with?("#EXTM3U")

      base = playlist_uri.dup
      base.fragment = nil
      base.query = nil
      base.path = base.path.to_s.sub(%r{[^/]+\z}, "")

      rewritten = body.each_line.map do |line|
        raw = line.to_s.strip
        next "" if raw.blank?

        if raw.start_with?("#")
          rewrite_quoted_uris_in_tag_line(raw, base, token)
        else
          rewrite_uri_line(raw, base, token)
        end
      end.join("\n")

      tmp = Tempfile.new(["media_gallery_identify_playlist_", ".m3u8"])
      tmp.binmode
      tmp.write(rewritten)
      tmp.write("\n") unless rewritten.end_with?("\n")
      tmp.flush
      tmp
    end

    # Build a local M3U8 that points at absolute files on disk.
    # Supports Discourse-Media-Plugin's HLS URLs, e.g.:
    #   /media/hls/:public_id/v/:variant/index.m3u8?token=...
    #
    # Why this exists:
    # - /media/hls/* endpoints require ensure_logged_in and also validate token vs current_user.
    # - Server-side fetching the URL (Net::HTTP / ffmpeg) does not carry the member's cookies.
    # - So the request often redirects to login HTML, and the playlist "doesn't look like M3U8".
    #
    # Admin-only identify can safely read the packaged HLS files from private storage.
    def localize_hls_playlist_to_tempfile!(playlist_uri, media_item:)
      path = playlist_uri.path.to_s

      # Variant playlist URL
      m = path.match(%r{\A/media/hls/(?<public_id>[\w\-]+)/v/(?<variant>[^/]+)/index\.m3u8\z}i)

      # Master playlist URL (we'll pick a variant from disk)
      master = path.match(%r{\A/media/hls/(?<public_id>[\w\-]+)/master\.m3u8\z}i)

      if m.blank? && master.blank?
        raise "unsupported_hls_url"
      end

      public_id = (m ? m[:public_id] : master[:public_id]).to_s
      variant = m ? m[:variant].to_s : nil

      if public_id != media_item.public_id.to_s
        raise "public_id_mismatch"
      end

      token = extract_token_param(playlist_uri)
      payload = token.present? ? (MediaGallery::Token.verify(token, purpose: "hls") rescue nil) : nil
      fingerprint_id = payload.is_a?(Hash) ? payload["fingerprint_id"].presence : nil
      token_media_item_id = payload.is_a?(Hash) ? payload["media_item_id"].presence : nil

      if token_media_item_id.present? && token_media_item_id.to_i != media_item.id
        raise "token_item_mismatch"
      end

      if variant.blank?
        master_abs = MediaGallery::PrivateStorage.hls_master_abs_path(media_item)
        raise "master_playlist_not_found" if master_abs.blank? || !File.exist?(master_abs)

        master_raw = File.read(master_abs)
        picked = nil
        master_raw.to_s.each_line do |line|
          l = line.to_s.strip
          next if l.blank? || l.start_with?("#")
          v = l.split("/").first.to_s
          if MediaGallery::Hls.variant_allowed?(v)
            picked = v
            break
          end
        end
        raise "no_variant_found_in_master" if picked.blank?
        variant = picked
      end

      abs = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(public_id, variant)
      raise "variant_playlist_not_found" if abs.blank? || !File.exist?(abs)

      raw = File.read(abs)

      rewritten = []
      seg_counter = 0

      raw.to_s.each_line do |line|
        l = line.to_s.rstrip
        if l.blank? || l.start_with?("#")
          # Handle EXT-X-MAP URI for fMP4
          if l.include?("URI=\"")
            rewritten << l.gsub(/URI=\"([^\"]+)\"/) do
              uri_str = Regexp.last_match(1).to_s
              file = File.basename(uri_str)
              local = resolve_segment_abs_path(public_id, variant, file, fingerprint_id: fingerprint_id, media_item_id: media_item.id)
              "URI=\"#{local}\""
            end
          else
            rewritten << l
          end
          next
        end

        seg = File.basename(l)
        if seg =~ /\A[\w\-.]+\.(ts|m4s)\z/i
          local = resolve_segment_abs_path(public_id, variant, seg, fingerprint_id: fingerprint_id, media_item_id: media_item.id, seg_counter: seg_counter)
          seg_counter += 1
          rewritten << local
        else
          # Unknown line type; keep as-is.
          rewritten << l
        end
      end

      out = rewritten.join("\n") + "\n"
      raise "playlist did not look like M3U8" unless out.lstrip.start_with?("#EXTM3U")

      tmp = Tempfile.new(["media_gallery_identify_local_", ".m3u8"])
      tmp.binmode
      tmp.write(out)
      tmp.flush
      tmp
    end

    def resolve_segment_abs_path(public_id, variant, segment, fingerprint_id: nil, media_item_id: nil, seg_counter: nil)
      seg = segment.to_s

      # Prefer A/B-specific files when fingerprinting is enabled and the token contains a fingerprint_id.
      if MediaGallery::Fingerprinting.enabled? && fingerprint_id.present? && media_item_id.present?
        idx = MediaGallery::Fingerprinting.segment_index_from_filename(seg)
        idx ||= seg_counter
        if idx.present?
          ab = MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: fingerprint_id,
            media_item_id: media_item_id,
            segment_index: idx
          )

          if ab.present?
            ab_abs = File.join(MediaGallery::PrivateStorage.private_root, public_id.to_s, "hls", ab.to_s, variant.to_s, seg)
            return ab_abs if File.exist?(ab_abs)
          end
        end
      end

      # Fallback to legacy packaging.
      MediaGallery::PrivateStorage.hls_segment_abs_path(public_id, variant, seg)
    end

    def http_get_text!(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = "DiscourseMediaGalleryForensicsIdentify/1.0"

      # If the URL requires authentication (e.g. ensure_logged_in), forward cookies from
      # the admin's browser session. This makes URL-mode usable for protected endpoints.
      cookie = request&.headers&.[]("Cookie").to_s
      req["Cookie"] = cookie if cookie.present?
      req["Accept"] = "application/vnd.apple.mpegurl, */*"

      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise "playlist HTTP #{res.code}"
      end

      res.body.to_s
    end

    def extract_token_param(uri)
      qs = CGI.parse(uri.query.to_s)
      qs["token"]&.first.presence
    end

    def rewrite_uri_line(value, base_uri, token)
      abs = absolutize_uri(value, base_uri)
      add_token(abs, token)
    end

    # Rewrites URI="..." occurrences in HLS tag lines like EXT-X-KEY, EXT-X-MAP, EXT-X-MEDIA.
    def rewrite_quoted_uris_in_tag_line(line, base_uri, token)
      line.gsub(/URI="([^"]+)"/) do
        original = Regexp.last_match(1)
        abs = absolutize_uri(original, base_uri)
        rewritten = add_token(abs, token)
        "URI=\"#{rewritten}\""
      end
    end

    def absolutize_uri(value, base_uri)
      v = value.to_s
      begin
        u = URI.parse(v)
        if u.scheme.present? && u.host.present?
          u
        else
          URI.join(base_uri.to_s, v)
        end
      rescue
        URI.join(base_uri.to_s, v)
      end
    end

    def add_token(uri, token)
      return uri.to_s if token.blank?

      u = uri.is_a?(URI) ? uri.dup : URI.parse(uri.to_s)
      q = CGI.parse(u.query.to_s)
      q["token"] ||= [token]
      u.query = URI.encode_www_form(q.flat_map { |k, vs| vs.map { |v| [k, v] } })
      u.to_s
    rescue
      uri.to_s
    end
  end
end