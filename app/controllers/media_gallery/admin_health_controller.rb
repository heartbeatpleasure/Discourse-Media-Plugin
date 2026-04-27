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
