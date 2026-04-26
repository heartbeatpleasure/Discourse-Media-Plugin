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
      return "Accepted / asset deleted";
    case "reject":
      return "Rejected";
    case "resolve":
      return "Resolved";
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
        statusLabel: titleize(status),
        decisionLabel: decisionLabel(report?.decision),
        mediaTitle: media.title || report?.item_snapshot?.title || "Untitled media",
        mediaPublicId: media.public_id || report?.item_snapshot?.public_id || "—",
        mediaUploader: media.uploader_username || report?.item_snapshot?.uploader_username || "—",
        mediaCreatedAt: formatDateTime(media.created_at || report?.item_snapshot?.created_at),
        mediaTypeLabel: titleize(media.media_type || report?.item_snapshot?.media_type),
        reporterLabel: report?.reporter_username ? `${report.reporter_username} (TL${report.reporter_trust_level ?? "—"})` : "—",
        statusBadgeClass:
          status === "open"
            ? "is-warning"
            : status === "accepted"
              ? "is-danger"
              : status === "rejected"
                ? ""
                : "is-success",
        hiddenLabel: media.hidden ? "Hidden" : "Visible",
        hiddenBadgeClass: media.hidden ? "is-danger" : "is-success",
        assetLabel: media.asset_deleted ? "Asset deleted" : "Asset retained",
        assetBadgeClass: media.asset_deleted ? "is-danger" : "",
      };
    });
  }

  get selectedSnapshotRows() {
    const snapshot = this.selectedReport?.item_snapshot || {};
    return [
      { label: "Public ID", value: snapshot.public_id || "—" },
      { label: "Title", value: snapshot.title || "—" },
      { label: "Uploader", value: snapshot.uploader_username ? `${snapshot.uploader_username} (#${snapshot.uploader_user_id || "—"})` : "—" },
      { label: "Media type", value: titleize(snapshot.media_type) || "—" },
      { label: "File contains", value: titleize(snapshot.gender) || "—" },
      { label: "Original filename", value: snapshot.original_filename || "—" },
      { label: "Original SHA1", value: snapshot.original_upload_sha1 || "—" },
      { label: "Processed SHA1", value: snapshot.processed_upload_sha1 || "—" },
      { label: "Original size", value: formatBytes(snapshot.filesize_original_bytes || snapshot.original_upload_filesize) },
      { label: "Processed size", value: formatBytes(snapshot.filesize_processed_bytes || snapshot.processed_upload_filesize) },
      { label: "Storage", value: [snapshot.managed_storage_backend, snapshot.managed_storage_profile].filter(Boolean).join(" / ") || "—" },
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
        "Delete the underlying asset files for this media item? The report and media audit record will be kept, but the file itself will be removed."
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
}
