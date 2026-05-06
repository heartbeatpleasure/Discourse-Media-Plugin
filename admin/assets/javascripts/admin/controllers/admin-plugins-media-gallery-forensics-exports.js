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

export default class AdminPluginsMediaGalleryForensicsExportsController extends Controller {
  @tracked error = "";
  @tracked notice = "";
  @tracked confirmModal = null;

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

      this.set("exports", (this.exports || []).filter((item) => String(item.id) !== String(id)));
      this.notice = "Forensic export deleted.";
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
