# frozen_string_literal: true

module ::MediaGallery
  # Small, conservative AES-128 operations that are safe to run from admin UI.
  # This module deliberately does not try to reconstruct clear/legacy HLS after
  # AES packaging. Backfill overwrites the active HLS role/path, so a true media
  # rollback requires reprocessing from the source/processed video.
  module HlsAes128Maintenance
    module_function

    MAX_SAMPLE_BLOCKERS = 20

    def cleanup_item!(item, requested_by:, clear_stale_state: true, delete_inactive_keys: true, delete_leaked_artifacts: true)
      raise ArgumentError, "media_item_missing" if item.blank? || item.id.blank?

      role = current_hls_role(item)
      encryption = current_encryption(role)
      key_id = encryption&.dig("key_id").to_s.presence
      actions = []
      warnings = []

      deleted_inactive_keys = 0
      deleted_artifacts = []
      cleared_state = false

      if delete_inactive_keys && aes_key_table_available?
        deleted_inactive_keys = cleanup_inactive_key_records!(item, current_key_id: key_id)
        actions << "deleted_inactive_key_records" if deleted_inactive_keys.positive?
      end

      if delete_leaked_artifacts && role.is_a?(Hash)
        deleted_artifacts = delete_known_key_artifacts!(item, role: role, key_id: key_id)
        actions << "deleted_key_artifacts" if deleted_artifacts.present?
      end

      if clear_stale_state && defined?(::MediaGallery::HlsAes128Backfill)
        state = ::MediaGallery::HlsAes128Backfill.state_for(item)
        if state.is_a?(Hash) && state.present? && cleanup_state_clearable?(state)
          ::MediaGallery::HlsAes128Backfill.clear_state!(
            item,
            requested_by: requested_by.to_s.presence || "system",
            reason: "maintenance_cleanup"
          )
          cleared_state = true
          actions << "cleared_backfill_state"
        end
      end

      warnings << "no_hls_role" unless role.is_a?(Hash)
      warnings << "aes_metadata_missing" if role.is_a?(Hash) && encryption.blank?
      warnings << "current_aes_key_id_missing" if encryption.present? && key_id.blank?
      warnings << "true_legacy_hls_rollback_requires_reprocess" if encryption.present?

      result = {
        ok: true,
        public_id: item.public_id.to_s,
        media_item_id: item.id,
        cleaned_at: Time.now.utc.iso8601,
        requested_by: requested_by.to_s.presence,
        actions: actions,
        warnings: warnings,
        hls_present: role.is_a?(Hash),
        aes_present: encryption.present?,
        current_key_id: key_id,
        deleted_inactive_key_records: deleted_inactive_keys,
        deleted_key_artifacts: deleted_artifacts,
        cleared_backfill_state: cleared_state,
        rollback_available: false,
        rollback_note: encryption.present? ? "AES packages cannot be reverted to clear HLS without reprocessing from source/processed video." : nil,
      }.compact

      log_maintenance!("hls_aes128_maintenance_cleanup", item: item, requested_by: requested_by, result: result)
      result
    end

    def required_readiness_report(limit: MAX_SAMPLE_BLOCKERS)
      hls_enabled = setting_bool(:media_gallery_hls_enabled)
      hls_only_enabled = setting_bool(:media_gallery_protected_video_hls_only)
      aes_enabled = setting_bool(:media_gallery_hls_aes128_enabled)
      aes_required = aes_enabled && setting_bool(:media_gallery_hls_aes128_required)

      ready_video_scope = ::MediaGallery::MediaItem.where(media_type: "video", status: "ready")
      hls_scope = ready_video_scope.where("storage_manifest -> 'roles' -> 'hls' IS NOT NULL")
      aes_meta_scope = hls_scope.where("storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NOT NULL")
      legacy_scope = hls_scope.where("storage_manifest -> 'roles' -> 'hls' -> 'encryption' IS NULL")
      no_hls_scope = ready_video_scope.where("storage_manifest -> 'roles' -> 'hls' IS NULL")

      total_ready_videos = ready_video_scope.count
      hls_ready_videos = hls_scope.count
      aes_metadata_count = aes_meta_scope.count
      needs_backfill_count = legacy_scope.count
      no_hls_count = no_hls_scope.count

      key_check = key_record_check_for_scope(aes_meta_scope.limit(500).to_a)
      backfill = backfill_counts_for_scope(hls_scope.limit(1000).to_a)

      blockers = []
      blockers << blocker("hls_disabled", "HLS is disabled; AES-required playback cannot be enforced safely.") unless hls_enabled
      blockers << blocker("aes_disabled", "HLS AES-128 packaging is disabled; enable it before required mode.") unless aes_enabled
      blockers << blocker("hls_only_disabled", "HLS-only protected video mode is disabled; enable it to avoid direct stream fallback.") unless hls_only_enabled
      blockers << blocker("legacy_hls_needs_backfill", "#{needs_backfill_count} HLS video(s) still need AES backfill.") if needs_backfill_count.positive?
      blockers << blocker("aes_key_records_missing", "#{key_check[:missing_key_count]} AES video(s) have encryption metadata but no active server-side key record.") if key_check[:missing_key_count].positive?
      blockers << blocker("aes_backfill_failed", "#{backfill[:failed_count]} AES backfill job(s) failed.") if backfill[:failed_count].positive?
      blockers << blocker("aes_backfill_stale", "#{backfill[:stale_count]} AES backfill job(s) look stale.") if backfill[:stale_count].positive?
      blockers << blocker("aes_backfill_running", "#{backfill[:queued_count] + backfill[:processing_count]} AES backfill job(s) are queued or processing.") if (backfill[:queued_count] + backfill[:processing_count]).positive?

      warnings = []
      warnings << blocker("ready_videos_without_hls", "#{no_hls_count} ready video(s) do not have HLS. They will be blocked if protected playback requires HLS.") if no_hls_count.positive?
      warnings << blocker("aes_required_already_enabled", "AES required mode is already enabled; watch playback errors while backfill/QA completes.") if aes_required && blockers.present?

      sample_blockers = sample_required_blockers(
        legacy_scope: legacy_scope,
        missing_key_items: key_check[:missing_items],
        failed_or_stale_items: backfill[:problem_items],
        no_hls_scope: no_hls_scope,
        limit: limit
      )

      can_enable_required = blockers.empty?
      status = if !aes_enabled
        "manual"
      elsif blockers.present?
        "attention"
      elsif warnings.present?
        "partial"
      else
        "ok"
      end

      {
        generated_at: Time.now.utc.iso8601,
        status: status,
        can_enable_required: can_enable_required,
        aes_required_enabled: aes_required,
        hls_enabled: hls_enabled,
        hls_only_enabled: hls_only_enabled,
        aes_enabled: aes_enabled,
        total_ready_videos: total_ready_videos,
        hls_ready_video_count: hls_ready_videos,
        aes_metadata_count: aes_metadata_count,
        aes_ready_count: key_check[:ready_count],
        needs_backfill_count: needs_backfill_count,
        missing_key_count: key_check[:missing_key_count],
        no_hls_ready_video_count: no_hls_count,
        queued_count: backfill[:queued_count],
        processing_count: backfill[:processing_count],
        failed_count: backfill[:failed_count],
        stale_count: backfill[:stale_count],
        blockers: blockers,
        warnings: warnings,
        sample_blockers: sample_blockers,
        recommendation: required_mode_recommendation(can_enable_required: can_enable_required, aes_required: aes_required, blockers: blockers, warnings: warnings),
      }
    rescue => e
      {
        generated_at: Time.now.utc.iso8601,
        status: "attention",
        can_enable_required: false,
        error: "#{e.class}: #{e.message}",
        blockers: [blocker("readiness_check_failed", "Required-mode readiness check failed: #{e.message}")],
        warnings: [],
        sample_blockers: [],
        recommendation: "Fix the readiness check error before changing AES required settings.",
      }
    end

    def current_hls_role(item)
      role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      role = role.deep_stringify_keys if role.is_a?(Hash)
      role.is_a?(Hash) ? role : nil
    rescue
      nil
    end

    def current_encryption(role)
      encryption = role.is_a?(Hash) ? role["encryption"] : nil
      encryption = encryption.deep_stringify_keys if encryption.is_a?(Hash)
      encryption.is_a?(Hash) && encryption.present? ? encryption : nil
    rescue
      nil
    end

    def cleanup_inactive_key_records!(item, current_key_id: nil)
      return 0 unless aes_key_table_available?

      scope = ::MediaGallery::HlsAes128Key.where(media_item_id: item.id, active: false)
      scope = scope.where.not(key_id: current_key_id.to_s) if current_key_id.present?
      count = scope.count
      scope.delete_all if count.positive?
      count
    rescue => e
      Rails.logger.warn("[media_gallery] AES inactive key cleanup failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      0
    end

    def delete_known_key_artifacts!(item, role:, key_id: nil)
      store = store_for_role(item, role)
      return [] if store.blank?

      key_ids = [key_id.to_s.presence, ::MediaGallery::HlsAes128::DEFAULT_KEY_ID].compact.uniq
      variants = Array(role["variants"]).map(&:to_s).reject(&:blank?)
      variants = [::MediaGallery::Hls::DEFAULT_VARIANT] if variants.blank?
      prefixes = [role["key_prefix"].to_s]
      variants.each do |variant|
        prefixes << key_join(role["key_prefix"], variant)
        if ActiveModel::Type::Boolean.new.cast(role["ab_fingerprint"]) || role["ab_segment_key_template"].present?
          prefixes << key_join(role["key_prefix"], "a", variant)
          prefixes << key_join(role["key_prefix"], "b", variant)
        end
      end

      keys = prefixes.uniq.flat_map do |prefix|
        key_ids.flat_map do |id|
          [
            key_join(prefix, ::MediaGallery::HlsAes128.key_uri_placeholder(id)),
            key_join(prefix, ::MediaGallery::HlsAes128.keyinfo_filename(id)),
          ]
        end
      end.uniq

      deleted = []
      keys.each do |key|
        next if key.blank?
        next unless store.exists?(key)

        store.delete(key)
        deleted << key
      end
      deleted
    rescue => e
      Rails.logger.warn("[media_gallery] AES artifact cleanup failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      []
    end

    def cleanup_state_clearable?(state)
      return false unless state.is_a?(Hash)

      status = state["status"].to_s
      return true if %w[failed cancelled].include?(status)
      return true if defined?(::MediaGallery::HlsAes128Backfill) && ::MediaGallery::HlsAes128Backfill.stale_state?(state)

      false
    end

    def key_record_check_for_scope(items)
      rows = []
      missing = []
      ready = 0

      Array(items).each do |item|
        role = current_hls_role(item)
        encryption = current_encryption(role)
        key_id = encryption&.dig("key_id").to_s.presence
        next if key_id.blank?

        present = aes_key_record_present?(item, key_id: key_id)
        if present
          ready += 1
        else
          missing << item
        end
        rows << [item.id, key_id, present]
      end

      { checked_count: rows.length, ready_count: ready, missing_key_count: missing.length, missing_items: missing }
    end

    def aes_key_record_present?(item, key_id:)
      return false unless aes_key_table_available?

      ::MediaGallery::HlsAes128Key.active.exists?(
        media_item_id: item.id,
        key_id: key_id.to_s,
        variant: ::MediaGallery::Hls::DEFAULT_VARIANT,
        ab: ""
      )
    rescue
      false
    end

    def aes_key_table_available?
      defined?(::MediaGallery::HlsAes128Key) && ::MediaGallery::HlsAes128Key.table_exists?
    rescue
      false
    end

    def backfill_counts_for_scope(items)
      counters = Hash.new(0)
      problem_items = []

      Array(items).each do |item|
        state = if defined?(::MediaGallery::HlsAes128Backfill)
          ::MediaGallery::HlsAes128Backfill.state_for(item)
        else
          {}
        end
        next unless state.is_a?(Hash)

        status = state["status"].to_s
        stale = defined?(::MediaGallery::HlsAes128Backfill) && ::MediaGallery::HlsAes128Backfill.stale_state?(state)
        counters[:queued_count] += 1 if status == "queued"
        counters[:processing_count] += 1 if status == "processing"
        counters[:failed_count] += 1 if status == "failed"
        counters[:stale_count] += 1 if stale
        problem_items << item if status == "failed" || stale
      end

      {
        queued_count: counters[:queued_count],
        processing_count: counters[:processing_count],
        failed_count: counters[:failed_count],
        stale_count: counters[:stale_count],
        problem_items: problem_items,
      }
    end

    def sample_required_blockers(legacy_scope:, missing_key_items:, failed_or_stale_items:, no_hls_scope:, limit:)
      rows = []
      limit = [[limit.to_i, 1].max, MAX_SAMPLE_BLOCKERS].min

      legacy_scope.limit(limit).each do |item|
        rows << sample_row(item, reason: "needs_aes_backfill")
      end
      remaining = limit - rows.length
      Array(missing_key_items).first(remaining).each do |item|
        rows << sample_row(item, reason: "aes_key_record_missing")
      end
      remaining = limit - rows.length
      Array(failed_or_stale_items).first(remaining).each do |item|
        rows << sample_row(item, reason: "aes_backfill_failed_or_stale")
      end
      remaining = limit - rows.length
      no_hls_scope.limit(remaining).each do |item|
        rows << sample_row(item, reason: "no_hls")
      end if remaining.positive?

      rows
    rescue
      []
    end

    def sample_row(item, reason:)
      {
        public_id: item.public_id.to_s,
        title: item.title.to_s.presence,
        media_item_id: item.id,
        reason: reason,
        status: item.status.to_s,
      }.compact
    end

    def blocker(code, message)
      { code: code.to_s, message: message.to_s }
    end

    def required_mode_recommendation(can_enable_required:, aes_required:, blockers:, warnings:)
      if can_enable_required && aes_required
        "AES required mode is enabled and no required-mode blockers were found. Continue monitoring playback and key denials."
      elsif can_enable_required
        warnings.present? ?
          "Required mode is close to ready. Review warnings and run a final browser/backfill QA pass before enabling it." :
          "Required mode readiness looks good. Enable on staging first, test playback/identify, then enable in production."
      else
        "Do not enable AES required mode yet. Resolve blockers first: #{Array(blockers).map { |b| b[:code] || b['code'] }.compact.join(', ')}."
      end
    end


    def final_qa_report(limit: MAX_SAMPLE_BLOCKERS)
      readiness = required_readiness_report(limit: limit)
      checks = []

      hls_enabled = setting_bool(:media_gallery_hls_enabled)
      hls_only_enabled = setting_bool(:media_gallery_protected_video_hls_only)
      aes_enabled = setting_bool(:media_gallery_hls_aes128_enabled)
      aes_required = setting_bool(:media_gallery_hls_aes128_required) && aes_enabled
      key_limit = setting_int(:media_gallery_hls_key_requests_per_token_per_minute)
      playlist_limit = setting_int(:media_gallery_hls_playlist_requests_per_token_per_minute)
      segment_limit = setting_int(:media_gallery_hls_segment_requests_per_token_per_minute)
      bind_user = setting_bool(:media_gallery_bind_stream_to_user)
      bind_session = setting_bool(:media_gallery_bind_stream_to_session)
      bind_ip = setting_bool(:media_gallery_bind_stream_to_ip)
      block_direct = setting_bool(:media_gallery_block_direct_media_navigation, default: true)
      fingerprint_enabled = setting_bool(:media_gallery_fingerprint_enabled)
      watermark_enabled = setting_bool(:media_gallery_watermark_enabled)
      key_denial_logging = setting_bool(:media_gallery_log_hls_aes128_key_denials)
      forensic_policy = setting_string(:media_gallery_forensics_http_source_url_policy, default: "deny_all")
      key_rotation = setting_int(:media_gallery_hls_aes128_key_rotation_segments)

      checks << qa_check(
        code: "hls_enabled",
        title: "HLS enabled",
        status: hls_enabled ? "ok" : "attention",
        summary: hls_enabled ? "HLS delivery is enabled." : "HLS delivery is disabled.",
        action: hls_enabled ? "Keep HLS enabled for AES playback." : "Enable media_gallery_hls_enabled before AES QA."
      )

      checks << qa_check(
        code: "aes_enabled",
        title: "AES packaging enabled",
        status: aes_enabled ? "ok" : "attention",
        summary: aes_enabled ? "New/reprocessed HLS packages can be AES-128 encrypted." : "AES-128 packaging is disabled.",
        action: aes_enabled ? "Use staging uploads/backfill to validate encrypted playback." : "Enable media_gallery_hls_aes128_enabled before required-mode QA."
      )

      checks << qa_check(
        code: "required_readiness",
        title: "Required-mode blockers",
        status: readiness[:can_enable_required] ? "ok" : (aes_enabled ? "attention" : "manual"),
        summary: readiness[:can_enable_required] ? "No required-mode blockers were found." : Array(readiness[:blockers]).map { |b| b[:code] || b["code"] }.presence&.join(", ") || "Required-mode readiness has not passed.",
        action: readiness[:recommendation].to_s.presence || "Resolve readiness blockers before enabling AES required mode."
      )

      checks << qa_check(
        code: "hls_only_fallback",
        title: "Direct stream fallback",
        status: (hls_only_enabled || aes_required) ? "ok" : "warning",
        summary: if aes_required
          "AES required mode blocks direct stream fallback."
        elsif hls_only_enabled
          "HLS-only mode blocks direct stream fallback for protected video."
        else
          "Direct stream fallback can still be used while required mode is off."
        end,
        action: (hls_only_enabled || aes_required) ? "Validate playback errors do not fall back to direct MP4." : "Enable HLS-only or AES required mode before final production enforcement."
      )

      checks << qa_check(
        code: "rate_limits",
        title: "HLS/key rate limits",
        status: key_limit.positive? && playlist_limit.positive? && segment_limit.positive? ? "ok" : "attention",
        summary: "playlist #{playlist_limit}/min · segment #{segment_limit}/min · key #{key_limit}/min",
        action: "Keep limits high enough for normal playback but non-zero for abuse control."
      )

      checks << qa_check(
        code: "token_binding",
        title: "Token binding",
        status: bind_user && bind_session ? "ok" : "warning",
        summary: "user #{bind_user ? 'on' : 'off'} · session #{bind_session ? 'on' : 'off'} · IP #{bind_ip ? 'on' : 'off'}",
        action: bind_user && bind_session ? "IP binding is optional depending on user networks." : "Enable at least user and session binding for final AES QA."
      )

      checks << qa_check(
        code: "direct_navigation",
        title: "Direct media navigation",
        status: block_direct ? "ok" : "warning",
        summary: block_direct ? "Fetch-metadata direct navigation blocking is enabled." : "Direct navigation to tokenized media URLs is allowed.",
        action: block_direct ? "Retest after CDN/proxy changes." : "Enable direct media navigation blocking before production hardening."
      )

      checks << qa_check(
        code: "forensic_signals",
        title: "Forensic deterrence",
        status: fingerprint_enabled ? "ok" : (watermark_enabled ? "warning" : "manual"),
        summary: "fingerprint #{fingerprint_enabled ? 'on' : 'off'} · watermark #{watermark_enabled ? 'on' : 'off'}",
        action: fingerprint_enabled ? "Run one AES-HLS identify regression test before sign-off." : "Enable fingerprinting if forensic attribution is required."
      )

      checks << qa_check(
        code: "key_denial_logging",
        title: "AES key denial diagnostics",
        status: key_denial_logging ? "ok" : "manual",
        summary: key_denial_logging ? "Denied AES key requests are logged." : "Denied AES key requests are not logged by default.",
        action: key_denial_logging ? "Disable later if logs are too noisy." : "Enable temporarily during final QA if browser/key issues appear."
      )

      checks << qa_check(
        code: "forensics_source_policy",
        title: "Forensics source URL policy",
        status: forensic_policy == "deny_all" ? "ok" : "warning",
        summary: forensic_policy,
        action: forensic_policy == "deny_all" ? "Strict production policy is active." : "Use deny_all in production after HTTP/staging identify tests are finished."
      )

      checks << qa_check(
        code: "key_rotation_v1",
        title: "Key rotation v1 scope",
        status: key_rotation.to_i == 0 ? "ok" : "warning",
        summary: key_rotation.to_i == 0 ? "One AES key per video/package." : "Non-zero key rotation is configured but not part of the v1 QA scope.",
        action: key_rotation.to_i == 0 ? "Keep rotation off until a dedicated key-rotation iteration exists." : "Reset key rotation to 0 for the current implementation."
      )

      checks << qa_check(
        code: "manual_browser_matrix",
        title: "Manual browser matrix",
        status: "manual",
        summary: "Chrome/Edge hls.js, Firefox hls.js and Safari/iOS native HLS must still be manually verified.",
        action: "Run the final QA checklist on at least one AES-ready video and one legacy/non-AES video before enabling required mode in production."
      )

      statuses = checks.map { |check| check[:status].to_s }
      status = if statuses.include?("attention")
        "attention"
      elsif statuses.include?("warning") || statuses.include?("manual")
        readiness[:can_enable_required] ? "partial" : "manual"
      else
        "ok"
      end

      attention_count = statuses.count("attention")
      warning_count = statuses.count("warning")
      manual_count = statuses.count("manual")
      ready_for_final_signoff = attention_count.zero? && readiness[:can_enable_required]

      {
        generated_at: Time.now.utc.iso8601,
        status: status,
        ready_for_final_signoff: ready_for_final_signoff,
        aes_required_enabled: aes_required,
        attention_count: attention_count,
        warning_count: warning_count,
        manual_count: manual_count,
        checks: checks,
        recommendation: final_qa_recommendation(ready_for_final_signoff: ready_for_final_signoff, aes_required: aes_required, attention_count: attention_count, warning_count: warning_count, manual_count: manual_count),
      }
    rescue => e
      {
        generated_at: Time.now.utc.iso8601,
        status: "attention",
        ready_for_final_signoff: false,
        attention_count: 1,
        warning_count: 0,
        manual_count: 0,
        checks: [qa_check(code: "final_qa_failed", title: "Final QA check failed", status: "attention", summary: "#{e.class}: #{e.message}", action: "Fix the final QA report error before changing AES required settings.")],
        recommendation: "Final QA report failed. Check Rails logs before changing AES settings.",
      }
    end


    def qa_check(code:, title:, status:, summary:, action:)
      {
        code: code.to_s,
        title: title.to_s,
        status: status.to_s,
        label: status.to_s.tr("_", " ").capitalize,
        summary: summary.to_s,
        action: action.to_s,
      }
    end

    def final_qa_recommendation(ready_for_final_signoff:, aes_required:, attention_count:, warning_count:, manual_count:)
      if ready_for_final_signoff && aes_required
        "AES required mode is enabled and automated QA blockers were not found. Keep monitoring playback errors and key denials."
      elsif ready_for_final_signoff
        "Automated blockers are clear. Complete the manual browser/identify QA checklist on staging, then enable AES required mode."
      elsif attention_count.to_i.positive?
        "Resolve #{attention_count} attention item(s) before final AES sign-off."
      else
        "Review warning/manual QA items before production sign-off."
      end
    end

    def setting_int(name, default: 0)
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def setting_string(name, default: "")
      return default unless SiteSetting.respond_to?(name)
      SiteSetting.public_send(name).to_s
    rescue
      default
    end

    def setting_bool(name, default: false)
      return default unless SiteSetting.respond_to?(name)
      ActiveModel::Type::Boolean.new.cast(SiteSetting.public_send(name))
    rescue
      default
    end

    def store_for_role(item, role)
      backend = role["backend"].presence || item.managed_storage_backend
      profile = role["profile"].presence || item.managed_storage_profile.presence || ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      return nil unless %w[local s3].include?(backend.to_s)

      ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile)
    rescue
      nil
    end

    def key_join(*parts)
      parts.flatten.compact.map(&:to_s).reject(&:blank?).join("/").gsub(%r{/+}, "/").sub(%r{\A/}, "")
    end

    def log_maintenance!(event, item:, requested_by:, result:)
      ::MediaGallery::OperationLogger.info(
        event,
        item: item,
        operation: "hls_aes128_maintenance",
        data: result.merge(requested_by: requested_by.to_s.presence).except(:deleted_key_artifacts)
      ) if defined?(::MediaGallery::OperationLogger)
    rescue => e
      Rails.logger.warn("[media_gallery] AES maintenance log failed event=#{event} item_id=#{item&.id} error=#{e.class}: #{e.message}")
    end
  end
end
