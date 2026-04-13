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

export default class AdminPluginsMediaGalleryLogsController extends Controller {
  @tracked query = "";
  @tracked severity = "all";
  @tracked eventType = "all";
  @tracked hours = "168";
  @tracked limit = "100";

  @tracked isLoading = false;
  @tracked error = "";
  @tracked events = [];
  @tracked summary = null;
  @tracked filterOptions = { severities: ["all", "info", "warning", "danger"], event_types: ["all"] };
  @tracked lastLoadedAt = null;

  resetState() {
    this.query = "";
    this.severity = "all";
    this.eventType = "all";
    this.hours = "168";
    this.limit = "100";
    this.isLoading = false;
    this.error = "";
    this.events = [];
    this.summary = null;
    this.filterOptions = { severities: ["all", "info", "warning", "danger"], event_types: ["all"] };
    this.lastLoadedAt = null;
  }

  async loadInitial() {
    await this.refreshLogs();
  }

  get hasEvents() {
    return Array.isArray(this.events) && this.events.length > 0;
  }

  get severityOptions() {
    const list = Array.isArray(this.filterOptions?.severities)
      ? this.filterOptions.severities
      : ["all", "info", "warning", "danger"];

    return list.map((value) => ({
      value,
      label: value === "all" ? "All severities" : titleize(value),
      selected: String(value) === String(this.severity),
    }));
  }

  get eventTypeOptions() {
    const list = Array.isArray(this.filterOptions?.event_types)
      ? this.filterOptions.event_types
      : ["all"];

    return list.map((value) => ({
      value,
      label: value === "all" ? "All event types" : titleize(value),
      selected: String(value) === String(this.eventType),
    }));
  }

  get decoratedEvents() {
    return (Array.isArray(this.events) ? this.events : []).map((event) => ({
      ...event,
      severityClass: `is-${String(event?.severity || "info")}`,
      severityLabel: titleize(event?.severity || "info"),
      eventLabel: titleize(event?.event_type || "event"),
      createdLabel: formatDateTime(event?.created_at),
      userLabel: event?.name || event?.username || (event?.user_id ? `User #${event.user_id}` : "—"),
      mediaLabel: event?.media_title || event?.media_public_id || (event?.media_item_id ? `Item #${event.media_item_id}` : "—"),
      hasDetails: !!String(event?.details_pretty || "").trim(),
    }));
  }

  get summaryCards() {
    const summary = this.summary || {};
    const severityCounts = summary.severity_counts || {};
    return [
      { label: "Shown", value: summary.shown_rows ?? this.events.length ?? 0, tone: "neutral" },
      { label: "Filtered total", value: summary.filtered_count ?? 0, tone: "neutral" },
      { label: "Last 24h", value: summary.last_24h_count ?? 0, tone: "neutral" },
      { label: "Warning", value: severityCounts.warning ?? 0, tone: "warning" },
      { label: "Danger", value: severityCounts.danger ?? 0, tone: "danger" },
      { label: "Unique users", value: summary.unique_users ?? 0, tone: "neutral" },
    ];
  }

  get topEventTypes() {
    return Array.isArray(this.summary?.top_event_types) ? this.summary.top_event_types : [];
  }

  get lastLoadedLabel() {
    return this.lastLoadedAt ? formatDateTime(this.lastLoadedAt) : "";
  }

  get hourlyBars() {
    const rows = Array.isArray(this.summary?.hourly_counts) ? this.summary.hourly_counts : [];
    const max = rows.reduce((memo, entry) => Math.max(memo, Number(entry?.count || 0)), 0) || 1;
    return rows.map((entry) => {
      const count = Number(entry?.count || 0);
      return {
        label: entry?.label || "",
        count,
        style: `height: ${Math.max(8, Math.round((count / max) * 92))}px;`,
      };
    });
  }

  buildQueryParams() {
    const params = new URLSearchParams();
    const query = String(this.query || "").trim();
    if (query) {
      params.set("q", query);
    }
    params.set("severity", String(this.severity || "all"));
    params.set("event_type", String(this.eventType || "all"));
    params.set("hours", String(this.hours || "168"));
    params.set("limit", String(this.limit || "100"));
    return params.toString();
  }

  @action
  async refreshLogs() {
    this.isLoading = true;
    this.error = "";

    try {
      const query = this.buildQueryParams();
      const data = await ajax(`/admin/plugins/media-gallery/logs.json?${query}`);
      this.events = Array.isArray(data?.events) ? data.events : [];
      this.summary = data?.summary || null;
      this.filterOptions = data?.filter_options || this.filterOptions;
      this.lastLoadedAt = new Date();
    } catch (error) {
      let message = "Unable to load logs.";
      try {
        message =
          error?.jqXHR?.responseJSON?.errors?.join(" ") ||
          error?.jqXHR?.responseText ||
          error?.message ||
          message;
      } catch {
        // ignore
      }
      this.error = message;
      this.events = [];
      this.summary = null;
    } finally {
      this.isLoading = false;
    }
  }

  @action updateQuery(event) { this.query = event?.target?.value ?? ""; }
  @action updateSeverity(event) { this.severity = event?.target?.value ?? "all"; }
  @action updateEventType(event) { this.eventType = event?.target?.value ?? "all"; }
  @action updateHours(event) { this.hours = event?.target?.value ?? "168"; }
  @action updateLimit(event) { this.limit = event?.target?.value ?? "100"; }

  @action
  async submitFilters(event) {
    event?.preventDefault?.();
    await this.refreshLogs();
  }

  @action
  async resetFilters() {
    this.query = "";
    this.severity = "all";
    this.eventType = "all";
    this.hours = "168";
    this.limit = "100";
    await this.refreshLogs();
  }
}
