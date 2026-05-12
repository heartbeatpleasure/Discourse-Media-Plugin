# frozen_string_literal: true

module ::MediaGallery
  class MediaCommentSerializer < ::ApplicationSerializer
    attributes(
      :id,
      :body,
      :created_at,
      :updated_at,
      :comment_url,
      :likes_count,
      :liked,
      :liked_by_current_user,
      :can_like,
      :can_report,
      :reported_by_current_user,
      :mine,
      :can_delete,
      :user,
      :owner_comment,
      :staff_comment
    )

    def comment_url
      ::MediaGallery::CommentNotifications.comment_url_for(object.media_item, object)
    end

    def likes_count
      if object.respond_to?(:has_attribute?) && object.has_attribute?("likes_count")
        return object.likes_count.to_i
      end

      return object.likes_count.to_i if object.respond_to?(:likes_count)
      return 0 unless comment_like_table_available?

      ::MediaGallery::MediaCommentLike.where(media_comment_id: object.id).count
    rescue ActiveModel::MissingAttributeError, NoMethodError, ActiveRecord::StatementInvalid
      comment_like_table_available? ? ::MediaGallery::MediaCommentLike.where(media_comment_id: object.id).count : 0
    end

    def liked
      liked_by_current_user
    end

    def liked_by_current_user
      u = current_user
      return false if u.blank?
      return false unless comment_like_table_available?

      ::MediaGallery::MediaCommentLike.exists?(user_id: u.id, media_comment_id: object.id)
    rescue ActiveRecord::StatementInvalid, ActiveModel::MissingAttributeError
      false
    end

    def can_like
      u = current_user
      return false if u.blank?
      return false unless comment_likes_enabled?
      return false unless comment_like_table_available?

      u.trust_level.to_i >= comment_likes_min_trust_level
    end

    def can_report
      u = current_user
      return false if u.blank?
      return false if object.user_id.to_i == u.id.to_i
      return false unless comment_reports_enabled?
      return false unless comment_report_table_available?

      u.trust_level.to_i >= comment_reports_min_trust_level
    end

    def reported_by_current_user
      u = current_user
      return false if u.blank?
      return false unless comment_report_table_available?

      ::MediaGallery::MediaCommentReport.exists?(user_id: u.id, media_comment_id: object.id, status: "open")
    rescue ActiveRecord::StatementInvalid, ActiveModel::MissingAttributeError
      false
    end

    def mine
      current_user.present? && object.user_id == current_user.id
    end

    def can_delete
      return false if current_user.blank?
      current_user.staff? || current_user.admin? || object.user_id == current_user.id
    end

    def user
      u = object.user
      return nil if u.blank?

      {
        id: u.id,
        username: u.username,
        name: u.name.to_s.presence,
        avatar_template: u.avatar_template.to_s.presence,
        profile_url: "/u/#{u.username}"
      }.compact
    end

    def owner_comment
      object.media_item&.user_id.to_i == object.user_id.to_i
    end

    def staff_comment
      !!object.user&.staff?
    end

    private

    def current_user
      scope&.user
    end

    def comment_likes_enabled?
      SiteSetting.respond_to?(:media_gallery_comment_likes_enabled) && SiteSetting.media_gallery_comment_likes_enabled
    end

    def comment_likes_min_trust_level
      SiteSetting.respond_to?(:media_gallery_comment_likes_min_trust_level) ? SiteSetting.media_gallery_comment_likes_min_trust_level.to_i : 0
    end

    def comment_reports_enabled?
      SiteSetting.respond_to?(:media_gallery_comment_reports_enabled) && SiteSetting.media_gallery_comment_reports_enabled
    end

    def comment_reports_min_trust_level
      SiteSetting.respond_to?(:media_gallery_comment_reports_min_trust_level) ? SiteSetting.media_gallery_comment_reports_min_trust_level.to_i : 0
    end

    def comment_like_table_available?
      defined?(::MediaGallery::MediaCommentLike) && ::MediaGallery::MediaCommentLike.table_exists?
    rescue ActiveRecord::StatementInvalid, NoMethodError
      false
    end


    def comment_report_table_available?
      defined?(::MediaGallery::MediaCommentReport) && ::MediaGallery::MediaCommentReport.table_exists?
    rescue ActiveRecord::StatementInvalid, NoMethodError
      false
    end
  end
end
