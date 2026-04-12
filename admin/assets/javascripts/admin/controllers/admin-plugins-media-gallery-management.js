import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

const GENDER_OPTIONS = [
  { value: "male", label: "Male hearts" },
  { value: "female", label: "Female hearts" },
  { value: "both", label: "Both male and female hearts" },
  { value: "non_binary", label: "Non-binary hearts" },
  { value: "objects", label: "Heart-related objects" },
  { value: "other", label: "Other" },
];

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

function titleize(value) {
  return String(value || "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function displayTagLabel(value) {
  return titleize(String(value || "").trim());
}

function normalizeTags(tags) {
  return Array.isArray(tags)
    ? tags.map((tag) => String(tag || "").trim().toLowerCase()).filter(Boolean)
    : String(tags || "")
        .split(",")
        .map((tag) => String(tag || "").trim().toLowerCase())
        .filter(Boolean);
}

function arrayEqual(left, right) {
  const a = Array.isArray(left) ? left : [];
  const b = Array.isArray(right) ? right : [];
  if (a.length !== b.length) {
    return false;
  }

  return a.every((value, index) => String(value) === String(b[index]));
}

function genderLabel(value) {
  return (
    GENDER_OPTIONS.find((option) => option.value === value)?.label ||
    stringifyValue(value)
  );
}

function stringifyValue(value, key = "") {
  if (key === "gender") {
    return genderLabel(value);
  }

  if (key === "hidden") {
    return value ? "Hidden" : "Visible";
  }

  if (Array.isArray(value)) {
    const entries = value
      .map((entry) => String(entry || "").trim())
      .filter(Boolean)
      .map(displayTagLabel);
    return entries.length ? entries.join(", ") : "—";
  }

  const normalized = String(value ?? "");
  return normalized.trim() ? normalized : "—";
}

function formatHistoryAction(action) {
  switch (String(action || "")) {
    case "update_metadata":
      return "Updated metadata";
    case "hide":
      return "Hidden item";
    case "unhide":
      return "Made item visible";
    case "admin_note":
      return "Added admin note";
    default:
      return titleize(action || "change");
  }
}

function formatHistoryChanges(entry) {
  const changes = entry?.changes;
  if (!changes || typeof changes !== "object") {
    return [];
  }

  return Object.entries(changes)
    .map(([key, pair]) => {
      const fromValue = Array.isArray(pair) ? pair[0] : undefined;
      const toValue = Array.isArray(pair) ? pair[1] : undefined;
      if (
        JSON.stringify(fromValue ?? null) === JSON.stringify(toValue ?? null)
      ) {
        return null;
      }

      let label = titleize(key);
      if (key === "gender") {
        label = "The file contains";
      } else if (key === "hidden") {
        label = "Visibility";
      }

      return {
        key,
        label,
        from: stringifyValue(fromValue, key),
        to: stringifyValue(toValue, key),
      };
    })
    .filter(Boolean);
}

export default class AdminPluginsMediaGalleryManagementController extends Controller {
  @tracked searchQuery = "";
  @tracked backendFilter = "all";
  @tracked profileFilter = "all";
  @tracked statusFilter = "all";
  @tracked mediaTypeFilter = "all";
  @tracked hiddenFilter = "all";
  @tracked genderFilter = "all";
  @tracked limit = "50";
  @tracked sortBy = "newest";
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
  @tracked noticeTone = "success";

  @tracked editTitle = "";
  @tracked editDescription = "";
  @tracked editGender = "";
  @tracked editTags = [];
  @tracked editTagsText = "";
  @tracked adminNote = "";

  @tracked isSaving = false;
  @tracked isTogglingHidden = false;
  @tracked isDeleting = false;
  @tracked isRetrying = false;
  @tracked availableSearchProfiles = [];

  resetState() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.profileFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hiddenFilter = "all";
    this.genderFilter = "all";
    this.limit = "50";
    this.sortBy = "newest";
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
    this.noticeTone = "success";

    this.editTitle = "";
    this.editDescription = "";
    this.editGender = "";
    this.editTags = [];
    this.editTagsText = "";
    this.adminNote = "";

    this.isSaving = false;
    this.isTogglingHidden = false;
    this.isDeleting = false;
    this.isRetrying = false;
    this.availableSearchProfiles = [];
  }

  async loadInitial() {
    await this.search();
  }

  get hasSelectedItem() {
    return !!this.selectedItem;
  }

  get allowedTagOptions() {
    return Array.isArray(this.selectedItem?.allowed_tags)
      ? this.selectedItem.allowed_tags
          .map((tag) => String(tag || "").trim())
          .filter(Boolean)
      : [];
  }

  get profileOptions() {
    const seen = new Set();
    return (Array.isArray(this.availableSearchProfiles) ? this.availableSearchProfiles : [])
      .map((profile) => ({
        value: String(profile?.value || profile?.profile_key || "").trim(),
        label: String(profile?.label || profile?.value || profile?.profile_key || "").trim(),
      }))
      .filter((profile) => {
        if (!profile.value || seen.has(profile.value)) {
          return false;
        }
        seen.add(profile.value);
        return true;
      });
  }

  get usingAllowedTags() {
    return this.allowedTagOptions.length > 0;
  }

  get decoratedAllowedTagOptions() {
    return this.allowedTagOptions.map((tag) => ({
      value: String(tag || "").trim().toLowerCase(),
      label: displayTagLabel(tag),
      isSelected: this.editTags.includes(String(tag || "").trim().toLowerCase()),
    }));
  }

  get currentTagValues() {
    return this.usingAllowedTags ? this.editTags : normalizeTags(this.editTagsText);
  }

  get metadataDirty() {
    if (!this.selectedItem) {
      return false;
    }

    const originalTags = Array.isArray(this.selectedItem.tags)
      ? this.selectedItem.tags.map((tag) => String(tag || "").trim().toLowerCase())
      : [];

    return (
      String(this.selectedItem.title || "") !== String(this.editTitle || "").trim() ||
      String(this.selectedItem.description || "") !== String(this.editDescription || "").trim() ||
      String(this.selectedItem.gender || "") !== String(this.editGender || "") ||
      !arrayEqual(originalTags, this.currentTagValues)
    );
  }

  get noteDirty() {
    return !!String(this.adminNote || "").trim();
  }

  get saveDisabled() {
    return (
      !this.hasSelectedItem ||
      this.isSaving ||
      !this.editTitle?.trim() ||
      !this.editGender ||
      (!this.metadataDirty && !this.noteDirty)
    );
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


  get noticeClass() {
    return this.noticeTone === "danger" ? "mg-management__flash is-danger" : "mg-management__flash is-success";
  }

  get decoratedSearchResults() {
    return (Array.isArray(this.searchResults) ? this.searchResults : []).map((item) => ({
      ...item,
      isSelected: item?.public_id === this.selectedPublicId,
      displayStatus: titleize(item?.status),
      displayMediaType: titleize(item?.media_type),
      displayVisibility: item?.hidden ? "Hidden" : "Visible",
      displayStorage:
        item?.managed_storage_profile_label ||
        item?.managed_storage_profile ||
        titleize(item?.managed_storage_backend),
      displayMeta: [item?.username ? `by ${item.username}` : "", formatDateTime(item?.created_at)]
        .filter(Boolean)
        .join(" • "),
      statusBadgeClass:
        item?.status === "ready"
          ? "is-success"
          : item?.status === "failed"
            ? "is-danger"
            : item?.status === "processing" || item?.status === "queued"
              ? "is-warning"
              : "",
      visibilityBadgeClass: item?.hidden ? "is-danger" : "is-success",
    }));
  }

  get selectedStatusBadgeClass() {
    return this.selectedItem?.status === "ready"
      ? "is-success"
      : this.selectedItem?.status === "failed"
        ? "is-danger"
        : this.selectedItem?.status === "processing" || this.selectedItem?.status === "queued"
          ? "is-warning"
          : "";
  }

  get selectedVisibilityBadgeClass() {
    return this.selectedItem?.hidden ? "is-danger" : "is-success";
  }

  get selectedDisplayStatus() {
    return titleize(this.selectedItem?.status);
  }

  get selectedDisplayMediaType() {
    return titleize(this.selectedItem?.media_type);
  }

  get selectedDisplayStorage() {
    return (
      this.selectedItem?.managed_storage_profile_label ||
      this.selectedItem?.managed_storage_profile ||
      titleize(this.selectedItem?.managed_storage_backend)
    );
  }

  get selectedMetaRows() {
    const item = this.selectedItem || {};
    return [
      { label: "Status", value: titleize(item.status) || "—" },
      { label: "Media type", value: titleize(item.media_type) || "—" },
      { label: "The file contains", value: genderLabel(item.gender) },
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
      actionLabel: formatHistoryAction(entry?.action),
      prettyAt: formatDateTime(entry?.at),
      changeRows: formatHistoryChanges(entry),
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
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "X-Requested-With": "XMLHttpRequest",
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
    this.editTags = Array.isArray(item?.tags)
      ? item.tags.map((tag) => String(tag || "").trim().toLowerCase()).filter(Boolean)
      : [];
    this.editTagsText = this.editTags.join(", ");
    this.adminNote = "";
  }

  _updateSearchInfo() {
    this.searchInfo = `${this.searchResults.length} item(s) found.`;
  }

  _sortSearchResults(items) {
    const entries = Array.isArray(items) ? [...items] : [];
    const asTime = (value) => new Date(value || 0).getTime() || 0;

    return entries.sort((a, b) => {
      switch (this.sortBy) {
        case "oldest":
          return asTime(a?.created_at) - asTime(b?.created_at);
        case "title_asc":
          return String(a?.title || "").localeCompare(String(b?.title || ""), undefined, { sensitivity: "base" });
        case "title_desc":
          return String(b?.title || "").localeCompare(String(a?.title || ""), undefined, { sensitivity: "base" });
        case "updated_desc":
          return asTime(b?.updated_at) - asTime(a?.updated_at);
        default:
          return asTime(b?.created_at) - asTime(a?.created_at);
      }
    });
  }

  _matchesActiveFilters(item) {
    const query = String(this.searchQuery || "").trim().toLowerCase();
    if (query) {
      const haystack = [item?.public_id, item?.title, item?.id, item?.username]
        .map((value) => String(value || "").toLowerCase())
        .join(" ");
      if (!haystack.includes(query)) {
        return false;
      }
    }

    if (this.backendFilter !== "all" && item?.managed_storage_backend !== this.backendFilter) {
      return false;
    }

    if (this.profileFilter !== "all" && item?.managed_storage_profile !== this.profileFilter) {
      return false;
    }

    if (this.statusFilter !== "all" && item?.status !== this.statusFilter) {
      return false;
    }

    if (this.mediaTypeFilter !== "all" && item?.media_type !== this.mediaTypeFilter) {
      return false;
    }

    if (this.genderFilter !== "all" && item?.gender !== this.genderFilter) {
      return false;
    }

    if (this.hiddenFilter === "hidden" && !item?.hidden) {
      return false;
    }

    if (this.hiddenFilter === "visible" && item?.hidden) {
      return false;
    }

    return true;
  }

  _syncSearchResult(item) {
    if (!item?.public_id) {
      return;
    }

    const next = {
      id: item.id,
      public_id: item.public_id,
      title: item.title,
      status: item.status,
      created_at: item.created_at,
      updated_at: item.updated_at,
      user_id: item.user_id,
      username: item.username,
      media_type: item.media_type,
      gender: item.gender,
      error_message: item.error_message,
      thumbnail_url: item.thumbnail_url,
      managed_storage_backend: item.managed_storage_backend,
      managed_storage_profile: item.managed_storage_profile,
      managed_storage_profile_label: item.managed_storage_profile_label,
      managed_storage_location_fingerprint_key: item.managed_storage_location_fingerprint_key,
      delivery_mode: item.delivery_mode,
      has_hls: item.has_hls,
      hidden: item.hidden,
      hidden_reason: item.visibility?.reason || item.hidden_reason,
    };

    const existing = Array.isArray(this.searchResults) ? [...this.searchResults] : [];
    const index = existing.findIndex((entry) => entry?.public_id === item.public_id);
    if (!this._matchesActiveFilters(next)) {
      if (index >= 0) {
        existing.splice(index, 1);
        this.searchResults = this._sortSearchResults(existing);
        this._updateSearchInfo();
      }
      return;
    }

    if (index >= 0) {
      existing.splice(index, 1, { ...existing[index], ...next });
    } else {
      existing.unshift(next);
    }
    this.searchResults = this._sortSearchResults(existing);
    this._updateSearchInfo();
  }

  @action onSearchInput(event) {
    this.searchQuery = event?.target?.value || "";
  }

  @action onBackendFilterChange(event) {
    this.backendFilter = event?.target?.value || "all";
  }

  @action onProfileFilterChange(event) {
    this.profileFilter = event?.target?.value || "all";
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

  @action onGenderFilterChange(event) {
    this.genderFilter = event?.target?.value || "all";
  }

  @action onLimitChange(event) {
    this.limit = event?.target?.value || "50";
  }

  @action onSortChange(event) {
    this.sortBy = event?.target?.value || "newest";
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

  @action onEditTagsText(event) {
    this.editTagsText = event?.target?.value || "";
  }

  @action toggleTag(tag) {
    const normalized = String(tag || "").trim().toLowerCase();
    if (!normalized) {
      return;
    }

    const current = Array.isArray(this.editTags) ? [...this.editTags] : [];
    const index = current.indexOf(normalized);
    if (index >= 0) {
      current.splice(index, 1);
    } else {
      current.push(normalized);
    }
    this.editTags = current;
  }

  @action onAdminNote(event) {
    this.adminNote = event?.target?.value || "";
  }

  @action
  async resetFilters() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.profileFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hiddenFilter = "all";
    this.genderFilter = "all";
    this.limit = "50";
    this.sortBy = "newest";
    await this.search();
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
      if (this.backendFilter !== "all") {
        params.set("backend", this.backendFilter);
      }
      if (this.profileFilter !== "all") {
        params.set("profile", this.profileFilter);
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
      if (this.genderFilter !== "all") {
        params.set("gender", this.genderFilter);
      }
      params.set("limit", String(this.limit || "50"));
      params.set("sort", String(this.sortBy || "newest"));

      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
        method: "GET",
      });
      this.availableSearchProfiles = Array.isArray(json?.search_profiles) ? json.search_profiles : this.availableSearchProfiles;
      this.searchResults = this._sortSearchResults(Array.isArray(json?.items) ? json.items : []);
      this._updateSearchInfo();
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
    if (this.selectedItem?.public_id !== publicId) {
      this.selectedItem = { ...item };
    }
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
    this.noticeTone = "success";

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
    this.noticeTone = "success";
    this.noticeTone = "success";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/admin-update.json`, {
        method: "PUT",
        body: JSON.stringify({
          title: this.editTitle.trim(),
          description: String(this.editDescription || "").trim(),
          gender: this.editGender,
          tags: this.currentTagValues,
          admin_note: this.adminNote,
        }),
      });
      this.selectedItem = json?.item || this.selectedItem;
      this._syncEditForm(this.selectedItem);
      this.noticeTone = "success";
      this.noticeMessage = json?.message || "Item updated.";
      this._syncSearchResult(this.selectedItem);
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
    this.noticeTone = "success";
    this.noticeTone = "success";

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
      this.noticeTone = "success";
      this.noticeMessage = json?.message || "Visibility updated.";
      this._syncSearchResult(this.selectedItem);
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

    const title = String(this.selectedItem?.title || "").trim();
    const label = title ? `${title}
${this.selectedPublicId}` : this.selectedPublicId;
    if (!window.confirm(`Delete media item:

${label}

This cannot be undone.`)) {
      return;
    }

    this.isDeleting = true;
    this.selectionError = "";
    this.noticeMessage = "";
    this.noticeTone = "success";
    this.noticeTone = "success";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/admin-destroy.json`, {
        method: "DELETE",
        body: JSON.stringify({ admin_note: this.adminNote }),
      });
      this.noticeTone = "success";
      this.noticeMessage = json?.message || "Item deleted.";
      this.searchResults = this.searchResults.filter((entry) => entry?.public_id !== this.selectedPublicId);
      this._updateSearchInfo();
      this.selectedItem = null;
      this.selectedPublicId = "";
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
    this.noticeTone = "success";
    this.noticeTone = "success";

    try {
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/retry-processing.json`, {
        method: "POST",
        body: JSON.stringify({ force: false }),
      });
      this.noticeTone = "success";
      this.noticeMessage = "Processing retry queued.";
      await this.refreshSelected();
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isRetrying = false;
    this.availableSearchProfiles = [];
    }
  }
}
