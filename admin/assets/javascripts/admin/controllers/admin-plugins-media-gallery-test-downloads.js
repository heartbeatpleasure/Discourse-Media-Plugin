import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

export default class AdminPluginsMediaGalleryTestDownloadsController extends Controller {
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked hasSearched = false;
  @tracked searchInfo = "";

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
    return !this.hasSearchQuery || this.isSearching;
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

  @action
  onSearchInput(event) {
    this.searchQuery = (event?.target?.value || "").trim();
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
      if (q.length < 3) {
        this.searchResults = [];
        return;
      }

      const url = `/admin/plugins/media-gallery/media-items/search.json?q=${encodeURIComponent(q)}`;
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
      this.searchInfo = `${this.searchResults.length} result(s) found.`;
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
