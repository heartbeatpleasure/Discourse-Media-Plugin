# frozen_string_literal: true

require "json"

module ::MediaGallery
  module OperationLogger
    module_function

    def info(event, item: nil, operation: nil, data: nil)
      log(:info, event, item: item, operation: operation, data: data)
    end

    def warn(event, item: nil, operation: nil, data: nil)
      log(:warn, event, item: item, operation: operation, data: data)
    end

    def error(event, item: nil, operation: nil, data: nil)
      log(:error, event, item: item, operation: operation, data: data)
    end

    def audit(event, item: nil, operation: nil, user: nil, request: nil, data: nil, result: nil)
      payload = stringify_hash(data || {}).merge(
        "actor_id" => user&.id,
        "actor_username" => user&.username,
        "result" => result.to_s.presence
      ).compact

      log(:info, event, item: item, operation: operation, data: payload)

      if defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.respond_to?(:record)
        ::MediaGallery::LogEvents.record(
          event_type: event.to_s,
          severity: "info",
          category: "audit",
          request: request,
          user: user,
          media_item: item,
          message: "Admin action: #{operation.presence || event}",
          details: payload
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] audit_logger_failed event=#{event} error=#{e.class}: #{e.message}")
    end

    def log(level, event, item: nil, operation: nil, data: nil)
      payload = {
        event: event.to_s,
        operation: operation.to_s.presence,
        media_item_id: item&.id,
        public_id: item&.public_id,
        status: item&.status,
        backend: item&.managed_storage_backend,
        profile: item&.managed_storage_profile,
      }.compact

      payload.merge!(stringify_hash(data || {}))
      Rails.logger.public_send(level, "[media_gallery] #{payload.to_json}")
    rescue => e
      Rails.logger.warn("[media_gallery] logger_failed event=#{event} error=#{e.class}: #{e.message}")
    end

    def stringify_hash(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = stringify_hash(v)
        end
      when Array
        value.map { |entry| stringify_hash(entry) }
      when Time, DateTime
        value.iso8601
      else
        value
      end
    end
    private_class_method :stringify_hash
  end
end
