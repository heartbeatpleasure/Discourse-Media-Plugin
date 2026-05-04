import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

function severityRank(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return 2;
    case "warning":
      return 1;
    default:
      return 0;
  }
}

function severityLabel(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return "Critical";
    case "warning":
      return "Warning";
    default:
      return "OK";
  }
}

function badgeClass(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return "is-danger";
    case "warning":
      return "is-warning";
    default:
      return "is-success";
  }
}

function iconFor(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return "×";
    case "warning":
      return "!";
    default:
      return "✓";
  }
}

function stringify(value) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }
  return String(value);
}

function formatNumber(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) {
    return "0";
  }
  return new Intl.NumberFormat().format(number);
}

function formatDateTime(value, options = {}) {
  if (!value) {
    return "—";
  }

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }

  const formatted = new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);

  return options.showLocalSuffix ? `${formatted} (local time)` : formatted;
}

function formatRelativeTime(value) {
  if (!value || typeof Intl.RelativeTimeFormat !== "function") {
    return "";
  }

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }

  let seconds = Math.round((date.getTime() - Date.now()) / 1000);
  const divisions = [
    { amount: 60, unit: "second" },
    { amount: 60, unit: "minute" },
    { amount: 24, unit: "hour" },
    { amount: 7, unit: "day" },
    { amount: 4.345, unit: "week" },
    { amount: 12, unit: "month" },
    { amount: Number.POSITIVE_INFINITY, unit: "year" },
  ];

  for (const division of divisions) {
    if (Math.abs(seconds) < division.amount) {
      return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(Math.round(seconds), division.unit);
    }
    seconds = seconds / division.amount;
  }

  return "";
}

function formatDuration(value) {
  const ms = Number(value || 0);
  if (!Number.isFinite(ms) || ms <= 0) {
    return "—";
  }

  if (ms < 1000) {
    return `${Math.round(ms)} ms`;
  }

  const seconds = ms / 1000;
  if (seconds < 60) {
    return `${seconds.toFixed(seconds >= 10 ? 0 : 1)} s`;
  }

  return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
}

function profileLabel(profile) {
  return String(profile?.display_label || profile?.label || "").trim();
}

function profileTechnicalLabel(profile) {
  return String(profile?.profile_key || profile?.backend || "profile").trim();
}

function profileStatusLabel(profile) {
  switch (String(profile?.status || "checked")) {
    case "unavailable":
      return "Unavailable";
    case "failed":
      return "Scan failed";
    case "pending":
      return "Pending";
    default:
      return "Checked";
  }
}

function profileStatusClass(profile) {
  switch (String(profile?.status || "checked")) {
    case "unavailable":
    case "failed":
      return "is-warning";
    default:
      return "is-success";
  }
}

function decorateExample(example) {
  const title = stringify(example?.title || example?.public_id || example?.label);
  const subtitleParts = [];

  if (example?.public_id) {
    subtitleParts.push(example.public_id);
  }
  if (example?.status) {
    subtitleParts.push(example.status);
  }
  if (example?.age) {
    subtitleParts.push(example.age);
  }
  if (example?.missing) {
    subtitleParts.push(`missing: ${example.missing}`);
  }
  const profileLabel = example?.profile_display_label || example?.profile_label || example?.profile_key;
  if (profileLabel) {
    subtitleParts.push(`profile: ${profileLabel}`);
  }
  if (example?.backend) {
    subtitleParts.push(`backend: ${example.backend}`);
  }
  if (example?.role) {
    subtitleParts.push(`role: ${example.role}`);
  }
  if (example?.storage_key) {
    subtitleParts.push(`key: ${example.storage_key}`);
  }
  if (example?.error) {
    subtitleParts.push(example.error);
  }

  return {
    ...example,
    key: example?.key || `${example?.issue_type || "issue"}:${example?.public_id || title}`,
    issueType: example?.issue_type || "missing_ready_asset",
    title,
    subtitle: subtitleParts.filter(Boolean).join(" • "),
    detail: example?.detail || "",
    suggestion: example?.suggestion || "",
    hasDetail: Boolean(example?.detail),
    hasSuggestion: Boolean(example?.suggestion),
    url: example?.url || null,
    canIgnore: Boolean(example?.can_ignore && (example?.key || example?.public_id)),
  };
}

