import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { scheduleOnce } from "@ember/runloop";
import { ajax } from "discourse/lib/ajax";

const HOURS_LABELS = {
  "24": "Last 24 hours",
  "72": "Last 3 days",
  "168": "Last 7 days",
  "720": "Last 30 days",
  "2160": "Last 90 days",
};

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

function uniqueStrings(values) {
  return [
    ...new Set(
      coerceArray(values)
        .map((value) => String(value || "").trim())
        .filter(Boolean)
    ),
  ];
}

function normalizedOptionList(values, selectedValue = "") {
  const items = uniqueStrings(values);
  const selected = String(selectedValue || "").trim();

  if (selected && !items.includes(selected)) {
    items.push(selected);
  }

  return items
    .sort((left, right) => left.localeCompare(right, undefined, { sensitivity: "base" }))
    .map((value) => ({
      id: value,
      value,
      label: titleize(value),
    }));
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
    case "failure":
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
    id: `${label}-${text}-${options.meta || ""}`,
    label,
    value: text,
    meta: normalizeText(options.meta, ""),
    isWide: Boolean(options.isWide),
    valueClass: [
      "mg-logs__fact-value",
      options.isMono ? "mg-logs__fact-value--mono" : null,
    ]
      .filter(Boolean)
      .join(" "),
  };
}

function decorateTopEventTypes(entries) {
  return coerceArray(entries).map((entry) => ({
    id: String(entry?.event_type || "event"),
    eventLabel: titleize(entry?.event_type || "event"),
    count: Number(entry?.count || 0),
  }));
}

function decorateEvents(events) {
  return coerceArray(events).map((event) => {
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
      categoryBadgeClass: badgeClass("mg-logs__badge", categoryTone(event?.category), true),
      facts,
      detailsPreview: String(event?.details_pretty || "").trim(),
    };
  });
}

export default class AdminPluginsMediaGalleryLogsController extends Controller {
  @tracked query = "";
  @tracked severityFilter = "all";
  @tracked categoryFilter = "";
  @tracked eventTypeFilter = "";
  @tracked hoursFilter = "168";
  @tracked limit = "100";
  @tracked sortBy = "created_at_desc";
  @tracked categoryOptions = [];
  @tracked eventTypeOptions = [];
  @tracked renderedCategoryOptions = [];
  @tracked renderedEventTypeOptions = [];
  @tracked decoratedEventRows = [];
  @tracked decoratedTopEventRows = [];
  @tracked isLoading = false;
  @tracked error = "";
  @tracked events = [];
  @tracked summary = {};
  @tracked topEventTypes = [];
  @tracked lastLoadedAt = null;
  @tracked hasLoadedOnce = false;
  _initialLoadScheduled = false;

  resetState() {
    this.query = "";
    this.severityFilter = "all";
    this.categoryFilter = "";
    this.eventTypeFilter = "";
    this.hoursFilter = "168";
    this.limit = "100";
    this.sortBy = "created_at_desc";
    this.categoryOptions = [];
    this.eventTypeOptions = [];
    this.renderedCategoryOptions = [];
    this.renderedEventTypeOptions = [];
    this.decoratedEventRows = [];
    this.decoratedTopEventRows = [];
    this.isLoading = false;
    this.error = "";
    this.events = [];
    this.summary = {};
    this.topEventTypes = [];
    this.lastLoadedAt = null;
    this.hasLoadedOnce = false;
    this._initialLoadScheduled = false;
  }

  loadInitial() {
    if (this._initialLoadScheduled) {
      return;
    }

    this._initialLoadScheduled = true;
    scheduleOnce("afterRender", this, this.loadLogs);
  }

  buildQuery() {
    const params = new URLSearchParams();
    const query = String(this.query || "").trim();
    const category = String(this.categoryFilter || "").trim();
    const eventType = String(this.eventTypeFilter || "").trim();

    if (query) {
      params.set("q", query);
    }

    if (this.severityFilter && this.severityFilter !== "all") {
      params.set("severity", this.severityFilter);
    }

    if (category) {
      params.set("category", category);
    }

    if (eventType) {
      params.set("event_type", eventType);
    }

    params.set("hours", this.hoursFilter || "168");
    params.set("limit", this.limit || "100");
    params.set("sort", this.sortBy || "created_at_desc");

    return params.toString();
  }

