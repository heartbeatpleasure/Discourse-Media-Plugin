import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function formatDateTime(value) {
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

function normalizeTags(tags) {
  return Array.isArray(tags)
    ? tags.map((tag) => String(tag || "").trim().toLowerCase()).filter(Boolean)
    : String(tags || "")
        .split(",")
        .map((tag) => String(tag || "").trim().toLowerCase())
        .filter(Boolean);
}

export default class AdminPluginsMediaGalleryManagementController extends Controller {
  @tracked searchQuery = "";
  @tracked statusFilter = "all";
  @tracked mediaTypeFilter = "all";
  @tracked hiddenFilter = "all";
  @tracked limit = 50;
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked searchInfo = "";
  @tracked hasSearched = false;

  @tracked selectedPublicId = "";
  @tracked selectedItem = null;
  @tracked isLoadingSelection = false;
  @tracked selectionError = "";
  @tracked noticeMessage = "";

  @tracked editTitle = "";
  @tracked editDescription = "";
  @tracked editGender = "";
  @tracked editTags = "";
  @tracked adminNote = "";

  @tracked isSaving = false;
  @tracked isTogglingHidden = false;
  @tracked isDeleting = false;
  @tracked isRetrying = false;

  resetState() {
    this.searchQuery = "";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hiddenFilter = "all";
    this.limit = 50;
    this.searchResults = [];
    this.isSearching = false;
    this.searchError = "";
    this.searchInfo = "";
    this.hasSearched = false;

    this.selectedPublicId = "";
    this.selectedItem = null;
    this.isLoadingSelection = false;
    this.selectionError = "";
    this.noticeMessage = "";

    this.editTitle = "";
    this.editDescription = "";
    this.editGender = "";
    this.editTags = "";
    this.adminNote = "";

    this.isSaving = false;
    this.isTogglingHidden = false;
    this.isDeleting = false;
    this.isRetrying = false;
  }

  async loadInitial() {
    await this.search();
  }

  get hasSelectedItem() {
    return !!this.selectedItem;
  }

  get saveDisabled() {
    return !this.hasSelectedItem || this.isSaving || !this.editTitle?.trim() || !this.editGender;
  }

  get toggleHiddenDisabled() {
    return !this.hasSelectedItem || this.isTogglingHidden || this.isDeleting;
  }

  get deleteDisabled() {
    return !this.hasSelectedItem || this.isDeleting || this.isTogglingHidden;
  }

  get retryDisabled() {
    return !this.hasSelectedItem || this.isRetrying || this.selectedItem?.status !== "failed";
  }

  get hiddenButtonLabel() {
    return this.selectedItem?.hidden ? "Unhide item" : "Hide item";
  }

  get selectedMetaRows() {
    const item = this.selectedItem || {};
    return [
      { label: "public_id", value: item.public_id || "—" },
      { label: "Status", value: item.status || "—" },
      { label: "Media type", value: item.media_type || "—" },
      { label: "Owner", value: item.username ? `${item.username} (#${item.user_id})` : String(item.user_id || "—") },
      { label: "Created", value: formatDateTime(item.created_at) },
      { label: "Updated", value: formatDateTime(item.updated_at) },
      { label: "Storage", value: item.managed_storage_profile_label || item.managed_storage_profile || item.managed_storage_backend || "—" },
      { label: "Delivery", value: item.delivery_mode || "—" },
      { label: "Visibility", value: item.hidden ? `Hidden${item.visibility?.reason ? ` — ${item.visibility.reason}` : ""}` : "Visible" },
    ];
  }

  get historyEntries() {
    return (Array.isArray(this.selectedItem?.management_log) ? this.selectedItem.management_log : []).map((entry) => ({
      ...entry,
      changesSummary: entry?.changes ? JSON.stringify(entry.changes) : "",
    }));
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

  async _fetchJson(url, options = {}) {
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        ...options.headers,
      },
      ...options,
    });

    if (!response.ok) {
      const error = await this._extractError(response);
      throw new Error(error);
    }

    return await response.json();
  }

  _syncEditForm(item) {
    this.editTitle = item?.title || "";
    this.editDescription = item?.description || "";
    this.editGender = item?.gender || "";
    this.editTags = Array.isArray(item?.tags) ? item.tags.join(", ") : "";
    this.adminNote = "";
  }

  @action onSearchInput(event) {
    this.searchQuery = event?.target?.value || "";
  }

  @action onStatusFilterChange(event) {
    this.statusFilter = event?.target?.value || "all";
  }

  @action onMediaTypeFilterChange(event) {
    this.mediaTypeFilter = event?.target?.value || "all";
  }

  @action onHiddenFilterChange(event) {
    this.hiddenFilter = event?.target?.value || "all";
  }

  @action onEditTitle(event) {
    this.editTitle = event?.target?.value || "";
  }

  @action onEditDescription(event) {
    this.editDescription = event?.target?.value || "";
  }

  @action onEditGender(event) {
    this.editGender = event?.target?.value || "";
  }

  @action onEditTags(event) {
    this.editTags = event?.target?.value || "";
  }

  @action onAdminNote(event) {
    this.adminNote = event?.target?.value || "";
  }

  @action
  async search() {
    this.isSearching = true;
    this.searchError = "";
    this.searchInfo = "";
    this.hasSearched = true;

    try {
      const params = new URLSearchParams();
      if ((this.searchQuery || "").trim()) {
        params.set("q", this.searchQuery.trim());
      }
      if (this.statusFilter !== "all") {
        params.set("status", this.statusFilter);
      }
      if (this.mediaTypeFilter !== "all") {
        params.set("media_type", this.mediaTypeFilter);
      }
      if (this.hiddenFilter !== "all") {
        params.set("hidden", this.hiddenFilter);
      }
      params.set("limit", String(this.limit));

      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
        method: "GET",
      });
      this.searchResults = Array.isArray(json?.items) ? json.items : [];
      this.searchInfo = `${this.searchResults.length} item(s) found.`;
    } catch (e) {
      this.searchResults = [];
      this.searchError = e?.message || String(e);
    } finally {
      this.isSearching = false;
    }
  }

  @action
  async selectItem(item) {
    const publicId = item?.public_id;
    if (!publicId) {
      return;
    }

    this.selectedPublicId = publicId;
    await this.refreshSelected();
  }

  @action
  async refreshSelected() {
    if (!this.selectedPublicId) {
      return;
    }

    this.isLoadingSelection = true;
    this.selectionError = "";
    this.noticeMessage = "";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/management.json`, {
        method: "GET",
      });
      this.selectedItem = json;
      this._syncEditForm(json);
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isLoadingSelection = false;
    }
  }

  @action
  async saveChanges() {
    if (this.saveDisabled) {
      return;
    }

    this.isSaving = true;
    this.selectionError = "";
    this.noticeMessage = "";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/admin-update.json`, {
        method: "PUT",
        body: JSON.stringify({
          title: this.editTitle.trim(),
          description: this.editDescription,
          gender: this.editGender,
          tags: normalizeTags(this.editTags),
          admin_note: this.adminNote,
        }),
      });
      this.selectedItem = json?.item || this.selectedItem;
      this._syncEditForm(this.selectedItem);
      this.noticeMessage = json?.message || "Item updated.";
      await this.search();
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isSaving = false;
    }
  }

  @action
  async toggleHidden() {
    if (this.toggleHiddenDisabled) {
      return;
    }

    this.isTogglingHidden = true;
    this.selectionError = "";
    this.noticeMessage = "";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/visibility.json`, {
        method: "POST",
        body: JSON.stringify({
          hidden: !this.selectedItem?.hidden,
          reason: this.adminNote,
          admin_note: this.adminNote,
        }),
      });
      this.selectedItem = json?.item || this.selectedItem;
      this._syncEditForm(this.selectedItem);
      this.noticeMessage = json?.message || "Visibility updated.";
      await this.search();
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isTogglingHidden = false;
    }
  }

  @action
  async deleteItem() {
    if (this.deleteDisabled) {
      return;
    }

    if (!window.confirm(`Delete media item ${this.selectedPublicId}? This cannot be undone.`)) {
      return;
    }

    this.isDeleting = true;
    this.selectionError = "";
    this.noticeMessage = "";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/admin-destroy.json`, {
        method: "DELETE",
        body: JSON.stringify({ admin_note: this.adminNote }),
      });
      this.noticeMessage = json?.message || "Item deleted.";
      this.selectedItem = null;
      this.selectedPublicId = "";
      await this.search();
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isDeleting = false;
    }
  }

  @action
  async retryProcessing() {
    if (this.retryDisabled) {
      return;
    }

    this.isRetrying = true;
    this.selectionError = "";
    this.noticeMessage = "";

    try {
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/retry-processing.json`, {
        method: "POST",
        body: JSON.stringify({ force: false }),
      });
      this.noticeMessage = "Processing retry queued.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isRetrying = false;
    }
  }
}
