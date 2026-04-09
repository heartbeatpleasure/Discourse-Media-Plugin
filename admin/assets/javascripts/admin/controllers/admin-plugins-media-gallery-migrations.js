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

const FRIENDLY_ERROR_MESSAGES = {
  backend_not_configured: "The backend is not configured.",
  copy_already_in_progress: "A copy job is already in progress for this item.",
  item_not_ready: "This item is not ready for migration yet.",
  item_not_resettable: "This item cannot be reset right now.",
  item_not_retryable: "This item cannot be retried right now.",
  media_item_required: "No media item was selected.",
  migration_plan_missing: "Could not build a migration plan for this item.",
  no_media_items_selected: "No media items were selected.",
  rollback_not_available: "Rollback is not available for the current state.",
  rollback_source_already_cleaned: "Rollback is not available because the source was already cleaned.",
  rollback_source_backend_missing: "Rollback is not available because the source backend is missing.",
  rollback_source_profile_missing: "Rollback is not available because the source profile is missing.",
  rollback_source_store_missing: "Rollback is not available because the source storage is missing.",
  source_and_target_same_profile: "Source and target use the same profile.",
  source_store_missing: "The source storage is not available.",
  target_profile_not_configured: "The target profile is not configured.",
  target_store_missing: "The target storage is not available.",
};

function prettyErrorMessage(value) {
  let message = value == null ? "" : String(value).trim();
  if (!message) {
    return "";
  }

  message = message.replace(/^\s*[A-Z]\w*(?:::[A-Z]\w*)*:\s*/, "");

  if (FRIENDLY_ERROR_MESSAGES[message]) {
    return FRIENDLY_ERROR_MESSAGES[message];
  }

  let match = message.match(/^copy_verification_incomplete:(\d+)$/);
  if (match) {
    const count = Number(match[1] || 0);
    return `Copy verification is incomplete. ${count} object(s) are still missing on the target.`;
  }

  match = message.match(/^rollback_source_missing:(.+)$/);
  if (match) {
    return `Rollback is not available because source data is missing (${prettyLabel(match[1])}).`;
  }

  match = message.match(/^source_object_missing:(.+)$/);
  if (match) {
    return `A source object is missing (${match[1]}).`;
  }

  if (/^[a-z0-9_:-]+$/i.test(message)) {
    return titleCase(message.replace(/:/g, " - "));
  }

  return message;
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
    case "switched":
    case "cleaned":
    case "ok":
    case "available":
      return "success";
    case "queued":
    case "copying":
    case "processing":
    case "cleaning":
      return "warning";
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
    error: error ? truncate(prettyErrorMessage(error), 220) : "",
  };
}

export default class AdminPluginsMediaGalleryMigrationsController extends Controller {
  @tracked searchQuery = "";
  @tracked backendFilter = "all";
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
  @tracked activeProbe = null;
  @tracked targetProbe = null;
  @tracked storageError = "";
  @tracked storageBusy = false;

