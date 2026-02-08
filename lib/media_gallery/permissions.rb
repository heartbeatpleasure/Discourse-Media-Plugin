# frozen_string_literal: true

module ::MediaGallery
  module Permissions
    module_function

    def enabled?
      SiteSetting.media_gallery_enabled
    end

    # Discourse list site settings may come back as a String ("a|b") or an Array.
    # We also accept commas/newlines because it's easy to paste values like "mp4,webm".
    def list_setting(value)
      return value.map { |v| v.to_s.strip }.reject(&:blank?) if value.is_a?(Array)

      value
        .to_s
        .split(/[|,\n]/)
        .map { |v| v.to_s.strip }
        .reject(&:blank?)
    end

    def viewer_groups
      list_setting(SiteSetting.media_gallery_viewer_groups).map(&:downcase)
    end

    def uploader_groups
      list_setting(SiteSetting.media_gallery_allowed_uploader_groups).map(&:downcase)
    end

    def allowed_tags
      list_setting(SiteSetting.media_gallery_allowed_tags).map(&:downcase)
    end

    # Members-only: always requires a logged-in user.
    def can_view?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?

      groups = viewer_groups
      return true if groups.blank?

      user.groups.where("lower(name) IN (?)", groups).exists?
    end

    def can_upload?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?

      # Avoid relying on Guardian internal helper methods that may change across Discourse versions.
      return true if user.admin? || user.staff?

      groups = uploader_groups
      return true if groups.blank?

      user.groups.where("lower(name) IN (?)", groups).exists?
    end
  end
end
