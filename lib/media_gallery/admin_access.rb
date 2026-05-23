# frozen_string_literal: true

module ::MediaGallery
  module AdminAccess
    PAGE_SETTINGS = {
      management: :media_gallery_staff_access_management_enabled,
      reports: :media_gallery_staff_access_reports_enabled,
      statistics: :media_gallery_staff_access_statistics_enabled,
      user_diagnostics: :media_gallery_staff_access_user_diagnostics_enabled,
      logs: :media_gallery_staff_access_logs_enabled,
      forensics_identify: :media_gallery_staff_access_forensics_identify_enabled,
    }.freeze

    ADMIN_ONLY_PAGE_KEY = :admin_only

    module_function

    def valid_page_key?(page_key)
      PAGE_SETTINGS.key?(normalize_page_key(page_key))
    end

    def normalize_page_key(page_key)
      page_key.to_s.strip.tr("-", "_").to_sym
    end

    def setting_name_for(page_key)
      PAGE_SETTINGS[normalize_page_key(page_key)]
    end

    def enabled?
      SiteSetting.respond_to?(:media_gallery_enabled) && SiteSetting.media_gallery_enabled
    rescue
      false
    end

    def setting_enabled?(page_key)
      setting_name = setting_name_for(page_key)
      return false if setting_name.blank?
      return false unless SiteSetting.respond_to?(setting_name)

      !!SiteSetting.public_send(setting_name)
    rescue
      false
    end

    def user_from_guardian(guardian)
      return nil if guardian.blank?

      guardian.respond_to?(:user) ? guardian.user : nil
    rescue
      nil
    end

    def user_from_request(request)
      request&.env&.dig("warden")&.user
    rescue
      nil
    end

    def can_access?(page_key, user: nil, guardian: nil)
      user ||= user_from_guardian(guardian)
      return false if user.blank?
      return true if user.admin?
      return false unless enabled?
      return false unless user.staff?

      setting_enabled?(page_key)
    end

    def any_staff_access_enabled?
      enabled? && PAGE_SETTINGS.keys.any? { |page_key| setting_enabled?(page_key) }
    rescue
      false
    end

    def can_access_landing?(user)
      return false if user.blank?
      return true if user.admin?
      return false unless enabled?
      return false unless user.staff?

      any_staff_access_enabled?
    rescue
      false
    end

    def landing_permissions_for(user)
      is_admin = user.present? && user.admin?

      {
        openSettings: is_admin,
        settingsGuide: is_admin,
        management: can_access?(:management, user: user),
        reports: can_access?(:reports, user: user),
        health: is_admin,
        statistics: can_access?(:statistics, user: user),
        security: is_admin,
        userDiagnostics: can_access?(:user_diagnostics, user: user),
        logs: can_access?(:logs, user: user),
        forensicsIdentify: can_access?(:forensics_identify, user: user),
        forensicsExports: is_admin,
        testDownloads: is_admin,
        jobs: is_admin,
        migrations: is_admin,
      }
    end

    def landing_access_payload(user)
      can = landing_permissions_for(user)

      {
        isAdmin: user.present? && user.admin?,
        isStaff: user.present? && user.staff?,
        can: can,
        hasVisibleCards: can.values.any?,
      }
    end

    def ensure_landing_access!(user)
      raise Discourse::InvalidAccess.new unless can_access_landing?(user)
    end

    def ensure_page_access!(page_key, guardian)
      raise Discourse::InvalidAccess.new unless can_access?(page_key, guardian: guardian)
    end

    module ControllerMethods
      def self.included(base)
        base.before_action :ensure_media_gallery_admin_page_access
      end

      private

      # Admin::AdminController calls ensure_admin as part of its normal guard.
      # Override it so admins keep the existing behavior while staff can be
      # allowed only for explicitly configured Media Gallery admin pages.
      def ensure_admin
        ensure_media_gallery_admin_page_access
      end

      def ensure_media_gallery_admin_page_access
        ::MediaGallery::AdminAccess.ensure_page_access!(media_gallery_admin_page_key, guardian)
      end

      def media_gallery_admin_page_key
        self.class.const_defined?(:MEDIA_GALLERY_ADMIN_PAGE_KEY) ? self.class.const_get(:MEDIA_GALLERY_ADMIN_PAGE_KEY) : ::MediaGallery::AdminAccess::ADMIN_ONLY_PAGE_KEY
      end
    end

    module ActionScopedControllerMethods
      def self.included(base)
        base.before_action :ensure_media_gallery_admin_page_access
      end

      private

      # See ControllerMethods#ensure_admin.
      def ensure_admin
        ensure_media_gallery_admin_page_access
      end

      def ensure_media_gallery_admin_page_access
        page_key = media_gallery_admin_page_key_for_action
        raise Discourse::InvalidAccess.new if page_key.blank?

        ::MediaGallery::AdminAccess.ensure_page_access!(page_key, guardian)
      end

      def media_gallery_admin_page_key_for_action
        action = action_name.to_s
        self.class::MEDIA_GALLERY_ADMIN_ACTION_PAGES.each do |page_key, actions|
          return page_key if Array(actions).map(&:to_s).include?(action)
        end

        ::MediaGallery::AdminAccess::ADMIN_ONLY_PAGE_KEY
      rescue
        ::MediaGallery::AdminAccess::ADMIN_ONLY_PAGE_KEY
      end
    end
  end

  class AdminPageConstraint
    def initialize(page_key)
      @page_key = ::MediaGallery::AdminAccess.normalize_page_key(page_key)
    end

    def matches?(request)
      user = ::MediaGallery::AdminAccess.user_from_request(request)
      ::MediaGallery::AdminAccess.can_access?(@page_key, user: user)
    end
  end

  class AnyStaffAdminPageConstraint
    def matches?(request)
      user = ::MediaGallery::AdminAccess.user_from_request(request)
      ::MediaGallery::AdminAccess.can_access_landing?(user)
    end
  end
end