  resetState() {
    this.searchQuery = "";
    this.backendFilter = "all";
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
        profileLabel: normalizeText(item.managed_storage_profile),
        statusLabel: titleCase(item.status || "unknown"),
        statusClass: badgeClassForStatus(item.status),
        mediaTypeLabel: mediaType,
        mediaTypeClass: "mg-migrations__badge",
        hasHlsLabel: item.has_hls ? "HLS" : "No HLS",
        hlsClass: badgeClassForStatus(item.has_hls ? "ok" : "neutral"),
        metaLabel: metaParts.join(" • "),
        thumbnailUrl: item.thumbnail_url || `/media/${encodeURIComponent(item.public_id)}/thumbnail`,
        sizeLabel: formatBytes(item.filesize_processed_bytes),
      };
    });
  }

  get hasSearchResults() {
    return this.resultCards.length > 0;
  }

  get hasSelectedItem() {
    return !!this.selectedPublicId;
  }

  get selectedSourceProfileKey() {
    return this.selectedDiagnostics?.managed_storage_profile || this.selectedItem?.managed_storage_profile || "";
  }

  get isSameSourceAndTargetProfile() {
    const sourceProfileKey = this.selectedSourceProfileKey;
    const targetProfileKey = this.targetHealth?.profile_key || "";
    return !!(sourceProfileKey && targetProfileKey && sourceProfileKey === targetProfileKey);
  }

  get copyStatus() {
    return (this.selectedDiagnostics?.migration_copy?.status || "").toString();
  }

  get copyStateMatchesSelection() {
    const copyState = this.selectedDiagnostics?.migration_copy || {};
    const sourceProfileKey = this.selectedSourceProfileKey;
    const targetProfileKey = this.targetHealth?.profile_key || "";

    if (!copyState.source_profile_key || !copyState.target_profile_key) {
      return true;
    }

    return copyState.source_profile_key === sourceProfileKey && copyState.target_profile_key === targetProfileKey;
  }

  get cleanupStatus() {
    return (this.selectedDiagnostics?.migration_cleanup?.status || "").toString();
  }

  get finalizeStatus() {
    return (this.selectedDiagnostics?.migration_finalize?.status || "").toString();
  }

  get copyDisabled() {
    if (!this.hasSelectedItem || this.isCopying || this.isSwitching || this.isCleaning) {
      return true;
    }

    if (this.isSameSourceAndTargetProfile && !this.forceAction) {
      return true;
    }

    return ["queued", "copying"].includes(this.copyStatus) && this.copyStateMatchesSelection && !this.forceAction;
  }

  get switchDisabled() {
    if (!this.hasSelectedItem || this.isSwitching || this.isCopying || this.isCleaning) {
      return true;
    }

    return this.isSameSourceAndTargetProfile && !this.forceAction;
  }

  get cleanupDisabled() {
    if (!this.hasSelectedItem || this.isCleaning || this.isCopying || this.isSwitching || this.isRollingBack || this.isFinalizing) {
      return true;
    }

    return ["cleaned", "finalized"].includes(this.cleanupStatus) || this.finalizeStatus === "finalized";
  }

  get verifyDisabled() {
    if (!this.hasSelectedItem || this.isVerifying || this.isLoadingSelection || this.isRollingBack || this.isFinalizing) {
      return true;
    }

    return this.isSameSourceAndTargetProfile && !this.forceAction;
  }

  get rollbackDisabled() {
    if (!this.hasSelectedItem || this.isRollingBack || this.isCopying || this.isSwitching || this.isCleaning || this.isFinalizing) {
      return true;
    }

    return this.cleanupStatus === "cleaned" || this.finalizeStatus === "finalized";
  }

  get finalizeDisabled() {
    if (!this.hasSelectedItem || this.isFinalizing || this.isRollingBack || this.isCopying || this.isSwitching) {
      return true;
    }

    return this.finalizeStatus === "finalized";
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
    return this.isBulkMigrating || this.isSearching || !this.hasBulkSelection || !this.bulkConfirm;
  }

  get selectedTargetProfileKey() {
    return this.targetHealth?.profile_key || "target";
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
    return !this.isSameSourceAndTargetProfile;
  }

  get selectedPlanHint() {
    if (!this.hasSelectedItem) {
      return "Select an item to inspect its migration preview.";
    }
    if (this.isSameSourceAndTargetProfile) {
      return "Source and target use the same profile. Change the target profile to preview a migration.";
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
    if (!this.selectedPublicId) {
      return "";
    }

    return this.selectedItem?.thumbnail_url || `/media/${encodeURIComponent(this.selectedPublicId)}/thumbnail`;
  }

  get selectedSummaryRows() {
    const diagnostics = this.selectedDiagnostics || {};
    const item = this.selectedItem || {};

    return [
      buildSummaryRow("Public ID", this.selectedPublicId),
      buildSummaryRow("Type", titleCase(diagnostics.media_type || item.media_type || "unknown")),
      buildSummaryRow("Uploaded by", diagnostics.username || item.username),
      buildSummaryRow("Created", item.created_at ? formatDateTime(item.created_at) : (diagnostics.created_at ? formatDateTime(diagnostics.created_at) : null)),
      buildSummaryRow("Backend / profile", `${normalizeText(diagnostics.managed_storage_backend || item.managed_storage_backend)} / ${normalizeText(diagnostics.managed_storage_profile || item.managed_storage_profile)}`),
      buildSummaryRow("Delivery", diagnostics.delivery_mode),
      buildSummaryRow("Status", titleCase(diagnostics.status || item.status || "unknown")),
    ];
  }

  get selectedProcessingCard() {
    if (!this.hasSelectedItem) {
      return null;
    }

    const diagnostics = this.selectedDiagnostics || {};
    const processing = diagnostics.processing || {};
    const stage = processing.current_stage || processing.last_stage || processing.last_failed_stage || "—";
    const stale = diagnostics.processing_stale ? `Stale after ${diagnostics.processing_stale_after_minutes} min` : "Live state";

    return buildStateCard({
      title: "Processing",
      status: diagnostics.status || this.selectedItem?.status,
      detail: `Stage: ${prettyLabel(stage)}`,
      meta: stale,
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
        detail: copy.current_key ? `Current object: ${truncate(copy.current_key, 80)}` : `${copy.objects_copied || 0} copied • ${copy.objects_skipped || 0} skipped`,
        meta: copy.progress_total ? `${copy.progress_index || 0} / ${copy.progress_total} objects` : `${copy.object_count || 0} objects`,
        error: copy.last_error,
      }),
      buildStateCard({
        title: "Verify",
        status: verify.status || "idle",
        detail: verify.target_profile_key ? `${normalizeText(verify.source_profile_key)} → ${normalizeText(verify.target_profile_key)}` : "Target verification not run yet",
        meta: verify.missing_on_target_count === 0 ? "Target complete" : `${verify.missing_on_target_count || 0} objects still missing`,
        error: verify.last_error,
      }),
      buildStateCard({
        title: "Switch",
        status: switchState.status || "idle",
        detail: switchState.target_profile_key ? `${normalizeText(switchState.source_profile_key)} → ${normalizeText(switchState.target_profile_key)}` : "No switch recorded yet",
        meta: switchState.switched_at ? `Switched ${formatDateTime(switchState.switched_at)}` : "Waiting for switch",
        error: switchState.last_error,
      }),
      buildStateCard({
        title: "Cleanup",
        status: cleanup.status || "idle",
        detail: cleanup.current_role ? `Role: ${prettyLabel(cleanup.current_role)}` : "Source cleanup not started",
        meta: cleanup.progress_total ? `${cleanup.progress_index || 0} / ${cleanup.progress_total} role groups` : `${cleanup.object_count || 0} source objects`,
        error: cleanup.last_error,
      }),
      buildStateCard({
        title: "Rollback",
        status: rollback.status || "idle",
        detail: rollback.source_profile_key ? `Back to ${normalizeText(rollback.source_profile_key)}` : "Rollback not performed",
        meta: rollback.rolled_back_at ? `Rolled back ${formatDateTime(rollback.rolled_back_at)}` : "Source kept as rollback buffer until cleanup",
        error: rollback.last_error,
      }),
      buildStateCard({
        title: "Finalize",
        status: finalize.status || "idle",
        detail: finalize.status === "pending_cleanup" ? "Cleanup queued before finalization" : "Finalize marks the migrated item as complete",
        meta: finalize.finalized_at ? `Finalized ${formatDateTime(finalize.finalized_at)}` : (finalize.queued_at ? `Queued ${formatDateTime(finalize.queued_at)}` : "Not finalized"),
        error: finalize.last_error,
      }),
    ].filter(Boolean);
  }

  get selectedRoleCards() {
    return safeArray(this.selectedDiagnostics?.roles).map((entry) => {
      const role = entry?.role || {};
      const exists = entry?.exists;
      const status = exists === true ? "ok" : exists === false ? "missing" : "neutral";
      const locator = summarizeLocator(role);

      return {
        name: titleCase(entry?.name || "role"),
        badgeClass: badgeClassForStatus(status),
        existsLabel: exists === true ? "Available" : exists === false ? "Missing" : normalizeText(exists),
        backendLabel: titleCase(role.backend || "unknown"),
        locator: truncate(locator, 120),
        legacyLabel: role.legacy ? "Legacy" : "Managed",
        contentType: normalizeText(role.content_type),
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
      sourceLabel: `${titleCase(source.backend || "unknown")} / ${normalizeText(source.profile_key)}`,
      targetLabel: `${titleCase(target.backend || "unknown")} / ${normalizeText(target.profile_key)}`,
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

  get rawPlanJson() {
    return this.selectedPlan ? JSON.stringify(this.selectedPlan, null, 2) : "";
  }

  get rawDiagnosticsJson() {
    return this.selectedDiagnostics ? JSON.stringify(this.selectedDiagnostics, null, 2) : "";
  }

  get activeStorageCard() {
    return this._buildStorageCard({
      title: "Active storage",
      health: this.activeHealth,
      probe: this.activeProbe,
    });
  }

  get targetStorageCard() {
    return this._buildStorageCard({
      title: "Target storage",
      health: this.targetHealth,
      probe: this.targetProbe,
    });
  }

  _buildStorageCard({ title, health, probe }) {
    const config = health?.config || {};
    const backend = health?.backend || "unknown";
    const location =
      backend === "s3"
        ? [config.bucket, config.prefix].filter(Boolean).join(" / ") || config.bucket || "—"
        : config.local_asset_root_path || "—";

    const rows = [
      buildSummaryRow("Backend", titleCase(backend)),
      buildSummaryRow("Profile", health?.profile_key),
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
        return prettyErrorMessage(json.errors.join(" "));
      }
      if (json?.error) return prettyErrorMessage(json.error);
      if (json?.message) return prettyErrorMessage(json.message);
    } catch {
      // ignore
    }
    try {
      const text = await response.text();
      if (text) return prettyErrorMessage(truncate(text, 600));
    } catch {
      // ignore
    }
    return prettyErrorMessage(`HTTP ${response.status}`);
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
    return prettyErrorMessage(message);
  }

  @action onSearchInput(event) { this.searchQuery = event?.target?.value || ""; }
  @action onBackendFilterChange(event) { this.backendFilter = event?.target?.value || "all"; }
  @action onStatusFilterChange(event) { this.statusFilter = event?.target?.value || "all"; }
  @action onMediaTypeFilterChange(event) { this.mediaTypeFilter = event?.target?.value || "all"; }
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
  async resetFilters() {
    this.searchQuery = "";
    this.backendFilter = "all";
    this.statusFilter = "all";
    this.mediaTypeFilter = "all";
    this.hlsFilter = "all";
    this.limit = 50;
    this.sortBy = "created_at_desc";
    await this.search();
  }

  @action
  async search() {
    this.isSearching = true;
    this.searchError = "";
    this.searchInfo = "";
    try {
      const params = this._currentSearchParams();
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
      this.searchError = prettyErrorMessage(e?.message || String(e));
      this.searchResults = [];
    } finally {
      this.isSearching = false;
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

  @action
  async refreshSelected() {
    if (!this.selectedPublicId) return;
    this.isLoadingSelection = true;
    this.selectedError = "";
    this.selectedPlanError = "";

    try {
      const publicId = encodeURIComponent(this.selectedPublicId);
      const diagnostics = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/diagnostics.json`);
      this.selectedDiagnostics = diagnostics;
      this.selectedVerification = diagnostics?.migration_verify || null;

      const refreshedSelection = this.searchResults.find((row) => row.public_id === this.selectedPublicId);
      if (refreshedSelection) {
        this.selectedItem = refreshedSelection;
      }

      const targetProfileKey = this.targetHealth?.profile_key;
      const sourceProfileKey = diagnostics?.managed_storage_profile;
      if (targetProfileKey && sourceProfileKey && targetProfileKey === sourceProfileKey) {
        this.selectedPlan = null;
        this.selectedPlanLoaded = false;
      } else if (this.selectedPlanLoaded) {
        await this.loadSelectedPlan();
      }
    } catch (e) {
      this.selectedError = prettyErrorMessage(e?.message || String(e));
    } finally {
      this.isLoadingSelection = false;
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
      this.selectedPlan = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/migration-plan.json`, {
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
      this.actionError = prettyErrorMessage(e?.message || String(e));
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
      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/${publicId}/verify-target.json`);
      this.selectedVerification = result?.verification || null;
      this.lastActionMessage = this.selectedVerification?.status === "verified"
        ? "Target verified. All objects are present."
        : "Verification completed. Check the state cards for details.";
      await this.refreshSelected();
    } catch (e) {
      this.actionError = prettyErrorMessage(e?.message || String(e));
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
          target_profile: "target",
          auto_cleanup: this.autoCleanup,
        }),
      });
      this.lastActionMessage = "Switch completed.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = prettyErrorMessage(e?.message || String(e));
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
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = prettyErrorMessage(e?.message || String(e));
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
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = prettyErrorMessage(e?.message || String(e));
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
        ? "Finalize queued cleanup first. Run finalize again after cleanup completes."
        : "Migration finalized.";
      await this.refreshSelected();
      await this.search();
    } catch (e) {
      this.actionError = prettyErrorMessage(e?.message || String(e));
    } finally {
      this.isFinalizing = false;
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
        target_profile: "target",
        force: this.forceAction,
        auto_switch: this.autoSwitch,
        auto_cleanup: this.autoCleanup,
      };

      const result = await this._fetchJson(`/admin/plugins/media-gallery/media-items/bulk-migrate.json`, {
        method: "POST",
        headers: this._actionHeaders(),
        body: JSON.stringify(payload),
      });

      this.bulkActionMessage = `${result?.queued_count || 0} selected item(s) queued, ${result?.skipped_count || 0} skipped.`;
      this.bulkConfirm = false;
      await this.search();
      if (this.hasSelectedItem) {
        await this.refreshSelected();
      }
    } catch (e) {
      this.bulkActionError = prettyErrorMessage(e?.message || String(e));
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
    this.storageBusy = true;
    this.storageError = "";
    try {
      const json = await this._fetchJson(`/admin/plugins/media-gallery/storage/health.json?profile=${encodeURIComponent(profile)}`);
      if (profile === "active") this.activeHealth = json;
      else this.targetHealth = json;
    } catch (e) {
      this.storageError = prettyErrorMessage(e?.message || String(e));
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
        headers: this._actionHeaders(),
        body: JSON.stringify({ profile }),
      });
      if (profile === "active") this.activeProbe = json;
      else this.targetProbe = json;
    } catch (e) {
      this.storageError = prettyErrorMessage(e?.message || String(e));
    } finally {
      this.storageBusy = false;
    }
  }
}
