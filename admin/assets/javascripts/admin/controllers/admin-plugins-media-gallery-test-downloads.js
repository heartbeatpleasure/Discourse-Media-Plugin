import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

const MEDIA_TYPE_OPTIONS = Object.freeze([
  { value: "video", label: "Video" },
  { value: "audio", label: "Audio" },
  { value: "image", label: "Image" },
  { value: "", label: "All types" },
]);

const STATUS_OPTIONS = Object.freeze([
  { value: "", label: "All statuses" },
  { value: "ready", label: "Ready" },
  { value: "processing", label: "Processing" },
  { value: "queued", label: "Queued" },
  { value: "failed", label: "Failed" },
]);

const BACKEND_OPTIONS = Object.freeze([
  { value: "", label: "All backends" },
  { value: "local", label: "Local" },
  { value: "s3", label: "S3" },
]);

const SORT_OPTIONS = Object.freeze([
  { value: "", label: "Newest" },
  { value: "oldest", label: "Oldest" },
  { value: "updated_desc", label: "Recently updated" },
  { value: "title_asc", label: "Title A–Z" },
  { value: "title_desc", label: "Title Z–A" },
]);

const LIMIT_OPTIONS = Object.freeze([
  { value: "12", label: "12" },
  { value: "24", label: "24" },
  { value: "48", label: "48" },
  { value: "100", label: "100" },
]);

export default class AdminPluginsMediaGalleryTestDownloadsController extends Controller {
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked hasSearched = false;
  @tracked searchInfo = "";

  @tracked mediaTypeFilter = "video";
  @tracked statusFilter = "";
  @tracked backendFilter = "";
  @tracked sort = "";
  @tracked limit = "12";

  @tracked publicId = "";
  @tracked selectedItem = null;
  @tracked selectionMessage = "";

  @tracked users = [];
  @tracked isLoadingUsers = false;
  @tracked usersError = "";
  @tracked selectedUserId = "";
  @tracked manualUserId = "";

  @tracked isGenerating = false;
  @tracked generateError = "";
  @tracked artifacts = [];

  resetState() {
    this.searchQuery = "";
    this.searchResults = [];
    this.isSearching = false;
    this.searchError = "";
    this.hasSearched = false;
    this.searchInfo = "";

    this.mediaTypeFilter = "video";
    this.statusFilter = "";
    this.backendFilter = "";
    this.sort = "";
    this.limit = "12";

    this.publicId = "";
    this.selectedItem = null;
    this.selectionMessage = "";

    this.users = [];
    this.isLoadingUsers = false;
    this.usersError = "";
    this.selectedUserId = "";
    this.manualUserId = "";

    this.isGenerating = false;
    this.generateError = "";
    this.artifacts = [];
  }

  get mediaTypeOptions() {
    return MEDIA_TYPE_OPTIONS;
  }

  get statusOptions() {
    return STATUS_OPTIONS;
  }

  get backendOptions() {
    return BACKEND_OPTIONS;
  }

  get sortOptions() {
    return SORT_OPTIONS;
  }

  get limitOptions() {
    return LIMIT_OPTIONS;
  }

  get hasSelectedItem() {
    return !!(this.publicId || "").trim();
  }

