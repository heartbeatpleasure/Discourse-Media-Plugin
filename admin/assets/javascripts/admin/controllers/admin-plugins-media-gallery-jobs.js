import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";

function formatNumber(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) {
    return "0";
  }
  return new Intl.NumberFormat().format(number);
}

function formatDateTime(value) {
  if (!value) {
    return null;
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
    .replace(/_/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function statusClass(group) {
  switch (String(group || "")) {
    case "active":
      return "is-info";
    case "failed":
      return "is-danger";
    case "completed":
      return "is-success";
    default:
      return "is-muted";
  }
}

function progressLabel(progress) {
  if (!progress) {
    return null;
  }

  const parts = [];
  if (progress.index && progress.total) {
    parts.push(`${formatNumber(progress.index)} / ${formatNumber(progress.total)}`);
  }
  if (progress.percent !== null && progress.percent !== undefined) {
    parts.push(`${progress.percent}%`);
  }
  if (progress.copied !== null && progress.copied !== undefined) {
    parts.push(`${formatNumber(progress.copied)} copied`);
  }
  if (progress.skipped !== null && progress.skipped !== undefined) {
    parts.push(`${formatNumber(progress.skipped)} skipped`);
  }
  if (progress.failed) {
    parts.push(`${formatNumber(progress.failed)} failed`);
  }

  return parts.join(" • ") || null;
}

function compactRow(row) {
  const group = row?.group;
  const primaryUrl =
    group === "migration"
      ? row?.migrations_url
      : group === "forensics"
        ? row?.forensics_url
        : group === "test_download"
          ? row?.test_downloads_url
          : row?.management_url;
  const primaryLabel =
    group === "migration"
      ? "Open migration"
      : group === "forensics"
        ? "Open identify search"
        : group === "test_download"
          ? "Open test downloads"
          : "Open management";
  const secondaryUrl =
    primaryUrl !== row?.management_url && row?.management_url ? row.management_url : null;

  return {
    ...row,
    statusClass: statusClass(row?.status_group),
    statusLabel: row?.status_label || titleize(row?.status),
    progressLabel: progressLabel(row?.progress),
    titleLabel: row?.title || row?.public_id || row?.operation || "Untitled job",
    itemMeta: [row?.public_id, row?.media_type, row?.username].filter(Boolean).join(" • "),
    updatedAtDisplay: formatDateTime(row?.updated_at),
    primaryUrl,
    primaryLabel,
    secondaryUrl,
    secondaryLabel: secondaryUrl ? "Open management" : null,
  };
}

function urlFor({ status = "all", type = "all", limit = "50" } = {}) {
  const params = new URLSearchParams();
  if (status && status !== "all") {
    params.set("status", status);
  }
  if (type && type !== "all") {
    params.set("type", type);
  }
  if (limit && limit !== "50") {
    params.set("limit", limit);
  }

  const query = params.toString();
  return `/admin/plugins/media-gallery-jobs${query ? `?${query}` : ""}`;
}

function countFrom(entries, keyName, keyValue) {
  const entry = (entries || []).find((item) => String(item?.[keyName]) === String(keyValue));
  return Number(entry?.count || 0);
}

export default class AdminPluginsMediaGalleryJobsController extends Controller {
  queryParams = ["status", "type", "limit"];

  @tracked rows = [];
  @tracked summary = {};
  @tracked status = "all";
  @tracked type = "all";
  @tracked limit = "50";
  @tracked error = null;
  @tracked generatedAtLabel = null;
  @tracked generatedAt = null;

  loadModel(data = {}) {
    const filters = data.filters || {};
    this.status = filters.status || this.status || "all";
    this.type = filters.type || this.type || "all";
    this.limit = String(data.limit || this.limit || "50");
    this.summary = data.summary || {};
    this.rows = (data.rows || []).map(compactRow);
    this.generatedAtLabel = data.generated_at_label || null;
    this.generatedAt = data.generated_at || null;
    this.error = data.error || null;
  }

  get hasRows() {
    return this.rows.length > 0;
  }

  get activeCountLabel() {
    return formatNumber(this.summary?.active_count || 0);
  }

  get failedCountLabel() {
    return formatNumber(this.summary?.failed_count || 0);
  }

  get completedCountLabel() {
    return formatNumber(this.summary?.completed_count || 0);
  }

  get visibleCountLabel() {
    return formatNumber(this.summary?.visible_count || this.rows.length || 0);
  }

  get totalCountLabel() {
    return formatNumber(this.summary?.total_count || 0);
  }

  get statusScopeCountLabel() {
    return formatNumber(this.summary?.status_scope_count || 0);
  }

  get generatedAtDisplay() {
    return formatDateTime(this.generatedAt) || this.generatedAtLabel;
  }

  get refreshUrl() {
    return urlFor({ status: this.status, type: this.type, limit: this.limit });
  }

  get statusCards() {
    const statuses = [
      { value: "all", label: "All statuses", description: "All known states for the selected job type." },
      { value: "active", label: "Active", description: "Queued or running operations." },
      { value: "failed", label: "Failed", description: "Operations that need review." },
      { value: "completed", label: "Completed", description: "Recently completed/logged." },
    ];

    return statuses.map((status) => {
      const count = countFrom(this.summary?.by_status, "status", status.value);
      const isActive = status.value === this.status;
      return {
        ...status,
        count,
        countLabel: formatNumber(count),
        isActive,
        isDisabled: status.value !== "all" && count === 0 && !isActive,
        href: urlFor({ status: status.value, type: this.type, limit: this.limit }),
      };
    });
  }

  get showingSummaryLabel() {
    return `Showing ${this.visibleCountLabel} of ${this.totalCountLabel} known states.`;
  }

  get typeCards() {
    const allCount = Number(this.summary?.type_scope_count || 0);
    const entries = [
      { type: "all", label: "All job types", count: allCount },
      ...(this.summary?.by_type || []),
    ];

    return entries.map((entry) => {
      const value = entry?.type || entry?.value || "all";
      const count = Number(entry?.count || 0);
      const isActive = value === this.type;
      return {
        ...entry,
        value,
        label: entry?.label || value,
        isActive,
        isDisabled: value !== "all" && count === 0 && !isActive,
        countLabel: formatNumber(count),
        href: urlFor({ status: this.status, type: value, limit: this.limit }),
      };
    });
  }

  get statusLinks() {
    const allCount = countFrom(this.summary?.by_status, "status", "all");
    const options = [
      { value: "all", label: "All statuses", count: allCount },
      { value: "active", label: "Active", count: countFrom(this.summary?.by_status, "status", "active") },
      { value: "failed", label: "Failed", count: countFrom(this.summary?.by_status, "status", "failed") },
      { value: "completed", label: "Completed", count: countFrom(this.summary?.by_status, "status", "completed") },
    ];

    return options.map((option) => ({
      ...option,
      isActive: option.value === this.status,
      isDisabled: option.value !== "all" && option.count === 0 && option.value !== this.status,
      href: urlFor({ status: option.value, type: this.type, limit: this.limit }),
    }));
  }

  get typeLinks() {
    const options = [
      { value: "all", label: "All job types", count: this.summary?.visible_count || 0 },
      { value: "processing", label: "Media processing", count: countFrom(this.summary?.by_type, "type", "processing") },
      { value: "migration", label: "Migration", count: countFrom(this.summary?.by_type, "type", "migration") },
      { value: "aes", label: "AES / HLS", count: countFrom(this.summary?.by_type, "type", "aes") },
      { value: "forensics", label: "Forensics", count: countFrom(this.summary?.by_type, "type", "forensics") },
      { value: "test_download", label: "Test downloads", count: countFrom(this.summary?.by_type, "type", "test_download") },
    ];

    return options.map((option) => ({
      ...option,
      isActive: option.value === this.type,
      isDisabled: option.value !== "all" && option.count === 0 && option.value !== this.type,
      href: urlFor({ status: this.status, type: option.value, limit: this.limit }),
    }));
  }

  get limitLinks() {
    return ["25", "50", "100"].map((value) => ({
      value,
      label: value,
      isActive: value === String(this.limit),
      href: urlFor({ status: this.status, type: this.type, limit: value }),
    }));
  }
}
