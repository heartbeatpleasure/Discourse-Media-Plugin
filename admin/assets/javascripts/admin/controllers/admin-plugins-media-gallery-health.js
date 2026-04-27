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

function formatDateTime(value) {
  if (!value) {
    return "—";
  }

  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }

  return `${new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date)} (local time)`;
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
  const label = String(profile?.label || profile?.profile_key || "Unknown profile");
  const backend = profile?.backend ? ` (${profile.backend})` : "";
  return `${label}${backend}`;
}

function decorateProfile(profile, fallbackStatus = "Checked") {
  const statusText = profile?.reason || (profile?.truncated ? "Partial" : fallbackStatus);
  const statusClass = profile?.truncated ? "is-warning" : (profile?.reason ? "is-muted" : "is-success");
  return {
    ...profile,
    key: profile?.profile_key || profile?.label || "unknown-profile",
    label: profile?.label || profile?.profile_key || "Unknown profile",
    backend: profile?.backend || "unknown",
    displayLabel: profileLabel(profile),
    statusText,
    statusClass,
    dotClass: `mg-health__status-dot ${statusClass}`,
  };
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
  if (example?.profile_label || example?.profile_key) {
    subtitleParts.push(`profile: ${example.profile_label || example.profile_key}`);
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
  return {
    ...finding,
    key: finding?.key || `${finding?.issue_type || "issue"}:${finding?.public_id || "unknown"}`,
    issueType: finding?.issue_type || "missing_ready_asset",
    title: stringify(finding?.title || finding?.public_id || "Media item"),
    subtitle: [finding?.public_id, finding?.ignored_by_username ? `ignored by ${finding.ignored_by_username}` : "", formatDateTime(finding?.ignored_at)]
      .filter(Boolean)
      .join(" • "),
    url: finding?.url || null,
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
  @tracked reconciliationProfileScope = "all_configured";

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
    this.reconciliationProfileScope = "all_configured";
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
    return formatDateTime(this.data?.generated_at);
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

  get hasIgnoredFindings() {
    return this.ignoredFindings.length > 0;
  }

  get hasReconciliation() {
    return !!this.reconciliation;
  }

  get reconciliationGeneratedAtLabel() {
    return formatDateTime(this.reconciliation?.generated_at);
  }

  get reconciliationGeneratedAtRelativeLabel() {
    return formatRelativeTime(this.reconciliation?.generated_at);
  }

  get reconciliationDurationLabel() {
    return formatDuration(this.reconciliation?.duration_ms);
  }

  get storageProfiles() {
    const profiles = Array.isArray(this.reconciliation?.configured_profiles)
      ? this.reconciliation.configured_profiles
      : [];
    return profiles.filter((profile) => profile?.profile_key);
  }

  get reconciliationProfileOptions() {
    return [
      { id: "all_configured", label: "All configured profiles" },
      { id: "referenced", label: "Referenced profiles only" },
      ...this.storageProfiles.map((profile) => ({ id: profile.profile_key, label: profileLabel(profile) })),
    ];
  }

  get reconciliationScopeLabel() {
    const scope = this.reconciliation?.profile_scope || this.reconciliationProfileScope || "all_configured";
    if (scope === "all_configured") {
      return "All configured profiles";
    }
    if (scope === "referenced") {
      return "Referenced profiles only";
    }

    const profile = this.storageProfiles.find((item) => item.profile_key === scope);
    return profile ? profileLabel(profile) : String(scope);
  }

  get reconciliationCompletenessLabel() {
    switch (String(this.reconciliation?.scan_completeness || "unknown")) {
      case "complete":
        return "Complete";
      case "partial":
        return "Partial";
      case "failed":
        return "Failed";
      default:
        return "Unknown";
    }
  }

  get checkedProfiles() {
    return Array.isArray(this.reconciliation?.checked_profiles)
      ? this.reconciliation.checked_profiles.map((profile) => decorateProfile(profile))
      : [];
  }

  get skippedProfiles() {
    return Array.isArray(this.reconciliation?.skipped_profiles)
      ? this.reconciliation.skipped_profiles.map((profile) => decorateProfile(profile, "Skipped"))
      : [];
  }

  get hasCheckedProfiles() {
    return this.checkedProfiles.length > 0;
  }

  get hasSkippedProfiles() {
    return this.skippedProfiles.length > 0;
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
    return [
      { label: "Last run", value: this.reconciliationGeneratedAtLabel },
      { label: "Relative", value: this.reconciliationGeneratedAtRelativeLabel || "—" },
      { label: "Duration", value: this.reconciliationDurationLabel },
      { label: "Scope", value: this.reconciliationScopeLabel },
      { label: "Completeness", value: this.reconciliationCompletenessLabel },
      { label: "Active findings", value: this.reconciliationActiveFindingsCount },
      { label: "Ignored findings", value: this.reconciliationIgnoredFindingsCount },
      { label: "Items checked", value: formatNumber(stats.items_checked || 0) },
      { label: "Items skipped by scope", value: formatNumber(stats.items_skipped_by_scope || 0) },
      { label: "Profiles checked", value: formatNumber(stats.profiles_checked || 0) },
      { label: "Objects scanned", value: formatNumber(stats.objects_scanned || 0) },
      { label: "Object limit", value: formatNumber(limits.object_limit || 0) },
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
  onReconciliationProfileScopeChange(event) {
    this.reconciliationProfileScope = event?.target?.value || "all_configured";
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
        data: { profile_scope: this.reconciliationProfileScope },
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
  async exportReconciliation(event) {
    event?.preventDefault?.();
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";
    this.notice = "";

    try {
      const data = await ajax("/admin/plugins/media-gallery/health/reconciliation-export.json");
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      link.href = url;
      link.download = `media-gallery-storage-reconciliation-${stamp}.json`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
      this.notice = "Storage reconciliation report exported.";
    } catch (error) {
      this.error = this.errorMessage(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  async ignoreFinding(issue, example, event) {
    event?.preventDefault?.();
    if (!example?.canIgnore || this.isLoading) {
      return;
    }

    const confirmed = window.confirm(
      "Ignore this storage finding? It will no longer affect health status until you unignore it or a different issue is found."
    );
    if (!confirmed) {
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
          reason: issue?.label || "Health finding ignored by admin",
        },
      });
      this.applyResponse(data);
      this.notice = "Health finding ignored.";
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
