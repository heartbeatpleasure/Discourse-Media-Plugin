import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

function normalizeText(value, fallback = "—") {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  const text = String(value).trim();
  return text ? text : fallback;
}

function titleize(value) {
  return normalizeText(value)
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function formatNumber(value) {
  const number = Number(value || 0);
  return Number.isFinite(number) ? new Intl.NumberFormat().format(number) : "0";
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

function statusTone(status) {
  switch (String(status || "").toLowerCase()) {
    case "ok":
      return "success";
    case "partial":
    case "manual":
      return "warning";
    case "attention":
      return "danger";
    default:
      return "info";
  }
}

function badgeClass(status) {
  return ["mg-security__badge", `is-${statusTone(status)}`].join(" ");
}

function decorateControl(control) {
  const status = control?.status || "info";
  return {
    ...control,
    key: control?.title || `${status}-${Math.random()}`,
    label: normalizeText(control?.label || status),
    badgeClass: badgeClass(status),
    summary: normalizeText(control?.summary),
    action: normalizeText(control?.action),
  };
}

function decorateSetting(setting) {
  return {
    ...setting,
    key: setting?.key || setting?.label,
    label: normalizeText(setting?.label),
    value: normalizeText(setting?.value),
    recommended: normalizeText(setting?.recommended),
    badgeClass: setting?.present ? "mg-security__badge is-info" : "mg-security__badge is-warning",
    presentLabel: setting?.present ? "available" : "not available",
  };
}

function decorateProfile(profile) {
  return {
    ...profile,
    key: profile?.profile_key || profile?.label,
    label: normalizeText(profile?.label || profile?.profile_key),
    backendLabel: titleize(profile?.backend),
    deliveryModeLabel: titleize(profile?.delivery_mode),
    endpoint: normalizeText(profile?.config?.endpoint, "—"),
    bucket: normalizeText(profile?.config?.bucket, "—"),
    prefix: normalizeText(profile?.config?.prefix, "—"),
    rootPath: normalizeText(profile?.config?.local_asset_root_path, "—"),
  };
}

function decorateEvent(entry) {
  return {
    key: entry?.event_type || "event",
    label: titleize(entry?.event_type || "event"),
    count: formatNumber(entry?.count),
  };
}

function normalizeSecurityPayload(payload) {
  // Normal response is top-level. Accept wrapped variants as a defensive fallback
  // so future/older controller wrappers do not render the page as empty.
  return payload?.security || payload?.security_status || payload?.data || payload || {};
}

export default class AdminPluginsMediaGallerySecurityController extends Controller {
  @tracked isLoading = false;
  @tracked error = "";
  @tracked summary = {};
  @tracked controls = [];
  @tracked settings = [];
  @tracked storage = {};
  @tracked download = {};
  @tracked profiles = [];
  @tracked forensics = {};
  @tracked recentEvents = {};
  @tracked topEventTypes = [];
  @tracked links = [];
  @tracked generatedAt = "";
  @tracked hasLoaded = false;

  resetState() {
    this.isLoading = false;
    this.error = "";
    this.summary = {};
    this.controls = [];
    this.settings = [];
    this.storage = {};
    this.download = {};
    this.profiles = [];
    this.forensics = {};
    this.recentEvents = {};
    this.topEventTypes = [];
    this.links = [];
    this.generatedAt = "";
    this.hasLoaded = false;
  }

  applySecurityStatus(payload) {
    const data = normalizeSecurityPayload(payload);

    if (data?.error_message) {
      this.error = data.error_message;
      this.hasLoaded = true;
      return;
    }

    this.generatedAt = data?.generated_at || "";
    this.summary = data?.summary || {};
    this.controls = Array.isArray(data?.controls) ? data.controls.map(decorateControl) : [];
    this.settings = Array.isArray(data?.settings) ? data.settings.map(decorateSetting) : [];
    this.storage = data?.storage || {};
    this.download = data?.download_prevention || {};
    this.profiles = Array.isArray(data?.storage?.profiles) ? data.storage.profiles.map(decorateProfile) : [];
    this.forensics = data?.forensics || {};
    this.recentEvents = data?.recent_events || {};
    this.topEventTypes = Array.isArray(data?.recent_events?.top_event_types) ? data.recent_events.top_event_types.map(decorateEvent) : [];
    this.links = Array.isArray(data?.links) ? data.links : [];
    this.hasLoaded = true;

    if (!this.generatedAt && !this.controls.length && !this.settings.length && !this.profiles.length) {
      this.error = "Security status response was empty. Refresh or check the JSON endpoint.";
    }
  }

  get generatedAtLabel() {
    return formatDateTime(this.generatedAt);
  }

  get postureBadgeClass() {
    const posture = String(this.summary?.posture || "").toLowerCase();
    if (posture === "good") {
      return "mg-security__badge is-success";
    }
    if (posture === "partial") {
      return "mg-security__badge is-warning";
    }
    return "mg-security__badge is-danger";
  }

  get downloadBadgeClass() {
    const level = String(this.summary?.download_prevention_level || "").toLowerCase();
    if (level === "strong") {
      return "mg-security__badge is-success";
    }
    if (level === "medium") {
      return "mg-security__badge is-warning";
    }
    return "mg-security__badge is-info";
  }

  get forensicsLatestExportLabel() {
    return formatDateTime(this.forensics?.latest_export_at);
  }

  get hlsOnlyLabel() {
    if (!this.summary?.download_prevention_level) {
      return "—";
    }
    return this.summary.download_prevention_level;
  }

  @action
  async loadSecurityStatus() {
    this.isLoading = true;
    this.error = "";

    try {
      const data = await ajax("/admin/plugins/media-gallery/security.json");
      this.applySecurityStatus(data);
    } catch (e) {
      this.error = e?.jqXHR?.responseJSON?.message || e?.message || "Security status could not be loaded.";
      this.hasLoaded = true;
    } finally {
      this.isLoading = false;
    }
  }
}
