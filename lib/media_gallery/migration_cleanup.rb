# frozen_string_literal: true

require "securerandom"
require "time"

module ::MediaGallery
  module MigrationCleanup
    module_function

    CLEANUP_STATE_KEY = "migration_cleanup"
    CLEANUP_ROLE_NAMES = %w[main thumbnail hls].freeze

    def enqueue_cleanup!(item, requested_by: nil, force: false, auto_finalize: false)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      switch_state = ::MediaGallery::MigrationSwitch.switch_state_for(item)
      context = cleanup_context_for(item, switch_state)

      state = cleanup_state_for(item)
      cleanup_matches_current_switch = cleanup_state_matches_current_context?(state, context)
      if state["status"].to_s == "cleaning" && !force && cleanup_matches_current_switch
        raise "cleanup_already_in_progress"
      end
      if state["status"].to_s == "cleaned" && !force && cleanup_matches_current_switch
        return state
      end

      token = SecureRandom.hex(10)
      state = build_queued_state(context: context, requested_by: requested_by, force: force, run_token: token, auto_finalize: auto_finalize)
      save_cleanup_state!(item, state)

      ::Jobs.enqueue(:media_gallery_cleanup_source_after_switch, media_item_id: item.id, run_token: token, force: force, auto_finalize: auto_finalize)
      state
    end

    def perform_cleanup!(item, run_token: nil, force: false, auto_finalize: nil)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      switch_state = ::MediaGallery::MigrationSwitch.switch_state_for(item)
      context = cleanup_context_for(item, switch_state)

      current_state = cleanup_state_for(item)
      cleanup_matches_current_switch = cleanup_state_matches_current_context?(current_state, context)
      if current_state["status"].to_s == "cleaning" && current_state["run_token"].present? && run_token.present? && current_state["run_token"] != run_token && !force && cleanup_matches_current_switch
        raise "cleanup_already_in_progress"
      end
      return current_state if current_state["status"].to_s == "cleaned" && !force && cleanup_matches_current_switch
      auto_finalize = current_state["auto_finalize"] if auto_finalize.nil?

      inactive_store = store_for_switch_summary(profile_key: context[:inactive_profile_key], backend: context[:inactive_backend])
      active_store = store_for_switch_summary(profile_key: context[:active_profile_key], backend: context[:active_backend])
      raise "cleanup_source_store_missing" if inactive_store.blank?
      raise "cleanup_target_store_missing" if active_store.blank?

      inactive_store.ensure_available!
      active_store.ensure_available!

      expected_inactive_fingerprint = context[:inactive_location_fingerprint]
      current_inactive_fingerprint = ::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(context[:inactive_profile_key])
      if fingerprints_differ?(expected_inactive_fingerprint, current_inactive_fingerprint)
        raise "cleanup_source_profile_changed_since_switch"
      end

      expected_active_fingerprint = context[:active_location_fingerprint]
      current_active_fingerprint = ::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(context[:active_profile_key].to_s)
      if fingerprints_differ?(expected_active_fingerprint, current_active_fingerprint)
        raise "cleanup_target_profile_changed_since_switch"
      end

      raise "cleanup_same_store_protected" if inactive_store.same_location?(active_store)

      inactive_objects = ::MediaGallery::MigrationPreview.objects_for_item(item, store: inactive_store)
      active_objects = ::MediaGallery::MigrationPreview.objects_for_item(item, store: active_store)
      active_missing = verify_target_objects(active_store, active_objects)
      raise "cleanup_target_incomplete:#{active_missing}" if active_missing.positive?

      state = build_cleaning_state(context: context, run_token: run_token.presence || current_state["run_token"], force: force, inactive_objects: inactive_objects, auto_finalize: auto_finalize)
      save_cleanup_state!(item, state)

      grouped = group_objects_for_cleanup(item, inactive_objects)
      role_results = []
      deleted_current = 0
      deleted_versions = 0
      deleted_delete_markers = 0

      grouped.each_with_index do |entry, index|
        result = purge_group(inactive_store, entry)
        role_results << entry.merge(result: result)
        raise(result[:error].presence || "cleanup_purge_failed") unless result[:ok]

        deleted_current += result[:deleted_current].to_i
        deleted_versions += result[:deleted_versions].to_i
        deleted_delete_markers += result[:deleted_delete_markers].to_i

        update_progress!(item, state, role_results: role_results, current_role: entry[:role_name], index: index + 1, total: grouped.length, deleted_current: deleted_current, deleted_versions: deleted_versions, deleted_delete_markers: deleted_delete_markers)
      end

      remaining = role_results.sum do |entry|
        result = entry[:result].is_a?(Hash) ? entry[:result] : {}
        result[:remaining_current_count].to_i + result[:remaining_version_entries].to_i
      end
      raise "cleanup_remaining_source_objects:#{remaining}" if remaining.positive?

      state = cleanup_state_for(item)
      state["status"] = "cleaned"
      state["finished_at"] = Time.now.utc.iso8601
      state["cleaned_at"] = state["finished_at"]
      state["deleted_current"] = deleted_current
      state["deleted_versions"] = deleted_versions
      state["deleted_delete_markers"] = deleted_delete_markers
      state["remaining_source_count"] = remaining
      state["role_results"] = role_results
      state["last_error"] = nil
      save_cleanup_state!(item, state)

      if auto_finalize
        ::MediaGallery::MigrationFinalize.finalize!(item.reload, requested_by: state["requested_by"], force: force)
      end

      state
    rescue => e
      state = cleanup_state_for(item)
      state["status"] = "failed"
      state["finished_at"] = Time.now.utc.iso8601
      state["last_error"] = "#{e.class}: #{e.message}"
      save_cleanup_state!(item, state) if item&.persisted?
      raise e
    end

    def cleanup_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[CLEANUP_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_cleanup_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[CLEANUP_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end

    def build_queued_state(context:, requested_by:, force:, run_token:, auto_finalize:)
      {
        "status" => "queued",
        "queued_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "force" => !!force,
        "run_token" => run_token,
        "cleanup_mode" => context[:mode],
        "source_backend" => context[:inactive_backend].to_s,
        "source_profile" => context[:inactive_profile].to_s,
        "source_profile_key" => context[:inactive_profile_key].to_s,
        "target_backend" => context[:active_backend].to_s,
        "target_profile_key" => context[:active_profile_key].to_s,
        "source_location_fingerprint" => context[:inactive_location_fingerprint],
        "target_location_fingerprint" => context[:active_location_fingerprint],
        "auto_finalize" => !!auto_finalize,
        "last_error" => nil
      }
    end
    private_class_method :build_queued_state

    def build_cleaning_state(context:, run_token:, force:, inactive_objects:, auto_finalize:)
      {
        "status" => "cleaning",
        "started_at" => Time.now.utc.iso8601,
        "run_token" => run_token,
        "force" => !!force,
        "cleanup_mode" => context[:mode],
        "source_backend" => context[:inactive_backend].to_s,
        "source_profile" => context[:inactive_profile].to_s,
        "source_profile_key" => context[:inactive_profile_key].to_s,
        "target_backend" => context[:active_backend].to_s,
        "target_profile_key" => context[:active_profile_key].to_s,
        "source_location_fingerprint" => context[:inactive_location_fingerprint],
        "target_location_fingerprint" => context[:active_location_fingerprint],
        "auto_finalize" => !!auto_finalize,
        "object_count" => inactive_objects.length,
        "last_error" => nil
      }
    end
    private_class_method :build_cleaning_state

    def update_progress!(item, state, role_results:, current_role:, index:, total:, deleted_current:, deleted_versions:, deleted_delete_markers:)
      latest = cleanup_state_for(item)
      latest.merge!(state)
      latest["status"] = "cleaning"
      latest["current_role"] = current_role.to_s
      latest["progress_index"] = index
      latest["progress_total"] = total
      latest["deleted_current"] = deleted_current
      latest["deleted_versions"] = deleted_versions
      latest["deleted_delete_markers"] = deleted_delete_markers
      latest["role_results"] = role_results
      latest["updated_at"] = Time.now.utc.iso8601
      save_cleanup_state!(item, latest)
    end
    private_class_method :update_progress!

    def fingerprints_differ?(left, right)
      return false if left.blank? || right.blank?

      normalize_fingerprint(left) != normalize_fingerprint(right)
    end
    private_class_method :fingerprints_differ?

    def normalize_fingerprint(value)
      return nil if value.blank?

      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = normalize_fingerprint(v)
        end
      when Array
        value.map { |v| normalize_fingerprint(v) }
      else
        value.to_s
      end
    end
    private_class_method :normalize_fingerprint

    def cleanup_state_matches_current_context?(state, context)
      return false unless state.is_a?(Hash)

      same_inactive = state["source_backend"].to_s == context[:inactive_backend].to_s &&
        state["source_profile_key"].to_s == context[:inactive_profile_key].to_s

      same_active = state["target_backend"].to_s == context[:active_backend].to_s &&
        state["target_profile_key"].to_s == context[:active_profile_key].to_s

      return false unless same_inactive && same_active
      return false if fingerprints_differ?(state["source_location_fingerprint"], context[:inactive_location_fingerprint])
      return false if fingerprints_differ?(state["target_location_fingerprint"], context[:active_location_fingerprint])

      true
    end
    private_class_method :cleanup_state_matches_current_context?

    def cleanup_context_for(item, switch_state)
      raise "switch_state_missing" unless switch_state.is_a?(Hash)

      case switch_state["status"].to_s
      when "switched"
        inactive_profile_key = switch_state["source_profile_key"].to_s
        active_profile_key = item.managed_storage_profile.to_s
        raise "switch_source_profile_missing" if inactive_profile_key.blank?
        raise "switch_target_profile_missing" if active_profile_key.blank?
        raise "cleanup_source_equals_target_profile" if inactive_profile_key == active_profile_key

        {
          mode: "source_after_switch",
          inactive_backend: switch_state["source_backend"].to_s,
          inactive_profile: switch_state["source_profile"].to_s,
          inactive_profile_key: inactive_profile_key,
          inactive_location_fingerprint: switch_state["source_location_fingerprint"],
          active_backend: item.managed_storage_backend.to_s,
          active_profile_key: active_profile_key,
          active_location_fingerprint: switch_state["target_location_fingerprint"],
        }
      when "rolled_back"
        inactive_profile_key = switch_state["target_profile_key"].to_s
        active_profile_key = item.managed_storage_profile.to_s
        raise "rollback_target_profile_missing" if inactive_profile_key.blank?
        raise "rollback_source_profile_missing" if active_profile_key.blank?
        raise "cleanup_source_equals_target_profile" if inactive_profile_key == active_profile_key

        {
          mode: "inactive_target_after_rollback",
          inactive_backend: switch_state["target_backend"].to_s,
          inactive_profile: switch_state["target_profile"].to_s,
          inactive_profile_key: inactive_profile_key,
          inactive_location_fingerprint: switch_state["target_location_fingerprint"],
          active_backend: item.managed_storage_backend.to_s,
          active_profile_key: active_profile_key,
          active_location_fingerprint: switch_state["source_location_fingerprint"],
        }
      else
        raise "switch_state_missing"
      end
    end
    private_class_method :cleanup_context_for

    def store_for_switch_summary(profile_key:, backend:)
      profile_key = profile_key.to_s
      if profile_key.present?
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
        return store if store.present?
      end

      case backend.to_s
      when "local"
        ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_asset_root_path)
      when "s3"
        ::MediaGallery::StorageSettingsResolver.build_store_for_profile("active")
      else
        nil
      end
    end
    private_class_method :store_for_switch_summary

    def verify_target_objects(target_store, target_objects)
      target_objects.count do |object|
        !target_store.object_info(object[:key]).deep_symbolize_keys[:exists]
      end
    end
    private_class_method :verify_target_objects

    def group_objects_for_cleanup(item, inactive_objects)
      grouped = []
      seen = {}

      inactive_objects.each do |object|
        role_name = object[:role_name].to_s
        next unless CLEANUP_ROLE_NAMES.include?(role_name)

        if role_name == "hls"
          prefix = File.join(item.public_id.to_s, "hls")
          key = "prefix:#{prefix}"
          next if seen[key]
          seen[key] = true
          grouped << { role_name: role_name, type: "prefix", key: prefix }
        else
          object_key = object[:key].to_s
          next if object_key.blank?
          key = "object:#{object_key}"
          next if seen[key]
          seen[key] = true
          grouped << { role_name: role_name, type: "object", key: object_key }
        end
      end

      grouped
    end
    private_class_method :group_objects_for_cleanup

    def purge_group(source_store, entry)
      if entry[:type] == "prefix"
        source_store.purge_prefix!(entry[:key])
      else
        source_store.purge_key!(entry[:key])
      end
    end
    private_class_method :purge_group
  end
end