function decorateIssue(issue) {
  const severity = issue?.severity || "ok";
  const examples = Array.isArray(issue?.examples)
    ? issue.examples.map(decorateExample)
    : [];
  const sectionTitle =
    issue?.section_title || issue?.metadata?.section_title || "Health issue";

  return {
    ...issue,
    sectionTitle,
    severity,
    severityLabel: severityLabel(severity),
    badgeClass: badgeClass(severity),
    icon: iconFor(severity),
    iconClass: badgeClass(severity),
    countLabel:
      issue?.count === null || issue?.count === undefined
        ? ""
        : formatNumber(issue.count),
    examples,
    hasExamples: examples.length > 0,
    hasDetail: Boolean(issue?.detail),
  };
}

function decorateSection(section) {
  const issues = Array.isArray(section?.items)
    ? section.items.map(decorateIssue).sort((a, b) => severityRank(b.severity) - severityRank(a.severity))
    : [];
  const severity = section?.severity || "ok";

  return {
    ...section,
    severity,
    severityLabel: severityLabel(severity),
    badgeClass: badgeClass(severity),
    issues,
    hasHelp: Boolean(section?.help),
  };
}

function decorateCard(card) {
  const severity = card?.severity || "ok";
  const badge = badgeClass(severity);
  return {
    ...card,
    severity,
    severityLabel: severityLabel(severity),
    badgeClass: badge,
    dotClass: `mg-health__status-dot ${badge}`,
    value: stringify(card?.value),
  };
}

function decorateIgnoredFinding(finding) {
  const expiresAt = finding?.expires_at;
  return {
    ...finding,
    key: finding?.key || `${finding?.issue_type || "issue"}:${finding?.public_id || "unknown"}`,
    issueType: finding?.issue_type || "missing_ready_asset",
    title: stringify(finding?.title || finding?.public_id || "Media item"),
    subtitle: [finding?.public_id, finding?.ignored_by_username ? `ignored by ${finding.ignored_by_username}` : "", formatDateTime(finding?.ignored_at, { showLocalSuffix: true })]
      .filter(Boolean)
      .join(" • "),
    expiresAtLabel: expiresAt ? formatDateTime(expiresAt, { showLocalSuffix: true }) : "Never",
    url: finding?.url || null,
  };
}

function decorateHistoryEntry(entry) {
  const severity = entry?.severity || "ok";
  const profiles = Array.isArray(entry?.profile_labels) ? entry.profile_labels.filter(Boolean) : [];
  const truncated = Array.isArray(entry?.truncated_profile_labels) ? entry.truncated_profile_labels.filter(Boolean) : [];

  return {
    ...entry,
    severity,
    severityLabel: severityLabel(severity),
    badgeClass: badgeClass(severity),
    generatedAtLabel: formatDateTime(entry?.generated_at),
    generatedAtRelativeLabel: formatRelativeTime(entry?.generated_at),
    durationLabel: formatDuration(entry?.duration_ms),
    activeFindingsLabel: formatNumber(entry?.active_findings_count || 0),
    ignoredFindingsLabel: formatNumber(entry?.ignored_findings_count || 0),
    newFindingsLabel: formatNumber(entry?.new_findings_count || 0),
    resolvedFindingsLabel: formatNumber(entry?.resolved_findings_count || 0),
    itemsCheckedLabel: formatNumber(entry?.items_checked || 0),
    objectsScannedLabel: formatNumber(entry?.objects_scanned || 0),
    profilesLabel: profiles.length ? profiles.join(", ") : "—",
    truncatedProfilesLabel: truncated.length ? truncated.join(", ") : "",
  };
}

