# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "set"
require "tmpdir"
require "time"

module ::MediaGallery
  # Maintains one optional secondary copy of managed media assets on another
  # configured storage profile. The media item's own profile and manifest remain
  # canonical; a replica never changes playback routing or migration state.
  module StorageReplica
    module_function

    STATE_KEY = "storage_replica"
    PROFILE_KEYS = %w[local s3_1 s3_2 s3_3].freeze
    SCOPES = %w[hls_only all_managed_assets].freeze
    ACTIVE_STATUSES = %w[queued copying].freeze
    COMPLETE_STATUSES = %w[complete complete_unconfigured].freeze
    COPY_ATTEMPTS = 3
    MAX_RETAINED_REPLICAS = 8

    class RunSuperseded < StandardError; end

    def enabled?
      SiteSetting.respond_to?(:media_gallery_storage_replica_enabled) &&
        ActiveModel::Type::Boolean.new.cast(SiteSetting.media_gallery_storage_replica_enabled)
    rescue
      false
    end

    def destination_profile_key
      value = if SiteSetting.respond_to?(:media_gallery_storage_replica_profile_key)
        SiteSetting.media_gallery_storage_replica_profile_key.to_s
      end
      normalized = ::MediaGallery::StorageSettingsResolver.canonicalize_profile_key(value)
      PROFILE_KEYS.include?(normalized) ? normalized : "local"
    rescue
      "local"
    end

    def scope
      value = if SiteSetting.respond_to?(:media_gallery_storage_replica_scope)
        SiteSetting.media_gallery_storage_replica_scope.to_s
      end
      SCOPES.include?(value) ? value : "hls_only"
    rescue
      "hls_only"
    end

    def role_names_for_scope(value = scope)
      value.to_s == "all_managed_assets" ? %w[main thumbnail hls] : %w[hls]
    end

    def includes_hls?(value = scope)
      role_names_for_scope(value).include?("hls")
    end

    def all_managed_assets?(value = scope)
      value.to_s == "all_managed_assets"
    end

    # A global target can legitimately equal an individual item's current profile
    # during a rolling migration. That is a per-item no-op, not a broken global
    # configuration. Keep configuration validity and item applicability separate.
    def configured_replica_for_item(item)
      replica_enabled = enabled?
      source_profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
      target_profile_key = destination_profile_key.to_s
      source_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(source_profile_key).to_s
      target_backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(target_profile_key).to_s
      source_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(source_profile_key).to_s.presence
      target_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(target_profile_key).to_s.presence
      errors = []

      errors << "storage_replica_source_profile_missing" if source_profile_key.blank? || source_backend.blank?
      errors << "storage_replica_target_profile_missing" if target_profile_key.blank? || target_backend.blank?
      errors.concat(profile_validation_errors(source_profile_key, prefix: "source")) if source_profile_key.present?
      errors.concat(profile_validation_errors(target_profile_key, prefix: "target")) if target_profile_key.present?

      not_applicable_reason = nil
      managed_roles = managed_roles_for_item(item)
      selected_scope = scope
      if errors.blank? && managed_roles.blank?
        not_applicable_reason = "storage_replica_item_not_managed"
      elsif errors.blank? && selected_scope == "hls_only" && !managed_roles.key?("hls")
        not_applicable_reason = "storage_replica_hls_role_absent"
      elsif errors.blank? && selected_scope == "all_managed_assets" && !managed_roles.key?("main")
        not_applicable_reason = "storage_replica_main_role_absent"
      elsif errors.blank? && source_profile_key == target_profile_key
        not_applicable_reason = "storage_replica_source_equals_target"
      elsif errors.blank? && source_location.present? && target_location.present? && source_location == target_location
        not_applicable_reason = "storage_replica_source_equals_target_location"
      end

      configuration_valid = errors.blank?
      applicable = replica_enabled && configuration_valid && not_applicable_reason.blank?

      {
        enabled: replica_enabled,
        configuration_valid: configuration_valid,
        applicable: applicable,
        valid: applicable,
        errors: errors.uniq,
        not_applicable_reason: not_applicable_reason,
        source_profile_key: source_profile_key.presence,
        source_backend: source_backend.presence,
        source_location_fingerprint_key: source_location,
        target_profile_key: target_profile_key.presence,
        target_backend: target_backend.presence,
        target_location_fingerprint_key: target_location,
        scope: selected_scope,
      }
    rescue => e
      {
        enabled: enabled?,
        configuration_valid: false,
        applicable: false,
        valid: false,
        errors: ["storage_replica_configuration_error:#{e.class}"],
        scope: scope,
        target_profile_key: destination_profile_key,
      }
    end

    def current_replica_expected_for?(item, target_profile_key:, replica_scope: nil)
      config = configured_replica_for_item(item)
      return false unless config[:applicable]
      return false unless config[:target_profile_key].to_s == target_profile_key.to_s
      return true if replica_scope.blank?

      config[:scope].to_s == replica_scope.to_s
    rescue
      false
    end

    # Used by destructive cleanup. Any enabled replica on the same target
    # conflicts with cleanup, even when its current scope differs, because the
    # scopes overlap (both include HLS and all-assets additionally includes main
    # and thumbnail).
    def current_replica_target_expected_for?(item, target_profile_key:)
      config = configured_replica_for_item(item)
      config[:applicable] && config[:target_profile_key].to_s == target_profile_key.to_s
    rescue
      false
    end

    def local_hls_fallback_enabled_for?(item)
      config = configured_replica_for_item(item)
      return false unless config[:applicable]
      return false unless config[:target_profile_key].to_s == "local"
      return false unless includes_hls?(config[:scope])

      state = state_for(item)
      exact = state_for_target_scope_from_state(
        state,
        target_profile_key: "local",
        replica_scope: config[:scope],
      )

      # Compatibility for a pre-replica local HLS copy: when no replica record
      # exists at all, the normal local HLS readiness check still decides whether
      # the copy is usable. As soon as this subsystem has a record, only a current
      # completed generation may act as fallback, preventing stale packages from
      # being served while an asynchronous refresh is queued or has failed.
      return true if exact.blank? && replica_records(state).blank?
      return false unless exact["status"].to_s == "complete"
      return false unless exact["source_generation"].to_s == source_generation(item).to_s

      true
    rescue
      false
    end

    def managed_roles_for_item(item)
      manifest = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash : nil
      manifest = manifest.deep_stringify_keys if manifest.is_a?(Hash)
      roles = manifest.is_a?(Hash) ? manifest["roles"] : nil
      return {} unless roles.is_a?(Hash)

      roles.each_with_object({}) do |(name, role), result|
        next unless role.is_a?(Hash) && %w[local s3].include?(role["backend"].to_s)

        result[name.to_s] = role
      end
    rescue
      {}
    end
    private_class_method :managed_roles_for_item

    def state_for(item)
      meta = item&.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def state_for_target_scope(item, target_profile_key:, replica_scope:)
      state_for_target_scope_from_state(
        state_for(item),
        target_profile_key: target_profile_key,
        replica_scope: replica_scope,
      )
    end

    def replica_records(state_or_item)
      state = state_or_item.respond_to?(:extra_metadata) ? state_for(state_or_item) : state_or_item
      return [] unless state.is_a?(Hash)

      records = []
      if state["target_profile_key"].present? && state["scope"].present?
        records << state.except("retained_replicas")
      end
      records.concat(Array(state["retained_replicas"]).select { |row| row.is_a?(Hash) })
      records
        .map(&:deep_stringify_keys)
        .uniq { |row| [row["target_profile_key"].to_s, row["scope"].to_s] }
    rescue
      []
    end

    def save_state!(item, state, expected_run_token: nil)
      writer = lambda do
        meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
        current = meta[STATE_KEY].is_a?(Hash) ? meta[STATE_KEY].deep_stringify_keys : {}
        if expected_run_token.present? && current["run_token"].to_s != expected_run_token.to_s
          raise RunSuperseded, "storage_replica_run_superseded"
        end

        meta[STATE_KEY] = state
        item.update_columns(extra_metadata: meta, updated_at: Time.now)
        state
      end

      if item&.persisted? && item.respond_to?(:with_lock)
        item.with_lock { writer.call }
      else
        item.reload if item&.persisted?
        writer.call
      end
    end

    def source_generation(item)
      manifest = item.respond_to?(:storage_manifest_hash) ? item.storage_manifest_hash : {}
      roles = manifest.is_a?(Hash) ? manifest.fetch("roles", {}) : {}
      payload = {
        public_id: item.public_id.to_s,
        profile_key: ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s,
        manifest_generated_at: manifest.is_a?(Hash) ? manifest["generated_at"].to_s : "",
        role_generations: roles.each_with_object({}) do |(name, role), result|
          next unless role.is_a?(Hash)
          result[name.to_s] = [
            role["backend"],
            role["key"],
            role["key_prefix"],
            role["generated_at"],
            role.dig("encryption", "key_id"),
          ]
        end,
      }
      Digest::SHA256.hexdigest(payload.to_json)
    rescue
      Digest::SHA256.hexdigest([item&.id, item&.updated_at&.to_f].join(":"))
    end

    def enqueue_after_primary_change!(item, reason:, requested_by: nil, force: false)
      return false unless enabled?

      result = enqueue_for_item!(item, reason: reason, requested_by: requested_by, force: force)
      result.is_a?(Hash) && result["status"].to_s != "not_applicable"
    rescue => e
      Rails.logger.warn(
        "[media_gallery] storage replica enqueue failed item_id=#{item&.id} public_id=#{item&.public_id} " \
        "reason=#{reason} error=#{e.class}: #{e.message}"
      )
      false
    end

    def enqueue_for_item!(item, reason:, requested_by: nil, force: false)
      raise "media_item_required" if item.blank?
      raise "media_item_not_ready" unless item.ready?
      raise "media_item_assets_deleted" if asset_deleted?(item)

      config = configured_replica_for_item(item)
      raise(config[:errors].first || "storage_replica_configuration_invalid") unless config[:configuration_valid]
      unless config[:applicable]
        return {
          "status" => "not_applicable",
          "reason" => config[:not_applicable_reason].to_s.presence || "storage_replica_disabled",
          "target_profile_key" => config[:target_profile_key],
          "scope" => config[:scope],
        }.compact
      end

      generation = source_generation(item)
      existing = state_for(item)
      same_run = existing["source_generation"].to_s == generation &&
        existing["source_profile_key"].to_s == config[:source_profile_key].to_s &&
        existing["target_profile_key"].to_s == config[:target_profile_key].to_s &&
        existing["scope"].to_s == config[:scope].to_s
      if !force && same_run && (ACTIVE_STATUSES + ["complete"]).include?(existing["status"].to_s)
        return existing
      end

      retained = retained_replicas_for_next_run(existing, config)
      same_target = existing["target_profile_key"].to_s == config[:target_profile_key].to_s
      prior_single_keys = same_target ? Array(existing["replicated_single_keys"]) : []
      prior_prefixes = same_target ? Array(existing["replicated_prefixes"]) : []

      token = SecureRandom.hex(16)
      state = {
        "schema_version" => 2,
        "status" => "queued",
        "queued_at" => Time.now.utc.iso8601,
        "run_token" => token,
        "reason" => reason.to_s,
        "requested_by" => requested_by.to_s.presence,
        "source_profile_key" => config[:source_profile_key],
        "source_backend" => config[:source_backend],
        "source_location_fingerprint_key" => config[:source_location_fingerprint_key],
        "target_profile_key" => config[:target_profile_key],
        "target_backend" => config[:target_backend],
        "target_location_fingerprint_key" => config[:target_location_fingerprint_key],
        "scope" => config[:scope],
        "source_generation" => generation,
        "force" => !!force,
        # Keep same-target keys visible while a scope refresh is in progress so
        # reconciliation never misclassifies them as an unrelated orphan.
        "replicated_single_keys" => prior_single_keys,
        "replicated_prefixes" => prior_prefixes,
        "retained_replicas" => retained,
      }.compact
      save_state!(item, state)

      job_id = ::Jobs.enqueue(
        :media_gallery_replicate_item,
        media_item_id: item.id,
        run_token: token,
        reason: reason.to_s,
        requested_by: requested_by.to_s.presence,
        force: !!force,
      )

      # A fast Sidekiq worker can start before Jobs.enqueue returns. Never write the
      # original queued snapshot back over a copying or completed state.
      item.reload
      latest = state_for(item)
      if latest["run_token"].to_s == token && latest["status"].to_s == "queued"
        latest["job_id"] = job_id.to_s.presence
        latest["job_enqueued_at"] = Time.now.utc.iso8601
        save_state!(item, latest, expected_run_token: token)
      end
      state_for(item)
    rescue RunSuperseded
      state_for(item)
    rescue => e
      mark_failed_without_raising!(item, e, reason: reason, expected_run_token: (token rescue nil))
      raise e
    end

    def perform!(item, run_token:, reason: nil, requested_by: nil, force: false)
      synchronize_item(item) do
        item.reload
        state = state_for(item)
        if run_token.present? && state["run_token"].to_s != run_token.to_s
          return state
        end
        current_token = state["run_token"].to_s.presence || run_token.to_s.presence
        return mark_cancelled!(item, state, "media_item_not_ready", expected_run_token: current_token) unless item.ready?
        return mark_cancelled!(item, state, "media_item_assets_deleted", expected_run_token: current_token) if asset_deleted?(item)

        config = configured_replica_for_item(item)
        unless config[:configuration_valid]
          return mark_cancelled!(
            item,
            state,
            config[:errors].first || "storage_replica_configuration_invalid",
            expected_run_token: current_token,
          )
        end
        unless config[:applicable]
          return mark_cancelled!(
            item,
            state,
            config[:not_applicable_reason].to_s.presence || "storage_replica_disabled",
            expected_run_token: current_token,
          )
        end
        unless queued_configuration_matches?(state, config)
          return mark_cancelled!(
            item,
            state,
            "storage_replica_configuration_changed",
            expected_run_token: current_token,
          )
        end

        source_store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(config[:source_profile_key])
        target_store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(config[:target_profile_key])
        raise "storage_replica_source_store_unavailable" if source_store.blank?
        raise "storage_replica_target_store_unavailable" if target_store.blank?
        source_store.ensure_available!
        target_store.ensure_available!

        generation = source_generation(item)
        objects = replica_objects_for(item, source_store: source_store, replica_scope: config[:scope])
        validate_replica_object_set!(item, objects, replica_scope: config[:scope])
        state = state.merge(
          "status" => "copying",
          "started_at" => Time.now.utc.iso8601,
          "reason" => reason.to_s.presence || state["reason"],
          "requested_by" => requested_by.to_s.presence || state["requested_by"],
          "source_profile_key" => config[:source_profile_key],
          "source_backend" => config[:source_backend],
          "target_profile_key" => config[:target_profile_key],
          "target_backend" => config[:target_backend],
          "scope" => config[:scope],
          "source_generation" => generation,
          "object_count" => objects.length,
          "objects_copied" => 0,
          "objects_failed" => 0,
          "bytes_copied" => 0,
        ).except("last_error", "last_error_class", "failed_at", "cancelled_at", "cancel_reason")
        save_state!(item, state, expected_run_token: current_token)

        copied = 0
        bytes_copied = 0
        copied_keys = []
        role_names = []
        stage_prefix = local_hls_stage_prefix(item, target_store, objects, state["run_token"])
        prepare_local_hls_stage!(target_store, stage_prefix) if stage_prefix.present?
        stage_published = false

        begin
          Dir.mktmpdir("media_gallery_replica") do |tmpdir|
            objects.each_with_index do |object, index|
              current_run_state!(item, current_token, expected_generation: generation)

              final_key = normalize_key(object[:key])
              raise "storage_replica_object_key_invalid" if final_key.blank?

              source_info = source_store.object_info(final_key).deep_symbolize_keys
              raise "storage_replica_source_object_missing:#{final_key}" unless source_info[:exists]
              raise "storage_replica_source_object_empty:#{final_key}" if source_info[:bytes].to_i <= 0

              write_key = replica_write_key(final_key, item: item, stage_prefix: stage_prefix)
              tmp_path = File.join(tmpdir, "object_#{index}_#{SecureRandom.hex(6)}")
              copy_object_with_retries!(
                source_store: source_store,
                target_store: target_store,
                source_key: final_key,
                target_key: write_key,
                content_type: object[:content_type].presence || "application/octet-stream",
                expected_bytes: source_info[:bytes].to_i,
                tmp_path: tmp_path,
              )
              verify_target_object!(target_store, write_key, expected_bytes: source_info[:bytes].to_i)

              copied += 1
              bytes_copied += source_info[:bytes].to_i
              copied_keys << final_key
              role_names << object[:role_name].to_s
              update_progress!(
                item,
                copied: copied,
                bytes_copied: bytes_copied,
                current_key: final_key,
                index: index + 1,
                total: objects.length,
                run_token: current_token,
                expected_generation: generation,
              )
            end
          end

          latest = current_run_state!(item, current_token, expected_generation: generation)
          current_config = configured_replica_for_item(item)
          still_expected = current_config[:applicable] && queued_configuration_matches?(state, current_config)

          # Local HLS is a possible playback fallback, so expose it atomically only
          # while this exact run is still configured and current. Non-local copies
          # are never used automatically, but destructive pruning is also skipped
          # when settings changed during the copy.
          if stage_prefix.present?
            unless still_expected
              return mark_cancelled!(
                item,
                latest,
                "storage_replica_configuration_changed_before_publish",
                expected_run_token: current_token,
              )
            end
            publish_local_hls_stage!(item, target_store, stage_prefix: stage_prefix)
            stage_published = true
          elsif still_expected && includes_hls?(config[:scope])
            prune_target_hls!(item, target_store, copied_keys)
          end

          if still_expected
            cleanup_superseded_single_keys!(
              target_store,
              prior_keys: superseded_single_keys_for(
                item,
                prior_keys: Array(state["replicated_single_keys"]),
                replica_scope: config[:scope],
                copied_keys: copied_keys,
                target_profile_key: config[:target_profile_key],
              ),
              current_keys: copied_keys,
              public_id: item.public_id,
            )
          end

          latest = current_run_state!(item, current_token, expected_generation: generation)
          current_config = configured_replica_for_item(item)
          still_expected = current_config[:applicable] && queued_configuration_matches?(state, current_config)
          finished_at = Time.now.utc.iso8601
          final_state = latest.merge(
            "status" => objects.empty? ? "skipped" : (still_expected ? "complete" : "complete_unconfigured"),
            "finished_at" => finished_at,
            "completed_at" => finished_at,
            "source_generation" => generation,
            "object_count" => objects.length,
            "objects_copied" => copied,
            "objects_failed" => 0,
            "bytes_copied" => bytes_copied,
            "replicated_role_names" => role_names.reject(&:blank?).uniq,
            "replicated_single_keys" => copied_keys.reject { |key| hls_key_for_item?(item, key) },
            "replicated_prefixes" => copied_keys.any? { |key| hls_key_for_item?(item, key) } ? [hls_prefix_for(item)] : [],
          ).except("current_key", "progress_index", "progress_total", "last_error", "last_error_class", "failed_at")
          save_state!(item, final_state, expected_run_token: current_token)
          log_event("storage_replica_completed", item, final_state)
          final_state
        ensure
          cleanup_local_hls_stage!(target_store, stage_prefix) if stage_prefix.present? && !stage_published
        end
      end
    rescue RunSuperseded
      state_for(item)
    rescue => e
      failed = state_for(item)
      return failed if run_token.present? && failed["run_token"].to_s != run_token.to_s

      failed["status"] = "failed"
      failed["failed_at"] = Time.now.utc.iso8601
      failed["finished_at"] = failed["failed_at"]
      failed["last_error_class"] = e.class.to_s
      failed["last_error"] = e.message.to_s.truncate(800)
      failed["objects_failed"] = failed["objects_failed"].to_i + 1
      begin
        save_state!(item, failed, expected_run_token: failed["run_token"].to_s.presence) if item&.persisted?
      rescue RunSuperseded
        return state_for(item)
      end
      log_event("storage_replica_failed", item, failed, severity: :error)
      raise e
    end

    def replica_objects_for(item, source_store:, replica_scope: scope)
      allowed = role_names_for_scope(replica_scope)
      ::MediaGallery::MigrationPreview.objects_for_item(item, store: source_store)
        .map { |row| row.deep_symbolize_keys }
        .select { |row| allowed.include?(row[:role_name].to_s) }
        .reject { |row| row[:key].to_s.blank? }
        .uniq { |row| normalize_key(row[:key]) }
    end

    def validate_replica_object_set!(item, objects, replica_scope:)
      role_counts = Array(objects).each_with_object(Hash.new(0)) do |row, counts|
        counts[row[:role_name].to_s] += 1
      end

      if all_managed_assets?(replica_scope)
        main = ::MediaGallery::AssetManifest.role_for(item, "main")
        unless main.is_a?(Hash) && %w[local s3].include?(main["backend"].to_s) && main["key"].present?
          raise "storage_replica_main_role_not_managed"
        end
        raise "storage_replica_main_object_not_enumerated" unless role_counts["main"].positive?
      end

      %w[thumbnail hls].each do |role_name|
        next unless role_names_for_scope(replica_scope).include?(role_name)
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?
        raise "storage_replica_#{role_name}_role_not_managed" unless role.is_a?(Hash) && %w[local s3].include?(role["backend"].to_s)
        raise "storage_replica_#{role_name}_objects_not_enumerated" unless role_counts[role_name].positive?
      end
      true
    end
    private_class_method :validate_replica_object_set!

    def replica_layout_for(item, replica_scope: scope, state: nil)
      roles = role_names_for_scope(replica_scope)
      main = ::MediaGallery::AssetManifest.role_for(item, "main")
      thumbnail = ::MediaGallery::AssetManifest.role_for(item, "thumbnail")
      hls = ::MediaGallery::AssetManifest.role_for(item, "hls")
      single_keys = []
      single_keys << main["key"].to_s if roles.include?("main") && main.is_a?(Hash) && main["key"].present?
      single_keys << thumbnail["key"].to_s if roles.include?("thumbnail") && thumbnail.is_a?(Hash) && thumbnail["key"].present?
      single_keys.concat(Array(state&.dig("replicated_single_keys")))
      prefixes = []
      if roles.include?("hls") && hls.is_a?(Hash)
        prefixes << (hls["key_prefix"].to_s.presence || hls_prefix_for(item))
      end
      prefixes.concat(Array(state&.dig("replicated_prefixes")))
      {
        role_names: roles,
        single_keys: single_keys.map { |key| normalize_key(key) }.reject(&:blank?).uniq,
        prefixes: prefixes.map { |prefix| normalize_key(prefix) }.reject(&:blank?).uniq,
      }
    rescue
      { role_names: roles || [], single_keys: [], prefixes: [] }
    end

    def presence_on_profile(item, profile_key:, replica_scope:, state: nil, object_limit: 20_000)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      return { present: false, object_count: 0, keys: [], prefixes: [], object_info_by_key: {}, errors: ["store_unavailable"] } if store.blank?

      layout = replica_layout_for(item, replica_scope: replica_scope, state: state)
      info_by_key = {}
      layout[:single_keys].each do |key|
        info = store.object_info(key).deep_stringify_keys
        next unless ActiveModel::Type::Boolean.new.cast(info["exists"])

        normalized = normalize_key(key)
        info_by_key[normalized] = info.merge("key" => normalized)
      end

      prefixes = []
      layout[:prefixes].each do |prefix|
        listed = if store.respond_to?(:list_prefix_entries)
          Array(store.list_prefix_entries(prefix, limit: object_limit))
        else
          Array(store.list_prefix(prefix, limit: object_limit)).map { |key| { key: key } }
        end
        next if listed.blank?

        prefixes << prefix
        listed.each do |entry|
          value = entry.is_a?(Hash) ? entry.deep_stringify_keys : { "key" => entry.to_s }
          normalized = normalize_key(value["key"])
          next if normalized.blank?

          info_by_key[normalized] = value.merge("key" => normalized, "exists" => true)
        end
      end

      all_keys = info_by_key.keys.sort
      {
        present: all_keys.present?,
        object_count: all_keys.length,
        keys: all_keys,
        prefixes: prefixes,
        object_info_by_key: info_by_key,
        layout: layout,
        errors: [],
      }
    rescue => e
      { present: false, object_count: 0, keys: [], prefixes: [], object_info_by_key: {}, errors: ["#{e.class}: #{e.message}"] }
    end

    def mark_cleaned!(item, target_profile_key:, replica_scope:, deleted_keys:, deleted_prefixes:)
      state = state_for(item)
      retained = Array(state["retained_replicas"]).select { |row| row.is_a?(Hash) }
      retained.reject! do |row|
        row["target_profile_key"].to_s == target_profile_key.to_s && row["scope"].to_s == replica_scope.to_s
      end
      state["retained_replicas"] = retained

      if state["target_profile_key"].to_s == target_profile_key.to_s && state["scope"].to_s == replica_scope.to_s
        state["status"] = "cleaned"
        state["cleaned_at"] = Time.now.utc.iso8601
        state["cleaned_scope"] = replica_scope.to_s
        state["cleaned_keys"] = Array(deleted_keys).first(20)
        state["cleaned_prefixes"] = Array(deleted_prefixes).first(20)
        state["replicated_single_keys"] = []
        state["replicated_prefixes"] = []
      end
      save_state!(item, state)
    rescue
      state_for(item)
    end

    def synchronize_item(item, &block)
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize("media_gallery_storage_replica_#{item.id}", validity: 12.hours, &block)
      else
        yield
      end
    end

    def normalize_key(value)
      value.to_s.sub(%r{\A/+}, "").delete_suffix("/")
    end

    def asset_deleted?(item)
      return false if item.blank?

      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      meta["reported_asset_deletion"].is_a?(Hash) ||
        meta["asset_deleted_after_report"].present? ||
        item.status.to_s == "asset_deleted"
    rescue
      false
    end
    private_class_method :asset_deleted?

    def profile_validation_errors(profile_key, prefix:)
      return ["storage_replica_#{prefix}_profile_missing"] if profile_key.blank?

      Array(::MediaGallery::StorageSettingsResolver.validate_profile(profile_key)).map do |error|
        "storage_replica_#{prefix}_#{error}"
      end
    rescue => e
      ["storage_replica_#{prefix}_profile_validation_error:#{e.class}"]
    end
    private_class_method :profile_validation_errors

    def state_for_target_scope_from_state(state, target_profile_key:, replica_scope:)
      replica_records(state).find do |row|
        row["target_profile_key"].to_s == target_profile_key.to_s && row["scope"].to_s == replica_scope.to_s
      end || {}
    rescue
      {}
    end
    private_class_method :state_for_target_scope_from_state

    def replica_record_present?(record)
      return false unless record.is_a?(Hash)
      return true if Array(record["replicated_single_keys"]).present?
      return true if Array(record["replicated_prefixes"]).present?

      COMPLETE_STATUSES.include?(record["status"].to_s) && record["object_count"].to_i.positive?
    end
    private_class_method :replica_record_present?

    def retained_replicas_for_next_run(existing, config)
      retained = Array(existing["retained_replicas"]).select { |row| row.is_a?(Hash) }.map(&:deep_stringify_keys)
      old_target = existing["target_profile_key"].to_s
      old_scope = existing["scope"].to_s
      new_target = config[:target_profile_key].to_s

      if replica_record_present?(existing) && old_target.present? && old_scope.present? && old_target != new_target
        retained << replica_record_snapshot(existing)
      end

      # A successful new copy to a target supersedes any older retained record on
      # that same target. Same-target scope reductions are handled by strict stale
      # single-key cleanup after the new HLS package is committed.
      retained.reject! { |row| row["target_profile_key"].to_s == new_target }
      retained
        .uniq { |row| [row["target_profile_key"].to_s, row["scope"].to_s] }
        .last(MAX_RETAINED_REPLICAS)
    rescue
      []
    end
    private_class_method :retained_replicas_for_next_run

    def replica_record_snapshot(record)
      record.slice(
        "schema_version",
        "status",
        "source_profile_key",
        "source_backend",
        "source_location_fingerprint_key",
        "target_profile_key",
        "target_backend",
        "target_location_fingerprint_key",
        "scope",
        "source_generation",
        "object_count",
        "objects_copied",
        "bytes_copied",
        "replicated_role_names",
        "replicated_single_keys",
        "replicated_prefixes",
        "completed_at",
        "finished_at",
      ).merge("retained_at" => Time.now.utc.iso8601)
    end
    private_class_method :replica_record_snapshot

    def queued_configuration_matches?(state, config)
      state["source_profile_key"].to_s == config[:source_profile_key].to_s &&
        state["target_profile_key"].to_s == config[:target_profile_key].to_s &&
        state["scope"].to_s == config[:scope].to_s
    end
    private_class_method :queued_configuration_matches?

    def current_run_state!(item, run_token, expected_generation: nil)
      item.reload
      state = state_for(item)
      if run_token.present? && state["run_token"].to_s != run_token.to_s
        raise RunSuperseded, "storage_replica_run_superseded"
      end
      raise RunSuperseded, "storage_replica_item_not_ready" unless item.ready?
      raise RunSuperseded, "storage_replica_item_assets_deleted" if asset_deleted?(item)
      if expected_generation.present? && source_generation(item).to_s != expected_generation.to_s
        raise RunSuperseded, "storage_replica_source_generation_changed"
      end

      state
    end
    private_class_method :current_run_state!

    def mark_cancelled!(item, state, reason, expected_run_token: nil)
      state = state.deep_dup
      state["status"] = "cancelled"
      state["cancelled_at"] = Time.now.utc.iso8601
      state["finished_at"] = state["cancelled_at"]
      state["cancel_reason"] = reason.to_s
      save_state!(item, state, expected_run_token: expected_run_token)
    end
    private_class_method :mark_cancelled!

    def mark_failed_without_raising!(item, error, reason:, expected_run_token: nil)
      return unless item&.persisted?

      item.reload
      state = state_for(item)
      return state if expected_run_token.present? && state["run_token"].to_s != expected_run_token.to_s

      state["status"] = "failed"
      state["reason"] = reason.to_s
      state["failed_at"] = Time.now.utc.iso8601
      state["last_error_class"] = error.class.to_s
      state["last_error"] = error.message.to_s.truncate(800)
      save_state!(item, state, expected_run_token: expected_run_token)
    rescue RunSuperseded
      state_for(item)
    rescue
      nil
    end
    private_class_method :mark_failed_without_raising!

    def copy_object_with_retries!(source_store:, target_store:, source_key:, target_key:, content_type:, expected_bytes:, tmp_path:)
      last_error = nil
      COPY_ATTEMPTS.times do |index|
        begin
          FileUtils.rm_f(tmp_path)
          source_store.download_to_file!(source_key, tmp_path, expected_bytes: expected_bytes.positive? ? expected_bytes : nil)
          raise "storage_replica_download_missing:#{source_key}" unless File.exist?(tmp_path)
          if expected_bytes.positive? && File.size(tmp_path).to_i != expected_bytes
            raise "storage_replica_download_size_mismatch:#{source_key}"
          end
          target_store.put_file!(tmp_path, key: target_key, content_type: content_type)
          return true
        rescue => e
          last_error = e
          sleep([0.5 * (index + 1), 2.0].min) if index + 1 < COPY_ATTEMPTS
        ensure
          FileUtils.rm_f(tmp_path)
        end
      end
      raise(last_error || "storage_replica_copy_failed:#{source_key}")
    end
    private_class_method :copy_object_with_retries!

    def verify_target_object!(target_store, key, expected_bytes:)
      info = target_store.object_info(key).deep_symbolize_keys
      raise "storage_replica_target_object_missing:#{key}" unless info[:exists]
      if expected_bytes.positive? && info[:bytes].to_i != expected_bytes
        raise "storage_replica_target_size_mismatch:#{key}"
      end
      true
    end
    private_class_method :verify_target_object!

    def hls_prefix_for(item)
      File.join(item.public_id.to_s, "hls")
    end
    private_class_method :hls_prefix_for

    def hls_key_for_item?(item, key)
      normalized = normalize_key(key)
      prefix = hls_prefix_for(item)
      normalized == prefix || normalized.start_with?(prefix + "/")
    end
    private_class_method :hls_key_for_item?

    def local_hls_stage_prefix(item, target_store, objects, run_token)
      return nil unless target_store.respond_to?(:backend) && target_store.backend.to_s == "local"
      return nil unless Array(objects).any? { |row| hls_key_for_item?(item, row[:key]) }

      safe_token = run_token.to_s.gsub(/[^a-zA-Z0-9]+/, "")[0, 40]
      safe_token = SecureRandom.hex(12) if safe_token.blank?
      File.join(item.public_id.to_s, "hls__tmp_replica_#{safe_token}")
    end
    private_class_method :local_hls_stage_prefix

    def prepare_local_hls_stage!(target_store, stage_prefix)
      return if stage_prefix.blank?

      target_store.delete_prefix(stage_prefix)
      remaining = Array(target_store.list_prefix(stage_prefix, limit: 1))
      raise "storage_replica_local_stage_not_empty" if remaining.present?
      if target_store.respond_to?(:prune_empty_prefix_directory)
        target_store.prune_empty_prefix_directory(stage_prefix, boundary_prefix: stage_prefix.split("/").first)
      end
      true
    end
    private_class_method :prepare_local_hls_stage!

    def replica_write_key(final_key, item:, stage_prefix:)
      return final_key if stage_prefix.blank? || !hls_key_for_item?(item, final_key)

      relative = final_key.delete_prefix(hls_prefix_for(item)).sub(%r{\A/+}, "")
      raise "storage_replica_hls_relative_key_invalid" if relative.blank?
      File.join(stage_prefix, relative)
    end
    private_class_method :replica_write_key

    def publish_local_hls_stage!(item, target_store, stage_prefix:)
      unless target_store.respond_to?(:root_path) && target_store.backend.to_s == "local"
        raise "storage_replica_local_stage_store_invalid"
      end

      root = File.expand_path(target_store.root_path.to_s)
      item_root = ::MediaGallery::PathSecurity.safe_join!(root, item.public_id.to_s)
      stage_root = ::MediaGallery::PathSecurity.safe_join!(root, stage_prefix)
      final_root = ::MediaGallery::PathSecurity.safe_join!(root, hls_prefix_for(item))
      raise "storage_replica_local_stage_missing" unless Dir.exist?(stage_root)

      FileUtils.mkdir_p(item_root)
      old_root = ::MediaGallery::PathSecurity.safe_join!(
        item_root,
        "hls__old_replica_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}_#{SecureRandom.hex(4)}",
      )
      moved_old = false
      begin
        if Dir.exist?(final_root)
          FileUtils.mv(final_root, old_root)
          moved_old = true
        end
        FileUtils.mv(stage_root, final_root)
        ::MediaGallery::PathSecurity.remove_tree_under!(old_root, item_root) if moved_old && Dir.exist?(old_root)
        true
      rescue => e
        begin
          ::MediaGallery::PathSecurity.remove_tree_under!(final_root, item_root) if Dir.exist?(final_root)
          FileUtils.mv(old_root, final_root) if moved_old && Dir.exist?(old_root)
        rescue
          nil
        end
        raise e
      end
    end
    private_class_method :publish_local_hls_stage!

    def cleanup_local_hls_stage!(target_store, stage_prefix)
      return if stage_prefix.blank?

      target_store.delete_prefix(stage_prefix)
      if target_store.respond_to?(:prune_empty_prefix_directory)
        target_store.prune_empty_prefix_directory(stage_prefix, boundary_prefix: stage_prefix.split("/").first)
      end
      true
    rescue
      false
    end
    private_class_method :cleanup_local_hls_stage!

    def prune_target_hls!(item, target_store, copied_keys)
      prefix = hls_prefix_for(item)
      keep = copied_keys.map { |key| normalize_key(key) }.select { |key| key.start_with?(prefix + "/") }.to_set
      return if keep.blank?

      Array(target_store.list_prefix(prefix)).map { |key| normalize_key(key) }.each do |key|
        next if keep.include?(key)

        delete_replica_key_completely!(
          target_store,
          key,
          failure_code: "storage_replica_hls_prune_delete_failed",
        )
      end
    rescue => e
      raise "storage_replica_hls_prune_failed: #{e.class}: #{e.message}"
    end
    private_class_method :prune_target_hls!

    def superseded_single_keys_for(item, prior_keys:, replica_scope:, copied_keys:, target_profile_key:)
      keys = Array(prior_keys).dup
      hls_current = Array(copied_keys).any? { |key| hls_key_for_item?(item, key) }
      trim_inactive_migration_side = inactive_migration_profile?(
        item,
        target_profile_key: target_profile_key,
      )
      if replica_scope.to_s == "hls_only" && hls_current && trim_inactive_migration_side
        %w[main thumbnail].each do |role_name|
          role = ::MediaGallery::AssetManifest.role_for(item, role_name)
          next unless role.is_a?(Hash) && %w[local s3].include?(role["backend"].to_s)

          key = role["key"].to_s.presence
          keys << key if key.present?
        end
      end

      keys.map { |key| normalize_key(key) }.reject(&:blank?).uniq
    rescue
      Array(prior_keys)
    end
    private_class_method :superseded_single_keys_for

    def inactive_migration_profile?(item, target_profile_key:)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      switch_state = meta["migration_switch"]
      return false unless switch_state.is_a?(Hash)

      case switch_state["status"].to_s
      when "switched"
        switch_state["source_profile_key"].to_s == target_profile_key.to_s
      when "rolled_back"
        switch_state["target_profile_key"].to_s == target_profile_key.to_s
      else
        false
      end
    rescue
      false
    end
    private_class_method :inactive_migration_profile?

    def cleanup_superseded_single_keys!(target_store, prior_keys:, current_keys:, public_id:)
      current = current_keys.map { |key| normalize_key(key) }.to_set
      allowed = %w[main.mp4 main.mp3 main.jpg main.bin thumb.jpg].map { |name| File.join(public_id.to_s, name) }.to_set
      Array(prior_keys).each do |raw_key|
        key = normalize_key(raw_key)
        next if key.blank? || current.include?(key)
        raise "storage_replica_stale_key_scope_invalid:#{key}" unless allowed.include?(key)

        next unless target_store.exists?(key)

        delete_replica_key_completely!(
          target_store,
          key,
          failure_code: "storage_replica_stale_key_delete_failed",
        )
      end
      true
    end
    private_class_method :cleanup_superseded_single_keys!

    def delete_replica_key_completely!(store, key, failure_code:)
      if store.respond_to?(:purge_key!)
        begin
          result = store.purge_key!(key)
          result = result.deep_symbolize_keys if result.is_a?(Hash)
          remaining = store.exists?(key) rescue nil
          current_cleared = remaining == false ||
            (remaining.nil? && result.is_a?(Hash) && result[:remaining_current_count].to_i.zero?)
          versions_cleared = !result.is_a?(Hash) || result[:remaining_version_entries].nil? ||
            result[:remaining_version_entries].to_i.zero?
          return true if result.is_a?(Hash) && result[:ok] == true && current_cleared && versions_cleared

          raise "#{failure_code}:#{key}"
        rescue NotImplementedError
          # Compatibility with custom stores that inherit the abstract method.
        end
      end

      deleted = store.delete(key)
      raise "#{failure_code}:#{key}" unless deleted && !store.exists?(key)

      true
    end
    private_class_method :delete_replica_key_completely!

    def update_progress!(item, copied:, bytes_copied:, current_key:, index:, total:, run_token:, expected_generation:)
      latest = current_run_state!(item, run_token, expected_generation: expected_generation)
      latest["status"] = "copying"
      latest["objects_copied"] = copied
      latest["bytes_copied"] = bytes_copied
      latest["current_key"] = current_key
      latest["progress_index"] = index
      latest["progress_total"] = total
      latest["updated_at"] = Time.now.utc.iso8601
      save_state!(item, latest, expected_run_token: run_token)
    end
    private_class_method :update_progress!

    def log_event(name, item, state, severity: :info)
      return unless defined?(::MediaGallery::OperationLogger)

      method = severity == :error ? :error : :info
      ::MediaGallery::OperationLogger.public_send(
        method,
        name,
        item: item,
        operation: "storage_replica",
        data: state.slice(
          "status",
          "reason",
          "source_profile_key",
          "target_profile_key",
          "scope",
          "object_count",
          "objects_copied",
          "bytes_copied",
          "last_error",
        ),
      )
    rescue
      nil
    end
    private_class_method :log_event
  end
end
