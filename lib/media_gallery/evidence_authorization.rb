# frozen_string_literal: true

module ::MediaGallery
  module EvidenceAuthorization
    module_function

    CAPABILITY_SETTINGS = {
      case_operator: :media_gallery_evidence_case_operator_groups,
      technical_reviewer: :media_gallery_evidence_technical_reviewer_groups,
      senior_reviewer: :media_gallery_evidence_senior_reviewer_groups,
      restricted_approver: :media_gallery_evidence_restricted_approver_groups,
      policy_administrator: :media_gallery_evidence_policy_administrator_groups,
    }.freeze

    def allowed?(user, capability)
      return false if user.blank?

      key = capability.to_sym
      return false unless CAPABILITY_SETTINGS.key?(key)

      # Restricted identity data is intentionally opt-in. Even administrators must be
      # placed in an explicitly configured group before they can view or export it.
      return explicit_group_member?(user, key) if key == :restricted_approver

      return true if user.admin?

      explicit_group_member?(user, key)
    rescue
      false
    end

    def ensure!(user, capability)
      raise Discourse::InvalidAccess.new unless allowed?(user, capability)
    end

    def review_capability(review_kind)
      case review_kind.to_s
      when "technical" then :technical_reviewer
      when "senior" then :senior_reviewer
      when "privacy" then :restricted_approver
      else :case_operator
      end
    end

    def capabilities(user)
      CAPABILITY_SETTINGS.keys.index_with { |key| allowed?(user, key) }
    end

    def configured_groups(capability)
      setting = CAPABILITY_SETTINGS[capability.to_sym]
      return [] if setting.blank? || !SiteSetting.respond_to?(setting)

      ::MediaGallery::Permissions.list_setting(SiteSetting.public_send(setting)).map(&:downcase).uniq
    rescue
      []
    end

    def explicit_group_member?(user, capability)
      groups = configured_groups(capability)
      return false if groups.empty?

      ::MediaGallery::Permissions.user_in_any_group?(user, groups)
    end
    private_class_method :explicit_group_member?
  end
end
