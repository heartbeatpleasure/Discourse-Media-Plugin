# frozen_string_literal: true

module ::MediaGallery
  class AdminUserDiagnosticsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    SEARCH_LIMIT = 20
    RECENT_LIMIT = 8

    def search
      query = sanitized_query(params[:q])
      return render_json_dump(users: []) if query.blank?

      users = search_users(query)
      render_json_dump(users: users.map { |user| user_search_payload(user) })
    rescue => e
      Rails.logger.warn("[media_gallery] user diagnostics search failed request_id=#{request.request_id}: #{e.class}: #{e.message}")
      render_json_error("user_search_failed", status: 422, message: "User search failed. Please try again.")
    end

    def show
      user = ::User.includes(:groups).find_by(id: params[:user_id].to_i)
      raise Discourse::NotFound if user.blank?

      render_json_dump(
        user: user_payload(user),
        access: access_payload(user),
        settings: settings_payload(user),
        stats: stats_payload(user),
        recent: recent_payload(user),
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.warn("[media_gallery] user diagnostics failed user_id=#{params[:user_id]} request_id=#{request.request_id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
      render_json_error("user_diagnostics_failed", status: 422, message: "User diagnostics failed. Please try again.")
    end

    private

    def sanitized_query(value)
      ::MediaGallery::TextSanitizer.search_query(value, max_length: 120).to_s.strip
    end

    def search_users(query)
      term = query.downcase
      users = []

      if term.match?(/\A\d+\z/)
        user = ::User.find_by(id: term.to_i)
        users << user if user.present?
      end

      user_scope = ::User
        .where("LOWER(username) LIKE :q OR LOWER(name) LIKE :q", q: "%#{::ActiveRecord::Base.sanitize_sql_like(term)}%")
        .order(:username)
        .limit(SEARCH_LIMIT)
      users.concat(user_scope.to_a)


      users.compact.uniq(&:id).first(SEARCH_LIMIT)
    end

    def user_search_payload(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        trust_level: user.trust_level,
        admin: user.admin?,
        moderator: user.moderator?,
        staff: user.staff?,
        last_seen_at: user.last_seen_at&.iso8601,
        created_at: user.created_at&.iso8601,
      }
    end

    def user_payload(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        trust_level: user.trust_level,
        admin: user.admin?,
        moderator: user.moderator?,
        staff: user.staff?,
        active: user.active,
        approved: user.approved,
        staged: user.staged,
        suspended: user.suspended?,
        suspended_till: user.suspended_till&.iso8601,
        silenced: user.silenced?,
        silenced_till: user.silenced_till&.iso8601,
        created_at: user.created_at&.iso8601,
        last_seen_at: user.last_seen_at&.iso8601,
        groups: user_group_payloads(user),
        admin_url: "/admin/users/#{user.id}/#{user.username}",
        profile_url: "/u/#{user.username}/summary",
      }
    end

    def user_group_payloads(user)
      groups = user.groups.order(:name).limit(100).to_a
      tl_groups = groups.select { |group| trust_level_group_name?(group.name) }
      highest_tl = tl_groups.max_by { |group| trust_level_from_group_name(group.name) }

      display_groups = groups.reject { |group| trust_level_group_name?(group.name) }
      display_groups.unshift(highest_tl) if highest_tl.present?

      display_groups.compact.map do |group|
        {
          id: group.id,
          name: group.name,
          automatic: group.respond_to?(:automatic) ? group.automatic : false,
        }
      end
    end

    def trust_level_group_name?(name)
      name.to_s.match?(/\Atrust_level_\d+\z/)
    end

    def trust_level_from_group_name(name)
      name.to_s[/\Atrust_level_(\d+)\z/, 1].to_i
    end

    def access_payload(user)
      guardian = ::Guardian.new(user)
      user_groups = normalized_group_names(user)
      view_block_matches = matching_groups(user_groups, view_block_groups)
      upload_block_matches = matching_groups(user_groups, upload_block_groups)
      viewer_matches = matching_groups(user_groups, viewer_groups)
      uploader_matches = matching_groups(user_groups, uploader_groups)

      can_view = ::MediaGallery::Permissions.can_view?(guardian)
      can_upload = ::MediaGallery::Permissions.can_upload?(guardian)
      can_report = SiteSetting.media_gallery_reports_enabled && can_view
      instant_report_hide = report_auto_hide_user?(user)
      report_points = report_points_for(user)

      {
        can_view: can_view,
        view_reason: view_access_reason(user, view_block_matches, viewer_matches),
        view_details: view_access_details(view_block_matches, viewer_matches),
        can_upload: can_upload,
        upload_reason: upload_access_reason(user, view_block_matches, upload_block_matches, uploader_matches),
        upload_details: upload_access_details(user, view_block_matches, upload_block_matches, uploader_matches),
        can_report: can_report,
        report_reason: can_report ? "Allowed because the user can view media and reports are enabled." : report_access_reason(can_view),
        report_details: report_access_details(can_view),
        view_blocked: view_block_matches.any?,
        view_block_groups: view_block_matches,
        upload_blocked: upload_block_matches.any? || view_block_matches.any?,
        upload_only_blocked: upload_block_matches.any?,
        upload_block_groups: upload_block_matches,
        viewer_group_matches: viewer_matches,
        uploader_group_matches: uploader_matches,
        report_auto_hide_instant: instant_report_hide,
        report_auto_hide_instant_reason: instant_report_hide ? "User matches an instant auto-hide reporter group or rule." : "User does not match an instant auto-hide reporter rule.",
        report_auto_hide_details: report_auto_hide_details(user),
        report_score_points: report_points,
        report_score_threshold: SiteSetting.media_gallery_report_auto_hide_score_threshold.to_i,
        report_score_details: report_score_details(user, report_points),
      }
    end

    def view_access_reason(user, view_block_matches, viewer_matches)
      return "Media gallery is disabled." unless SiteSetting.media_gallery_enabled
      return "Denied because the user is in view-block group: #{view_block_matches.join(', ')}." if view_block_matches.any?

      if viewer_groups.blank?
        return view_block_groups.blank? ?
          "Allowed because no viewer groups or view-block groups are configured." :
          "Allowed because viewer groups are empty and the user is not in any configured view-block group."
      end

      return "Allowed because the user matches viewer group: #{viewer_matches.join(', ')} and is not in a view-block group." if viewer_matches.any?

      "Denied because the user does not match any configured viewer group."
    end

    def upload_access_reason(user, view_block_matches, upload_block_matches, uploader_matches)
      return "Media gallery is disabled." unless SiteSetting.media_gallery_enabled
      return "Denied because view-block also denies upload: #{view_block_matches.join(', ')}." if view_block_matches.any?
      return "Denied because the user is in upload-block group: #{upload_block_matches.join(', ')}." if upload_block_matches.any?
      return "Allowed because the user is staff/admin and is not view-blocked or upload-blocked." if user.staff? || user.admin?

      if uploader_groups.blank?
        return upload_block_groups.blank? ?
          "Allowed because no uploader groups or upload-block groups are configured." :
          "Allowed because uploader groups are empty and the user is not in any configured upload-block group."
      end

      return "Allowed because the user matches uploader group: #{uploader_matches.join(', ')} and is not view-blocked or upload-blocked." if uploader_matches.any?

      "Denied because the user does not match any configured uploader group."
    end

    def report_access_reason(can_view)
      return "Denied because media reports are disabled." unless SiteSetting.media_gallery_reports_enabled
      return "Denied because the user cannot view media." unless can_view

      "Denied."
    end

    def view_access_details(view_block_matches, viewer_matches)
      [
        detail_row("Media gallery", SiteSetting.media_gallery_enabled ? "enabled" : "disabled"),
        detail_row("Viewer groups", viewer_groups.present? ? viewer_groups.join(", ") : "empty; all logged-in users may view"),
        detail_row("Viewer match", viewer_matches.present? ? viewer_matches.join(", ") : (viewer_groups.blank? ? "not required" : "no match")),
        detail_row("View-block groups", view_block_groups.present? ? view_block_groups.join(", ") : "none configured"),
        detail_row("View-block match", view_block_matches.present? ? view_block_matches.join(", ") : "no match"),
      ]
    end

    def upload_access_details(user, view_block_matches, upload_block_matches, uploader_matches)
      [
        detail_row("Media gallery", SiteSetting.media_gallery_enabled ? "enabled" : "disabled"),
        detail_row("Uploader groups", uploader_groups.present? ? uploader_groups.join(", ") : "empty; all logged-in users may upload unless blocked"),
        detail_row("Uploader match", uploader_matches.present? ? uploader_matches.join(", ") : (uploader_groups.blank? ? "not required" : "no match")),
        detail_row("View-block match", view_block_matches.present? ? view_block_matches.join(", ") : "no match"),
        detail_row("Upload-block groups", upload_block_groups.present? ? upload_block_groups.join(", ") : "none configured"),
        detail_row("Upload-block match", upload_block_matches.present? ? upload_block_matches.join(", ") : "no match"),
        detail_row("Staff/admin", user.staff? || user.admin? ? "yes; may upload unless blocked" : "no"),
      ]
    end

    def report_access_details(can_view)
      [
        detail_row("Reports setting", SiteSetting.media_gallery_reports_enabled ? "enabled" : "disabled"),
        detail_row("Can view media", can_view ? "yes" : "no"),
        detail_row("Result", SiteSetting.media_gallery_reports_enabled && can_view ? "allowed" : "denied"),
      ]
    end

    def report_auto_hide_details(user)
      matches = matching_report_auto_hide_rules(user)
      [
        detail_row("Configured rules", report_auto_hide_groups.present? ? report_auto_hide_groups.join(", ") : "none configured"),
        detail_row("User match", matches.present? ? matches.join(", ") : "no match"),
        detail_row("Trust level", "TL#{user.trust_level}"),
      ]
    end

    def report_score_details(user, report_points)
      threshold = SiteSetting.media_gallery_report_auto_hide_score_threshold.to_i
      [
        detail_row("User trust level", "TL#{user.trust_level}"),
        detail_row("Point weight", "#{report_points} per open report"),
        detail_row("Threshold", threshold.positive? ? threshold.to_s : "disabled"),
        detail_row("Scope", "per media item; only open reports on the same media item count"),
      ]
    end

    def detail_row(label, value)
      { label: label, value: value }
    end

    def settings_payload(user)
      user_groups = normalized_group_names(user)
      rows = []
      rows << setting_row("Viewer groups", "media_gallery_viewer_groups", viewer_groups, matching_groups(user_groups, viewer_groups), viewer_groups.blank? ? "Empty means all logged-in users may view." : "User must match one of these groups to view.")
      rows << setting_row("Uploader groups", "media_gallery_allowed_uploader_groups", uploader_groups, matching_groups(user_groups, uploader_groups), uploader_groups.blank? ? "Empty means all logged-in users may upload unless blocked." : "User must match one of these groups to upload unless staff/admin.")
      rows << setting_row("View blocked groups", "media_gallery_blocked_groups + quick block group", view_block_groups, matching_groups(user_groups, view_block_groups), "A match denies both viewing and uploading.")
      rows << setting_row("Upload blocked groups", "media_gallery_upload_blocked_groups + quick upload block group", upload_block_groups, matching_groups(user_groups, upload_block_groups), "A match denies uploading only; viewing may still be allowed.")
      rows << setting_row("Report instant auto-hide groups", "media_gallery_report_auto_hide_groups", report_auto_hide_groups, matching_report_auto_hide_rules(user), "A match auto-hides immediately when the user reports media.")
      rows << {
        label: "Report score threshold",
        setting: "media_gallery_report_auto_hide_score_threshold",
        configured: SiteSetting.media_gallery_report_auto_hide_score_threshold.to_i.positive? ? SiteSetting.media_gallery_report_auto_hide_score_threshold.to_i.to_s : "disabled",
        matches: report_points_for(user).positive? ? "#{report_points_for(user)} points for TL#{user.trust_level}" : "0 points",
        effect: "Reports from this user add these points to the open-report score unless instant auto-hide already applies.",
      }
      rows << setting_row("Report notify groups", "media_gallery_report_notify_group", list_setting(SiteSetting.media_gallery_report_notify_group), matching_groups(user_groups, list_setting(SiteSetting.media_gallery_report_notify_group).map(&:downcase)), "Groups receiving report notifications. This is informational for the selected user.")
      rows
    end

    def setting_row(label, setting, configured_groups, matches, effect)
      {
        label: label,
        setting: setting,
        configured: configured_groups.present? ? configured_groups.join(", ") : "empty",
        matches: matches.present? ? matches.join(", ") : "no match",
        matched: matches.present?,
        effect: effect,
      }
    end

    def stats_payload(user)
      item_scope = ::MediaGallery::MediaItem.where(user_id: user.id)
      report_involvement = report_involvement_payload(user)
      {
        uploads_total: safe_count(item_scope),
        uploads_ready: safe_count(item_scope.where(status: "ready")),
        uploads_failed: safe_count(item_scope.where(status: "failed")),
        uploads_processing: safe_count(item_scope.where(status: %w[queued processing])),
        uploads_hidden: safe_count(item_scope.where("COALESCE((extra_metadata -> 'admin_visibility' ->> 'hidden')::boolean, false) = true")),
        reports_submitted: report_involvement.dig(:submitted, :total).to_i,
        reports_against_media: report_involvement.dig(:on_user_media, :total).to_i,
        report_involvement: report_involvement,
        likes_given: table_count(::MediaGallery::MediaLike, user_id: user.id),
        playback_sessions: table_count(::MediaGallery::MediaPlaybackSession, user_id: user.id),
        log_events_30d: log_events_count(user, 30.days.ago),
        last_upload_at: item_scope.maximum(:created_at)&.iso8601,
        last_report_at: last_report_at_for(user)&.iso8601,
      }
    end

    def recent_payload(user)
      {
        uploads: recent_uploads(user),
        logs: recent_logs(user),
        reports: recent_reports_by_user(user),
      }
    end

    def recent_uploads(user)
      ::MediaGallery::MediaItem
        .where(user_id: user.id)
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
        .map { |item| media_item_payload(item) }
    rescue
      []
    end

    def recent_logs(user)
      return [] unless log_events_available?

      ::MediaGallery::MediaLogEvent
        .includes(:media_item)
        .where(user_id: user.id)
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
        .map do |event|
          {
            id: event.id,
            created_at: event.created_at&.iso8601,
            event_type: event.event_type,
            severity: event.severity,
            category: event.category,
            message: event.message,
            media_public_id: event.media_public_id || event.media_item&.public_id,
            media_title: event.media_item&.title,
          }
        end
    rescue
      []
    end

    def recent_reports_by_user(user)
      reports = []
      ::MediaGallery::MediaItem
        .where("jsonb_typeof(extra_metadata -> 'media_reports') = 'array'")
        .where("extra_metadata -> 'media_reports' @> ?::jsonb", [{ reporter_user_id: user.id }].to_json)
        .order(updated_at: :desc)
        .limit(100)
        .to_a.each do |item|
          media_reports_for(item).each do |report|
            next unless report["reporter_user_id"].to_i == user.id

            reports << {
              id: report["id"],
              created_at: report["created_at"],
              status: report["status"],
              reason_label: report["reason_label"].presence || report["reason"],
              media_public_id: item.public_id,
              media_title: item.title,
              report_url: report["id"].present? ? "/admin/plugins/media-gallery-reports?report_id=#{report["id"]}" : "/admin/plugins/media-gallery-reports?status=all&reporter_user_id=#{user.id}",
            }
          end
        end
      reports.sort_by { |report| report[:created_at].to_s }.reverse.first(RECENT_LIMIT)
    rescue
      []
    end

    def media_item_payload(item)
      {
        id: item.id,
        public_id: item.public_id,
        title: item.title,
        status: item.status,
        media_type: item.media_type,
        gender: item.gender,
        tags: Array(item.tags).map(&:to_s),
        hidden: item.admin_hidden?,
        created_at: item.created_at&.iso8601,
        thumbnail_url: "/media/#{item.public_id}/thumbnail?admin_preview=1",
        management_url: "/admin/plugins/media-gallery-management?public_id=#{item.public_id}",
      }
    end

    def report_involvement_payload(user)
      {
        submitted: report_counts_by_reporter(user),
        on_user_media: report_counts_on_user_media(user),
      }
    end

    def empty_report_counts
      {
        total: 0,
        open: 0,
        accepted: 0,
        rejected: 0,
        resolved: 0,
        auto_hidden: 0,
      }
    end

    def report_counts_by_reporter(user)
      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT COALESCE(report.value ->> 'status', 'open') AS status,
                 COALESCE(report.value ->> 'auto_hidden', 'false') AS auto_hidden,
                 COUNT(*) AS count
          FROM media_gallery_media_items
          CROSS JOIN LATERAL jsonb_array_elements(extra_metadata -> 'media_reports') AS report(value)
          WHERE jsonb_typeof(extra_metadata -> 'media_reports') = 'array'
            AND report.value ->> 'reporter_user_id' = ?
          GROUP BY status, auto_hidden
        SQL
        user.id.to_s,
      ])
      report_counts_from_sql(sql)
    rescue
      empty_report_counts
    end

    def report_counts_on_user_media(user)
      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT COALESCE(report.value ->> 'status', 'open') AS status,
                 COALESCE(report.value ->> 'auto_hidden', 'false') AS auto_hidden,
                 COUNT(*) AS count
          FROM media_gallery_media_items
          CROSS JOIN LATERAL jsonb_array_elements(extra_metadata -> 'media_reports') AS report(value)
          WHERE jsonb_typeof(extra_metadata -> 'media_reports') = 'array'
            AND user_id = ?
          GROUP BY status, auto_hidden
        SQL
        user.id,
      ])
      report_counts_from_sql(sql)
    rescue
      empty_report_counts
    end

    def report_counts_from_sql(sql)
      counts = empty_report_counts
      ActiveRecord::Base.connection.select_all(sql).each do |row|
        count = row["count"].to_i
        status = row["status"].to_s.presence || "open"
        status = "open" unless %w[open accepted rejected resolved].include?(status)
        counts[:total] += count
        counts[status.to_sym] += count
        counts[:auto_hidden] += count if ActiveModel::Type::Boolean.new.cast(row["auto_hidden"])
      end
      counts
    rescue
      empty_report_counts
    end

    def reports_submitted_count(user)
      ::MediaGallery::MediaItem
        .where("jsonb_typeof(extra_metadata -> 'media_reports') = 'array'")
        .where("extra_metadata -> 'media_reports' @> ?::jsonb", [{ reporter_user_id: user.id }].to_json)
        .count
    rescue
      0
    end

    def reports_against_user_media_count(user)
      ::MediaGallery::MediaItem
        .where(user_id: user.id)
        .where("jsonb_typeof(extra_metadata -> 'media_reports') = 'array'")
        .where("jsonb_array_length(extra_metadata -> 'media_reports') > 0")
        .count
    rescue
      0
    end

    def last_report_at_for(user)
      recent_reports_by_user(user).map { |report| Time.zone.parse(report[:created_at].to_s) rescue nil }.compact.max
    end

    def media_reports_for(item)
      value = item.extra_metadata.is_a?(Hash) ? item.extra_metadata["media_reports"] : nil
      value.is_a?(Array) ? value : []
    end

    def view_block_groups
      ::MediaGallery::Permissions.blocked_groups
    end

    def upload_block_groups
      ::MediaGallery::Permissions.upload_blocked_groups
    end

    def viewer_groups
      ::MediaGallery::Permissions.viewer_groups
    end

    def uploader_groups
      ::MediaGallery::Permissions.uploader_groups
    end

    def list_setting(value)
      ::MediaGallery::Permissions.list_setting(value)
    end

    def normalized_group_names(user)
      user.groups.pluck(:name).map { |name| name.to_s.downcase }
    rescue
      []
    end

    def matching_groups(user_groups, configured_groups)
      normalized = Array(configured_groups).map { |name| name.to_s.downcase }.reject(&:blank?)
      (user_groups & normalized).sort
    end

    def report_auto_hide_groups
      list_setting(SiteSetting.media_gallery_report_auto_hide_groups).map(&:downcase)
    end

    def matching_report_auto_hide_rules(user)
      report_auto_hide_groups.select { |entry| report_auto_hide_rule_matches_user?(entry, user) }
    end

    def report_auto_hide_user?(user)
      matching_report_auto_hide_rules(user).any?
    end

    def report_auto_hide_rule_matches_user?(entry, user)
      token = entry.to_s.downcase.strip
      case token
      when "staff"
        user.staff? || user.admin?
      when "admin", "admins"
        user.admin?
      when /\A(?:trust_level_|tl)(\d+)\z/
        user.trust_level.to_i >= Regexp.last_match(1).to_i
      else
        normalized_group_names(user).include?(token)
      end
    end

    def report_points_for(user)
      case user.trust_level.to_i
      when 0 then SiteSetting.media_gallery_report_auto_hide_tl0_points.to_i
      when 1 then SiteSetting.media_gallery_report_auto_hide_tl1_points.to_i
      when 2 then SiteSetting.media_gallery_report_auto_hide_tl2_points.to_i
      when 3 then SiteSetting.media_gallery_report_auto_hide_tl3_points.to_i
      else SiteSetting.media_gallery_report_auto_hide_tl4_points.to_i
      end
    rescue
      0
    end

    def safe_count(scope)
      scope.count
    rescue
      0
    end

    def table_count(model, where = {})
      return 0 unless table_exists?(model.table_name)

      model.where(where).count
    rescue
      0
    end

    def log_events_count(user, since)
      return 0 unless log_events_available?

      ::MediaGallery::MediaLogEvent.where(user_id: user.id).where("created_at >= ?", since).count
    rescue
      0
    end

    def log_events_available?
      defined?(::MediaGallery::MediaLogEvent) && table_exists?(::MediaGallery::MediaLogEvent.table_name)
    end

    def table_exists?(table_name)
      ::ActiveRecord::Base.connection.data_source_exists?(table_name)
    rescue
      false
    end
  end
end
