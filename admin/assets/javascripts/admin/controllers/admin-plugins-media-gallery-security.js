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

function parseBoolish(value) {
  if (value === true || value === false) {
    return value;
  }

  const text = String(value ?? "")
    .trim()
    .toLowerCase();

  if (["true", "1", "yes", "on", "enabled"].includes(text)) {
    return true;
  }

  if (["false", "0", "no", "off", "disabled"].includes(text)) {
    return false;
  }

  return null;
}

function formatDays(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) {
    return "—";
  }
  if (number === 0) {
    return "Unlimited";
  }
  return `${formatNumber(number)} ${number === 1 ? "day" : "days"}`;
}

function toneForStatus(status) {
  switch (String(status || "").toLowerCase()) {
    case "ok":
    case "good":
    case "success":
      return "success";
    case "partial":
    case "manual":
    case "warning":
    case "medium":
      return "warning";
    case "attention":
    case "danger":
    case "critical":
    case "error":
      return "danger";
    default:
      return "info";
  }
}

function statusChipClass(status) {
  return `mg-security__status-chip is-${toneForStatus(status)}`;
}

function statusDotClass(status) {
  return `mg-security__status-dot is-${toneForStatus(status)}`;
}

function yesNo(value) {
  return value ? "Yes" : "No";
}

function evaluateSetting(setting) {
  const key = setting?.key;
  const present = Boolean(setting?.present);
  const rawValue = setting?.value;

  if (!present) {
    return {
      displayValue: "Unavailable",
      status: "attention",
      statusText: "Missing",
      note: "This setting is not available in the current plugin build.",
    };
  }

  const boolValue = parseBoolish(rawValue);
  const numericValue = Number(rawValue);

  switch (key) {
    case "media_gallery_protected_video_hls_only":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "attention",
        statusText: boolValue ? "OK" : "Check",
        note: boolValue
          ? "Direct video stream fallback is blocked for protected playback."
          : "Protected video can still fall back to direct stream mode.",
      };
    case "media_gallery_hls_enabled":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "attention",
        statusText: boolValue ? "OK" : "Check",
        note: boolValue
          ? "Segmented HLS delivery is available for video playback."
          : "Protected video controls are weaker when HLS is disabled.",
      };
    case "media_gallery_hls_aes128_enabled":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "info",
        statusText: boolValue ? "On" : "Off",
        note: boolValue
          ? "New/reprocessed HLS packages are encrypted with AES-128."
          : "AES-128 is available but disabled; current HLS behavior is unchanged.",
      };
    case "media_gallery_hls_aes128_required":
      return {
        displayValue: boolValue ? "Required" : "Not required",
        status: boolValue ? "ok" : "warning",
        statusText: boolValue ? "Enforced" : "Migration",
        note: boolValue
          ? "Only AES-ready HLS packages may play when the backend setting is active."
          : "Legacy/non-AES HLS can still play while backfill is in progress.",
      };
    case "media_gallery_hls_aes128_key_rotation_segments":
      return {
        displayValue: Number.isFinite(numericValue) ? String(numericValue) : normalizeText(rawValue),
        status: numericValue === 0 ? "ok" : "warning",
        statusText: numericValue === 0 ? "v1 OK" : "Reserved",
        note: numericValue === 0
          ? "Current v1 uses one AES key per video/package."
          : "Non-zero key rotation is reserved for a later implementation.",
      };
    case "media_gallery_log_hls_aes128_key_denials":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "info",
        statusText: boolValue ? "Logging" : "Quiet",
        note: boolValue
          ? "Denied AES key requests are logged for QA/troubleshooting."
          : "Enable during AES QA if key request denials need diagnosis.",
      };
    case "media_gallery_fingerprint_enabled":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "warning",
        statusText: boolValue ? "OK" : "Partial",
        note: boolValue
          ? "Per-user fingerprinting is enabled for new protected media."
          : "Fingerprinting is available but currently disabled.",
      };
    case "media_gallery_watermark_enabled":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "warning",
        statusText: boolValue ? "OK" : "Partial",
        note: boolValue
          ? "Visible watermarking is enabled."
          : "Visible watermarking is available but currently disabled.",
      };
    case "media_gallery_watermark_user_can_toggle":
      return {
        displayValue: boolValue ? "Allowed" : "Blocked",
        status: boolValue ? "warning" : "ok",
        statusText: boolValue ? "Attention" : "OK",
        note: boolValue
          ? "Users may disable the visible watermark."
          : "Users cannot disable the visible watermark.",
      };
    case "media_gallery_block_direct_media_navigation":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "warning",
        statusText: boolValue ? "OK" : "Partial",
        note: boolValue
          ? "Clear top-level navigation to tokenized media URLs is blocked."
          : "Copied media URLs may open directly while their token remains valid.",
      };
    case "media_gallery_bind_stream_to_user":
    case "media_gallery_bind_stream_to_session":
      return {
        displayValue: boolValue ? "Enabled" : "Disabled",
        status: boolValue ? "ok" : "warning",
        statusText: boolValue ? "OK" : "Partial",
        note: boolValue
          ? "Binding is active for issued playback tokens."
          : "Binding is available but currently disabled.",
      };
    case "media_gallery_hls_playlist_requests_per_token_per_minute":
    case "media_gallery_hls_segment_requests_per_token_per_minute":
    case "media_gallery_hls_key_requests_per_token_per_minute":
      return {
        displayValue: Number.isFinite(numericValue) ? `${formatNumber(numericValue)} req/min` : normalizeText(rawValue),
        status: numericValue > 0 ? "ok" : "attention",
        statusText: numericValue > 0 ? "OK" : "Check",
        note: numericValue > 0
          ? "A per-token rate limit is configured."
          : "Set a positive value to limit abusive request bursts.",
      };
    case "media_gallery_forensics_playback_session_retention_days":
    case "media_gallery_forensics_export_retention_days":
    case "media_gallery_forensics_export_archive_retention_days": {
      const status = numericValue >= 90 ? "ok" : numericValue > 0 ? "warning" : "attention";
      const statusText = numericValue >= 90 ? "OK" : numericValue > 0 ? "Custom" : "Check";
      const note = numericValue >= 90
        ? "Retention meets the current 90-day baseline."
        : numericValue > 0
          ? "Retention is shorter than the 90-day baseline."
          : "Retention is unlimited or unset; review your policy.";
      return {
        displayValue: formatDays(numericValue),
        status,
        statusText,
        note,
      };
    }
    default:
      return {
        displayValue: normalizeText(rawValue),
        status: "info",
        statusText: "Info",
        note: "Configuration value shown for reference.",
      };
  }
}

