import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

const DEFAULT_SEVERITIES = ["all", "info", "success", "warning", "danger"];
const DEFAULT_CATEGORIES = ["all"];
const DEFAULT_EVENT_TYPES = ["all"];
const HOURS_OPTIONS = [
  { value: "24", label: "Last 24 hours" },
  { value: "72", label: "Last 3 days" },
  { value: "168", label: "Last 7 days" },
  { value: "720", label: "Last 30 days" },
  { value: "2160", label: "Last 90 days" },
];
const LIMIT_OPTIONS = ["25", "50", "100", "250"];
const SORT_OPTIONS = [
  { value: "created_at_desc", label: "Newest first" },
  { value: "created_at_asc", label: "Oldest first" },
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

function normalizeText(value, fallback = "—") {
  if (value == null) {
    return fallback;
  }

  const text = String(value).trim();
  return text ? text : fallback;
}

function prettyLabel(value) {
  return normalizeText(value, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function titleize(value) {
  const text = prettyLabel(value);
  return text ? text.replace(/\b\w/g, (char) => char.toUpperCase()) : "—";
}

function coerceArray(value) {
  return Array.isArray(value) ? value : [];
}

function severityTone(value) {
  switch (String(value || "").toLowerCase()) {
    case "success":
    case "ok":
      return "success";
    case "warning":
    case "warn":
      return "warning";
    case "danger":
    case "error":
    case "failed":
      return "danger";
    case "info":
    case "notice":
    case "debug":
      return "info";
    default:
      return "neutral";
  }
}

function categoryTone(value) {
  switch (String(value || "").toLowerCase()) {
    case "playback":
    case "audit":
      return "info";
    case "security":
    case "forensics":
      return "warning";
    case "delivery":
      return "success";
    case "error":
    case "failure":
      return "danger";
    default:
      return "neutral";
  }
}

function badgeClass(baseClass, tone, isSoft = false) {
  const classes = [baseClass, `is-${tone}`];
  if (isSoft) {
    classes.push("is-soft");
  }
  return classes.join(" ");
}

function buildUserLabel(event) {
  const name = normalizeText(event?.name, "");
  const username = normalizeText(event?.username, "");

  if (name && username && name.toLowerCase() !== username.toLowerCase()) {
    return {
      value: name,
      meta: `@${username}`,
    };
  }

  if (name || username) {
    return {
      value: name || username,
      meta: "",
    };
  }

  return {
    value: event?.user_id ? `User #${event.user_id}` : "—",
    meta: "",
  };
}

function buildMediaLabel(event) {
  const title = normalizeText(event?.media_title, "");
  const publicId = normalizeText(event?.media_public_id, "");

  if (title && publicId && title !== publicId) {
    return {
      value: title,
      meta: publicId,
    };
  }

  if (title || publicId) {
    return {
      value: title || publicId,
      meta: "",
    };
  }

  return {
    value: event?.media_item_id ? `Item #${event.media_item_id}` : "—",
    meta: "",
  };
}

function buildFact(label, value, options = {}) {
  const text = normalizeText(value);
  return {
    label,
    value: text,
    meta: normalizeText(options.meta, ""),
    isWide: Boolean(options.isWide),
    isMono: Boolean(options.isMono),
    valueClass: [
      "mg-logs__fact-value",
      options.isMono ? "mg-logs__fact-value--mono" : null,
    ]
      .filter(Boolean)
      .join(" "),
  };
}

function makeOption(value, currentValue, labelBuilder) {
  return {
    value,
    label: labelBuilder(value),
    selected: String(currentValue) === String(value),
  };
}

function allOptionLabel(value, noun) {
  return value === "all" ? `All ${noun}` : titleize(value);
}

export default class AdminPluginsMediaGalleryLogsController extends Controller {
  @tracked query = "";
  @tracked severityFilter = "all";
  @tracked categoryFilter = "all";
  @tracked eventTypeFilter = "all";
  @tracked hoursFilter = "168";
  @tracked limit = "100";
  @tracked sortBy = "created_at_desc";
  @tracked filterOptions = {};
  @tracked isLoading = false;
  @tracked error = "";
  @tracked events = [];
  @tracked summary = {};
  @tracked topEventTypes = [];
  @tracked lastLoadedAt = null;
  @tracked hasLoadedOnce = false;

  resetState() {
    this.query = "";
    this.severityFilter = "all";
    this.categoryFilter = "all";
    this.eventTypeFilter = "all";
    this.hoursFilter = "168";
    this.limit = "100";
    this.sortBy = "created_at_desc";
    this.filterOptions = {};
    this.isLoading = false;
    this.error = "";
    this.events = [];
    this.summary = {};
    this.topEventTypes = [];
    this.lastLoadedAt = null;
    this.hasLoadedOnce = false;
  }

  buildQuery() {
    const params = new URLSearchParams();
    const query = String(this.query || "").trim();
    if (query) {
      params.set("q", query);
    }

    params.set("severity", this.severityFilter || "all");
    params.set("category", this.categoryFilter || "all");
    params.set("event_type", this.eventTypeFilter || "all");
    params.set("hours", this.hoursFilter || "168");
    params.set("limit", this.limit || "100");
    params.set("sort", this.sortBy || "created_at_desc");
    return params.toString();
  }

  get severityOptions() {
    const values = coerceArray(this.filterOptions?.severities);
    const source = values.length ? values : DEFAULT_SEVERITIES;
    return source.map((value) => makeOption(value, this.severityFilter, (entry) => allOptionLabel(entry, "severities")));
  }

  get categoryOptions() {
    const values = coerceArray(this.filterOptions?.categories);
    const source = values.length ? values : DEFAULT_CATEGORIES;
    return source.map((value) => makeOption(value, this.categoryFilter, (entry) => allOptionLabel(entry, "categories")));
  }

  get eventTypeOptions() {
    const values = coerceArray(this.filterOptions?.event_types);
    const source = values.length ? values : DEFAULT_EVENT_TYPES;
    return source.map((value) => makeOption(value, this.eventTypeFilter, (entry) => allOptionLabel(entry, "event types")));
  }

  get hoursOptions() {
    return HOURS_OPTIONS.map((entry) => ({
      ...entry,
      selected: this.hoursFilter === entry.value,
    }));
  }

  get limitOptions() {
    return LIMIT_OPTIONS.map((value) => ({
      value,
      label: value,
      selected: this.limit === value,
    }));
  }

  get sortOptions() {
    return SORT_OPTIONS.map((entry) => ({
      ...entry,
      selected: this.sortBy === entry.value,
    }));
  }

  get decoratedTopEventTypes() {
    return coerceArray(this.topEventTypes).map((entry) => ({
      eventLabel: titleize(entry?.event_type || "event"),
      count: Number(entry?.count || 0),
    }));
  }

  get decoratedEvents() {
    return coerceArray(this.events).map((event) => {
      const user = buildUserLabel(event);
      const media = buildMediaLabel(event);
      const facts = [
        buildFact("User", user.value, { meta: user.meta }),
        buildFact("Media", media.value, { meta: media.meta }),
        buildFact("IP address", event?.ip, { isMono: true }),
        buildFact("Overlay code", event?.overlay_code, { isMono: true }),
        buildFact("Request", [event?.method, event?.path].filter(Boolean).join(" "), {
          isWide: true,
          isMono: true,
        }),
        buildFact("Fingerprint", event?.fingerprint_id, { isWide: true, isMono: true }),
        buildFact("Request ID", event?.request_id, { isWide: true, isMono: true }),
        buildFact("Message", event?.message, { isWide: true }),
      ].filter((fact) => fact.value !== "—");

      return {
        id: event?.id,
        createdLabel: formatDateTime(event?.created_at || event?.created_at_label),
        eventLabel: titleize(event?.event_type || "event"),
        severityLabel: titleize(event?.severity || "info"),
        severityBadgeClass: badgeClass("mg-logs__badge", severityTone(event?.severity)),
        categoryLabel: titleize(event?.category || "general"),
        categoryBadgeClass: badgeClass(
          "mg-logs__badge",
          categoryTone(event?.category),
          true,
        ),
        facts,
        detailsPreview: String(event?.details_pretty || "").trim(),
      };
    });
  }

  get shownRows() {
    return Number(this.summary?.shown_rows || this.events.length || 0);
  }

  get filteredCount() {
    return Number(this.summary?.filtered_count || 0);
  }

  get last24hCount() {
    return Number(this.summary?.last_24h_count || 0);
  }

  get uniqueUsers() {
    return Number(this.summary?.unique_users || 0);
  }

  get lastLoadedLabel() {
    return this.lastLoadedAt ? formatDateTime(this.lastLoadedAt) : "";
  }

  get searchInfo() {
    if (!this.hasLoadedOnce) {
      return "Choose filters and run a search to inspect matching log events.";
    }

    const parts = [`${this.filteredCount} match${this.filteredCount === 1 ? "" : "es"}`];
    const timeOption = HOURS_OPTIONS.find((entry) => entry.value === this.hoursFilter);
    if (timeOption) {
      parts.push(timeOption.label);
    }
    parts.push(`showing ${this.shownRows}`);
    return parts.join(" · ");
  }

  applyResponseFilters(filters = {}, filterOptions = {}) {
    this.query = String(filters?.q ?? this.query ?? "");
    this.severityFilter = String(filters?.severity || this.severityFilter || "all");
    this.categoryFilter = String(filters?.category || this.categoryFilter || "all");
    this.eventTypeFilter = String(filters?.event_type || this.eventTypeFilter || "all");
    this.hoursFilter = String(filters?.hours || this.hoursFilter || "168");
    this.limit = String(filters?.limit || this.limit || "100");
    this.sortBy = String(filters?.sort || this.sortBy || "created_at_desc");
    this.filterOptions = filterOptions || {};
  }

  @action
  updateQuery(event) {
    this.query = event?.target?.value ?? "";
  }

  @action
  onSeverityFilterChange(event) {
    this.severityFilter = event?.target?.value || "all";
  }

  @action
  onCategoryFilterChange(event) {
    this.categoryFilter = event?.target?.value || "all";
  }

  @action
  onEventTypeFilterChange(event) {
    this.eventTypeFilter = event?.target?.value || "all";
  }

  @action
  onHoursFilterChange(event) {
    this.hoursFilter = event?.target?.value || "168";
  }

  @action
  onLimitChange(event) {
    this.limit = event?.target?.value || "100";
  }

  @action
  onSortChange(event) {
    this.sortBy = event?.target?.value || "created_at_desc";
  }

  @action
  async onSearchKeydown(event) {
    if (event?.key !== "Enter") {
      return;
    }

    event.preventDefault();
    await this.loadLogs();
  }

  @action
  async loadLogs() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";

    try {
      const data = await ajax(`/admin/plugins/media-gallery/logs.json?${this.buildQuery()}`);
      this.events = coerceArray(data?.events);
      this.summary = data?.summary || {};
      this.topEventTypes = coerceArray(data?.summary?.top_event_types);
      this.error = String(data?.error || "").trim();
      this.applyResponseFilters(data?.filters, data?.filter_options);
      this.lastLoadedAt = new Date();
      this.hasLoadedOnce = true;
    } catch (error) {
      let message = "Unable to load logs.";
      try {
        message =
          error?.jqXHR?.responseJSON?.error ||
          error?.jqXHR?.responseJSON?.errors?.join(" ") ||
          error?.jqXHR?.responseText ||
          error?.message ||
          message;
      } catch {
        // ignore parse failures
      }
      this.error = message;
      this.events = [];
      this.summary = {};
      this.topEventTypes = [];
    } finally {
      this.isLoading = false;
    }
  }

  @action
  async search(event) {
    event?.preventDefault?.();
    await this.loadLogs();
  }

  @action
  async resetFilters(event) {
    event?.preventDefault?.();
    this.query = "";
    this.severityFilter = "all";
    this.categoryFilter = "all";
    this.eventTypeFilter = "all";
    this.hoursFilter = "168";
    this.limit = "100";
    this.sortBy = "created_at_desc";
    await this.loadLogs();
  }
}
