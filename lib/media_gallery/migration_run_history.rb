# frozen_string_literal: true

require "time"

module ::MediaGallery
  module MigrationRunHistory
    module_function

    HISTORY_KEY = "migration_history"
    COPY_STATE_KEY = "migration_copy"
    VERIFY_STATE_KEY = "migration_verify"
    SWITCH_STATE_KEY = "migration_switch"
    CLEANUP_STATE_KEY = "migration_cleanup"
    ROLLBACK_STATE_KEY = "migration_rollback"
    FINALIZE_STATE_KEY = "migration_finalize"

    CURRENT_STATE_KEYS = [
      COPY_STATE_KEY,
      VERIFY_STATE_KEY,
      SWITCH_STATE_KEY,
      CLEANUP_STATE_KEY,
      ROLLBACK_STATE_KEY,
      FINALIZE_STATE_KEY,
    ].freeze

    def history_for(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[HISTORY_KEY]
      Array(value).select { |entry| entry.is_a?(Hash) }.map(&:deep_dup)
    end

    def archive_current_cycle!(item, archived_by: nil, reason: nil)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      cycle = current_cycle_from_meta(meta)
      return nil if cycle.blank?

      entry = {
        "archived_at" => Time.now.utc.iso8601,
        "archived_by" => archived_by.to_s.presence,
        "reason" => reason.to_s.presence,
        "source_profile_key" => first_present(cycle.values.map { |value| value["source_profile_key"] }),
        "target_profile_key" => first_present(cycle.values.map { |value| value["target_profile_key"] }),
        "source_backend" => first_present(cycle.values.map { |value| value["source_backend"] }),
        "target_backend" => first_present(cycle.values.map { |value| value["target_backend"] }),
        "copy" => cycle[COPY_STATE_KEY],
        "verify" => cycle[VERIFY_STATE_KEY],
        "switch" => cycle[SWITCH_STATE_KEY],
        "cleanup" => cycle[CLEANUP_STATE_KEY],
        "rollback" => cycle[ROLLBACK_STATE_KEY],
        "finalize" => cycle[FINALIZE_STATE_KEY],
      }.compact

      history = Array(meta[HISTORY_KEY]).select { |value| value.is_a?(Hash) }
      history.unshift(entry)
      meta[HISTORY_KEY] = history.first(15)
      CURRENT_STATE_KEYS.each { |key| meta.delete(key) }
      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      entry
    end

    def clear_current_cycle!(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
      changed = false
      CURRENT_STATE_KEYS.each do |key|
        changed ||= meta.key?(key)
        meta.delete(key)
      end
      return false unless changed

      item.update_columns(extra_metadata: meta, updated_at: Time.now)
      true
    end

    def current_cycle_present?(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      current_cycle_from_meta(meta).present?
    end

    def current_cycle_from_meta(meta)
      CURRENT_STATE_KEYS.each_with_object({}) do |key, acc|
        value = meta[key]
        acc[key] = value.deep_dup if value.is_a?(Hash) && value.present?
      end
    end
    private_class_method :current_cycle_from_meta

    def first_present(values)
      Array(values).find(&:present?)
    end
    private_class_method :first_present
  end
end
