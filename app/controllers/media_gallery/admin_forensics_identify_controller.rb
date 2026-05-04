# frozen_string_literal: true

require "cgi"
require "tempfile"
require "uri"
require "open3"
require "net/http"
require "timeout"
require "securerandom"
require "fileutils"
require "tmpdir"
require "digest"

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

    FORENSICS_HLS_TEMP_PREFIX = "media_gallery_forensics_hls_"
    FORENSICS_HLS_TEMP_TTL_SECONDS = 2 * 60 * 60

    def show
      public_id = params[:public_id].to_s
      public_id = public_id.sub(/\.(json|html)\z/i, "")
      public_id = public_id.strip
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      if item.blank?
        return render json: { errors: ["unknown_public_id", public_id] }, status: 422
      end

      action_url = CGI.escapeHTML("/admin/plugins/media-gallery/forensics-identify/#{public_id}.json")
      csrf_token = CGI.escapeHTML(form_authenticity_token.to_s)
      public_id_label = CGI.escapeHTML(public_id)
      media_item_id_label = CGI.escapeHTML(item.id.to_s)

      html = <<~HTML
        <div class="wrap">
          <h1>Media Gallery – Forensics Identify</h1>
          <p>
            Upload a leaked copy of this video to attempt identification.
            This is best-effort and can be affected by re-encoding/cropping.
          </p>

          <ul>
            <li><strong>public_id:</strong> #{public_id_label}</li>
            <li><strong>media_item_id:</strong> #{media_item_id_label}</li>
          </ul>

          <form action="#{action_url}" method="post" enctype="multipart/form-data">
            <input type="hidden" name="authenticity_token" value="#{csrf_token}">

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
      ::MediaGallery::OperationLogger.audit("forensics_identify_queued", item: item, operation: "forensics_identify_queue", user: current_user, request: request, result: "queued", data: { task_id: task_id, max_samples: max_samples, max_offset_segments: max_offset })

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


    # GET /admin/plugins/media-gallery/forensics-identify/overlay-lookup(.json)
    def overlay_lookup
      code = params[:code].to_s.strip.upcase.gsub(/[^A-Z0-9]/, "")
      return render_json_dump(ok: true, matches: []) if code.blank?

      public_id = params[:public_id].to_s.strip.presence
      matches = ::MediaGallery::PlaybackOverlay.lookup_by_code(code: code, public_id: public_id, limit: 25)

      render_json_dump(
        ok: true,
        code: code,
        public_id: public_id,
        matches: matches
      )
    rescue => e
      render json: { ok: false, error: "#{e.class}: #{e.message}", error_class: e.class.name }, status: 500
    end

    def preflight
      public_id = params[:public_id].to_s.sub(/\.(json|html)\z/i, "").strip
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      return render json: { ok: false, error: "unknown_public_id" }, status: 422 if item.blank?

      source_url = params[:source_url].to_s.strip.presence
      return render json: { ok: false, error: "missing_source_url" }, status: 422 if source_url.blank?
      return render json: { ok: false, error: "source_url_too_long" }, status: 422 if source_url.length > setting_max_source_url_length

      uri = URI.parse(source_url) rescue nil
      checks = []
      begin
        ensure_source_url_allowed!(uri, context: "source_url")
        checks << { status: "ok", label: "URL policy", message: "Source URL is allowed by the configured HTTP source URL policy." }
      rescue => e
        checks << { status: "critical", label: "URL policy", message: source_url_validation_message(e.message) }
      end

      if uri&.path.to_s.downcase.end_with?(".m3u8")
        begin
          tmp = localize_hls_playlist_to_tempfile!(uri, media_item: item)
          body = File.read(tmp.path) rescue ""
          tmp.close! rescue nil
          checks << { status: body.lstrip.start_with?("#EXTM3U") ? "ok" : "warning", label: "Playlist", message: body.lstrip.start_with?("#EXTM3U") ? "Playlist can be resolved and localized." : "Playlist resolved but did not look like M3U8." }
        rescue => e
          if e.message.to_s == "unsupported_hls_url" && !setting_forensics_allow_remote_hls_playlist_fetch?
            checks << { status: "warning", label: "Playlist", message: source_url_validation_message("remote_hls_playlist_fetch_disabled") }
          else
            checks << { status: "critical", label: "Playlist", message: e.message.to_s.truncate(300) }
          end
        end
      else
        checks << { status: "ok", label: "Mode", message: "Direct media URL mode will be used. Full FFmpeg analysis is not run during preflight." }
      end

      status = checks.any? { |row| row[:status] == "critical" } ? "critical" : (checks.any? { |row| row[:status] == "warning" } ? "warning" : "ok")
      ::MediaGallery::OperationLogger.audit("forensics_identify_preflight", item: item, operation: "forensics_preflight", user: current_user, request: request, result: status, data: { source_kind: uri&.path.to_s.downcase.end_with?(".m3u8") ? "hls_playlist" : "direct_media" })
      render_json_dump(ok: status != "critical", status: status, public_id: item.public_id, checks: checks)
    rescue => e
      render json: { ok: false, error: "#{e.class}: #{e.message}", error_class: e.class.name }, status: 422
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
          capped_max_samples = [capped_max_samples, 35].min
        elsif file_mb >= FILEMODE_AUTOCAP_MB_2
          capped_max_samples = [capped_max_samples, 45].min
        elsif file_mb >= FILEMODE_AUTOCAP_MB_1
          capped_max_samples = [capped_max_samples, 55].min
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
              user_message: "Analysis reached the configured file-mode time limit (soft=#{filemode_soft_budget_seconds}s, engine=#{filemode_engine_budget_seconds}s). In production, the Discourse backend timeout is often around 30s; only raise these budgets together with your infrastructure timeouts (for example Unicorn/web worker and any reverse proxy).",
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
              user_message: "Internal error during analysis (debug_id=#{debug_id}). Check production.log for details.",
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
        apply_statistical_confidence!(result)
      rescue => e
        Rails.logger.warn("[media_gallery] forensics stats enrichment failed #{e.class}: #{e.message}") rescue nil
      end

      begin
        apply_decision_policy!(result)
      rescue => e
        debug_id = "mgfi_policy_#{SecureRandom.hex(6)}"
        Rails.logger.error("[media_gallery] forensics policy failed debug_id=#{debug_id} #{e.class}: #{e.message}") rescue nil
        result["meta"]["decision"] = "error"
        result["meta"]["conclusive"] = false
        result["meta"]["debug_id"] = debug_id
        result["meta"]["user_message"] ||= "Internal error during score calculation (debug_id=#{debug_id})."
      end

      begin
        ::MediaGallery::OperationLogger.audit("forensics_identify_run", item: item, operation: "forensics_identify", user: current_user, request: request, result: result.dig("meta", "decision"), data: { source_mode: result.dig("meta", "source_mode"), auto_extend: auto_extend })
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
            msg = "Analysis stopped before enough watermark signal was accumulated"
            parts = []
            parts << "engine=#{engine_budget.to_i}s" if engine_budget > 0
            parts << "soft=#{soft_budget.to_i}s" if soft_budget > 0
            msg += " (#{parts.join(', ')})" if parts.present?
            msg + ". This more often points to a timeout than to a wrong public_id. Increase the file-mode budgets in plugin settings first; only go towards ~30s or higher if you also increase the Discourse/web-worker timeout and any reverse-proxy timeout."
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

    def decision_policy_thresholds_for(result, mode:)
      thresholds = {
        min_usable_any: setting_policy_min_usable_any,
        min_usable_strong: setting_policy_min_usable_strong,
        min_match_strong: setting_policy_min_match_strong_ratio,
        min_delta_strong: setting_policy_min_delta_strong_ratio,
        max_mismatch_rate_strong: setting_policy_max_mismatch_rate_strong_ratio,
        min_usable_likely: setting_policy_min_usable_likely,
        min_match_likely: setting_policy_min_match_likely_ratio,
        min_delta_likely: setting_policy_min_delta_likely_ratio,
        min_consistent_chunks_strong: 0,
        min_consistent_chunks_likely: 0,
        min_shortlist_gap_strong: 0.0,
        min_shortlist_gap_likely: 0.0,
        filemode_hardened: (mode == "file_mode"),
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
        v8_weighted_top_ratio_sparse_longform_conclusive: 0.62,
        v8_weighted_delta_sparse_longform_conclusive: 0.06,
        v8_raw_delta_sparse_longform_floor: 0.02,
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
        v8_pairwise_win_advantage_recovery_hq_conclusive: 3,
        v8_min_top_adaptive_ratio_recovery_hq_conclusive: 0.66,
        v8_min_adaptive_delta_recovery_hq_conclusive: 0.10,
        v8_min_top_high_quality_ratio_recovery_hq_conclusive: 0.70,
        v8_min_high_quality_support_ratio_recovery_hq_conclusive: 0.50,
        v8_targeted_fill_score_gain_recovery_hq_max: 2.6,
        v8_sync_anchor_ratio_recovery_hq_fill_hardened: 0.34,
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
      return thresholds unless mode == "file_mode"

      thresholds[:min_usable_strong] = [thresholds[:min_usable_strong], 16].max
      thresholds[:min_match_strong] = [thresholds[:min_match_strong], 0.90].max
      thresholds[:min_delta_strong] = [thresholds[:min_delta_strong], 0.18].max
      thresholds[:max_mismatch_rate_strong] = [thresholds[:max_mismatch_rate_strong], 0.15].min
      thresholds[:min_usable_likely] = [thresholds[:min_usable_likely], 12].max
      thresholds[:min_match_likely] = [thresholds[:min_match_likely], 0.82].max
      thresholds[:min_delta_likely] = [thresholds[:min_delta_likely], 0.14].max
      thresholds[:min_consistent_chunks_strong] = 2
      thresholds[:min_consistent_chunks_likely] = 2
      thresholds[:min_shortlist_gap_strong] = 0.75
      thresholds[:min_shortlist_gap_likely] = 0.35

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

        if available <= 12
          thresholds[:min_consistent_chunks_strong] = 1
          thresholds[:min_consistent_chunks_likely] = 1
          thresholds[:min_shortlist_gap_strong] = 0.55
          thresholds[:min_shortlist_gap_likely] = 0.20
        end
      end

      thresholds
    rescue
      thresholds
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

        thresholds = decision_policy_thresholds_for(result, mode: (result.dig("meta", "source_mode").to_s == "hls_playlist" ? "hls_playlist" : "file_mode"))
        result["meta"]["policy"] ||= {
          "min_usable_any" => thresholds[:min_usable_any],
          "min_usable_strong" => thresholds[:min_usable_strong],
          "min_match_strong" => thresholds[:min_match_strong],
          "min_delta_strong" => thresholds[:min_delta_strong],
          "max_mismatch_rate_strong" => thresholds[:max_mismatch_rate_strong],
          "min_usable_likely" => thresholds[:min_usable_likely],
          "min_match_likely" => thresholds[:min_match_likely],
          "min_delta_likely" => thresholds[:min_delta_likely],
          "min_consistent_chunks_strong" => thresholds[:min_consistent_chunks_strong],
          "min_consistent_chunks_likely" => thresholds[:min_consistent_chunks_likely],
          "min_shortlist_gap_strong" => thresholds[:min_shortlist_gap_strong],
          "min_shortlist_gap_likely" => thresholds[:min_shortlist_gap_likely],
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
        "v8_weighted_top_ratio_sparse_longform_conclusive" => thresholds[:v8_weighted_top_ratio_sparse_longform_conclusive],
        "v8_weighted_delta_sparse_longform_conclusive" => thresholds[:v8_weighted_delta_sparse_longform_conclusive],
        "v8_raw_delta_sparse_longform_floor" => thresholds[:v8_raw_delta_sparse_longform_floor],
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
        "v8_pairwise_win_advantage_recovery_hq_conclusive" => thresholds[:v8_pairwise_win_advantage_recovery_hq_conclusive],
        "v8_min_top_adaptive_ratio_recovery_hq_conclusive" => thresholds[:v8_min_top_adaptive_ratio_recovery_hq_conclusive],
        "v8_min_adaptive_delta_recovery_hq_conclusive" => thresholds[:v8_min_adaptive_delta_recovery_hq_conclusive],
        "v8_min_top_high_quality_ratio_recovery_hq_conclusive" => thresholds[:v8_min_top_high_quality_ratio_recovery_hq_conclusive],
        "v8_min_high_quality_support_ratio_recovery_hq_conclusive" => thresholds[:v8_min_high_quality_support_ratio_recovery_hq_conclusive],
        "v8_targeted_fill_score_gain_recovery_hq_max" => thresholds[:v8_targeted_fill_score_gain_recovery_hq_max],
        "v8_sync_anchor_ratio_recovery_hq_fill_hardened" => thresholds[:v8_sync_anchor_ratio_recovery_hq_fill_hardened],
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

        result["meta"]["recommendation"] ||= "gather_longer_sample_or_try_url_mode"
        return
      end

      decision_info = classify_decision_with_reasons(result)
      decision = decision_info[:decision]
      top = decision_info[:top_ratio].to_f
      second = decision_info[:second_ratio].to_f
      delta = decision_info[:delta].to_f
      mismatches = decision_info[:mismatches].to_i
      compared = decision_info[:compared].to_i
      mismatch_rate = decision_info[:mismatch_rate].to_f

      result["meta"]["decision"] = decision
      result["meta"]["conclusive"] = (decision == "conclusive_match")
      result["meta"]["top_match_ratio"] = top
      result["meta"]["second_match_ratio"] = second
      result["meta"]["match_delta"] = delta
      result["meta"]["top_mismatches"] = mismatches
      result["meta"]["top_compared"] = compared
      result["meta"]["top_mismatch_rate"] = mismatch_rate
      result["meta"]["top_evidence_score"] = decision_info[:top_evidence_score].to_f.round(4)
      result["meta"]["top_consistent_chunks"] = decision_info[:top_consistent_chunks].to_i
      result["meta"]["shortlist_evidence_gap"] = decision_info[:shortlist_evidence_gap].to_f.round(4)
      result["meta"]["decision_reasons"] = Array(decision_info[:reasons])
      result["meta"]["decision_mode"] = decision_info[:mode]
      result["meta"]["v8_pairwise_conclusive_basis"] = decision_info[:v8_pairwise_conclusive_basis] if decision_info[:v8_pairwise_conclusive_basis].present?

      thresholds = decision_policy_thresholds_for(result, mode: decision_info[:mode])
      result["meta"]["policy"] = {
        "min_usable_any" => thresholds[:min_usable_any],
        "min_usable_strong" => thresholds[:min_usable_strong],
        "min_match_strong" => thresholds[:min_match_strong],
        "min_delta_strong" => thresholds[:min_delta_strong],
        "max_mismatch_rate_strong" => thresholds[:max_mismatch_rate_strong],
        "min_usable_likely" => thresholds[:min_usable_likely],
        "min_match_likely" => thresholds[:min_match_likely],
        "min_delta_likely" => thresholds[:min_delta_likely],
        "min_consistent_chunks_strong" => thresholds[:min_consistent_chunks_strong],
        "min_consistent_chunks_likely" => thresholds[:min_consistent_chunks_likely],
        "min_shortlist_gap_strong" => thresholds[:min_shortlist_gap_strong],
        "min_shortlist_gap_likely" => thresholds[:min_shortlist_gap_likely],
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
      classify_decision_with_reasons(result)[:decision]
    end

    def classify_decision_with_reasons(result)
      usable = result.dig("meta", "usable_samples").to_i
      cands = result["candidates"]
      has_cands = cands.is_a?(Array) && cands.present?

      reasons = []
      mode = (result.dig("meta", "source_mode").to_s == "hls_playlist") ? "hls_playlist" : "file_mode"

      if usable < setting_policy_min_usable_any
        reasons << "usable_samples=#{usable} < #{setting_policy_min_usable_any}"
        return {
          decision: "insufficient_samples",
          reasons: reasons,
          mode: mode,
          top_ratio: 0.0,
          second_ratio: 0.0,
          delta: 0.0,
          mismatches: 0,
          compared: 0,
          mismatch_rate: 1.0,
          top_evidence_score: 0.0,
          top_consistent_chunks: 0,
          shortlist_evidence_gap: 0.0,
        }
      end

      unless has_cands
        reasons << "no_candidates"
        return {
          decision: "no_match",
          reasons: reasons,
          mode: mode,
          top_ratio: 0.0,
          second_ratio: 0.0,
          delta: 0.0,
          mismatches: 0,
          compared: 0,
          mismatch_rate: 1.0,
          top_evidence_score: 0.0,
          top_consistent_chunks: 0,
          shortlist_evidence_gap: 0.0,
        }
      end

      top_cand = cands[0].is_a?(Hash) ? cands[0] : {}
      second_cand = cands[1].is_a?(Hash) ? cands[1] : {}

      top = candidate_match_ratio(top_cand)
      second = candidate_match_ratio(second_cand)
      delta = top - second

      mismatches = top_cand["mismatches"].to_i
      compared = top_cand["compared"].to_i
      mismatch_rate = compared > 0 ? (mismatches.to_f / compared.to_f) : 1.0
      top_evidence_score = top_cand["evidence_score"].to_f
      meta_top_evidence_score = result.dig("meta", "shortlist_top_evidence_score").to_f
      top_evidence_score = [top_evidence_score, meta_top_evidence_score].max
      top_consistent_chunks = top_cand["evidence_consistent_chunks"].to_i
      top_consistent_chunks = result.dig("meta", "top_consistent_chunks").to_i if top_consistent_chunks <= 0
      shortlist_evidence_gap = result.dig("meta", "shortlist_evidence_gap").to_f

      thresholds = decision_policy_thresholds_for(result, mode: mode)
      strong_usable = thresholds[:min_usable_strong]
      strong_match = thresholds[:min_match_strong]
      strong_delta = thresholds[:min_delta_strong]
      strong_mismatch = thresholds[:max_mismatch_rate_strong]
      likely_usable = thresholds[:min_usable_likely]
      likely_match = thresholds[:min_match_likely]
      likely_delta = thresholds[:min_delta_likely]

      strong_ok = true
      if usable < strong_usable
        strong_ok = false
        reasons << "usable_samples=#{usable} < strong=#{strong_usable}"
      end
      if top < strong_match
        strong_ok = false
        reasons << "top_match=#{top.round(4)} < strong=#{strong_match.round(4)}"
      end
      if delta < strong_delta
        strong_ok = false
        reasons << "delta=#{delta.round(4)} < strong=#{strong_delta.round(4)}"
      end
      if mismatch_rate > strong_mismatch
        strong_ok = false
        reasons << "mismatch_rate=#{mismatch_rate.round(4)} > strong=#{strong_mismatch.round(4)}"
      end
      if mode == "file_mode"
        if top_evidence_score < 4.0
          strong_ok = false
          reasons << "evidence_score=#{top_evidence_score.round(4)} < strong=4.0"
        end
        if top_consistent_chunks < thresholds[:min_consistent_chunks_strong]
          strong_ok = false
          reasons << "stable_chunks=#{top_consistent_chunks} < strong=#{thresholds[:min_consistent_chunks_strong]}"
        end
        if shortlist_evidence_gap < thresholds[:min_shortlist_gap_strong]
          strong_ok = false
          reasons << "shortlist_gap=#{shortlist_evidence_gap.round(4)} < strong=#{thresholds[:min_shortlist_gap_strong].round(4)}"
        end
      end

      v8_pairwise_info = if mode == "file_mode"
        v8_pairwise_conclusive_info(result, thresholds: thresholds, top_cand: top_cand, second_cand: second_cand, mismatch_rate: mismatch_rate)
      else
        { used: false, basis: nil, reason: nil }
      end

      if v8_pairwise_info[:used]
        return {
          decision: "conclusive_match",
          reasons: [v8_pairwise_info[:reason]],
          mode: mode,
          top_ratio: top,
          second_ratio: second,
          delta: delta,
          mismatches: mismatches,
          compared: compared,
          mismatch_rate: mismatch_rate,
          top_evidence_score: top_evidence_score,
          top_consistent_chunks: top_consistent_chunks,
          shortlist_evidence_gap: shortlist_evidence_gap,
          v8_pairwise_conclusive_basis: v8_pairwise_info[:basis],
        }
      end

      if strong_ok
        return {
          decision: "conclusive_match",
          reasons: ["all_strong_thresholds_passed"],
          mode: mode,
          top_ratio: top,
          second_ratio: second,
          delta: delta,
          mismatches: mismatches,
          compared: compared,
          mismatch_rate: mismatch_rate,
          top_evidence_score: top_evidence_score,
          top_consistent_chunks: top_consistent_chunks,
          shortlist_evidence_gap: shortlist_evidence_gap,
        }
      end

      likely_ok = true
      if usable < likely_usable
        likely_ok = false
      end
      if top < likely_match
        likely_ok = false
      end
      if delta < likely_delta
        likely_ok = false
      end
      if mode == "file_mode"
        likely_ok &&= (mismatch_rate <= 0.22)
        likely_ok &&= (top_evidence_score >= 2.5)
        likely_ok &&= (top_consistent_chunks >= thresholds[:min_consistent_chunks_likely])
        likely_ok &&= (shortlist_evidence_gap >= thresholds[:min_shortlist_gap_likely])
      end

      if likely_ok
        return {
          decision: "likely_match",
          reasons: [mode == "file_mode" ? "file_mode_guardrails_passed" : "likely_thresholds_passed"],
          mode: mode,
          top_ratio: top,
          second_ratio: second,
          delta: delta,
          mismatches: mismatches,
          compared: compared,
          mismatch_rate: mismatch_rate,
          top_evidence_score: top_evidence_score,
          top_consistent_chunks: top_consistent_chunks,
          shortlist_evidence_gap: shortlist_evidence_gap,
        }
      end

      {
        decision: "ambiguous",
        reasons: reasons.presence || ["top_candidate_not_separated_enough"],
        mode: mode,
        top_ratio: top,
        second_ratio: second,
        delta: delta,
        mismatches: mismatches,
        compared: compared,
        mismatch_rate: mismatch_rate,
        top_evidence_score: top_evidence_score,
        top_consistent_chunks: top_consistent_chunks,
        shortlist_evidence_gap: shortlist_evidence_gap,
      }
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
      adaptive_metrics = adaptive_quality_metrics(result)
      pairwise_support = v8_pairwise_support_metrics(top_cand)
      decisive_chunks = pairwise_support[:decisive_chunks].to_i
      win_advantage = pairwise_support[:win_advantage].to_i
      top_margin_median = pairwise_support[:margin_median].to_f
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
      weighted_top_ratio = top_cand["match_ratio_weighted"].to_f
      weighted_second_ratio = second_cand["match_ratio_weighted"].to_f
      weighted_delta = result.dig("meta", "offset_delta").to_f
      raw_delta = top_ratio - second_ratio
      sync_ratio = result.dig("meta", "sync_anchor_best_ratio").to_f
      sync_used = result.dig("meta", "sync_anchor_used") == true
      discriminative_used = result.dig("meta", "discriminative_shortlist_decoder_used") == true
      discriminative_margin = top_cand["discriminative_margin_total"].to_f

      return { used: false, basis: nil, reason: nil } if mismatch_rate > thresholds[:v8_max_mismatch_rate_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if top_margin < thresholds[:v8_pairwise_margin_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if top_wins < thresholds[:v8_pairwise_wins_conclusive].to_i
      return { used: false, basis: nil, reason: nil } if top_wins < (top_losses + 4)
      return { used: false, basis: nil, reason: nil } if rank_gap < thresholds[:v8_rank_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if evidence_gap < thresholds[:v8_evidence_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if top_rank < thresholds[:v8_evidence_gap_conclusive].to_f
      return { used: false, basis: nil, reason: nil } if second_rank > 0.0 && second_evidence > 0.0
      return { used: false, basis: nil, reason: nil } if discriminative_used && discriminative_margin < -0.25

      if sync_used && sync_ratio >= thresholds[:v8_sync_anchor_ratio_conclusive].to_f
        return {
          used: true,
          basis: "sync_anchor_pairwise",
          reason: "v8_pairwise_artifact_policy_passed",
        }
      end

      anchorless_ok = true
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

      recovery_hq_ok = true
      recovery_hq_ok &&= sync_used
      recovery_hq_ok &&= (sync_ratio >= thresholds[:v8_sync_anchor_ratio_recovery_conclusive].to_f)
      recovery_hq_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_recovery].to_f)
      recovery_hq_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_recovery_conclusive].to_f)
      recovery_hq_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_recovery_conclusive].to_i)
      recovery_hq_ok &&= (win_advantage >= thresholds[:v8_pairwise_win_advantage_recovery_hq_conclusive].to_i)
      recovery_hq_ok &&= (top_margin_median >= 0.20)
      recovery_hq_ok &&= (decisive_chunks >= 7)
      recovery_hq_ok &&= (top_losses <= 2)
      recovery_hq_ok &&= (rank_gap >= thresholds[:v8_rank_gap_recovery_conclusive].to_f)
      recovery_hq_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_recovery_conclusive].to_f)
      recovery_hq_ok &&= (raw_delta >= thresholds[:v8_match_delta_recovery_conclusive].to_f)
      recovery_hq_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_recovery_conclusive].to_f)
      recovery_hq_ok &&= (second_ratio <= thresholds[:v8_second_match_recovery_max].to_f)
      recovery_hq_ok &&= (top_ratio >= thresholds[:v8_min_top_ratio_recovery_conclusive].to_f)
      recovery_hq_ok &&= (top_consistent >= 2)
      recovery_hq_ok &&= (second_consistent <= 2)
      recovery_hq_ok &&= (second_evidence <= -6.0)
      recovery_hq_ok &&= (adaptive_metrics[:top_adaptive_ratio] >= thresholds[:v8_min_top_adaptive_ratio_recovery_hq_conclusive].to_f)
      recovery_hq_ok &&= (adaptive_metrics[:adaptive_delta] >= thresholds[:v8_min_adaptive_delta_recovery_hq_conclusive].to_f)
      recovery_hq_ok &&= (adaptive_metrics[:top_high_quality_ratio] >= thresholds[:v8_min_top_high_quality_ratio_recovery_hq_conclusive].to_f)
      recovery_hq_ok &&= (adaptive_metrics[:support_ratio] >= thresholds[:v8_min_high_quality_support_ratio_recovery_hq_conclusive].to_f)

      if result.dig("meta", "targeted_fill_applied") == true
        recovery_hq_ok &&= (result.dig("meta", "targeted_fill_score_gain").to_f <= thresholds[:v8_targeted_fill_score_gain_recovery_hq_max].to_f)
        recovery_hq_ok &&= (sync_ratio >= thresholds[:v8_sync_anchor_ratio_recovery_hq_fill_hardened].to_f)
      end

      if recovery_hq_ok
        return {
          used: true,
          basis: "sync_anchor_pairwise_recovery_high_quality",
          reason: "v8_pairwise_recovery_high_quality_policy_passed",
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

      sparse_weighted_ok = true
      sparse_weighted_ok &&= !sync_used
      sparse_weighted_ok &&= (thresholds[:observable_capacity].to_i >= thresholds[:v8_min_observable_capacity_sparse_longform_conclusive].to_i)
      sparse_weighted_ok &&= (top_margin >= thresholds[:v8_pairwise_margin_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (top_wins >= thresholds[:v8_pairwise_wins_sparse_longform_conclusive].to_i)
      sparse_weighted_ok &&= (top_losses <= 1)
      sparse_weighted_ok &&= (rank_gap >= thresholds[:v8_rank_gap_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (evidence_gap >= thresholds[:v8_evidence_gap_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (top_consistent >= thresholds[:v8_min_consistent_chunks_sparse_longform_conclusive].to_i)
      sparse_weighted_ok &&= (top_evidence >= thresholds[:v8_min_top_evidence_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (second_evidence <= thresholds[:v8_max_second_evidence_sparse_longform].to_f)
      sparse_weighted_ok &&= (weighted_top_ratio >= thresholds[:v8_weighted_top_ratio_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (weighted_delta >= thresholds[:v8_weighted_delta_sparse_longform_conclusive].to_f)
      sparse_weighted_ok &&= (raw_delta >= thresholds[:v8_raw_delta_sparse_longform_floor].to_f)
      sparse_weighted_ok &&= (mismatch_rate <= thresholds[:v8_max_mismatch_rate_sparse_longform].to_f)
      sparse_weighted_ok &&= (second_ratio <= thresholds[:v8_second_match_sparse_longform_max].to_f)

      if sparse_weighted_ok
        return {
          used: true,
          basis: "anchorless_pairwise_sparse_weighted",
          reason: "v8_pairwise_sparse_weighted_policy_passed",
        }
      end

      asymmetric_ok = true
      asymmetric_ok &&= !sync_used
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

    def apply_statistical_confidence!(result)
      return unless result.is_a?(Hash)

      result["meta"] ||= {}
      candidates = result["candidates"]
      return unless candidates.is_a?(Array)

      pool_size = candidates.length
      reference_pool_size = (result.dig("meta", "reference_pool_size") || 2000).to_i
      reference_pool_size = 2000 if reference_pool_size <= 0

      result["meta"]["pool_size"] ||= pool_size
      result["meta"]["reference_pool_size"] ||= reference_pool_size
      result["meta"]["statistical_confidence_model"] ||= "binomial_tail_p0_0.5"
      result["meta"]["statistical_confidence_note"] ||= "Supportive significance based on compared/mismatches under a random 50/50 agreement baseline."

      candidates.each do |candidate|
        next unless candidate.is_a?(Hash)
        annotate_candidate_statistical_confidence!(candidate, pool_size: pool_size, reference_pool_size: reference_pool_size)
      end
    end

    def annotate_candidate_statistical_confidence!(candidate, pool_size:, reference_pool_size:)
      compared = candidate["compared"].to_i
      mismatches = candidate["mismatches"].to_i
      return candidate if compared <= 0

      matches = [compared - mismatches, 0].max
      z_score = binomial_match_z_score(matches, compared)
      p_value = binomial_tail_p_value(matches, compared)
      expected_pool = p_value * pool_size.to_f
      expected_reference = p_value * reference_pool_size.to_f

      candidate["matches"] = matches
      candidate["signal_z"] = z_score.round(4)
      candidate["p_value"] = round_probability(p_value)
      candidate["expected_false_positives_pool"] = round_probability(expected_pool)
      candidate["expected_false_positives_2000"] = round_probability(expected_reference)
      candidate["statistical_confidence_model"] ||= "binomial_tail_p0_0.5"
      candidate
    end

    def binomial_match_z_score(matches, compared, p0: 0.5)
      n = compared.to_i
      return 0.0 if n <= 0

      mean = n * p0.to_f
      variance = n * p0.to_f * (1.0 - p0.to_f)
      return 0.0 if variance <= 0.0

      (matches.to_f - mean) / Math.sqrt(variance)
    end

    def binomial_tail_p_value(matches, compared, p0: 0.5)
      n = compared.to_i
      k = matches.to_i
      return 1.0 if n <= 0
      return 1.0 if k <= 0
      return Float::MIN if k > n

      log_terms = (k..n).map { |i| log_binomial_probability(n, i, p0) }
      log_sum = logsumexp(log_terms)
      return Float::MIN if log_sum.nan?

      [Math.exp(log_sum), Float::MIN].max
    end

    def log_binomial_probability(n, k, p)
      return -Float::INFINITY if k < 0 || k > n
      return -Float::INFINITY if p <= 0.0 || p >= 1.0

      log_choose = Math.lgamma(n + 1).first - Math.lgamma(k + 1).first - Math.lgamma(n - k + 1).first
      log_choose + (k * Math.log(p)) + ((n - k) * Math.log(1.0 - p))
    end

    def logsumexp(values)
      finite = Array(values).select { |v| v.finite? }
      return -Float::INFINITY if finite.blank?

      max = finite.max
      max + Math.log(finite.sum { |v| Math.exp(v - max) })
    end

    def round_probability(value)
      f = value.to_f
      return 0.0 unless f.finite? && f >= 0.0
      return 0.0 if f.zero?
      return f.round(6) if f >= 0.01
      return f.round(8) if f >= 0.0001

      f
    end

    def candidate_value(candidate, key)
      return 0.0 unless candidate.is_a?(Hash)

      candidate[key.to_s].to_f
    rescue
      0.0
    end

    def adaptive_quality_metrics(result)
      arr = Array(result["candidates"])
      top = arr[0] || {}
      second = arr[1] || {}
      meta = result.is_a?(Hash) ? (result["meta"] || {}) : {}
      {
        top_adaptive_ratio: candidate_value(top, :match_ratio_adaptive_weighted),
        second_adaptive_ratio: candidate_value(second, :match_ratio_adaptive_weighted),
        adaptive_delta: (candidate_value(top, :match_ratio_adaptive_weighted) - candidate_value(second, :match_ratio_adaptive_weighted)).round(4),
        top_high_quality_ratio: candidate_value(top, :high_quality_match_ratio),
        support_ratio: meta["adaptive_high_quality_support_ratio"].to_f,
      }
    rescue
      {
        top_adaptive_ratio: 0.0,
        second_adaptive_ratio: 0.0,
        adaptive_delta: 0.0,
        top_high_quality_ratio: 0.0,
        support_ratio: 0.0,
      }
    end

    def v8_pairwise_support_metrics(candidate)
      return { decisive_chunks: 0, win_advantage: 0, margin_median: 0.0 } unless candidate.is_a?(Hash)

      wins = candidate["pairwise_chunks_won"].to_i
      losses = candidate["pairwise_chunks_lost"].to_i
      {
        decisive_chunks: wins + losses,
        win_advantage: wins - losses,
        margin_median: candidate["pairwise_chunk_margin_median"].to_f,
      }
    rescue
      { decisive_chunks: 0, win_advantage: 0, margin_median: 0.0 }
    end

    def candidate_match_ratio(candidate)
      return 0.0 unless candidate.is_a?(Hash)

      weighted = candidate["match_ratio_weighted"].to_f
      return weighted if weighted > 0.0

      candidate["match_ratio"].to_f
    end

    def top_two_match_ratios(result)
      cands = result["candidates"]
      return [0.0, 0.0] unless cands.is_a?(Array) && cands.present?

      top = cands[0].is_a?(Hash) ? candidate_match_ratio(cands[0]) : 0.0
      second = cands[1].is_a?(Hash) ? candidate_match_ratio(cands[1]) : 0.0
      [top, second]
    end

    DISCOURSE_SOURCE_URL_PATH_PREFIXES = ["/media/hls/", "/media/stream/", "/uploads/", "/secure-uploads/"].freeze
    S3_SOURCE_URL_PROFILE_KEYS = %w[s3_1 s3_2 s3_3].freeze

    def source_url_allowed_host_and_port?(uri)
      source_url_allowed_origin?(uri)
    end

    def source_url_allowed_path?(uri)
      classification = classify_source_url_origin(uri)
      return false if classification.blank?

      case classification[:kind]
      when :discourse
        discourse_source_url_path_allowed?(uri)
      when :s3
        s3_source_url_path_allowed?(uri, classification[:profile])
      else
        false
      end
    end

    def source_url_allowed_origin?(uri)
      classify_source_url_origin(uri).present?
    end

    def classify_source_url_origin(uri)
      return nil unless uri.is_a?(URI::HTTP)
      return nil unless %w[http https].include?(uri.scheme.to_s)
      return nil if uri.host.blank?

      canonical_discourse_source_uris.each do |base_uri|
        next unless same_origin_for_source_url?(uri, base_uri)
        return { kind: :discourse, profile: nil }
      end

      configured_s3_source_url_origins.each do |entry|
        next unless same_origin_for_source_url?(uri, entry[:uri])
        return { kind: :s3, profile: entry[:profile_key] }
      end

      nil
    rescue
      nil
    end

    def canonical_discourse_source_uris
      [safe_base_uri].compact
    end

    def safe_base_uri
      URI.parse(Discourse.base_url.to_s)
    rescue
      nil
    end

    def same_origin_for_source_url?(uri, base_uri)
      return false if uri.blank? || base_uri.blank?

      uri.scheme.to_s.downcase == base_uri.scheme.to_s.downcase &&
        uri.host.to_s.downcase == base_uri.host.to_s.downcase &&
        normalized_port(uri) == normalized_port(base_uri)
    end

    def normalized_port(uri)
      return uri.port if uri.port.present?
      uri.scheme.to_s == "https" ? 443 : 80
    end

    def discourse_source_url_path_allowed?(uri)
      path = uri.path.to_s
      return true if path == "/media/stream"

      DISCOURSE_SOURCE_URL_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    end

    def configured_s3_source_url_origins
      S3_SOURCE_URL_PROFILE_KEYS.flat_map do |profile_key|
        s3_source_url_origins_for_profile(profile_key)
      end.compact.uniq { |entry| [entry[:profile_key], entry[:uri]&.scheme, entry[:uri]&.host, normalized_port(entry[:uri]), entry[:style]] }
    rescue
      []
    end

    def s3_source_url_origins_for_profile(profile_key)
      opts = ::MediaGallery::StorageSettingsResolver.s3_options_for_profile_key(profile_key) rescue nil
      return [] if opts.blank? || opts[:endpoint].to_s.blank? || opts[:bucket].to_s.blank?

      endpoint = URI.parse(opts[:endpoint].to_s.sub(%r{/+\z}, "")) rescue nil
      return [] if endpoint.blank? || endpoint.host.blank? || !%w[http https].include?(endpoint.scheme.to_s)

      entries = [{ profile_key: profile_key.to_s, uri: endpoint, style: :path }]

      unless opts[:force_path_style]
        virtual_uri = endpoint.dup
        virtual_uri.host = "#{opts[:bucket]}.#{endpoint.host}"
        entries << { profile_key: profile_key.to_s, uri: virtual_uri, style: :virtual }
      end

      entries
    rescue
      []
    end

    def s3_profile_options(profile_key)
      ::MediaGallery::StorageSettingsResolver.s3_options_for_profile_key(profile_key)
    rescue
      {}
    end

    def s3_source_url_path_allowed?(uri, profile_key)
      opts = s3_profile_options(profile_key)
      return false if opts.blank?

      endpoint = URI.parse(opts[:endpoint].to_s.sub(%r{/+\z}, "")) rescue nil
      return false if endpoint.blank?

      bucket = opts[:bucket].to_s
      prefix = opts[:prefix].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      path = uri.path.to_s

      # Path-style S3 URLs: https://endpoint/bucket/prefix/key
      if same_origin_for_source_url?(uri, endpoint)
        required = "/#{bucket}"
        required << "/#{prefix}" if prefix.present?
        return path == required || path.start_with?("#{required}/")
      end

      # Virtual-hosted S3 URLs: https://bucket.endpoint/prefix/key
      unless opts[:force_path_style]
        required = prefix.present? ? "/#{prefix}" : "/"
        return path == required || path.start_with?(required.end_with?("/") ? required : "#{required}/")
      end

      false
    rescue
      false
    end

    def ensure_source_url_allowed!(uri, context: "source_url")
      raise "#{context} must be an http(s) URL" if uri.blank? || uri.host.blank? || !%w[http https].include?(uri.scheme.to_s)
      raise "#{context} credentials are not allowed" if uri.user.present? || uri.password.present?
      raise "#{context} must use HTTPS" unless source_url_scheme_allowed?(uri)
      raise "#{context} host is not allowed" unless source_url_allowed_host_and_port?(uri)
      raise "#{context} path is not allowed" unless source_url_allowed_path?(uri)
      true
    end

    def source_url_scheme_allowed?(uri)
      return true unless uri&.scheme.to_s == "http"

      case setting_forensics_http_source_url_policy
      when "allow_all"
        true
      when "canonical_only"
        classify_source_url_origin(uri).try(:[], :kind) == :discourse
      else
        false
      end
    rescue
      false
    end



    def setting_forensics_http_source_url_policy
      value =
        if SiteSetting.respond_to?(:media_gallery_forensics_http_source_url_policy)
          SiteSetting.media_gallery_forensics_http_source_url_policy.to_s
        else
          "deny_all"
        end

      %w[allow_all canonical_only deny_all].include?(value) ? value : "deny_all"
    rescue
      "deny_all"
    end

    def setting_forensics_allow_remote_hls_playlist_fetch?
      SiteSetting.respond_to?(:media_gallery_forensics_allow_remote_hls_playlist_fetch) &&
        SiteSetting.media_gallery_forensics_allow_remote_hls_playlist_fetch
    rescue
      false
    end

    def source_url_validation_message(message)
      text = message.to_s
      return "Only canonical site media/upload URLs or configured S3 object URLs are allowed." if text.include?("host is not allowed") || text.include?("path is not allowed")
      return "HTTPS source URLs are required by the current forensic identify settings." if text.include?("must use HTTPS")
      return "Remote HLS playlist fetching is disabled. Use the plugin's /media/hls URL or enable the remote playlist setting." if text.include?("remote_hls_playlist_fetch_disabled")
      text.presence || "source_url is not allowed"
    end

    def forward_cookie_for_source_url?(uri)
      classify_source_url_origin(uri).try(:[], :kind) == :discourse && uri.path.to_s.start_with?("/media/hls/", "/media/stream/")
    end

    def download_source_url_to_tempfile!(source_url, max_samples:, segment_seconds:, media_item:)
      url = source_url.to_s.strip
      raise "source_url is blank" if url.blank?
      raise "source_url is too long" if url.length > setting_max_source_url_length

      uri = URI.parse(url) rescue nil
      begin
        ensure_source_url_allowed!(uri, context: "source_url")
      rescue => e
        raise source_url_validation_message(e.message)
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
            unless setting_forensics_allow_remote_hls_playlist_fetch?
              raise source_url_validation_message("remote_hls_playlist_fetch_disabled")
            end

            playlist_tmp = rewrite_hls_playlist_to_tempfile!(uri)
          else
            raise e
          end
        end
        input = playlist_tmp.path
      end

      tmp = Tempfile.new(["media_gallery_identify_", ".mp4"])
      tmp.binmode

      remote_ffmpeg_input = input.to_s == url && %w[http https].include?(uri.scheme.to_s)
      protocol_whitelist = remote_ffmpeg_input ? "file,http,https,tcp,tls,crypto" : "file,crypto"

      cmd = [
        ::MediaGallery::Ffmpeg.ffmpeg_path,
        *::MediaGallery::Ffmpeg.ffmpeg_common_args,
        "-y",
        "-protocol_whitelist",
        protocol_whitelist,
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

      playlist_tmp&.close! rescue nil
      playlist_tmp = nil
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
    # Admin-only identify can safely read the packaged HLS files. For migrated media,
    # the HLS package may exist only in the managed store (S3/R2/local managed storage),
    # so we localize the playlist and its referenced objects into a temporary directory
    # and point FFmpeg only at local files.
    def localize_hls_playlist_to_tempfile!(playlist_uri, media_item:)
      path = playlist_uri.path.to_s

      # Variant playlist URL
      m = path.match(%r{\A/media/hls/(?<public_id>[\w\-]+)/v/(?<variant>[^/]+)/index\.m3u8\z}i)

      # Master playlist URL (we'll pick a variant from the manifest or playlist)
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

      role = managed_hls_role_for_identify(media_item)
      if role.present?
        return localize_managed_hls_playlist_to_tempfile!(
          media_item: media_item,
          role: role,
          variant: variant,
          fingerprint_id: fingerprint_id
        )
      end

      localize_legacy_hls_playlist_to_tempfile!(
        media_item: media_item,
        public_id: public_id,
        variant: variant,
        fingerprint_id: fingerprint_id
      )
    end

    def localize_legacy_hls_playlist_to_tempfile!(media_item:, public_id:, variant:, fingerprint_id: nil)
      if variant.blank?
        master_abs = MediaGallery::PrivateStorage.hls_master_abs_path(media_item)
        raise "master_playlist_not_found" if master_abs.blank? || !File.exist?(master_abs)

        variant = pick_hls_variant_from_master!(File.read(master_abs))
      end

      abs = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(public_id, variant)
      raise "variant_playlist_not_found" if abs.blank? || !File.exist?(abs)

      raw = File.read(abs)

      cleanup_stale_forensics_hls_tempdirs!
      temp_dir = Dir.mktmpdir(FORENSICS_HLS_TEMP_PREFIX)
      cache = {}

      begin
        rewritten = rewrite_hls_playlist_with_local_paths(
          raw,
          resolver: lambda do |segment, seg_counter, map_uri|
            resolve_segment_abs_path(
              public_id,
              variant,
              segment,
              fingerprint_id: fingerprint_id,
              media_item_id: media_item.id,
              seg_counter: seg_counter
            )
          end,
          aes_key_resolver: lambda do |key_uri|
            localize_hls_aes128_key_for_identify!(
              media_item: media_item,
              key_uri: key_uri,
              variant: variant,
              temp_dir: temp_dir,
              cache: cache
            )
          end
        )

        write_localized_hls_playlist!(rewritten, prefix: "media_gallery_identify_local_", cleanup_dir: temp_dir)
      rescue
        FileUtils.rm_rf(temp_dir) if temp_dir.present? && Dir.exist?(temp_dir)
        raise
      end
    end

    def localize_managed_hls_playlist_to_tempfile!(media_item:, role:, variant:, fingerprint_id: nil)
      store = MediaGallery::Hls.store_for_managed_role(media_item, role)
      raise "managed_hls_store_unavailable" if store.blank?

      cleanup_stale_forensics_hls_tempdirs!
      temp_dir = Dir.mktmpdir(FORENSICS_HLS_TEMP_PREFIX)
      cache = {}

      begin
        if variant.blank?
          master_key = MediaGallery::Hls.master_key_for(media_item, role: role)
          master_raw = store.read(master_key)
          variant = pick_hls_variant_from_master!(master_raw)
        end

        variant_key = MediaGallery::Hls.variant_playlist_key_for(media_item, variant, role: role)
        raw = store.read(variant_key)
        codebook_scheme = packaged_codebook_scheme_for_identify(media_item, role: role, store: store)

        rewritten = rewrite_hls_playlist_with_local_paths(
          raw,
          resolver: lambda do |segment, seg_counter, map_uri|
            key = managed_hls_segment_key_for_identify(
              media_item: media_item,
              role: role,
              store: store,
              variant: variant,
              segment: segment,
              fingerprint_id: fingerprint_id,
              seg_counter: seg_counter,
              codebook_scheme: codebook_scheme,
              map_uri: map_uri
            )

            localize_managed_hls_object!(store: store, key: key, temp_dir: temp_dir, cache: cache, suggested_name: segment)
          end,
          aes_key_resolver: lambda do |key_uri|
            localize_hls_aes128_key_for_identify!(
              media_item: media_item,
              key_uri: key_uri,
              role: role,
              variant: variant,
              temp_dir: temp_dir,
              cache: cache
            )
          end
        )

        write_localized_hls_playlist!(rewritten, prefix: "media_gallery_identify_managed_", cleanup_dir: temp_dir)
      rescue
        FileUtils.rm_rf(temp_dir) if temp_dir.present? && Dir.exist?(temp_dir)
        raise
      end
    end

    def rewrite_hls_playlist_with_local_paths(raw, resolver:, aes_key_resolver: nil)
      rewritten = []
      seg_counter = 0

      raw.to_s.each_line do |line|
        l = line.to_s.rstrip
        if l.blank? || l.start_with?("#")
          if hls_aes128_key_tag?(l)
            rewritten << rewrite_hls_aes128_key_tag_for_identify(l, aes_key_resolver: aes_key_resolver)
          elsif l.include?("URI=\"")
            rewritten << l.gsub(/URI=\"([^\"]+)\"/) do
              uri_str = Regexp.last_match(1).to_s
              file = safe_hls_reference_filename!(uri_str, allowed_extensions: %w[mp4 m4s])
              local = resolver.call(file, seg_counter, true)
              "URI=\"#{local}\""
            end
          else
            rewritten << l
          end
          next
        end

        seg = safe_hls_reference_filename!(l, allowed_extensions: %w[ts m4s])
        local = resolver.call(seg, seg_counter, false)
        seg_counter += 1
        rewritten << local
      rescue ArgumentError => e
        # Do not allow unrecognized media or URI references to fall through to FFmpeg as remote paths.
        raise e if l.present? && (!l.start_with?("#") || l.include?("URI=\""))
        rewritten << l
      end

      out = rewritten.join("\n") + "\n"
      raise "playlist did not look like M3U8" unless out.lstrip.start_with?("#EXTM3U")
      out
    end

    def hls_aes128_key_tag?(line)
      line.to_s.start_with?("#EXT-X-KEY") && line.to_s.match?(/METHOD=AES-128/i) && line.to_s.include?("URI=\"")
    end

    def rewrite_hls_aes128_key_tag_for_identify(line, aes_key_resolver:)
      raise "hls_aes128_key_resolver_missing" unless aes_key_resolver.respond_to?(:call)

      line.to_s.gsub(/URI=\"([^\"]+)\"/) do
        key_uri = Regexp.last_match(1).to_s
        local = aes_key_resolver.call(key_uri).to_s
        raise "hls_aes128_key_localization_failed" if local.blank?

        "URI=\"#{local}\""
      end
    end

    def write_localized_hls_playlist!(content, prefix:, cleanup_dir: nil)
      tmp = Tempfile.new([prefix, ".m3u8"], cleanup_dir.presence)
      tmp.binmode
      tmp.write(content)
      tmp.flush
      attach_tempdir_cleanup!(tmp, cleanup_dir) if cleanup_dir.present?
      tmp
    end

    def pick_hls_variant_from_master!(master_raw)
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
      picked
    end

    def managed_hls_role_for_identify(media_item)
      role = MediaGallery::Hls.managed_role_for(media_item)
      return nil unless role.present?
      return nil unless MediaGallery::Hls.managed_role_ready?(media_item, role)

      role.deep_stringify_keys
    rescue
      nil
    end

    def packaged_codebook_scheme_for_identify(media_item, role:, store:)
      meta = MediaGallery::Hls.fingerprint_meta_for(media_item, role: role, store: store)
      return nil unless meta.is_a?(Hash)

      meta["codebook_scheme"].to_s.presence || MediaGallery::Fingerprinting.codebook_scheme_for(layout: meta["layout"].to_s)
    rescue
      nil
    end

    def localize_hls_aes128_key_for_identify!(media_item:, key_uri:, variant:, temp_dir:, cache:, role: nil)
      raise "hls_aes128_key_temp_dir_missing" if temp_dir.blank?

      key_id = hls_aes128_key_id_from_reference_for_identify(key_uri)
      raise "hls_aes128_key_reference_unsupported" if key_id.blank?

      if role.present?
        encryption = MediaGallery::Hls.aes128_encryption_meta_for(media_item, role: role)
        expected_key_id = encryption.is_a?(Hash) ? encryption["key_id"].to_s.presence : nil
        raise "hls_aes128_key_mismatch" if expected_key_id.present? && expected_key_id != key_id
      end

      variant = variant.to_s.presence || MediaGallery::Hls::DEFAULT_VARIANT
      cache_key = "aes128-key:#{media_item.id}:#{variant}:#{key_id}"
      cached = cache[cache_key]
      return cached if cached.present? && File.exist?(cached) && File.size(cached).to_i == ::MediaGallery::HlsAes128::KEY_BYTES

      key_bytes = MediaGallery::HlsAes128.fetch_key_bytes(item: media_item, key_id: key_id, variant: variant)
      if !MediaGallery::HlsAes128.valid_key_bytes?(key_bytes) && variant.to_s != MediaGallery::Hls::DEFAULT_VARIANT.to_s
        key_bytes = MediaGallery::HlsAes128.fetch_key_bytes(item: media_item, key_id: key_id, variant: MediaGallery::Hls::DEFAULT_VARIANT)
      end
      raise "hls_aes128_key_missing" unless MediaGallery::HlsAes128.valid_key_bytes?(key_bytes)

      keys_dir = File.join(temp_dir, "keys")
      FileUtils.mkdir_p(keys_dir)
      safe_key_id = MediaGallery::HlsAes128.normalize_key_id(key_id)
      filename = "#{Digest::SHA256.hexdigest(cache_key)[0, 16]}_#{safe_key_id}.key"
      local = File.join(keys_dir, filename)

      File.binwrite(local, key_bytes.b)
      File.chmod(0o600, local) rescue nil
      raise "hls_aes128_key_localization_failed" unless File.exist?(local) && File.size(local).to_i == ::MediaGallery::HlsAes128::KEY_BYTES

      cache[cache_key] = local
      local
    end

    def hls_aes128_key_id_from_reference_for_identify(uri)
      key_id = MediaGallery::HlsAes128.key_id_from_placeholder_uri(uri)
      return key_id if key_id.present?

      file = File.basename(uri.to_s.split("?", 2).first.to_s)
      match = file.match(/\A([a-zA-Z0-9_-]+)\.key\z/)
      return nil unless match

      MediaGallery::HlsAes128.normalize_key_id(match[1])
    rescue
      nil
    end

    def managed_hls_segment_key_for_identify(media_item:, role:, store:, variant:, segment:, fingerprint_id:, seg_counter:, codebook_scheme:, map_uri: false)
      seg = safe_hls_reference_filename!(segment, allowed_extensions: map_uri ? %w[mp4 m4s] : %w[ts m4s])
      candidates = []

      if !map_uri && MediaGallery::Fingerprinting.enabled? && fingerprint_id.present? && media_item&.id.present?
        idx = MediaGallery::Fingerprinting.segment_index_from_filename(seg)
        idx ||= seg_counter
        if idx.present?
          ab = MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: fingerprint_id,
            media_item_id: media_item.id,
            segment_index: idx,
            codebook: codebook_scheme
          )

          if ab.present?
            ab_key = MediaGallery::Hls.segment_key_for(media_item, variant, seg, ab: ab, role: role)
            candidates << ab_key if ab_key.present?
          end
        end
      end

      fallback_key = MediaGallery::Hls.segment_key_for(media_item, variant, seg, role: role)
      candidates << fallback_key if fallback_key.present?
      candidates = candidates.compact.map(&:to_s).reject(&:blank?).uniq

      raise "hls_segment_key_missing" if candidates.blank?

      # Return ordered candidates instead of doing a HEAD/exists? probe here.
      # Some S3-compatible providers, including certain Backblaze/B2 setups,
      # can return provider-specific 403/ServiceError responses for HEAD on
      # a missing candidate while GET for the fallback object is valid. Trying
      # GET candidates in order keeps Cloudflare/R2, Backblaze and local managed
      # storage consistent and avoids surfacing a provider HEAD quirk as HTTP 500.
      candidates
    end

    def localize_managed_hls_object!(store:, key:, temp_dir:, cache:, suggested_name:)
      candidate_keys = Array(key).flatten.compact.map(&:to_s).reject(&:blank?).uniq
      raise "managed_hls_object_key_missing" if candidate_keys.blank?

      candidate_keys.each do |candidate_key|
        cached = cache[candidate_key]
        return cached if cached.present? && File.exist?(cached) && File.size?(cached).to_i > 0
      end

      safe_name = safe_hls_reference_filename!(suggested_name, allowed_extensions: %w[ts m4s mp4])
      objects_dir = File.join(temp_dir, "objects")
      FileUtils.mkdir_p(objects_dir)

      last_error = nil
      candidate_keys.each do |candidate_key|
        local = File.join(objects_dir, "#{Digest::SHA256.hexdigest(candidate_key.to_s)[0, 16]}_#{safe_name}")

        begin
          download_managed_hls_object_to_file!(store: store, key: candidate_key, destination_path: local)
          raise "managed_hls_object_empty" unless File.exist?(local) && File.size?(local).to_i > 0

          cache[candidate_key] = local
          return local
        rescue => e
          last_error = e
          FileUtils.rm_f(local)
          next
        end
      end

      raise "managed_hls_object_download_failed: #{last_error.class}: #{last_error.message.to_s.truncate(180)}"
    end

    def download_managed_hls_object_to_file!(store:, key:, destination_path:)
      FileUtils.mkdir_p(File.dirname(destination_path.to_s))

      primary_error = nil
      begin
        store.download_to_file!(key, destination_path)
        return destination_path if File.exist?(destination_path) && File.size?(destination_path).to_i > 0
      rescue => e
        primary_error = e
        FileUtils.rm_f(destination_path)
      end

      # Fallback for S3-compatible providers where the SDK response_target path
      # behaves differently than a plain get_object/read or streamed download.
      begin
        if store.respond_to?(:stream)
          wrote = false
          File.open(destination_path, "wb") do |file|
            store.stream(key) do |chunk|
              file.write(chunk)
              wrote = true
            end
          end
          return destination_path if wrote && File.exist?(destination_path) && File.size?(destination_path).to_i > 0
          FileUtils.rm_f(destination_path)
        end

        File.open(destination_path, "wb") do |file|
          file.write(store.read(key))
        end
        return destination_path if File.exist?(destination_path) && File.size?(destination_path).to_i > 0
      rescue => fallback_error
        FileUtils.rm_f(destination_path)
        raise primary_error || fallback_error
      end

      raise primary_error || "managed_hls_object_empty"
    end

    def attach_tempdir_cleanup!(tmp, dir)
      cleanup_dir = dir.to_s
      original_close_bang = tmp.method(:close!)
      tmp.define_singleton_method(:close!) do
        begin
          original_close_bang.call
        ensure
          FileUtils.rm_rf(cleanup_dir) if cleanup_dir.present? && Dir.exist?(cleanup_dir)
        end
      end
      tmp
    end

    def cleanup_stale_forensics_hls_tempdirs!
      cutoff = Time.now - FORENSICS_HLS_TEMP_TTL_SECONDS
      Dir.glob(File.join(Dir.tmpdir, "#{FORENSICS_HLS_TEMP_PREFIX}*")).each do |path|
        next unless File.directory?(path)
        next if File.mtime(path) > cutoff
        FileUtils.rm_rf(path)
      rescue
        next
      end
    rescue
      nil
    end

    def safe_hls_reference_filename!(value, allowed_extensions:)
      name = File.basename(value.to_s.split("?").first.to_s)
      raise ArgumentError, "invalid_hls_reference" if name.blank?
      raise ArgumentError, "invalid_hls_reference" unless name.match?(/\A[\w\-.]+\z/)

      ext = File.extname(name).delete(".").downcase
      raise ArgumentError, "invalid_hls_reference_extension" unless allowed_extensions.map(&:to_s).include?(ext)

      name
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
      req["Cookie"] = cookie if cookie.present? && forward_cookie_for_source_url?(uri)
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
      ensure_playlist_reference_allowed!(abs)
      add_token(abs, token)
    end

    # Rewrites URI="..." occurrences in HLS tag lines like EXT-X-KEY, EXT-X-MAP, EXT-X-MEDIA.
    def rewrite_quoted_uris_in_tag_line(line, base_uri, token)
      line.gsub(/URI="([^"]+)"/) do
        original = Regexp.last_match(1)
        abs = absolutize_uri(original, base_uri)
        ensure_playlist_reference_allowed!(abs)
        rewritten = add_token(abs, token)
        "URI=\"#{rewritten}\""
      end
    end

    def absolutize_uri(value, base_uri)
      v = value.to_s
      raise "playlist reference is blank" if v.blank?

      u = URI.parse(v) rescue nil
      return u if u&.scheme.present? && u&.host.present?

      URI.join(base_uri.to_s, v)
    rescue => e
      raise "invalid playlist reference: #{e.message}"
    end

    def ensure_playlist_reference_allowed!(uri)
      ensure_source_url_allowed!(uri, context: "playlist_reference")
    rescue => e
      raise source_url_validation_message(e.message)
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
