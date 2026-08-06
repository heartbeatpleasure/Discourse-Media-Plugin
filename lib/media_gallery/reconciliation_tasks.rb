# frozen_string_literal: true

require "cgi"
require "securerandom"
require "time"

module ::MediaGallery
  module ReconciliationTasks
    module_function

    TASK_NAMESPACE = "media_gallery_reconciliation_tasks"
    ACTIVE_TASK_KEY = "__active_task_id"
    LAST_TASK_KEY = "__last_task_id"
    CREATE_MUTEX_KEY = "media_gallery_storage_reconciliation_task_create"
    ACTIVE_STATUSES = %w[queued working].freeze
    TERMINAL_STATUSES = %w[complete failed stale].freeze
    STALE_AFTER_SECONDS = 60 * 60
    VISIBLE_TERMINAL_SECONDS = 24.hours.to_i
    POLLING_TIMEOUT_SECONDS = 6.hours.to_i
    MAX_ERROR_LENGTH = 500

    def create_or_reuse_task!(scan_mode:, user:)
      normalized_mode = normalize_scan_mode(scan_mode)

      with_create_mutex do
        if (existing = active_task)
          return {
            task_id: existing["task_id"].to_s,
            task: existing,
            reused: true,
          }
        end

        task_id = SecureRandom.hex(12)
        limits = ::MediaGallery::HealthCheck.reconciliation_limits(scan_mode: normalized_mode)
        now = Time.now.utc.iso8601
        payload = {
          "task_id" => task_id,
          "scan_mode" => normalized_mode,
          "status" => "queued",
          "requested_by_user_id" => user&.id,
          "requested_by_username" => user&.username.to_s.presence,
          "created_at" => now,
          "updated_at" => now,
          "started_at" => nil,
          "finished_at" => nil,
          "limits" => limits.deep_stringify_keys,
          "progress" => initial_progress(limits),
          "report" => nil,
          "error" => nil,
          "error_class" => nil,
          "error_detail" => nil,
        }.compact

        write_task(task_id, payload)
        ::PluginStore.set(TASK_NAMESPACE, ACTIVE_TASK_KEY, task_id)
        ::PluginStore.set(TASK_NAMESPACE, LAST_TASK_KEY, task_id)

        {
          task_id: task_id,
          task: payload,
          reused: false,
        }
      end
    end

    def read_task(task_id)
      id = task_id.to_s
      return nil if id.blank?

      value = ::PluginStore.get(TASK_NAMESPACE, task_key(id))
      value.is_a?(Hash) ? value.deep_stringify_keys : nil
    rescue
      nil
    end

    def write_task(task_id, payload, touch: true)
      id = task_id.to_s
      raise ArgumentError, "task_id_required" if id.blank?

      stored = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      stored["task_id"] = id
      stored["updated_at"] = Time.now.utc.iso8601 if touch
      ::PluginStore.set(TASK_NAMESPACE, task_key(id), stored)
      stored
    end

    def active_task_id
      ::PluginStore.get(TASK_NAMESPACE, ACTIVE_TASK_KEY).to_s.presence
    rescue
      nil
    end

    def last_task_id
      ::PluginStore.get(TASK_NAMESPACE, LAST_TASK_KEY).to_s.presence
    rescue
      nil
    end

    def active_task
      id = active_task_id
      return nil if id.blank?

      task = read_task(id)
      if task.blank?
        clear_active_task!(id)
        return nil
      end

      unless active_status?(task["status"])
        clear_active_task!(id)
        return nil
      end

      if stale?(task)
        mark_task_stale!(id)
        return nil
      end

      task
    end

    def visible_task
      active = active_task
      return active if active.present?

      task = read_task(last_task_id)
      return nil if task.blank?
      return nil if task["status"].to_s == "complete"
      return nil unless terminal_status?(task["status"])
      return nil if older_than?(task["updated_at"], VISIBLE_TERMINAL_SECONDS)

      task
    end

    def public_payload(task_or_id)
      task = task_or_id.is_a?(Hash) ? task_or_id.deep_stringify_keys : read_task(task_or_id)
      return nil if task.blank?

      {
        task_id: task["task_id"],
        scan_mode: normalize_scan_mode(task["scan_mode"]),
        status: task["status"].to_s.presence || "queued",
        requested_by_user_id: task["requested_by_user_id"],
        requested_by_username: task["requested_by_username"],
        created_at: task["created_at"],
        updated_at: task["updated_at"],
        started_at: task["started_at"],
        finished_at: task["finished_at"],
        limits: task["limits"] || {},
        progress: task["progress"] || {},
        report: task["report"],
        error: task["error"],
        error_class: task["error_class"],
        status_url: status_url(task["task_id"]),
        polling_timeout_seconds: POLLING_TIMEOUT_SECONDS,
      }.compact
    end

    def visible_task_summary
      public_payload(visible_task)
    end

    def mark_task_working!(task_id)
      task = read_task(task_id)
      return nil if task.blank? || terminal_status?(task["status"])

      now = Time.now.utc.iso8601
      task["status"] = "working"
      task["started_at"] ||= now
      task["error"] = nil
      task["error_class"] = nil
      task["error_detail"] = nil
      task["progress"] = (task["progress"] || {}).merge(
        "stage" => "preparing",
        "stage_label" => "Preparing storage reconciliation",
      )
      write_task(task_id, task)
    end

    def update_progress!(task_id, progress)
      task = read_task(task_id)
      return nil if task.blank? || terminal_status?(task["status"])

      task["status"] = "working"
      task["progress"] = (task["progress"] || {}).merge(normalize_progress(progress))
      write_task(task_id, task)
    end

    def mark_task_complete!(task_id, report)
      task = read_task(task_id)
      return nil if task.blank?

      now = Time.now.utc.iso8601
      report_hash = report.is_a?(Hash) ? report.deep_stringify_keys : {}
      task["status"] = "complete"
      task["finished_at"] = now
      task["error"] = nil
      task["error_class"] = nil
      task["error_detail"] = nil
      task["report"] = {
        "generated_at" => report_hash["generated_at"],
        "finished_at" => report_hash["finished_at"],
        "severity" => report_hash["severity"],
        "duration_ms" => report_hash["duration_ms"],
        "scan_mode" => report_hash["scan_mode"],
        "stats" => report_hash["stats"] || {},
      }.compact
      task["progress"] = (task["progress"] || {}).merge(
        "stage" => "complete",
        "stage_label" => "Storage reconciliation completed",
      )
      stored = write_task(task_id, task)
      clear_active_task!(task_id)
      stored
    end

    def mark_task_failed!(task_id, error)
      task = read_task(task_id)
      return nil if task.blank?

      exception = error.is_a?(Exception) ? error : nil
      detail = exception ? "#{exception.class}: #{exception.message}" : error.to_s
      task["status"] = "failed"
      task["finished_at"] = Time.now.utc.iso8601
      task["error"] = "Storage reconciliation failed. Check Rails logs and try again."
      task["error_class"] = exception&.class&.name.to_s.presence
      task["error_detail"] = detail.truncate(MAX_ERROR_LENGTH)
      task["progress"] = (task["progress"] || {}).merge(
        "stage" => "failed",
        "stage_label" => "Storage reconciliation failed",
      )
      stored = write_task(task_id, task)
      clear_active_task!(task_id)
      stored
    end

    def mark_task_stale!(task_id)
      task = read_task(task_id)
      return nil if task.blank? || terminal_status?(task["status"])

      task["status"] = "stale"
      task["finished_at"] = Time.now.utc.iso8601
      task["error"] = "The reconciliation task stopped updating and may have been interrupted. Start a new scan after checking Background jobs and Rails logs."
      task["progress"] = (task["progress"] || {}).merge(
        "stage" => "stale",
        "stage_label" => "Storage reconciliation appears interrupted",
      )
      stored = write_task(task_id, task)
      clear_active_task!(task_id)
      stored
    end

    def status_url(task_id)
      "/admin/plugins/media-gallery/health/reconciliation-status/#{CGI.escape(task_id.to_s)}.json"
    end

    def active_status?(status)
      ACTIVE_STATUSES.include?(status.to_s)
    end

    def terminal_status?(status)
      TERMINAL_STATUSES.include?(status.to_s)
    end

    def stale?(task)
      return false unless active_status?(task["status"])

      older_than?(task["updated_at"], STALE_AFTER_SECONDS)
    end

    def older_than?(timestamp, seconds)
      value = Time.iso8601(timestamp.to_s)
      value < Time.now.utc - seconds.to_i
    rescue
      true
    end

    def task_key(task_id)
      task_id.to_s
    end

    def normalize_scan_mode(value)
      value.to_s == "expanded" ? "expanded" : "bounded"
    end

    def initial_progress(limits)
      {
        "stage" => "queued",
        "stage_label" => "Queued for background processing",
        "items_checked" => 0,
        "item_limit" => limits[:item_limit].to_i,
        "profiles_checked" => 0,
        "profiles_total" => 0,
        "objects_scanned" => 0,
      }
    end

    def normalize_progress(progress)
      raw = progress.is_a?(Hash) ? progress : {}
      allowed = %i[
        stage
        stage_label
        items_checked
        item_limit
        profiles_checked
        profiles_total
        objects_scanned
        current_profile_key
        current_profile_label
      ]

      raw.each_with_object({}) do |(key, value), memo|
        symbol = key.to_sym rescue nil
        next unless allowed.include?(symbol)

        memo[symbol.to_s] = value
      end
    end

    def clear_active_task!(task_id = nil)
      current = active_task_id
      return false if current.blank?
      return false if task_id.present? && current.to_s != task_id.to_s

      ::PluginStore.remove(TASK_NAMESPACE, ACTIVE_TASK_KEY)
      true
    rescue
      false
    end

    def with_create_mutex(&block)
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(CREATE_MUTEX_KEY, validity: 30.seconds, &block)
      else
        block.call
      end
    end
  end
end