export default class AdminPluginsMediaGalleryHealthController extends Controller {
  @tracked isLoading = false;
  @tracked isFullStorage = false;
  @tracked error = "";
  @tracked notice = "";
  @tracked data = null;
  @tracked summaryCards = [];
  @tracked sections = [];
  @tracked attentionIssues = [];
  @tracked ignoredFindings = [];
  @tracked reconciliation = null;
  @tracked reconciliationHistory = [];
  @tracked exportCategory = "all";
  @tracked ignoreModalOpen = false;
  @tracked ignoreIssue = null;
  @tracked ignoreExample = null;
  @tracked ignoreReason = "";
  @tracked ignoreExpiresInDays = "0";

  resetState() {
    this.isLoading = false;
    this.isFullStorage = false;
    this.error = "";
    this.notice = "";
    this.data = null;
    this.summaryCards = [];
    this.sections = [];
    this.attentionIssues = [];
    this.ignoredFindings = [];
    this.reconciliation = null;
    this.reconciliationHistory = [];
    this.exportCategory = "all";
    this.ignoreModalOpen = false;
    this.ignoreIssue = null;
    this.ignoreExample = null;
    this.ignoreReason = "";
    this.ignoreExpiresInDays = "0";
  }

  get overallSeverity() {
    return this.data?.severity || "ok";
  }

  get overallSeverityLabel() {
    return severityLabel(this.overallSeverity);
  }

  get overallBadgeClass() {
    return badgeClass(this.overallSeverity);
  }

  get generatedAtLabel() {
    return formatDateTime(this.data?.generated_at, { showLocalSuffix: true });
  }

  get generatedAtRelativeLabel() {
    return formatRelativeTime(this.data?.generated_at);
  }

  get alertStateRows() {
    const state = this.data?.alert_state || {};
    return [
      { label: "Notify group", value: stringify(state.group || "admins") },
      { label: "Last sent", value: formatDateTime(state.sent_at) },
      { label: "Last attempted", value: formatDateTime(state.attempted_at) },
      { label: "Last error", value: stringify(state.error) },
    ];
  }

  get hasAttentionIssues() {
    return this.attentionIssues.length > 0;
  }

  get operationalSafetyCards() {
    const storageSection = this.sections.find((section) => section?.id === "storage") || {};
    const processingSection = this.sections.find((section) => section?.id === "processing") || {};
    const storageSafetyIssues = (storageSection.issues || []).filter((issue) =>
      String(issue?.id || "").startsWith("storage_profile_safety_")
    );
    const staleTempIssue = (processingSection.issues || []).find((issue) => issue?.id === "stale_temp_workspaces");

    const storageSeverity = storageSafetyIssues.length
      ? storageSafetyIssues.reduce((highest, issue) => severityRank(issue.severity) > severityRank(highest) ? issue.severity : highest, "ok")
      : "ok";

    const storageMessages = storageSafetyIssues.map((issue) => issue.message || issue.label).filter(Boolean);

    return [
      {
        label: "Storage profile safety",
        value: storageSafetyIssues.length ? `${storageSafetyIssues.length} warning${storageSafetyIssues.length === 1 ? "" : "s"}` : "OK",
        detail: storageMessages.length ? storageMessages.join(" • ") : "No storage profile safety warnings found.",
        severity: storageSeverity,
        badgeClass: badgeClass(storageSeverity),
        severityLabel: severityLabel(storageSeverity),
      },
      {
        label: "Temp/workspace cleanup",
        value: staleTempIssue?.countLabel || "0",
        detail: staleTempIssue?.detail || staleTempIssue?.message || "No stale Media Gallery temp workspaces found.",
        severity: staleTempIssue?.severity || "ok",
        badgeClass: badgeClass(staleTempIssue?.severity || "ok"),
        severityLabel: severityLabel(staleTempIssue?.severity || "ok"),
      },
    ];
  }

  get hasOperationalSafetyCards() {
    return this.operationalSafetyCards.length > 0;
  }

  get hasIgnoredFindings() {
    return this.ignoredFindings.length > 0;
  }

  get hasReconciliation() {
    return !!this.reconciliation;
  }

  get hasReconciliationHistory() {
    return this.reconciliationHistory.length > 0;
  }

  get decoratedReconciliationHistory() {
    return this.reconciliationHistory.map(decorateHistoryEntry);
  }

