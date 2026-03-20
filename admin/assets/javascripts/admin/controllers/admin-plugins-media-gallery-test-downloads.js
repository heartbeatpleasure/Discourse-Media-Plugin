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

  @tracked users = [];
  @tracked isLoadingUsers = false;
  @tracked usersError = "";
  @tracked selectedUserId = "";
  @tracked manualUserId = "";

  @tracked isGenerating = false;
  @tracked generateError = "";
  @tracked artifacts = [];

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

  @action
  pickItem(item) {
    this.selectedItem = item || null;
    this.publicId = item?.public_id || "";
    this.users = [];
    this.selectedUserId = "";
    this.usersError = "";
    this.generateError = "";
    this.searchInfo = this.publicId ? `Selected public_id ${this.publicId}.` : "";
  }

  @action
  useTypedPublicId() {
    const q = (this.searchQuery || "").trim();
    if (q.length < 3) {
      return;
    }

    const exact = (this.searchResults || []).find((item) => item?.public_id === q) || null;
    this.selectedItem = exact || { public_id: q, title: null, username: null };
    this.publicId = q;
    this.users = [];
    this.selectedUserId = "";
    this.usersError = "";
    this.generateError = "";
    this.searchInfo = `Selected entered public_id ${q}. Click “Load users” below.`;
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
    } catch (e) {
      this.usersError = e?.message || String(e);
      this.users = [];
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
      if (!response.ok || !json?.ok || !json?.artifact) {
        const err = json?.error || json?.message || `HTTP ${response.status}`;
        this.generateError = String(err);
        return;
      }

      this._pushArtifact(json.artifact);
      if (json.artifact.download_url) {
        window.open(json.artifact.download_url, "_blank", "noopener,noreferrer");
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
