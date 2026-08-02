# frozen_string_literal: true

require "digest"
require "time"

module ::MediaGallery
  module EvidenceAcquisition
    module_function

    STAFF_UPLOAD_ROLES = %w[
      external_original working_copy source_screenshot source_html source_warc source_headers
      rights_statement other
    ].freeze

    def automatic_queue_enabled?
      return true unless SiteSetting.respond_to?(:media_gallery_evidence_scan_on_upload)

      SiteSetting.media_gallery_evidence_scan_on_upload
    rescue
      true
    end

    def scan_required?(record)
      record.storage_kind == "file" && STAFF_UPLOAD_ROLES.include?(record.role.to_s)
    end

    def enqueue!(record, requested_by_id: nil, force: false, inspection_only: false)
      return false unless record.present? && record.persisted?
      return false unless record.storage_kind == "file"
      return false unless force || automatic_queue_enabled?

      now = Time.now.utc
      scan_meta = hash_copy(record.scan_metadata)
      unless inspection_only
        scan_meta.merge!(
          "provider" => ::MediaGallery::EvidenceScanner.mode,
          "state" => ::MediaGallery::EvidenceScanner.enabled? && scan_required?(record) ? "queued" : "disabled",
          "queued_at_utc" => now.iso8601(6),
          "requested_by_id" => requested_by_id,
        )
      end
      inspection_meta = hash_copy(record.inspection_metadata)
      inspection_meta.merge!(
        "state" => "queued",
        "queued_at_utc" => now.iso8601(6),
        "requested_by_id" => requested_by_id,
      )

      status = if !inspection_only && ::MediaGallery::EvidenceScanner.enabled? && scan_required?(record)
        "queued"
      else
        record.quarantine_status
      end
      record.update!(
        quarantine_status: status,
        scan_metadata: scan_meta,
        inspection_metadata: inspection_meta,
      )

      Jobs.enqueue(
        :media_gallery_evidence_acquisition,
        evidence_object_id: record.id,
        requested_by_id: requested_by_id,
        inspection_only: inspection_only,
      )
      true
    rescue => e
      Rails.logger.warn("[media_gallery] evidence acquisition enqueue failed object_id=#{record&.id} error=#{e.class}: #{e.message}")
      mark_enqueue_failure(record, e, inspection_only: inspection_only)
      false
    end

    def process!(record, requested_by_id: nil, inspection_only: false)
      return if record.blank? || record.storage_kind != "file"

      mutex_key = "media_gallery_evidence_acquisition_#{record.id}"
      runner = proc { process_under_lock!(record.reload, requested_by_id: requested_by_id, inspection_only: inspection_only) }
      if defined?(::DistributedMutex)
        ::DistributedMutex.synchronize(mutex_key, validity: 2.hours, &runner)
      else
        runner.call
      end
    end

    def health
      builder = proc do
        {
          "scanner" => ::MediaGallery::EvidenceScanner.health,
          "inspector" => ::MediaGallery::EvidenceInspector.health,
          "storage" => ::MediaGallery::EvidenceVault.storage_health,
          "automatic_queue" => automatic_queue_enabled?,
        }
      end
      return builder.call unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache.present?

      Rails.cache.fetch("media_gallery_evidence_acquisition_health_v1", expires_in: 30.seconds, &builder)
    end

    def process_under_lock!(record, requested_by_id: nil, inspection_only: false)
      path = ::MediaGallery::EvidenceVault.absolute_path(record)
      verify_immutable_file!(record, path)
      user = ::User.find_by(id: requested_by_id)

      scan_result = nil
      if inspection_only
        scan_result = hash_copy(record.scan_metadata)
        scan_result["state"] = "manual_clean" if scan_result["state"].blank?
        scan_result["provider"] ||= "manual_review"
      elsif scan_required?(record) && ::MediaGallery::EvidenceScanner.enabled?
        scan_result = perform_scan!(record, path)
      elsif scan_required?(record)
        scan_result = ::MediaGallery::EvidenceScanner.disabled_result
        preserved_status = %w[clean rejected].include?(record.quarantine_status) ? record.quarantine_status : "pending"
        update_scan_result!(record, scan_result, quarantine_status: preserved_status)
      else
        scan_result = ::MediaGallery::EvidenceScanner.disabled_result.merge(
          "state" => "not_applicable",
          "message" => "This system-generated evidence role does not require malware scanning.",
        )
        update_scan_result!(record, scan_result, quarantine_status: "not_applicable")
      end

      current_status = record.reload.quarantine_status
      inspection_result = if scan_result["state"] == "infected" || current_status == "infected"
        {
          "state" => "not_run",
          "inspected_at_utc" => Time.now.utc.iso8601(6),
          "message" => "Technical inspection was skipped because malware was detected.",
        }
      elsif scan_required?(record) && current_status != "clean"
        {
          "state" => "not_run",
          "inspected_at_utc" => Time.now.utc.iso8601(6),
          "message" => "Technical inspection is deferred until the evidence has a clean automatic scan or documented manual quarantine review.",
        }
      else
        ::MediaGallery::EvidenceInspector.inspect(record, path)
      end
      record.update!(
        inspection_metadata: inspection_result,
        inspected_at: parse_time(inspection_result["inspected_at_utc"]) || Time.now.utc,
      )

      ::MediaGallery::EvidenceChain.record!(
        evidence_case: record.evidence_case,
        event_type: "evidence_acquisition_checked",
        user: user,
        actor_type: user.present? ? nil : "system",
        actor_ref: user.present? ? nil : "system:evidence-service",
        object_ref: record.object_ref,
        details: {
          quarantine_status: record.reload.quarantine_status,
          scan_state: scan_result["state"],
          scan_provider: scan_result["provider"],
          inspection_state: inspection_result["state"],
          sha256: record.sha256,
          size_bytes: record.size_bytes,
        },
      )
      record
    rescue => e
      Rails.logger.warn("[media_gallery] evidence acquisition failed object_id=#{record&.id} error=#{e.class}: #{e.message}")
      mark_processing_failure(record, e, inspection_only: inspection_only)
      raise
    end
    private_class_method :process_under_lock!

    def perform_scan!(record, path)
      started = Time.now.utc
      scan_meta = hash_copy(record.scan_metadata).merge(
        "provider" => ::MediaGallery::EvidenceScanner.mode,
        "state" => "scanning",
        "started_at_utc" => started.iso8601(6),
      )
      record.update!(quarantine_status: "scanning", scan_metadata: scan_meta, scan_started_at: started)
      result = ::MediaGallery::EvidenceScanner.scan(path)
      status = quarantine_status_for_scan(result["state"])
      update_scan_result!(record, result, quarantine_status: status)
      result
    end
    private_class_method :perform_scan!

    def update_scan_result!(record, result, quarantine_status:)
      completed = Time.now.utc
      metadata = hash_copy(result).merge("completed_at_utc" => completed.iso8601(6))
      record.update!(
        quarantine_status: quarantine_status,
        scan_metadata: metadata,
        scan_completed_at: completed,
      )
    end
    private_class_method :update_scan_result!

    def quarantine_status_for_scan(state)
      case state.to_s
      when "clean" then "clean"
      when "infected" then "infected"
      when "scanner_unavailable" then "scanner_unavailable"
      when "skipped_size" then "skipped_size"
      when "disabled" then "pending"
      else "scan_failed"
      end
    end
    private_class_method :quarantine_status_for_scan

    def verify_immutable_file!(record, path)
      stat = File.lstat(path)
      raise "evidence_symlink_not_allowed" if stat.symlink?
      raise "evidence_size_changed" unless stat.size == record.size_bytes.to_i
      actual = Digest::SHA256.file(path).hexdigest
      raise "evidence_hash_mismatch" unless ActiveSupport::SecurityUtils.secure_compare(actual, record.sha256.to_s)
    end
    private_class_method :verify_immutable_file!

    def mark_processing_failure(record, error, inspection_only: false)
      return if record.blank? || !record.persisted?

      if inspection_only
        inspection = hash_copy(record.inspection_metadata).merge(
          "state" => "failed",
          "error_class" => error.class.name,
          "message" => error.message.to_s.truncate(500),
          "completed_at_utc" => Time.now.utc.iso8601(6),
        )
        record.update!(inspection_metadata: inspection, inspected_at: Time.now.utc)
      else
        metadata = hash_copy(record.scan_metadata).merge(
          "state" => "scan_failed",
          "error_class" => error.class.name,
          "message" => error.message.to_s.truncate(500),
          "completed_at_utc" => Time.now.utc.iso8601(6),
        )
        record.update!(
          quarantine_status: "scan_failed",
          scan_metadata: metadata,
          scan_completed_at: Time.now.utc,
        )
      end
    rescue => update_error
      Rails.logger.error("[media_gallery] could not persist evidence acquisition failure object_id=#{record&.id} error=#{update_error.class}: #{update_error.message}")
    end
    private_class_method :mark_processing_failure

    def mark_enqueue_failure(record, error, inspection_only: false)
      return if record.blank? || !record.persisted?

      metadata = hash_copy(record.scan_metadata).merge(
        "state" => "scan_failed",
        "error_class" => error.class.name,
        "message" => "The evidence acquisition job could not be queued.",
        "completed_at_utc" => Time.now.utc.iso8601(6),
      )
      if inspection_only
        inspection = hash_copy(record.inspection_metadata).merge(
          "state" => "failed",
          "error_class" => error.class.name,
          "message" => "The evidence inspection job could not be queued.",
          "completed_at_utc" => Time.now.utc.iso8601(6),
        )
        record.update!(inspection_metadata: inspection, inspected_at: Time.now.utc)
      else
        attributes = { scan_metadata: metadata, scan_completed_at: Time.now.utc }
        if ::MediaGallery::EvidenceScanner.enabled? && scan_required?(record)
          attributes[:quarantine_status] = "scan_failed"
        end
        record.update!(attributes)
      end
    rescue
      nil
    end
    private_class_method :mark_enqueue_failure

    def hash_copy(value)
      value.is_a?(Hash) ? value.deep_dup.deep_stringify_keys : {}
    end
    private_class_method :hash_copy

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_time
  end
end