function decorateControl(control) {
  const status = control?.status || "info";
  return {
    ...control,
    key: control?.title || `${status}-${Math.random()}`,
    label: normalizeText(control?.label || status),
    statusText: normalizeText(control?.label || status),
    statusChipClass: statusChipClass(status),
    statusDotClass: statusDotClass(status),
    summary: normalizeText(control?.summary),
    action: normalizeText(control?.action),
  };
}

function decorateSetting(setting) {
  const evaluation = evaluateSetting(setting);
  return {
    ...setting,
    key: setting?.key || setting?.label,
    label: normalizeText(setting?.label),
    recommended: normalizeText(setting?.recommended),
    displayValue: evaluation.displayValue,
    note: evaluation.note,
    statusText: evaluation.statusText,
    statusChipClass: statusChipClass(evaluation.status),
    statusDotClass: statusDotClass(evaluation.status),
  };
}

function decorateProfile(profile) {
  return {
    ...profile,
    key: profile?.profile_key || profile?.label,
    label: normalizeText(profile?.label || profile?.profile_key),
    profileKey: normalizeText(profile?.profile_key),
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
    key: `${entry?.event_type || "event"}-${entry?.count || 0}`,
    label: titleize(entry?.event_type || "event"),
    count: formatNumber(entry?.count),
  };
}

function decorateBaselineCheck(check) {
  const status = check?.status || "info";
  return {
    ...check,
    key: check?.key || check?.label,
    label: normalizeText(check?.label),
    current: normalizeText(check?.current),
    recommended: normalizeText(check?.recommended),
    note: normalizeText(check?.note),
    statusText: normalizeText(check?.status_label || status),
    statusChipClass: statusChipClass(status),
    statusDotClass: statusDotClass(status),
  };
}

function decoratePath(row) {
  const status = row?.status || "info";
  return {
    ...row,
    key: row?.label || row?.path,
    label: normalizeText(row?.label),
    path: normalizeText(row?.path),
    purpose: normalizeText(row?.purpose),
    recommendation: normalizeText(row?.recommendation),
    retention: normalizeText(row?.retention),
    note: normalizeText(row?.note),
    statusText: normalizeText(row?.status_label || status),
    statusChipClass: statusChipClass(status),
    statusDotClass: statusDotClass(status),
  };
}

function decorateFailureReason(row) {
  return {
    key: row?.reason || "unknown",
    label: titleize(row?.reason || "unknown"),
    count: formatNumber(row?.count),
  };
}

