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

function decisionLabel(value) {
  switch (String(value || "")) {
    case "accept_hide":
      return "Accepted / hidden";
    case "accept_delete_asset":
      return "Accepted / files deleted";
    case "reject":
      return "Rejected";
    case "resolve":
      return "Resolved without action";
    default:
      return "—";
  }
}

export default class AdminPluginsMediaGalleryReportsController extends Controller {
  @tracked statusFilter = "open";
  @tracked searchQuery = "";
  @tracked limit = "50";
  @tracked reports = [];
  @tracked isLoading = false;
  @tracked loadError = "";
  @tracked noticeMessage = "";
  @tracked noticeTone = "success";
  @tracked selectedReportId = "";
  @tracked isReviewing = false;
  @tracked reviewNote = "";

  abortController = null;

  resetState() {
    this.statusFilter = "open";
    this.searchQuery = "";
    this.limit = "50";
    this.reports = [];
    this.isLoading = false;
    this.loadError = "";
    this.noticeMessage = "";
    this.noticeTone = "success";
    this.selectedReportId = "";
    this.isReviewing = false;
    this.reviewNote = "";
  }

  async loadInitial() {
    await this.loadReports();
  }

  willDestroy() {
    this.abortController?.abort?.();
    super.willDestroy(...arguments);
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

  get reviewDisabled() {
    return !this.hasSelectedReport || !this.selectedIsOpen || this.isReviewing;
  }

  get selectedOwnerAccess() {
    return this.selectedReport?.owner_access || {};
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
            : status === "resolved"
              ? "is-success"
              : "",
        hiddenLabel: media.hidden ? "Hidden" : "Visible",
        hiddenBadgeClass: media.hidden ? "is-danger" : "is-success",
        assetLabel: media.asset_deleted ? "Files deleted" : "Files present",
        assetBadgeClass: media.asset_deleted ? "is-danger" : "",
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
    if (String(this.searchQuery || "").trim()) {
      params.set("q", String(this.searchQuery || "").trim());
    }

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/reports?${params.toString()}`, {
        method: "GET",
        signal: this.abortController.signal,
      });
      this.reports = Array.isArray(data?.reports) ? data.reports : [];
      if (!this.reports.some((report) => report.id === this.selectedReportId)) {
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
    this.searchQuery = "";
    this.limit = "50";
    this.loadReports();
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

    if (decision === "accept_delete_asset") {
      const ok = window.confirm(
        "Delete the stored asset files for this media item? The report, media snapshot, checksum data, and audit history will be kept, but the playable/viewable files will be removed."
      );
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

    const ok = window.confirm(confirmText);
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