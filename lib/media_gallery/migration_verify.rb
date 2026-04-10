# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"
require "tmpdir"

module ::MediaGallery
  module MigrationVerify
    module_function

    VERIFY_STATE_KEY = "migration_verify"
    DIGEST_DETAIL_LIMIT = 20

    def verify!(item, target_profile: "target", requested_by: nil)
      raise "media_item_required" if item.blank?

      plan = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      totals = (plan[:totals] || plan["totals"] || {}).deep_symbolize_keys
      source = (plan[:source] || plan["source"] || {}).deep_symbolize_keys
      target = (plan[:target] || plan["target"] || {}).deep_symbolize_keys
      warnings = Array(plan[:warnings] || plan["warnings"]).map(&:to_s)
      same_profile = source[:profile_key].present? && source[:profile_key].to_s == target[:profile_key].to_s
      same_location = source[:location_fingerprint_key].present? && source[:location_fingerprint_key].to_s == target[:location_fingerprint_key].to_s

      verification = {
        object_count: totals[:object_count].to_i,
        missing_on_target_count: totals[:missing_on_target_count].to_i,
        compared_object_count: 0,
        bytes_matched_count: 0,
        digest_verified_count: 0,
        mismatched_count: 0,
        mismatches: []
      }

      status = if target[:backend].to_s.blank?
        "not_configured"
      elsif same_profile || same_location
        "same_profile"
      else
        verification = verify_plan_objects(plan)
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
        "mismatched_count" => verification[:mismatched_count].to_i,
        "mismatches" => Array(verification[:mismatches]).first(DIGEST_DETAIL_LIMIT),
        "warnings" => warnings,
        "last_error" => nil,
      }

      save_verify_state!(item, state)
      { ok: status == "verified", public_id: item.public_id, verification: state, plan: plan }
    rescue => e
      state = {
        "status" => "failed",
        "verified_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "last_error" => "#{e.class}: #{e.message}",
      }
      save_verify_state!(item, state) if item&.persisted?
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

    def verify_plan_objects(plan)
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
        mismatched_count: 0,
        mismatches: [],
        warnings: []
      }

      if source_store.blank? || target_store.blank?
        result[:warnings] << "verify_store_missing"
        return result.merge(object_count: (plan.dig(:totals, :object_count) || plan.dig("totals", "object_count") || 0).to_i)
      end

      source_store.ensure_available!
      target_store.ensure_available!

      objects = flatten_objects(plan)
      result[:object_count] = objects.length

      Dir.mktmpdir("media_gallery_verify") do |tmpdir|
        objects.each_with_index do |object, index|
          key = object[:key].to_s
          next if key.blank?

          source_info = normalize_info(source_store.object_info(key))
          target_info = normalize_info(target_store.object_info(key))

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

          source_digest = digest_for_object(store: source_store, key: key, info: source_info, tmpdir: tmpdir, label: "src", index: index)
          target_digest = digest_for_object(store: target_store, key: key, info: target_info, tmpdir: tmpdir, label: "dst", index: index)

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

      result[:warnings].uniq!
      result
    end
    private_class_method :verify_plan_objects

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
        return ::MediaGallery::LocalAssetStore.new(root_path: root_path)
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

    def digest_for_object(store:, key:, info:, tmpdir:, label:, index:)
      checksum = info[:checksum_sha256].to_s.presence
      return checksum if checksum.present?

      tmp_path = File.join(tmpdir, "#{label}_#{index}_#{SecureRandom.hex(6)}")
      begin
        store.download_to_file!(key, tmp_path)
        Digest::SHA256.file(tmp_path).hexdigest
      ensure
        FileUtils.rm_f(tmp_path)
      end
    rescue
      nil
    end
    private_class_method :digest_for_object

    def append_mismatch!(result, attrs)
      result[:mismatches] << attrs.stringify_keys
    end
    private_class_method :append_mismatch!
  end
end
