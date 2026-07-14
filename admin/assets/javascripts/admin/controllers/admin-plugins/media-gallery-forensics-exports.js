import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function paragraphs(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => String(entry || "").trim()).filter(Boolean);
  }

  return String(value || "")
    .split(/\n{2,}/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function pad(value) {
  return String(value).padStart(2, "0");
}

function formatAdminDateTime(value) {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }

  return `${pad(date.getUTCDate())}-${pad(date.getUTCMonth() + 1)}-${date.getUTCFullYear()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())} UTC`;
}

function trimCsvExtension(filename) {
  return String(filename || "").replace(/\.csv(?:\.gz)?$/i, "") || "—";
}

function displayExportName(filename) {
  const base = trimCsvExtension(filename);
  if (base === "—") {
    return base;
  }

  return base.replace(/^media_gallery_playback_sessions_/i, "");
}

function titleizeStorageLocation(value) {
  switch (String(value || "").toLowerCase()) {
    case "local":
      return "Local";
    case "local+archive":
      return "Local + archive";
    case "archive":
      return "Archive";
    case "database+archive":
      return "Database + archive";
    case "database":
    case "db":
      return "Database";
    default:
      return value ? String(value) : "—";
  }
}

function formatNumber(value) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }

  const number = Number(value);
  if (Number.isNaN(number)) {
    return String(value);
  }

  return new Intl.NumberFormat().format(number);
}

function decorateExport(exp) {
  const rowsCount = Number(exp?.rows_count || 0);
  const isReady = Boolean(exp?.download_ready);

  return {
    ...exp,
    displayName: displayExportName(exp?.filename),
    rowsLabel: formatNumber(rowsCount),
    availabilityLabel: isReady ? "Ready" : "Missing file",
    availabilityClass: isReady ? "is-success" : "is-warning",
    showAvailability: !isReady,
    createdLabel: formatAdminDateTime(exp?.created_at),
    cutoffLabel: formatAdminDateTime(exp?.cutoff_at),
    storageLocationLabel: titleizeStorageLocation(exp?.storage_location),
    csvSizeLabel: formatNumber(exp?.csv_bytes),
    gzipSizeLabel: formatNumber(exp?.gzip_bytes),
    csvShaLabel: exp?.csv_sha256 || "—",
    gzipShaLabel: exp?.gzip_sha256 || "—",
    archiveLabel: exp?.archive_exists ? "Archived" : "Not archived",
    archiveClass: exp?.archive_exists ? "is-success" : "is-info",
    archivedLabel: formatAdminDateTime(exp?.archived_at),
    archiveSizeLabel: formatNumber(exp?.archive_bytes),
  };
}

function clampPage(value, totalPages) {
  const page = Number(value || 1);
  const total = Math.max(Number(totalPages || 1), 1);
  if (!Number.isFinite(page) || page <= 1) {
    return 1;
  }
  return Math.min(Math.floor(page), total);
}


export default class AdminPluginsMediaGalleryForensicsExportsController extends Controller {
  @tracked error = "";
  @tracked notice = "";
  @tracked confirmModal = null;
  @tracked exports = [];
  @tracked page = 1;
  @tracked perPage = 20;
  @tracked totalCount = 0;
  @tracked totalPages = 1;
  @tracked isLoading = false;

  downloadBase = "/admin/plugins/media-gallery/forensics-exports";

  confirmResolver = null;