  get reconciliationExportCategories() {
    const categories = Array.isArray(this.reconciliation?.categories) ? this.reconciliation.categories : [];
    return [
      { id: "all", title: "All categories" },
      ...categories.map((category) => ({
        id: category.id,
        title: `${category.title || category.id} (${formatNumber(category.active_count || 0)} active)`,
      })),
    ];
  }

  get ignoreTargetTitle() {
    return stringify(this.ignoreExample?.title || "this finding");
  }

  get ignoreSubmitDisabled() {
    return this.isLoading || !this.ignoreExample?.key;
  }

  get reconciliationGeneratedAtLabel() {
    return formatDateTime(this.reconciliation?.generated_at);
  }

  get reconciliationActiveFindingsCount() {
    return formatNumber(this.reconciliation?.active_findings_count || 0);
  }

  get reconciliationIgnoredFindingsCount() {
    return formatNumber(this.reconciliation?.ignored_findings_count || 0);
  }

  get reconciliationStatsRows() {
    const stats = this.reconciliation?.stats || {};
    const limits = this.reconciliation?.limits || {};
    const truncatedProfiles = Array.isArray(stats.truncated_profile_labels) && stats.truncated_profile_labels.length
      ? stats.truncated_profile_labels.filter(Boolean)
      : (Array.isArray(stats.truncated_profiles) ? stats.truncated_profiles.filter(Boolean) : []);
    const profileCount = Number(stats.profiles_checked || 0);
    const objectLimit = Number(limits.object_limit || 0);
    const itemLimit = Number(limits.item_limit || 0);

    return [
      { label: "Last run", value: formatDateTime(this.reconciliation?.generated_at) },
      {
        label: "Since last run",
        value: formatRelativeTime(this.reconciliation?.generated_at) || "—",
        help: "Relative time since the latest storage reconciliation run.",
      },
      { label: "Duration", value: formatDuration(this.reconciliation?.duration_ms) },
      {
        label: "Scan completeness",
        value: truncatedProfiles.length ? "Partial" : "Complete",
        help: truncatedProfiles.length
          ? `One or more profiles reached the per-profile object limit: ${truncatedProfiles.join(", ")}. The scan is still read-only, but orphan detection may be incomplete for those profiles.`
          : "No checked storage profile reached the per-profile object limit.",
      },
      { label: "Active findings", value: this.reconciliationActiveFindingsCount },
      { label: "Ignored findings", value: this.reconciliationIgnoredFindingsCount },
      {
        label: "New",
        value: formatNumber(this.reconciliation?.new_findings_count || 0),
        help: "New active finding keys compared with the previous reconciliation run.",
      },
      {
        label: "Resolved",
        value: formatNumber(this.reconciliation?.resolved_findings_count || 0),
        help: "Finding keys from the previous run that are no longer present in the latest run.",
      },
      {
        label: "Items checked",
        value: formatNumber(stats.items_checked || 0),
        help: itemLimit
          ? `Media records are checked up to the item limit for each run. Current item limit: ${formatNumber(itemLimit)}.`
          : "Media records checked during this reconciliation run.",
      },
      {
        label: "Profiles checked",
        value: formatNumber(profileCount),
        help: "All configured storage profiles are checked. Named profiles are listed below when a custom storage name is configured.",
      },
      {
        label: "Objects scanned",
        value: formatNumber(stats.objects_scanned || 0),
        help: "Total storage objects listed across all checked profiles. This can be higher than the object limit when more than one profile is checked.",
      },
      {
        label: "Object limit / profile",
        value: formatNumber(objectLimit),
        help: "Maximum number of storage objects listed per profile during this read-only scan. Hitting this limit makes orphan-file detection partial for that profile.",
      },
    ];
  }

  flattenAttentionIssues(data) {
    if (Array.isArray(data?.issues)) {
      return data.issues
        .map(decorateIssue)
        .sort((a, b) => severityRank(b.severity) - severityRank(a.severity));
    }

    return (Array.isArray(data?.sections) ? data.sections : [])
      .flatMap((section) => {
        const sectionTitle = section?.title || "Health issue";
        return (Array.isArray(section?.items) ? section.items : [])
          .filter((item) => item?.severity && item.severity !== "ok")
          .map((item) => decorateIssue({ ...item, section_title: sectionTitle }));
      })
      .sort((a, b) => severityRank(b.severity) - severityRank(a.severity));
  }

