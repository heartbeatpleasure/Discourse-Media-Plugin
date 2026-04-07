# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "time"

module ::MediaGallery
  module MigrationCopy
    module_function

    COPY_STATE_KEY = "migration_copy"

    def enqueue_copy!(item, target_profile: "target", requested_by: nil, force: false, auto_switch: false, auto_cleanup: false)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      plan = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      validate_plan_for_copy!(plan)

      state = copy_state_for(item)
      if state["status"].to_s == "copying" && !force
        raise "copy_already_in_progress"
      end

      token = SecureRandom.hex(10)
      state = build_queued_state(plan: plan, requested_by: requested_by, run_token: token, force: force, auto_switch: auto_switch, auto_cleanup: auto_cleanup)
      save_copy_state!(item, state)

      ::Jobs.enqueue(
        :media_gallery_copy_item_to_target,
        media_item_id: item.id,
        target_profile: target_profile.to_s,
        run_token: token,
        force: force,
        auto_switch: auto_switch,
        auto_cleanup: auto_cleanup
      )

      state
    end

    def perform_copy!(item, target_profile: "target", run_token: nil, force: false, auto_switch: nil, auto_cleanup: nil)
      raise "media_item_required" if item.blank?
      raise "item_not_ready" unless item.ready?

      plan = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      validate_plan_for_copy!(plan)

      current_state = copy_state_for(item)
      if current_state["status"].to_s == "copying" && current_state["run_token"].present? && run_token.present? && current_state["run_token"] != run_token && !force
        raise "copy_already_in_progress"
      end
      auto_switch = current_state["auto_switch"] if auto_switch.nil?
      auto_cleanup = current_state["auto_cleanup"] if auto_cleanup.nil?

      source_store = store_for_summary(plan[:source] || plan["source"])
      target_store = store_for_summary(plan[:target] || plan["target"])
      raise "source_store_missing" if source_store.blank?
      raise "target_store_missing" if target_store.blank?

      source_store.ensure_available!
      target_store.ensure_available!

      objects = flatten_plan_objects(plan)
      state = build_copying_state(plan: plan, prior_state: current_state, run_token: run_token.presence || current_state["run_token"], object_count: objects.length)
      state["auto_switch"] = !!auto_switch
      state["auto_cleanup"] = !!auto_cleanup
      save_copy_state!(item, state)

      copied = 0
      skipped = 0
      failed = 0
      bytes_copied = 0

      Dir.mktmpdir("media_gallery_copy") do |tmpdir|
        objects.each_with_index do |object, index|
          source_info = source_store.object_info(object[:key]).deep_symbolize_keys
          raise "source_object_missing:#{object[:key]}" unless source_info[:exists]

          target_info = target_store.object_info(object[:key]).deep_symbolize_keys
          if skip_copy?(source_info: source_info, target_info: target_info)
            skipped += 1
            update_progress!(item, state, copied: copied, skipped: skipped, failed: failed, bytes_copied: bytes_copied, current_key: object[:key], index: index + 1, total: objects.length)
            next
          end

          tmp_path = File.join(tmpdir, "obj_#{index}_#{SecureRandom.hex(6)}")
          begin
            source_store.download_to_file!(object[:key], tmp_path)
            target_store.put_file!(tmp_path, key: object[:key], content_type: object[:content_type].presence || "application/octet-stream")
            bytes_copied += File.size(tmp_path).to_i
            copied += 1
          ensure
            FileUtils.rm_f(tmp_path)
          end

          update_progress!(item, state, copied: copied, skipped: skipped, failed: failed, bytes_copied: bytes_copied, current_key: object[:key], index: index + 1, total: objects.length)
        rescue => e
          failed += 1
          raise e
        end
      end

      verification = ::MediaGallery::MigrationPreview.preview(item, target_profile: target_profile)
      remaining = verification.dig(:totals, :missing_on_target_count).to_i
      remaining = verification.dig("totals", "missing_on_target_count").to_i if remaining <= 0 && verification.is_a?(Hash)
      raise "copy_verification_incomplete:#{remaining}" if remaining.positive?

      state = copy_state_for(item)
      state["status"] = "copied"
      state["copied_at"] = Time.now.utc.iso8601
      state["finished_at"] = state["copied_at"]
      state["objects_copied"] = copied
      state["objects_skipped"] = skipped
      state["objects_failed"] = failed
      state["bytes_copied"] = bytes_copied
      state["verification_missing_on_target_count"] = remaining
      state["last_error"] = nil
      save_copy_state!(item, state)

      if auto_switch
        item.reload
        switch_state = ::MediaGallery::MigrationSwitch.switch!(
          item,
          target_profile: target_profile,
          requested_by: state["requested_by"],
          mode: "auto_after_copy"
        )

        if auto_cleanup
          item.reload
          cleanup_state = ::MediaGallery::MigrationCleanup.enqueue_cleanup!(item, requested_by: state["requested_by"], force: false)
        end
        state = copy_state_for(item)
        state["status"] = "switched"
        state["switched_at"] = switch_state["switched_at"]
        state["switched_backend"] = switch_state["target_backend"]
        state["switched_profile_key"] = switch_state["target_profile_key"]
        state["last_error"] = nil
        state["auto_cleanup"] = !!auto_cleanup
        state["cleanup_enqueued_at"] = cleanup_state["queued_at"] if defined?(cleanup_state) && cleanup_state.is_a?(Hash)
        save_copy_state!(item, state)
      end

      state
    rescue => e
      state = copy_state_for(item)
      state["status"] = "failed"
      state["finished_at"] = Time.now.utc.iso8601
      state["last_error"] = "#{e.class}: #{e.message}"
      save_copy_state!(item, state) if item&.persisted?
      raise e
    end

    def copy_state_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[COPY_STATE_KEY]
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def save_copy_state!(item, state)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      meta[COPY_STATE_KEY] = state
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
    end

    def validate_plan_for_copy!(plan)
      raise "migration_plan_missing" unless plan.is_a?(Hash)
      target = plan[:target] || plan["target"]
      raise "target_profile_not_configured" if target.blank? || (target[:backend].blank? && target["backend"].blank?)

      source = plan[:source] || plan["source"]
      source_key = source[:profile_key].presence || source["profile_key"].presence
      target_key = target[:profile_key].presence || target["profile_key"].presence
      raise "source_and_target_same_profile" if source_key.present? && source_key == target_key

      warnings = Array(plan[:warnings] || plan["warnings"])
      unsupported = warnings.select { |w| w.to_s.include?("upload") || w.to_s.include?("source_store_unavailable") }
      raise(unsupported.first) if unsupported.present?
      true
    end
    private_class_method :validate_plan_for_copy!

    def build_queued_state(plan:, requested_by:, run_token:, force:, auto_switch:, auto_cleanup:)
      {
        "status" => "queued",
        "queued_at" => Time.now.utc.iso8601,
        "requested_by" => requested_by.to_s.presence,
        "target_profile" => plan.dig(:target, :profile) || plan.dig("target", "profile") || "target",
        "target_profile_key" => plan.dig(:target, :profile_key) || plan.dig("target", "profile_key"),
        "target_backend" => plan.dig(:target, :backend) || plan.dig("target", "backend"),
        "source_profile_key" => plan.dig(:source, :profile_key) || plan.dig("source", "profile_key"),
        "source_backend" => plan.dig(:source, :backend) || plan.dig("source", "backend"),
        "object_count" => plan.dig(:totals, :object_count).to_i.nonzero? || plan.dig("totals", "object_count").to_i,
        "source_bytes" => plan.dig(:totals, :source_bytes).to_i.nonzero? || plan.dig("totals", "source_bytes").to_i,
        "run_token" => run_token,
        "force" => !!force,
        "auto_switch" => !!auto_switch,
        "auto_cleanup" => !!auto_cleanup,
        "last_error" => nil
      }
    end
    private_class_method :build_queued_state

    def build_copying_state(plan:, prior_state:, run_token:, object_count:)
      state = prior_state.is_a?(Hash) ? prior_state.deep_dup : {}
      state["status"] = "copying"
      state["started_at"] = Time.now.utc.iso8601
      state["run_token"] = run_token
      state["target_profile"] ||= plan.dig(:target, :profile) || plan.dig("target", "profile") || "target"
      state["target_profile_key"] ||= plan.dig(:target, :profile_key) || plan.dig("target", "profile_key")
      state["target_backend"] ||= plan.dig(:target, :backend) || plan.dig("target", "backend")
      state["source_profile_key"] ||= plan.dig(:source, :profile_key) || plan.dig("source", "profile_key")
      state["source_backend"] ||= plan.dig(:source, :backend) || plan.dig("source", "backend")
      state["object_count"] = object_count
      state["objects_copied"] = 0
      state["objects_skipped"] = 0
      state["objects_failed"] = 0
      state["bytes_copied"] = 0
      state["last_error"] = nil
      state
    end
    private_class_method :build_copying_state

    def update_progress!(item, state, copied:, skipped:, failed:, bytes_copied:, current_key:, index:, total:)
      latest = copy_state_for(item)
      latest.merge!(state)
      latest["status"] = "copying"
      latest["objects_copied"] = copied
      latest["objects_skipped"] = skipped
      latest["objects_failed"] = failed
      latest["bytes_copied"] = bytes_copied
      latest["current_key"] = current_key
      latest["progress_index"] = index
      latest["progress_total"] = total
      latest["updated_at"] = Time.now.utc.iso8601
      save_copy_state!(item, latest)
    end
    private_class_method :update_progress!

    def skip_copy?(source_info:, target_info:)
      return false unless source_info[:exists] && target_info[:exists]
      source_bytes = source_info[:bytes].to_i
      target_bytes = target_info[:bytes].to_i
      source_bytes.positive? && source_bytes == target_bytes
    end
    private_class_method :skip_copy?

    def flatten_plan_objects(plan)
      Array(plan[:roles] || plan["roles"]).flat_map do |role_entry|
        role_hash = role_entry.is_a?(Hash) ? role_entry.deep_symbolize_keys : {}
        Array(role_hash[:objects]).map do |object|
          obj = object.is_a?(Hash) ? object.deep_symbolize_keys : {}
          {
            role_name: role_hash[:name].to_s,
            key: obj[:key].to_s,
            content_type: obj[:content_type].to_s
          }
        end
      end.reject { |row| row[:key].blank? }.uniq { |row| row[:key] }
    end
    private_class_method :flatten_plan_objects

    def store_for_summary(summary)
      summary = summary.is_a?(Hash) ? summary.deep_symbolize_keys : {}
      profile_key = summary[:profile_key].to_s
      case profile_key
      when "active_local", "active_s3", "target_local", "target_s3"
        ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      else
        backend = summary[:backend].to_s
        case backend
        when "local"
          ::MediaGallery::LocalAssetStore.new(root_path: ::MediaGallery::StorageSettingsResolver.local_asset_root_path)
        when "s3"
          ::MediaGallery::StorageSettingsResolver.build_store_for_profile("active")
        else
          nil
        end
      end
    end
    private_class_method :store_for_summary
  end
end
