# frozen_string_literal: true

module ::MediaGallery
  class MediaCommentSerializer < ::ApplicationSerializer
    attributes(
      :id,
      :body,
      :created_at,
      :updated_at,
      :comment_url,
      :mine,
      :can_delete,
      :user,
      :owner_comment,
      :staff_comment
    )

    def comment_url
      ::MediaGallery::CommentNotifications.comment_url_for(object.media_item, object)
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
  end
end
