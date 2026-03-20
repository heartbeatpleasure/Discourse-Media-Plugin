import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

export default class AdminPluginsMediaGalleryTestDownloadsController extends Controller {
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked hasSearched = false;

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

  _searchTimer = null;

  get enabled() {
    return true;
  }

  get hasSelectedItem() {
    return !!this.publicId;
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
    return !this.isLoadingUsers && (this.users?.length || 0) === 0;
  }

  get generateDisabled() {
    return !this.canGenerate;
  }

  resetState() {
    this.searchQuery = "";
    this.searchResults = [];
    this.isSearching = false;
    this.searchError = "";
    this.hasSearched = false;
    this.publicId = "";
    this.selectedItem = null;
    this.users = [];
    this.isLoadingUsers = false;
    this.usersError = "";
    this.selectedUserId = "";
    this.manualUserId = "";
    this.isGenerating = false;
    this.generateError = "";
    this.artifacts = [];
  }

  @action
  onSearchInput(event) {
    this.searchQuery = (event?.target?.value || "").trim();
    this.hasSearched = false;
    this._debouncedSearch();
  }

  @action
  onSearchKeydown(event) {
    if (event?.key === "Enter") {
      event.preventDefault();
      this.search();
    }
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
    this.isSearching = true;
    this.hasSearched = true;

    try {
      const q = this.searchQuery;
      if (q && q.length < 3) {
        this.searchResults = [];
        return;
      }

      const url = `/admin/plugins/media-gallery/media-items/search.json?q=${encodeURIComponent(q || "")}`;
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
  async pickItem(item) {
    this.selectedItem = item || null;
    this.publicId = item?.public_id || "";
    this.users = [];
    this.selectedUserId = "";
    this.usersError = "";
    if (this.publicId) {
      await this.loadUsers();
    }
  }

  @action
  async useTypedPublicId() {
    const q = (this.searchQuery || "").trim();
    if (q.length < 3) {
      return;
    }

    const exact = (this.searchResults || []).find((item) => item?.public_id === q) || null;
    this.selectedItem = exact;
    this.publicId = q;
    this.users = [];
    this.selectedUserId = "";
    this.usersError = "";
    this.generateError = "";
    await this.loadUsers();
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
        this.usersError = `HTTP ${response.status}: ${err}`;
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
