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
    before_action :ensure_secure_write_request!, only: [:create, :destroy, :like, :unlike, :report]

    def index
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      page_size = comments_page_size
      base_scope = item.media_comments.visible.includes(:user)
      actual_comments_count = item.media_comments.visible.count

      focus_comment_id = params[:comment_id].to_i
      focused_comment = nil
      comment_found = nil
      before_id = params[:before_id].to_i

      if before_id.positive?
        # Normal pagination: load comments older than the oldest comment the
        # client already has. Keep this path unchanged for the regular comment
        # tab and the "load earlier" button.
        rows = base_scope.where("id < ?", before_id).order(id: :desc).limit(page_size + 1).to_a
        has_more_before = rows.length > page_size
        rows = rows.first(page_size)
      else
        # Default/deeplink load: always start with the latest page. If a
        # specific comment is requested and it is not in the latest page, add it
        # to the response instead of replacing the whole list with only comments
        # older than that focused comment. This prevents old comment links from
        # making newer comments disappear from the preview.
        rows = base_scope.order(id: :desc).limit(page_size + 1).to_a
        rows = rows.first(page_size) if rows.length > page_size

        if focus_comment_id.positive?
          focused_comment = base_scope.find_by(id: focus_comment_id)
          comment_found = focused_comment.present?
          if focused_comment.present? && rows.none? { |row| row.id.to_i == focused_comment.id.to_i }
            rows << focused_comment
          end
        end

        oldest_id = rows.map { |row| row&.id }.compact.min
        has_more_before = oldest_id.present? && item.media_comments.visible.where("id < ?", oldest_id).exists?
      end

      comments = rows.compact.uniq { |row| row.id }.sort_by(&:id)

      render_json_dump(
        comments: serialize_data(comments, MediaGallery::MediaCommentSerializer, root: false),
        total: actual_comments_count,
        has_more_before: has_more_before,
        next_before_id: has_more_before ? comments.first&.id : nil,
        comments_count: actual_comments_count,
        focused_comment_id: focused_comment&.id,
        comment_found: comment_found
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comments index failed request_id=#{request.request_id} public_id=#{params[:public_id]} error=#{e.class}: #{e.message}
#{e.backtrace&.first(30)&.join("
")}")
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
        update_item_comment_counters!(item, last_comment: comment)
      end

      item.reload
      ::MediaGallery::CommentNotifications.notify_owner(item, comment)
      log_comment_event("media_comment_created", item: item, comment: comment, severity: "info")

      render_json_dump(
        ok: true,
        comment: serialize_data(comment, MediaGallery::MediaCommentSerializer, root: false),
        comments_count: comments_count_for(item),
        last_commented_at: last_commented_at_for(item)&.iso8601
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
        update_item_comment_counters!(item, last_comment: last_visible_comment)
      end

      item.reload
      log_comment_event("media_comment_deleted", item: item, comment: comment, severity: "info")

      render_json_dump(ok: true, comments_count: comments_count_for(item), last_commented_at: last_commented_at_for(item)&.iso8601)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comments destroy failed request_id=#{request.request_id} public_id=#{params[:public_id]} comment_id=#{params[:comment_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_delete_failed", status: 500, message: "Comment could not be deleted.")
    end

    def like
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      comment = find_visible_comment!(item)
      return render_json_error("comment_likes_forbidden", status: 403, message: "You are not allowed to like comments.") unless can_like_comment?

      comment.with_lock do
        existing = ::MediaGallery::MediaCommentLike.find_by(media_comment_id: comment.id, user_id: current_user.id)
        if existing.blank?
          ::MediaGallery::MediaCommentLike.create!(
            media_item_id: item.id,
            media_comment_id: comment.id,
            user_id: current_user.id
          )
          update_comment_like_counter!(comment)
        end
      end

      comment.reload
      log_comment_event("media_comment_liked", item: item, comment: comment, severity: "info")
      render_json_dump(ok: true, liked: true, likes_count: comment_likes_count_for(comment))
    rescue ActiveRecord::RecordNotUnique
      comment = find_visible_comment!(find_item_by_public_id!(params[:public_id]))
      render_json_dump(ok: true, liked: true, likes_count: comment_likes_count_for(comment))
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comment like failed request_id=#{request.request_id} public_id=#{params[:public_id]} comment_id=#{params[:comment_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_like_failed", status: 500, message: "Comment like could not be updated.")
    end

    def unlike
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      comment = find_visible_comment!(item)
      return render_json_error("comment_likes_forbidden", status: 403, message: "You are not allowed to like comments.") unless can_like_comment?

      comment.with_lock do
        existing = ::MediaGallery::MediaCommentLike.find_by(media_comment_id: comment.id, user_id: current_user.id)
        if existing.present?
          existing.destroy!
          update_comment_like_counter!(comment)
        end
      end

      comment.reload
      log_comment_event("media_comment_unliked", item: item, comment: comment, severity: "info")
      render_json_dump(ok: true, liked: false, likes_count: comment_likes_count_for(comment))
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comment unlike failed request_id=#{request.request_id} public_id=#{params[:public_id]} comment_id=#{params[:comment_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_like_failed", status: 500, message: "Comment like could not be updated.")
    end

    def report
      item = find_item_by_public_id!(params[:public_id])
      ensure_item_visible_to_current_user!(item)
      raise Discourse::NotFound unless item.ready?

      comment = find_visible_comment!(item)
      return render_json_error("comment_reports_disabled", status: 404, message: "Comment reports are not enabled.") unless comment_reports_enabled?
      return render_json_error("comment_reports_unavailable", status: 503, message: "Comment reports are not available yet. Please try again after the site has finished migrating.") unless comment_report_table_available?
      return render_json_error("comment_reports_forbidden", status: 403, message: "You are not allowed to report this comment.") unless can_report_comment?(comment)

      reason = normalize_comment_report_reason(params[:reason])
      return render_json_error("invalid_comment_report_reason", status: 422, message: "Please choose a report reason.") if reason.blank?

      message = sanitize_comment_report_message(params[:message]).presence

      result = create_comment_report!(item, comment, reason: reason, message: message)

      render_json_dump(
        ok: true,
        duplicate: result[:duplicate],
        report: result[:report],
        message: result[:duplicate] ? "You already reported this comment. Staff can review your existing report." : "Comment report submitted. Staff will review it."
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] comment report failed request_id=#{request.request_id} public_id=#{params[:public_id]} comment_id=#{params[:comment_id]} error=#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}")
      render_json_error("comment_report_failed", status: 500, message: "Comment report failed. Please try again.")
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

    def can_like_comment?
      return false if current_user.blank?
      return false unless SiteSetting.respond_to?(:media_gallery_comment_likes_enabled) && SiteSetting.media_gallery_comment_likes_enabled
      return false unless comment_like_table_available?

      current_user.trust_level.to_i >= comment_likes_min_trust_level
    end

    def comment_likes_min_trust_level
      SiteSetting.respond_to?(:media_gallery_comment_likes_min_trust_level) ? SiteSetting.media_gallery_comment_likes_min_trust_level.to_i : 0
    end

    def comment_reports_enabled?
      SiteSetting.respond_to?(:media_gallery_comment_reports_enabled) && SiteSetting.media_gallery_comment_reports_enabled
    end

    def can_report_comment?(comment)
      return false if current_user.blank?
      return false if comment.blank?
      return false unless comment_reports_enabled?
      return false if comment.user_id.to_i == current_user.id.to_i

      current_user.trust_level.to_i >= comment_reports_min_trust_level
    end

    def comment_reports_min_trust_level
      SiteSetting.respond_to?(:media_gallery_comment_reports_min_trust_level) ? SiteSetting.media_gallery_comment_reports_min_trust_level.to_i : 0
    end

    def comment_report_reason_options
      [
        { id: "harassment", label: "Harassment or abuse" },
        { id: "personal_info", label: "Personal or private information" },
        { id: "illegal", label: "Illegal or prohibited content" },
        { id: "spam", label: "Spam or unwanted content" },
        { id: "rule_violation", label: "Comment guideline violation" },
        { id: "other", label: "Other" },
      ]
    end

    def normalize_comment_report_reason(value)
      reason = ::MediaGallery::TextSanitizer.plain_text(value, max_length: 40, allow_newlines: false).to_s.strip
      comment_report_reason_options.any? { |entry| entry[:id] == reason } ? reason : nil
    end

    def sanitize_comment_report_message(value)
      ::MediaGallery::TextSanitizer.plain_text(value, max_length: 1200, allow_newlines: true).to_s.strip
    end

    def create_comment_report!(item, comment, reason:, message: nil)
      duplicate = false
      report_payload = nil
      report = nil

      comment.with_lock do
        report = ::MediaGallery::MediaCommentReport.where(
          media_comment_id: comment.id,
          user_id: current_user.id,
          status: "open"
        ).first

        if report.present?
          duplicate = true
        else
          report = ::MediaGallery::MediaCommentReport.create!(
            media_item_id: item.id,
            media_comment_id: comment.id,
            comment_user_id: comment.user_id,
            user_id: current_user.id,
            reason: reason,
            message: message,
            status: "open",
            snapshot: comment_report_snapshot(item, comment, reason: reason)
          )
          update_comment_report_counter!(comment)
        end

        report_payload = public_comment_report_payload(report)
      end

      if duplicate
        ::MediaGallery::OperationLogger.info("media_comment_report_duplicate_ignored", item: item, operation: "comment_report", data: { comment_id: comment.id, reporter_user_id: current_user.id, reporter_username: current_user.username })
      else
        ::MediaGallery::OperationLogger.warn("media_comment_report_created", item: item, operation: "comment_report", data: { comment_id: comment.id, comment_user_id: comment.user_id, reporter_user_id: current_user.id, reporter_username: current_user.username, reason: reason })
        log_comment_report_event(item: item, comment: comment, report: report, reason: reason)
        notify_comment_report_group(item, comment, report: report, reason: reason)
      end

      { duplicate: duplicate, report: report_payload }
    end

    def comment_report_snapshot(item, comment, reason:)
      {
        "media_item_id" => item.id,
        "public_id" => item.public_id.to_s,
        "title" => item.title.to_s.presence,
        "media_type" => item.media_type.to_s.presence,
        "comment_id" => comment.id,
        "comment_body" => comment.body.to_s.truncate(1000),
        "comment_created_at" => comment.created_at&.iso8601,
        "comment_user_id" => comment.user_id,
        "comment_username" => comment.user&.username.to_s.presence,
        "reporter_user_id" => current_user.id,
        "reporter_username" => current_user.username,
        "reporter_trust_level" => current_user.trust_level.to_i,
        "reporter_staff" => current_user.staff?,
        "reason" => reason,
        "reason_label" => comment_report_reason_options.find { |entry| entry[:id] == reason }&.dig(:label).to_s.presence || reason.to_s,
      }.compact
    rescue => e
      Rails.logger.warn("[media_gallery] comment report snapshot failed item_id=#{item&.id} comment_id=#{comment&.id}: #{e.class}: #{e.message}")
      {
        "media_item_id" => item&.id,
        "public_id" => item&.public_id.to_s,
        "comment_id" => comment&.id,
      }.compact
    end

    def public_comment_report_payload(report)
      return {} if report.blank?

      {
        id: report.id,
        status: report.status.to_s,
        reason: report.reason.to_s,
        reason_label: comment_report_reason_options.find { |entry| entry[:id] == report.reason.to_s }&.dig(:label).to_s.presence || report.reason.to_s,
        created_at: report.created_at&.iso8601,
      }.compact
    end

    def notify_comment_report_group(item, comment, report:, reason:)
      group_names = comment_report_notify_group_names
      return if group_names.blank?

      comment_url = ::MediaGallery::CommentNotifications.comment_url_for(item, comment)
      reason_label = comment_report_reason_options.find { |entry| entry[:id] == reason }&.dig(:label).to_s.presence || reason.to_s
      title = "Comment report: #{item.title.to_s.presence || item.public_id}"
      raw = <<~MD
        A media comment has been reported and needs staff review.

        Media: #{item.title.to_s.presence || "Untitled media"}
        Public ID: #{item.public_id}
        Comment ID: #{comment.id}
        Comment author: #{comment.user&.username || "unknown"}
        Reporter: #{current_user.username}
        Reason: #{reason_label}
        Report ID: #{report&.id}

        Comment:
        #{comment.body.to_s.truncate(1200)}

        View the comment: #{comment_url}
      MD

      ::PostCreator.create!(
        Discourse.system_user,
        target_group_names: group_names,
        archetype: Archetype.private_message,
        title: title.truncate(200),
        raw: raw
      )
    rescue => e
      Rails.logger.warn("[media_gallery] comment report notification failed item_id=#{item&.id} comment_id=#{comment&.id} groups=#{defined?(group_names) ? group_names.inspect : 'unknown'}: #{e.class}: #{e.message}")
    end

    def comment_report_notify_group_names
      raw = if SiteSetting.respond_to?(:media_gallery_comment_reports_notify_group)
        SiteSetting.media_gallery_comment_reports_notify_group
      else
        SiteSetting.respond_to?(:media_gallery_report_notify_group) ? SiteSetting.media_gallery_report_notify_group : "staff"
      end

      ::MediaGallery::Permissions
        .list_setting(raw)
        .map { |name| ::MediaGallery::TextSanitizer.plain_text(name, max_length: 100, allow_newlines: false).to_s.strip }
        .reject(&:blank?)
        .uniq
    end

    def log_comment_report_event(item:, comment:, report:, reason:)
      return unless defined?(::MediaGallery::LogEvents) && ::MediaGallery::LogEvents.respond_to?(:record)

      ::MediaGallery::LogEvents.record(
        event_type: "media_comment_report_created",
        severity: "warning",
        category: "comment_reports",
        request: request,
        user: current_user,
        media_item: item,
        message: reason,
        details: { comment_id: comment&.id, comment_user_id: comment&.user_id, report_id: report&.id, reason: reason }
      )
    rescue => e
      Rails.logger.warn("[media_gallery] comment report audit failed item_id=#{item&.id} comment_id=#{comment&.id}: #{e.class}: #{e.message}")
    end

    def find_visible_comment!(item)
      comment = item.media_comments.visible.find_by(id: params[:comment_id].to_i)
      raise Discourse::NotFound if comment.blank?
      comment
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

    def comments_count_for(item)
      actual_count = item.media_comments.visible.count

      if media_item_column_available?("comments_count") && item.respond_to?(:comments_count)
        stored_count = item.comments_count.to_i
        if stored_count != actual_count
          begin
            item.update_columns(comments_count: actual_count, updated_at: Time.now)
            item.comments_count = actual_count if item.respond_to?(:comments_count=)
          rescue => e
            Rails.logger.warn("[media_gallery] comments_count self-heal failed item_id=#{item&.id}: #{e.class}: #{e.message}")
          end
        end
      end

      actual_count
    rescue ActiveModel::MissingAttributeError, NoMethodError, ActiveRecord::StatementInvalid
      item.media_comments.visible.count
    end

    def last_commented_at_for(item)
      if media_item_column_available?("last_commented_at")
        return item.last_commented_at
      end

      item.media_comments.visible.order(id: :desc).pick(:created_at)
    rescue ActiveModel::MissingAttributeError, NoMethodError
      item.media_comments.visible.order(id: :desc).pick(:created_at)
    end

    def comment_likes_count_for(comment)
      if media_comment_column_available?("likes_count")
        return comment.likes_count.to_i
      end

      return 0 unless comment_like_table_available?

      ::MediaGallery::MediaCommentLike.where(media_comment_id: comment.id).count
    rescue ActiveModel::MissingAttributeError, NoMethodError, ActiveRecord::StatementInvalid
      comment_like_table_available? ? ::MediaGallery::MediaCommentLike.where(media_comment_id: comment.id).count : 0
    end

    def update_comment_like_counter!(comment)
      return unless media_comment_column_available?("likes_count")

      comment.update_columns(likes_count: ::MediaGallery::MediaCommentLike.where(media_comment_id: comment.id).count, updated_at: Time.now)
    end

    def update_comment_report_counter!(comment)
      return unless media_comment_column_available?("reports_count")

      count = comment_report_table_available? ? ::MediaGallery::MediaCommentReport.where(media_comment_id: comment.id, status: "open").count : 0
      comment.update_columns(reports_count: count, updated_at: Time.now)
    rescue ActiveRecord::StatementInvalid, ActiveModel::MissingAttributeError, NoMethodError => e
      Rails.logger.warn("[media_gallery] media comment report counter update failed comment_id=#{comment&.id}: #{e.class}: #{e.message}")
    end

    def update_item_comment_counters!(item, last_comment:)
      updates = { updated_at: Time.now }
      updates[:comments_count] = item.media_comments.visible.count if media_item_column_available?("comments_count")
      updates[:last_commented_at] = last_comment&.created_at if media_item_column_available?("last_commented_at")

      item.update_columns(updates) if updates.present?
    end

    def media_item_column_available?(column_name)
      MediaGallery::MediaItem.columns_hash.key?(column_name.to_s)
    rescue => e
      Rails.logger.warn("[media_gallery] media item column check failed column=#{column_name}: #{e.class}: #{e.message}")
      false
    end

    def media_comment_column_available?(column_name)
      MediaGallery::MediaComment.columns_hash.key?(column_name.to_s)
    rescue => e
      Rails.logger.warn("[media_gallery] media comment column check failed column=#{column_name}: #{e.class}: #{e.message}")
      false
    end

    def comment_like_table_available?
      defined?(::MediaGallery::MediaCommentLike) && ::MediaGallery::MediaCommentLike.table_exists?
    rescue ActiveRecord::StatementInvalid, NoMethodError => e
      Rails.logger.warn("[media_gallery] media comment like table check failed: #{e.class}: #{e.message}")
      false
    end

    def comment_report_table_available?
      defined?(::MediaGallery::MediaCommentReport) && ::MediaGallery::MediaCommentReport.table_exists?
    rescue ActiveRecord::StatementInvalid, NoMethodError => e
      Rails.logger.warn("[media_gallery] media comment report table check failed: #{e.class}: #{e.message}")
      false
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
