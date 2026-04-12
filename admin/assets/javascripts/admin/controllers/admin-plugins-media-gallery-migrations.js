import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function truncate(text, max = 400) {
  const value = text == null ? "" : String(text);
  return value.length > max ? `${value.slice(0, max)}…` : value;
}

function safeArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeText(value) {
  return value == null || value === "" ? "—" : String(value);
}

function prettyLabel(value) {
  const text = normalizeText(value);
  if (text === "—") {
    return text;
  }

  return text
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function titleCase(value) {
  const text = prettyLabel(value);
  if (text === "—") {
    return text;
  }

  return text.replace(/\b\w/g, (char) => char.toUpperCase());
}

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

function formatBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value <= 0) {
    return value === 0 ? "0 B" : "—";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = value;
  let unitIndex = 0;

  while (amount >= 1024 && unitIndex < units.length - 1) {
    amount /= 1024;
    unitIndex += 1;
  }

  const decimals = amount >= 100 || unitIndex === 0 ? 0 : 1;
  return `${amount.toFixed(decimals)} ${units[unitIndex]}`;
}

function summarizeLocator(role) {
  const entry = role && typeof role === "object" ? role : {};
  return (
    entry.key_prefix ||
    entry.key ||
    (entry.upload_id ? `upload:${entry.upload_id}` : null) ||
    "—"
  );
}

function toneForStatus(status) {
  switch ((status || "").toString()) {
    case "ready":
    case "copied":
    case "verified":
    case "switched":
    case "cleaned":
    case "rolled_back":
    case "finalized":
    case "ok":
    case "available":
      return "success";
    case "queued":
    case "copying":
    case "processing":
    case "cleaning":
    case "pending_cleanup":
    case "incomplete":
      return "warning";
    case "same_profile":
    case "not_configured":
    case "missing":
    case "failed":
    case "error":
    case "unavailable":
      return "danger";
    default:
      return "neutral";
  }
}

function badgeClassForStatus(status) {
  return `mg-migrations__badge is-${toneForStatus(status)}`;
}

function buildSummaryRow(label, value) {
  return {
    label,
    value: normalizeText(value),
  };
}

function buildStateCard({ title, status, detail, meta, error }) {
  const statusLabel = titleCase(status || "unknown");

  return {
    title,
    statusLabel,
    badgeClass: badgeClassForStatus(status),
    detail: normalizeText(detail),
    meta: normalizeText(meta),
    error: error ? truncate(error, 220) : "",
  };
}

function thumbnailStateKey(item, diagnostics) {
  const itemData = item && typeof item === "object" ? item : {};
  const diagnosticsData = diagnostics && typeof diagnostics === "object" ? diagnostics : {};
  const processing = diagnosticsData.processing || itemData.processing || {};
  const status = diagnosticsData.status || itemData.status || "unknown";
  const stage = processing.current_stage || processing.last_stage || processing.last_failed_stage || "";
  const updatedAt = diagnosticsData.updated_at || itemData.updated_at || "";

  return [status, stage, updatedAt].filter(Boolean).join(":");
}

const TARGET_PROFILE_STORAGE_KEY = "media-gallery:migrations:selected-target-profile";

function buildThumbnailUrl(publicId, { item = null, diagnostics = null } = {}) {
  if (!publicId) {
    return "";
  }

  const base =
    diagnostics?.thumbnail_url ||
    item?.thumbnail_url ||
    `/media/${encodeURIComponent(publicId)}/thumbnail`;
  const stateKey = thumbnailStateKey(item, diagnostics);

  if (!stateKey) {
    return base;
  }

  const separator = base.includes("?") ? "&" : "?";
  return `${base}${separator}v=${encodeURIComponent(stateKey)}`;
}

export default class AdminPluginsMediaGalleryMigrationsController extends Controller {
  @tracked searchQuery = "";
  @tracked backendFilter = "all";
  @tracked profileFilter = "all";
  @tracked statusFilter = "all";
  @tracked mediaTypeFilter = "all";
  @tracked hlsFilter = "all";
  @tracked limit = 50;
  @tracked sortBy = "created_at_desc";

  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked searchInfo = "";
  @tracked searchResults = [];
  @tracked selectedBulkPublicIds = [];
  @tracked bulkConfirm = false;
  @tracked bulkFullMigration = true;

  @tracked selectedItem = null;
  @tracked selectedPublicId = "";
  @tracked selectedPlan = null;
  @tracked selectedDiagnostics = null;
  @tracked selectedVerification = null;
  @tracked selectedError = "";
  @tracked selectedPlanError = "";
  @tracked isLoadingSelection = false;
  @tracked isLoadingPlan = false;
  @tracked selectedPlanLoaded = false;

  @tracked lastActionMessage = "";
  @tracked actionError = "";
  @tracked bulkActionMessage = "";
  @tracked bulkActionError = "";
  @tracked isCopying = false;
  @tracked isSwitching = false;
  @tracked isCleaning = false;
  @tracked isVerifying = false;
  @tracked isRollingBack = false;
  @tracked isFinalizing = false;
  @tracked isBulkMigrating = false;
  @tracked autoSwitch = false;
  @tracked autoCleanup = false;
  @tracked forceAction = false;

  @tracked activeHealth = null;
  @tracked targetHealth = null;
  @tracked availableSearchProfiles = [];
  @tracked activeProfileSummary = null;
  @tracked availableTargetProfiles = [];
  @tracked selectedTargetProfile = "";
  @tracked activeProbe = null;
  @tracked targetProbe = null;
  @tracked storageError = "";
  @tracked storageBusy = false;

  autoRefreshTimer = null;
  autoRefreshIntervalMs = 5000;
  autoRefreshSearchCounter = 0;
  searchAbortController = null;
  selectionAbortController = null;
  storageAbortController = null;

  _readStoredTargetProfile() {
    try {
      return window?.localStorage?.getItem(TARGET_PROFILE_STORAGE_KEY) || "";
    } catch {
      return "";
    }
  }

  _persistTargetProfile(profileKey) {
    const value = profileKey == null ? "" : String(profileKey);
    try {
      if (!value) {
        window?.localStorage?.removeItem(TARGET_PROFILE_STORAGE_KEY);
      } else {
        window?.localStorage?.setItem(TARGET_PROFILE_STORAGE_KEY, value);
      }
    } catch {
      // ignore storage failures
    }
  }

