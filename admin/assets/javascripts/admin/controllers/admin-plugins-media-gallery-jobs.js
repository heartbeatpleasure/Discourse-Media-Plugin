import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

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

export default class AdminPluginsMediaGalleryJobsController extends Controller {
  @tracked rows = [];
  @tracked summary = {};
  @tracked filterOptions = { statuses: [], types: [] };
  @tracked status = "all";
  @tracked type = "all";
  @tracked limit = "50";
  @tracked loading = false;
  @tracked error = null;
  @tracked message = null;
  @tracked generatedAtLabel = null;

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

  get typeCards() {
    return (this.summary?.by_type || []).map((entry) => ({
      ...entry,
      countLabel: formatNumber(entry.count || 0),
    }));
  }

  get statusOptions() {
    return [
      { value: "all", label: "All statuses" },
      { value: "active", label: "Active" },
      { value: "failed", label: "Failed" },
      { value: "completed", label: "Completed" },
    ].map((option) => ({ ...option, selected: option.value === this.status }));
  }

  get typeOptions() {
    return [
      { value: "all", label: "All job types" },
      { value: "processing", label: "Processing" },
      { value: "migration", label: "Migration" },
      { value: "aes", label: "AES / HLS" },
      { value: "forensics", label: "Forensics" },
      { value: "test_download", label: "Test downloads" },
    ].map((option) => ({ ...option, selected: option.value === this.type }));
  }

  get limitOptions() {
    return ["25", "50", "100"].map((value) => ({
      value,
      label: value,
      selected: value === this.limit,
    }));
  }

  loadInitial() {
    this.loadJobs();
  }

  async loadJobs() {
    this.loading = true;
    this.error = null;
    this.message = null;

    try {
      const data = await ajax("/admin/plugins/media-gallery/jobs.json", {
        data: {
          status: this.status,
          type: this.type,
          limit: this.limit,
        },
      });

      this.summary = data.summary || {};
      this.filterOptions = data.filter_options || { statuses: [], types: [] };
      this.rows = (data.rows || []).map(compactRow);
      this.generatedAtLabel = data.generated_at_label || null;
      this.error = data.error || null;
      this.message = data.error ? null : "Background jobs refreshed.";
    } catch (e) {
      this.error = e?.jqXHR?.responseJSON?.errors?.join(" ") || e?.message || "Unable to load background jobs.";
      this.rows = [];
    } finally {
      this.loading = false;
    }
  }

  @action
  refresh() {
    this.loadJobs();
  }

  @action
  setStatus(event) {
    this.status = event.target.value || "all";
    this.loadJobs();
  }

  @action
  setType(event) {
    this.type = event.target.value || "all";
    this.loadJobs();
  }

  @action
  setLimit(event) {
    this.limit = event.target.value || "50";
    this.loadJobs();
  }

  @action
  filterByType(type) {
    this.type = type || "all";
    this.loadJobs();
  }
}