function decorateCounter(row) {
  return {
    key: row?.event_type || "event",
    label: titleize(row?.event_type || "event"),
    count: formatNumber(row?.count),
  };
}

function decorateTuningRow(row) {
  const status = row?.status || "info";
  return {
    key: row?.key || "tuning",
    label: normalizeText(row?.label),
    value: formatNumber(row?.value),
    detail: normalizeText(row?.detail),
    statusText: normalizeText(row?.status_label || status),
    statusChipClass: statusChipClass(status),
    statusDotClass: statusDotClass(status),
  };
}

function decorateTuningThreshold(row) {
  const status = row?.status || "info";
  return {
    key: row?.key || "threshold",
    label: normalizeText(row?.label),
    value: normalizeText(row?.value),
    detail: normalizeText(row?.detail),
    statusText: normalizeText(row?.status_label || status),
    statusChipClass: statusChipClass(status),
    statusDotClass: statusDotClass(status),
  };
}

function normalizeSecurityPayload(payload) {
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
  @tracked eventCounters = [];
  @tracked links = [];
  @tracked environment = {};
  @tracked baselineChecks = [];
  @tracked processingFailures = {};
  @tracked backupRetention = {};
  @tracked backupPaths = [];
  @tracked rateLimitTuning = {};
  @tracked aesBackfill = {};
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
    this.eventCounters = [];
    this.links = [];
    this.environment = {};
    this.baselineChecks = [];
    this.processingFailures = {};
    this.backupRetention = {};
    this.backupPaths = [];
    this.rateLimitTuning = {};
    this.aesBackfill = {};
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
    this.environment = data?.environment || {};
    this.baselineChecks = Array.isArray(data?.baseline_checks) ? data.baseline_checks.map(decorateBaselineCheck) : [];
    this.processingFailures = data?.processing_failures || {};
    this.backupRetention = data?.backup_retention || {};
    this.backupPaths = Array.isArray(data?.backup_retention?.paths) ? data.backup_retention.paths.map(decoratePath) : [];
    this.rateLimitTuning = data?.rate_limit_tuning || {};
    this.aesBackfill = data?.aes128_backfill || {};
    this.recentEvents = data?.recent_events || {};
    this.topEventTypes = Array.isArray(data?.recent_events?.top_event_types)
      ? data.recent_events.top_event_types.map(decorateEvent)
      : [];
    this.eventCounters = Array.isArray(data?.recent_events?.counters)
      ? data.recent_events.counters.map(decorateCounter)
      : [];
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
    const posture = String(this.summary?.posture || "");
    const postureStatus = posture.toLowerCase().includes("attention")
      ? "attention"
      : posture.toLowerCase() === "partial"
        ? "partial"
        : "ok";

    const level = String(this.summary?.download_prevention_level || "");
    const levelStatus = level.toLowerCase() === "strong"
      ? "ok"
      : level.toLowerCase() === "medium"
        ? "warning"
        : level.toLowerCase() === "basic"
          ? "info"
          : "attention";

    const attentionCount = Number(this.summary?.attention_count || 0);
    const partialCount = Number(this.summary?.partial_count || 0) + Number(this.summary?.manual_count || 0);
    const warningEvents = Number(this.recentEvents?.warning_or_danger_7d || 0);

    return [
      {
        key: "posture",
        label: "Overall posture",
        value: normalizeText(this.summary?.posture),
        secondary: "Read-only security status",
        detail: "High-level summary of current security control posture.",
        statusDotClass: statusDotClass(postureStatus),
        statusTitle: posture || "Unknown",
      },
      {
        key: "download",
        label: "Download prevention",
        value: normalizeText(this.summary?.download_prevention_level),
        secondary: "HLS, fallback, watermark and fingerprint signals",
        detail: "Combined deterrence level based on current protection settings.",
        statusDotClass: statusDotClass(levelStatus),
        statusTitle: level || "Unknown",
      },
      {
        key: "controls",
        label: "Controls",
        value: formatNumber(this.summary?.controls_total),
        secondary: `OK ${formatNumber(this.summary?.ok_count)} · Partial ${formatNumber(this.summary?.partial_count)} · Attention ${formatNumber(this.summary?.attention_count)}`,
        detail: partialCount > 0 || attentionCount > 0 ? "Some controls depend on configuration or need review." : "All tracked controls currently report OK.",
        statusDotClass: statusDotClass(attentionCount > 0 ? "attention" : partialCount > 0 ? "partial" : "ok"),
        statusTitle: attentionCount > 0 ? "Attention present" : partialCount > 0 ? "Partial controls" : "All OK",
      },
      {
        key: "events",
        label: "Events last 7 days",
        value: formatNumber(this.recentEvents?.total_7d),
        secondary: `${formatNumber(this.recentEvents?.warning_or_danger_7d)} warning/danger`,
        detail: "Recent logged media security events. Use Logs for event details.",
        statusDotClass: statusDotClass(warningEvents > 0 ? "warning" : "ok"),
        statusTitle: warningEvents > 0 ? "Warnings present" : "No warnings",
      },
    ];
  }

  get downloadFacts() {
    const bindingCount = [this.download?.bind_to_user, this.download?.bind_to_session, this.download?.bind_to_ip].filter(Boolean).length;

    return [
      {
        key: "hls",
        label: "HLS enabled",
        value: this.download?.hls_enabled ? "Enabled" : "Disabled",
        detail: "Videos can be delivered as segmented HLS playlists.",
        statusText: this.download?.hls_enabled ? "OK" : "Check",
        statusChipClass: statusChipClass(this.download?.hls_enabled ? "ok" : "attention"),
        statusDotClass: statusDotClass(this.download?.hls_enabled ? "ok" : "attention"),
      },
      {
        key: "hls_only",
        label: "HLS-only video",
        value: this.download?.hls_only_available ? (this.download?.hls_only_enabled ? "Enabled" : "Disabled") : "Unavailable",
        detail: this.download?.hls_only_enabled
          ? "Direct video stream fallback is blocked."
          : "Direct video stream fallback can still be used.",
        statusText: this.download?.hls_only_enabled ? "Protected" : "Fallback allowed",
        statusChipClass: statusChipClass(this.download?.hls_only_enabled ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.hls_only_enabled ? "ok" : "warning"),
      },
      {
        key: "hls_aes128",
        label: "HLS AES-128",
        value: this.download?.hls_aes128_required ? "Required" : this.download?.hls_aes128_enabled ? "Enabled" : "Disabled",
        detail: this.download?.hls_aes128_required
          ? "Only AES-ready HLS packages may play; direct stream fallback is blocked."
          : this.download?.hls_aes128_enabled
            ? `Encrypting new/reprocessed HLS packages; key limit ${formatNumber(this.download?.hls_key_requests_per_token_per_minute)} req/min.`
            : "AES-128 hardening is available but currently off.",
        statusText: this.download?.hls_aes128_required ? "Enforced" : this.download?.hls_aes128_enabled ? "Migration" : "Off",
        statusChipClass: statusChipClass(this.download?.hls_aes128_required ? "ok" : this.download?.hls_aes128_enabled ? "warning" : "info"),
        statusDotClass: statusDotClass(this.download?.hls_aes128_required ? "ok" : this.download?.hls_aes128_enabled ? "warning" : "info"),
      },
      {
        key: "direct_navigation",
        label: "Direct URL opening",
        value: this.download?.block_direct_media_navigation ? "Blocked" : "Allowed",
        detail: this.download?.block_direct_media_navigation
          ? "Address-bar/new-tab navigation to tokenized media endpoints is blocked when browsers send Fetch Metadata headers."
          : "Copied tokenized media URLs may open directly until their token expires.",
        statusText: this.download?.block_direct_media_navigation ? "OK" : "Partial",
        statusChipClass: statusChipClass(this.download?.block_direct_media_navigation ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.block_direct_media_navigation ? "ok" : "warning"),
      },
      {
        key: "fingerprint",
        label: "Fingerprinting",
        value: this.download?.fingerprint_enabled ? "Enabled" : "Disabled",
        detail: this.download?.fingerprint_layout ? `Layout: ${this.download.fingerprint_layout}` : "Per-user segment fingerprinting signal.",
        statusText: this.download?.fingerprint_enabled ? "On" : "Off",
        statusChipClass: statusChipClass(this.download?.fingerprint_enabled ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.fingerprint_enabled ? "ok" : "warning"),
      },
      {
        key: "watermark",
        label: "Watermarking",
        value: this.download?.watermark_enabled ? "Enabled" : "Disabled",
        detail: this.download?.watermark_user_can_toggle
          ? "Users may be able to disable visible watermarking."
          : "Users cannot disable visible watermarking.",
        statusText: this.download?.watermark_enabled ? (this.download?.watermark_user_can_toggle ? "Partial" : "On") : "Off",
        statusChipClass: statusChipClass(this.download?.watermark_enabled ? (this.download?.watermark_user_can_toggle ? "warning" : "ok") : "warning"),
        statusDotClass: statusDotClass(this.download?.watermark_enabled ? (this.download?.watermark_user_can_toggle ? "warning" : "ok") : "warning"),
      },
      {
        key: "ttl",
        label: "Stream token TTL",
        value: `${formatNumber(this.download?.stream_token_ttl_minutes)} min`,
        detail: "Shorter token lifetime reduces replay window but can affect unstable clients.",
        statusText: Number(this.download?.stream_token_ttl_minutes || 0) > 0 ? "Set" : "Check",
        statusChipClass: statusChipClass(Number(this.download?.stream_token_ttl_minutes || 0) > 0 ? "ok" : "warning"),
        statusDotClass: statusDotClass(Number(this.download?.stream_token_ttl_minutes || 0) > 0 ? "ok" : "warning"),
      },
      {
        key: "binding",
        label: "Token binding",
        value: `${bindingCount}/3 active`,
        detail: `User ${yesNo(this.download?.bind_to_user)} · Session ${yesNo(this.download?.bind_to_session)} · IP ${yesNo(this.download?.bind_to_ip)}`,
        statusText: bindingCount >= 2 ? "Strong" : bindingCount === 1 ? "Partial" : "Off",
        statusChipClass: statusChipClass(bindingCount >= 2 ? "ok" : bindingCount === 1 ? "warning" : "attention"),
        statusDotClass: statusDotClass(bindingCount >= 2 ? "ok" : bindingCount === 1 ? "warning" : "attention"),
      },
      {
        key: "heartbeat",
        label: "Heartbeat / revoke",
        value: this.download?.heartbeat_enabled ? "Heartbeat on" : "Heartbeat off",
        detail: `Revoke ${yesNo(this.download?.revoke_enabled)} · User sessions ${formatNumber(this.download?.max_concurrent_sessions_per_user)} · Active tokens ${formatNumber(this.download?.max_active_tokens_per_user)}`,
        statusText: this.download?.heartbeat_enabled && this.download?.revoke_enabled ? "OK" : "Partial",
        statusChipClass: statusChipClass(this.download?.heartbeat_enabled && this.download?.revoke_enabled ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.heartbeat_enabled && this.download?.revoke_enabled ? "ok" : "warning"),
      },
      {
        key: "hls_limits",
        label: "HLS rate limits",
        value: `${formatNumber(this.download?.hls_playlist_requests_per_token_per_minute)} / ${formatNumber(this.download?.hls_segment_requests_per_token_per_minute)} / ${formatNumber(this.download?.hls_key_requests_per_token_per_minute)} req/min`,
        detail: "Playlist / segment / AES key requests allowed per token per minute.",
        statusText:
          Number(this.download?.hls_playlist_requests_per_token_per_minute || 0) > 0 &&
          Number(this.download?.hls_segment_requests_per_token_per_minute || 0) > 0 &&
          Number(this.download?.hls_key_requests_per_token_per_minute || 0) > 0
            ? "OK"
            : "Check",
        statusChipClass: statusChipClass(
          Number(this.download?.hls_playlist_requests_per_token_per_minute || 0) > 0 &&
            Number(this.download?.hls_segment_requests_per_token_per_minute || 0) > 0 &&
            Number(this.download?.hls_key_requests_per_token_per_minute || 0) > 0
            ? "ok"
            : "warning"
        ),
        statusDotClass: statusDotClass(
          Number(this.download?.hls_playlist_requests_per_token_per_minute || 0) > 0 &&
            Number(this.download?.hls_segment_requests_per_token_per_minute || 0) > 0 &&
            Number(this.download?.hls_key_requests_per_token_per_minute || 0) > 0
            ? "ok"
            : "warning"
        ),
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
        statusText: "Info",
        statusChipClass: statusChipClass("info"),
        statusDotClass: statusDotClass("info"),
      },
      {
        key: "expired",
        label: "Expired pending cleanup",
        value: formatNumber(this.forensics?.expired_exports),
        detail: "Exports older than configured retention.",
        statusText: Number(this.forensics?.expired_exports || 0) > 0 ? "Cleanup" : "OK",
        statusChipClass: statusChipClass(Number(this.forensics?.expired_exports || 0) > 0 ? "warning" : "ok"),
        statusDotClass: statusDotClass(Number(this.forensics?.expired_exports || 0) > 0 ? "warning" : "ok"),
      },
      {
        key: "latest",
        label: "Latest export",
        value: this.forensicsLatestExportLabel,
        detail: "Most recent generated export.",
        statusText: this.forensics?.latest_export_at ? "Found" : "None",
        statusChipClass: statusChipClass(this.forensics?.latest_export_at ? "info" : "ok"),
        statusDotClass: statusDotClass(this.forensics?.latest_export_at ? "info" : "ok"),
      },
      {
        key: "delete",
        label: "Manual delete",
        value: this.forensics?.delete_action_available ? "Available" : "Unavailable",
        detail: "Admin export delete action removes the DB record and stored files.",
        statusText: this.forensics?.delete_action_available ? "OK" : "Check",
        statusChipClass: statusChipClass(this.forensics?.delete_action_available ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.forensics?.delete_action_available ? "ok" : "warning"),
      },
      {
        key: "retention",
        label: "Retention",
        value: formatDays(this.forensics?.export_retention_days),
        detail: `Playback sessions ${formatDays(this.forensics?.playback_session_retention_days)} · archive ${formatDays(this.forensics?.archive_retention_days)}`,
        statusText: Number(this.forensics?.export_retention_days || 0) > 0 ? "Set" : "Check",
        statusChipClass: statusChipClass(Number(this.forensics?.export_retention_days || 0) > 0 ? "ok" : "warning"),
        statusDotClass: statusDotClass(Number(this.forensics?.export_retention_days || 0) > 0 ? "ok" : "warning"),
      },
      {
        key: "archive",
        label: "Archive copy",
        value: this.forensics?.archive_enabled ? "Enabled" : "Disabled",
        detail: `CSV formula protection: ${yesNo(this.forensics?.csv_formula_protection)}`,
        statusText: this.forensics?.archive_enabled ? "On" : "Off",
        statusChipClass: statusChipClass(this.forensics?.archive_enabled ? "ok" : "info"),
        statusDotClass: statusDotClass(this.forensics?.archive_enabled ? "ok" : "info"),
      },
    ];
  }

  get storageProfiles() {
    const activeProfile = String(this.storage?.active_profile || "");
    return this.profiles.map((profile) => {
      const isActive = activeProfile && activeProfile === profile.profileKey;
      const pathValue = profile.rootPath !== "—" ? profile.rootPath : profile.prefix;
      return {
        ...profile,
        statusText: isActive ? "Active" : "Configured",
        statusChipClass: statusChipClass(isActive ? "ok" : "info"),
        statusDotClass: statusDotClass(isActive ? "ok" : "info"),
        pathValue,
      };
    });
  }

  get aesBackfillFact() {
    const b = this.aesBackfill || {};
    const enabled = !!b.aes_enabled;
    const failed = Number(b.failed_count || 0);
    const stale = Number(b.stale_count || 0);
    const queued = Number(b.queued_count || 0);
    const processing = Number(b.processing_count || 0);
    const needs = Number(b.needs_backfill_count || 0);
    const ready = Number(b.aes_ready_count || 0);
    const hls = Number(b.hls_ready_video_count || 0);
    const status = !enabled
      ? "info"
      : failed > 0 || stale > 0
        ? "attention"
        : queued > 0 || processing > 0 || needs > 0
          ? "warning"
          : "ok";

    return {
      key: "aes_backfill_health",
      label: "AES backfill health",
      value: enabled ? `${formatNumber(ready)} / ${formatNumber(hls)} AES-ready` : "AES disabled",
      detail: enabled
        ? `Needs ${formatNumber(needs)} · queued ${formatNumber(queued)} · processing ${formatNumber(processing)} · failed ${formatNumber(failed)} · stale ${formatNumber(stale)}`
        : "Enable HLS AES-128 before backfilling legacy HLS videos.",
      statusText: !enabled ? "Off" : failed > 0 || stale > 0 ? "Review" : queued > 0 || processing > 0 ? "Running" : needs > 0 ? "Backfill" : "OK",
      statusChipClass: statusChipClass(status),
      statusDotClass: statusDotClass(status),
    };
  }


  get environmentFacts() {
    const status = this.environment?.status || "info";
    return [
      {
        key: "base_url",
        label: "Canonical base URL",
        value: normalizeText(this.environment?.base_url),
        detail: "Recommended: use a single HTTPS canonical URL.",
        statusText: normalizeText(this.environment?.label || status),
        statusChipClass: statusChipClass(status),
        statusDotClass: statusDotClass(status),
      },
      {
        key: "request_scheme",
        label: "Current request scheme",
        value: normalizeText(this.environment?.request_scheme).toUpperCase(),
        detail: `Request host ${normalizeText(this.environment?.request_host)}; canonical host ${normalizeText(this.environment?.canonical_host)}.`,
        statusText: this.environment?.https_ok ? "HTTPS" : "Review",
        statusChipClass: statusChipClass(this.environment?.https_ok ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.environment?.https_ok ? "ok" : "warning"),
      },
      {
        key: "host_match",
        label: "Canonical host match",
        value: this.environment?.host_matches ? "Matches" : "Review",
        detail: normalizeText(this.environment?.action),
        statusText: this.environment?.host_matches ? "OK" : "Check",
        statusChipClass: statusChipClass(this.environment?.host_matches ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.environment?.host_matches ? "ok" : "warning"),
      },
    ];
  }

  get recentControlFacts() {
    const hardStreamLimits = Number(this.download?.stream_requests_per_token_per_minute || 0) > 0 || Number(this.download?.stream_range_requests_per_token_per_minute || 0) > 0;
    const f11Policy = normalizeText(this.download?.forensics_http_source_url_policy, "deny_all");
    return [
      {
        key: "direct_navigation",
        label: "Direct media URL opening",
        value: this.download?.block_direct_media_navigation ? "Blocked" : "Allowed",
        detail: "Blocks clear top-level browser navigation to tokenized play, stream and HLS endpoints. Final S3/R2 redirect URLs cannot be controlled after redirect.",
        statusText: this.download?.block_direct_media_navigation ? "OK" : "Partial",
        statusChipClass: statusChipClass(this.download?.block_direct_media_navigation ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.block_direct_media_navigation ? "ok" : "warning"),
      },
      {
        key: "f08_soft",
        label: "Stream anomaly logging",
        value: this.download?.log_stream_anomalies ? "Enabled" : "Disabled",
        detail: `Soft thresholds: ${formatNumber(this.download?.stream_anomaly_requests_per_token_per_minute)} requests/min and ${formatNumber(this.download?.stream_anomaly_range_requests_per_token_per_minute)} range requests/min.`,
        statusText: this.download?.log_stream_anomalies ? "OK" : "Check",
        statusChipClass: statusChipClass(this.download?.log_stream_anomalies ? "ok" : "warning"),
        statusDotClass: statusDotClass(this.download?.log_stream_anomalies ? "ok" : "warning"),
      },
      {
        key: "aes_key_logging",
        label: "AES key denial logging",
        value: this.download?.log_hls_aes128_key_denials ? "Enabled" : "Disabled",
        detail: `Key endpoint rate limit: ${formatNumber(this.download?.hls_key_requests_per_token_per_minute)} requests per token per minute.`,
        statusText: this.download?.log_hls_aes128_key_denials ? "QA ready" : "Quiet",
        statusChipClass: statusChipClass(this.download?.log_hls_aes128_key_denials ? "ok" : "info"),
        statusDotClass: statusDotClass(this.download?.log_hls_aes128_key_denials ? "ok" : "info"),
      },
      this.aesBackfillFact,
      {
        key: "f08_hard",
        label: "Hard stream limits",
        value: hardStreamLimits ? "Configured" : "Observe only",
        detail: `Hard limits: ${formatNumber(this.download?.stream_requests_per_token_per_minute)} total/min and ${formatNumber(this.download?.stream_range_requests_per_token_per_minute)} range/min.`,
        statusText: hardStreamLimits ? "Active" : "Safe default",
        statusChipClass: statusChipClass(hardStreamLimits ? "warning" : "ok"),
        statusDotClass: statusDotClass(hardStreamLimits ? "warning" : "ok"),
      },
      {
        key: "f11_policy",
        label: "Forensic HTTP policy",
        value: f11Policy,
        detail: "deny_all is strict production behavior; canonical_only is useful for HTTP test sites.",
        statusText: f11Policy === "deny_all" ? "OK" : f11Policy === "canonical_only" ? "Test mode" : "Review",
        statusChipClass: statusChipClass(f11Policy === "deny_all" ? "ok" : f11Policy === "canonical_only" ? "warning" : "attention"),
        statusDotClass: statusDotClass(f11Policy === "deny_all" ? "ok" : f11Policy === "canonical_only" ? "warning" : "attention"),
      },
      {
        key: "f12_thumbs",
        label: "Thumbnail no-store",
        value: this.download?.no_store_thumbnails ? "Enabled" : "Disabled",
        detail: "No-store thumbnails reduce cache reuse but can increase thumbnail traffic.",
        statusText: this.download?.no_store_thumbnails ? "OK" : "Optional",
        statusChipClass: statusChipClass(this.download?.no_store_thumbnails ? "ok" : "info"),
        statusDotClass: statusDotClass(this.download?.no_store_thumbnails ? "ok" : "info"),
      },
      {
        key: "fail_closed",
        label: "Upload content validation",
        value: this.download?.fail_closed_on_unrecognized_media ? "Fail closed" : "Fallback allowed",
        detail: "Rejects renamed PDFs/ZIPs/random bytes before the full FFmpeg processing pipeline.",
        statusText: this.download?.fail_closed_on_unrecognized_media ? "OK" : "Review",
        statusChipClass: statusChipClass(this.download?.fail_closed_on_unrecognized_media ? "ok" : "attention"),
        statusDotClass: statusDotClass(this.download?.fail_closed_on_unrecognized_media ? "ok" : "attention"),
      },
    ];
  }

  get baselineRows() {
    return this.baselineChecks;
  }

  get processingFailureFacts() {
    const rows = Array.isArray(this.processingFailures?.top_reasons_30d)
      ? this.processingFailures.top_reasons_30d.map(decorateFailureReason)
      : [];

    if (rows.length) {
      return rows;
    }

    return [{ key: "none", label: "No recent processing failures", count: "0" }];
  }

  get rateLimitTuningFacts() {
    const rows = Array.isArray(this.rateLimitTuning?.rows)
      ? this.rateLimitTuning.rows.map(decorateTuningRow)
      : [];

    return rows.length
      ? rows
      : [{ key: "none", label: "No tuning events", value: "0", detail: "No recent rate-limit or anomaly signals found.", statusText: "OK", statusChipClass: statusChipClass("ok"), statusDotClass: statusDotClass("ok") }];
  }

  get rateLimitThresholdFacts() {
    return Array.isArray(this.rateLimitTuning?.thresholds)
      ? this.rateLimitTuning.thresholds.map(decorateTuningThreshold)
      : [];
  }

  get rateLimitTuningStatusChipClass() {
    return statusChipClass(this.rateLimitTuning?.status || "info");
  }

  get rateLimitTuningStatusDotClass() {
    return statusDotClass(this.rateLimitTuning?.status || "info");
  }

  get rateLimitTuningStatusText() {
    return titleize(this.rateLimitTuning?.status || "info");
  }

  get rateLimitTuningSummary() {
    return normalizeText(this.rateLimitTuning?.summary, "Observe recent traffic before tightening enforcement thresholds.");
  }

  get processingFailureSummaryFacts() {
    return [
      {
        key: "failed_7d",
        label: "Failed last 7 days",
        value: formatNumber(this.processingFailures?.failed_7d),
        detail: "Media items currently failed and updated in the last 7 days.",
        statusText: Number(this.processingFailures?.failed_7d || 0) > 0 ? "Review" : "OK",
        statusChipClass: statusChipClass(Number(this.processingFailures?.failed_7d || 0) > 0 ? "warning" : "ok"),
        statusDotClass: statusDotClass(Number(this.processingFailures?.failed_7d || 0) > 0 ? "warning" : "ok"),
      },
      {
        key: "failed_30d",
        label: "Failed last 30 days",
        value: formatNumber(this.processingFailures?.failed_30d),
        detail: "Grouped by sanitized failure reason, not raw user content.",
        statusText: Number(this.processingFailures?.failed_30d || 0) > 0 ? "Info" : "OK",
        statusChipClass: statusChipClass(Number(this.processingFailures?.failed_30d || 0) > 0 ? "info" : "ok"),
        statusDotClass: statusDotClass(Number(this.processingFailures?.failed_30d || 0) > 0 ? "info" : "ok"),
      },
      {
        key: "failed_total",
        label: "Total failed items",
        value: formatNumber(this.processingFailures?.total_failed),
        detail: "All currently failed media items, regardless of age.",
        statusText: "Info",
        statusChipClass: statusChipClass("info"),
        statusDotClass: statusDotClass("info"),
      },
    ];
  }

  get backupPathFacts() {
    return this.backupPaths;
  }

  get eventCounterFacts() {
    return this.eventCounters;
  }

  get quickLinks() {
    const links = Array.isArray(this.links) ? [...this.links] : [];
    const extras = [
      { label: "Management", url: "/admin/plugins/media-gallery-management" },
      { label: "Forensic identify", url: "/admin/plugins/media-gallery-forensics-identify" },
    ];

    extras.forEach((extra) => {
      if (!links.some((link) => link?.url === extra.url)) {
        links.push(extra);
      }
    });

    return links;
  }

  get forensicsLatestExportLabel() {
    return formatDateTime(this.forensics?.latest_export_at);
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