  resetState() {
    this._stopAutoRefresh();
    this.searchQuery = "";
    this.backendFilter = "all";
    this.profileFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hlsFilter = "all";
    this.limit = 50;
    this.sortBy = "created_at_desc";
    this.isSearching = false;
    this.searchError = "";
    this.searchInfo = "";
    this.searchResults = [];
    this.selectedBulkPublicIds = [];
    this.bulkConfirm = false;
    this.bulkFullMigration = true;
    this.selectedItem = null;
    this.selectedPublicId = "";
    this.selectedPlan = null;
    this.selectedDiagnostics = null;
    this.selectedVerification = null;
    this.selectedError = "";
    this.selectedPlanError = "";
    this.isLoadingSelection = false;
    this.isLoadingPlan = false;
    this.selectedPlanLoaded = false;
    this.lastActionMessage = "";
    this.actionError = "";
    this.bulkActionMessage = "";
    this.bulkActionError = "";
    this.isCopying = false;
    this.isSwitching = false;
    this.isCleaning = false;
    this.isVerifying = false;
    this.isRollingBack = false;
    this.isFinalizing = false;
    this.isBulkMigrating = false;
    this.autoSwitch = false;
    this.autoCleanup = false;
    this.forceAction = false;
    this.activeHealth = null;
    this.targetHealth = null;
    this.availableSearchProfiles = [];
    this.activeProfileSummary = null;
    this.availableTargetProfiles = [];
    this.selectedTargetProfile = "";
    this.activeProbe = null;
    this.targetProbe = null;
    this.storageError = "";
    this.storageBusy = false;
  }

  async loadInitial() {
    await this.loadTargetProfiles();
    await this.search();
    await this.loadStorageHealth("active");
    if (this.selectedTargetProfileKey) {
      await this.loadStorageHealth(this.selectedTargetProfileKey);
    }
    this._syncAutoRefresh();
  }

