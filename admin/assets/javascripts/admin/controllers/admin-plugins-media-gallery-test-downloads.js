import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

const DEFAULT_BACKEND_FILTER = "";
const DEFAULT_STATUS_FILTER = "ready";
const DEFAULT_SORT = "newest";
const DEFAULT_LIMIT = "24";
const DEFAULT_HAS_HLS_FILTER = "true";

export default class AdminPluginsMediaGalleryTestDownloadsController extends Controller {
  @tracked searchQuery = "";
  @tracked backendFilter = DEFAULT_BACKEND_FILTER;
  @tracked statusFilter = DEFAULT_STATUS_FILTER;
  @tracked sort = DEFAULT_SORT;
  @tracked limit = DEFAULT_LIMIT;
  @tracked hasHlsFilter = DEFAULT_HAS_HLS_FILTER;
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked hasSearched = false;
  @tracked searchInfo = "";

  @tracked publicId = "";
  @tracked selectedItem = null;
  @tracked selectionMessage = "";
  @tracked selectionMessageTone = "info";

  @tracked users = [];
  @tracked isLoadingUsers = false;
  @tracked usersError = "";
  @tracked selectedUserId = "";
  @tracked manualUserId = "";

  @tracked isGenerating = false;
  @tracked generateError = "";
  @tracked artifacts = [];

  _didInitialLoad = false;

  resetState() {
    this.searchQuery = "";
    this.backendFilter = DEFAULT_BACKEND_FILTER;
    this.statusFilter = DEFAULT_STATUS_FILTER;
    this.sort = DEFAULT_SORT;
    this.limit = DEFAULT_LIMIT;
    this.hasHlsFilter = DEFAULT_HAS_HLS_FILTER;
    this.searchResults = [];
    this.isSearching = false;
    this.searchError = "";
    this.hasSearched = false;
    this.searchInfo = "";

    this.publicId = "";
    this.selectedItem = null;
    this.selectionMessage = "";
    this.selectionMessageTone = "info";

    this.users = [];
    this.isLoadingUsers = false;
    this.usersError = "";
    this.selectedUserId = "";
    this.manualUserId = "";

    this.isGenerating = false;
    this.generateError = "";
    this.artifacts = [];
    this._didInitialLoad = false;
  }

  get hasSelectedItem() {
    return !!(this.publicId || "").trim();
  }

  get hasSearchQuery() {
    return (this.searchQuery || "").trim().length > 0;
  }

  get showNoResults() {
    return this.hasSearched && !this.isSearching && !this.searchError && (this.searchResults?.length || 0) === 0;
  }

  get canUseTypedPublicId() {
    return this.hasSearchQuery && !this.isLoadingUsers && !this.isGenerating;
  }

  get searchButtonDisabled() {
    return this.isSearching;
  }

  get useTypedPublicIdDisabled() {
    return !this.canUseTypedPublicId;
  }

  get resolvedUserId() {
    const fromSelect = parseInt(this.selectedUserId, 10);
    if (Number.isFinite(fromSelect) && fromSelect > 0) {
      return fromSelect;
    }
    const manual = parseInt(this.manualUserId, 10);
    return Number.isFinite(manual) && manual > 0 ? manual : null;
  }

  get canGenerate() {
    return !!this.publicId && !!this.resolvedUserId && !this.isGenerating;
  }

  get hasArtifacts() {
    return (this.artifacts?.length || 0) > 0;
  }

  get showNoUsersWarning() {
    return this.hasSelectedItem && !this.isLoadingUsers && !this.usersError && (this.users?.length || 0) === 0;
  }

  get generateDisabled() {
    return !this.canGenerate;
  }

  get selectionMessageClass() {
    return `mg-test-downloads__notice is-${this.selectionMessageTone || "info"}`;
  }

  _humanize(value) {
    const text = (value || "").toString().trim();
    if (!text) {
      return "";
    }

    return text
      .replace(/[_-]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/\b\w/g, (match) => match.toUpperCase());
  }

