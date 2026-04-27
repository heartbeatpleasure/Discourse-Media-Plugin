# frozen_string_literal: true

module ::MediaGallery
  module ProcessingNotifications
    extend self

    READY_STATUS = "ready"
    FAILED_STATUS = "failed"
    VALID_STATUSES = [READY_STATUS, FAILED_STATUS].freeze
    MAX_TITLE_LENGTH = 120

    def notify!(item, status)
      return unless notifications_enabled?
      return if item.blank? || !item.persisted?

      status = status.to_s
      return unless VALID_STATUSES.include?(status)

      item.reload
      return if item.admin_hidden?

      user = item.user
      return if user.blank? || user.id.blank? || user.id.to_i <= 0 || user.staged? || !user.active?

      meta = item.extra_metadata_hash.deep_dup
      processing_meta = meta["processing"].is_a?(Hash) ? meta["processing"].deep_dup : {}
      notifications_meta = processing_meta["notifications"].is_a?(Hash) ? processing_meta["notifications"].deep_dup : {}

      dedupe_key = notification_dedupe_key(item, processing_meta, status)
      return if notifications_meta["#{status}_dedupe_key"] == dedupe_key

      notification = create_notification!(item, user, status)
      return if notification.blank?

      now = Time.now.utc.iso8601
      notifications_meta["#{status}_dedupe_key"] = dedupe_key
      notifications_meta["#{status}_notified_at"] = now
      notifications_meta["#{status}_notification_id"] = notification.id
      processing_meta["notifications"] = notifications_meta
      meta["processing"] = processing_meta
      item.update_column(:extra_metadata, meta)

      record_notification_event(item, user, status, notification)
      notification
    rescue => e
      Rails.logger.warn("[media_gallery] processing notification failed item_id=#{item&.id} status=#{status} error=#{e.class}: #{e.message}")
      nil
    end

    private

    def notifications_enabled?
      !SiteSetting.respond_to?(:media_gallery_processing_notifications_enabled) || SiteSetting.media_gallery_processing_notifications_enabled
    end

    def notification_dedupe_key(item, processing_meta, status)
      run_id = processing_meta["current_run_token"].presence || processing_meta["last_started_at"].presence || processing_meta["last_finished_at"].presence || item.updated_at&.utc&.iso8601 || item.id
      "#{status}:#{run_id}"
    end

    def create_notification!(item, user, status)
      notification = ::Notification.new(
        notification_type: ::Notification.types[:custom],
        user_id: user.id,
        data: notification_data(item, status).to_json,
      )

      # Keep this as an in-app Discourse notification without creating email noise
      # for asynchronous processing status changes.
      notification.skip_send_email = true if notification.respond_to?(:skip_send_email=)
      notification.save!
      notification
    end

    def notification_data(item, status)
      {
        media_gallery_processing: true,
        status: status,
        message: message_key(status),
        title: title_key(status),
        media_title: clean_title(item.title),
        media_public_id: item.public_id.to_s,
        url: notification_url(status),
      }
    end

    def message_key(status)
      status == READY_STATUS ? "media_gallery.notifications.upload_ready" : "media_gallery.notifications.upload_failed"
    end

    def title_key(status)
      status == READY_STATUS ? "media_gallery.notifications.upload_ready_title" : "media_gallery.notifications.upload_failed_title"
    end

    def notification_url(status)
      if status == READY_STATUS
        "/media-library?tab=mine"
      else
        "/media-library?tab=mine&status=failed"
      end
    end

    def clean_title(value)
      if defined?(::MediaGallery::TextSanitizer)
        ::MediaGallery::TextSanitizer.plain_text(value, max_length: MAX_TITLE_LENGTH)
      else
        value.to_s.gsub(/[\u0000-\u001F\u007F]/, " ").squish.truncate(MAX_TITLE_LENGTH)
      end.presence || "Untitled media item"
    end

    def record_notification_event(item, user, status, notification)
      return unless defined?(::MediaGallery::LogEvents)

      ::MediaGallery::LogEvents.record(
        event_type: "processing_notification_sent",
        severity: status == READY_STATUS ? "success" : "warning",
        category: "processing",
        user: user,
        media_item: item,
        message: "Processing #{status} notification sent",
        details: {
          notification_id: notification.id,
          status: status,
          media_public_id: item.public_id,
        },
      )
    rescue => e
      Rails.logger.warn("[media_gallery] processing notification log failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      nil
    end
  end
end
