import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
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

function titleize(value) {
  const text = String(value || "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

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
    case "request_security":
    case "security":
    case "forensics":
      return "warning";
    case "delivery":
    case "migration":
      return "success";
    case "error":
    case "failure":
      return "danger";
    default:
      return "neutral";
  }
}

function buildBadgeClass(tone, soft = false) {
  return ["mg-logs__badge", `is-${tone}`, soft ? "is-soft" : null]
    .filter(Boolean)
    .join(" ");
}

function buildUserLabel(event) {
  const name = normalizeText(event?.name, "");
  const username = normalizeText(event?.username, "");

  if (name && username && name.toLowerCase() !== username.toLowerCase()) {
    return { value: name, meta: `@${username}` };
  }

  if (name || username) {
    return { value: name || username, meta: "" };
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
    return { value: title, meta: publicId };
  }

  if (title || publicId) {
    return { value: title || publicId, meta: "" };
  }

  return {
    value: event?.media_item_id ? `Item #${event.media_item_id}` : "—",
    meta: "",
  };
}

function buildFact(key, label, value, options = {}) {
  const text = normalizeText(value);
  return {
    key,
    label,
    value: text,
    meta: normalizeText(options.meta, ""),
    itemClass: ["mg-logs__fact", options.isWide ? "is-wide" : null]
      .filter(Boolean)
      .join(" "),
    valueClass: [
      "mg-logs__fact-value",
      options.isMono ? "mg-logs__fact-value--mono" : null,
    ]
      .filter(Boolean)
      .join(" "),
  };
}

function decorateEvent(event) {
  const user = buildUserLabel(event);
  const media = buildMediaLabel(event);
  const facts = [
    buildFact("user", "User", user.value, { meta: user.meta }),
    buildFact("media", "Media", media.value, { meta: media.meta }),
    buildFact("ip", "IP address", event?.ip, { isMono: true }),
    buildFact("overlay", "Overlay code", event?.overlay_code, { isMono: true }),
    buildFact("request", "Request", [event?.method, event?.path].filter(Boolean).join(" "), {
      isWide: true,
      isMono: true,
    }),
    buildFact("fingerprint", "Fingerprint", event?.fingerprint_id, {
      isWide: true,
      isMono: true,
    }),
    buildFact("request-id", "Request ID", event?.request_id, {
      isWide: true,
      isMono: true,
    }),
    buildFact("message", "Message", event?.message, { isWide: true }),
  ].filter((fact) => fact.value !== "—");

  return {
    id: String(event?.id ?? `${event?.created_at || "row"}-${event?.event_type || "event"}`),
    createdLabel: formatDateTime(event?.created_at || event?.created_at_label),
    eventLabel: titleize(event?.event_type || "event"),
    severityLabel: titleize(event?.severity || "info"),
    severityBadgeClass: buildBadgeClass(severityTone(event?.severity)),
    categoryLabel: titleize(event?.category || "general"),
    categoryBadgeClass: buildBadgeClass(categoryTone(event?.category), true),
    detailsPreview: String(event?.details_pretty || "").trim(),
    facts,
  };
}

function decorateTopEvent(entry) {
  const eventType = String(entry?.event_type || "event");
  return {
    key: eventType,
    eventLabel: titleize(eventType),
    count: Number(entry?.count || 0),
  };
}

export default class AdminPluginsMediaGalleryLogsController extends Controller {
  @tracked query = "";
  @tracked severityFilter = "all";
  @tracked categoryFilter = "all";
  @tracked eventTypeFilter = "all";
  @tracked hoursFilter = "168";
  @tracked limit = "25";
  @tracked sortBy = "created_at_desc";
  @tracked isLoading = false;
  @tracked error = "";
  @tracked summary = {};
  @tracked decoratedEvents = [];
  @tracked decoratedTopEventTypes = [];
  @tracked lastLoadedAt = null;
  @tracked hasLoadedOnce = false;

  _requestSequence = 0;

  resetState() {
    this.query = "";
    this.severityFilter = "all";
    this.categoryFilter = "all";
    this.eventTypeFilter = "all";
    this.hoursFilter = "168";
    this.limit = "25";
    this.sortBy = "created_at_desc";
    this.isLoading = false;
    this.error = "";
    this.summary = {};
    this.decoratedEvents = [];
    this.decoratedTopEventTypes = [];
    this.lastLoadedAt = null;
    this.hasLoadedOnce = false;
  }

  buildQuery() {
    const params = new URLSearchParams();
    const query = String(this.query || "").trim();

    if (query) {
      params.set("q", query);
    }

    if (this.severityFilter !== "all") {
      params.set("severity", this.severityFilter);
    }

    if (this.categoryFilter !== "all") {
      params.set("category", this.categoryFilter);
    }

    if (this.eventTypeFilter !== "all") {
      params.set("event_type", this.eventTypeFilter);
    }

    params.set("hours", this.hoursFilter || "168");
    params.set("limit", this.limit || "25");
    params.set("sort", this.sortBy || "created_at_desc");

    return params.toString();
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

  get shownRows() {
    return Number(this.summary?.shown_rows || this.decoratedEvents.length || 0);
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

  applyResponse(data = {}) {
    const filters = data?.filters || {};
    const rows = coerceArray(data?.events);
    const topEventTypes = coerceArray(data?.summary?.top_event_types);

    this.query = String(filters?.q || this.query || "");
    this.severityFilter = String(filters?.severity || this.severityFilter || "all");
    this.categoryFilter = String(filters?.category || this.categoryFilter || "all");
    this.eventTypeFilter = String(filters?.event_type || this.eventTypeFilter || "all");
    this.hoursFilter = String(filters?.hours || this.hoursFilter || "168");
    this.limit = String(filters?.limit || this.limit || "25");
    this.sortBy = String(filters?.sort || this.sortBy || "created_at_desc");

    this.decoratedEvents = rows.map((event) => decorateEvent(event));
    this.decoratedTopEventTypes = topEventTypes.map((entry) => decorateTopEvent(entry));
    this.summary = data?.summary || {};
    this.error = String(data?.error || "").trim();
    this.lastLoadedAt = new Date();
    this.hasLoadedOnce = true;
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
    this.categoryFilter = event?.target?.value || "all";
  }

  @action
  updateEventTypeFilter(event) {
    this.eventTypeFilter = event?.target?.value || "all";
  }

  @action
  updateHoursFilter(event) {
    this.hoursFilter = event?.target?.value || "168";
  }

  @action
  updateLimit(event) {
    this.limit = event?.target?.value || "25";
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

    const requestSequence = ++this._requestSequence;
    this.isLoading = true;
    this.error = "";

    try {
      const queryString = this.buildQuery();
      const data = await ajax(
        `/admin/plugins/media-gallery/logs.json${queryString ? `?${queryString}` : ""}`
      );

      if (requestSequence !== this._requestSequence) {
        return;
      }

      this.applyResponse(data);
    } catch (error) {
      if (requestSequence !== this._requestSequence) {
        return;
      }

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
      this.summary = {};
      this.decoratedEvents = [];
      this.decoratedTopEventTypes = [];
      this.hasLoadedOnce = true;
    } finally {
      if (requestSequence === this._requestSequence) {
        this.isLoading = false;
      }
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
    this.categoryFilter = "all";
    this.eventTypeFilter = "all";
    this.hoursFilter = "168";
    this.limit = "25";
    this.sortBy = "created_at_desc";
    await this.loadLogs();
  }
}
