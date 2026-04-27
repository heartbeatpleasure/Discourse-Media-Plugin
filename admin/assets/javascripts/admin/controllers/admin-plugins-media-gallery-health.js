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
  if (example?.error) {
    subtitleParts.push(example.error);
  }

  return {
    ...example,
    title,
    subtitle: subtitleParts.filter(Boolean).join(" • "),
    url: example?.url || null,
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
  return {
    ...card,
    severity,
    badgeClass: badgeClass(severity),
    value: stringify(card?.value),
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

  resetState() {
    this.isLoading = false;
    this.isFullStorage = false;
    this.error = "";
    this.notice = "";
    this.data = null;
    this.summaryCards = [];
    this.sections = [];
    this.attentionIssues = [];
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
    return this.data?.generated_at_label || "—";
  }

  get alertStateRows() {
    const state = this.data?.alert_state || {};
    return [
      { label: "Notify group", value: stringify(state.group || "admins") },
      { label: "Last sent", value: stringify(state.sent_at) },
      { label: "Last attempted", value: stringify(state.attempted_at) },
      { label: "Last error", value: stringify(state.error) },
    ];
  }

  get hasAttentionIssues() {
    return this.attentionIssues.length > 0;
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
        ? "Full storage check completed."
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
}
