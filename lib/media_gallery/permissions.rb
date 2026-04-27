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

    # View block groups deny both viewing and uploading.
    def quick_block_group
      list_setting(SiteSetting.media_gallery_quick_block_group).map(&:downcase)
    end

    def blocked_groups
      (list_setting(SiteSetting.media_gallery_blocked_groups) + quick_block_group).map(&:downcase).uniq
    end

    # Upload block groups deny uploading only. They do not deny viewing.
    def quick_upload_block_group
      list_setting(SiteSetting.media_gallery_quick_upload_block_group).map(&:downcase)
    end

    def upload_blocked_groups
      (list_setting(SiteSetting.media_gallery_upload_blocked_groups) + quick_upload_block_group).map(&:downcase).uniq
    end

    def allowed_tags
      MediaGallery::TextSanitizer.tag_list(
        list_setting(SiteSetting.media_gallery_allowed_tags),
        max_count: 500,
        max_length: 40
      )
    end

    def user_in_any_group?(user, groups)
      return false if user.nil? || groups.blank?

      user.groups.where("lower(name) IN (?)", groups).exists?
    end

    # A view block is an explicit staff/admin decision and takes precedence over
    # viewer/uploader groups for regular users. Staff/admin are kept unblocked so
    # they can always recover access and manage the setting.
    def access_blocked?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?
      return false if user.admin? || user.staff?

      user_in_any_group?(user, blocked_groups)
    end

    # Upload-only blocks do not affect viewing. A view block always implies upload
    # is denied too, but this helper only returns true for upload-specific groups.
    def upload_access_blocked?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?
      return false if user.admin? || user.staff?

      user_in_any_group?(user, upload_blocked_groups)
    end

    def upload_denied_by_block?(guardian)
      access_blocked?(guardian) || upload_access_blocked?(guardian)
    end

    # Members-only: always requires a logged-in user.
    def can_view?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?
      return false if access_blocked?(guardian)

      groups = viewer_groups
      return true if groups.blank?

      user_in_any_group?(user, groups)
    end

    def can_upload?(guardian)
      return false unless enabled?
      user = guardian&.user
      return false if user.nil?
      return false if access_blocked?(guardian)
      return false if upload_access_blocked?(guardian)

      # Avoid relying on Guardian internal helper methods that may change across Discourse versions.
      return true if user.admin? || user.staff?

      groups = uploader_groups
      return true if groups.blank?

      user_in_any_group?(user, groups)
    end
  end
end
