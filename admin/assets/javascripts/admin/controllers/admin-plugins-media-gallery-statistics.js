import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

const PERIOD_DEFAULT_LIMITS = {
  day: "30",
  week: "12",
  month: "12",
  year: "5",
};

function coerceArray(value) {
  return Array.isArray(value) ? value : [];
}

function numberValue(value) {
  const number = Number(value || 0);
  return Number.isFinite(number) ? number : 0;
}

function formatNumber(value) {
  return new Intl.NumberFormat().format(numberValue(value));
}

function formatPercent(value) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }

  const number = Number(value);
  return Number.isFinite(number) ? `${number.toFixed(number % 1 === 0 ? 0 : 1)}%` : "—";
}

function formatBytes(value) {
  const bytes = numberValue(value);
  if (bytes <= 0) {
    return "—";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = bytes;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size = size / 1024;
    unitIndex += 1;
  }

  const decimals = unitIndex === 0 || size >= 10 ? 0 : 1;
  return `${size.toFixed(decimals)} ${units[unitIndex]}`;
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

function titleize(value) {
  const text = String(value || "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  return text ? text.replace(/\b\w/g, (char) => char.toUpperCase()) : "—";
}

function plainText(value, fallback = "—") {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function ratio(part, total) {
  const totalNumber = numberValue(total);
  if (totalNumber <= 0) {
    return 0;
  }

  return Math.round((numberValue(part) / totalNumber) * 100);
}

function decorateSeries(series, maxCount) {
  const max = Math.max(numberValue(maxCount), 1);
  return coerceArray(series).map((point) => {
    const count = numberValue(point?.count);
    return {
      key: plainText(point?.key, plainText(point?.label, "bucket")),
      label: plainText(point?.label),
      count,
      countLabel: formatNumber(count),
      barStyle: `width: ${Math.max(2, Math.round((count / max) * 100))}%;`,
    };
  });
}

function decorateBreakdown(row, total) {
  const count = numberValue(row?.count);
  const share = ratio(count, total);
  return {
    key: plainText(row?.name, plainText(row?.label, "unknown")),
    label: plainText(row?.label, titleize(row?.name)),
    count,
    countLabel: formatNumber(count),
    share,
    shareLabel: `${share}%`,
    barStyle: `width: ${Math.max(2, share)}%;`,
  };
}

function safeObject(value) {
  return value && typeof value === "object" ? value : {};
}

export default class AdminPluginsMediaGalleryStatisticsController extends Controller {
  @tracked period = "day";
  @tracked limit = "30";
  @tracked isLoading = false;
  @tracked error = "";
  @tracked summary = {};
  @tracked trends = {};
  @tracked breakdowns = {};
  @tracked moderation = {};
  @tracked quality = {};
  @tracked topContent = [];
  @tracked notes = [];
  @tracked generatedAt = null;
  @tracked hasLoadedOnce = false;
  @tracked showPerformanceTimings = false;
  @tracked lastTimingMs = null;
  @tracked lastTimingBreakdown = null;

  _requestSequence = 0;

  resetState() {
    this.period = "day";
    this.limit = "30";
    this.isLoading = false;
    this.error = "";
    this.summary = {};
    this.trends = {};
    this.breakdowns = {};
    this.moderation = {};
    this.quality = {};
    this.topContent = [];
    this.notes = [];
    this.generatedAt = null;
    this.hasLoadedOnce = false;
    this.showPerformanceTimings = false;
    this.lastTimingMs = null;
    this.lastTimingBreakdown = null;
  }

  async loadInitial() {
    await this.loadStatistics();
  }

  buildQuery() {
    const params = new URLSearchParams();
    params.set("period", this.period || "day");
    params.set("limit", this.limit || PERIOD_DEFAULT_LIMITS[this.period] || "30");
    return params.toString();
  }

  applyResponse(data = {}) {
    const filters = safeObject(data?.filters);
    this.period = String(filters.period || this.period || "day");
    this.limit = String(filters.limit || this.limit || PERIOD_DEFAULT_LIMITS[this.period] || "30");
    this.summary = safeObject(data?.summary);
    this.trends = safeObject(data?.trends);
    this.breakdowns = safeObject(data?.breakdowns);
    this.moderation = safeObject(data?.moderation);
    this.quality = safeObject(data?.quality);
    this.topContent = coerceArray(data?.top_content);
    this.notes = coerceArray(data?.notes);
    this.generatedAt = data?.generated_at || new Date().toISOString();
    this.error = String(data?.error || "").trim();
    this.showPerformanceTimings = !!data?.show_performance_timings;
    this.lastTimingMs = numberValue(data?.timing_ms) || null;
    this.lastTimingBreakdown = data?.timing_breakdown_ms || null;
    this.hasLoadedOnce = true;
  }

  get summaryCards() {
    const summary = this.summary || {};
    const quality = this.quality || {};
    return [
      {
        key: "items",
        label: "Total media items",
        value: formatNumber(summary.total_items),
        meta: `${formatNumber(summary.ready_items)} ready · ${formatNumber(summary.failed_items)} failed`,
      },
      {
        key: "playbacks",
        label: "Playback sessions",
        value: formatNumber(summary.playback_sessions),
        meta: `${formatNumber(summary.unique_viewers)} unique viewers`,
      },
      {
        key: "engagement",
        label: "Likes and comments",
        value: formatNumber(numberValue(summary.media_likes) + numberValue(summary.comment_count)),
        meta: `${formatNumber(summary.media_likes)} likes · ${formatNumber(summary.comment_count)} comments`,
      },
      {
        key: "reports",
        label: "Reports",
        value: formatNumber(summary.total_reports),
        meta: `${formatNumber(summary.open_reports)} open`,
      },
      {
        key: "success",
        label: "Processing success",
        value: formatPercent(quality.processing_success_rate_percent),
        meta: `${formatNumber(quality.queued_count)} queued · ${formatNumber(quality.processing_count)} processing`,
      },
      {
        key: "storage",
        label: "Processed storage",
        value: formatBytes(summary.storage_processed_bytes),
        meta: `${formatBytes(summary.storage_original_bytes)} original`,
      },
    ];
  }

  get uploadSeries() {
    return decorateSeries(this.trends?.uploads, this.maxTrendCount);
  }

  get playbackSeries() {
    return decorateSeries(this.trends?.playbacks, this.maxTrendCount);
  }

  get engagementSeries() {
    const likes = coerceArray(this.trends?.likes);
    const comments = coerceArray(this.trends?.comments);
    const commentLikes = coerceArray(this.trends?.comment_likes);
    const keys = new Map();

    [...likes, ...comments, ...commentLikes].forEach((point) => {
      const key = String(point?.key || point?.label || "");
      if (!key) {
        return;
      }
      if (!keys.has(key)) {
        keys.set(key, { key, label: plainText(point?.label, key), likes: 0, comments: 0, commentLikes: 0 });
      }
    });

    likes.forEach((point) => {
      const row = keys.get(String(point?.key || point?.label || ""));
      if (row) {
        row.likes = numberValue(point?.count);
      }
    });
    comments.forEach((point) => {
      const row = keys.get(String(point?.key || point?.label || ""));
      if (row) {
        row.comments = numberValue(point?.count);
      }
    });
    commentLikes.forEach((point) => {
      const row = keys.get(String(point?.key || point?.label || ""));
      if (row) {
        row.commentLikes = numberValue(point?.count);
      }
    });

    const rows = Array.from(keys.values()).map((row) => {
      const total = row.likes + row.comments + row.commentLikes;
      return { ...row, total };
    });
    const max = Math.max(...rows.map((row) => row.total), 1);

    return rows.map((row) => ({
      ...row,
      totalLabel: formatNumber(row.total),
      likesLabel: formatNumber(row.likes),
      commentsLabel: formatNumber(row.comments),
      commentLikesLabel: formatNumber(row.commentLikes),
      barStyle: `width: ${Math.max(2, Math.round((row.total / max) * 100))}%;`,
    }));
  }

  get maxTrendCount() {
    const values = [
      ...coerceArray(this.trends?.uploads),
      ...coerceArray(this.trends?.playbacks),
      ...coerceArray(this.trends?.likes),
      ...coerceArray(this.trends?.comments),
      ...coerceArray(this.trends?.comment_likes),
    ].map((point) => numberValue(point?.count));

    return Math.max(...values, 1);
  }

  get statusBreakdown() {
    return coerceArray(this.breakdowns?.by_status).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get typeBreakdown() {
    return coerceArray(this.breakdowns?.by_type).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get storageBreakdown() {
    return coerceArray(this.breakdowns?.by_storage_backend).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get logCategoryBreakdown() {
    const total = coerceArray(this.breakdowns?.log_categories).reduce((sum, row) => sum + numberValue(row?.count), 0);
    return coerceArray(this.breakdowns?.log_categories).map((row) => decorateBreakdown(row, total));
  }

  get moderationRows() {
    const totals = safeObject(this.moderation?.totals?.combined);
    return [
      { key: "total", label: "Total", value: formatNumber(totals.total) },
      { key: "open", label: "Open", value: formatNumber(totals.open) },
      { key: "accepted", label: "Accepted", value: formatNumber(totals.accepted) },
      { key: "rejected", label: "Rejected", value: formatNumber(totals.rejected) },
      { key: "resolved", label: "Resolved", value: formatNumber(totals.resolved) },
      { key: "false-ratio", label: "Rejected ratio", value: formatPercent(this.moderation?.false_report_ratio_percent) },
    ];
  }

  get decoratedTopContent() {
    return this.topContent.map((item) => ({
      key: plainText(item?.public_id, plainText(item?.title, "item")),
      title: plainText(item?.title, "Untitled media"),
      publicId: plainText(item?.public_id, "—"),
      uploader: plainText(item?.uploader, "—"),
      typeLabel: titleize(item?.media_type),
      statusLabel: titleize(item?.status),
      viewsLabel: formatNumber(item?.views_count),
      playsLabel: formatNumber(item?.playback_sessions),
      likesLabel: formatNumber(item?.likes_count),
      commentsLabel: formatNumber(item?.comments_count),
      reportsLabel: formatNumber(item?.reports_count),
      createdLabel: formatDateTime(item?.created_at),
    }));
  }

  get generatedAtLabel() {
    return this.generatedAt ? formatDateTime(this.generatedAt) : "";
  }

  get periodLabel() {
    switch (this.period) {
      case "week":
        return "per week";
      case "month":
        return "per month";
      case "year":
        return "per year";
      default:
        return "per day";
    }
  }

  get performanceTimingLabel() {
    if (!this.showPerformanceTimings || !this.lastTimingBreakdown) {
      return "";
    }

    const keys = ["summary", "trends", "breakdowns", "top_content", "moderation", "quality"];
    const parts = keys
      .map((key) => {
        const value = Number(this.lastTimingBreakdown?.[key]);
        return Number.isFinite(value) ? `${key.replace(/_/g, " ")} ${value}ms` : null;
      })
      .filter(Boolean);

    return `server ${this.lastTimingMs || 0}ms${parts.length ? ` (${parts.join(" · ")})` : ""}`;
  }

  @action
  updatePeriod(event) {
    this.period = event?.target?.value || "day";
    this.limit = PERIOD_DEFAULT_LIMITS[this.period] || "30";
  }

  @action
  updateLimit(event) {
    this.limit = event?.target?.value || PERIOD_DEFAULT_LIMITS[this.period] || "30";
  }

  @action
  async refresh(event) {
    event?.preventDefault?.();
    await this.loadStatistics();
  }

  @action
  async loadStatistics() {
    if (this.isLoading) {
      return;
    }

    const requestSequence = ++this._requestSequence;
    this.isLoading = true;
    this.error = "";

    try {
      const queryString = this.buildQuery();
      const data = await ajax(`/admin/plugins/media-gallery/statistics.json?${queryString}`);

      if (requestSequence !== this._requestSequence) {
        return;
      }

      this.applyResponse(data);
    } catch (error) {
      if (requestSequence !== this._requestSequence) {
        return;
      }

      let message = "Unable to load statistics.";
      try {
        message =
          error?.jqXHR?.responseJSON?.error ||
          error?.jqXHR?.responseJSON?.errors?.join(" ") ||
          error?.jqXHR?.responseText ||
          error?.message ||
          message;
      } catch {
        // Ignore parse failures.
      }

      this.error = message;
      this.hasLoadedOnce = true;
    } finally {
      if (requestSequence === this._requestSequence) {
        this.isLoading = false;
      }
    }
  }
}
