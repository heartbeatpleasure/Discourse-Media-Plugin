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

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "—";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = bytes;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size = size / 1024;
    unitIndex += 1;
  }

  const decimals = unitIndex === 0 || size >= 10 ? 0 : 1;
  return `${size.toFixed(decimals)} ${units[unitIndex]}`;
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

  if (key === "owner_media_blocked" || key === "owner_media_view_blocked" || key === "owner_media_upload_blocked") {
    return value ? "Blocked" : "Allowed";
  }

  if (key === "quick_block_group") {
    return String(value || "").trim() || "—";
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

function friendlyProcessingError(message) {
  const raw = String(message || "").trim();
  if (!raw) {
    return null;
  }

  if (raw === "file_content_unrecognized") {
    return {
      title: "File content could not be recognized",
      summary: "The uploaded file does not look like a valid image, audio file, or video file after server-side inspection.",
      advice: "Ask the user to upload the original media file again. Renamed PDFs, ZIP files, documents, or corrupted files are intentionally rejected.",
      retry: "Retry is usually not useful unless the user uploads a clean media file first.",
      raw,
    };
  }

  if (raw === "file_content_mismatch") {
    return {
      title: "File content does not match the extension",
      summary: "The server detected media content that does not match the uploaded file extension or allowed media type.",
      advice: "Ask the user to export the file with a correct extension and upload it again.",
      retry: "Retrying the same file is unlikely to help.",
      raw,
    };
  }

  if (raw === "duration_probe_failed") {
    return {
      title: "Duration could not be checked",
      summary: "The server could not read the media duration before processing.",
      advice: "Ask the user to try a standard MP4, MP3, M4A, or image export. Check FFprobe/FFmpeg availability if this happens often.",
      retry: "Retry may help only if the failure was temporary.",
      raw,
    };
  }

  if (raw.startsWith("duration_exceeds_")) {
    return {
      title: "Media duration is too long",
      summary: "The file is longer than the configured Media Gallery duration policy allows.",
      advice: "Ask the user to shorten the media or adjust the duration limit if this content should be allowed.",
      retry: "Retrying the same file will fail until the file or policy changes.",
      raw,
    };
  }

  if (raw === "processing_attempt_limit_reached") {
    return {
      title: "Processing attempt limit reached",
      summary: "The item failed repeatedly and processing was stopped to avoid an endless retry loop.",
      advice: "Review earlier logs for the first failure reason, then retry only after fixing the underlying cause.",
      retry: "Retry only after reviewing the cause.",
      raw,
    };
  }

  if (raw.includes("ffprobe_failed")) {
    return {
      title: "FFprobe could not inspect the file",
      summary: "The media inspection step failed. This can happen with corrupted, unsupported, or unusual media containers.",
      advice: "Ask for a standard export and check FFprobe availability if multiple normal files fail.",
      retry: "Retry may help only for temporary server issues.",
      raw,
    };
  }

  if (raw.includes("ffmpeg_")) {
    return {
      title: "FFmpeg processing failed",
      summary: "The media reached the processing pipeline, but FFmpeg could not produce the required output.",
      advice: "Ask for a standard export, or review server logs if this happens for normal files.",
      retry: "Retry may help if the failure was caused by temporary storage or worker load.",
      raw,
    };
  }

  if (raw.includes("storage") || raw.includes("store_") || raw.includes("upload")) {
    return {
      title: "Storage or output save failed",
      summary: "The file may have processed, but the server could not store or register the output safely.",
      advice: "Check local/S3/R2 storage health, permissions, bucket configuration and available disk space.",
      retry: "Retry after storage health is confirmed.",
      raw,
    };
  }

  return {
    title: "Processing failed",
    summary: "The item failed during processing. The raw code below is kept for support and log lookup.",
    advice: "Check Media Gallery logs and server logs for details before retrying repeatedly.",
    retry: "Retry may help only if the underlying cause was temporary.",
    raw,
  };
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
    case "block_owner":
    case "block_owner_view":
      return "Blocked uploader from view and upload";
    case "unblock_owner":
    case "unblock_owner_view":
      return "Unblocked uploader from view and upload";
    case "block_owner_upload":
      return "Blocked uploader from upload only";
    case "unblock_owner_upload":
      return "Unblocked uploader from upload only";
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
      } else if (key === "owner_media_blocked") {
        label = "Uploader access";
      } else if (key === "quick_block_group") {
        label = "Quick block group";
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
  @tracked userIdFilter = "";
  @tracked duplicateFilter = "all";
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
  @tracked isBlockingOwner = false;
  @tracked availableSearchProfiles = [];

  searchAbortController = null;
  selectionAbortController = null;

  resetState() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.profileFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hiddenFilter = "all";
    this.userIdFilter = "";
    this.duplicateFilter = "all";
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
    this.isBlockingOwner = false;
    this.availableSearchProfiles = [];
  }

  async loadInitial() {
    this.applyInitialQueryState();
    await this.search();
    if (this.selectedPublicId) {
      await this.refreshSelected();
    }
  }

  applyInitialQueryState() {
    const params = new URLSearchParams(window.location?.search || "");
    const publicId = String(params.get("public_id") || "").trim();
    const query = String(params.get("q") || publicId || "").trim();

    if (query) {
      this.searchQuery = query;
    }
    if (publicId) {
      this.selectedPublicId = publicId;
    }

    const userId = String(params.get("user_id") || "").replace(/\D/g, "").slice(0, 20);
    if (userId) {
      this.userIdFilter = userId;
    }
  }

  willDestroy() {
    this.searchAbortController?.abort?.();
    this.selectionAbortController?.abort?.();
    super.willDestroy(...arguments);
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
      })
      .map((profile) => ({
        ...profile,
        selected: profile.value === this.profileFilter,
      }));
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

  get ownerMediaAccess() {
    return this.selectedItem?.owner_media_access || {};
  }

  get ownerMediaAccessLabel() {
    const access = this.ownerMediaAccess;
    if (!access?.user_id) {
      return "Uploader unavailable";
    }
    if (!access.user_blockable) {
      return "Not blockable (staff/admin)";
    }
    if (access.view_blocked) {
      return "View and upload blocked";
    }
    if (access.upload_only_blocked || access.upload_blocked) {
      return "Upload blocked, view allowed";
    }
    return "Allowed";
  }

  get ownerMediaAccessHelp() {
    const access = this.ownerMediaAccess;
    if (!access?.user_id) {
      return "The media uploader could not be found.";
    }
    if (!access.quick_block_group_name && !access.quick_upload_block_group_name) {
      return "Configure the media quick view block group and/or quick upload block group settings to enable quick blocking.";
    }
    if (!access.user_blockable) {
      return "Staff and admin users cannot be blocked from the media section.";
    }
    if (access.view_blocked) {
      return "This uploader cannot view media and therefore cannot upload either. A view block always takes priority over upload permissions.";
    }
    if (access.upload_only_blocked || access.upload_blocked) {
      return "This uploader can still view media if viewer rules allow it, but cannot upload to the media section.";
    }
    return "Use view block to deny both viewing and uploading, or upload-only block to keep viewing allowed while preventing uploads.";
  }

  get ownerViewBlockDisabled() {
    const access = this.ownerMediaAccess;
    return !(
      this.hasSelectedItem &&
      !this.isBlockingOwner &&
      access?.user_id &&
      access.quick_block_group_name &&
      access.quick_block_group_exists &&
      access.quick_block_group_usable &&
      access.user_blockable &&
      !access.blocked_by_quick_group
    );
  }

  get ownerViewUnblockDisabled() {
    const access = this.ownerMediaAccess;
    return !(
      this.hasSelectedItem &&
      !this.isBlockingOwner &&
      access?.user_id &&
      access.quick_block_group_name &&
      access.quick_block_group_exists &&
      access.quick_block_group_usable &&
      access.user_blockable &&
      access.blocked_by_quick_group
    );
  }

  get ownerUploadBlockDisabled() {
    const access = this.ownerMediaAccess;
    return !(
      this.hasSelectedItem &&
      !this.isBlockingOwner &&
      access?.user_id &&
      access.quick_upload_block_group_name &&
      access.quick_upload_block_group_exists &&
      access.quick_upload_block_group_usable &&
      access.user_blockable &&
      !access.upload_blocked_by_quick_group &&
      !access.view_blocked
    );
  }

  get ownerUploadUnblockDisabled() {
    const access = this.ownerMediaAccess;
    return !(
      this.hasSelectedItem &&
      !this.isBlockingOwner &&
      access?.user_id &&
      access.quick_upload_block_group_name &&
      access.quick_upload_block_group_exists &&
      access.quick_upload_block_group_usable &&
      access.user_blockable &&
      access.upload_blocked_by_quick_group
    );
  }

  get ownerBlockActionDisabled() {
    return this.ownerViewBlockDisabled;
  }

  get ownerBlockButtonLabel() {
    if (this.isBlockingOwner) {
      return "Updating…";
    }
    return "Block view & upload";
  }

  get ownerBlockButtonClass() {
    return "btn btn-danger";
  }

  get hiddenButtonLabel() {
    return this.selectedItem?.hidden ? "Unhide item" : "Hide item";
  }

  get selectedDuplicateDetection() {
    return this.selectedItem?.duplicate_detection || {};
  }

  get selectedHasPossibleDuplicate() {
    return !!this.selectedDuplicateDetection?.possible_duplicate;
  }

  get selectedDuplicateBadgeClass() {
    return this.selectedHasPossibleDuplicate ? "is-warning" : "";
  }

  get selectedDuplicateLabel() {
    return this.selectedHasPossibleDuplicate ? "Possible duplicate" : "No duplicate recorded";
  }

  get selectedDuplicateDetectionRows() {
    const detection = this.selectedDuplicateDetection || {};
    const match = detection.match || {};
    const matchedLabel = match.public_id || "Recorded match not available";

    return [
      { label: "Matched media", value: matchedLabel, wide: true },
      { label: "Matched uploader", value: match.username ? `${match.username} (#${match.user_id || "—"})` : "—" },
      { label: "Matched created", value: formatDateTime(match.created_at) },
      { label: "Matched status", value: match.still_exists === false ? "Deleted or no longer available" : titleize(match.status) || "—" },
      { label: "Match method", value: detection.method === "sha1_filesize" ? "SHA1 + file size" : titleize(detection.method) || "—" },
      { label: "Original filename", value: detection.source_original_filename || "—", wide: true },
      { label: "File size", value: formatBytes(detection.source_filesize) },
      { label: "SHA1", value: detection.source_sha1 || "—", wide: true },
      { label: "Upload action", value: titleize(detection.action) || "—" },
      { label: "Override", value: detection.override ? `Yes${detection.override_by_username ? ` by ${detection.override_by_username}` : ""}` : "No" },
      { label: "Checked", value: formatDateTime(detection.checked_at) },
    ];
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
      displayDuplicate: item?.possible_duplicate ? "Possible duplicate" : "",
      duplicateBadgeClass: item?.possible_duplicate ? "is-warning" : "",
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

  get selectedProcessingErrorDetails() {
    const message = String(this.selectedItem?.error_message || "").trim();

    if (!message || this.selectedItem?.status !== "failed") {
      return null;
    }

    return friendlyProcessingError(message);
  }

  get selectedProcessingErrorMessage() {
    return this.selectedProcessingErrorDetails?.raw || "";
  }

  get selectedProcessingErrorTitle() {
    return this.selectedProcessingErrorDetails?.title || "Processing error";
  }

  get selectedProcessingErrorSummary() {
    return this.selectedProcessingErrorDetails?.summary || "";
  }

  get selectedProcessingErrorAdvice() {
    return this.selectedProcessingErrorDetails?.advice || "";
  }

  get selectedProcessingErrorRetry() {
    return this.selectedProcessingErrorDetails?.retry || "";
  }

  get selectedMetaRows() {
    const item = this.selectedItem || {};
    return [
      { label: "Status", value: titleize(item.status) || "—" },
      { label: "Media type", value: titleize(item.media_type) || "—" },
      { label: "The file contains", value: genderLabel(item.gender) },
      { label: "Uploader", value: item.username ? `${item.username} (#${item.user_id})` : String(item.user_id || "—") },
      { label: "Uploader access", value: this.ownerMediaAccessLabel },
      { label: "Upload terms", value: this.uploadTermsAcceptanceLabel(item.upload_terms_acceptance) },
      { label: "Duplicate detection", value: this.selectedDuplicateLabel },
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

  uploadTermsAcceptanceLabel(acceptance) {
    if (!acceptance?.accepted) {
      return "Not recorded";
    }

    const acceptedAt = formatDateTime(acceptance.accepted_at);
    const username = String(acceptance.accepted_by_username || "").trim();
    const suffix = username ? ` by ${username}` : "";
    return `${acceptedAt}${suffix}`;
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
      signal: options.signal,
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

    if (this.duplicateFilter === "possible" && !item?.possible_duplicate) {
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
      possible_duplicate: !!item.possible_duplicate,
      duplicate_detection: item.duplicate_detection || {},
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

  @action onDuplicateFilterChange(event) {
    this.duplicateFilter = event?.target?.value || "all";
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
    this.duplicateFilter = "all";
    this.genderFilter = "all";
    this.limit = "50";
    this.sortBy = "newest";
    await this.search();
  }

  @action
  async search() {
    this.searchAbortController?.abort?.();
    const controller = new AbortController();
    this.searchAbortController = controller;

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
      if ((this.userIdFilter || "").trim()) {
        params.set("user_id", this.userIdFilter.trim());
      }
      if (this.duplicateFilter !== "all") {
        params.set("duplicate", this.duplicateFilter);
      }
      if (this.genderFilter !== "all") {
        params.set("gender", this.genderFilter);
      }
      params.set("limit", String(this.limit || "50"));
      params.set("sort", String(this.sortBy || "newest"));

      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
        method: "GET",
        signal: controller.signal,
      });
      this.availableSearchProfiles = Array.isArray(json?.search_profiles) ? json.search_profiles : this.availableSearchProfiles;
      this.searchResults = this._sortSearchResults(Array.isArray(json?.items) ? json.items : []);
      this._updateSearchInfo();
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.searchResults = [];
      this.searchError = e?.message || String(e);
    } finally {
      if (this.searchAbortController === controller) {
        this.searchAbortController = null;
      }
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

    this.selectionAbortController?.abort?.();
    const controller = new AbortController();
    this.selectionAbortController = controller;

    this.isLoadingSelection = true;
    this.selectionError = "";
    this.noticeMessage = "";
    this.noticeTone = "success";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/management.json`, {
        method: "GET",
        signal: controller.signal,
      });
      this.selectedItem = json;
      this._syncEditForm(json);
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.selectionError = e?.message || String(e);
    } finally {
      if (this.selectionAbortController === controller) {
        this.selectionAbortController = null;
      }
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
  async toggleOwnerMediaBlock(actionType = "view-block") {
    if (this.isBlockingOwner || !this.hasSelectedItem) {
      return;
    }

    const access = this.ownerMediaAccess;
    const username = String(access?.username || this.selectedItem?.username || "this user").trim();

    let endpoint = "block-owner";
    let confirmText = `Block ${username} from viewing and uploading media?`;
    let fallbackMessage = "Uploader access updated.";

    switch (actionType) {
      case "view-unblock":
        if (this.ownerViewUnblockDisabled) return;
        endpoint = "unblock-owner";
        confirmText = `Remove ${username} from the media view block group?`;
        fallbackMessage = "Uploader view access restored.";
        break;
      case "upload-block":
        if (this.ownerUploadBlockDisabled) return;
        endpoint = "block-owner-upload";
        confirmText = `Block ${username} from uploading only? They will still be able to view media if viewer rules allow it.`;
        fallbackMessage = "Uploader blocked from uploading.";
        break;
      case "upload-unblock":
        if (this.ownerUploadUnblockDisabled) return;
        endpoint = "unblock-owner-upload";
        confirmText = `Remove ${username} from the media upload block group?`;
        fallbackMessage = "Uploader upload access restored.";
        break;
      case "view-block":
      default:
        if (this.ownerViewBlockDisabled) return;
        endpoint = "block-owner";
        break;
    }

    if (!window.confirm(confirmText)) {
      return;
    }

    this.isBlockingOwner = true;
    this.selectionError = "";
    this.noticeMessage = "";
    this.noticeTone = "success";

    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${encodeURIComponent(this.selectedPublicId)}/${endpoint}.json`, {
        method: "POST",
        body: JSON.stringify({ admin_note: this.adminNote }),
      });
      this.selectedItem = json?.item || this.selectedItem;
      this._syncEditForm(this.selectedItem);
      this.noticeTone = "success";
      this.noticeMessage = json?.message || fallbackMessage;
      this._syncSearchResult(this.selectedItem);
    } catch (e) {
      this.selectionError = e?.message || String(e);
    } finally {
      this.isBlockingOwner = false;
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
    }
  }
}
