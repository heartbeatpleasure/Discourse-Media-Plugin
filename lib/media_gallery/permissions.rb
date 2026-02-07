# frozen_string_literal: true

module ::MediaGallery
  module Permissions
    module_function

    def enabled?
      SiteSetting.media_gallery_enabled
    end

    def list_setting(value)
      return value if value.is_a?(Array)
      value.to_s.split("|").map(&:strip).reject(&:blank?)
    end

    def viewer_groups
      list_setting(SiteSetting.media_gallery_viewer_groups)
    end

    def uploader_groups
      list_setting(SiteSetting.media_gallery_allowed_uploader_groups)
    end

    def allowed_tags
      list_setting(SiteSetting.media_gallery_allowed_tags)
    end

    # Members-only: always requires a logged-in user.
    def can_view?(guardian)
      return false unless enabled?
      return false if guardian.nil? || guardian.user.nil?

      groups = viewer_groups
      return true if groups.blank?

      groups.any? { |g| guardian.user.groups.exists?(name: g) }
    end

    def can_upload?(guardian)
      return false unless enabled?
      return false if guardian.nil? || guardian.user.nil?

      return true if guardian.is_admin? || guardian.is_staff?
      return true if uploader_groups.blank?

      uploader_groups.any? { |g| guardian.user.groups.exists?(name: g) }
    end
  end
end
