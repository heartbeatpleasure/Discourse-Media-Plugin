# frozen_string_literal: true

module ::MediaGallery
  module Permissions
    module_function

    def enabled?
      SiteSetting.media_gallery_enabled
    end

    def public_view?
      SiteSetting.media_gallery_public_view
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

    def can_view?(guardian)
      return false unless enabled?
      return false if guardian.nil?

      groups = viewer_groups

      if public_view?
        # Public view means anonymous is allowed ONLY if no groups are specified.
        return true if groups.blank?
        return false if guardian.user.nil?
        return groups.any? { |g| guardian.user.groups.exists?(name: g) }
      end

      # Not public: require a logged-in user.
      return false if guardian.user.nil?
      return true if groups.blank?

      groups.any? { |g| guardian.user.groups.exists?(name: g) }
    end

    def can_upload?(guardian)
      return false unless enabled?
      return false if guardian.nil? || guardian.user.nil?

      return true if guardian.is_admin?
      return true if uploader_groups.blank?

      uploader_groups.any? { |g| guardian.user.groups.exists?(name: g) }
    end
  end
end