  get reconciliationProfiles() {
    const profiles = this.reconciliation?.profiles || {};
    return Array.isArray(profiles.checked) ? profiles.checked : [];
  }

  get hasReconciliationProfiles() {
    return this.reconciliationProfiles.length > 0;
  }

  get reconciliationNamedProfiles() {
    return this.reconciliationProfiles
      .map((profile) => ({
        ...profile,
        displayName: profileLabel(profile),
        technicalName: profileTechnicalLabel(profile),
        statusLabel: profileStatusLabel(profile),
        statusClass: profileStatusClass(profile),
        objectsScannedLabel: formatNumber(profile?.objects_scanned || 0),
        truncatedLabel: profile?.truncated ? "Limit reached" : "Complete",
      }))
      .filter((profile) => profile.displayName);
  }

  get reconciliationUnnamedProfilesCount() {
    return Math.max(this.reconciliationProfiles.length - this.reconciliationNamedProfiles.length, 0);
  }

  get hasReconciliationNamedProfiles() {
    return this.reconciliationNamedProfiles.length > 0;
  }

  get reconciliationProfilesHelpText() {
    const unnamed = this.reconciliationUnnamedProfilesCount;
    if (unnamed > 0) {
      return `${unnamed} checked profile${unnamed === 1 ? "" : "s"} had no custom display name configured and is not shown by name.`;
    }
    return "Only storage profiles with a configured display name are listed here. The scan still checks every configured profile.";
  }

  applyResponse(data) {
    this.data = data || {};
    this.summaryCards = Array.isArray(data?.summary_cards)
      ? data.summary_cards.map(decorateCard)
      : [];
    this.sections = Array.isArray(data?.sections)
      ? data.sections.map(decorateSection)
      : [];
    this.attentionIssues = this.flattenAttentionIssues(data);
    this.ignoredFindings = Array.isArray(data?.ignored_findings)
      ? data.ignored_findings.map(decorateIgnoredFinding)
      : [];
    this.reconciliation = data?.reconciliation || null;
    this.reconciliationHistory = Array.isArray(data?.reconciliation_history)
      ? data.reconciliation_history.map(decorateHistoryEntry)
      : [];
    const allowedCategories = new Set(this.reconciliationExportCategories.map((category) => category.id));
    if (!allowedCategories.has(this.exportCategory)) {
      this.exportCategory = "all";
    }
  }

  errorMessage(error) {
    try {
      return (
        error?.jqXHR?.responseJSON?.message ||
        error?.jqXHR?.responseJSON?.error ||
        error?.jqXHR?.responseJSON?.errors?.join(" ") ||
        error?.jqXHR?.responseText ||
        error?.message ||
        "Unable to load Media Gallery health."
      );
    } catch {
      return "Unable to load Media Gallery health.";
    }
  }

