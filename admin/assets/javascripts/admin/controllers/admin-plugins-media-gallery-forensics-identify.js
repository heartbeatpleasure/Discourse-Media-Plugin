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
  @tracked autoExtend = true;
  @tracked isRunning = false;

  // public_id finder
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  _searchTimer = null;

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

  get topCandidates() {
    const cands = this.candidates || [];
    const top = this.topMatchRatio;
    return cands.slice(0, 3).map((c, idx) => {
      const v = c?.match_ratio;
      const mr = typeof v === "number" ? v : parseFloat(v);
      const matchRatio = Number.isFinite(mr) ? mr : 0;
      return {
        ...c,
        _idx: idx,
        delta_from_top: idx === 0 ? 0 : Math.max(0, top - matchRatio),
      };
    });
  }

  get topCandidate() {
    return this.candidates?.[0] || null;
  }

  get secondCandidate() {
    return this.candidates?.[1] || null;
  }

  get topMatchRatio() {
    const v = this.topCandidate?.match_ratio;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : 0;
  }

  get secondMatchRatio() {
    const v = this.secondCandidate?.match_ratio;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : 0;
  }

  get matchDelta() {
    return Math.max(0, this.topMatchRatio - this.secondMatchRatio);
  }

  get confidence() {
    const usable = this.usableSamples;
    const top = this.topMatchRatio;
    const delta = this.matchDelta;

    if (!this.candidates?.length || usable < 5 || top <= 0) {
      return "none";
    }

    // Heuristics: we care about (1) enough usable samples, (2) a high match ratio,
    // and (3) clear separation from #2.
    if (usable >= 12 && top >= 0.85 && delta >= 0.2) {
      return "strong";
    }

    if (usable >= 8 && top >= 0.7 && delta >= 0.15) {
      return "medium";
    }

    if (usable >= 5 && top >= 0.55 && delta >= 0.1) {
      return "weak";
    }

    return "none";
  }

  get confidenceClass() {
    switch (this.confidence) {
      case "strong":
        return "alert-success";
      case "medium":
        return "alert-info";
      case "weak":
        return "alert-warning";
      default:
        return "alert-error";
    }
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

  get showWeakTip() {
    return this.weakSignal || this.confidence === "weak" || this.confidence === "none";
  }

  get isAmbiguous() {
    return (this.candidates?.length || 0) > 1 && this.matchDelta < 0.1;
  }

  get attempts() {
    return this.meta?.attempts ?? 1;
  }

  get autoExtended() {
    return !!this.meta?.auto_extended;
  }

  get maxSamplesUsed() {
    return this.meta?.max_samples_used ?? null;
  }

  get hasMoreCandidates() {
    return (this.candidates?.length || 0) > 3;
  }

  get showNoSearchMatches() {
    const q = this.searchQuery || "";
    return (
      !this.isSearching &&
      q.length >= 3 &&
      (this.searchResults?.length || 0) === 0 &&
      !this.searchError
    );
  }

  @action
  onPublicIdInput(event) {
    this.publicId = (event?.target?.value || "").trim();
  }

  @action
  onSearchInput(event) {
    this.searchQuery = (event?.target?.value || "").trim();
    this._debouncedSearch();
  }

  _debouncedSearch() {
    if (this._searchTimer) {
      clearTimeout(this._searchTimer);
    }

    this._searchTimer = setTimeout(() => {
      this._searchTimer = null;
      this.search();
    }, 300);
  }

  async search() {
    this.searchError = "";
    this.isSearching = true;
    try {
      const q = this.searchQuery;
      // If user typed something very short, don't spam the server.
      // Empty query is allowed: it returns recent items.
      if (q && q.length < 3) {
        this.searchResults = [];
        return;
      }

      const url = `/admin/plugins/media-gallery/media-items/search.json?q=${encodeURIComponent(
        q || ""
      )}`;
      const response = await fetch(url, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.searchError = `HTTP ${response.status}: ${err}`;
        this.searchResults = [];
        return;
      }

      const json = await response.json();
      this.searchResults = Array.isArray(json?.items) ? json.items : [];
    } catch (e) {
      this.searchError = e?.message || String(e);
      this.searchResults = [];
    } finally {
      this.isSearching = false;
    }
  }

  @action
  pickPublicId(item) {
    const pid = item?.public_id;
    if (pid) {
      this.publicId = pid;
    }
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
  onAutoExtendChange(event) {
    this.autoExtend = !!event?.target?.checked;
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
    form.append("auto_extend", this.autoExtend ? "1" : "0");

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