  _formatDate(value) {
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

  _backendLabel(value) {
    switch ((value || "").toString()) {
      case "local":
        return "Local";
      case "s3":
        return "S3";
      default:
        return value ? this._humanize(value) : "Unknown";
    }
  }

  _statusTone(value) {
    switch ((value || "").toString()) {
      case "ready":
        return "success";
      case "failed":
        return "danger";
      case "processing":
      case "queued":
        return "warning";
      default:
        return "neutral";
    }
  }

  _setSelectionMessage(message, tone = "info") {
    this.selectionMessage = message || "";
    this.selectionMessageTone = tone || "info";
  }

  _normalizeItem(item) {
    const publicId = (item?.public_id || "").toString();
    const title = (item?.title || "").toString().trim() || "Untitled video";
    const username = (item?.username || "").toString().trim();
    const userId = item?.user_id;
    const owner = username ? `${username}${userId ? ` (#${userId})` : ""}` : (userId ? `User #${userId}` : "Unknown owner");
    const status = (item?.status || "").toString();
    const mediaType = (item?.media_type || "video").toString();

    return {
      ...item,
      public_id: publicId,
      displayTitle: title,
      displayOwner: owner,
      displayPublicId: publicId,
      displayCreatedAt: this._formatDate(item?.created_at),
      displayUpdatedAt: this._formatDate(item?.updated_at),
      displayStatus: this._humanize(status || "unknown"),
      displayMediaType: this._humanize(mediaType || "video"),
      displayBackend: this._backendLabel(item?.managed_storage_backend),
      statusTone: this._statusTone(status),
      statusClassName: `is-${this._statusTone(status)}`,
      hasHlsLabel: item?.has_hls ? "HLS ready" : "No HLS",
      hiddenLabel: item?.hidden ? "Hidden" : "Visible",
      isSelected: publicId && publicId === this.publicId,
    };
  }

  _normalizeArtifact(artifact) {
    if (!artifact) {
      return null;
    }

    const region = artifact?.random_clip_region
      ? `${this._humanize(artifact.random_clip_region)}${artifact?.clip_percent_of_video ? ` (${artifact.clip_percent_of_video}%)` : ""}`
      : "";

    return {
      ...artifact,
      displayTitle: (artifact?.title || artifact?.displayTitle || "").toString().trim() || null,
      displayCreatedAt: this._formatDate(artifact?.created_at),
      displayMode: this._humanize(artifact?.mode || "full"),
      displayUser: artifact?.username ? `${artifact.username} (#${artifact.user_id})` : `User #${artifact?.user_id}`,
      displaySegments:
        artifact?.start_segment != null && artifact?.segment_count != null
          ? `Start ${artifact.start_segment} · Count ${artifact.segment_count}${artifact?.total_segments != null ? ` of ${artifact.total_segments}` : ""}`
          : "—",
      displayRegion: region,
    };
  }

  _markSelectedResults() {
    const selectedPublicId = (this.publicId || "").trim();
    this.searchResults = (this.searchResults || []).map((item) => ({
      ...item,
      isSelected: !!selectedPublicId && item.public_id === selectedPublicId,
    }));
  }

  async loadInitialResults() {
    if (this._didInitialLoad) {
      return;
    }

    this._didInitialLoad = true;
    await this.search();
  }

  @action
  onSearchInput(event) {
    this.searchQuery = event?.target?.value || "";
    this.searchError = "";
  }

  @action
  onSearchKeydown(event) {
    if (event?.key === "Enter") {
      event.preventDefault();
      this.search();
    }
  }

  @action
  onBackendChange(event) {
    this.backendFilter = event?.target?.value || "";
  }

  @action
  onStatusChange(event) {
    this.statusFilter = event?.target?.value || "";
  }

  @action
  onSortChange(event) {
    this.sort = event?.target?.value || DEFAULT_SORT;
  }

  @action
  onLimitChange(event) {
    this.limit = event?.target?.value || DEFAULT_LIMIT;
  }

  @action
  onHasHlsChange(event) {
    this.hasHlsFilter = event?.target?.value || DEFAULT_HAS_HLS_FILTER;
  }

  @action
  async clearSearch() {
    this.searchQuery = "";
    this.backendFilter = DEFAULT_BACKEND_FILTER;
    this.statusFilter = DEFAULT_STATUS_FILTER;
    this.sort = DEFAULT_SORT;
    this.limit = DEFAULT_LIMIT;
    this.hasHlsFilter = DEFAULT_HAS_HLS_FILTER;
    await this.search();
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
    } catch {
      // ignore
    }

    try {
      const text = await response.text();
      if (text) {
        return text.length > 500 ? `${text.slice(0, 500)}…` : text;
      }
    } catch {
      // ignore
    }

    return `HTTP ${response.status}`;
  }

  _buildSearchParams() {
    const params = new URLSearchParams();
    const q = (this.searchQuery || "").trim();

    if (q) {
      params.set("q", q);
    }

    params.set("media_type", "video");
    params.set("limit", this.limit || DEFAULT_LIMIT);

    if (this.backendFilter) {
      params.set("backend", this.backendFilter);
    }

    if (this.statusFilter) {
      params.set("status", this.statusFilter);
    }

    if (this.hasHlsFilter) {
      params.set("has_hls", this.hasHlsFilter);
    }

    if (this.sort && this.sort !== "newest") {
      params.set("sort", this.sort);
    }

    return params;
  }

  @action
  async search() {
    this.searchError = "";
    this.searchInfo = "";
    this.isSearching = true;
    this.hasSearched = true;

    try {
      const url = `/admin/plugins/media-gallery/media-items/search.json?${this._buildSearchParams().toString()}`;
      const response = await fetch(url, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.searchError = `Search failed (${response.status}): ${err}`;
        this.searchResults = [];
        return;
      }

      const json = await response.json();
      const items = Array.isArray(json?.items) ? json.items : [];
      this.searchResults = items.map((item) => this._normalizeItem(item));
      this._markSelectedResults();

      const noun = this.searchResults.length === 1 ? "video" : "videos";
      this.searchInfo = `${this.searchResults.length} ${noun} shown`;
      if ((this.searchQuery || "").trim()) {
        this.searchInfo += ` for “${(this.searchQuery || "").trim()}”`;
      }
      if (this.hasHlsFilter === "true") {
        this.searchInfo += " · HLS ready only";
      }
    } catch (e) {
      this.searchError = e?.message || String(e);
      this.searchResults = [];
    } finally {
      this.isSearching = false;
    }
  }

  async _selectPublicId(publicId, item = null) {
    const trimmed = (publicId || "").trim();
    if (!trimmed) {
      return;
    }

    this.selectedItem = item ? this._normalizeItem(item) : {
      public_id: trimmed,
      displayTitle: "Selected video",
      displayOwner: "Unknown owner",
      displayPublicId: trimmed,
      displayCreatedAt: "—",
      displayUpdatedAt: "—",
      displayStatus: "Unknown",
      displayMediaType: "Video",
      displayBackend: "Unknown",
      statusTone: "neutral",
      statusClassName: "is-neutral",
      hasHlsLabel: "Unknown",
      hiddenLabel: "Unknown",
      thumbnail_url: null,
      isSelected: true,
    };
    this.publicId = trimmed;
    this.users = [];
    this.selectedUserId = "";
    this.manualUserId = "";
    this.usersError = "";
    this.generateError = "";
    this._setSelectionMessage(`Selected video ${trimmed}. Loading user options…`, "info");
    this._markSelectedResults();
    await this.loadUsers();
  }

  @action
  async pickItem(item) {
    await this._selectPublicId(item?.public_id, item || null);
  }

  @action
  async useTypedPublicId() {
    const q = (this.searchQuery || "").trim();
    if (!q) {
      this._setSelectionMessage("Enter a public_id in the search field first.", "warning");
      return;
    }

    const exact = (this.searchResults || []).find((item) => item?.public_id === q) || null;
    await this._selectPublicId(q, exact);
  }

  @action
  onManualUserIdInput(event) {
    this.manualUserId = (event?.target?.value || "").trim();
  }

  @action
  onUserSelect(event) {
    this.selectedUserId = event?.target?.value || "";
  }

  async loadUsers() {
    if (!this.publicId) {
      this.usersError = "No public_id selected yet.";
      return;
    }

    this.isLoadingUsers = true;
    this.usersError = "";
    try {
      const response = await fetch(
        `/admin/plugins/media-gallery/fingerprints/${encodeURIComponent(this.publicId)}.json`,
        {
          method: "GET",
          headers: { Accept: "application/json" },
          credentials: "same-origin",
        }
      );

      if (!response.ok) {
        const err = await this._extractError(response);
        this.usersError = `Load users failed (${response.status}): ${err}`;
        this.users = [];
        this._setSelectionMessage(`Selected video ${this.publicId}, but loading users failed.`, "danger");
        return;
      }

      const json = await response.json();
      const byId = new Map();
      for (const fp of json?.fingerprints || []) {
        if (fp?.user_id) {
          byId.set(fp.user_id, { id: fp.user_id, username: fp.username || `user_${fp.user_id}` });
        }
      }
      for (const s of json?.playback_sessions || []) {
        if (s?.user_id && !byId.has(s.user_id)) {
          byId.set(s.user_id, { id: s.user_id, username: s.username || `user_${s.user_id}` });
        }
      }
      this.users = Array.from(byId.values()).sort((a, b) =>
        (a.username || "").localeCompare(b.username || "")
      );
      if (!this.selectedUserId && this.users.length === 1) {
        this.selectedUserId = String(this.users[0].id);
      }
      this._setSelectionMessage(`Selected video ${this.publicId}. ${this.users.length} user option(s) loaded.`, "success");
    } catch (e) {
      this.usersError = e?.message || String(e);
      this.users = [];
      this._setSelectionMessage(`Selected video ${this.publicId}, but loading users failed.`, "danger");
    } finally {
      this.isLoadingUsers = false;
    }
  }

  _csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  }