  async loadHealth({ fullStorage = false } = {}) {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";

    try {
      const query = fullStorage ? "?full_storage=1" : "";
      const data = await ajax(`/admin/plugins/media-gallery/health.json${query}`);
      this.isFullStorage = Boolean(data?.full_storage);
      this.applyResponse(data);
      this.notice = fullStorage
        ? "Full storage check completed. The result will remain visible until the next full check."
        : "Health summary refreshed.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  refresh(event) {
    event?.preventDefault?.();
    return this.loadHealth({ fullStorage: false });
  }

  @action
  runFullStorage(event) {
    event?.preventDefault?.();
    return this.loadHealth({ fullStorage: true });
  }

  @action
  async runReconciliation(event) {
    event?.preventDefault?.();
    if (this.isLoading) {
      return;
    }

    const confirmed = window.confirm(
      "Run storage reconciliation now? This is read-only, but it may take longer on large storage profiles."
    );
    if (!confirmed) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";

    try {
      const data = await ajax("/admin/plugins/media-gallery/health/reconcile.json", {
        type: "POST",
      });
      this.isFullStorage = false;
      this.applyResponse(data);
      this.notice = "Reconciliation completed. Read-only scan only; no files were changed or deleted.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  setExportCategory(event) {
    this.exportCategory = event?.target?.value || "all";
  }

  buildExportQuery(extra = {}) {
    const params = new URLSearchParams();
    if (this.exportCategory && this.exportCategory !== "all") {
      params.set("category", this.exportCategory);
    }
    Object.entries(extra).forEach(([key, value]) => {
      if (value !== null && value !== undefined && value !== "") {
        params.set(key, value);
      }
    });
    const query = params.toString();
    return query ? `?${query}` : "";
  }

  downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  @action
  async exportReconciliation(event) {
    event?.preventDefault?.();
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";

    try {
      const data = await ajax(`/admin/plugins/media-gallery/health/reconciliation-export.json${this.buildExportQuery()}`);
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      const category = this.exportCategory && this.exportCategory !== "all" ? `-${this.exportCategory}` : "";
      this.downloadBlob(blob, `media-gallery-storage-reconciliation${category}-${stamp}.json`);
      this.notice = "Storage reconciliation JSON report exported.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  async exportReconciliationCsv(event) {
    event?.preventDefault?.();
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";

    try {
      const response = await fetch(`/admin/plugins/media-gallery/health/reconciliation-export.json${this.buildExportQuery({ export_format: "csv" })}`, {
        credentials: "same-origin",
        headers: {
          Accept: "text/csv",
          "X-Requested-With": "XMLHttpRequest",
        },
      });

      if (!response.ok) {
        throw new Error(`Export failed (${response.status})`);
      }

      const blob = await response.blob();
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      const category = this.exportCategory && this.exportCategory !== "all" ? `-${this.exportCategory}` : "";
      this.downloadBlob(blob, `media-gallery-storage-reconciliation${category}-${stamp}.csv`);
      this.notice = "Storage reconciliation CSV report exported.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  ignoreFinding(issue, example, event) {
    event?.preventDefault?.();
    if (!example?.canIgnore || this.isLoading) {
      return;
    }

    this.ignoreIssue = issue || null;
    this.ignoreExample = example || null;
    this.ignoreReason = issue?.label || "Health finding ignored after admin review.";
    this.ignoreExpiresInDays = "0";
    this.ignoreModalOpen = true;
  }

  @action
  cancelIgnoreFinding(event) {
    event?.preventDefault?.();
    if (this.isLoading) {
      return;
    }

    this.ignoreModalOpen = false;
    this.ignoreIssue = null;
    this.ignoreExample = null;
    this.ignoreReason = "";
    this.ignoreExpiresInDays = "0";
  }

  @action
  setIgnoreReason(event) {
    this.ignoreReason = String(event?.target?.value || "").slice(0, 500);
  }

  @action
  setIgnoreExpiry(event) {
    this.ignoreExpiresInDays = event?.target?.value || "0";
  }

  @action
  async submitIgnoreFinding(event) {
    event?.preventDefault?.();
    const example = this.ignoreExample;
    if (!example?.key || this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";
    try {
      const data = await ajax("/admin/plugins/media-gallery/health/ignore.json", {
        type: "POST",
        data: {
          key: example.key,
          public_id: example.public_id,
          issue_type: example.issueType,
          title: example.title,
          reason: this.ignoreReason || "Health finding ignored after admin review.",
          expires_in_days: this.ignoreExpiresInDays,
        },
      });
      this.applyResponse(data);
      this.notice = "Health finding ignored.";
      this.ignoreModalOpen = false;
      this.ignoreIssue = null;
      this.ignoreExample = null;
      this.ignoreReason = "";
      this.ignoreExpiresInDays = "0";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  async unignoreFinding(finding, event) {
    event?.preventDefault?.();
    if (!finding?.key || this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";
    try {
      const data = await ajax("/admin/plugins/media-gallery/health/ignore.json", {
        type: "DELETE",
        data: {
          key: finding.key,
          public_id: finding.public_id,
          issue_type: finding.issueType,
        },
      });
      this.applyResponse(data);
      this.notice = "Health finding restored.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }
}