  get confirmModalOpen() {
    return !!this.confirmModal;
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

  get hasExports() {
    return this.exports.length > 0;
  }

  get countLabel() {
    return `${formatNumber(this.totalCount)} ${this.totalCount === 1 ? "export" : "exports"}`;
  }

  get pageRangeLabel() {
    if (!this.totalCount) {
      return "No exports";
    }

    const start = (this.page - 1) * this.perPage + 1;
    const end = Math.min(this.page * this.perPage, this.totalCount);
    return `${formatNumber(start)}-${formatNumber(end)} of ${formatNumber(this.totalCount)}`;
  }

  get canGoPrevious() {
    return this.page > 1 && !this.isLoading;
  }

  get canGoNext() {
    return this.page < this.totalPages && !this.isLoading;
  }

  get previousDisabled() {
    return !this.canGoPrevious;
  }

  get nextDisabled() {
    return !this.canGoNext;
  }

  async loadExports(page = this.page) {
    const nextPage = clampPage(page, this.totalPages);
    const params = new URLSearchParams();
    params.set("page", String(nextPage));
    params.set("per_page", String(this.perPage));

    this.isLoading = true;
    this.error = "";

    try {
      const response = await fetch(`${this.downloadBase}.json?${params.toString()}`, {
        method: "GET",
        headers: {
          Accept: "application/json",
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        throw new Error(`Load failed (${response.status}): ${err}`);
      }

      const data = await response.json();
      this.exports = Array.isArray(data?.exports) ? data.exports.map(decorateExport) : [];
      this.page = Number(data?.page || nextPage) || 1;
      this.perPage = Number(data?.per_page || this.perPage) || this.perPage;
      this.totalCount = Number(data?.total_count || this.exports.length) || 0;
      this.totalPages = Math.max(Number(data?.total_pages || 1) || 1, 1);
    } catch (e) {
      this.error = e?.message || String(e);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  loadCurrentPage() {
    return this.loadExports(this.page);
  }

  @action
  previousPage() {
    if (this.canGoPrevious) {
      return this.loadExports(this.page - 1);
    }
  }

  @action
  nextPage() {
    if (this.canGoNext) {
      return this.loadExports(this.page + 1);
    }
  }

  @action
  updatePerPage(event) {
    const value = Number(event?.target?.value || 20);
    this.perPage = [10, 20, 50].includes(value) ? value : 20;
    return this.loadExports(1);
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }

  async _extractError(response) {
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) {
        return json.errors.join(" ");
      }
      if (json?.error) {
        return String(json.error);
      }
      if (json?.message) {
        return String(json.message);
      }
    } catch {}

    try {
      const text = await response.text();
      if (text) {
        return text.length > 500 ? `${text.slice(0, 500)}…` : text;
      }
    } catch {}

    return `HTTP ${response.status}`;
  }

  _downloadFilenameFromHeaders(headers, fallbackName) {
    const cd = headers?.get?.("Content-Disposition") || headers?.get?.("content-disposition") || "";
    const utf8Match = cd.match(/filename\*=UTF-8''([^;]+)/i);
    if (utf8Match?.[1]) {
      try {
        return decodeURIComponent(utf8Match[1]);
      } catch {
        return utf8Match[1];
      }
    }

    const basicMatch = cd.match(/filename="?([^";]+)"?/i);
    if (basicMatch?.[1]) {
      return basicMatch[1];
    }

    return fallbackName || "download";
  }

  @action
  async deleteExport(exp) {
    const base = this.downloadBase || "/admin/plugins/media-gallery/forensics-exports";
    const id = exp?.id;
    if (!id) {
      return;
    }

    const label = String(exp?.displayName || exp?.filename || `export ${id}`);
    const ok = await this._confirmAction({
      title: "Delete forensic export",
      subtitle: label,
      body: "This removes the database record and stored export/archive files. This cannot be undone.",
      confirmLabel: "Delete export",
      danger: true,
    });
    if (!ok) {
      return;
    }

    this.error = "";
    this.notice = "";

    try {
      const response = await fetch(`${base}/${encodeURIComponent(String(id))}`, {
        method: "DELETE",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": this._csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        throw new Error(`Delete failed (${response.status}): ${err}`);
      }

      this.notice = "Forensic export deleted.";
      const nextPage = this.exports.length <= 1 && this.page > 1 ? this.page - 1 : this.page;
      await this.loadExports(nextPage);
    } catch (e) {
      this.error = e?.message || String(e);
    }
  }

  @action
  async downloadExport(exp, gz = false) {
    const base = this.downloadBase || "/admin/plugins/media-gallery/forensics-exports";
    const id = exp?.id;
    if (!id) {
      return;
    }

    const filename = String(exp?.filename || `media_gallery_export_${id}.csv`);
    const fallbackName = gz ? (filename.endsWith('.gz') ? filename : `${filename}.gz`) : filename;
    const url = `${base}/${encodeURIComponent(String(id))}${gz ? '?gz=1' : ''}`;

    this.error = "";
    this.notice = "";

    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          Accept: gz ? "application/gzip,application/octet-stream;q=0.9,*/*;q=0.5" : "text/csv,application/octet-stream;q=0.9,*/*;q=0.5",
          "X-CSRF-Token": this._csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        throw new Error(`Download failed (${response.status}): ${err}`);
      }

      const blob = await response.blob();
      const objectUrl = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = objectUrl;
      anchor.download = this._downloadFilenameFromHeaders(response.headers, fallbackName);
      anchor.style.display = "none";
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
      this.notice = "Download started.";
    } catch (e) {
      this.error = e?.message || String(e);
    }
  }
}
