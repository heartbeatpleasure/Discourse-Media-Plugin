# frozen_string_literal: true

require "fileutils"

module ::MediaGallery
  class AdminReportsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    REPORTS_KEY = "media_reports"
    VISIBILITY_KEY = "admin_visibility"
    MANAGEMENT_LOG_KEY = "admin_management_log"
    ASSET_DELETION_KEY = "reported_asset_deletion"
    MAX_MANAGEMENT_LOG_ENTRIES = 50

    def index
      reports = report_scope.flat_map { |item| report_payloads_for_item(item) }
      reports = apply_status_filter(reports)
      reports = apply_report_search_filter(reports)
      reports.sort_by! { |report| report[:created_at].to_s }
      reports.reverse!

      limit = bounded_limit
      render_json_dump(
        reports: reports.first(limit),
        count: reports.length,
        limit: limit
      )
    end

    def review
      report_id = safe_report_id(params[:report_id])
      return render_json_error("invalid_report_id", status: 422) if report_id.blank?

      decision = params[:decision].to_s.strip
      unless %w[accept_hide accept_delete_asset reject resolve].include?(decision)
        return render_json_error("invalid_report_decision", status: 422)
      end

      note = ::MediaGallery::TextSanitizer.plain_text(params[:note], max_length: 2000, allow_newlines: true).presence
      item = find_item_by_report_id!(report_id)
      report_payload = nil
      delete_summary = nil

      item.with_lock do
        meta = metadata_for(item)
        reports = reports_from_meta(meta)
        report = reports.find { |entry| entry.is_a?(Hash) && entry["id"].to_s == report_id }
        raise Discourse::NotFound if report.blank?

        if report["status"].to_s != "open"
          return render_json_error("report_already_reviewed", status: 422, message: "This report has already been reviewed.")
        end

        now = Time.now.utc.iso8601
        report["status"] = decision == "reject" ? "rejected" : "accepted"
        report["decision"] = decision
        report["reviewed_at"] = now
        report["reviewed_by_user_id"] = current_user.id
        report["reviewed_by_username"] = current_user.username
        report["review_note"] = note if note.present?

        case decision
        when "accept_hide"
          apply_visibility!(meta, item, hidden: true, reason: "Report accepted by staff.", at: now)
          append_management_log!(meta, action: "report_accept_hide", item: item, note: note, changes: { "hidden" => [item.admin_hidden?, true], "report_id" => [nil, report_id] })
        when "accept_delete_asset"
          delete_summary = delete_reported_asset!(item)
          report["delete_summary"] = delete_summary
          meta[ASSET_DELETION_KEY] = asset_deletion_metadata(item, report, delete_summary, at: now)
          apply_visibility!(meta, item, hidden: true, reason: "Report accepted by staff; asset deleted.", at: now)
          append_management_log!(meta, action: "report_accept_delete_asset", item: item, note: note, changes: { "hidden" => [item.admin_hidden?, true], "asset_deleted" => [false, true], "report_id" => [nil, report_id] })
        when "reject"
          append_management_log!(meta, action: "report_reject", item: item, note: note, changes: { "report_id" => [nil, report_id] })
        when "resolve"
          report["status"] = "resolved"
          append_management_log!(meta, action: "report_resolve", item: item, note: note, changes: { "report_id" => [nil, report_id] })
        end

        meta[REPORTS_KEY] = reports

        update_attrs = { extra_metadata: meta, updated_at: Time.now }
        if decision == "accept_delete_asset"
          update_attrs.merge!(
            original_upload_id: nil,
            processed_upload_id: nil,
            thumbnail_upload_id: nil,
            status: "failed",
            error_message: "asset_deleted_after_media_report"
          )
        end

        item.update_columns(update_attrs)
        item.reload
        report_payload = report_payload_for(item, report)
      end

      ::MediaGallery::OperationLogger.warn(
        "media_report_reviewed",
        item: item,
        operation: "report_review",
        data: {
          report_id: report_id,
          decision: decision,
          reviewed_by: current_user.username,
          note_present: note.present?,
          delete_summary: delete_summary,
        }.compact
      )

      render_json_dump(ok: true, report: report_payload, item: item_summary_payload(item), message: review_message(decision), delete_summary: delete_summary)
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("[media_gallery] report review failed report_id=#{params[:report_id]} request_id=#{request.request_id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(40)&.join("\n")}")
      render_json_error("report_review_failed", status: 422, message: "Report review failed. Please try again.")
    end

    private

    def report_scope
      ::MediaGallery::MediaItem
        .includes(:user)
        .where("jsonb_typeof(extra_metadata -> ?) = 'array'", REPORTS_KEY)
        .where("jsonb_array_length(extra_metadata -> ?) > 0", REPORTS_KEY)
        .order(updated_at: :desc)
        .limit(1000)
    end

    def report_payloads_for_item(item)
      reports_from_meta(metadata_for(item)).map { |report| report_payload_for(item, report) }
    end

    def report_payload_for(item, report)
      snapshot = report["item_snapshot"].is_a?(Hash) ? report["item_snapshot"] : {}
      {
        id: report["id"].to_s,
        status: report["status"].to_s.presence || "open",
        decision: report["decision"].to_s.presence,
        reason: report["reason"].to_s,
        reason_label: report["reason_label"].to_s.presence || report["reason"].to_s,
        message: report["message"].to_s.presence,
        created_at: report["created_at"].to_s,
        reporter_user_id: report["reporter_user_id"],
        reporter_username: report["reporter_username"].to_s.presence,
        reporter_trust_level: report["reporter_trust_level"],
        reporter_staff: ActiveModel::Type::Boolean.new.cast(report["reporter_staff"]),
        auto_hidden: ActiveModel::Type::Boolean.new.cast(report["auto_hidden"]),
        reviewed_at: report["reviewed_at"].to_s.presence,
        reviewed_by_username: report["reviewed_by_username"].to_s.presence,
        review_note: report["review_note"].to_s.presence,
        media: item_summary_payload(item, snapshot: snapshot),
        item_snapshot: snapshot_payload(snapshot),
        delete_summary: report["delete_summary"].is_a?(Hash) ? report["delete_summary"] : nil,
      }.compact
    end

    def item_summary_payload(item, snapshot: nil)
      snapshot ||= {}
      deletion = asset_deletion_state(item)
      {
        id: item.id,
        public_id: item.public_id.to_s,
        title: item.title.to_s.presence || snapshot["title"].to_s,
        status: item.status.to_s,
        media_type: item.media_type.to_s.presence || snapshot["media_type"].to_s.presence,
        uploader_user_id: item.user_id || snapshot["uploader_user_id"],
        uploader_username: item.user&.username.to_s.presence || snapshot["uploader_username"].to_s.presence,
        created_at: item.created_at&.iso8601 || snapshot["created_at"].to_s.presence,
        hidden: item.admin_hidden?,
        asset_deleted: deletion.present?,
        asset_deleted_at: deletion["deleted_at"],
        thumbnail_url: deletion.present? ? nil : "/media/#{item.public_id}/thumbnail?admin_preview=1",
      }.compact
    end

    def snapshot_payload(snapshot)
      return {} unless snapshot.is_a?(Hash)

      snapshot.slice(
        "public_id",
        "title",
        "description",
        "media_type",
        "gender",
        "tags",
        "status",
        "uploader_user_id",
        "uploader_username",
        "created_at",
        "filesize_original_bytes",
        "filesize_processed_bytes",
        "original_upload_id",
        "processed_upload_id",
        "thumbnail_upload_id",
        "original_upload_sha1",
        "processed_upload_sha1",
        "thumbnail_upload_sha1",
        "original_filename",
        "managed_storage_backend",
        "managed_storage_profile",
        "delivery_mode"
      )
    end

    def apply_status_filter(reports)
      status = params[:status].to_s.strip.presence || "open"
      return reports if status == "all"

      reports.select { |report| report[:status].to_s == status }
    end

    def apply_report_search_filter(reports)
      q = ::MediaGallery::TextSanitizer.search_query(params[:q], max_length: 160).to_s.downcase
      return reports if q.blank?

      reports.select do |report|
        [
          report[:id],
          report[:reason_label],
          report[:message],
          report[:reporter_username],
          report.dig(:media, :public_id),
          report.dig(:media, :title),
          report.dig(:media, :uploader_username),
        ].compact.any? { |value| value.to_s.downcase.include?(q) }
      end
    end

    def bounded_limit
      value = params[:limit].to_i
      value = 50 if value <= 0
      [[value, 20].max, 200].min
    end

    def find_item_by_report_id!(report_id)
      item = ::MediaGallery::MediaItem.where("extra_metadata -> ? @> ?::jsonb", REPORTS_KEY, [{ id: report_id }].to_json).first
      raise Discourse::NotFound if item.blank?
      item
    end

    def safe_report_id(value)
      value.to_s.strip.match?(/\A[a-f0-9\-]{20,80}\z/i) ? value.to_s.strip : nil
    end

    def metadata_for(item)
      item.extra_metadata.is_a?(Hash) ? item.extra_metadata.deep_dup : {}
    end

    def reports_from_meta(meta)
      reports = meta[REPORTS_KEY]
      reports.is_a?(Array) ? reports : []
    end

    def apply_visibility!(meta, item, hidden:, reason:, at:)
      visibility = meta[VISIBILITY_KEY].is_a?(Hash) ? meta[VISIBILITY_KEY].deep_dup : {}
      visibility["hidden"] = hidden
      visibility["updated_at"] = at
      visibility["updated_by"] = current_user.username
      visibility["reason"] = reason
      if hidden
        visibility["hidden_at"] ||= at
        visibility["hidden_by"] ||= current_user.username
      else
        visibility["unhidden_at"] = at
        visibility["unhidden_by"] = current_user.username
      end
      meta[VISIBILITY_KEY] = visibility
    end

    def append_management_log!(meta, action:, item:, note:, changes: nil)
      log = meta[MANAGEMENT_LOG_KEY]
      log = [] unless log.is_a?(Array)
      entry = {
        "action" => action.to_s,
        "at" => Time.now.utc.iso8601,
        "admin_username" => current_user.username,
        "admin_user_id" => current_user.id,
        "public_id" => item.public_id.to_s,
      }
      entry["note"] = note if note.present?
      entry["changes"] = changes if changes.present?
      log.unshift(entry)
      meta[MANAGEMENT_LOG_KEY] = log.first(MAX_MANAGEMENT_LOG_ENTRIES)
    end

    def asset_deletion_state(item)
      meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata : {}
      value = meta[ASSET_DELETION_KEY]
      value.is_a?(Hash) ? value : {}
    end

    def asset_deletion_metadata(item, report, delete_summary, at:)
      snapshot = report["item_snapshot"].is_a?(Hash) ? report["item_snapshot"].deep_dup : {}
      snapshot["storage_manifest"] ||= item.storage_manifest_hash
      {
        "deleted_at" => at,
        "deleted_by_user_id" => current_user.id,
        "deleted_by_username" => current_user.username,
        "report_id" => report["id"].to_s,
        "reason" => report["reason"].to_s,
        "item_snapshot" => snapshot,
        "delete_summary" => delete_summary,
      }
    end

    def delete_reported_asset!(item)
      delete_summary = build_delete_summary_for(item)
      upload_ids = [item.original_upload_id, item.processed_upload_id, item.thumbnail_upload_id].compact.uniq
      uploads = upload_ids.present? ? ::Upload.where(id: upload_ids).to_a : []

      delete_managed_assets_safely!(item, delete_summary: delete_summary)
      uploads.each { |upload| destroy_upload_safely!(upload, delete_summary: delete_summary) }

      partial = Array(delete_summary["warnings"]).present?
      delete_summary["status"] = partial ? "partial" : "complete"
      delete_summary
    end

    def build_delete_summary_for(item)
      {
        "mode" => "report_asset_delete_keep_audit_record",
        "public_id" => item.public_id.to_s,
        "managed_assets" => [],
        "uploads" => [],
        "filesystem_paths" => [],
        "warnings" => [],
      }
    end

    def delete_managed_assets_safely!(item, delete_summary:)
      public_id = item.public_id.to_s

      ["main", "thumbnail"].each do |role_name|
        role = ::MediaGallery::AssetManifest.role_for(item, role_name)
        next if role.blank?
        next unless %w[local s3].include?(role["backend"].to_s)

        deleted = false
        warning = nil
        begin
          store = managed_store_for_role(item, role)
          if store.blank?
            warning = "store_missing"
          else
            deleted = !!store.delete(role["key"].to_s)
            warning = "delete_failed" unless deleted
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["managed_assets"] << {
          role: role_name,
          backend: role["backend"].to_s,
          key: role["key"].to_s,
          deleted: deleted,
          warning: warning,
        }.compact
        delete_summary["warnings"] << "#{role_name}: #{warning}" if warning.present?
      end

      hls_role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      if hls_role.present? && %w[local s3].include?(hls_role["backend"].to_s)
        prefix = hls_role["key_prefix"].presence || hls_role["key"].presence || ::MediaGallery::PrivateStorage.hls_root_rel_dir(public_id)
        deleted = false
        warning = nil
        begin
          store = managed_store_for_role(item, hls_role)
          if store.blank?
            warning = "store_missing"
          elsif prefix.present?
            deleted = !!store.delete_prefix(prefix.to_s)
            warning = "delete_prefix_failed" unless deleted
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["managed_assets"] << {
          role: "hls",
          backend: hls_role["backend"].to_s,
          key_prefix: prefix.to_s,
          deleted: deleted,
          warning: warning,
        }.compact
        delete_summary["warnings"] << "hls: #{warning}" if warning.present?
      end

      [
        { label: "private_dir", path: ::MediaGallery::PrivateStorage.item_private_dir(public_id) },
        { label: "original_export_dir", path: ::MediaGallery::PrivateStorage.item_original_dir(public_id) },
      ].each do |entry|
        removed = false
        warning = nil
        begin
          if entry[:path].present? && Dir.exist?(entry[:path])
            FileUtils.rm_rf(entry[:path])
            removed = !Dir.exist?(entry[:path])
            warning = "filesystem_remove_failed" unless removed
          else
            removed = true
          end
        rescue => e
          warning = "#{e.class}: #{e.message}"
        end

        delete_summary["filesystem_paths"] << { label: entry[:label], path: entry[:path].to_s, removed: removed, warning: warning }.compact
        delete_summary["warnings"] << "#{entry[:label]}: #{warning}" if warning.present?
      end

      delete_summary["warnings"].uniq!
    end

    def managed_store_for_role(item, role)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"].to_s)
      return nil if store.blank?
      return nil if role["backend"].to_s.present? && store.backend.to_s != role["backend"].to_s

      store
    end

    def destroy_upload_safely!(upload, delete_summary:)
      return if upload.blank?

      deleted = false
      warning = nil
      begin
        if defined?(::UploadDestroyer)
          ::UploadDestroyer.new(Discourse.system_user, upload).destroy
          deleted = !::Upload.exists?(id: upload.id)
        else
          upload.destroy!
          deleted = !::Upload.exists?(id: upload.id)
        end
        warning = "upload_delete_failed" unless deleted
      rescue => e
        warning = "#{e.class}: #{e.message}"
      end

      delete_summary["uploads"] << { id: upload.id, original_filename: upload.original_filename.to_s, sha1: upload.sha1.to_s, filesize: upload.filesize, deleted: deleted, warning: warning }.compact
      delete_summary["warnings"] << "upload #{upload.id}: #{warning}" if warning.present?
      deleted
    end

    def review_message(decision)
      case decision
      when "accept_hide"
        "Report accepted. The media item is hidden."
      when "accept_delete_asset"
        "Report accepted. The asset files were deleted and the audit record was kept."
      when "reject"
        "Report rejected."
      when "resolve"
        "Report resolved without further action."
      else
        "Report updated."
      end
    end
  end
end
