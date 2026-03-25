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

  get enabled() {
    return true;
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

  async _pollTask(statusUrl) {
    const started = Date.now();
    while (Date.now() - started < 180000) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const response = await fetch(statusUrl, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      const json = await response.json().catch(() => null);
      if (!response.ok || !json?.ok || !json?.task) {
        const err = json?.error || json?.message || `Status poll failed (${response.status})`;
        throw new Error(String(err));
      }

      const task = json.task;
      if (task.status === "complete" && task.artifact) {
        return task.artifact;
      }
      if (task.status === "failed") {
        throw new Error(task.error || "Generation failed.");
      }
      this.selectionMessage = `Generating ${task.mode} download for ${task.public_id}… (${task.status})`;
    }

    throw new Error("Generation timed out while waiting for the background job.");
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
        `/admin/plugins/media-gallery/test-downloads/${encodeURIComponent(this.publicId)}.json`,
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
        const err = json?.error || json?.message || `Generation request failed (${response.status})`;
        this.generateError = String(err);
        return;
      }
      if (!json?.ok || !json?.queued || !json?.status_url) {
        const err = json?.error || json?.message || "Generation request failed.";
        this.generateError = String(err);
        return;
      }

      this.selectionMessage = `Queued ${payload.mode} generation for ${this.publicId}. Waiting for background job…`;
      const artifact = await this._pollTask(json.status_url);
      this._pushArtifact(artifact);
      this.selectionMessage = `Artifact generated for ${this.publicId}.`;
      if (artifact.download_url) {
        window.open(artifact.download_url, "_blank", "noopener,noreferrer");
      }
    } catch (e) {
      this.generateError = e?.message || String(e);
    } finally {
      this.isGenerating = false;
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
