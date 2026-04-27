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
          truncated_profiles: [],
          truncated_profile_labels: [],
        },
        profiles: {
          configured: [],
          checked: [],
        },
      }

      ::MediaGallery::MediaItem.includes(:user).order(updated_at: :desc).limit(item_limit).find_each do |item|
        context[:stats][:items_checked] += 1
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
        suggestion: "Review the report deletion summary before any cleanup action. This reconciler does not delete files.",
        storage_key: leftovers.first
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

          orphan_count = 0
          keys.each do |key|
            next if expected_storage_key?(context, profile_key, key)

            orphan_count += 1
            next if orphan_count > orphan_sample_limit

            add_finding(
              context,
              "orphaned_files",
              issue_type: "orphaned_storage_file",
              severity: "warning",
              profile_key: profile_key,
              backend: backend,
              storage_key: key,
              label: "Orphaned storage file candidate",
              detail: "No sampled media item or manifest references this storage object.",
              suggestion: "Review this candidate before cleanup. Do not delete until confirmed.",
              can_ignore: true
            )
          end

          if orphan_count > orphan_sample_limit
            omitted = orphan_count - orphan_sample_limit
            add_finding(
              context,
              "orphaned_files",
              issue_type: "orphaned_storage_file_truncated",
              severity: "warning",
              profile_key: profile_key,
              backend: backend,
              label: "More orphan candidates omitted",
              detail: "#{omitted} additional orphan candidate#{'s' if omitted != 1} were omitted from the preview for this profile.",
              suggestion: "Increase the sample limit only after reviewing performance impact.",
              can_ignore: false
            )
          end
        rescue => e
          profile_payload[:status] = "failed"
          profile_payload[:error] = "#{e.class}: #{e.message}".truncate(300)
          add_finding(
            context,
            "invalid_storage_references",
            issue_type: "profile_scan_failed",
            severity: "warning",
            profile_key: profile_key,
            backend: backend,
            label: "Storage profile scan failed",
            detail: "#{e.class}: #{e.message}".truncate(500),
            suggestion: "Check profile availability and Rails logs."
          )
        end
      end
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

    def finding_payload(category:, issue_type:, severity:, label:, item: nil, public_id: nil, title: nil, status: nil, profile_key: nil, backend: nil, role: nil, storage_key: nil, missing: nil, detail: nil, suggestion: nil, can_ignore: true)
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
        backend: backend,
        role: role,
        storage_key: safe_storage_key,
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