  willDestroy() {
    this._stopAutoRefresh();
    this.searchAbortController?.abort?.();
    this.selectionAbortController?.abort?.();
    this.storageAbortController?.abort?.();
    super.willDestroy(...arguments);
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

  get resultCards() {
    return this.sortedResults.map((item) => {
      const isSelected = this.selectedPublicId === item.public_id;
      const mediaType = item.media_type ? titleCase(item.media_type) : "Media";
      const username = item.username ? `by ${item.username}` : "";
      const metaParts = [username, formatDateTime(item.created_at)].filter(Boolean);

      const isBulkSelected = this.selectedBulkPublicIds.includes(item.public_id);

      return {
        ...item,
        isSelected,
        isBulkSelected,
        cardClass: `mg-migrations__result-card${isSelected ? " is-selected" : ""}${isBulkSelected ? " is-bulk-selected" : ""}`,
        titleLabel: item.title || "Untitled media",
        publicIdLabel: item.public_id || "—",
        backendLabel: titleCase(item.managed_storage_backend || "unknown"),
        profileLabel: normalizeText(item.managed_storage_profile_label || item.managed_storage_profile),
        statusLabel: titleCase(item.status || "unknown"),
        statusClass: badgeClassForStatus(item.status),
        mediaTypeLabel: mediaType,
        mediaTypeClass: "mg-migrations__badge",
        hasHlsLabel: item.has_hls ? "HLS" : "No HLS",
        hlsClass: badgeClassForStatus(item.has_hls ? "ok" : "neutral"),
        metaLabel: metaParts.join(" • "),
        thumbnailUrl: buildThumbnailUrl(item.public_id, { item }),
        sizeLabel: formatBytes(item.filesize_processed_bytes),
      };
    });
  }

  get hasSearchResults() {
    return this.resultCards.length > 0;
  }

  get searchProfileOptions() {
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

  get hasSelectedItem() {
    return !!this.selectedPublicId;
  }

  get canUseSelectedTargetProfile() {
    return !!this.selectedTargetProfileKey && this.targetProfileOptions.some((entry) => entry.profile_key === this.selectedTargetProfileKey);
  }

  get copyDisabled() {
    return !this.hasSelectedItem || !this.canUseSelectedTargetProfile || this.isCopying || this.isSwitching || this.isCleaning;
  }

  get switchDisabled() {
    return !this.hasSelectedItem || !this.canUseSelectedTargetProfile || this.isSwitching || this.isCopying || this.isCleaning;
  }

  get cleanupDisabled() {
    const switchStatus = this.selectedDiagnostics?.migration_switch?.status || "";
    return !this.hasSelectedItem || this.isCleaning || this.isCopying || this.isSwitching || this.isRollingBack || this.isFinalizing || !["switched", "rolled_back"].includes(switchStatus);
  }

  get cleanupActionLabel() {
    const cleanupMode = this.selectedDiagnostics?.migration_cleanup?.cleanup_mode || "";
    const switchStatus = this.selectedDiagnostics?.migration_switch?.status || "";
    if (cleanupMode === "inactive_target_after_rollback" || switchStatus === "rolled_back") {
      return "Cleanup inactive target";
    }
    return "Cleanup source";
  }

  get verifyDisabled() {
    return !this.hasSelectedItem || !this.canUseSelectedTargetProfile || this.isVerifying || this.isLoadingSelection || this.isRollingBack || this.isFinalizing;
  }

  get rollbackDisabled() {
    const switchStatus = this.selectedDiagnostics?.migration_switch?.status || "";
    const cleanupStatus = this.selectedDiagnostics?.migration_cleanup?.status || "";
    return !this.hasSelectedItem || this.isRollingBack || this.isCopying || this.isSwitching || this.isCleaning || this.isFinalizing || !["switched", "rolled_back"].includes(switchStatus) || cleanupStatus === "cleaned";
  }

  get finalizeDisabled() {
    const cleanupStatus = this.selectedDiagnostics?.migration_cleanup?.status || "";
    const rollbackStatus = this.selectedDiagnostics?.migration_rollback?.status || "";
    return !this.hasSelectedItem || this.isFinalizing || this.isRollingBack || this.isCopying || this.isSwitching || !(cleanupStatus === "cleaned" || rollbackStatus === "rolled_back");
  }

  get clearQueuedStateDisabled() {
    if (!this.hasSelectedItem || this.isLoadingSelection || this.isCopying || this.isCleaning || this.isFinalizing) {
      return true;
    }

    const statuses = [
      this.selectedDiagnostics?.migration_copy?.status,
      this.selectedDiagnostics?.migration_cleanup?.status,
      this.selectedDiagnostics?.migration_finalize?.status,
    ].filter(Boolean).map((value) => String(value));

    return !statuses.some((status) => ["queued", "copying", "cleaning", "pending_cleanup"].includes(status));
  }

  get bulkSelectionCount() {
    return this.selectedBulkPublicIds.length;
  }

  get hasBulkSelection() {
    return this.bulkSelectionCount > 0;
  }

  get allVisibleSelected() {
    return this.sortedResults.length > 0 && this.sortedResults.every((item) => this.selectedBulkPublicIds.includes(item.public_id));
  }

  get bulkMigrateDisabled() {
    return this.isBulkMigrating || this.isSearching || !this.hasBulkSelection || !this.bulkConfirm || !this.selectedTargetProfileKey;
  }

  get bulkModeLabel() {
    return this.bulkFullMigration ? "full migration" : "copy only";
  }

  get selectedTargetProfileKey() {
    return this.selectedTargetProfile || this.targetHealth?.profile_key || this.availableTargetProfiles[0]?.profile_key || "target";
  }

  get selectedTargetProfileLabel() {
    const option = this.targetProfileOptions.find((entry) => entry.profile_key === this.selectedTargetProfileKey);
    return option?.label || this.targetHealth?.label || this.selectedTargetProfileKey;
  }

  get selectedSourceLocationFingerprintKey() {
    return this.selectedDiagnostics?.managed_storage_location_fingerprint_key || this.selectedItem?.managed_storage_location_fingerprint_key || "";
  }

  get targetProfileOptions() {
    const seen = new Set();
    const selectedProfileKey = this.selectedTargetProfile || this.targetHealth?.profile_key || this.availableTargetProfiles[0]?.profile_key || "target";

    return (this.availableTargetProfiles || []).filter((entry) => {
      if (!entry?.profile_key) {
        return false;
      }

      const dedupeKey = entry.profile_key;
      if (seen.has(dedupeKey)) {
        return false;
      }
      seen.add(dedupeKey);
      return true;
    }).map((entry) => ({
      ...entry,
      selected: entry.profile_key === selectedProfileKey,
    }));
  }

  get selectAllVisibleDisabled() {
    return !this.hasSearchResults;
  }

  get clearBulkSelectionDisabled() {
    return !this.hasBulkSelection;
  }

  get loadPlanDisabled() {
    return !this.canLoadSelectedPlan;
  }

  get canLoadSelectedPlan() {
    if (!this.hasSelectedItem || this.isLoadingSelection || this.isLoadingPlan) {
      return false;
    }
    const sourceProfileKey = this.selectedDiagnostics?.managed_storage_profile || this.selectedItem?.managed_storage_profile;
    const targetProfileKey = this.selectedTargetProfileKey;
    const sourceFingerprint = this.selectedSourceLocationFingerprintKey;
    const targetFingerprint = this.targetHealth?.location_fingerprint_key || this.targetProfileOptions.find((entry) => entry.profile_key === targetProfileKey)?.location_fingerprint_key;
    return !((sourceProfileKey && targetProfileKey && sourceProfileKey === targetProfileKey) || (sourceFingerprint && targetFingerprint && sourceFingerprint === targetFingerprint));
  }

  get selectedPlanHint() {
    if (!this.hasSelectedItem) {
      return "Select an item to inspect its migration preview.";
    }
    if (!this.targetProfileOptions.length) {
      return "No alternate migration destination is configured for this item. Add another storage profile in settings.";
    }
    const sourceProfileKey = this.selectedDiagnostics?.managed_storage_profile || this.selectedItem?.managed_storage_profile;
    const targetProfileKey = this.selectedTargetProfileKey;
    const sourceFingerprint = this.selectedSourceLocationFingerprintKey;
    const targetFingerprint = this.targetHealth?.location_fingerprint_key || this.targetProfileOptions.find((entry) => entry.profile_key === targetProfileKey)?.location_fingerprint_key;
    if ((sourceProfileKey && targetProfileKey && sourceProfileKey === targetProfileKey) || (sourceFingerprint && targetFingerprint && sourceFingerprint === targetFingerprint)) {
      return "Source and target use the same storage profile. Choose a different destination.";
    }
    if (!this.selectedPlanLoaded) {
      return "Load a dry-run migration preview when you need it.";
    }
    return "";
  }

  get selectedDisplayTitle() {
    return this.selectedItem?.title || this.selectedDiagnostics?.title || "Selected media";
  }

  get selectedThumbnailUrl() {
    return buildThumbnailUrl(this.selectedPublicId, {
      item: this.selectedItem,
      diagnostics: this.selectedDiagnostics,
    });
  }

  get selectedSummaryRows() {
    const diagnostics = this.selectedDiagnostics || {};
    const item = this.selectedItem || {};

    return [
      buildSummaryRow("Public ID", this.selectedPublicId),
      buildSummaryRow("Type", titleCase(diagnostics.media_type || item.media_type || "unknown")),
      buildSummaryRow("Uploaded by", diagnostics.username || item.username),
      buildSummaryRow("Created", item.created_at ? formatDateTime(item.created_at) : (diagnostics.created_at ? formatDateTime(diagnostics.created_at) : null)),
      buildSummaryRow("Backend / profile", `${titleCase(diagnostics.managed_storage_backend || item.managed_storage_backend || "unknown")} / ${normalizeText(diagnostics.managed_storage_profile_label || item.managed_storage_profile_label || diagnostics.managed_storage_profile || item.managed_storage_profile)}`),
      buildSummaryRow("Delivery", diagnostics.delivery_mode),
      buildSummaryRow("Status", titleCase(diagnostics.status || item.status || "unknown")),
    ];
  }

  get selectedProcessingCard() {
    if (!this.hasSelectedItem) {
      return null;
    }

    const diagnostics = this.selectedDiagnostics || {};
    const selectedItem = this.selectedItem || {};
    const processing = diagnostics.processing || {};
    const stage = processing.current_stage || processing.last_stage || processing.last_failed_stage || "—";
    const status = diagnostics.status || selectedItem.status;
    const stale = diagnostics.processing_stale ? `Stale after ${diagnostics.processing_stale_after_minutes} min` : "Live state";

    const backend = diagnostics.managed_storage_backend || selectedItem.managed_storage_backend || this.activeHealth?.backend || this.activeProfileSummary?.backend;
    const profileLabel =
      diagnostics.managed_storage_profile_label ||
      selectedItem.managed_storage_profile_label ||
      diagnostics.managed_storage_profile ||
      selectedItem.managed_storage_profile ||
      this.activeHealth?.label ||
      this.activeProfileSummary?.label;

    const metaParts = [stale];
    if (["queued", "processing"].includes(String(status || "")) && (backend || profileLabel)) {
      const destinationLabel = [backend ? titleCase(backend) : "", normalizeText(profileLabel)].filter((value) => value && value !== "—").join(" / ");
      if (destinationLabel) {
        metaParts.push(`Destination: ${destinationLabel}`);
      }
    }

    return buildStateCard({
      title: "Processing",
      status,
      detail: `Stage: ${prettyLabel(stage)}`,
      meta: metaParts.join(" • "),
      error: diagnostics.error_message,
    });
  }

  get selectedStateCards() {
    const diagnostics = this.selectedDiagnostics || {};
    const copy = diagnostics.migration_copy || {};
    const verify = this.selectedVerification || diagnostics.migration_verify || {};
    const switchState = diagnostics.migration_switch || {};
    const cleanup = diagnostics.migration_cleanup || {};
    const rollback = diagnostics.migration_rollback || {};
    const finalize = diagnostics.migration_finalize || {};

    return [
      this.selectedProcessingCard,
      buildStateCard({
        title: "Copy",
        status: copy.status || "idle",
        detail: copy.current_key ? `Current object: ${truncate(copy.current_key, 80)}` : ((copy.status || "idle") === "idle" ? "Copy not started" : `${copy.objects_copied || 0} copied • ${copy.objects_skipped || 0} skipped`),
        meta: copy.progress_total ? `${copy.progress_index || 0} / ${copy.progress_total} objects` : ((copy.status || "idle") === "idle" ? "No copy queued" : `${copy.object_count || 0} objects`),
        error: copy.last_error_human || copy.last_error,
      }),
      buildStateCard({
        title: "Verify",
        status: verify.status || "idle",
        detail: verify.target_profile_key ? `${normalizeText(this.profileLabelForKey(verify.source_profile_key))} → ${normalizeText(this.profileLabelForKey(verify.target_profile_key))}` : "Target verification not run yet",
        meta: verify.target_profile_key ? (verify.missing_on_target_count === 0 ? "Target complete" : `${verify.missing_on_target_count || 0} objects still missing`) : "No verification recorded",
        error: verify.last_error_human || verify.last_error,
      }),
      buildStateCard({
        title: "Switch",
        status: switchState.status || "idle",
        detail: switchState.target_profile_key ? `${normalizeText(this.profileLabelForKey(switchState.source_profile_key))} → ${normalizeText(this.profileLabelForKey(switchState.target_profile_key))}` : "No switch recorded yet",
        meta: switchState.switched_at ? `Switched ${formatDateTime(switchState.switched_at)}` : "Waiting for switch",
        error: switchState.last_error_human || switchState.last_error,
      }),
      buildStateCard({
        title: "Cleanup",
        status: cleanup.status || "idle",
        detail: cleanup.current_role ? `Role: ${prettyLabel(cleanup.current_role)}` : ((cleanup.cleanup_mode === "inactive_target_after_rollback" || switchState.status === "rolled_back") ? "Inactive target cleanup not started" : "Source cleanup not started"),
        meta: cleanup.progress_total ? `${cleanup.progress_index || 0} / ${cleanup.progress_total} role groups` : `${cleanup.object_count || 0} objects to purge`,
        error: cleanup.last_error_human || cleanup.last_error,
      }),
      buildStateCard({
        title: "Rollback",
        status: rollback.status || "idle",
        detail: rollback.source_profile_key ? `Back to ${normalizeText(rollback.source_profile_key)}` : "Rollback not performed",
        meta: rollback.rolled_back_at ? `Rolled back ${formatDateTime(rollback.rolled_back_at)}` : "Source kept as rollback buffer until cleanup",
        error: rollback.last_error_human || rollback.last_error,
      }),
      buildStateCard({
        title: "Finalize",
        status: finalize.status || "idle",
        detail: finalize.status === "pending_cleanup" ? "Cleanup queued before finalization" : "Finalize marks the migrated item as complete",
        meta: finalize.finalized_at ? `Finalized ${formatDateTime(finalize.finalized_at)}` : (finalize.queued_at ? `Queued ${formatDateTime(finalize.queued_at)}` : "Not finalized"),
        error: finalize.last_error_human || finalize.last_error,
      }),
    ].filter(Boolean);
  }

  get selectedRoleCards() {
    const mediaType = String(this.selectedDiagnostics?.media_type || this.selectedItem?.media_type || "").toLowerCase();

    return safeArray(this.selectedDiagnostics?.roles).map((entry) => {
      const roleName = String(entry?.name || "role");
      const role = entry && typeof entry.role === "object" ? entry.role : null;
      const hasRoleData = !!(role && Object.keys(role).length > 0);
      const exists = entry?.exists;
      const backendLabel = titleCase(role?.backend || "unknown");
      const legacyLabel = role?.legacy ? "Legacy" : "Managed";
      const locator = summarizeLocator(role);

      if (roleName === "hls") {
        if (mediaType === "image") {
          return {
            name: titleCase(roleName),
            badgeClass: badgeClassForStatus("neutral"),
            existsLabel: "Not applicable",
            summaryLabel: "Images do not use HLS",
            locator: "—",
            contentType: "—",
          };
        }

        if (mediaType === "audio" && !hasRoleData) {
          return {
            name: titleCase(roleName),
            badgeClass: badgeClassForStatus("neutral"),
            existsLabel: "Not generated",
            summaryLabel: "Optional · Managed",
            locator: "—",
            contentType: "Audio can use HLS, but this item uses standard playback.",
          };
        }
      }

      const status = exists === true ? "ok" : exists === false ? "missing" : "neutral";

      return {
        name: titleCase(roleName),
        badgeClass: badgeClassForStatus(status),
        existsLabel: exists === true ? "Available" : exists === false ? "Missing" : normalizeText(exists),
        summaryLabel: `${backendLabel} · ${legacyLabel}`,
        locator: truncate(locator, 120),
        contentType: normalizeText(role?.content_type),
      };
    });
  }

  get selectedPlanSummary() {
    const plan = this.selectedPlan;
    if (!plan) {
      return null;
    }

    const totals = plan.totals || {};
    const source = plan.source || {};
    const target = plan.target || {};
    const missingCount = Number(totals.missing_on_target_count || 0);

    return {
      sourceLabel: `${titleCase(source.backend || "unknown")} / ${normalizeText(source.label || source.profile_key)}`,
      targetLabel: `${titleCase(target.backend || "unknown")} / ${normalizeText(target.label || target.profile_key)}`,
      objectCountLabel: String(totals.object_count || 0),
      objectCountCaption: "Objects on source",
      sourceBytesLabel: formatBytes(totals.source_bytes),
      targetExistingLabel: String(totals.target_existing_count || 0),
      targetExistingCaption: "Objects on target",
      targetExistingBytesLabel: formatBytes(totals.target_existing_bytes),
      missingCountLabel: String(missingCount),
      missingBadgeClass: badgeClassForStatus(missingCount === 0 ? "ok" : "warning"),
      switchReadinessLabel: missingCount === 0 ? "Ready to switch" : "Copy still missing target objects",
      warnings: safeArray(plan.warnings).map((warning) => titleCase(warning)),
    };
  }

  get selectedPlanRoleCards() {
    return safeArray(this.selectedPlan?.roles).map((entry) => {
      const summary = entry?.summary || {};
      const missingCount = Math.max(0, Number(summary.object_count || 0) - Number(summary.target_existing_count || 0));

      return {
        name: titleCase(entry?.name || "role"),
        backendLabel: titleCase(entry?.backend || "unknown"),
        objectCountLabel: String(summary.object_count || 0),
        sourceBytesLabel: formatBytes(summary.source_bytes),
        targetExistingLabel: String(summary.target_existing_count || 0),
        missingCountLabel: String(missingCount),
        missingBadgeClass: badgeClassForStatus(missingCount === 0 ? "ok" : "warning"),
        warnings: safeArray(entry?.warnings).map((warning) => titleCase(warning)),
      };
    });
  }

  get selectedHistoryEntries() {
    return safeArray(this.selectedDiagnostics?.migration_history).map((entry) => {
      const copy = entry?.copy || {};
      const verify = entry?.verify || {};
      const switchState = entry?.switch || {};
      const cleanup = entry?.cleanup || {};
      const rollback = entry?.rollback || {};
      const finalize = entry?.finalize || {};
      const sourceProfile = entry?.source_profile_key || copy?.source_profile_key || switchState?.source_profile_key || rollback?.source_profile_key;
      const targetProfile = entry?.target_profile_key || copy?.target_profile_key || switchState?.target_profile_key || finalize?.target_profile_key;
      const finishedAt = finalize?.finalized_at || rollback?.rolled_back_at || cleanup?.cleaned_at || switchState?.switched_at || copy?.copied_at || entry?.archived_at;

      return {
        title: sourceProfile && targetProfile ? `${normalizeText(this.profileLabelForKey(sourceProfile))} → ${normalizeText(this.profileLabelForKey(targetProfile))}` : "Previous migration run",
        meta: finishedAt ? `Completed ${formatDateTime(finishedAt)}` : `Archived ${formatDateTime(entry?.archived_at)}`,
        reason: entry?.reason ? titleCase(entry.reason) : "",
        badges: [
          { label: `Copy ${titleCase(copy?.status || "idle")}`, className: badgeClassForStatus(copy?.status || "neutral") },
          { label: `Verify ${titleCase(verify?.status || "idle")}`, className: badgeClassForStatus(verify?.status || "neutral") },
          { label: `Switch ${titleCase(switchState?.status || "idle")}`, className: badgeClassForStatus(switchState?.status || "neutral") },
          { label: `Cleanup ${titleCase(cleanup?.status || "idle")}`, className: badgeClassForStatus(cleanup?.status || "neutral") },
          rollback?.status ? { label: `Rollback ${titleCase(rollback.status)}`, className: badgeClassForStatus(rollback.status) } : null,
          finalize?.status ? { label: `Finalize ${titleCase(finalize.status)}`, className: badgeClassForStatus(finalize.status) } : null,
        ].filter(Boolean),
      };
    });
  }

  get hasSelectedHistory() {
    return this.selectedHistoryEntries.length > 0;
  }

  get rawPlanJson() {
    return this.selectedPlan ? JSON.stringify(this.selectedPlan, null, 2) : "";
  }

  get rawDiagnosticsJson() {
    return this.selectedDiagnostics ? JSON.stringify(this.selectedDiagnostics, null, 2) : "";
  }

  get activeStorageCard() {
    const profileName = this.activeHealth?.label || this.activeProfileSummary?.label || "Not configured";
    return this._buildStorageCard({
      title: "Default storage",
      profileName,
      selectionLabel: "Current profile",
      selectionValue: profileName,
      health: this.activeHealth,
      probe: this.activeProbe,
    });
  }

  get targetStorageCard() {
    const targetLabel = this.targetHealth?.label || this.selectedTargetProfileLabel || "Choose a destination";
    return this._buildStorageCard({
      title: "Destination storage",
      profileName: targetLabel,
      selectionLabel: "Migration destination",
      selectionValue: targetLabel,
      health: this.targetHealth,
      probe: this.targetProbe,
    });
  }

  _shouldAutoRefreshSelected() {
    if (!this.selectedPublicId || this.isLoadingSelection || this.isSearching) {
      return false;
    }

    const diagnostics = this.selectedDiagnostics || {};
    const mediaStatus = String(diagnostics?.status || this.selectedItem?.status || "");
    if (["queued", "processing"].includes(mediaStatus)) {
      return true;
    }

    const activeStatuses = [
      diagnostics?.migration_copy?.status,
      diagnostics?.migration_cleanup?.status,
      diagnostics?.migration_finalize?.status,
    ].filter(Boolean);

    return activeStatuses.some((status) => ["queued", "copying", "cleaning", "pending_cleanup"].includes(String(status)));
  }

  _startAutoRefresh() {
    if (this.autoRefreshTimer) {
      return;
    }

    this.autoRefreshTimer = window.setInterval(() => {
      this._pollSelected();
    }, this.autoRefreshIntervalMs);
  }

  _stopAutoRefresh() {
    if (this.autoRefreshTimer) {
      window.clearInterval(this.autoRefreshTimer);
      this.autoRefreshTimer = null;
      this.autoRefreshSearchCounter = 0;
    }
  }

  _syncAutoRefresh() {
    if (this._shouldAutoRefreshSelected()) {
      this._startAutoRefresh();
    } else {
      this._stopAutoRefresh();
    }
  }

  async _pollSelected() {
    if (
      document?.visibilityState === "hidden" ||
      !this.selectedPublicId ||
      this.isLoadingSelection ||
      this.isCopying ||
      this.isSwitching ||
      this.isCleaning ||
      this.isVerifying ||
      this.isRollingBack ||
      this.isFinalizing
    ) {
      return;
    }

    await this.refreshSelected({ preserveMessages: true, includeSearchRefresh: false, updateResults: false });
  }



  _isSameAsSourceProfile(profileKey) {
    if (!profileKey) {
      return false;
    }

    const sourceProfileKey = this.selectedDiagnostics?.managed_storage_profile || this.selectedItem?.managed_storage_profile;
    const sourceFingerprint = this.selectedSourceLocationFingerprintKey;
    const option = this.targetProfileOptions.find((entry) => entry.profile_key === profileKey);
    const targetFingerprint = option?.location_fingerprint_key;

    return !!(
      (sourceProfileKey && profileKey && sourceProfileKey === profileKey) ||
      (sourceFingerprint && targetFingerprint && sourceFingerprint === targetFingerprint)
    );
  }

  _preferredTargetProfileFromOptions(options = this.targetProfileOptions) {
    if (!options.length) {
      return "";
    }

    const current = this.selectedTargetProfileKey;
    if (current && options.some((entry) => entry.profile_key === current) && !this._isSameAsSourceProfile(current)) {
      return current;
    }

    const alternate = options.find((entry) => !this._isSameAsSourceProfile(entry.profile_key));
    return alternate?.profile_key || options[0]?.profile_key || "";
  }

  async _ensureValidSelectedTargetProfile() {
    const options = this.targetProfileOptions;
    if (!options.length) {
      return;
    }

    const current = this.selectedTargetProfileKey;
    const currentIsValid = options.some((entry) => entry.profile_key === current);
    if (currentIsValid && !this._isSameAsSourceProfile(current)) {
      return;
    }

    const nextProfile = this._preferredTargetProfileFromOptions(options);
    if (!nextProfile) {
      return;
    }

    this.selectedTargetProfile = nextProfile;
    this._persistTargetProfile(nextProfile);
    if (this.targetHealth?.profile_key !== nextProfile) {
      await this.loadStorageHealth(nextProfile);
    }
  }

  profileLabelForKey(profileKey) {
    if (!profileKey) {
      return "—";
    }

    const active = this.activeProfileSummary;
    if (active?.profile_key === profileKey) {
      return active?.label || profileKey;
    }

    const configured = (this.availableTargetProfiles || []).find((entry) => entry.profile_key === profileKey);
    if (configured?.label) {
      return configured.label;
    }

    switch (profileKey) {
      case "local":
      case "active_local":
      case "target_local":
        return "Local storage";
      case "s3_1":
      case "active_s3":
        return "S3 profile 1";
      case "s3_2":
      case "target_s3":
        return "S3 profile 2";
      case "s3_3":
      case "target_s3_2":
      case "target_s3_3":
        return "S3 profile 3";
      default:
        return profileKey;
    }
  }

  _buildStorageCard({ title, profileName, selectionLabel, selectionValue, health, probe }) {
    const config = health?.config || {};
    const backend = health?.backend || "unknown";
    const location =
      backend === "s3"
        ? [config.bucket, config.prefix].filter(Boolean).join(" / ") || config.bucket || "—"
        : config.local_asset_root_path || "—";

    const rows = [
      buildSummaryRow("Backend", titleCase(backend)),
      buildSummaryRow("Profile", health?.label ? `${health.label} (${health.profile_key || "—"})` : health?.profile_key),
      buildSummaryRow("Available", health?.available ? "Yes" : "No"),
      buildSummaryRow("Location", location),
      buildSummaryRow("Latency", health?.availability_ms ? `${health.availability_ms} ms` : "—"),
    ];

    if (backend === "s3") {
      rows.push(buildSummaryRow("Endpoint", config.endpoint));
      rows.push(buildSummaryRow("Region", config.region));
    }

    if (probe) {
      rows.push(buildSummaryRow("Probe", probe.ok ? "Passed" : "Failed"));
    }

    return {
      title,
      profileName: normalizeText(profileName || health?.label || "Not configured"),
      selectionLabel: normalizeText(selectionLabel || "Profile"),
      selectionValue: normalizeText(selectionValue || profileName || health?.label || "—"),
      badgeClass: badgeClassForStatus(health?.available ? "available" : "unavailable"),
      badgeLabel: health?.available ? "Healthy" : "Needs attention",
      rows,
      validationErrors: safeArray(health?.validation_errors).map((value) => titleCase(value)),
      probeNote: probe?.note || "",
      probeTimings: probe?.timings_ms
        ? Object.entries(probe.timings_ms).map(([label, value]) => ({
            label: titleCase(label.replace(/_ms$/i, "").replace(/_/g, " ")),
            value: `${value} ms`,
          }))
        : [],
    };
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

  _currentSearchParams() {
    const params = new URLSearchParams();
    const q = (this.searchQuery || "").trim();
    if (q) params.set("q", q);
    if (this.backendFilter && this.backendFilter !== "all") params.set("backend", this.backendFilter);
    if (this.profileFilter && this.profileFilter !== "all") params.set("profile", this.profileFilter);
    if (this.statusFilter && this.statusFilter !== "all") params.set("status", this.statusFilter);
    if (this.mediaTypeFilter && this.mediaTypeFilter !== "all") params.set("media_type", this.mediaTypeFilter);
    if (this.hlsFilter && this.hlsFilter !== "all") params.set("has_hls", this.hlsFilter === "yes" ? "true" : "false");
    params.set("limit", String(this.limit || 50));
    return params;
  }

  _actionHeaders() {
    return {
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
    };
  }

  _normalizePlanError(errorMessage) {
    const message = errorMessage == null ? "" : String(errorMessage);
    if (!message) return "";
    if (message.includes("source_and_target_same_profile")) {
      return "Source and target use the same profile. Change the target profile to preview a migration.";
    }
    if (message.includes("Internal Server Error")) {
      return "Could not build a migration plan for this item right now.";
    }
    return message;
  }

  @action onSearchInput(event) { this.searchQuery = event?.target?.value || ""; }
  @action onBackendFilterChange(event) { this.backendFilter = event?.target?.value || "all"; }
  @action onProfileFilterChange(event) { this.profileFilter = event?.target?.value || "all"; }
  @action onStatusFilterChange(event) { this.statusFilter = event?.target?.value || "all"; }
  @action onMediaTypeFilterChange(event) { this.mediaTypeFilter = event?.target?.value || "all"; }
  @action onHlsFilterChange(event) { this.hlsFilter = event?.target?.value || "all"; }
  @action onSortByChange(event) { this.sortBy = event?.target?.value || "created_at_desc"; }
  @action onLimitChange(event) {
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
  @action onBulkFullMigrationChange(event) { this.bulkFullMigration = !!event?.target?.checked; }
  @action onForceActionChange(event) { this.forceAction = !!event?.target?.checked; }

  @action
  async resetFilters() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.profileFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hlsFilter = "all";
    this.limit = 50;
    this.sortBy = "created_at_desc";
    this.bulkConfirm = false;
    this.bulkFullMigration = true;
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
    try {
      const params = this._currentSearchParams();
      const response = await fetch(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: controller.signal,
      });
      if (!response.ok) {
        this.searchError = await this._extractError(response);
        this.searchResults = [];
        return;
      }
      const json = await response.json();
      this.availableSearchProfiles = Array.isArray(json?.search_profiles) ? json.search_profiles : this.availableSearchProfiles;
      this.searchResults = Array.isArray(json?.items) ? json.items : [];
      const visibleIds = new Set(this.searchResults.map((row) => row.public_id));
      this.selectedBulkPublicIds = this.selectedBulkPublicIds.filter((publicId) => visibleIds.has(publicId));
      if (!this.selectedBulkPublicIds.length) {
        this.bulkConfirm = false;
      }
      this.searchInfo = `${this.searchResults.length} result(s).`;
      const refreshedSelection = this.searchResults.find((row) => row.public_id === this.selectedPublicId);
      if (refreshedSelection) {
        this.selectedItem = refreshedSelection;
      }
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.searchError = e?.message || String(e);
      this.searchResults = [];
    } finally {
      if (this.searchAbortController === controller) {
        this.searchAbortController = null;
      }
      this.isSearching = false;
      this._syncAutoRefresh();
    }
  }

  @action
  async selectItem(item, event) {
    event?.preventDefault?.();
    const publicId = item?.public_id;
    if (!publicId) return;

    const restoreScrollY = window.scrollY;
    this.selectedItem = item;
    this.selectedPublicId = publicId;
    this.selectedError = "";
    this.selectedPlanError = "";
    this.selectedVerification = null;
    this.selectedPlan = null;
    this.selectedPlanLoaded = false;
    this.lastActionMessage = "";
    this.actionError = "";
    await this.refreshSelected();
    event?.currentTarget?.blur?.();
    requestAnimationFrame(() => {
      window.scrollTo({ top: restoreScrollY, left: 0, behavior: "auto" });
    });
  }

  _mergeDiagnosticsIntoSelectedResults(diagnostics) {
    if (!this.selectedPublicId) {
      return;
    }

    const updatedResults = (this.searchResults || []).map((row) => {
      if (row.public_id !== this.selectedPublicId) {
        return row;
      }

      return {
        ...row,
        thumbnail_url: diagnostics?.thumbnail_url || row.thumbnail_url,
        managed_storage_backend: diagnostics?.managed_storage_backend || row.managed_storage_backend,
        managed_storage_profile: diagnostics?.managed_storage_profile || row.managed_storage_profile,
        managed_storage_profile_label: diagnostics?.managed_storage_profile_label || row.managed_storage_profile_label,
        managed_storage_location_fingerprint_key: diagnostics?.managed_storage_location_fingerprint_key || row.managed_storage_location_fingerprint_key,
        delivery_mode: diagnostics?.delivery_mode || row.delivery_mode,
        error_message: diagnostics?.error_message || row.error_message,
        status: diagnostics?.status || row.status,
      };
    });

    this.searchResults = updatedResults;

    const updatedSelection = updatedResults.find((row) => row.public_id === this.selectedPublicId);
    if (updatedSelection) {
      this.selectedItem = updatedSelection;
      return;
    }

    if (this.selectedItem?.public_id === this.selectedPublicId) {
      this.selectedItem = {
        ...this.selectedItem,
        thumbnail_url: diagnostics?.thumbnail_url || this.selectedItem.thumbnail_url,
        managed_storage_backend: diagnostics?.managed_storage_backend || this.selectedItem.managed_storage_backend,
        managed_storage_profile: diagnostics?.managed_storage_profile || this.selectedItem.managed_storage_profile,
        managed_storage_profile_label: diagnostics?.managed_storage_profile_label || this.selectedItem.managed_storage_profile_label,
        managed_storage_location_fingerprint_key:
          diagnostics?.managed_storage_location_fingerprint_key || this.selectedItem.managed_storage_location_fingerprint_key,
        delivery_mode: diagnostics?.delivery_mode || this.selectedItem.delivery_mode,
        error_message: diagnostics?.error_message || this.selectedItem.error_message,
        status: diagnostics?.status || this.selectedItem.status,
      };
    }
  }

  async refreshSelected(options = {}) {
    if (!this.selectedPublicId) return;

    this.selectionAbortController?.abort?.();
    const controller = new AbortController();
    this.selectionAbortController = controller;

    const preserveMessages = !!options.preserveMessages;
    const includeSearchRefresh = !!options.includeSearchRefresh;
    const updateResults = options.updateResults !== false;

    this.isLoadingSelection = true;
    if (!preserveMessages) {
      this.selectedError = "";
      this.selectedPlanError = "";
    }

    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const diagnostics = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/diagnostics.json`, {
        signal: controller.signal,
      });
      this.selectedDiagnostics = diagnostics;
      this.selectedVerification = diagnostics?.migration_verify || null;

      if (includeSearchRefresh) {
        await this.search();
      }

      if (updateResults || !includeSearchRefresh) {
        this._mergeDiagnosticsIntoSelectedResults(diagnostics);
      }

      await this._ensureValidSelectedTargetProfile();

      if (this.selectedPlanLoaded && this.canLoadSelectedPlan) {
        await this.loadSelectedPlan();
      } else if (!this.canLoadSelectedPlan) {
        this.selectedPlan = null;
        this.selectedPlanLoaded = false;
      }
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.selectedError = e?.message || String(e);
    } finally {
      if (this.selectionAbortController === controller) {
        this.selectionAbortController = null;
      }
      this.isLoadingSelection = false;
      this._syncAutoRefresh();
    }
  }

  @action
  async loadSelectedPlan() {
    if (!this.selectedPublicId || !this.canLoadSelectedPlan) {
      return;
    }

    this.isLoadingPlan = true;
    this.selectedPlanError = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const query = new URLSearchParams({ target_profile: this.selectedTargetProfileKey });
      this.selectedPlan = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/migration-plan.json?${query.toString()}`, {
        method: "GET",
      });
      this.selectedPlanLoaded = true;
    } catch (planError) {
      this.selectedPlan = null;
      this.selectedPlanLoaded = false;
      this.selectedPlanError = this._normalizePlanError(planError?.message || String(planError));
    } finally {
      this.isLoadingPlan = false;
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
        headers: this._actionHeaders(),
        body: JSON.stringify({
          target_profile: this.selectedTargetProfileKey,
          force: this.forceAction,
          auto_switch: this.autoSwitch,
          auto_cleanup: this.autoCleanup,
        }),
      });
      await this.refreshSelected({ includeSearchRefresh: false });
      const copyStatus = this.selectedDiagnostics?.migration_copy?.status;
      const copyError = this.selectedDiagnostics?.migration_copy?.last_error_human || this.selectedDiagnostics?.migration_copy?.last_error;
      if (copyStatus === "failed" && copyError) {
        this.actionError = copyError;
      } else if (copyStatus === "copied") {
        this.lastActionMessage = "Copy completed.";
      } else {
        this.lastActionMessage = "Copy queued/completed.";
      }
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isCopying = false;
    }
  }

  @action
  async verifyTarget() {
    if (!this.selectedPublicId) return;
    this.isVerifying = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const query = new URLSearchParams({ target_profile: this.selectedTargetProfileKey });
      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/verify-target.json?${query.toString()}`);
      this.selectedVerification = result?.verification || null;
      this.lastActionMessage = this.selectedVerification?.status === "verified"
        ? "Target verified. All objects are present."
        : "Verification completed. Check the state cards for details.";
      await this.refreshSelected();
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isVerifying = false;
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
        headers: this._actionHeaders(),
        body: JSON.stringify({
          target_profile: this.selectedTargetProfileKey,
          auto_cleanup: this.autoCleanup,
        }),
      });
      this.lastActionMessage = "Switch completed.";
      await this.refreshSelected({ includeSearchRefresh: false });
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
        headers: this._actionHeaders(),
        body: JSON.stringify({ force: this.forceAction }),
      });
      this.lastActionMessage = "Cleanup queued/completed.";
      await this.refreshSelected({ includeSearchRefresh: false });
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isCleaning = false;
    }
  }

  @action
  async rollbackToSource() {
    if (!this.selectedPublicId) return;
    this.isRollingBack = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/rollback-to-source.json`, {
        method: "POST",
        headers: this._actionHeaders(),
        body: JSON.stringify({ force: this.forceAction }),
      });
      this.lastActionMessage = "Rollback completed.";
      await this.refreshSelected({ includeSearchRefresh: false });
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isRollingBack = false;
    }
  }

  @action
  async finalizeMigration() {
    if (!this.selectedPublicId) return;
    this.isFinalizing = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/finalize-migration.json`, {
        method: "POST",
        headers: this._actionHeaders(),
        body: JSON.stringify({ force: this.forceAction }),
      });
      this.lastActionMessage = result?.migration_finalize?.status === "pending_cleanup"
        ? "Finalize is waiting for cleanup to finish."
        : ((result?.migration_finalize?.finalize_mode === "rolled_back") ? "Rollback finalized." : "Migration finalized.");
      await this.refreshSelected({ includeSearchRefresh: false });
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isFinalizing = false;
    }
  }


  @action
  async clearQueuedState() {
    if (!this.selectedPublicId) return;
    this.isLoadingSelection = true;
    this.actionError = "";
    this.lastActionMessage = "";
    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/clear-queued-state.json`, {
        method: "POST",
        headers: this._actionHeaders(),
      });
      this.lastActionMessage = result?.message || "Queued state cleared.";
      await this.refreshSelected({ includeSearchRefresh: false });
    } catch (e) {
      this.actionError = e?.message || String(e);
    } finally {
      this.isLoadingSelection = false;
    }
  }

  @action
  async bulkMigrate() {
    this.isBulkMigrating = true;
    this.bulkActionError = "";
    this.bulkActionMessage = "";
    try {
      const payload = {
        public_ids: [...this.selectedBulkPublicIds],
        target_profile: this.selectedTargetProfileKey,
        force: this.forceAction,
        auto_switch: this.bulkFullMigration ? false : this.autoSwitch,
        auto_cleanup: this.bulkFullMigration ? false : this.autoCleanup,
        full_migration: this.bulkFullMigration,
      };

      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/bulk-migrate.json`, {
        method: "POST",
        headers: this._actionHeaders(),
        body: JSON.stringify(payload),
      });

      this.bulkActionMessage = `${result?.queued_count || 0} selected item(s) queued for ${this.bulkModeLabel}, ${result?.skipped_count || 0} skipped.`;
      this.bulkConfirm = false;
      await this.search();
      if (this.hasSelectedItem) {
        await this.refreshSelected();
      }
    } catch (e) {
      this.bulkActionError = e?.message || String(e);
    } finally {
      this.isBulkMigrating = false;
    }
  }

  @action
  toggleBulkSelection(item, event) {
    event?.stopPropagation?.();
    const publicId = item?.public_id;
    if (!publicId) {
      return;
    }

    if (this.selectedBulkPublicIds.includes(publicId)) {
      this.selectedBulkPublicIds = this.selectedBulkPublicIds.filter((value) => value !== publicId);
    } else {
      this.selectedBulkPublicIds = [...this.selectedBulkPublicIds, publicId];
    }

    this.bulkConfirm = false;
  }

  @action
  selectAllVisible() {
    this.selectedBulkPublicIds = this.sortedResults.map((item) => item.public_id).filter(Boolean);
    this.bulkConfirm = false;
  }

  @action
  clearBulkSelection() {
    this.selectedBulkPublicIds = [];
    this.bulkConfirm = false;
  }

  @action
  onBulkConfirmChange(event) {
    this.bulkConfirm = !!event?.target?.checked;
  }

  @action
  async loadStorageHealth(profile) {
    this.storageAbortController?.abort?.();
    const controller = new AbortController();
    this.storageAbortController = controller;

    this.storageBusy = true;
    this.storageError = "";
    const requestedProfile = profile === "target" ? this.selectedTargetProfileKey : profile;
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/health.json?profile=${encodeURIComponent(requestedProfile)}`, { signal: controller.signal });
      if (profile === "active") {
        this.activeHealth = json;
      } else {
        this.targetHealth = json;
        this.selectedTargetProfile = json?.profile_key || requestedProfile;
        this._persistTargetProfile(this.selectedTargetProfile);
      }
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.storageError = e?.message || String(e);
    } finally {
      if (this.storageAbortController === controller) {
        this.storageAbortController = null;
      }
      this.storageBusy = false;
    }
  }

  @action
  async runStorageProbe(profile) {
    this.storageAbortController?.abort?.();
    const controller = new AbortController();
    this.storageAbortController = controller;

    this.storageBusy = true;
    this.storageError = "";
    const requestedProfile = profile === "target" ? this.selectedTargetProfileKey : profile;
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/probe.json`, {
        method: "POST",
        headers: this._actionHeaders(),
        body: JSON.stringify({ profile: requestedProfile }),
        signal: controller.signal,
      });
      if (profile === "active") this.activeProbe = json;
      else this.targetProbe = json;
    } catch (e) {
      if (e?.name === "AbortError") {
        return;
      }
      this.storageError = e?.message || String(e);
    } finally {
      if (this.storageAbortController === controller) {
        this.storageAbortController = null;
      }
      this.storageBusy = false;
    }
  }

  @action
  async loadTargetProfiles() {
    this.storageBusy = true;
    this.storageError = "";
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/profiles.json`);
      this.activeProfileSummary = json?.default_profile || json?.active_profile || null;
      this.availableTargetProfiles = Array.isArray(json?.profiles) ? json.profiles : (Array.isArray(json?.target_profiles) ? json.target_profiles : []);
      const preferred = json?.default_target_profile_key;
      const options = this.targetProfileOptions;
      const stored = this._readStoredTargetProfile();
      const storedOption = options.find((entry) => entry.profile_key === stored && !this._isSameAsSourceProfile(entry.profile_key));
      const preferredOption = options.find((entry) => entry.profile_key === preferred && !this._isSameAsSourceProfile(entry.profile_key));
      this.selectedTargetProfile = storedOption?.profile_key || preferredOption?.profile_key || this._preferredTargetProfileFromOptions(options) || this.availableTargetProfiles[0]?.profile_key || "";
      this._persistTargetProfile(this.selectedTargetProfile);
    } catch (e) {
      this.storageError = e?.message || String(e);
    } finally {
      this.storageBusy = false;
    }
  }

  @action
  async onTargetProfileChange(event) {
    this.selectedTargetProfile = event?.target?.value || "";
    this._persistTargetProfile(this.selectedTargetProfile);
    this.targetProbe = null;
    if (this.selectedTargetProfile) {
      await this.loadStorageHealth(this.selectedTargetProfile);
    }
    if (this.selectedPlanLoaded && this.canLoadSelectedPlan) {
      await this.loadSelectedPlan();
    } else if (!this.canLoadSelectedPlan) {
      this.selectedPlan = null;
      this.selectedPlanLoaded = false;
    }
  }
}
