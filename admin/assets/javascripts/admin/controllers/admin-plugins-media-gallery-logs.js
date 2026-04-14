import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

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

export default class AdminPluginsMediaGalleryLogsController extends Controller {
  @tracked query = "";
  @tracked isLoading = false;
  @tracked error = "";
  @tracked events = [];
  @tracked summary = {};
  @tracked topEventTypes = [];
  @tracked lastLoadedAt = null;
  @tracked hasLoadedOnce = false;

  resetState() {
    this.query = "";
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
    params.set("hours", "168");
    params.set("limit", "100");
    return params.toString();
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

  @action
  updateQuery(event) {
    this.query = event?.target?.value ?? "";
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
  async clearSearch(event) {
    event?.preventDefault?.();
    this.query = "";
    await this.loadLogs();
  }
}
