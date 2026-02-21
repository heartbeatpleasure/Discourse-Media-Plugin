import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { i18n } from "discourse-i18n";

export default class AdminPluginsMediaGalleryForensicsIdentifyController extends Controller {
  @tracked publicId = "";
  @tracked file = null;
  @tracked maxSamples = 60;
  @tracked maxOffsetSegments = 30;
  @tracked layout = "";
  @tracked isRunning = false;
  @tracked resultJson = "";
  @tracked error = "";

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
  async identify() {
    this.error = "";
    this.resultJson = "";

    if (!this.publicId) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_public_id");
      return;
    }

    if (!this.file) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_file");
      return;
    }

    const csrfToken = document
      .querySelector("meta[name='csrf-token']")
      ?.getAttribute("content");

    const form = new FormData();
    form.append("file", this.file);
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
        const text = await response.text();
        this.error = `HTTP ${response.status}: ${text}`;
        return;
      }

      const json = await response.json();
      this.resultJson = JSON.stringify(json, null, 2);
    } catch (e) {
      this.error = e?.message || String(e);
    } finally {
      this.isRunning = false;
    }
  }
}
