import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";

function formatNumber(value) {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) {
    return "0";
  }
  return new Intl.NumberFormat().format(number);
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
  return {
    ...row,
    statusClass: statusClass(row?.status_group),
    progressLabel: progressLabel(row?.progress),
    titleLabel: row?.title || row?.public_id || row?.operation || "Untitled job",
    itemMeta: [row?.public_id, row?.media_type, row?.username].filter(Boolean).join(" • "),
    routeUrl: row?.group === "migration" ? row?.migrations_url : row?.management_url,
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

export default class AdminPluginsMediaGalleryJobsController extends Controller {
  queryParams = ["status", "type", "limit"];

  @tracked rows = [];
  @tracked summary = {};
  @tracked status = "all";
  @tracked type = "all";
  @tracked limit = "50";
  @tracked error = null;
  @tracked generatedAtLabel = null;

  loadModel(data = {}) {
    const filters = data.filters || {};
    this.status = filters.status || this.status || "all";
    this.type = filters.type || this.type || "all";
    this.limit = String(data.limit || this.limit || "50");
    this.summary = data.summary || {};
    this.rows = (data.rows || []).map(compactRow);
    this.generatedAtLabel = data.generated_at_label || null;
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

  get refreshUrl() {
    return urlFor({ status: this.status, type: this.type, limit: this.limit });
  }

  get typeCards() {
    return (this.summary?.by_type || []).map((entry) => {
      const value = entry?.type || entry?.value || "all";
      return {
        ...entry,
        value,
        label: entry?.label || value,
        isActive: value === this.type,
        countLabel: formatNumber(entry?.count || 0),
        href: urlFor({ status: this.status, type: value, limit: this.limit }),
      };
    });
  }

  get statusLinks() {
    return [
      { value: "all", label: "All statuses" },
      { value: "active", label: "Active" },
      { value: "failed", label: "Failed" },
      { value: "completed", label: "Completed" },
    ].map((option) => ({
      ...option,
      isActive: option.value === this.status,
      href: urlFor({ status: option.value, type: this.type, limit: this.limit }),
    }));
  }

  get typeLinks() {
    return [
      { value: "all", label: "All job types" },
      { value: "processing", label: "Processing" },
      { value: "migration", label: "Migration" },
      { value: "aes", label: "AES / HLS" },
      { value: "forensics", label: "Forensics" },
      { value: "test_download", label: "Test downloads" },
    ].map((option) => ({
      ...option,
      isActive: option.value === this.type,
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
