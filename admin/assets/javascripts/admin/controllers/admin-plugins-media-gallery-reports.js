import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function formatDateTime(value) {
  if (!value) {
    return "—";
  }

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function encodeParam(value) {
  return encodeURIComponent(String(value || "").trim());
}

function titleize(value) {
  return String(value || "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}


const GENDER_OPTIONS = [
  { value: "male", label: "Male hearts" },
  { value: "female", label: "Female hearts" },
  { value: "both", label: "Both male and female hearts" },
  { value: "non_binary", label: "Non-binary hearts" },
  { value: "objects", label: "Heart-related objects" },
  { value: "other", label: "Other" },
];

function genderLabel(value) {
  const normalized = String(value || "").trim();
  if (!normalized) {
    return "—";
  }

  return GENDER_OPTIONS.find((option) => option.value === normalized)?.label || titleize(normalized);
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "—";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = bytes;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size = size / 1024;
    unitIndex += 1;
  }

  const decimals = unitIndex === 0 || size >= 10 ? 0 : 1;
  return `${size.toFixed(decimals)} ${units[unitIndex]}`;
}

function formatPercent(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) {
    return "0%";
  }
  return `${Math.round(number * 100)}%`;
}

function decisionLabel(value) {
  switch (String(value || "")) {
    case "accept_hide":
      return "Accepted / hidden";
    case "accept_delete_asset":
      return "Accepted / files deleted";
    case "accept_delete_comment":
      return "Accepted / comment removed";
    case "reject":
      return "Rejected";
    case "resolve":
      return "Resolved without action";
    default:
      return "—";
  }
}

function paragraphs(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => String(entry || "").trim()).filter(Boolean);
  }

  return String(value || "")
    .split(/\n{2,}/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function reportConfirmRows(report) {
  const rows = [];
  rows.push({ label: "Report type", value: report?.typeLabel || report?.type_label || "Report" });
  if (report?.mediaTitle || report?.title) {
    rows.push({ label: "Media", value: report.mediaTitle || report.title });
  }
  if (report?.mediaPublicId || report?.public_id) {
    rows.push({ label: "Public ID", value: report.mediaPublicId || report.public_id, className: "is-code" });
  }
  if (report?.comment?.id) {
    rows.push({ label: "Comment ID", value: report.comment.id, className: "is-code" });
  }
  if (report?.comment?.username) {
    rows.push({ label: "Comment author", value: report.comment.username });
  }
  if (report?.reporter_username) {
    rows.push({ label: "Reporter", value: report.reporter_username });
  }
  if (report?.mediaUploader || report?.owner_username) {
    rows.push({ label: "Uploader", value: report.mediaUploader || report.owner_username });
  }
  return rows;
}

export default class AdminPluginsMediaGalleryReportsController extends Controller {
  @tracked statusFilter = "open";
  @tracked reportTypeFilter = "all";
  @tracked searchQuery = "";
  @tracked limit = "50";
  @tracked reports = [];
  @tracked moderationTrends = [];
  @tracked falseReporters = [];
  @tracked showAcknowledgedFalseReporters = false;
  @tracked timeWindowDays = "";
  @tracked isAcknowledgingReporter = false;
  @tracked showPerformanceTimings = false;
  @tracked lastTimingMs = null;
  @tracked lastTimingBreakdown = null;
  @tracked totalReportCount = 0;
  @tracked activeFilters = {};
  @tracked isLoading = false;
  @tracked loadError = "";
  @tracked noticeMessage = "";
  @tracked noticeTone = "success";
  @tracked selectedReportId = "";
  @tracked requestedReportId = "";
  @tracked reporterUserIdFilter = "";
  @tracked mediaOwnerUserIdFilter = "";
  @tracked commentAuthorUserIdFilter = "";
  @tracked isReviewing = false;
  @tracked reviewNote = "";
  @tracked confirmModal = null;

  confirmResolver = null;
  abortController = null;

  resetState() {
    const deepLinkedReportId = this.reportIdFromUrl();
    const initialParams = new URLSearchParams(window.location?.search || "");
    const initialQuery = String(initialParams.get("q") || "").trim().slice(0, 160);
    const initialStatus = String(initialParams.get("status") || "").trim();
    const reporterUserId = String(initialParams.get("reporter_user_id") || "").replace(/\D/g, "").slice(0, 20);
    const mediaOwnerUserId = String(initialParams.get("media_owner_user_id") || "").replace(/\D/g, "").slice(0, 20);
    const commentAuthorUserId = String(initialParams.get("comment_author_user_id") || "").replace(/\D/g, "").slice(0, 20);
    const sinceDays = String(initialParams.get("since_days") || "").replace(/\D/g, "").slice(0, 3);
    const reportType = String(initialParams.get("report_type") || initialParams.get("type") || "").trim();

    this.statusFilter = ["open", "closed", "accepted", "rejected", "resolved", "all"].includes(initialStatus)
      ? initialStatus
      : deepLinkedReportId
        ? "all"
        : "open";
    this.searchQuery = initialQuery || deepLinkedReportId || "";
    this.reportTypeFilter = ["media", "comment"].includes(reportType) ? reportType : "all";
    this.limit = "50";
    this.reports = [];
    this.moderationTrends = [];
    this.falseReporters = [];
    this.showAcknowledgedFalseReporters = false;
    this.timeWindowDays = ["7", "30", "90"].includes(sinceDays) ? sinceDays : "";
    this.isAcknowledgingReporter = false;
    this.showPerformanceTimings = false;
    this.lastTimingMs = null;
    this.lastTimingBreakdown = null;
    this.totalReportCount = 0;
    this.activeFilters = {};
    this.isLoading = false;
    this.loadError = "";
    this.noticeMessage = "";
    this.noticeTone = "success";
    this.selectedReportId = deepLinkedReportId || "";
    this.requestedReportId = deepLinkedReportId || "";
    this.reporterUserIdFilter = reporterUserId;
    this.mediaOwnerUserIdFilter = mediaOwnerUserId;
    this.commentAuthorUserIdFilter = commentAuthorUserId;
    this.isReviewing = false;
    this.reviewNote = "";
    this.confirmModal = null;
    this.confirmResolver = null;
  }

  reportIdFromUrl() {
    if (typeof window === "undefined") {
      return "";
    }

    const value = new URLSearchParams(window.location.search || "").get("report_id");
    return String(value || "").match(/^(?:comment-\d+|[a-f0-9-]{20,80})$/i) ? String(value) : "";
  }

  async loadInitial() {
    await this.loadReports();
  }

  willDestroy() {
    this.abortController?.abort?.();
    super.willDestroy(...arguments);
  }

  get confirmModalOpen() {
    return !!this.confirmModal;
  }

  get confirmModalHasRows() {
    return Array.isArray(this.confirmModal?.rows) && this.confirmModal.rows.length > 0;
  }

  get confirmModalHasBody() {
    return Array.isArray(this.confirmModal?.body) && this.confirmModal.body.length > 0;
  }

  _confirmAction(config = {}) {
    if (this.confirmModalOpen) {
      return Promise.resolve(false);
    }

    this.confirmModal = {
      title: config.title || "Confirm action",
      subtitle: config.subtitle || "",
      body: paragraphs(config.body),
      rows: Array.isArray(config.rows) ? config.rows.filter((row) => row?.value) : [],
      riskLabel: config.riskLabel || "",
      confirmLabel: config.confirmLabel || "Confirm",
      confirmClass: config.danger ? "btn btn-danger" : "btn btn-primary",
    };

    return new Promise((resolve) => {
      this.confirmResolver = resolve;
    });
  }

  _resolveConfirm(value) {
    const resolver = this.confirmResolver;
    this.confirmResolver = null;
    this.confirmModal = null;
    if (resolver) {
      resolver(Boolean(value));
    }
  }

  @action
  cancelConfirmModal(event) {
    event?.preventDefault?.();
    this._resolveConfirm(false);
  }

  @action
  submitConfirmModal(event) {
    event?.preventDefault?.();
    this._resolveConfirm(true);
  }

  get selectedReport() {
    return this.decoratedReports.find((report) => report.id === this.selectedReportId) || null;
  }

  get hasSelectedReport() {
    return !!this.selectedReport;
  }

  get selectedIsOpen() {
    return this.selectedReport?.status === "open";
  }

  get selectedIsCommentReport() {
    return this.selectedReport?.reportType === "comment" || this.selectedReport?.report_type === "comment";
  }

  get selectedIsMediaReport() {
    return this.hasSelectedReport && !this.selectedIsCommentReport;
  }

  get reviewDisabled() {
    return !this.hasSelectedReport || !this.selectedIsOpen || this.isReviewing;
  }

  get selectedOwnerAccess() {
    return this.selectedIsMediaReport ? (this.selectedReport?.owner_access || {}) : {};
  }

  get selectedOwnerBlocked() {
    return !!this.selectedOwnerAccess?.view_blocked;
  }

  get ownerViewBlockDisabled() {
    return !this.hasSelectedReport || this.isReviewing || !this.selectedOwnerAccess?.can_quick_block;
  }

  get ownerViewUnblockDisabled() {
    return !this.hasSelectedReport || this.isReviewing || !this.selectedOwnerAccess?.can_quick_unblock;
  }

  get ownerUploadBlockDisabled() {
    return !this.hasSelectedReport || this.isReviewing || !this.selectedOwnerAccess?.can_quick_upload_block;
  }

  get ownerUploadUnblockDisabled() {
    return !this.hasSelectedReport || this.isReviewing || !this.selectedOwnerAccess?.can_quick_upload_unblock;
  }

  get ownerBlockDisabled() {
    return this.ownerViewBlockDisabled;
  }

  get ownerUnblockDisabled() {
    return this.ownerViewUnblockDisabled;
  }

  get ownerAccessSummary() {
    const state = this.selectedOwnerAccess;
    if (!state?.username) {
      return "Uploader access status is unavailable.";
    }
    if (state.view_blocked) {
      return `${state.username} is blocked from viewing and uploading media.`;
    }
    if (state.upload_only_blocked || state.upload_blocked) {
      return `${state.username} can view media if allowed, but cannot upload.`;
    }
    return `${state.username} is not blocked from the media section.`;
  }

  get ownerAccessHelp() {
    const state = this.selectedOwnerAccess;
    if (!state?.username) {
      return "The media uploader could not be found.";
    }
    if (state.view_blocked) {
      return `${state.username} is currently blocked from viewing and uploading media. View blocks always take priority over upload permissions.`;
    }
    if (state.upload_only_blocked || state.upload_blocked) {
      return `${state.username} can still view media if viewer rules allow it, but cannot upload to the media section.`;
    }
    if (state.can_quick_block || state.can_quick_upload_block) {
      return `Use view block to deny both viewing and uploading, or upload-only block to keep viewing allowed while preventing uploads.`;
    }
    if (!state.quick_block_group_name && !state.quick_upload_block_group_name) {
      return "Configure the media quick view block group and/or quick upload block group setting before using these actions.";
    }
    if (state.reason === "media_owner_is_staff" || state.upload_reason === "media_owner_is_staff") {
      return "Staff and admin users cannot be blocked from the media section.";
    }
    return "The quick block actions are not available for this uploader right now.";
  }

  get actionHelpItems() {
    if (this.selectedIsCommentReport) {
      return [
        { label: "Accept / Remove comment", text: "Marks the report as accepted and removes the reported comment from the media item. The report audit snapshot remains available." },
        { label: "Resolve without action", text: "Closes the comment report without removing the comment." },
        { label: "Reject report", text: "Closes the comment report as rejected." },
      ];
    }

    return [
      { label: "Accept / Hide asset", text: "Marks the report as accepted and hides the media item from normal users. The asset files remain stored." },
      { label: "Accept / Delete asset", text: "Marks the report as accepted, hides the media item, deletes stored asset files, and keeps the audit snapshot/report history." },
      { label: "Resolve without action", text: "Closes the report without accepting or rejecting it. If this report auto-hidden the item, the item is restored." },
      { label: "Reject report", text: "Closes the report as rejected. If this report auto-hidden the item, the item is restored." },
    ];
  }

  get noticeClass() {
    return this.noticeTone === "danger" ? "mg-reports__flash is-danger" : "mg-reports__flash is-success";
  }

  get decoratedReports() {
    return (Array.isArray(this.reports) ? this.reports : []).map((report) => {
      const media = report?.media || {};
      const status = String(report?.status || "open");
      return {
        ...report,
        isSelected: report?.id === this.selectedReportId,
        createdAtLabel: formatDateTime(report?.created_at),
        reviewedAtLabel: formatDateTime(report?.reviewed_at),
        reportType: report?.report_type || report?.type || "media",
        typeLabel: report?.type_label || (report?.report_type === "comment" || report?.type === "comment" ? "Comment report" : "Media report"),
        isCommentReport: (report?.report_type || report?.type) === "comment",
        isMediaReport: (report?.report_type || report?.type || "media") !== "comment",
        statusLabel: status === "open" ? "Open" : "Closed",
        statusDetailLabel: status === "open" ? "Needs review" : titleize(status),
        decisionLabel: decisionLabel(report?.decision),
        mediaTitle: media.title || report?.item_snapshot?.title || "Untitled media",
        mediaPublicId: media.public_id || report?.item_snapshot?.public_id || "—",
        mediaUploader: media.uploader_username || report?.item_snapshot?.uploader_username || "—",
        mediaCreatedAt: formatDateTime(media.created_at || report?.item_snapshot?.created_at),
        mediaTypeLabel: titleize(media.media_type || report?.item_snapshot?.media_type),
        reporterLabel: report?.reporter_username ? `${report.reporter_username} (TL${report.reporter_trust_level ?? "—"})` : "—",
        statusBadgeClass: status === "open" ? "is-warning" : "is-success",
        statusDetailBadgeClass:
          status === "accepted"
            ? "is-danger"
            : status === "rejected"
              ? "is-warning"
              : status === "resolved"
                ? "is-success"
                : "",
        hiddenLabel: media.hidden ? "Hidden" : "Visible",
        hiddenBadgeClass: media.hidden ? "is-danger" : "is-success",
        assetLabel: media.asset_deleted ? "Files deleted" : "Files present",
        assetBadgeClass: media.asset_deleted ? "is-danger" : "",
        commentAuthor: report?.comment?.username || "—",
        commentId: report?.comment?.id || "—",
        commentPreview: String(report?.comment?.body || report?.comment?.snapshot_body || "").slice(0, 220),
        commentDeleted: !!report?.comment?.deleted,
        autoHideLabel:
          report?.auto_hide_mode === "score_threshold"
            ? `Score threshold ${report?.auto_hide_score ?? "—"}/${report?.auto_hide_threshold ?? "—"}`
            : report?.auto_hide_mode === "instant"
              ? "Instant trusted report"
              : report?.auto_hidden
                ? "Auto-hidden"
                : "—",
      };
    });
  }

  get moderationTrendCards() {
    return (Array.isArray(this.moderationTrends) ? this.moderationTrends : []).map((window) => ({
      label: `${window.days ?? 0} days`,
      total: window.total ?? 0,
      open: window.open ?? 0,
      accepted: window.accepted ?? 0,
      rejected: window.rejected ?? 0,
      resolved: window.resolved ?? 0,
      autoHidden: window.auto_hidden ?? 0,
      mediaReports: window.media_reports ?? 0,
      commentReports: window.comment_reports ?? 0,
      isActive: String(this.timeWindowDays || "") === String(window.days ?? ""),
    }));
  }

  get falseReporterCards() {
    return (Array.isArray(this.falseReporters) ? this.falseReporters : []).map((reporter) => ({
      ...reporter,
      label: reporter.username ? `${reporter.username} (#${reporter.user_id})` : `User #${reporter.user_id}`,
      rejectedRateLabel: formatPercent(reporter.rejected_rate),
      className: reporter.acknowledged ? "is-acknowledged" : reporter.severity === "danger" ? "is-danger" : "is-warning",
      diagnosticsUrl: reporter.user_id ? `/admin/plugins/media-gallery-user-diagnostics?user_id=${encodeParam(reporter.user_id)}` : "",
      reportsUrl: reporter.user_id ? `/admin/plugins/media-gallery-reports?status=all&reporter_user_id=${encodeParam(reporter.user_id)}` : "",
      acknowledgedLabel: reporter.acknowledged
        ? `Acknowledged${reporter.acknowledged_by_username ? ` by ${reporter.acknowledged_by_username}` : ""}${reporter.acknowledged_at ? ` · ${formatDateTime(reporter.acknowledged_at)}` : ""}`
        : "",
    }));
  }

  get hasAcknowledgedFalseReportersVisible() {
    return this.falseReporterCards.some((reporter) => reporter.acknowledged);
  }

  get falseReporterToggleLabel() {
    return this.showAcknowledgedFalseReporters ? "Hide acknowledged" : "Show acknowledged";
  }

  get performanceTimingLabel() {
    if (!this.showPerformanceTimings || !this.lastTimingBreakdown) {
      return "";
    }

    const parts = [];
    const order = ["scope", "filters", "sort", "serialize", "trends", "false_reporters"];
    order.forEach((key) => {
      const value = Number(this.lastTimingBreakdown?.[key]);
      if (Number.isFinite(value)) {
        parts.push(`${key.replace(/_/g, " ")} ${value}ms`);
      }
    });

    return `server ${this.lastTimingMs || 0}ms${parts.length ? ` (${parts.join(" · ")})` : ""}`;
  }

  get activeHiddenFilterLabel() {
    const parts = [];
    if (String(this.reporterUserIdFilter || "").trim()) {
      parts.push(`reporter user #${this.reporterUserIdFilter}`);
    }
    if (String(this.mediaOwnerUserIdFilter || "").trim()) {
      parts.push(`media owner #${this.mediaOwnerUserIdFilter}`);
    }
    if (String(this.commentAuthorUserIdFilter || "").trim()) {
      parts.push(`comment author #${this.commentAuthorUserIdFilter}`);
    }
    if (["media", "comment"].includes(String(this.reportTypeFilter || ""))) {
      parts.push(`${this.reportTypeFilter} reports only`);
    }
    return parts.length ? `Additional filter active: ${parts.join(" · ")}` : "";
  }

  get reportsCountLabel() {
    const shown = Array.isArray(this.reports) ? this.reports.length : 0;
    const filtered = Number(this.totalReportCount || 0);
    const total = Number(this.activeFilters?.total_count || 0);
    const status = String(this.activeFilters?.status || this.statusFilter || "open");
    const sinceDays = Number(this.activeFilters?.since_days || this.timeWindowDays || 0);
    const reportType = String(this.activeFilters?.report_type || this.reportTypeFilter || "all");
    const base = `${filtered} report${filtered === 1 ? "" : "s"} found`;
    const statusLabel = status === "all" ? "all statuses" : status;
    const typeLabel = reportType === "media" ? "media reports" : reportType === "comment" ? "comment reports" : "all report types";
    const parts = [base, statusLabel, typeLabel];
    if ([7, 30, 90].includes(sinceDays)) {
      parts.push(`last ${sinceDays} days`);
    }
    if (shown !== filtered) {
      parts.push(`showing ${shown}`);
    }
    if (total && total !== filtered) {
      parts.push(`${total} total before filters`);
    }
    return parts.join(" · ");
  }

  get selectedSnapshotRows() {
    const snapshot = this.selectedReport?.item_snapshot || {};
    return [
      { label: "Public ID", value: snapshot.public_id || "—", wide: true },
      { label: "Title", value: snapshot.title || "—", wide: true },
      { label: "Uploader", value: snapshot.uploader_username ? `${snapshot.uploader_username} (#${snapshot.uploader_user_id || "—"})` : "—" },
      { label: "Media type", value: titleize(snapshot.media_type) || "—" },
      { label: "File contains", value: genderLabel(snapshot.gender) },
      { label: "Source filename", value: snapshot.source_filename || snapshot.original_filename || "—", wide: true },
      { label: "Source SHA1", value: snapshot.original_upload_sha1 || "—", wide: true },
      { label: "Source size", value: formatBytes(snapshot.filesize_original_bytes || snapshot.original_upload_filesize) },
      { label: "Processed size", value: formatBytes(snapshot.filesize_processed_bytes || snapshot.processed_upload_filesize) },
      { label: "Storage", value: [snapshot.managed_storage_backend, snapshot.managed_storage_profile_name || snapshot.managed_storage_profile].filter(Boolean).join(" / ") || "—" },
    ];
  }

  get selectedCommentRows() {
    const comment = this.selectedReport?.comment || {};
    return [
      { label: "Comment ID", value: comment.id || "—" },
      { label: "Author", value: comment.username ? `${comment.username} (#${comment.user_id || "—"})` : "—" },
      { label: "Status", value: comment.deleted ? "Removed" : titleize(comment.status || "visible") },
      { label: "Created", value: formatDateTime(comment.created_at) },
      { label: "Likes", value: comment.likes_count ?? "—" },
      { label: "Open reports", value: comment.reports_count ?? "—" },
    ];
  }

  async _extractError(response) {
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) {
        return json.errors.join(" ");
      }
      if (json?.message) {
        return String(json.message);
      }
      if (json?.error) {
        return String(json.error);
      }
    } catch {
      // ignore
    }

    return `HTTP ${response.status}`;
  }

  async _fetchJson(url, options = {}) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "X-Requested-With": "XMLHttpRequest",
        ...options.headers,
      },
      signal: options.signal,
      ...options,
    });

    if (!response.ok) {
      throw new Error(await this._extractError(response));
    }

    return await response.json();
  }

  async loadReports() {
    this.abortController?.abort?.();
    this.abortController = new AbortController();
    this.isLoading = true;
    this.loadError = "";

    const params = new URLSearchParams();
    params.set("status", this.statusFilter || "open");
    params.set("limit", this.limit || "50");
    if (["media", "comment"].includes(String(this.reportTypeFilter || ""))) {
      params.set("report_type", String(this.reportTypeFilter));
    }
    if (String(this.searchQuery || "").trim()) {
      params.set("q", String(this.searchQuery || "").trim());
    }
    if (String(this.reporterUserIdFilter || "").trim()) {
      params.set("reporter_user_id", String(this.reporterUserIdFilter || "").trim());
    }
    if (String(this.mediaOwnerUserIdFilter || "").trim()) {
      params.set("media_owner_user_id", String(this.mediaOwnerUserIdFilter || "").trim());
    }
    if (String(this.commentAuthorUserIdFilter || "").trim()) {
      params.set("comment_author_user_id", String(this.commentAuthorUserIdFilter || "").trim());
    }
    if (["7", "30", "90"].includes(String(this.timeWindowDays || ""))) {
      params.set("since_days", String(this.timeWindowDays));
    }
    if (this.showAcknowledgedFalseReporters) {
      params.set("show_acknowledged_reporter_signals", "1");
    }

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/reports?${params.toString()}`, {
        method: "GET",
        signal: this.abortController.signal,
      });
      this.reports = Array.isArray(data?.reports) ? data.reports : [];
      this.moderationTrends = Array.isArray(data?.moderation_trends) ? data.moderation_trends : [];
      this.falseReporters = Array.isArray(data?.false_reporters) ? data.false_reporters : [];
      this.totalReportCount = Number(data?.count || 0);
      this.activeFilters = { ...(data?.active_filters || {}), total_count: Number(data?.total_count || 0) };
      this.showPerformanceTimings = !!data?.show_performance_timings;
      this.lastTimingMs = Number(data?.timing_ms || 0) || null;
      this.lastTimingBreakdown = data?.timing_breakdown_ms || null;
      if (this.requestedReportId && this.reports.some((report) => report.id === this.requestedReportId)) {
        this.selectedReportId = this.requestedReportId;
      } else if (!this.reports.some((report) => report.id === this.selectedReportId)) {
        this.selectedReportId = this.reports[0]?.id || "";
      }
    } catch (error) {
      if (error?.name !== "AbortError") {
        this.loadError = error?.message || "Loading reports failed.";
      }
    } finally {
      this.isLoading = false;
    }
  }

  @action
  onSearchInput(event) {
    this.searchQuery = String(event?.target?.value || "").slice(0, 160);
  }

  @action
  onStatusFilterChange(event) {
    this.statusFilter = event?.target?.value || "open";
    this.loadReports();
  }

  @action
  onReportTypeFilterChange(event) {
    const value = event?.target?.value || "all";
    this.reportTypeFilter = ["media", "comment"].includes(value) ? value : "all";
    this.loadReports();
  }

  @action
  onLimitChange(event) {
    this.limit = event?.target?.value || "50";
    this.loadReports();
  }

  @action
  search() {
    this.loadReports();
  }

  @action
  resetFilters() {
    this.statusFilter = "open";
    this.reportTypeFilter = "all";
    this.searchQuery = "";
    this.limit = "50";
    this.requestedReportId = "";
    this.reporterUserIdFilter = "";
    this.mediaOwnerUserIdFilter = "";
    this.commentAuthorUserIdFilter = "";
    this.timeWindowDays = "";
    this.loadReports();
  }

  @action
  applyTrendWindow(days) {
    const value = String(days || "");
    this.timeWindowDays = this.timeWindowDays === value ? "" : value;
    this.statusFilter = "all";
    this.requestedReportId = "";
    this.loadReports();
  }

  @action
  applyReporterFilter(reporter) {
    if (!reporter?.user_id) {
      return;
    }

    this.statusFilter = "all";
    this.searchQuery = "";
    this.requestedReportId = "";
    this.reporterUserIdFilter = String(reporter.user_id);
    this.mediaOwnerUserIdFilter = "";
    this.timeWindowDays = "";
    this.loadReports();
  }

  @action
  toggleAcknowledgedFalseReporters() {
    this.showAcknowledgedFalseReporters = !this.showAcknowledgedFalseReporters;
    this.loadReports();
  }

  @action
  async acknowledgeFalseReporter(reporter) {
    if (!reporter?.user_id || this.isAcknowledgingReporter) {
      return;
    }

    this.isAcknowledgingReporter = true;
    this.noticeMessage = "";
    this.noticeTone = "success";

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/reports/false-reporters/${encodeURIComponent(reporter.user_id)}/acknowledge`, {
        method: "POST",
      });
      this.noticeMessage = data?.message || "Reporter signal acknowledged.";
      this.noticeTone = "success";
      await this.loadReports();
    } catch (error) {
      this.noticeMessage = error?.message || "Reporter acknowledgement failed.";
      this.noticeTone = "danger";
    } finally {
      this.isAcknowledgingReporter = false;
    }
  }

  @action
  selectReport(report) {
    this.selectedReportId = report?.id || "";
    this.reviewNote = "";
    this.noticeMessage = "";
  }

  @action
  onReviewNote(event) {
    this.reviewNote = String(event?.target?.value || "").slice(0, 2000);
  }

  @action
  async reviewSelected(decision) {
    const report = this.selectedReport;
    if (!report?.id || this.reviewDisabled) {
      return;
    }

    if (decision === "accept_delete_asset" && this.selectedIsCommentReport) {
      return;
    }

    if (decision === "accept_delete_asset") {
      const ok = await this._confirmAction({
        title: "Accept report and delete asset files",
        subtitle: "The report snapshot, checksum data, and audit history will be kept.",
        rows: reportConfirmRows(report),
        body: "This removes the playable/viewable stored asset files for this media item. The action cannot be undone from the reports page.",
        confirmLabel: "Delete asset files",
        danger: true,
        riskLabel: "Destructive asset action",
      });
      if (!ok) {
        return;
      }
    }

    if (decision === "accept_delete_comment") {
      const ok = await this._confirmAction({
        title: "Accept report and remove comment",
        subtitle: "The comment report snapshot and audit trail will be kept.",
        rows: reportConfirmRows(report),
        body: "This removes the reported comment from the media comments list. The action cannot be undone from the reports page.",
        confirmLabel: "Remove comment",
        danger: true,
        riskLabel: "Comment removal",
      });
      if (!ok) {
        return;
      }
    }

    this.isReviewing = true;
    this.noticeMessage = "";
    this.noticeTone = "success";

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/reports/${encodeURIComponent(report.id)}/review`, {
        method: "POST",
        body: JSON.stringify({ decision, note: this.reviewNote }),
      });
      this.noticeMessage = data?.message || "Report updated.";
      this.noticeTone = "success";
      this.reviewNote = "";
      await this.loadReports();
      if (data?.report?.id) {
        this.selectedReportId = data.report.id;
      }
    } catch (error) {
      this.noticeMessage = error?.message || "Report review failed.";
      this.noticeTone = "danger";
    } finally {
      this.isReviewing = false;
    }
  }

  @action
  async toggleOwnerBlock(action) {
    const report = this.selectedReport;
    if (!report?.id || this.isReviewing) {
      return;
    }

    let endpoint = "block-owner";
    let confirmText = "Block this uploader from viewing and uploading media?";

    switch (action) {
      case "view-unblock":
        if (this.ownerViewUnblockDisabled) return;
        endpoint = "unblock-owner";
        confirmText = "Remove this uploader from the media view block group?";
        break;
      case "upload-block":
        if (this.ownerUploadBlockDisabled) return;
        endpoint = "block-owner-upload";
        confirmText = "Block this uploader from uploading only? They can still view media if viewer rules allow it.";
        break;
      case "upload-unblock":
        if (this.ownerUploadUnblockDisabled) return;
        endpoint = "unblock-owner-upload";
        confirmText = "Remove this uploader from the media upload block group?";
        break;
      case "view-block":
      case "block":
      default:
        if (this.ownerViewBlockDisabled) return;
        endpoint = "block-owner";
        break;
    }

    const ok = await this._confirmAction({
      title: "Update uploader access",
      subtitle: report?.owner_username || "Uploader access",
      rows: reportConfirmRows(report),
      body: confirmText,
      confirmLabel: String(action || "").includes("unblock") ? "Restore access" : "Update access",
      danger: !String(action || "").includes("unblock"),
      riskLabel: String(action || "").includes("unblock") ? "Access restore" : "Access restriction",
    });
    if (!ok) {
      return;
    }

    this.isReviewing = true;
    this.noticeMessage = "";
    this.noticeTone = "success";

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/reports/${encodeURIComponent(report.id)}/${endpoint}`, {
        method: "POST",
        body: JSON.stringify({ admin_note: this.reviewNote }),
      });
      this.noticeMessage = data?.message || "Uploader access updated.";
      this.noticeTone = "success";
      this.reviewNote = "";
      await this.loadReports();
      if (data?.report?.id) {
        this.selectedReportId = data.report.id;
      }
    } catch (error) {
      this.noticeMessage = error?.message || "Uploader access update failed.";
      this.noticeTone = "danger";
    } finally {
      this.isReviewing = false;
    }
  }

}