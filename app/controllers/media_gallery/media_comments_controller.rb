# frozen_string_literal: true

module ::MediaGallery
  class MediaCommentsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in
    before_action :ensure_comments_enabled
    before_action :ensure_can_view
    before_action :ensure_secure_write_request!, only: [:create, :destroy]

    def index
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      page_size = comments_page_size
      scope = item.media_comments.visible.includes(:user).order(id: :desc)

      focus_comment_id = params[:comment_id].to_i
      focused_comment = nil
      comment_found = nil
      if focus_comment_id.positive?
        focused_comment = item.media_comments.visible.find_by(id: focus_comment_id)
        comment_found = focused_comment.present?
        scope = scope.where("id <= ?", focused_comment.id) if focused_comment.present?
      else
        before_id = params[:before_id].to_i
        scope = scope.where("id < ?", before_id) if before_id.positive?
      end

      rows = scope.limit(page_size + 1).to_a
      has_more_before = rows.length > page_size
      rows = rows.first(page_size)

      comments = rows.reverse

      render_json_dump(
        comments: serialize_data(comments, MediaGallery::MediaCommentSerializer, root: false),
        total: item.comments_count.to_i,
        has_more_before: has_more_before,
        next_before_id: has_more_before ? rows.last&.id : nil,
        comments_count: item.comments_count.to_i,
        focused_comment_id: focused_comment&.id,
        comment_found: comment_found
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comments index failed request_id=#{request.request_id} public_id=#{params[:public_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comments_failed", status: 500, message: "Comments could not be loaded.")
    end

    def create
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?
      return render_json_error("comments_forbidden", status: 403, message: "You are not allowed to comment on media.") unless can_comment?

      enforce_comment_rate_limit!

      body = sanitize_comment_body(params[:body])
      if body.blank?
        return render_json_error("comment_body_required", status: 422, message: "Comment cannot be empty.")
      end

      max_length = comment_max_length
      if body.length > max_length
        return render_json_error("comment_too_long", status: 422, message: "Comment is too long. Maximum is #{max_length} characters.")
      end

      comment = nil
      item.with_lock do
        comment = item.media_comments.create!(user_id: current_user.id, body: body, status: "visible")
        item.update_columns(
          comments_count: item.media_comments.visible.count,
          last_commented_at: comment.created_at,
          updated_at: Time.now
        )
      end

      item.reload
      ::MediaGallery::CommentNotifications.notify_owner(item, comment)
      log_comment_event("media_comment_created", item: item, comment: comment, severity: "info")

      render_json_dump(
        ok: true,
        comment: serialize_data(comment, MediaGallery::MediaCommentSerializer, root: false),
        comments_count: item.comments_count.to_i,
        last_commented_at: item.last_commented_at&.iso8601
      )
    rescue RateLimiter::LimitExceeded
      render_json_error("rate_limited", status: 429, message: "You are commenting too quickly. Please wait and try again.")
    rescue ActiveRecord::RecordInvalid => e
      render_json_error("validation_error", status: 422, message: e.record.errors.full_messages.join(", "))
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comments create failed request_id=#{request.request_id} public_id=#{params[:public_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_failed", status: 500, message: "Comment could not be posted.")
    end

    def destroy
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      comment = item.media_comments.visible.find_by(id: params[:comment_id].to_i)
      raise Discourse::NotFound if comment.blank?
      raise Discourse::NotFound unless can_delete_comment?(comment)

      item.with_lock do
        comment.update_columns(
          status: "deleted",
          deleted_at: Time.now.utc,
          deleted_by_id: current_user.id,
          updated_at: Time.now
        )
        last_visible_comment = item.media_comments.visible.order(id: :desc).first
        item.update_columns(
          comments_count: item.media_comments.visible.count,
          last_commented_at: last_visible_comment&.created_at,
          updated_at: Time.now
        )
      end

      item.reload
      log_comment_event("media_comment_deleted", item: item, comment: comment, severity: "info")

      render_json_dump(ok: true, comments_count: item.comments_count.to_i, last_commented_at: item.last_commented_at&.iso8601)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comments destroy failed request_id=#{request.request_id} public_id=#{params[:public_id]} comment_id=#{params[:comment_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_delete_failed", status: 500, message: "Comment could not be deleted.")
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_comments_enabled
      raise Discourse::NotFound unless SiteSetting.respond_to?(:media_gallery_comments_enabled) && SiteSetting.media_gallery_comments_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end

    def ensure_secure_write_request!
      return if ::MediaGallery::RequestSecurity.secure_write_request?(self)

      ::MediaGallery::OperationLogger.warn(
        "request_blocked",
        operation: action_name,
        item: nil,
        data: {
          reason: "csrf_or_same_origin_failed",
          origin: request.headers["Origin"].to_s.presence,
          referer: request.referer.to_s.presence,
          sec_fetch_site: request.headers["Sec-Fetch-Site"].to_s.presence,
          method: request.request_method
        }
      )
      render_json_error("forbidden", status: 403, message: "Forbidden")
    end

    def find_item_by_public_id!(public_id)
      item = MediaGallery::MediaItem.find_by(public_id: public_id.to_s)
      raise Discourse::NotFound if item.blank?
      item
    end

    def ensure_item_visible_to_current_user!(item)
      return if item.blank?
      return if !item.respond_to?(:admin_hidden?) || !item.admin_hidden?

      raise Discourse::NotFound
    end

    def can_comment?
      current_user.present? && current_user.trust_level.to_i >= SiteSetting.media_gallery_comments_min_trust_level.to_i
    end

    def can_delete_comment?(comment)
      return false if current_user.blank?
      current_user.staff? || current_user.admin? || comment.user_id == current_user.id
    end

    def comment_max_length
      value = SiteSetting.media_gallery_comments_max_length.to_i
      value.positive? ? [[value, 50].max, 5_000].min : 1_000
    end

    def comments_page_size
      value = SiteSetting.media_gallery_comments_page_size.to_i
      value = 20 if value <= 0
      [[value, 5].max, 100].min
    end

    def sanitize_comment_body(value)
      ::MediaGallery::TextSanitizer.plain_text(
        value,
        max_length: comment_max_length,
        allow_newlines: true
      ).to_s.strip
    end

    def enforce_comment_rate_limit!
      per_minute = SiteSetting.media_gallery_comments_per_minute.to_i
      return if per_minute <= 0

      RateLimiter.new(current_user, "media_gallery_comments_create_#{current_user.id}", per_minute, 1.minute).performed!
    end

    def log_comment_event(event_type, item:, comment:, severity: "info")
      ::MediaGallery::OperationLogger.info(
        event_type,
        item: item,
        operation: "comments",
        data: {
          comment_id: comment&.id,
          actor_id: current_user&.id,
          actor_username: current_user&.username
        }
      )

      if defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.respond_to?(:record)
        ::MediaGallery::LogEvents.record(
          event_type: event_type,
          severity: severity,
          category: "comments",
          request: request,
          user: current_user,
          media_item: item,
          message: "media_comment",
          details: { comment_id: comment&.id }
        )
      end
    rescue => e
      Rails.logger.warn("[media_gallery] comment audit failed item_id=#{item&.id} comment_id=#{comment&.id}: #{e.class}: #{e.message}")
    end
  end
end
