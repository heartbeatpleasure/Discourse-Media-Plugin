# frozen_string_literal: true

require "cgi"
require "digest/sha1"
require "set"

module ::MediaGallery
  module StorageReconciler
    module_function

    CATEGORIES = {
      "missing_assets" => {
        title: "Missing assets",
        description: "Database items whose required upload or managed storage assets are missing.",
      },
      "orphaned_files" => {
        title: "Orphaned storage files",
        description: "Storage objects that are not referenced by any sampled media item or manifest.",
      },
      "deleted_media_leftovers" => {
        title: "Deleted media with remaining files",
        description: "Media items marked as asset-deleted while one or more storage objects still appear to exist.",
      },
      "invalid_storage_references" => {
        title: "Invalid storage references",
        description: "Items or manifests that point to missing profiles, invalid backends, or incomplete storage keys.",
      },
    }.freeze

    STORAGE_BACKENDS = %w[local s3].freeze
    KNOWN_PLUGIN_STORAGE_PREFIXES = {
      "forensics_exports" => "Forensics exports",
      "forensics_export_archive" => "Forensics export archive",
    }.freeze
    PUBLIC_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def run(item_limit: 500, object_limit: 2000, orphan_sample_limit: 50, progress_callback: nil)
      started_at = Time.zone.now
      item_limit = bounded_int(item_limit, min: 25, max: 5000, default: 500)
      object_limit = bounded_int(object_limit, min: 50, max: 20_000, default: 2000)
      orphan_sample_limit = bounded_int(orphan_sample_limit, min: 5, max: 500, default: 50)

      context = {
        expected_keys: Hash.new { |h, k| h[k] = Set.new },
        expected_prefixes: Hash.new { |h, k| h[k] = Set.new },
        findings: CATEGORIES.keys.index_with { [] },
        stats: {
          items_checked: 0,
          profiles_checked: 0,
          objects_scanned: 0,
          orphan_objects_found: 0,
          orphan_groups_found: 0,
          known_plugin_objects: 0,
          known_plugin_prefixes: [],
          unsampled_media_objects: 0,
          unsampled_media_prefixes: [],
          storage_replica_objects: 0,
          storage_replica_locations: [],
          truncated_profiles: [],
          truncated_profile_labels: [],
        },
        scanned_public_ids: Set.new,
        profiles: {
          configured: [],
          checked: [],
        },
      }

      emit_progress(
        progress_callback,
        stage: "inspecting_items",
        stage_label: "Inspecting media records and required assets",
        items_checked: 0,
        item_limit: item_limit,
        profiles_checked: 0,
        profiles_total: 0,
        objects_scanned: 0,
      )

      ::MediaGallery::MediaItem.includes(:user).order(updated_at: :desc).limit(item_limit).find_each do |item|
        context[:stats][:items_checked] += 1
        context[:scanned_public_ids] << item.public_id.to_s if item.public_id.present?
        inspect_item!(item, context)
      rescue => e
        add_finding(
          context,
          "invalid_storage_references",
          issue_type: "reconciliation_item_check_failed",
          severity: item.status.to_s == "ready" ? "warning" : "ok",
          item: item,
          label: "Item reconciliation check failed",
          detail: "#{e.class}: #{e.message}".truncate(500),
          suggestion: "Review this item in Media management and retry reconciliation after fixing the underlying error."
        )
      ensure
        emit_progress(
          progress_callback,
          stage: "inspecting_items",
          stage_label: "Inspecting media records and required assets",
          items_checked: context[:stats][:items_checked],
          item_limit: item_limit,
          profiles_checked: context[:stats][:profiles_checked],
          profiles_total: context.dig(:profiles, :configured).length,
          objects_scanned: context[:stats][:objects_scanned],
        )
      end

      scan_storage_profiles!(
        context,
        object_limit: object_limit,
        orphan_sample_limit: orphan_sample_limit,
        progress_callback: progress_callback,
        item_limit: item_limit,
      )

      emit_progress(
        progress_callback,
        stage: "finalizing",
        stage_label: "Finalizing reconciliation report",
        items_checked: context[:stats][:items_checked],
        item_limit: item_limit,
        profiles_checked: context[:stats][:profiles_checked],
        profiles_total: context.dig(:profiles, :configured).length,
        objects_scanned: context[:stats][:objects_scanned],
      )

      finished_at = Time.zone.now
      categories = CATEGORIES.map do |key, meta|
        findings = Array(context[:findings][key])
        {
          id: key,
          title: meta[:title],
          description: meta[:description],
          severity: highest_severity(findings.map { |finding| finding[:severity] }),
          count: findings.length,
          findings: findings,
        }
      end

      report = {
        ok: categories.all? { |category| category[:severity].to_s == "ok" },
        severity: highest_severity(categories.map { |category| category[:severity] }),
        generated_at: started_at.iso8601,
        generated_at_label: started_at.strftime("%Y-%m-%d %H:%M:%S"),
        finished_at: finished_at.iso8601,
        duration_ms: ((finished_at - started_at) * 1000).round,
        read_only: true,
        cleanup_available: false,
        limits: {
          item_limit: item_limit,
          object_limit: object_limit,
          orphan_sample_limit: orphan_sample_limit,
        },
        stats: context[:stats],
        profiles: context[:profiles],
        categories: categories,
        classifications: reconciliation_classification_summary(context),
      }

      emit_progress(
        progress_callback,
        stage: "complete",
        stage_label: "Storage reconciliation completed",
        items_checked: context[:stats][:items_checked],
        item_limit: item_limit,
        profiles_checked: context[:stats][:profiles_checked],
        profiles_total: context.dig(:profiles, :configured).length,
        objects_scanned: context[:stats][:objects_scanned],
      )

      report
    rescue => e
      Rails.logger.error("[media_gallery] storage reconciliation failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      emit_progress(
        progress_callback,
        stage: "failed",
        stage_label: "Storage reconciliation failed",
        items_checked: context&.dig(:stats, :items_checked).to_i,
        item_limit: item_limit,
        profiles_checked: context&.dig(:stats, :profiles_checked).to_i,
        profiles_total: context&.dig(:profiles, :configured)&.length.to_i,
        objects_scanned: context&.dig(:stats, :objects_scanned).to_i,
      )
      {
        ok: false,
        severity: "critical",
        generated_at: Time.zone.now.iso8601,
        generated_at_label: Time.zone.now.strftime("%Y-%m-%d %H:%M:%S"),
        read_only: true,
        cleanup_available: false,
        stats: {},
        limits: { item_limit: item_limit, object_limit: object_limit, orphan_sample_limit: orphan_sample_limit },
        categories: [
          {
            id: "invalid_storage_references",
            title: CATEGORIES.dig("invalid_storage_references", :title),
            description: CATEGORIES.dig("invalid_storage_references", :description),
            severity: "critical",
            count: 1,
            findings: [
              finding_payload(
                category: "invalid_storage_references",
                issue_type: "reconciliation_failed",
                severity: "critical",
                label: "Storage reconciliation failed",
                detail: "#{e.class}: #{e.message}".truncate(500),
                suggestion: "Check Rails logs and retry. No cleanup or file changes were performed."
              ),
            ],
          },
        ],
      }
    end

    def inspect_item!(item, context)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      backend = ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key)
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil

      if profile_key.blank? || backend.blank? || store.blank?
        add_finding(
          context,
          "invalid_storage_references",
          issue_type: "invalid_storage_profile",
          severity: item.status.to_s == "ready" ? "critical" : "warning",
          item: item,
          profile_key: profile_key,
          backend: backend,
          label: "Invalid storage profile",
          detail: "The item resolves to a storage profile that is missing or unavailable.",
          suggestion: "Check the item's managed storage profile and the configured storage settings."
        )
        return
      end

      roles = roles_for_item(item)
      register_expected_roles!(context, item, roles, profile_key: profile_key)
      inspect_storage_replicas!(context, item, roles, profile_key: profile_key, backend: backend)
      check_invalid_roles!(context, item, roles, profile_key: profile_key, backend: backend)
      check_missing_assets!(context, item, roles, profile_key: profile_key, backend: backend)
      check_deleted_leftovers!(context, item, roles, profile_key: profile_key, backend: backend) if asset_deleted?(item)
    end

    def roles_for_item(item)
      {
        "main" => ::MediaGallery::AssetManifest.role_for(item, "main"),
        "thumbnail" => ::MediaGallery::AssetManifest.role_for(item, "thumbnail"),
        "hls" => ::MediaGallery::AssetManifest.role_for(item, "hls"),
      }.compact
    end

    def register_expected_roles!(context, item, roles, profile_key:)
      roles.each do |_role_name, role|
        next unless role.is_a?(Hash)
        next unless STORAGE_BACKENDS.include?(role["backend"].to_s)

        role_keys(role).each { |key| context[:expected_keys][profile_key] << key }
        role_prefixes(item, role).each { |prefix| context[:expected_prefixes][profile_key] << normalized_prefix(prefix) }
      end
    end

    def inspect_storage_replicas!(context, item, roles, profile_key:, backend:)
      config = ::MediaGallery::StorageReplica.configured_replica_for_item(item)
      if config[:enabled] && !config[:configuration_valid]
        add_finding(
          context,
          "invalid_storage_references",
          issue_type: "storage_replica_configuration_invalid",
          severity: "warning",
          item: item,
          profile_key: config[:target_profile_key],
          backend: config[:target_backend],
          label: "Secondary storage replica configuration is invalid",
          replica_enabled: true,
          replica_scope: config[:scope],
          replica_target_profile_key: config[:target_profile_key],
          detail: "The secondary replica cannot run for this item: #{Array(config[:errors]).join(', ')}.",
          suggestion: "Choose a configured destination profile that differs from the active profile and physical storage location.",
        )
      end

      candidates = storage_replica_candidates(item, current_profile_key: profile_key, current_backend: backend)
      candidates.each do |candidate|
        target_profile_key = candidate[:target_profile_key].to_s
        replica_scope = candidate[:scope].to_s
        state = candidate[:state].is_a?(Hash) ? candidate[:state] : {}
        next if target_profile_key.blank? || target_profile_key == profile_key.to_s

        source_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(profile_key).to_s.presence
        target_location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(target_profile_key).to_s.presence
        next if source_location.present? && target_location.present? && source_location == target_location

        presence = ::MediaGallery::StorageReplica.presence_on_profile(
          item,
          profile_key: target_profile_key,
          replica_scope: replica_scope,
          state: state,
        )
        layout = presence[:layout] || ::MediaGallery::StorageReplica.replica_layout_for(item, replica_scope: replica_scope, state: state)
        expected_now = ::MediaGallery::StorageReplica.current_replica_expected_for?(
          item,
          target_profile_key: target_profile_key,
          replica_scope: replica_scope,
        ) && replica_source_roles_present?(roles, replica_scope: replica_scope)

        register_replica_layout!(context, target_profile_key, layout)

        if expected_now
          replica_complete = replica_state_current_and_complete?(
            item,
            state,
            target_profile_key: target_profile_key,
            replica_scope: replica_scope,
            presence: presence,
          )
          if !replica_complete && state.blank?
            replica_complete = replica_objects_match_primary?(
              item,
              target_profile_key: target_profile_key,
              replica_scope: replica_scope,
              presence: presence,
            )
          end
          next if replica_complete

          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "storage_replica_incomplete",
            severity: "warning",
            item: item,
            profile_key: target_profile_key,
            backend: ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(target_profile_key),
            label: "Secondary storage replica is incomplete",
            replica_enabled: true,
            replica_scope: replica_scope,
            replica_target_profile_key: target_profile_key,
            detail: storage_replica_incomplete_detail(item, state, presence, target_profile_key: target_profile_key, replica_scope: replica_scope),
            suggestion: "Check the storage replica job in Background jobs and verify the destination profile. A replica failure does not affect the canonical primary assets.",
          )
          next
        end

        next unless presence[:present]

        primary_available = primary_assets_available_for_replica?(item, replica_scope: replica_scope)
        register_storage_replica_stats!(context, target_profile_key, presence)
        add_finding(
          context,
          "orphaned_files",
          issue_type: "storage_replica_available_for_cleanup",
          severity: "warning",
          item: item,
          profile_key: target_profile_key,
          profile_label: profile_label_for_key(target_profile_key),
          profile_display_label: profile_display_label_for_key(target_profile_key),
          backend: ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(target_profile_key),
          storage_key: item.public_id.to_s,
          group_prefix: item.public_id.to_s,
          object_count: presence[:object_count].to_i,
          sample_keys: Array(presence[:keys]).first(5),
          classification: "storage_replica",
          current_profile_key: profile_key,
          current_profile_label: profile_label_for_key(profile_key),
          media_item_exists: true,
          replica_enabled: false,
          replica_scope: replica_scope,
          replica_target_profile_key: target_profile_key,
          primary_assets_available: primary_available,
          cleanup_available: primary_available,
          cleanup_kind: "cleanup_storage_replica",
          cleanup_label: "Remove secondary replica",
          cleanup_hint: "Deletes only the replicated managed asset roles from this non-current profile after a fresh complete verification of the active primary assets.",
          cleanup_risk: "low",
          label: "Secondary storage replica is no longer configured",
          detail: storage_replica_cleanup_detail(item, presence, target_profile_key: target_profile_key, replica_scope: replica_scope, primary_available: primary_available),
          suggestion: primary_available ? "Use Remove secondary replica to reclaim storage. The active primary assets are verified again immediately before deletion." : "Do not remove this replica yet. Restore or verify the active primary assets and rerun reconciliation.",
          can_ignore: true,
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] storage replica reconciliation failed public_id=#{item&.public_id} error=#{e.class}: #{e.message}")
    end

    def storage_replica_candidates(item, current_profile_key:, current_backend:)
      state = ::MediaGallery::StorageReplica.state_for(item) rescue {}
      records = ::MediaGallery::StorageReplica.replica_records(state)
      configured_target = ::MediaGallery::StorageReplica.destination_profile_key.to_s
      configured_scope = ::MediaGallery::StorageReplica.scope.to_s
      candidates = []

      if ::MediaGallery::StorageReplica.enabled?
        # The configured scope is the sole expected shape on its target. When the
        # scope has just changed, carry the prior target record into this candidate
        # so old main/thumbnail keys remain accounted for until the refresh job
        # removes them; do not produce an overlapping destructive cleanup finding.
        same_target_record = records.find { |row| row["target_profile_key"].to_s == configured_target }
        configured_state = same_target_record.present? ? same_target_record : {}
        candidates << { target_profile_key: configured_target, scope: configured_scope, state: configured_state }

        records.each do |record|
          next if record["target_profile_key"].to_s == configured_target
          candidates << {
            target_profile_key: record["target_profile_key"].to_s,
            scope: record["scope"].to_s,
            state: record,
          }
        end
      else
        candidates.concat(
          records.map do |record|
            {
              target_profile_key: record["target_profile_key"].to_s,
              scope: record["scope"].to_s,
              state: record,
            }
          end,
        )
        unless records.any? { |row| row["target_profile_key"].to_s == configured_target }
          candidates << { target_profile_key: configured_target, scope: configured_scope, state: {} }
        end
      end

      # Compatibility discovery for HLS-only local copies created by releases
      # before the general storage-replica settings existed.
      if current_backend.to_s == "s3" && current_profile_key.to_s != "local" && candidates.none? { |row| row[:target_profile_key].to_s == "local" }
        candidates << { target_profile_key: "local", scope: "hls_only", state: {} }
      end

      candidates
        .reject { |row| row[:target_profile_key].to_s.blank? || row[:scope].to_s.blank? }
        .uniq { |row| [row[:target_profile_key].to_s, row[:scope].to_s] }
    end
    private_class_method :storage_replica_candidates

    def replica_source_roles_present?(roles, replica_scope:)
      if replica_scope.to_s == "hls_only"
        roles["hls"].is_a?(Hash)
      else
        roles["main"].is_a?(Hash)
      end
    end
    private_class_method :replica_source_roles_present?

    def replica_objects_match_primary?(item, target_profile_key:, replica_scope:, presence:)
      return false unless presence[:present]
      source_profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      source_store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(source_profile_key)
      target_store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(target_profile_key)
      return false if source_store.blank? || target_store.blank?

      expected = ::MediaGallery::StorageReplica.replica_objects_for(
        item,
        source_store: source_store,
        replica_scope: replica_scope,
      )
      return false if expected.blank?

      target_info = presence[:object_info_by_key].is_a?(Hash) ? presence[:object_info_by_key] : {}
      expected.all? do |row|
        key = normalize_key(row[:key])
        next false if key.blank?

        source = source_store.object_info(key).deep_stringify_keys
        target = target_info[key]
        target = target_store.object_info(key).deep_stringify_keys if target.blank?
        next false unless ActiveModel::Type::Boolean.new.cast(source["exists"]) && ActiveModel::Type::Boolean.new.cast(target["exists"])

        source_bytes = source["bytes"].to_i
        target_bytes = target["bytes"].to_i
        source_bytes.positive? && source_bytes == target_bytes
      end
    rescue
      false
    end
    private_class_method :replica_objects_match_primary?

    def register_replica_layout!(context, profile_key, layout)
      Array(layout[:single_keys]).each { |key| context[:expected_keys][profile_key] << normalize_key(key) }
      Array(layout[:prefixes]).each { |prefix| context[:expected_prefixes][profile_key] << normalized_prefix(prefix) }
    end
    private_class_method :register_replica_layout!

    def replica_state_current_and_complete?(item, state, target_profile_key:, replica_scope:, presence:)
      return false unless state.is_a?(Hash)
      return false unless ::MediaGallery::StorageReplica::COMPLETE_STATUSES.include?(state["status"].to_s)
      return false unless state["target_profile_key"].to_s == target_profile_key.to_s
      return false unless state["scope"].to_s == replica_scope.to_s
      return false unless state["source_generation"].to_s == ::MediaGallery::StorageReplica.source_generation(item).to_s
      return false unless presence[:present]

      present_keys = Array(presence[:keys]).map { |key| normalize_key(key) }.to_set
      return false unless Array(state["replicated_single_keys"]).all? { |key| present_keys.include?(normalize_key(key)) }
      return false unless Array(state["replicated_prefixes"]).all? do |prefix|
        normalized = normalized_prefix(prefix)
        present_keys.any? { |key| key.start_with?(normalized) }
      end

      expected = state["object_count"].to_i
      expected <= 0 || presence[:object_count].to_i >= expected
    rescue
      false
    end
    private_class_method :replica_state_current_and_complete?

    def primary_assets_available_for_replica?(item, replica_scope:)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      return false if store.blank?

      ::MediaGallery::StorageReplica.role_names_for_scope(replica_scope).all? do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next true if role.blank? && role_name == "thumbnail"
        next true if role.blank? && role_name == "hls"
        next false unless role.is_a?(Hash)

        if role_name == "hls"
          master = role["master_key"].to_s.presence || File.join(item.public_id.to_s, "hls", "master.m3u8")
          complete = role["complete_key"].to_s.presence
          store.exists?(master) && (complete.blank? || store.exists?(complete))
        else
          key = role["key"].to_s.presence
          key.present? && store.exists?(key)
        end
      end
    rescue
      false
    end
    private_class_method :primary_assets_available_for_replica?

    def register_storage_replica_stats!(context, profile_key, presence)
      context[:stats][:storage_replica_objects] += presence[:object_count].to_i
      label = [profile_key.to_s, presence.dig(:layout, :role_names)&.join("+")].compact.join(": ")
      append_limited_unique!(context[:stats][:storage_replica_locations], label, limit: 50)
    end
    private_class_method :register_storage_replica_stats!

    def storage_replica_incomplete_detail(item, state, presence, target_profile_key:, replica_scope:)
      target = profile_display_label_for_key(target_profile_key).presence || profile_label_for_key(target_profile_key)
      status = state["status"].to_s.presence || "not yet copied"
      "The configured #{replica_scope == 'all_managed_assets' ? 'all-assets' : 'HLS-only'} replica for #{item.public_id} on #{target} is not current and complete. Job status: #{status}. Objects currently detected: #{presence[:object_count].to_i}."
    end
    private_class_method :storage_replica_incomplete_detail

    def storage_replica_cleanup_detail(item, presence, target_profile_key:, replica_scope:, primary_available:)
      target = profile_display_label_for_key(target_profile_key).presence || profile_label_for_key(target_profile_key)
      source = profile_label_for_key(::MediaGallery::StorageSettingsResolver.profile_key_for_item(item))
      verification = primary_available ? "The active primary assets passed the preliminary availability check." : "The active primary assets did not pass the preliminary availability check, so cleanup is blocked."
      "#{presence[:object_count].to_i} replicated object(s) for #{item.public_id} remain on #{target}, but that destination and scope are no longer configured for this item. The canonical profile is #{source}. Scope: #{replica_scope == 'all_managed_assets' ? 'all managed assets' : 'HLS only'}. #{verification}"
    end
    private_class_method :storage_replica_cleanup_detail

    def check_invalid_roles!(context, item, roles, profile_key:, backend:)
      roles.each do |role_name, role|
        next if role.blank?

        role_backend = role["backend"].to_s
        if role_backend.blank? || !(STORAGE_BACKENDS + ["upload"]).include?(role_backend)
          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "invalid_role_backend",
            severity: item.status.to_s == "ready" ? "critical" : "warning",
            item: item,
            profile_key: profile_key,
            backend: backend,
            role: role_name,
            label: "Invalid asset backend",
            detail: "Role #{role_name} uses unsupported backend #{role_backend.presence || 'blank'}.",
            suggestion: "Reprocess or migrate the media item so the manifest is regenerated."
          )
        end

        if STORAGE_BACKENDS.include?(role_backend) && role_keys(role).blank? && role_prefixes(item, role).blank?
          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "missing_role_key",
            severity: item.status.to_s == "ready" ? "critical" : "warning",
            item: item,
            profile_key: profile_key,
            backend: backend,
            role: role_name,
            label: "Missing storage key",
            detail: "Role #{role_name} points to #{role_backend} but does not contain a key or prefix.",
            suggestion: "Reprocess or migrate the media item so the manifest includes complete storage keys."
          )
        end
      end
    end

    def check_missing_assets!(context, item, roles, profile_key:, backend:)
      return unless item.status.to_s == "ready"

      missing = []
      if item.media_type.to_s == "video" && roles["hls"].present?
        missing << "hls" unless role_available?(item, roles["hls"], "hls")
      else
        missing << "main" unless role_available?(item, roles["main"], "main")
      end

      if item.media_type.to_s != "audio"
        missing << "thumbnail" unless role_available?(item, roles["thumbnail"], "thumbnail")
      end

      return if missing.blank?

      add_finding(
        context,
        "missing_assets",
        issue_type: "reconciliation_missing_asset",
        severity: missing.include?("main") || missing.include?("hls") ? "critical" : "warning",
        item: item,
        profile_key: profile_key,
        profile_label: profile_label_for_key(profile_key),
        profile_display_label: profile_display_label_for_key(profile_key),
        backend: backend,
        label: "Ready item has missing assets",
        missing: missing.join(", "),
        detail: "The item is ready but required asset roles are unavailable: #{missing.join(', ')}.",
        suggestion: "Open the item in Media management. Reprocess, restore the missing file, or hide the item until fixed."
      )
    end

    def check_deleted_leftovers!(context, item, roles, profile_key:, backend:)
      leftovers = []
      roles.each do |role_name, role|
        next unless role.is_a?(Hash)
        next unless STORAGE_BACKENDS.include?(role["backend"].to_s)

        if role_name == "hls"
          prefix = role["key_prefix"].presence || File.join(item.public_id.to_s, "hls")
          leftovers << "#{role_name}:#{prefix}" if prefix.present? && prefix_has_objects?(profile_key, prefix)
        else
          role_keys(role).each do |key|
            leftovers << "#{role_name}:#{key}" if role_storage_exists?(profile_key, key)
          end
        end
      end

      return if leftovers.blank?

      add_finding(
        context,
        "deleted_media_leftovers",
        issue_type: "deleted_media_leftover",
        severity: "warning",
        item: item,
        profile_key: profile_key,
        backend: backend,
        label: "Deleted media still has storage files",
        detail: "This item is marked as asset-deleted, but storage objects still appear to exist: #{leftovers.first(5).join(', ')}.",
        suggestion: "Review the report deletion summary before any cleanup action. Use scoped cleanup only after confirming the asset-deleted state is intentional.",
        storage_key: leftovers.first,
        cleanup_available: true,
        cleanup_kind: "cleanup_deleted_media_item",
        cleanup_label: "Clean deleted media leftovers",
        cleanup_hint: "Runs the shared media asset cleanup service for this asset-deleted record without deleting the audit record.",
        cleanup_risk: "medium"
      )
    end

    def scan_storage_profiles!(context, object_limit:, orphan_sample_limit:, progress_callback: nil, item_limit: nil)
      profiles = ::MediaGallery::StorageSettingsResolver.configured_profiles_summary
      context[:profiles][:configured] = profiles.map { |profile| profile_summary_payload(profile) }
      profiles_total = profiles.length

      emit_progress(
        progress_callback,
        stage: "scanning_profiles",
        stage_label: "Scanning configured storage profiles",
        items_checked: context[:stats][:items_checked],
        item_limit: item_limit,
        profiles_checked: context[:stats][:profiles_checked],
        profiles_total: profiles_total,
        objects_scanned: context[:stats][:objects_scanned],
      )

      profiles.each do |profile|
        profile_key = profile[:profile_key].to_s
        backend = profile[:backend].to_s
        next if profile_key.blank? || backend.blank?

        profile_payload = profile_summary_payload(profile).merge(
          status: "pending",
          objects_scanned: 0,
          truncated: false
        )
        context[:profiles][:checked] << profile_payload
        context[:stats][:profiles_checked] += 1

        emit_progress(
          progress_callback,
          stage: "scanning_profiles",
          stage_label: "Scanning storage profile #{profile_display_label_for_key(profile_key) || profile_label_for_key(profile_key)}",
          items_checked: context[:stats][:items_checked],
          item_limit: item_limit,
          profiles_checked: context[:stats][:profiles_checked] - 1,
          profiles_total: profiles_total,
          objects_scanned: context[:stats][:objects_scanned],
          current_profile_key: profile_key,
          current_profile_label: profile_display_label_for_key(profile_key) || profile_label_for_key(profile_key),
        )

        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
        if store.blank?
          profile_payload[:status] = "unavailable"
          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "profile_store_missing",
            severity: "warning",
            profile_key: profile_key,
            backend: backend,
            label: "Storage profile could not be opened",
            detail: "Storage profile #{profile_label_for_key(profile_key)} is configured but could not build a storage store.",
            suggestion: "Check storage settings for this profile."
          )
          emit_progress(
            progress_callback,
            stage: "scanning_profiles",
            stage_label: "Scanning configured storage profiles",
            items_checked: context[:stats][:items_checked],
            item_limit: item_limit,
            profiles_checked: context[:stats][:profiles_checked],
            profiles_total: profiles_total,
            objects_scanned: context[:stats][:objects_scanned],
            current_profile_key: profile_key,
            current_profile_label: profile_display_label_for_key(profile_key) || profile_label_for_key(profile_key),
          )
          next
        end

        begin
          scan_scope = storage_scan_scope_for(store)
          profile_payload[:scan_prefix] = scan_scope if scan_scope.present?
          store.ensure_available!
          listed = Array(store.list_prefix("", limit: object_limit + 1)).map(&:to_s)
          truncated = listed.length > object_limit
          keys = truncated ? listed.first(object_limit) : listed
          profile_payload[:status] = "checked"
          profile_payload[:objects_scanned] = keys.length
          profile_payload[:truncated] = truncated
          context[:stats][:objects_scanned] += keys.length
          if truncated
            context[:stats][:truncated_profiles] << profile_key
            label = profile_display_label_for_key(profile_key)
            context[:stats][:truncated_profile_labels] << label if label.present?
          end

          orphan_groups = grouped_unexpected_storage_findings(context, profile_key: profile_key, backend: backend, keys: keys)
          register_orphan_group_stats!(context, orphan_groups)
          orphan_groups.each_with_index do |group, index|
            next if index >= orphan_sample_limit

            add_grouped_orphan_finding!(context, group)
          end

          if orphan_groups.length > orphan_sample_limit
            omitted_groups = orphan_groups.length - orphan_sample_limit
            omitted_objects = orphan_groups.drop(orphan_sample_limit).sum { |group| group[:object_count].to_i }
            add_finding(
              context,
              "orphaned_files",
              issue_type: "orphaned_storage_group_truncated",
              severity: "warning",
              profile_key: profile_key,
              backend: backend,
              label: "More orphan groups omitted",
              detail: "#{omitted_groups} additional orphan group#{'s' if omitted_groups != 1} covering #{omitted_objects} storage object#{'s' if omitted_objects != 1} were omitted from the preview for this profile.",
              suggestion: "Increase the reconciliation orphan sample limit only after reviewing performance impact.",
              can_ignore: false
            )
          end
        rescue => e
          profile_payload[:status] = "failed"
          profile_payload[:error] = "#{e.class}: #{e.message}".truncate(300)
          scope_text = profile_payload[:scan_prefix].to_s.presence
          scope_detail = scope_text.present? ? " while listing configured scan scope #{scope_text}" : " while listing the profile root"
          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "profile_scan_failed",
            severity: "warning",
            profile_key: profile_key,
            backend: backend,
            label: "Storage profile scan failed",
            detail: "#{e.class}: #{e.message}#{scope_detail}".truncate(500),
            suggestion: "Check profile availability, Rails logs, and whether the storage/API key allows listing the configured scan scope."
          )
        ensure
          emit_progress(
            progress_callback,
            stage: "scanning_profiles",
            stage_label: "Scanning configured storage profiles",
            items_checked: context[:stats][:items_checked],
            item_limit: item_limit,
            profiles_checked: context[:stats][:profiles_checked],
            profiles_total: profiles_total,
            objects_scanned: context[:stats][:objects_scanned],
            current_profile_key: profile_key,
            current_profile_label: profile_display_label_for_key(profile_key) || profile_label_for_key(profile_key),
          )
        end
      end
    end

    def grouped_unexpected_storage_findings(context, profile_key:, backend:, keys:)
      groups = {}

      Array(keys).each do |raw_key|
        key = normalize_key(raw_key)
        next if key.blank?
        next if expected_storage_key?(context, profile_key, key)

        if known_plugin_storage_key?(key)
          register_known_plugin_storage!(context, profile_key, key)
          next
        end

        descriptor = orphan_group_descriptor(key)
        group_key = [profile_key, backend, descriptor[:classification], descriptor[:group_prefix]].join("|")
        group = groups[group_key] ||= descriptor.merge(
          profile_key: profile_key,
          profile_label: profile_label_for_key(profile_key),
          profile_display_label: profile_display_label_for_key(profile_key),
          backend: backend,
          object_count: 0,
          sample_keys: []
        )
        group[:object_count] += 1
        group[:sample_keys] << key if group[:sample_keys].length < 5
      end

      attach_media_context_to_orphan_groups!(context, groups.values, profile_key: profile_key)
      groups.values
        .reject { |group| %w[unsampled_media_prefix].include?(group[:classification].to_s) }
        .sort_by { |group| [-group[:object_count].to_i, group[:group_prefix].to_s] }
    end

    def orphan_group_descriptor(key)
      segments = normalize_key(key).split("/")
      first = segments.first.to_s

      if public_id_like?(first) && segments[1].to_s == "hls"
        return {
          classification: "hls_media_prefix",
          issue_type: "orphaned_hls_prefix",
          label: "HLS storage prefix is not referenced",
          public_id: first,
          title: "HLS leftovers for #{first}",
          group_prefix: File.join(first, "hls"),
          storage_key: File.join(first, "hls"),
        }
      end

      if public_id_like?(first) && segments[1].to_s.start_with?("hls__tmp_")
        prefix = File.join(first, segments[1].to_s)
        return {
          classification: "hls_temporary_prefix",
          issue_type: "orphaned_hls_temporary_prefix",
          label: "Stale HLS temporary workspace",
          public_id: first,
          title: "HLS temporary workspace for #{first}",
          group_prefix: prefix,
          storage_key: prefix,
        }
      end

      if public_id_like?(first) && segments[1].to_s.start_with?("hls__old_")
        prefix = File.join(first, segments[1].to_s)
        return {
          classification: "hls_old_package_prefix",
          issue_type: "orphaned_hls_old_package_prefix",
          label: "Old HLS package backup folder",
          public_id: first,
          title: "Old HLS package backup for #{first}",
          group_prefix: prefix,
          storage_key: prefix,
        }
      end

      {
        classification: "unknown_storage_prefix",
        issue_type: "orphaned_storage_prefix",
        label: "Unknown storage prefix",
        public_id: public_id_like?(first) ? first : nil,
        title: first.present? ? "Storage prefix #{first}" : "Unknown storage prefix",
        group_prefix: first.presence || normalize_key(key),
        storage_key: first.presence || normalize_key(key),
      }
    end

    def attach_media_context_to_orphan_groups!(context, groups, profile_key:)
      public_ids = groups.filter_map { |group| group[:public_id].to_s.presence }.uniq
      return if public_ids.blank?

      items = ::MediaGallery::MediaItem.where(public_id: public_ids).to_a.index_by { |item| item.public_id.to_s }
      groups.each do |group|
        public_id = group[:public_id].to_s
        item = items[public_id]

        if item.blank?
          if public_id_like?(public_id) && group[:classification].to_s == "unknown_storage_prefix"
            group[:classification] = "untracked_media_prefix"
            group[:issue_type] = "untracked_media_storage_prefix"
            group[:label] = "Untracked media storage prefix"
            group[:title] = "Untracked media files for #{public_id}"
            group[:media_item_exists] = false
          end
          next
        end

        group[:media_item_exists] = true
        current_profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item).to_s
        group[:title] = item.title.to_s.presence || "Untitled media"
        group[:status] = item.status.to_s.presence
        group[:current_profile_key] = current_profile_key.presence
        group[:current_profile_label] = profile_label_for_key(current_profile_key) if current_profile_key.present?

        cleanup_state = ::MediaGallery::MigrationCleanup.cleanup_state_for(item) rescue {}
        switch_state = ::MediaGallery::MigrationSwitch.switch_state_for(item) rescue {}
        cleanup_status = cleanup_state["status"].to_s.presence || switch_state["cleanup_status"].to_s.presence
        cleanup_mode = cleanup_state["cleanup_mode"].to_s.presence || switch_state["cleanup_mode"].to_s.presence

        if current_profile_key.present? && current_profile_key != profile_key.to_s
          group[:classification] = "migration_source_leftovers"
          group[:issue_type] = "migration_source_storage_leftovers"
          group[:label] = "Possible migration/source storage leftovers"
          group[:migration_cleanup_status] = cleanup_status
          group[:migration_cleanup_mode] = cleanup_mode
          group[:migration_cleanup_pending] = switch_state["cleanup_pending"] unless switch_state["cleanup_pending"].nil?
        elsif !context[:scanned_public_ids].include?(public_id)
          group[:classification] = "unsampled_media_prefix"
          register_unsampled_media_storage!(context, profile_key, group)
        end
      end
    rescue => e
      Rails.logger.warn("[media_gallery] storage reconciliation media context lookup failed: #{e.class}: #{e.message}")
    end

    def storage_scan_scope_for(store)
      return nil unless store.respond_to?(:list_scope_prefix)

      store.list_scope_prefix.to_s.presence
    rescue
      nil
    end

    def register_orphan_group_stats!(context, groups)
      context[:stats][:orphan_objects_found] += Array(groups).sum { |group| group[:object_count].to_i }
      context[:stats][:orphan_groups_found] += Array(groups).length
    end

    def add_grouped_orphan_finding!(context, group)
      object_count = group[:object_count].to_i
      detail = grouped_orphan_detail(group)
      suggestion = grouped_orphan_suggestion(group)
      sample_keys = Array(group[:sample_keys]).map(&:to_s).reject(&:blank?)
      cleanup = cleanup_descriptor_for_group(group)

      add_finding(
        context,
        "orphaned_files",
        issue_type: group[:issue_type],
        severity: "warning",
        public_id: group[:public_id],
        title: group[:title],
        status: group[:status],
        profile_key: group[:profile_key],
        profile_label: group[:profile_label],
        profile_display_label: group[:profile_display_label],
        backend: group[:backend],
        storage_key: group[:storage_key],
        group_prefix: group[:group_prefix],
        object_count: object_count,
        sample_keys: sample_keys,
        classification: group[:classification],
        current_profile_key: group[:current_profile_key],
        current_profile_label: group[:current_profile_label],
        media_item_exists: group[:media_item_exists],
        migration_cleanup_status: group[:migration_cleanup_status],
        migration_cleanup_mode: group[:migration_cleanup_mode],
        migration_cleanup_pending: group[:migration_cleanup_pending],
        local_mirror_enabled: group[:local_mirror_enabled],
        active_hls_available: group[:active_hls_available],
        cleanup_available: cleanup[:available],
        cleanup_kind: cleanup[:kind],
        cleanup_label: cleanup[:label],
        cleanup_hint: cleanup[:hint],
        cleanup_risk: cleanup[:risk],
        label: group[:label],
        detail: detail,
        suggestion: suggestion,
        can_ignore: true
      )
    end

    def cleanup_descriptor_for_group(group)
      classification = group[:classification].to_s
      public_id = group[:public_id].to_s
      prefix = group[:group_prefix].to_s

      return { available: false } if public_id.blank? || prefix.blank?

      case classification
      when "hls_temporary_prefix"
        {
          available: true,
          kind: "delete_prefix",
          label: "Clean temp workspace",
          hint: "Deletes only this stale hls__tmp_* workspace prefix after confirmation.",
          risk: "low"
        }
      when "hls_old_package_prefix"
        {
          available: true,
          kind: "delete_prefix",
          label: "Clean old HLS backup",
          hint: "Deletes only this hls__old_* backup prefix after confirmation.",
          risk: "low"
        }
      when "migration_source_leftovers"
        {
          available: true,
          kind: "delete_prefix",
          label: "Clean migration source leftovers",
          hint: "Deletes this media prefix only from the non-current source profile after the active target assets are verified.",
          risk: "medium"
        }
      when "hls_media_prefix"
        {
          available: group[:status].to_s.blank?,
          kind: "delete_prefix",
          label: "Clean orphaned HLS prefix",
          hint: "Deletes this HLS prefix only when the media record no longer exists.",
          risk: "medium"
        }
      when "untracked_media_prefix"
        {
          available: group[:status].to_s.blank?,
          kind: "delete_prefix",
          label: "Clean untracked media prefix",
          hint: "Deletes only this UUID-scoped media prefix after confirming no active media item exists.",
          risk: "medium"
        }
      else
        { available: false }
      end
    end

    def grouped_orphan_detail(group)
      object_count = group[:object_count].to_i
      prefix = group[:group_prefix].to_s
      sample_keys = Array(group[:sample_keys]).map(&:to_s).reject(&:blank?)
      sample_text = sample_keys.present? ? " Sample keys: #{sample_keys.join(', ')}." : ""

      case group[:classification].to_s
      when "migration_source_leftovers"
        found = group[:profile_display_label].presence || group[:profile_label].presence || group[:profile_key].presence || "this storage profile"
        current = group[:current_profile_label].presence || group[:current_profile_key].presence || "another profile"
        cleanup_status = group[:migration_cleanup_status].to_s.presence
        cleanup_text = cleanup_status.present? ? " Current cleanup status: #{cleanup_status}." : ""
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} were found on #{found}. The active playback profile for this media item is #{current}. This commonly means migration source cleanup is pending or incomplete.#{cleanup_text}#{sample_text}"
      when "hls_media_prefix"
        "#{object_count} HLS storage object#{'s' if object_count != 1} under #{prefix} are not referenced by any sampled media item or manifest. This often comes from deleted media or an incomplete cleanup path.#{sample_text}"
      when "untracked_media_prefix"
        found = group[:profile_display_label].presence || group[:profile_label].presence || group[:profile_key].presence || "this storage profile"
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} were found on #{found}, but no active Media Gallery item exists for this public_id. This is usually a deleted-media or old test/import leftover.#{sample_text}"
      when "hls_temporary_prefix"
        "#{object_count} HLS temporary storage object#{'s' if object_count != 1} under #{prefix} look like leftover packaging workspace files.#{sample_text}"
      when "hls_old_package_prefix"
        "#{object_count} old HLS package object#{'s' if object_count != 1} under #{prefix} look like leftover swap/rollback artifacts.#{sample_text}"
      else
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} are not referenced by sampled media items or manifests.#{sample_text}"
      end
    end

    def grouped_orphan_suggestion(group)
      case group[:classification].to_s
      when "migration_source_leftovers"
        "Open the item in Migration manager and verify whether source cleanup is pending, failed, or intentionally deferred. Do not delete until the active target profile and playback are verified."
      when "hls_media_prefix"
        "Check whether this public_id still exists in Media management or was deleted through frontend, Reports, or Management. Use a scoped cleanup only after confirming it is not the active package."
      when "untracked_media_prefix"
        "No active media item was found for this UUID-scoped storage prefix. If this came from a deleted test/upload item, use the scoped cleanup button; otherwise verify the prefix manually before deleting."
      when "hls_temporary_prefix", "hls_old_package_prefix"
        "Review age and recent HLS jobs. These should normally be cleared by HLS artifact cleanup after the safe retention window."
      else
        "Review this prefix before cleanup. It may be a legacy file, a deleted media leftover, or a file outside the Media Gallery manifest model."
      end
    end

    def known_plugin_storage_key?(key)
      KNOWN_PLUGIN_STORAGE_PREFIXES.key?(normalize_key(key).split("/").first.to_s)
    end

    def register_known_plugin_storage!(context, profile_key, key)
      top = normalize_key(key).split("/").first.to_s
      label = KNOWN_PLUGIN_STORAGE_PREFIXES[top] || top
      context[:stats][:known_plugin_objects] += 1
      entry = [profile_key.to_s, label].reject(&:blank?).join(": ")
      append_limited_unique!(context[:stats][:known_plugin_prefixes], entry, limit: 50)
    end

    def register_unsampled_media_storage!(context, profile_key, group)
      object_count = group[:object_count].to_i
      context[:stats][:unsampled_media_objects] += object_count
      prefix = [profile_key.to_s, group[:group_prefix].to_s].reject(&:blank?).join(": ")
      append_limited_unique!(context[:stats][:unsampled_media_prefixes], prefix, limit: 50)
    end

    def grouped_orphan_detail(group)
      object_count = group[:object_count].to_i
      prefix = group[:group_prefix].to_s
      sample_keys = Array(group[:sample_keys]).map(&:to_s).reject(&:blank?)
      sample_text = sample_keys.present? ? " Sample keys: #{sample_keys.join(', ')}." : ""

      case group[:classification].to_s
      when "migration_source_leftovers"
        found = group[:profile_display_label].presence || group[:profile_label].presence || group[:profile_key].presence || "this storage profile"
        current = group[:current_profile_label].presence || group[:current_profile_key].presence || "another profile"
        cleanup_status = group[:migration_cleanup_status].to_s.presence
        cleanup_text = cleanup_status.present? ? " Current cleanup status: #{cleanup_status}." : ""
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} were found on #{found}. The active playback profile for this media item is #{current}. This commonly means migration source cleanup is pending or incomplete.#{cleanup_text}#{sample_text}"
      when "hls_media_prefix"
        "#{object_count} HLS storage object#{'s' if object_count != 1} under #{prefix} are not referenced by any sampled media item or manifest. This often comes from deleted media or an incomplete cleanup path.#{sample_text}"
      when "untracked_media_prefix"
        found = group[:profile_display_label].presence || group[:profile_label].presence || group[:profile_key].presence || "this storage profile"
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} were found on #{found}, but no active Media Gallery item exists for this public_id. This is usually a deleted-media or old test/import leftover.#{sample_text}"
      when "hls_temporary_prefix"
        "#{object_count} HLS temporary storage object#{'s' if object_count != 1} under #{prefix} look like leftover packaging workspace files.#{sample_text}"
      when "hls_old_package_prefix"
        "#{object_count} old HLS package object#{'s' if object_count != 1} under #{prefix} look like leftover swap/rollback artifacts.#{sample_text}"
      else
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} are not referenced by sampled media items or manifests.#{sample_text}"
      end
    end

    def grouped_orphan_suggestion(group)
      case group[:classification].to_s
      when "migration_source_leftovers"
        "Open the item in Migration manager and verify whether source cleanup is pending, failed, or intentionally deferred. Do not delete until the active target profile and playback are verified."
      when "hls_media_prefix"
        "Check whether this public_id still exists in Media management or was deleted through frontend, Reports, or Management. Use a scoped cleanup only after confirming it is not the active package."
      when "untracked_media_prefix"
        "No active media item was found for this UUID-scoped storage prefix. If this came from a deleted test/upload item, use the scoped cleanup button; otherwise verify the prefix manually before deleting."
      when "hls_temporary_prefix", "hls_old_package_prefix"
        "Review age and recent HLS jobs. These should normally be cleared by HLS artifact cleanup after the safe retention window."
      else
        "Review this prefix before cleanup. It may be a legacy file, a deleted media leftover, or a file outside the Media Gallery manifest model."
      end
    end

    def known_plugin_storage_key?(key)
      KNOWN_PLUGIN_STORAGE_PREFIXES.key?(normalize_key(key).split("/").first.to_s)
    end

    def register_known_plugin_storage!(context, profile_key, key)
      top = normalize_key(key).split("/").first.to_s
      label = KNOWN_PLUGIN_STORAGE_PREFIXES[top] || top
      context[:stats][:known_plugin_objects] += 1
      entry = [profile_key.to_s, label].reject(&:blank?).join(": ")
      append_limited_unique!(context[:stats][:known_plugin_prefixes], entry, limit: 50)
    end

    def register_unsampled_media_storage!(context, profile_key, group)
      object_count = group[:object_count].to_i
      context[:stats][:unsampled_media_objects] += object_count
      prefix = [profile_key.to_s, group[:group_prefix].to_s].reject(&:blank?).join(": ")
      append_limited_unique!(context[:stats][:unsampled_media_prefixes], prefix, limit: 50)
    end

    def append_limited_unique!(array, value, limit:)
      return if value.blank? || array.include?(value) || array.length >= limit.to_i

      array << value
    end

    def public_id_like?(value)
      PUBLIC_ID_PATTERN.match?(value.to_s)
    end

    def reconciliation_classification_summary(context)
      stats = context[:stats] || {}
      {
        orphan_objects_found: stats[:orphan_objects_found].to_i,
        orphan_groups_found: stats[:orphan_groups_found].to_i,
        known_plugin_objects: stats[:known_plugin_objects].to_i,
        known_plugin_prefixes: Array(stats[:known_plugin_prefixes]).first(20),
        unsampled_media_objects: stats[:unsampled_media_objects].to_i,
        unsampled_media_prefixes: Array(stats[:unsampled_media_prefixes]).first(20),
        storage_replica_objects: stats[:storage_replica_objects].to_i,
        storage_replica_locations: Array(stats[:storage_replica_locations]).first(20),
      }
    end

    def role_available?(item, role, role_name)
      return false unless role.is_a?(Hash)

      case role["backend"].to_s
      when "upload"
        upload_id = role["upload_id"].presence
        upload_id.present? && ::Upload.exists?(id: upload_id)
      when "local", "s3"
        profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
        if role_name.to_s == "hls"
          master_key = role["master_key"].to_s.presence || File.join(item.public_id.to_s, "hls", "master.m3u8")
          complete_key = role["complete_key"].to_s.presence
          return false unless role_storage_exists?(profile_key, master_key)
          complete_key.blank? || role_storage_exists?(profile_key, complete_key)
        else
          key = role["key"].to_s.presence
          key.present? && role_storage_exists?(profile_key, key)
        end
      else
        false
      end
    end

    def role_storage_exists?(profile_key, key)
      return false if profile_key.blank? || key.blank?

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      store.present? && store.exists?(key)
    rescue
      false
    end

    def prefix_has_objects?(profile_key, prefix)
      return false if profile_key.blank? || prefix.blank?

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      store.present? && Array(store.list_prefix(prefix, limit: 1)).present?
    rescue
      false
    end

    def role_keys(role)
      return [] unless role.is_a?(Hash)

      %w[key master_key complete_key fingerprint_meta_key].filter_map { |field| role[field].to_s.presence }.map { |key| normalize_key(key) }.uniq
    end

    def role_prefixes(item, role)
      return [] unless role.is_a?(Hash)

      prefixes = []
      prefixes << role["key_prefix"].to_s.presence
      if role["master_key"].to_s.include?("/hls/") || role["key_prefix"].present?
        prefixes << File.join(item.public_id.to_s, "hls")
      end
      prefixes.compact.map { |prefix| normalized_prefix(prefix) }.uniq
    end

    def expected_storage_key?(context, profile_key, key)
      normalized = normalize_key(key)
      return true if context[:expected_keys][profile_key].include?(normalized)

      context[:expected_prefixes][profile_key].any? do |prefix|
        normalized == prefix.delete_suffix("/") || normalized.start_with?(prefix)
      end
    end

    def asset_deleted?(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      meta["reported_asset_deletion"].is_a?(Hash) ||
        meta["asset_deleted_after_report"].present? ||
        item.status.to_s == "asset_deleted"
    end

    def add_finding(context, category, **attrs)
      context[:findings][category] << finding_payload(category: category, **attrs)
    end

    def profile_summary_payload(profile)
      profile_key = profile[:profile_key].to_s
      label = profile_label_for_key(profile_key)
      {
        profile_key: profile_key,
        backend: profile[:backend].to_s,
        label: label,
        display_label: profile_display_label_for_key(profile_key),
      }.compact
    end

    def profile_label_for_key(profile_key)
      summary = ::MediaGallery::StorageSettingsResolver.profile_summary(profile_key)
      summary[:label].to_s.presence || profile_key.to_s
    rescue
      profile_key.to_s
    end

    def profile_display_label_for_key(profile_key)
      key = profile_key.to_s
      label = profile_label_for_key(key).to_s.strip
      default = case key
      when "local"
        "Local storage"
      when "s3_1"
        "S3 profile 1"
      when "s3_2"
        "S3 profile 2"
      when "s3_3"
        "S3 profile 3"
      else
        key
      end

      return nil if label.blank?
      return nil if label == default
      return nil if label == key

      label
    end

    def finding_payload(category:, issue_type:, severity:, label:, item: nil, public_id: nil, title: nil, status: nil, profile_key: nil, profile_label: nil, profile_display_label: nil, backend: nil, role: nil, storage_key: nil, group_prefix: nil, object_count: nil, sample_keys: nil, classification: nil, current_profile_key: nil, current_profile_label: nil, media_item_exists: nil, migration_cleanup_status: nil, migration_cleanup_mode: nil, migration_cleanup_pending: nil, local_mirror_enabled: nil, active_hls_available: nil, replica_enabled: nil, replica_scope: nil, replica_target_profile_key: nil, primary_assets_available: nil, cleanup_available: nil, cleanup_kind: nil, cleanup_label: nil, cleanup_hint: nil, cleanup_risk: nil, missing: nil, detail: nil, suggestion: nil, can_ignore: true)
      public_id ||= item&.public_id
      title ||= item&.title.to_s.presence || (public_id.present? ? "Untitled media" : label)
      status ||= item&.status
      safe_storage_key = normalize_key(storage_key)
      key = if safe_storage_key.present?
        "#{issue_type}:#{Digest::SHA1.hexdigest([profile_key, backend, safe_storage_key, public_id].join('|'))}"
      elsif public_id.present?
        "#{issue_type}:#{public_id.to_s.gsub(/[^a-z0-9_-]/i, '')}"
      else
        "#{issue_type}:#{Digest::SHA1.hexdigest([category, label, detail, profile_key, backend].join('|'))}"
      end

      has_media_item = !media_item_exists.nil? ? !!media_item_exists : item.present?
      management_url = public_id.present? && has_media_item ? management_url_for(public_id) : nil

      {
        key: key,
        category: category,
        issue_type: issue_type,
        label: label,
        severity: severity.to_s.presence || "warning",
        public_id: public_id,
        title: title,
        status: status,
        profile_key: profile_key,
        profile_label: profile_label,
        profile_display_label: profile_display_label,
        backend: backend,
        role: role,
        storage_key: safe_storage_key,
        group_prefix: group_prefix,
        object_count: object_count,
        sample_keys: Array(sample_keys).presence,
        classification: classification,
        current_profile_key: current_profile_key,
        current_profile_label: current_profile_label,
        media_item_exists: media_item_exists,
        migration_cleanup_status: migration_cleanup_status,
        migration_cleanup_mode: migration_cleanup_mode,
        migration_cleanup_pending: migration_cleanup_pending,
        local_mirror_enabled: local_mirror_enabled,
        active_hls_available: active_hls_available,
        replica_enabled: replica_enabled,
        replica_scope: replica_scope,
        replica_target_profile_key: replica_target_profile_key,
        primary_assets_available: primary_assets_available,
        cleanup_available: cleanup_available,
        cleanup_kind: cleanup_kind,
        cleanup_label: cleanup_label,
        cleanup_hint: cleanup_hint,
        cleanup_risk: cleanup_risk,
        missing: missing,
        detail: detail,
        suggestion: suggestion,
        url: management_url,
        can_ignore: can_ignore,
      }.compact
    end

    def management_url_for(public_id)
      encoded = CGI.escape(public_id.to_s)
      "/admin/plugins/media-gallery-management?q=#{encoded}&public_id=#{encoded}"
    end

    def normalize_key(key)
      key.to_s.sub(%r{\A/+}, "")
    end

    def normalized_prefix(prefix)
      value = normalize_key(prefix)
      value.blank? ? "" : value.delete_suffix("/") + "/"
    end

    def highest_severity(values)
      order = { "ok" => 0, "warning" => 1, "critical" => 2 }
      Array(values).map { |v| %w[ok warning critical].include?(v.to_s) ? v.to_s : "ok" }.max_by { |value| order[value] } || "ok"
    end

    def emit_progress(callback, **payload)
      return unless callback.respond_to?(:call)

      callback.call(payload.compact)
    rescue => e
      Rails.logger.warn("[media_gallery] reconciliation progress update failed: #{e.class}: #{e.message}")
      nil
    end

    def bounded_int(value, min:, max:, default:)
      number = value.to_i
      number = default unless number.positive?
      [[number, min].max, max].min
    end
  end
end
