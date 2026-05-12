# frozen_string_literal: true

require "cgi"

module ::MediaGallery
  module CommentNotifications
    FALLBACK_DEEP_LINK_PATH = "/media-library"
    COMMENT_EXCERPT_LENGTH = 500

    module_function

    def deep_link_path
      configured = if SiteSetting.respond_to?(:media_gallery_comments_deep_link_path)
        SiteSetting.media_gallery_comments_deep_link_path.to_s
      else
        ""
      end

      path = configured.strip.presence || FALLBACK_DEEP_LINK_PATH
      return FALLBACK_DEEP_LINK_PATH unless safe_deep_link_path?(path)

      normalized = path.sub(%r{/+\z}, "")
      normalized.presence || FALLBACK_DEEP_LINK_PATH
    end

    def comment_path_for(item, comment)
      public_id = item&.public_id.to_s
      comment_id = comment&.id.to_i
      query = "media=#{CGI.escape(public_id)}"
      query += "&comment=#{comment_id}" if comment_id.positive?
      "#{deep_link_path}?#{query}"
    end

    def comment_url_for(item, comment)
      base_url = Discourse.respond_to?(:base_url) ? Discourse.base_url.to_s : ""
      "#{base_url}#{comment_path_for(item, comment)}"
    rescue
      comment_path_for(item, comment)
    end

    def notify_owner(item, comment)
      return unless SiteSetting.respond_to?(:media_gallery_comments_notify_owner) && SiteSetting.media_gallery_comments_notify_owner
      return if item.blank? || comment.blank?
      return if item.user.blank?
      return if item.user_id.to_i == comment.user_id.to_i

      commenter = comment.user
      title = notification_title(item)
      raw = notification_body(item, comment, commenter)

      ::PostCreator.create!(
        Discourse.system_user,
        target_usernames: item.user.username,
        archetype: Archetype.private_message,
        title: title.truncate(200),
        raw: raw
      )
    rescue => e
      Rails.logger.warn("[media_gallery] comment notification failed item_id=#{item&.id} comment_id=#{comment&.id}: #{e.class}: #{e.message}")
    end

    def notification_title(item)
      media_title = item&.title.to_s.presence || item&.public_id.to_s.presence || "media"
      "New comment on your media: #{media_title}"
    end

    def notification_body(item, comment, commenter)
      media_title = item&.title.to_s.presence || "Untitled media"
      commenter_username = commenter&.username.to_s.presence || "A user"
      comment_excerpt = comment&.body.to_s.truncate(COMMENT_EXCERPT_LENGTH)
      media_url = comment_url_for(item, comment)

      <<~MD
        #{commenter_username} commented on your media item.

        **Media:** #{media_title}
        **Commenter:** @#{commenter_username}

        > #{comment_excerpt.gsub("\n", "\n> ")}

        [View the comment](#{media_url})
      MD
    end

    def safe_deep_link_path?(path)
      return false if path.blank?
      return false unless path.start_with?("/")
      return false if path.start_with?("//")
      return false if path.match?(/[\u0000-\u001f\u007f]/)
      return false if path.include?("?") || path.include?("#")

      true
    end
  end
end
