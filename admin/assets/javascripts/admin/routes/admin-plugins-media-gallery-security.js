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


function booleanLabel(value, positive = "Enabled", negative = "Disabled") {
  return value ? positive : negative;
}

function booleanBadge(value, goodWhen = true) {
  const good = Boolean(value) === Boolean(goodWhen);
  return good ? "mg-security__badge is-success" : "mg-security__badge is-warning";
}

function safeValue(value, fallback = "—") {
  return normalizeText(value, fallback);
}

function yesNo(value) {
  return value ? "Yes" : "No";
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


  get summaryCards() {
    return [
      {
        key: "posture",
        label: "Overall posture",
        value: safeValue(this.summary?.posture),
        detail: "Read-only security status",
        badgeLabel: safeValue(this.summary?.posture, "Unknown"),
        badgeClass: this.postureBadgeClass,
      },
      {
        key: "download",
        label: "Download prevention",
        value: safeValue(this.summary?.download_prevention_level),
        detail: "HLS, fallback, watermark and fingerprint signals",
        badgeLabel: safeValue(this.summary?.download_prevention_level, "Unknown"),
        badgeClass: this.downloadBadgeClass,
      },
      {
        key: "controls",
        label: "Controls",
        value: formatNumber(this.summary?.controls_total),
        detail: `OK ${formatNumber(this.summary?.ok_count)} · Partial ${formatNumber(this.summary?.partial_count)} · Attention ${formatNumber(this.summary?.attention_count)}`,
        badgeLabel: `${formatNumber(this.summary?.ok_count)} OK`,
        badgeClass: "mg-security__badge is-info",
      },
      {
        key: "events",
        label: "Events last 7 days",
        value: formatNumber(this.recentEvents?.total_7d),
        detail: `Warnings/danger: ${formatNumber(this.recentEvents?.warning_or_danger_7d)}`,
        badgeLabel: `${formatNumber(this.recentEvents?.warning_or_danger_7d)} warning`,
        badgeClass: Number(this.recentEvents?.warning_or_danger_7d || 0) > 0 ? "mg-security__badge is-warning" : "mg-security__badge is-success",
      },
    ];
  }

  get downloadFacts() {
    const bindingCount = [this.download?.bind_to_user, this.download?.bind_to_session, this.download?.bind_to_ip].filter(Boolean).length;
    return [
      {
        key: "hls",
        label: "HLS enabled",
        value: booleanLabel(this.download?.hls_enabled),
        detail: "Videos can be delivered as segmented HLS playlists.",
        badgeLabel: this.download?.hls_enabled ? "OK" : "Attention",
        badgeClass: booleanBadge(this.download?.hls_enabled, true),
      },
      {
        key: "hls_only",
        label: "HLS-only video",
        value: this.download?.hls_only_available ? booleanLabel(this.download?.hls_only_enabled) : "Unavailable",
        detail: this.download?.hls_only_enabled ? "Direct video stream fallback is blocked." : "Direct video stream fallback can still be used.",
        badgeLabel: this.download?.hls_only_enabled ? "Protected" : "Fallback allowed",
        badgeClass: this.download?.hls_only_enabled ? "mg-security__badge is-success" : "mg-security__badge is-warning",
      },
      {
        key: "fingerprint",
        label: "Fingerprinting",
        value: booleanLabel(this.download?.fingerprint_enabled),
        detail: this.download?.fingerprint_layout ? `Layout: ${this.download.fingerprint_layout}` : "Per-user segment fingerprinting signal.",
        badgeLabel: this.download?.fingerprint_enabled ? "On" : "Off",
        badgeClass: booleanBadge(this.download?.fingerprint_enabled, true),
      },
      {
        key: "watermark",
        label: "Watermarking",
        value: booleanLabel(this.download?.watermark_enabled),
        detail: this.download?.watermark_user_can_toggle ? "Users may be able to disable visible watermarking." : "Users cannot disable visible watermarking.",
        badgeLabel: this.download?.watermark_enabled ? "On" : "Off",
        badgeClass: booleanBadge(this.download?.watermark_enabled, true),
      },
      {
        key: "ttl",
        label: "Stream token TTL",
        value: `${formatNumber(this.download?.stream_token_ttl_minutes)} min`,
        detail: "Shorter token lifetime reduces replay window but can affect unstable clients.",
        badgeLabel: Number(this.download?.stream_token_ttl_minutes || 0) > 0 ? "Set" : "Check",
        badgeClass: Number(this.download?.stream_token_ttl_minutes || 0) > 0 ? "mg-security__badge is-success" : "mg-security__badge is-warning",
      },
      {
        key: "binding",
        label: "Token binding",
        value: `${bindingCount}/3 active`,
        detail: `User ${yesNo(this.download?.bind_to_user)} · Session ${yesNo(this.download?.bind_to_session)} · IP ${yesNo(this.download?.bind_to_ip)}`,
        badgeLabel: bindingCount >= 2 ? "Strong" : bindingCount === 1 ? "Partial" : "Off",
        badgeClass: bindingCount >= 2 ? "mg-security__badge is-success" : bindingCount === 1 ? "mg-security__badge is-warning" : "mg-security__badge is-danger",
      },
      {
        key: "heartbeat",
        label: "Heartbeat / revoke",
        value: `${this.download?.heartbeat_enabled ? "Heartbeat on" : "Heartbeat off"}`,
        detail: `Revoke ${yesNo(this.download?.revoke_enabled)} · User sessions ${formatNumber(this.download?.max_concurrent_sessions_per_user)} · Active tokens ${formatNumber(this.download?.max_active_tokens_per_user)}`,
        badgeLabel: this.download?.heartbeat_enabled && this.download?.revoke_enabled ? "OK" : "Partial",
        badgeClass: this.download?.heartbeat_enabled && this.download?.revoke_enabled ? "mg-security__badge is-success" : "mg-security__badge is-warning",
      },
      {
        key: "hls_limits",
        label: "HLS rate limits",
        value: `${formatNumber(this.download?.hls_playlist_requests_per_token_per_minute)} / ${formatNumber(this.download?.hls_segment_requests_per_token_per_minute)} per min`,
        detail: "Playlist / segment requests per token per minute.",
        badgeLabel: Number(this.download?.hls_playlist_requests_per_token_per_minute || 0) > 0 && Number(this.download?.hls_segment_requests_per_token_per_minute || 0) > 0 ? "OK" : "Check",
        badgeClass: Number(this.download?.hls_playlist_requests_per_token_per_minute || 0) > 0 && Number(this.download?.hls_segment_requests_per_token_per_minute || 0) > 0 ? "mg-security__badge is-success" : "mg-security__badge is-warning",
      },
    ];
  }

  get forensicsFacts() {
    return [
      {
        key: "exports",
        label: "Export count",
        value: formatNumber(this.forensics?.export_count),
        detail: "Visible forensics export records.",
        badgeLabel: "Info",
        badgeClass: "mg-security__badge is-info",
      },
      {
        key: "expired",
        label: "Expired pending cleanup",
        value: formatNumber(this.forensics?.expired_exports),
        detail: "Exports older than configured retention.",
        badgeLabel: Number(this.forensics?.expired_exports || 0) > 0 ? "Cleanup" : "OK",
        badgeClass: Number(this.forensics?.expired_exports || 0) > 0 ? "mg-security__badge is-warning" : "mg-security__badge is-success",
      },
      {
        key: "latest",
        label: "Latest export",
        value: this.forensicsLatestExportLabel,
        detail: "Most recent generated export.",
        badgeLabel: this.forensics?.latest_export_at ? "Found" : "None",
        badgeClass: this.forensics?.latest_export_at ? "mg-security__badge is-info" : "mg-security__badge is-success",
      },
      {
        key: "delete",
        label: "Manual delete",
        value: booleanLabel(this.forensics?.delete_action_available, "Available", "Unavailable"),
        detail: "Admin export delete action removes DB record and stored files.",
        badgeLabel: this.forensics?.delete_action_available ? "OK" : "Check",
        badgeClass: booleanBadge(this.forensics?.delete_action_available, true),
      },
      {
        key: "retention",
        label: "Retention",
        value: `${formatNumber(this.forensics?.export_retention_days)} days`,
        detail: `Playback sessions ${formatNumber(this.forensics?.playback_session_retention_days)} days · archive ${formatNumber(this.forensics?.archive_retention_days)} days`,
        badgeLabel: Number(this.forensics?.export_retention_days || 0) > 0 ? "Set" : "Unlimited",
        badgeClass: Number(this.forensics?.export_retention_days || 0) > 0 ? "mg-security__badge is-success" : "mg-security__badge is-warning",
      },
      {
        key: "archive",
        label: "Archive copy",
        value: booleanLabel(this.forensics?.archive_enabled),
        detail: `CSV formula protection: ${yesNo(this.forensics?.csv_formula_protection)}`,
        badgeLabel: this.forensics?.archive_enabled ? "On" : "Off",
        badgeClass: this.forensics?.archive_enabled ? "mg-security__badge is-success" : "mg-security__badge is-info",
      },
    ];
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