  _pushArtifact(artifact) {
    const matchedItem = (this.searchResults || []).find((item) => item?.public_id === artifact?.public_id) || (this.selectedItem?.public_id === artifact?.public_id ? this.selectedItem : null);
    const normalized = this._normalizeArtifact({
      ...(artifact || {}),
      title: artifact?.title || matchedItem?.displayTitle || matchedItem?.title || null,
    });
    if (!normalized) {
      return;
    }
    this.artifacts = [normalized, ...(this.artifacts || [])];
  }

  async _pollTask(taskId, statusUrl) {
    for (let attempt = 0; attempt < 180; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 1000));

      const response = await fetch(statusUrl, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });

      const json = await response.json().catch(() => null);
      if (!response.ok) {
        const err = json?.error || json?.message || (await this._extractError(response));
        this.generateError = String(err);
        this._setSelectionMessage(this.generateError, "danger");
        return;
      }

      const status = json?.status || "queued";
      if (status === "queued" || status === "working") {
        this._setSelectionMessage(`Generating artifact for ${this.publicId}… (${status})`, "info");
        continue;
      }

      if (status === "complete" && json?.artifact) {
        this._pushArtifact(json.artifact);
        this._setSelectionMessage(`Artifact generated for ${this.publicId}. Use Download below.`, "success");
        return;
      }

      if (status === "failed") {
        this.generateError = String(json?.error || "Generation failed.");
        this._setSelectionMessage(this.generateError, "danger");
        return;
      }

      this.generateError = `Unexpected task state for ${taskId}: ${status}`;
      this._setSelectionMessage(this.generateError, "danger");
      return;
    }

    this.generateError = "Timed out while waiting for artifact generation.";
    this._setSelectionMessage(this.generateError, "danger");
  }

  async _generate(payload) {
    if (!this.publicId || !this.resolvedUserId) {
      this.generateError = "Select a video and user first.";
      this._setSelectionMessage(this.generateError, "danger");
      return;
    }

    this.isGenerating = true;
    this.generateError = "";
    this._setSelectionMessage("", "info");

    try {
      const response = await fetch(
        `/admin/plugins/media-gallery/test-downloads/${encodeURIComponent(this.publicId)}`,
        {
          method: "POST",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-CSRF-Token": this._csrfToken(),
          },
          credentials: "same-origin",
          body: JSON.stringify({
            user_id: this.resolvedUserId,
            ...payload,
          }),
        }
      );

      const json = await response.json().catch(() => null);
      if (!response.ok) {
        const err = json?.error || json?.message || (await this._extractError(response));
        this.generateError = String(err);
        return;
      }

      if (json?.ok && json?.queued && json?.task_id && json?.status_url) {
        this._setSelectionMessage(`Queued generation for ${this.publicId}.`, "info");
        await this._pollTask(json.task_id, json.status_url);
        return;
      }

      if (json?.ok && json?.artifact) {
        this._pushArtifact(json.artifact);
        this._setSelectionMessage(`Artifact generated for ${this.publicId}. Use Download below.`, "success");
        return;
      }

      const err = json?.error || json?.message || "Generation failed.";
      this.generateError = String(err);
      this._setSelectionMessage(this.generateError, "danger");
    } catch (e) {
      this.generateError = e?.message || String(e);
      this._setSelectionMessage(this.generateError, "danger");
    } finally {
      this.isGenerating = false;
    }
  }

  _downloadFilenameFromHeaders(headers, fallbackName = "download.mp4") {
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

    return fallbackName;
  }

  _fallbackArtifactFilename(artifact) {
    const parts = [
      artifact?.public_id,
      artifact?.username,
      artifact?.mode,
      artifact?.random_clip_region,
      artifact?.start_segment != null ? `s${artifact.start_segment}` : null,
      artifact?.segment_count != null ? `n${artifact.segment_count}` : null,
    ].filter(Boolean);

    const base = parts.join("-").replace(/[^a-zA-Z0-9._-]+/g, "_") || "artifact";
    return `${base}.mp4`;
  }

  @action
  async downloadArtifact(artifact) {
    if (!artifact?.download_url) {
      this.generateError = "Download URL is missing for this artifact.";
      return;
    }

    this.generateError = "";

    try {
      const response = await fetch(artifact.download_url, {
        method: "GET",
        headers: {
          Accept: "video/mp4,application/octet-stream;q=0.9,*/*;q=0.5",
          "X-Requested-With": "XMLHttpRequest",
          "X-CSRF-Token": this._csrfToken(),
        },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.generateError = `Download failed (${response.status}): ${err}`;
        return;
      }

      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const filename = this._downloadFilenameFromHeaders(
        response.headers,
        this._fallbackArtifactFilename(artifact)
      );

      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      anchor.style.display = "none";
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();

      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) {
      this.generateError = e?.message || String(e);
      this._setSelectionMessage(this.generateError, "danger");
    }
  }

  @action
  async generateFull() {
    await this._generate({ mode: "full" });
  }

  @action
  async generateRandomPartial() {
    await this._generate({ mode: "random_partial" });
  }
}