  get hasSearchQuery() {
    return (this.searchQuery || "").trim().length >= 3;
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

  get decoratedSearchResults() {
    return (this.searchResults || []).map((item) => ({
      ...item,
      displayTitle: item?.title?.trim() || item?.public_id || "Untitled media",
      displayStatus: this._humanize(item?.status),
      displayType: this._humanize(item?.media_type),
      displayStorage: this._storageLabel(item),
      statusBadgeClass: this._statusBadgeClass(item?.status),
      createdLabel: this._formatDateTime(item?.created_at),
      updatedLabel: this._formatDateTime(item?.updated_at),
      sizeLabel: this._formatBytes(item?.filesize_processed_bytes),
      profileLabel: item?.managed_storage_profile_label || item?.managed_storage_profile || null,
    }));
  }

  get decoratedSelectedItem() {
    if (!this.selectedItem) {
      return null;
    }

    return {
      ...this.selectedItem,
      displayTitle: this.selectedItem?.title?.trim() || this.selectedItem?.public_id || "Selected media",
      displayStatus: this._humanize(this.selectedItem?.status),
      displayType: this._humanize(this.selectedItem?.media_type),
      displayStorage: this._storageLabel(this.selectedItem),
      statusBadgeClass: this._statusBadgeClass(this.selectedItem?.status),
      createdLabel: this._formatDateTime(this.selectedItem?.created_at),
      updatedLabel: this._formatDateTime(this.selectedItem?.updated_at),
      sizeLabel: this._formatBytes(this.selectedItem?.filesize_processed_bytes),
      profileLabel:
        this.selectedItem?.managed_storage_profile_label ||
        this.selectedItem?.managed_storage_profile ||
        null,
    };
  }

  get artifactCards() {
    return (this.artifacts || []).map((artifact) => ({
      ...artifact,
      createdLabel: this._formatDateTime(artifact?.created_at),
      modeLabel: this._artifactModeLabel(artifact),
      sizeLabel: this._formatBytes(artifact?.file_size_bytes),
      segmentSummary:
        artifact?.start_segment != null
          ? `Start ${artifact.start_segment}, ${artifact.segment_count || 0} / ${artifact.total_segments || 0} segments`
          : null,
      regionSummary:
        artifact?.random_clip_region && artifact?.clip_percent_of_video != null
          ? `${artifact.random_clip_region} · ${artifact.clip_percent_of_video}%`
          : artifact?.random_clip_region || null,
    }));
  }

  _humanize(value) {
    return String(value || "")
      .replace(/[_-]+/g, " ")
      .replace(/\b\w/g, (char) => char.toUpperCase())
      .trim();
  }


  _statusBadgeClass(status) {
    if (status === "ready") {
      return "mg-test-downloads__badge is-success";
    }
    if (status === "failed") {
      return "mg-test-downloads__badge is-danger";
    }
    return "mg-test-downloads__badge";
  }

  _storageLabel(item) {
    if (item?.managed_storage_profile_label) {
      return item.managed_storage_profile_label;
    }

    const backend = item?.managed_storage_backend;
    if (backend === "s3") {
      return "S3";
    }
    if (backend === "local") {
      return "Local";
    }
    return this._humanize(backend) || "Unknown";
  }

  _formatDateTime(value) {
    if (!value) {
      return "—";
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }

    const pad = (number) => String(number).padStart(2, "0");
    return `${pad(date.getUTCDate())}-${pad(date.getUTCMonth() + 1)}-${date.getUTCFullYear()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())} UTC`;
  }

  _formatBytes(value) {
    const bytes = Number(value);
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return "—";
    }

    if (bytes < 1024) {
      return `${bytes} B`;
    }

    const units = ["KB", "MB", "GB", "TB"];
    let unitIndex = -1;
    let size = bytes;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }

