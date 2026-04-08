import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function truncate(text, max = 400) {
  const value = text == null ? "" : String(text);
  return value.length > max ? `${value.slice(0, max)}…` : value;
}

export default class AdminPluginsMediaGalleryMigrationsController extends Controller {
  @tracked searchQuery = "";
  @tracked backendFilter = "all";
  @tracked statusFilter = "all";
  @tracked hlsFilter = "all";
  @tracked limit = 50;
  @tracked sortBy = "created_at_desc";

  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked searchInfo = "";
  @tracked searchResults = [];

  @tracked selectedItem = null;
  @tracked selectedPublicId = "";
  @tracked selectedPlan = null;
  @tracked selectedDiagnostics = null;
  @tracked selectedError = "";
  @tracked isLoadingSelection = false;

  @tracked lastActionMessage = "";
  @tracked actionError = "";
  @tracked isCopying = false;
  @tracked isSwitching = false;
  @tracked isCleaning = false;
  @tracked autoSwitch = false;
  @tracked autoCleanup = false;
  @tracked forceAction = false;

  @tracked activeHealth = null;
  @tracked targetHealth = null;
  @tracked activeProbe = null;
  @tracked targetProbe = null;
  @tracked storageError = "";
  @tracked storageBusy = false;

  resetState() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.statusFilter = "all";
    this.hlsFilter = "all";
    this.limit = 50;
    this.sortBy = "created_at_desc";
    this.isSearching = false;
    this.searchError = "";
    this.searchInfo = "";
    this.searchResults = [];
    this.selectedItem = null;
    this.selectedPublicId = "";
    this.selectedPlan = null;
    this.selectedDiagnostics = null;
    this.selectedError = "";
    this.isLoadingSelection = false;
    this.lastActionMessage = "";
    this.actionError = "";
    this.isCopying = false;
    this.isSwitching = false;
    this.isCleaning = false;
    this.autoSwitch = false;
    this.autoCleanup = false;
    this.forceAction = false;
    this.activeHealth = null;
    this.targetHealth = null;
    this.activeProbe = null;
    this.targetProbe = null;
    this.storageError = "";
    this.storageBusy = false;
  }

  async loadInitial() {
    await this.search();
    await this.loadStorageHealth("active");
    await this.loadStorageHealth("target");
  }

  get sortedResults() {
    const rows = [...(this.searchResults || [])];
    const sortBy = this.sortBy;
    rows.sort((a, b) => {
      switch (sortBy) {
        case "created_at_asc":
          return String(a.created_at || "").localeCompare(String(b.created_at || ""));
        case "title_asc":
          return String(a.title || "").localeCompare(String(b.title || ""));
        case "title_desc":
          return String(b.title || "").localeCompare(String(a.title || ""));
        case "backend_asc":
          return String(a.managed_storage_backend || "").localeCompare(String(b.managed_storage_backend || ""));
        case "backend_desc":
          return String(b.managed_storage_backend || "").localeCompare(String(a.managed_storage_backend || ""));
        case "created_at_desc":
        default:
          return String(b.created_at || "").localeCompare(String(a.created_at || ""));
      }
    });
    return rows;
  }

  get hasSelectedItem() {
    return !!this.selectedPublicId;
  }

  get copyDisabled() {
    return !this.hasSelectedItem || this.isCopying || this.isSwitching || this.isCleaning;
  }

  get switchDisabled() {
    return !this.hasSelectedItem || this.isSwitching || this.isCopying || this.isCleaning;
  }

  get cleanupDisabled() {
    return !this.hasSelectedItem || this.isCleaning || this.isCopying || this.isSwitching;
  }

  get planJson() {
    return this.selectedPlan ? JSON.stringify(this.selectedPlan, null, 2) : "";
  }

  get diagnosticsJson() {
    return this.selectedDiagnostics ? JSON.stringify(this.selectedDiagnostics, null, 2) : "";
  }

  async _extractError(response) {
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) {
        return json.errors.join(" ");
      }
      if (json?.error) return String(json.error);
      if (json?.message) return String(json.message);
    } catch {
      // ignore
    }
    try {
      const text = await response.text();
      if (text) return truncate(text, 600);
    } catch {
      // ignore
    }
    return `HTTP ${response.status}`;
  }

  async _fetchJson(url, options = {}) {
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: { Accept: "application/json", ...(options.headers || {}) },
      ...options,
    });
    if (!response.ok) {
      throw new Error(await this._extractError(response));
    }
    return await response.json();
  }

  @action onSearchInput(event) { this.searchQuery = event?.target?.value || ""; }
  @action onBackendFilterChange(event) { this.backendFilter = event?.target?.value || "all"; }
  @action onStatusFilterChange(event) { this.statusFilter = event?.target?.value || "all"; }
  @action onHlsFilterChange(event) { this.hlsFilter = event?.target?.value || "all"; }
  @action onSortByChange(event) { this.sortBy = event?.target?.value || "created_at_desc"; }
  @action onLimitInput(event) {
    const value = parseInt(event?.target?.value, 10);
    this.limit = Number.isFinite(value) && value > 0 ? Math.min(value, 100) : 50;
  }
  @action onSearchKeydown(event) {
    if (event?.key === "Enter") {
      event.preventDefault();
      this.search();
    }
  }
  @action onAutoSwitchChange(event) { this.autoSwitch = !!event?.target?.checked; }
  @action onAutoCleanupChange(event) { this.autoCleanup = !!event?.target?.checked; }
  @action onForceActionChange(event) { this.forceAction = !!event?.target?.checked; }

  @action
  async search() {
    this.isSearching = true;
    this.searchError = "";
    this.searchInfo = "";
    try {
      const params = new URLSearchParams();
      const q = (this.searchQuery || "").trim();
      if (q) params.set("q", q);
      if (this.backendFilter && this.backendFilter !== "all") params.set("backend", this.backendFilter);
      if (this.statusFilter && this.statusFilter !== "all") params.set("status", this.statusFilter);
      if (this.hlsFilter && this.hlsFilter !== "all") params.set("has_hls", this.hlsFilter === "yes" ? "true" : "false");
      params.set("limit", String(this.limit || 50));
      const response = await fetch(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) {
        this.searchError = await this._extractError(response);
        this.searchResults = [];
        return;
      }
      const json = await response.json();
      this.searchResults = Array.isArray(json?.items) ? json.items : [];
      this.searchInfo = `${this.searchResults.length} result(s).`;
    } catch (e) {
      this.searchError = e?.message || String(e);
      this.searchResults = [];
    } finally {
      this.isSearching = false;
    }
  }

  @action
  async selectItem(item) {
    const publicId = item?.public_id;
    if (!publicId) return;
    this.selectedItem = item;
    this.selectedPublicId = publicId;
    this.selectedError = "";
    this.lastActionMessage = "";
    this.actionError = "";
    await this.refreshSelected();
  }

  @action
  async refreshSelected() {
    if (!this.selectedPublicId) return;
    this.isLoadingSelection = true;
    this.selectedError = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const [diagnostics, plan] = await Promise.all([
        this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/diagnostics.json`),
        this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/migration-plan.json`),
      ]);
      this.selectedDiagnostics = diagnostics;
      this.selectedPlan = plan;
    } catch (e) {
      this.selectedError = e?.message || String(e);
    } finally {
      this.isLoadingSelection = false;
    }
  }

  @action
  async copyToTarget() {
    if (!this.selectedPublicId) return;
    this.isCopying = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/copy-to-target.json`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({
          target_profile: "target",
          force: this.forceAction,
          auto_switch: this.autoSwitch,
          auto_cleanup: this.autoCleanup,
        }),
      });
      this.lastActionMessage = "Copy queued/completed.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isCopying = false;
    }
  }

  @action
  async switchToTarget() {
    if (!this.selectedPublicId) return;
    this.isSwitching = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/switch-to-target.json`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({
          target_profile: "target",
          auto_cleanup: this.autoCleanup,
        }),
      });
      this.lastActionMessage = "Switch completed.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isSwitching = false;
    }
  }

  @action
  async cleanupSource() {
    if (!this.selectedPublicId) return;
    this.isCleaning = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/cleanup-source.json`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ force: this.forceAction }),
      });
      this.lastActionMessage = "Cleanup queued/completed.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isCleaning = false;
    }
  }

  @action
  async loadStorageHealth(profile) {
    this.storageBusy = true;
    this.storageError = "";
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/health.json?profile=${encodeURIComponent(profile)}`);
      if (profile === "active") this.activeHealth = json;
      else this.targetHealth = json;
    } catch (e) {
      this.storageError = e?.message || String(e);
    } finally {
      this.storageBusy = false;
    }
  }

  @action
  async runStorageProbe(profile) {
    this.storageBusy = true;
    this.storageError = "";
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/probe.json`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ profile }),
      });
      if (profile === "active") this.activeProbe = json;
      else this.targetProbe = json;
    } catch (e) {
      this.storageError = e?.message || String(e);
    } finally {
      this.storageBusy = false;
    }
  }
}
