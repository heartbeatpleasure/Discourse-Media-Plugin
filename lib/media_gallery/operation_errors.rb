# frozen_string_literal: true

module ::MediaGallery
  module OperationErrors
    module_function

    def normalize(error_or_message, operation: nil)
      raw_message =
        case error_or_message
        when Exception
          error_or_message.message.to_s
        else
          error_or_message.to_s
        end

      code, detail = split_code_and_detail(raw_message)
      mapped = map_error(code, detail: detail, operation: operation)

      {
        raw: raw_message,
        code: code,
        detail: detail,
        message: mapped[:message],
        retryable: mapped[:retryable],
        recommended_action: mapped[:recommended_action],
      }
    end

    def apply_failure!(state, error_or_message, operation: nil)
      normalized = normalize(error_or_message, operation: operation)
      state["last_error"] = normalized[:raw]
      state["last_error_code"] = normalized[:code]
      state["last_error_detail"] = normalized[:detail] if normalized[:detail].present?
      state["last_error_human"] = normalized[:message]
      state["retryable"] = normalized[:retryable]
      state["recommended_action"] = normalized[:recommended_action]
      state
    end

    def clear_failure!(state)
      state.delete("last_error")
      state.delete("last_error_code")
      state.delete("last_error_detail")
      state.delete("last_error_human")
      state.delete("retryable")
      state.delete("recommended_action")
      state
    end

    def split_code_and_detail(raw_message)
      message = raw_message.to_s
      message = message.sub(/\A[A-Z][A-Za-z0-9_:]+:\s*/, "")
      if message.include?(":")
        code, detail = message.split(":", 2)
        [code.to_s.strip.presence || message, detail.to_s.strip.presence]
      else
        [message, nil]
      end
    end
    private_class_method :split_code_and_detail

    def map_error(code, detail:, operation:)
      case code.to_s
      when "media_item_required"
        present("No media item was selected.", retryable: false)
      when "item_not_ready"
        present("This item is not ready yet. Only ready items can use this action.")
      when "migration_plan_missing"
        present("A valid migration plan could not be built for this item.", recommended_action: "Refresh the item and try again.")
      when "target_profile_not_configured"
        present("The target profile is not configured or is unavailable.", retryable: false, recommended_action: "Check the storage settings and run a probe.")
      when "source_and_target_same_profile"
        present("Source and target use the same storage profile. Choose a different target profile.", retryable: false)
      when "source_and_target_same_location"
        present("Source and target point to the same storage location. Migration would not change anything.", retryable: false)
      when "copy_already_in_progress"
        present("A copy operation is already running for this item.", recommended_action: "Wait for copy to finish or clear the queued state if it is stuck.")
      when "cleanup_already_in_progress"
        present("A cleanup operation is already running for this item.", recommended_action: "Wait for cleanup to finish or clear the queued state if it is stuck.")
      when "cleanup_already_finalized"
        present("This migration cycle is already finalized. Cleanup is only available with force.", retryable: false)
      when "previous_cycle_cleanup_pending"
        present("The previous migration cycle still has an open cleanup/finalize step.", retryable: false, recommended_action: "Finish cleanup/finalize first or use force only if you understand why.")
      when "previous_cycle_not_finalized"
        present("The previous migration cycle is not finished yet.", retryable: false, recommended_action: "Finalize the current cycle or use force only if you intentionally want to start a new cycle.")
      when "target_not_fully_copied"
        present("The target is not fully copied yet. Switch is blocked.", recommended_action: "Run copy and verify first.")
      when "cleanup_target_incomplete"
        present("Cleanup is blocked because the active target is not complete yet.", recommended_action: "Run verify on the active target before cleanup.")
      when "cleanup_remaining_source_objects"
        present("Cleanup could not remove all source objects.", recommended_action: "Review the delete results and retry cleanup if it is safe.")
      when "cleanup_source_profile_changed_since_switch"
        present("Cleanup stopped because the source profile changed after the switch.", retryable: false, recommended_action: "Check the storage configuration before continuing.")
      when "cleanup_target_profile_changed_since_switch"
        present("Cleanup stopped because the active target profile changed after the switch.", retryable: false, recommended_action: "Check the storage configuration before continuing.")
      when "switch_state_missing"
        present("There is no switch state for this item yet.", retryable: false, recommended_action: "Run copy and switch first.")
      when "rollback_source_missing"
        present("Rollback is blocked because the original source object is missing#{detail.present? ? ": #{detail}" : "."}", retryable: false)
      when "rollback_not_available"
        present("Rollback is not available for this state right now.", retryable: false)
      when "rollback_not_available_after_finalize"
        present("Rollback is blocked because this migration cycle is already finalized.", retryable: false, recommended_action: "Start a new migration cycle if you want to switch again.")
      when "already_on_source_profile"
        present("The item is already back on the source profile.", retryable: false)
      when "copy_verification_incomplete"
        present("Copy finished, but the target is still missing objects#{detail.present? ? ": #{detail}" : "."}", recommended_action: "Run verify and review the missing objects before switching.")
      when "source_object_missing"
        present("A source object is missing#{detail.present? ? ": #{detail}" : "."}", recommended_action: "Check source storage and try copy again.")
      when "verify_store_missing"
        present("Verify could not open the source or target store.", recommended_action: "Check storage health/probe.")
      when "finalize_not_available"
        present("Finalize is not available for this cycle yet.", retryable: false, recommended_action: "Run switch first or finish rollback.")
      when "cleanup_failed_finalize_blocked"
        present("Finalize is blocked because cleanup failed earlier.", retryable: false, recommended_action: "Fix cleanup or force finalize only if you understand the situation.")
      when "cleanup_failed_after_rollback"
        present("Rollback can only be finalized after the cleanup failure is resolved.", retryable: false, recommended_action: "Retry cleanup on the inactive target or use force only if you intentionally skip cleanup.")
      when "no_queued_state_to_clear"
        present("There was no queued or running state to clear.", retryable: false)
      when "delete_partial_failure"
        present("The item was deleted, but not all storage cleanup steps completed successfully.", retryable: false, recommended_action: "Check the delete summary and logs for remaining assets.")
      else
        fallback_message = case operation.to_s
        when "copy" then "Copy failed."
        when "verify" then "Verify failed."
        when "switch" then "Switch failed."
        when "cleanup" then "Cleanup failed."
        when "rollback" then "Rollback failed."
        when "finalize" then "Finalize failed."
        when "delete" then "Delete failed."
        else "The action failed."
        end

        suffix = code.to_s.present? ? " (#{code})" : ""
        present("#{fallback_message}#{suffix}")
      end
    end
    private_class_method :map_error

    def present(message, retryable: true, recommended_action: nil)
      {
        message: message,
        retryable: retryable,
        recommended_action: recommended_action,
      }
    end
    private_class_method :present
  end
end
