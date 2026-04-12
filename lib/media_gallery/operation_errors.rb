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
        present("No media-item was geselecteerd.", retryable: false)
      when "item_not_ready"
        present("Dit item is nog niet ready. Alleen ready items kunnen deze actie uitvoeren.")
      when "migration_plan_missing"
        present("Er kon geen geldig migratieplan voor dit item worden opgebouwd.", recommended_action: "Refresh het item en probeer opnieuw.")
      when "target_profile_not_configured"
        present("Het doelprofiel is niet geconfigureerd of niet beschikbaar.", retryable: false, recommended_action: "Controleer de storage settings en run een probe.")
      when "source_and_target_same_profile"
        present("Bron en doel gebruiken hetzelfde storageprofiel. Kies een ander doelprofiel.", retryable: false)
      when "source_and_target_same_location"
        present("Bron en doel wijzen naar dezelfde storage-locatie. Migreren zou niets veranderen.", retryable: false)
      when "copy_already_in_progress"
        present("Er draait al een copy voor dit item.", recommended_action: "Wacht tot copy klaar is of clear de queued state als het vastgelopen is.")
      when "cleanup_already_in_progress"
        present("Er draait al een cleanup voor dit item.", recommended_action: "Wacht tot cleanup klaar is of clear de queued state als het vastgelopen is.")
      when "cleanup_already_finalized"
        present("Deze migratiecyclus is al gefinalized. Cleanup kan alleen nog met force.", retryable: false)
      when "previous_cycle_cleanup_pending"
        present("De vorige migratiecyclus heeft nog een open cleanup/finalize-stap.", retryable: false, recommended_action: "Rond eerst cleanup/finalize af of gebruik force als je zeker weet waarom.")
      when "previous_cycle_not_finalized"
        present("De vorige migratiecyclus is nog niet afgerond.", retryable: false, recommended_action: "Finalize de huidige cyclus of gebruik force als je bewust een nieuwe cyclus wilt starten.")
      when "target_not_fully_copied"
        present("Het doel is nog niet compleet gekopieerd. Switch is daarom geblokkeerd.", recommended_action: "Run eerst copy en verify.")
      when "cleanup_target_incomplete"
        present("Cleanup is geblokkeerd omdat het actieve doel nog niet compleet is.", recommended_action: "Run verify op het actieve doel voordat je cleanup doet.")
      when "cleanup_remaining_source_objects"
        present("Cleanup heeft niet alle bronobjecten kunnen opruimen.", recommended_action: "Controleer de delete-resultaten en retry cleanup als dat veilig is.")
      when "cleanup_source_profile_changed_since_switch"
        present("Cleanup is gestopt omdat het bronprofiel sinds de switch is veranderd.", retryable: false, recommended_action: "Controleer de storageconfiguratie voordat je verdergaat.")
      when "cleanup_target_profile_changed_since_switch"
        present("Cleanup is gestopt omdat het actieve doelprofiel sinds de switch is veranderd.", retryable: false, recommended_action: "Controleer de storageconfiguratie voordat je verdergaat.")
      when "switch_state_missing"
        present("Er is nog geen switch-state voor dit item.", retryable: false, recommended_action: "Voer eerst copy en switch uit.")
      when "rollback_source_missing"
        present("Rollback is geblokkeerd omdat het oorspronkelijke bronobject ontbreekt#{detail.present? ? ": #{detail}" : "."}", retryable: false)
      when "rollback_not_available"
        present("Rollback is op dit moment niet beschikbaar voor deze state.", retryable: false)
      when "rollback_not_available_after_finalize"
        present("Rollback is geblokkeerd omdat deze migratiecyclus al gefinalized is.", retryable: false, recommended_action: "Start een nieuwe migratiecyclus als je opnieuw wilt wisselen.")
      when "already_on_source_profile"
        present("Het item staat al terug op het bronprofiel.", retryable: false)
      when "copy_verification_incomplete"
        present("Copy is afgerond, maar het doel mist nog objecten#{detail.present? ? ": #{detail}" : "."}", recommended_action: "Run verify en controleer de ontbrekende objecten voordat je switched.")
      when "source_object_missing"
        present("Een bronobject ontbreekt#{detail.present? ? ": #{detail}" : "."}", recommended_action: "Controleer source storage en probeer copy opnieuw.")
      when "verify_store_missing"
        present("Verify kon geen bron- of doelstore openen.", recommended_action: "Controleer de storage health/probe.")
      when "finalize_not_available"
        present("Finalize is nog niet beschikbaar voor deze cyclus.", retryable: false, recommended_action: "Voer eerst switch uit of rond rollback af.")
      when "cleanup_failed_finalize_blocked"
        present("Finalize is geblokkeerd omdat cleanup eerder faalde.", retryable: false, recommended_action: "Herstel cleanup of force finalize alleen als je de situatie begrijpt.")
      when "cleanup_failed_after_rollback"
        present("Rollback kan pas gefinalized worden nadat de cleanup-fout is opgelost.", retryable: false, recommended_action: "Retry cleanup op het inactieve target of gebruik force als je bewust afziet van cleanup.")
      when "no_queued_state_to_clear"
        present("Er was geen queued of running state om te clearen.", retryable: false)
      when "delete_partial_failure"
        present("Het item is verwijderd, maar niet alle storage cleanup-stappen zijn gelukt.", retryable: false, recommended_action: "Controleer de delete summary en logs voor resterende assets.")
      else
        fallback_message = case operation.to_s
        when "copy" then "Copy is mislukt."
        when "verify" then "Verify is mislukt."
        when "switch" then "Switch is mislukt."
        when "cleanup" then "Cleanup is mislukt."
        when "rollback" then "Rollback is mislukt."
        when "finalize" then "Finalize is mislukt."
        when "delete" then "Delete is mislukt."
        else "De actie is mislukt."
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
