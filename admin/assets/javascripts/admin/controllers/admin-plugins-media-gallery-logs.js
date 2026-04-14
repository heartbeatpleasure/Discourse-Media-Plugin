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

function titleize(value) {
  return String(value || "")
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function coerceArray(value) {
  return Array.isArray(value) ? value : [];
}

function severityBadgeClass(value) {
  switch (String(value || "").toLowerCase()) {
    case "warning":
      return "mg-logs__badge is-warning";
    case "danger":
    case "error":
      return "mg-logs__badge is-danger";
    default:
      return "mg-logs__badge is-info";
  }
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

  get decoratedEvents() {
    return coerceArray(this.events).map((event) => {
      const severity = String(event?.severity || "info").toLowerCase();
      const method = String(event?.method || "").trim();
      const path = String(event?.path || "").trim();

      return {
        id: event?.id,
        createdLabel: formatDateTime(event?.created_at || event?.created_at_label),
        eventLabel: titleize(event?.event_type || "event"),
        severityLabel: titleize(severity || "info"),
        severityBadgeClass: severityBadgeClass(severity),
        categoryLabel: titleize(event?.category || "general"),
        message: String(event?.message || "").trim(),
        userLabel:
          event?.name ||
          event?.username ||
          (event?.user_id ? `User #${event.user_id}` : "—"),
        mediaLabel:
          event?.media_title ||
          event?.media_public_id ||
          (event?.media_item_id ? `Item #${event.media_item_id}` : "—"),
        requestLabel: [method, path].filter(Boolean).join(" ") || "—",
        overlayCode: String(event?.overlay_code || "").trim(),
        fingerprintId: String(event?.fingerprint_id || "").trim(),
        ip: String(event?.ip || "").trim(),
        detailsPreview: String(event?.details_pretty || "").trim(),
      };
    });
  }

  get decoratedTopEventTypes() {
    return coerceArray(this.topEventTypes).map((entry) => ({
      label: titleize(entry?.event_type || "event"),
      count: Number(entry?.count || 0),
    }));
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