    return `${size.toFixed(size >= 10 || unitIndex === 0 ? 1 : 2)} ${units[unitIndex]}`;
  }

  _artifactModeLabel(artifact) {
    const base = this._humanize(artifact?.mode) || "Artifact";
    if (artifact?.random_clip_region) {
      return `${base} · ${artifact.random_clip_region}`;
    }
    return base;
  }

  @action
  onSearchInput(event) {
    this.searchQuery = event?.target?.value || "";
    this.hasSearched = false;
    this.searchInfo = "";
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
  onMediaTypeChange(event) {
    this.mediaTypeFilter = event?.target?.value || "";
  }

  @action
  onStatusChange(event) {
    this.statusFilter = event?.target?.value || "";
  }

  @action
  onBackendChange(event) {
    this.backendFilter = event?.target?.value || "";
  }

  @action
  onSortChange(event) {
    this.sort = event?.target?.value || "";
  }

  @action
  onLimitChange(event) {
    this.limit = event?.target?.value || "12";
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

  @action
  async search() {
    this.searchError = "";
    this.searchInfo = "";
    this.isSearching = true;
    this.hasSearched = true;

    try {
      const q = (this.searchQuery || "").trim();
      if (q.length > 0 && q.length < 3) {
        this.searchError = "Enter at least 3 characters, or clear the search field to browse recent items.";
        this.searchResults = [];
        return;
      }

      const params = new URLSearchParams();
      if (q.length >= 3) {
        params.set("q", q);
      }
      if (this.mediaTypeFilter) {
        params.set("media_type", this.mediaTypeFilter);
      }
      if (this.statusFilter) {
        params.set("status", this.statusFilter);
      }
      if (this.backendFilter) {
        params.set("backend", this.backendFilter);
      }
      if (this.sort) {
        params.set("sort", this.sort);
      }
      if (this.limit) {
        params.set("limit", this.limit);
      }

      const url = `/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`;
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
      this.searchResults = Array.isArray(json?.items) ? json.items : [];
      this.searchInfo = `${this.searchResults.length} result(s) loaded.`;
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

    this.selectedItem = item || { public_id: trimmed, title: null, username: null };
    this.publicId = trimmed;
    this.users = [];
    this.selectedUserId = "";
    this.manualUserId = "";
    this.usersError = "";
    this.generateError = "";
    this.selectionMessage = `Selected media ${trimmed}. Loading users…`;
    await this.loadUsers();
  }

  @action
  async pickItem(item) {
    await this._selectPublicId(item?.public_id, item || null);
  }

  @action
  async useTypedPublicId() {
    const q = (this.searchQuery || "").trim();
    if (q.length < 3) {
      this.selectionMessage = "Enter at least 3 characters or paste the full public_id.";
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

  @action
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
        this.selectionMessage = `Selected media ${this.publicId}, but loading users failed.`;
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
      this.searchInfo = `Loaded ${this.users.length} user option(s) for ${this.publicId}.`;
      this.selectionMessage = `Selected media ${this.publicId}. ${this.users.length} user option(s) loaded.`;
    } catch (e) {
      this.usersError = e?.message || String(e);
      this.users = [];
      this.selectionMessage = `Selected media ${this.publicId}, but loading users failed.`;
    } finally {
      this.isLoadingUsers = false;
    }
  }

  _csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  }

  _pushArtifact(artifact) {
    if (!artifact) {
      return;
    }
    this.artifacts = [artifact, ...(this.artifacts || [])];
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
        return;
      }

      const status = json?.status || "queued";
      if (status === "queued" || status === "working") {
        this.selectionMessage = `Generating artifact for ${this.publicId}… (${status})`;
        continue;
      }

      if (status === "complete" && json?.artifact) {
        this._pushArtifact(json.artifact);
        this.selectionMessage = `Artifact generated for ${this.publicId}. Use the Download button below.`;
        return;
      }

      if (status === "failed") {
        this.generateError = String(json?.error || "Generation failed.");
        return;
      }

      this.generateError = `Unexpected task state for ${taskId}: ${status}`;
      return;
    }

    this.generateError = "Timed out while waiting for artifact generation.";
  }

  async _generate(payload) {
    if (!this.publicId || !this.resolvedUserId) {
      this.generateError = "Select a public_id and user first.";
      return;
    }

    this.isGenerating = true;
    this.generateError = "";

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
        this.selectionMessage = `Queued generation for ${this.publicId}.`;
        await this._pollTask(json.task_id, json.status_url);
        return;
      }

      if (json?.ok && json?.artifact) {
        this._pushArtifact(json.artifact);
        this.selectionMessage = `Artifact generated for ${this.publicId}. Use the Download button below.`;
        return;
      }

      const err = json?.error || json?.message || "Generation failed.";
      this.generateError = String(err);
    } catch (e) {
      this.generateError = e?.message || String(e);
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
