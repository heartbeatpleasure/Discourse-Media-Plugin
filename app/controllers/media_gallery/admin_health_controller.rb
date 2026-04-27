# frozen_string_literal: true

module ::MediaGallery
  class AdminHealthController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def index
      full_storage = ActiveModel::Type::Boolean.new.cast(params[:full_storage])
      render_json_dump(::MediaGallery::HealthCheck.summary(full_storage: full_storage))
    rescue => e
      Rails.logger.error("[media_gallery] admin health failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("health_check_failed", status: 422, message: "Health check failed. Please check Rails logs and try again.")
    end

    def ignore
      ::MediaGallery::HealthCheck.ignore_finding!(params, user: current_user)
      render_json_dump(::MediaGallery::HealthCheck.summary(full_storage: false))
    rescue Discourse::InvalidParameters
      render_json_error("invalid_ignore_key", status: 422, message: "This health finding cannot be ignored.")
    rescue => e
      Rails.logger.error("[media_gallery] health ignore failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("health_ignore_failed", status: 422, message: "Could not ignore this health finding. Please check Rails logs and try again.")
    end

    def unignore
      ::MediaGallery::HealthCheck.unignore_finding!(params)
      render_json_dump(::MediaGallery::HealthCheck.summary(full_storage: false))
    rescue Discourse::InvalidParameters
      render_json_error("invalid_ignore_key", status: 422, message: "This health finding cannot be restored.")
    rescue => e
      Rails.logger.error("[media_gallery] health unignore failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("health_unignore_failed", status: 422, message: "Could not restore this health finding. Please check Rails logs and try again.")
    end


    def reconcile
      ::MediaGallery::HealthCheck.run_reconciliation!
      render_json_dump(::MediaGallery::HealthCheck.summary(full_storage: false))
    rescue => e
      Rails.logger.error("[media_gallery] storage reconciliation failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("storage_reconciliation_failed", status: 422, message: "Storage reconciliation failed. Please check Rails logs and try again.")
    end

    def reconciliation_export
      report = ::MediaGallery::HealthCheck.last_reconciliation
      if report.blank?
        return render_json_error("storage_reconciliation_not_run", status: 404, message: "Run storage reconciliation before exporting a report.")
      end

      category = params[:category].to_s.strip.presence
      include_ignored = ActiveModel::Type::Boolean.new.cast(params[:include_ignored])
      export_format = params[:export_format].to_s.strip.downcase

      if export_format == "csv"
        csv = ::MediaGallery::HealthCheck.reconciliation_export_csv(category: category, include_ignored: include_ignored)
        filename = "media-gallery-storage-reconciliation-#{Time.zone.now.strftime("%Y%m%d-%H%M%S")}.csv"
        return send_data csv, filename: filename, type: "text/csv; charset=utf-8", disposition: "attachment"
      end

      filtered = ::MediaGallery::HealthCheck.reconciliation_export_payload(category: category, include_ignored: include_ignored)
      render_json_dump(reconciliation: filtered, exported_at: Time.zone.now.iso8601)
    rescue => e
      Rails.logger.error("[media_gallery] storage reconciliation export failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("storage_reconciliation_export_failed", status: 422, message: "Could not export the reconciliation report. Please check Rails logs and try again.")
    end

    def notify_test
      result = ::MediaGallery::HealthCheck.summary(full_storage: false)
      sent = ::MediaGallery::HealthCheck.maybe_notify!(result)
      render_json_dump(ok: true, sent: sent, severity: result[:severity], alert_state: ::MediaGallery::HealthCheck.last_alert_state)
    rescue => e
      Rails.logger.error("[media_gallery] health notification test failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("health_notification_failed", status: 422, message: "Health notification test failed. Please check the notify group setting and Rails logs.")
    end
  end
end