  get availableCategoryOptions() {
    return this.renderedCategoryOptions;
  }

  get availableEventTypeOptions() {
    return this.renderedEventTypeOptions;
  }

  get decoratedEvents() {
    return this.decoratedEventRows;
  }

  get decoratedTopEventTypes() {
    return this.decoratedTopEventRows;
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

  get uniqueMediaItems() {
    return Number(this.summary?.unique_media_items || 0);
  }

  get uniqueIps() {
    return Number(this.summary?.unique_ips || 0);
  }

  get shownRows() {
    return Number(this.summary?.shown_rows || this.events.length || 0);
  }

  get lastLoadedLabel() {
    return this.lastLoadedAt ? formatDateTime(this.lastLoadedAt) : "";
  }

  get searchInfo() {
    if (!this.hasLoadedOnce) {
      return "Loading recent log events…";
    }

    const parts = [`${this.filteredCount} match${this.filteredCount === 1 ? "" : "es"}`];
    const hoursLabel = HOURS_LABELS[this.hoursFilter];

    if (hoursLabel) {
      parts.push(hoursLabel);
    }

    parts.push(`showing ${this.shownRows}`);
    return parts.join(" · ");
  }

  applyResponseFilters(filters = {}) {
    this.query = String(filters?.q ?? this.query ?? "");
    this.severityFilter = String(filters?.severity || this.severityFilter || "all");
    this.categoryFilter = String(filters?.category ?? this.categoryFilter ?? "");
    this.eventTypeFilter = String(filters?.event_type ?? this.eventTypeFilter ?? "");
    this.hoursFilter = String(filters?.hours || this.hoursFilter || "168");
    this.limit = String(filters?.limit || this.limit || "100");
    this.sortBy = String(filters?.sort || this.sortBy || "created_at_desc");
  }

  applyFilterOptions(filterOptions = {}) {
    this.categoryOptions = uniqueStrings(filterOptions?.categories);
    this.eventTypeOptions = uniqueStrings(filterOptions?.event_types);
    this.renderedCategoryOptions = normalizedOptionList(
      this.categoryOptions,
      this.categoryFilter
    );
    this.renderedEventTypeOptions = normalizedOptionList(
      this.eventTypeOptions,
      this.eventTypeFilter
    );
  }

  applyData(data = {}) {
    this.events = coerceArray(data?.events);
    this.summary = data?.summary || {};
    this.topEventTypes = coerceArray(data?.summary?.top_event_types);
    this.decoratedEventRows = decorateEvents(this.events);
    this.decoratedTopEventRows = decorateTopEventTypes(this.topEventTypes);
  }

  @action
  updateQuery(event) {
    this.query = event?.target?.value ?? "";
  }

  @action
  updateSeverityFilter(event) {
    this.severityFilter = event?.target?.value || "all";
  }

  @action
  updateCategoryFilter(event) {
    this.categoryFilter = event?.target?.value ?? "";
  }

  @action
  updateEventTypeFilter(event) {
    this.eventTypeFilter = event?.target?.value ?? "";
  }

  @action
  updateHoursFilter(event) {
    this.hoursFilter = event?.target?.value || "168";
  }

  @action
  updateLimit(event) {
    this.limit = event?.target?.value || "100";
  }

  @action
  updateSort(event) {
    this.sortBy = event?.target?.value || "created_at_desc";
  }

  @action
  async loadLogs() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = "";

    try {
      const queryString = this.buildQuery();
      const url = queryString
        ? `/admin/plugins/media-gallery/logs.json?${queryString}`
        : "/admin/plugins/media-gallery/logs.json";
      const data = await ajax(url);

      this.applyResponseFilters(data?.filters);
      this.applyFilterOptions(data?.filter_options);
      this.applyData(data);
      this.error = String(data?.error || "").trim();
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
      this.decoratedEventRows = [];
      this.decoratedTopEventRows = [];
      this.hasLoadedOnce = true;
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
  async clearFilters(event) {
    event?.preventDefault?.();
    this.query = "";
    this.severityFilter = "all";
    this.categoryFilter = "";
    this.eventTypeFilter = "";
    this.hoursFilter = "168";
    this.limit = "100";
    this.sortBy = "created_at_desc";
    await this.loadLogs();
  }
}
