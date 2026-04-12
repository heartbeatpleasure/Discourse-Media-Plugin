# frozen_string_literal: true

module ::MediaGallery
  module OperationCoordinator
    module_function

    def ensure_operation_allowed!(item, requested_operation:)
      raise "media_item_required" if item.blank?

      requested = requested_operation.to_s
      processing = processing_state(item)
      copy = ::MediaGallery::MigrationCopy.copy_state_for(item)
      verify = ::MediaGallery::MigrationVerify.verify_state_for(item)
      cleanup = ::MediaGallery::MigrationCleanup.cleanup_state_for(item)
      finalize = ::MediaGallery::MigrationFinalize.finalize_state_for(item)

      if processing_active?(item, processing) && %w[verify switch cleanup rollback].include?(requested)
        raise "processing_in_progress"
      end

      if copy_active?(copy) && %w[verify switch cleanup rollback finalize].include?(requested)
        raise "copy_in_progress"
      end

      if verify_active?(verify) && %w[switch cleanup rollback finalize].include?(requested)
        raise "verify_in_progress"
      end

      if cleanup_active?(cleanup) && %w[verify switch rollback].include?(requested)
        raise "cleanup_in_progress"
      end

      if finalize_pending?(finalize) && %w[copy verify switch rollback].include?(requested)
        raise "finalize_in_progress"
      end

      true
    end

    def processing_active?(item, processing = nil)
      return false if item.blank?

      state = processing.is_a?(Hash) ? processing : processing_state(item)
      status = item.status.to_s
      return false unless %w[queued processing].include?(status)

      stage = state["current_stage"].to_s
      run_token = state["current_run_token"].to_s
      status == "queued" || run_token.present? || stage.present?
    end

    def copy_active?(state)
      %w[queued copying].include?(state.to_h["status"].to_s)
    end

    def verify_active?(state)
      %w[queued verifying].include?(state.to_h["status"].to_s)
    end

    def cleanup_active?(state)
      %w[queued cleaning].include?(state.to_h["status"].to_s)
    end

    def finalize_pending?(state)
      %w[queued pending_cleanup].include?(state.to_h["status"].to_s)
    end

    def processing_state(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta["processing"]
      value.is_a?(Hash) ? value : {}
    end
  end
end
