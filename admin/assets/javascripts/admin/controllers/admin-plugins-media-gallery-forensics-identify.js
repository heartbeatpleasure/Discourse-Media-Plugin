import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { i18n } from "discourse-i18n";

export default class AdminPluginsMediaGalleryForensicsIdentifyController extends Controller {
  @tracked publicId = "";
  @tracked file = null;
  @tracked sourceUrl = "";
  @tracked maxSamples = 60;
  @tracked maxOffsetSegments = 30;
  @tracked layout = "";
  @tracked isRunning = false;

  // Raw + parsed result
  @tracked result = null;
  @tracked resultJson = "";
  @tracked error = "";

  get hasResult() {
    return !!this.result;
  }

  get meta() {
    return this.result?.meta;
  }

  get candidates() {
    return this.result?.candidates || [];
  }

  get observedVariants() {
    return this.result?.observed?.variants || "";
  }

  get samples() {
    return this.meta?.samples ?? 0;
  }

  get usableSamples() {
    return this.meta?.usable_samples ?? 0;
  }

  get weakSignal() {
    // Heuristic: if we have almost no usable samples, matching will be unreliable.
    return this.usableSamples === 0 || this.usableSamples < 5;
  }

  @action
  onPublicIdInput(event) {
    this.publicId = (event?.target?.value || "").trim();
  }

  @action
  onFileChange(event) {
    const files = event?.target?.files;
    this.file = files && files.length ? files[0] : null;
  }

  @action
  onSourceUrlInput(event) {
    this.sourceUrl = (event?.target?.value || "").trim();
  }

  @action
  onMaxSamplesInput(event) {
    const v = parseInt(event?.target?.value, 10);
    this.maxSamples = Number.isFinite(v) ? v : 60;
  }

  @action
  onMaxOffsetInput(event) {
    const v = parseInt(event?.target?.value, 10);
    this.maxOffsetSegments = Number.isFinite(v) ? v : 30;
  }

  @action
  onLayoutChange(event) {
    this.layout = event?.target?.value || "";
  }

  @action
  clear() {
    this.error = "";
    this.result = null;
    this.resultJson = "";
  }

  async _extractError(response) {
    // Try JSON error first, then fall back to text.
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) {
        return json.errors.join(" ");
      }
      if (json?.error) {
        return String(json.error);
      }
    } catch {
      // ignore
    }

    try {
      const text = await response.text();
      if (text) {
        // Keep it short-ish.
        return text.length > 500 ? `${text.slice(0, 500)}…` : text;
      }
    } catch {
      // ignore
    }

    return `HTTP ${response.status}`;
  }

  @action
  async identify() {
    this.error = "";
    this.result = null;
    this.resultJson = "";

    if (!this.publicId) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_public_id");
      return;
    }

    const hasUrl = !!this.sourceUrl;
    const hasFile = !!this.file;

    if (!hasUrl && !hasFile) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_file_or_url");
      return;
    }

    const csrfToken = document
      .querySelector("meta[name='csrf-token']")
      ?.getAttribute("content");

    const form = new FormData();
    if (hasFile) {
      form.append("file", this.file);
    }
    if (hasUrl) {
      form.append("source_url", this.sourceUrl);
    }

    form.append("max_samples", String(this.maxSamples || 60));
    form.append("max_offset_segments", String(this.maxOffsetSegments || 30));
    if (this.layout) {
      form.append("layout", this.layout);
    }

    const url = `/admin/plugins/media-gallery/forensics-identify/${encodeURIComponent(
      this.publicId
    )}.json`;

    this.isRunning = true;
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
          Accept: "application/json",
        },
        body: form,
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.error = `HTTP ${response.status}: ${err}`;
        return;
      }

      const json = await response.json();
      this.result = json;
      this.resultJson = JSON.stringify(json, null, 2);
    } catch (e) {
      this.error = e?.message || String(e);
    } finally {
      this.isRunning = false;
    }
  }
}
