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

    def run(item_limit: 500, object_limit: 2000, orphan_sample_limit: 50)
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
          truncated_profiles: [],
          truncated_profile_labels: [],
        },
        scanned_public_ids: Set.new,
        profiles: {
          configured: [],
          checked: [],
        },
      }

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
      end

      scan_storage_profiles!(context, object_limit: object_limit, orphan_sample_limit: orphan_sample_limit)

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

      {
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
    rescue => e
      Rails.logger.error("[media_gallery] storage reconciliation failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
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

    def scan_storage_profiles!(context, object_limit:, orphan_sample_limit:)
      profiles = ::MediaGallery::StorageSettingsResolver.configured_profiles_summary
      context[:profiles][:configured] = profiles.map { |profile| profile_summary_payload(profile) }

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
        .reject { |group| group[:classification].to_s == "unsampled_media_prefix" }
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
        next if item.blank?

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
        migration_cleanup_status: group[:migration_cleanup_status],
        migration_cleanup_mode: group[:migration_cleanup_mode],
        migration_cleanup_pending: group[:migration_cleanup_pending],
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
        current = group[:current_profile_label].presence || group[:current_profile_key].presence || "another profile"
        cleanup_status = group[:migration_cleanup_status].to_s.presence
        cleanup_text = cleanup_status.present? ? " Current cleanup status: #{cleanup_status}." : ""
        "#{object_count} storage object#{'s' if object_count != 1} under #{prefix} are on this profile, while the media item currently resolves to #{current}. This commonly means migration source cleanup is pending or incomplete.#{cleanup_text}#{sample_text}"
      when "hls_media_prefix"
        "#{object_count} HLS storage object#{'s' if object_count != 1} under #{prefix} are not referenced by any sampled media item or manifest. This often comes from deleted media or an incomplete cleanup path.#{sample_text}"
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
      meta["reported_asset_deletion"].is_a?(Hash) || meta["asset_deleted_after_report"].present?
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

    def finding_payload(category:, issue_type:, severity:, label:, item: nil, public_id: nil, title: nil, status: nil, profile_key: nil, profile_label: nil, profile_display_label: nil, backend: nil, role: nil, storage_key: nil, group_prefix: nil, object_count: nil, sample_keys: nil, classification: nil, current_profile_key: nil, current_profile_label: nil, migration_cleanup_status: nil, migration_cleanup_mode: nil, migration_cleanup_pending: nil, cleanup_available: nil, cleanup_kind: nil, cleanup_label: nil, cleanup_hint: nil, cleanup_risk: nil, missing: nil, detail: nil, suggestion: nil, can_ignore: true)
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
        migration_cleanup_status: migration_cleanup_status,
        migration_cleanup_mode: migration_cleanup_mode,
        migration_cleanup_pending: migration_cleanup_pending,
        cleanup_available: cleanup_available,
        cleanup_kind: cleanup_kind,
        cleanup_label: cleanup_label,
        cleanup_hint: cleanup_hint,
        cleanup_risk: cleanup_risk,
        missing: missing,
        detail: detail,
        suggestion: suggestion,
        url: public_id.present? ? management_url_for(public_id) : nil,
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

    def bounded_int(value, min:, max:, default:)
      number = value.to_i
      number = default unless number.positive?
      [[number, min].max, max].min
    end
  end
end
