# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"
require "tmpdir"
require "set"

module ::MediaGallery
  module MigrationVerify
    module_function

    VERIFY_STATE_KEY = "migration_verify"
    DIGEST_DETAIL_LIMIT = 20
    HLS_DETAIL_LIMIT = 10
    SUPPORTED_ROLE_NAMES = %w[main thumbnail hls].freeze

    def verify!(item, target_profile: "target", requested_by: nil)
      raise "media_item_required" if item.blank?
      ::MediaGallery::OperationCoordinator.ensure_operation_allowed!(item, requested_operation: "verify")

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ::MediaGallery::OperationLogger.info("migration_verify_started", item: item, operation: "verify", data: { target_profile: target_profile, requested_by: requested_by })

      runtime_cache = build_runtime_cache
      verifying_state = {
        "status" => "verifying",
        "started_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "target_profile" => target_profile.to_s,
      }
      ::MediaGallery::OperationErrors.clear_failure!(verifying_state)
      save_verify_state!(item, verifying_state)

      plan = build_verification_plan(item, target_profile: target_profile)
      source = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      target = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      warnings = Array(plan[:warnings] || plan["warnings"]).map(&:to_s)
      same_profile = source[:profile_key].present? && source[:profile_key].to_s == target[:profile_key].to_s
      same_location = source[:location_fingerprint_key].present? && source[:location_fingerprint_key].to_s == target[:location_fingerprint_key].to_s

      verification = {
        object_count: 0,
        missing_on_target_count: 0,
        compared_object_count: 0,
        bytes_matched_count: 0,
        digest_verified_count: 0,
        hls_manifest_checked_count: 0,
        hls_manifest_verified_count: 0,
        mismatched_count: 0,
        mismatches: []
      }

      status =
        if target[:backend].to_s.blank?
          "not_configured"
        elsif same_profile || same_location
          "same_profile"
        else
          verification = verify_plan_objects(plan, runtime_cache: runtime_cache)
          if verification[:object_count].to_i <= 0
            "incomplete"
          elsif verification[:missing_on_target_count].to_i.zero? && verification[:mismatched_count].to_i.zero?
            "verified"
          else
            "mismatch"
          end
        end

      warnings.concat(Array(verification[:warnings]).map(&:to_s))
      warnings.uniq!

      state = {
        "status" => status,
        "verified_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "target_profile" => target_profile.to_s,
        "source_profile_key" => source[:profile_key].to_s,
        "target_profile_key" => target[:profile_key].to_s,
        "source_backend" => source[:backend].to_s,
        "target_backend" => target[:backend].to_s,
        "object_count" => verification[:object_count].to_i,
        "target_existing_count" => (verification[:object_count].to_i - verification[:missing_on_target_count].to_i),
        "missing_on_target_count" => verification[:missing_on_target_count].to_i,
        "compared_object_count" => verification[:compared_object_count].to_i,
        "bytes_matched_count" => verification[:bytes_matched_count].to_i,
        "digest_verified_count" => verification[:digest_verified_count].to_i,
        "hls_manifest_checked_count" => verification[:hls_manifest_checked_count].to_i,
        "hls_manifest_verified_count" => verification[:hls_manifest_verified_count].to_i,
        "mismatched_count" => verification[:mismatched_count].to_i,
        "mismatches" => Array(verification[:mismatches]).first(DIGEST_DETAIL_LIMIT),
        "warnings" => warnings,
        "last_error" => nil,
        "duration_ms" => elapsed_ms(started_at),
      }
      ::MediaGallery::OperationErrors.clear_failure!(state)

      save_verify_state!(item, state)
      ::MediaGallery::OperationLogger.info("migration_verify_completed", item: item, operation: "verify", data: { status: status, source_profile_key: state["source_profile_key"], target_profile_key: state["target_profile_key"], missing_on_target_count: state["missing_on_target_count"], mismatched_count: state["mismatched_count"] })
      { ok: status == "verified", public_id: item.public_id, verification: state, plan: plan }
    rescue => e
      state = {
        "status" => "failed",
        "verified_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "duration_ms" => elapsed_ms(started_at),
      }
      ::MediaGallery::OperationErrors.apply_failure!(state, e, operation: "verify")
      save_verify_state!(item, state) if item&.persisted?
      ::MediaGallery::OperationLogger.error("migration_verify_failed", item: item, operation: "verify", data: { error: state["last_error"], error_code: state["last_error_code"], target_profile: target_profile, requested_by: requested_by })
      raise e
    end

    def verify_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[VERIFY_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_verify_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[VERIFY_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end

    def build_verification_plan(item, target_profile:)
      source = source_summary_for(item)
      target = target_summary_for(target_profile)
      source_store = store_for_summary(source)
      flat_objects = ::MediaGallery::MigrationPreview.objects_for_item(item, store: source_store)
      grouped_objects = flat_objects.group_by { |object| object[:role_name].to_s }

      roles = SUPPORTED_ROLE_NAMES.filter_map do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?

        {
          name: role_name,
          role: role,
          objects: Array(grouped_objects[role_name]).map do |object|
            {
              key: object[:key].to_s,
              content_type: object[:content_type].to_s.presence,
            }
          end,
        }
      end

      warnings = []
      warnings << "target_profile_not_configured" if target[:backend].to_s.blank?
      warnings << "source_and_target_same_profile" if source[:profile_key].present? && source[:profile_key].to_s == target[:profile_key].to_s
      warnings << "source_and_target_same_location" if source[:location_fingerprint_key].present? && source[:location_fingerprint_key].to_s == target[:location_fingerprint_key].to_s
      warnings << "source_backend_upload_roles_present" if roles.any? { |role_row| role_row.dig(:role, "backend").to_s == "upload" }
      warnings << "verify_store_missing" if source_store.blank? || store_for_summary(target).blank?
      warnings.uniq!

      {
        source: source,
        target: target,
        roles: roles,
        warnings: warnings,
        totals: {
          object_count: roles.sum { |role_row| Array(role_row[:objects]).length }
        }
      }
    end
    private_class_method :build_verification_plan

    def source_summary_for(item)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      backend = item.managed_storage_backend.presence || ::MediaGallery::StorageSettingsResolver.backend_for_profile_key(profile_key) || ::MediaGallery::StorageSettingsResolver.active_backend
      {
        profile: profile_key,
        backend: backend,
        profile_key: profile_key,
        label: ::MediaGallery::StorageSettingsResolver.profile_label_for_key(profile_key),
        config: ::MediaGallery::StorageSettingsResolver.sanitized_config_for_profile_key(profile_key),
        location_fingerprint: ::MediaGallery::StorageSettingsResolver.profile_key_location_fingerprint(profile_key),
        location_fingerprint_key: ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(profile_key),
      }
    end
    private_class_method :source_summary_for

    def target_summary_for(target_profile)
      ::MediaGallery::StorageSettingsResolver.profile_summary(target_profile).deep_symbolize_keys
    end
    private_class_method :target_summary_for

    def verify_plan_objects(plan, runtime_cache: nil)
      source_summary = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      target_summary = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      source_store = store_for_summary(source_summary)
      target_store = store_for_summary(target_summary)

      result = {
        object_count: 0,
        missing_on_target_count: 0,
        compared_object_count: 0,
        bytes_matched_count: 0,
        digest_verified_count: 0,
        hls_manifest_checked_count: 0,
        hls_manifest_verified_count: 0,
        mismatched_count: 0,
        mismatches: [],
        warnings: []
      }

      if source_store.blank? || target_store.blank?
        result[:warnings] << "verify_store_missing"
        result[:object_count] = (plan.dig(:totals, :object_count) || plan.dig("totals", "object_count") || 0).to_i
        return result
      end

      source_store.ensure_available!
      target_store.ensure_available!

      roles = Array(plan[:roles] || plan["roles"])
      result[:object_count] = roles.sum { |role_row| Array(role_row[:objects] || role_row["objects"]).length }

      runtime_cache ||= build_runtime_cache
      Dir.mktmpdir("media_gallery_verify") do |tmpdir|
        roles.each do |role_row|
          role_name = (role_row[:name] || role_row["name"]).to_s
          role = (role_row[:role] || role_row["role"] || {}).deep_stringify_keys
          objects = Array(role_row[:objects] || role_row["objects"]).map { |obj| obj.is_a?(Hash) ? obj.deep_symbolize_keys : {} }

          if role_name == "hls"
            verify_hls_role_objects!(
              result,
              role: role,
              objects: objects,
              source_store: source_store,
              target_store: target_store,
              tmpdir: tmpdir,
              runtime_cache: runtime_cache,
            )
            next
          end

          verify_standard_role_objects!(
            result,
            objects: objects.map { |obj| obj.merge(role_name: role_name) },
            source_store: source_store,
            target_store: target_store,
            tmpdir: tmpdir,
            runtime_cache: runtime_cache,
          )
        end
      end

      verify_hls_manifest_consistency!(result, plan: plan, target_store: target_store, runtime_cache: runtime_cache)
      result[:warnings].uniq!
      result
    end
    private_class_method :verify_plan_objects

    def verify_standard_role_objects!(result, objects:, source_store:, target_store:, tmpdir:, runtime_cache: nil)
      Array(objects).each_with_index do |object, index|
        key = object[:key].to_s
        next if key.blank?

        source_info = object_info_cached(runtime_cache, source_store, key)
        target_info = object_info_cached(runtime_cache, target_store, key)

        if !source_info[:exists]
          result[:mismatched_count] += 1
          append_mismatch!(result, key: key, reason: "source_missing")
          next
        end

        unless target_info[:exists]
          result[:missing_on_target_count] += 1
          append_mismatch!(result, key: key, reason: "target_missing")
          next
        end

        result[:compared_object_count] += 1

        source_bytes = source_info[:bytes].to_i
        target_bytes = target_info[:bytes].to_i
        if source_bytes != target_bytes
          result[:mismatched_count] += 1
          append_mismatch!(result, key: key, reason: "byte_size_mismatch", source_bytes: source_bytes, target_bytes: target_bytes)
          next
        end

        result[:bytes_matched_count] += 1

        if skip_expensive_digest_for_object?(object)
          next
        end

        source_digest = digest_for_object(store: source_store, key: key, info: source_info, tmpdir: tmpdir, label: "src", index: index, runtime_cache: runtime_cache)
        target_digest = digest_for_object(store: target_store, key: key, info: target_info, tmpdir: tmpdir, label: "dst", index: index, runtime_cache: runtime_cache)

        if source_digest.blank? || target_digest.blank?
          result[:warnings] << "digest_unavailable"
          next
        end

        if source_digest != target_digest
          result[:mismatched_count] += 1
          append_mismatch!(result, key: key, reason: "checksum_mismatch", source_checksum_sha256: source_digest, target_checksum_sha256: target_digest)
          next
        end

        result[:digest_verified_count] += 1
      end
    end
    private_class_method :verify_standard_role_objects!

    def verify_hls_role_objects!(result, role:, objects:, source_store:, target_store:, tmpdir:, runtime_cache: nil)
      object_rows = Array(objects).map { |obj| obj.is_a?(Hash) ? obj.deep_symbolize_keys : {} }
      prefix = role["key_prefix"].to_s.presence || derive_hls_prefix_from_objects(object_rows)
      source_key_set = Set.new(object_rows.map { |obj| obj[:key].to_s }.reject(&:blank?))
      target_key_set = build_key_set_for_prefix(target_store, prefix, fallback_objects: object_rows, runtime_cache: runtime_cache)

      object_rows.each_with_index do |object, index|
        key = object[:key].to_s
        next if key.blank?

        if segment_like_reference?(key)
          unless source_key_set.include?(key)
            result[:mismatched_count] += 1
            append_mismatch!(result, key: key, reason: "source_missing")
            next
          end

          unless target_key_set.include?(key)
            result[:missing_on_target_count] += 1
            append_mismatch!(result, key: key, reason: "target_missing")
            next
          end

          next
        end

        verify_standard_role_objects!(
          result,
          objects: [object.merge(role_name: "hls")],
          source_store: source_store,
          target_store: target_store,
          tmpdir: tmpdir,
        )
      end
    end
    private_class_method :verify_hls_role_objects!

    def flatten_objects(plan)
      roles = Array(plan[:roles] || plan["roles"])
      roles.flat_map do |role|
        Array(role[:objects] || role["objects"]).map do |obj|
          {
            key: obj[:key] || obj["key"],
            role_name: role[:name] || role["name"]
          }
        end
      end.reject { |row| row[:key].to_s.blank? }.uniq { |row| row[:key].to_s }
    end
    private_class_method :flatten_objects

    def store_for_summary(summary)
      summary = summary.deep_symbolize_keys if summary.respond_to?(:deep_symbolize_keys)
      profile_key = summary[:profile_key].to_s.presence
      backend = summary[:backend].to_s

      if profile_key.present?
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
        return store if store.present?
      end

      case backend
      when "local"
        root_path = summary.dig(:config, :local_asset_root_path).to_s.presence || ::MediaGallery::StorageSettingsResolver.local_asset_root_path
        ::MediaGallery::LocalAssetStore.new(root_path: root_path)
      when "s3"
        nil
      else
        nil
      end
    rescue
      nil
    end
    private_class_method :store_for_summary

    def normalize_info(info)
      value = info.is_a?(Hash) ? info.deep_symbolize_keys : {}
      value[:exists] = !!value[:exists]
      value
    end
    private_class_method :normalize_info

    def skip_expensive_digest_for_object?(object)
      return false unless object.is_a?(Hash)
      return false unless object[:role_name].to_s == "hls"

      segment_like_reference?(object[:key])
    end
    private_class_method :skip_expensive_digest_for_object?

    def digest_for_object(store:, key:, info:, tmpdir:, label:, index:, runtime_cache: nil)
      checksum = info[:checksum_sha256].to_s.presence
      return checksum if checksum.present?

      cache = (runtime_cache ||= build_runtime_cache)[:digest]
      cache_key = [store.backend.to_s, store.object_id, key.to_s, info[:etag].to_s, info[:bytes].to_i]
      return cache[cache_key] if cache.key?(cache_key)

      tmp_path = File.join(tmpdir, "#{label}_#{index}_#{SecureRandom.hex(6)}")
      begin
        store.download_to_file!(key, tmp_path)
        cache[cache_key] = Digest::SHA256.file(tmp_path).hexdigest
      ensure
        FileUtils.rm_f(tmp_path)
      end
    rescue
      nil
    end
    private_class_method :digest_for_object

    def verify_hls_manifest_consistency!(result, plan:, target_store:, runtime_cache: nil)
      roles = Array(plan[:roles] || plan["roles"])
      roles.each do |role_row|
        next unless (role_row[:name] || role_row["name"]).to_s == "hls"

        result[:hls_manifest_checked_count] += 1
        role = (role_row[:role] || role_row["role"] || {}).deep_stringify_keys
        objects = Array(role_row[:objects] || role_row["objects"]).map { |obj| (obj.is_a?(Hash) ? obj.deep_stringify_keys : {}) }
        prefix = role["key_prefix"].to_s.presence || derive_hls_prefix_from_objects(objects)
        target_keys = build_key_set_for_prefix(target_store, prefix, fallback_objects: objects, runtime_cache: runtime_cache).to_a
        consistency = verify_single_hls_role(target_store: target_store, role: role, objects: objects, target_keys: target_keys, runtime_cache: runtime_cache)

        if consistency[:ok]
          result[:hls_manifest_verified_count] += 1
        else
          result[:mismatched_count] += 1
          append_mismatch!(
            result,
            key: role["master_key"].to_s.presence || role["key_prefix"].to_s,
            reason: "hls_manifest_inconsistent",
            errors: Array(consistency[:errors]).first(HLS_DETAIL_LIMIT)
          )
        end

        result[:warnings].concat(Array(consistency[:warnings]))
      end
    end
    private_class_method :verify_hls_manifest_consistency!

    def verify_single_hls_role(target_store:, role:, objects:, target_keys: nil, runtime_cache: nil)
      return { ok: false, errors: ["target_store_missing"], warnings: [] } if target_store.blank?

      prefix = role["key_prefix"].to_s
      master_key = role["master_key"].to_s.presence || File.join(prefix, "master.m3u8")
      complete_key = role["complete_key"].to_s.presence || File.join(prefix, ".complete")
      errors = []
      warnings = []
      object_keys = objects.map { |obj| obj["key"].to_s }.reject(&:blank?).uniq
      target_key_set = Set.new(Array(target_keys).map(&:to_s).reject(&:blank?))
      target_has_key = lambda do |key|
        normalized = key.to_s
        if normalized.blank?
          false
        elsif target_key_set.any?
          target_key_set.include?(normalized)
        else
          target_store.exists?(normalized)
        end
      end

      errors << "missing_complete_marker: #{complete_key}" unless target_has_key.call(complete_key)
      errors << "missing_master_playlist: #{master_key}" unless target_has_key.call(master_key)
      return { ok: false, errors: errors, warnings: warnings } if errors.present?

      master_refs = playlist_refs(read_text(target_store, master_key, runtime_cache: runtime_cache))
      variant_keys = master_refs.select { |ref| ref.downcase.end_with?(".m3u8") }.map { |ref| normalize_playlist_reference(master_key, ref) }.uniq
      errors << "master_has_no_variant_playlists" if variant_keys.empty?

      uses_ab = ActiveModel::Type::Boolean.new.cast(role["ab_fingerprint"]) || role["ab_segment_key_template"].to_s.present?
      fingerprint_meta_key = role["fingerprint_meta_key"].to_s.presence
      if uses_ab && fingerprint_meta_key.present? && !target_has_key.call(fingerprint_meta_key)
        errors << "missing_fingerprint_meta: #{fingerprint_meta_key}"
      end

      variant_keys.each do |variant_key|
        unless target_has_key.call(variant_key)
          errors << "missing_variant_playlist: #{variant_key}"
          next
        end

        refs = playlist_refs(read_text(target_store, variant_key, runtime_cache: runtime_cache))
        segment_refs = refs.select { |ref| segment_like_reference?(ref) }
        errors << "variant_has_no_segments: #{variant_key}" if segment_refs.empty?

        variant_name = variant_name_from_playlist_key(prefix, variant_key)
        segment_refs.each do |segment_ref|
          file_name = File.basename(segment_ref.to_s)
          if uses_ab
            %w[a b].each do |ab|
              key = File.join(prefix, ab, variant_name, file_name)
              errors << "missing_ab_segment: #{key}" unless target_has_key.call(key) || object_keys.include?(key)
            end
          else
            key = normalize_playlist_reference(variant_key, segment_ref)
            errors << "missing_segment: #{key}" unless target_has_key.call(key) || object_keys.include?(key)
          end
        end
      end

      { ok: errors.empty?, errors: errors.uniq, warnings: warnings.uniq }
    rescue => e
      { ok: false, errors: ["hls_manifest_check_failed: #{e.class}: #{e.message}"], warnings: warnings }
    end
    private_class_method :verify_single_hls_role

    def build_key_set_for_prefix(store, prefix, fallback_objects: [], runtime_cache: nil)
      keys = []
      keys = list_prefix_cached(runtime_cache, store, prefix) if store.present? && prefix.present?
      keys = Array(fallback_objects).map { |obj| obj.is_a?(Hash) ? (obj[:key] || obj["key"]).to_s : obj.to_s } if keys.blank?
      Set.new(keys.reject(&:blank?))
    rescue => e
      Set.new(Array(fallback_objects).map { |obj| obj.is_a?(Hash) ? (obj[:key] || obj["key"]).to_s : obj.to_s }.reject(&:blank?)).tap do
        # keep verify moving even if prefix listing fails on a provider
      end
    end
    private_class_method :build_key_set_for_prefix

    def derive_hls_prefix_from_objects(objects)
      keys = Array(objects).map { |obj| obj.is_a?(Hash) ? (obj[:key] || obj["key"]).to_s : obj.to_s }.reject(&:blank?).sort
      return "" if keys.blank?

      if (master = keys.find { |key| File.basename(key) == "master.m3u8" })
        return File.dirname(master)
      end

      File.dirname(keys.first)
    end
    private_class_method :derive_hls_prefix_from_objects

    def read_text(store, key, runtime_cache: nil)
      cache = (runtime_cache ||= build_runtime_cache)[:read_text]
      cache_key = [store.backend.to_s, key.to_s]
      return cache[cache_key] if cache.key?(cache_key)

      value = store.read(key)
      normalized = value.respond_to?(:force_encoding) ? value.force_encoding("UTF-8") : value.to_s
      cache[cache_key] = normalized
    end
    private_class_method :read_text

    def playlist_refs(raw)
      refs = []
      raw.to_s.each_line do |line|
        stripped = line.to_s.strip
        next if stripped.blank?

        if stripped.start_with?("#")
          stripped.scan(/URI="([^"]+)"/) { |match| refs << sanitize_playlist_ref(match.first) }
          next
        end

        refs << sanitize_playlist_ref(stripped)
      end
      refs.reject(&:blank?)
    end
    private_class_method :playlist_refs

    def sanitize_playlist_ref(ref)
      value = ref.to_s.strip
      value = value.sub(/[?#].*\z/, "")
      value.sub(%r{\A\./}, "")
    end
    private_class_method :sanitize_playlist_ref

    def normalize_playlist_reference(base_key, ref)
      clean = sanitize_playlist_ref(ref)
      return clean if clean.start_with?("/")
      File.join(File.dirname(base_key.to_s), clean)
    end
    private_class_method :normalize_playlist_reference

    def segment_like_reference?(ref)
      ext = File.extname(ref.to_s).downcase
      %w[.ts .m4s .mp4].include?(ext)
    end
    private_class_method :segment_like_reference?

    def variant_name_from_playlist_key(prefix, playlist_key)
      relative = playlist_key.to_s.sub(%r{\A#{Regexp.escape(prefix.to_s)}/?}, "")
      value = relative.split("/").first.to_s
      value.present? ? value : ::MediaGallery::Hls::DEFAULT_VARIANT
    end
    private_class_method :variant_name_from_playlist_key

    def build_runtime_cache
      {
        object_info: {},
        list_prefix: {},
        read_text: {},
        digest: {},
      }
    end
    private_class_method :build_runtime_cache

    def object_info_cached(runtime_cache, store, key)
      cache = (runtime_cache ||= build_runtime_cache)[:object_info]
      cache_key = [store.backend.to_s, store.object_id, key.to_s]
      cache[cache_key] ||= normalize_info(store.object_info(key))
    end
    private_class_method :object_info_cached

    def list_prefix_cached(runtime_cache, store, prefix)
      cache = (runtime_cache ||= build_runtime_cache)[:list_prefix]
      cache_key = [store.backend.to_s, store.object_id, prefix.to_s]
      cache[cache_key] ||= Array(store.list_prefix(prefix)).map(&:to_s)
    end
    private_class_method :list_prefix_cached

    def elapsed_ms(started_at)
      return nil unless started_at
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round
    rescue
      nil
    end
    private_class_method :elapsed_ms

    def append_mismatch!(result, attrs)
      result[:mismatches] << attrs.stringify_keys
    end
    private_class_method :append_mismatch!
  end
end
