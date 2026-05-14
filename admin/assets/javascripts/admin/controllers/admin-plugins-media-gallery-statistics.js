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

const COMPARISON_METRICS = [
  { key: "uploads", label: "Uploads" },
  { key: "playbacks", label: "Playback sessions" },
  { key: "unique_viewers", label: "Unique viewers" },
  { key: "engagement_total", label: "Engagement" },
  { key: "comments", label: "Comments" },
  { key: "reports", label: "Reports" },
  { key: "failed_uploads", label: "Failed uploads" },
  { key: "processed_storage_added_bytes", label: "Processed storage added", type: "bytes" },
];

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

function formatSignedBytes(value) {
  const bytes = numberValue(value);
  if (bytes === 0) {
    return "0";
  }

  return `${bytes > 0 ? "+" : "−"}${formatBytes(Math.abs(bytes))}`;
}

function formatRatio(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) {
    return "—";
  }

  const decimals = number >= 10 ? 1 : 2;
  return `${number.toFixed(decimals)}×`;
}

function statusClassFor(status) {
  switch (String(status || "").toLowerCase()) {
    case "ready":
      return "mg-stats__badge is-success";
    case "failed":
      return "mg-stats__badge is-danger";
    case "processing":
    case "queued":
      return "mg-stats__badge is-warning";
    default:
      return "mg-stats__badge";
  }
}

function formatDuration(value) {
  const seconds = numberValue(value);
  if (seconds <= 0) {
    return "—";
  }

  if (seconds < 60) {
    return `${Math.round(seconds)}s`;
  }

  const minutes = seconds / 60;
  if (minutes < 60) {
    return `${minutes.toFixed(minutes >= 10 ? 0 : 1)}m`;
  }

  const hours = minutes / 60;
  if (hours < 48) {
    return `${hours.toFixed(hours >= 10 ? 0 : 1)}h`;
  }

  const days = hours / 24;
  return `${days.toFixed(days >= 10 ? 0 : 1)}d`;
}

function formatMetric(value, type = "number") {
  if (type === "bytes") {
    return formatBytes(value);
  }

  if (type === "percent") {
    return formatPercent(value);
  }

  return formatNumber(value);
}

function formatSignedNumber(value) {
  const number = numberValue(value);
  if (number === 0) {
    return "0";
  }

  return `${number > 0 ? "+" : "−"}${formatNumber(Math.abs(number))}`;
}

function formatSignedPercent(value) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }

  const number = Number(value);
  if (!Number.isFinite(number)) {
    return "—";
  }

  const decimals = Number.isInteger(number) ? 0 : 1;
  return `${number > 0 ? "+" : number < 0 ? "−" : ""}${Math.abs(number).toFixed(decimals)}%`;
}

function formatDeltaValue(delta = {}, type = "number") {
  const previous = numberValue(delta?.previous);
  const current = numberValue(delta?.current);
  const difference = Number(delta?.difference || 0);

  if (previous === 0 && current > 0) {
    return type === "bytes"
      ? `new (${difference > 0 ? "+" : ""}${formatBytes(Math.abs(difference))})`
      : `new (${formatSignedNumber(difference)})`;
  }

  if (previous === 0 && current === 0) {
    return "0";
  }

  if (type === "bytes") {
    const sign = difference > 0 ? "+" : difference < 0 ? "−" : "";
    return difference === 0 ? "0" : `${sign}${formatBytes(Math.abs(difference))}`;
  }

  return formatSignedNumber(difference);
}

function formatDeltaPercent(delta = {}) {
  const previous = numberValue(delta?.previous);
  const current = numberValue(delta?.current);

  if (previous === 0 && current > 0) {
    return "new";
  }

  if (previous === 0 && current === 0) {
    return "0%";
  }

  return formatSignedPercent(delta?.percent_change);
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
  @tracked periodSummary = {};
  @tracked contributors = {};
  @tracked watchlist = {};
  @tracked contentProfile = {};
  @tracked engagementQuality = {};
  @tracked deliveryIntegrity = {};
  @tracked contentCuration = {};
  @tracked processingPerformance = {};
  @tracked metadataCompleteness = {};
  @tracked storageEfficiency = {};
  @tracked insights = [];
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
    this.periodSummary = {};
    this.contributors = {};
    this.watchlist = {};
    this.contentProfile = {};
    this.engagementQuality = {};
    this.deliveryIntegrity = {};
    this.contentCuration = {};
    this.processingPerformance = {};
    this.metadataCompleteness = {};
    this.storageEfficiency = {};
    this.insights = [];
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
    this.periodSummary = safeObject(data?.period_summary);
    this.contributors = safeObject(data?.contributors);
    this.watchlist = safeObject(data?.watchlist);
    this.contentProfile = safeObject(data?.content_profile);
    this.engagementQuality = safeObject(data?.engagement_quality);
    this.deliveryIntegrity = safeObject(data?.delivery_integrity);
    this.contentCuration = safeObject(data?.content_curation);
    this.processingPerformance = safeObject(data?.processing_performance);
    this.metadataCompleteness = safeObject(data?.metadata_completeness);
    this.storageEfficiency = safeObject(data?.storage_efficiency);
    this.insights = coerceArray(data?.insights);
    this.topContent = coerceArray(data?.top_content);
    this.notes = coerceArray(data?.notes);
    this.generatedAt = data?.generated_at || new Date().toISOString();
    this.error = String(data?.error || "").trim();
    this.showPerformanceTimings = !!data?.show_performance_timings;
    this.lastTimingMs = numberValue(data?.timing_ms) || null;
    this.lastTimingBreakdown = data?.timing_breakdown_ms || null;
    this.hasLoadedOnce = true;
  }

  get currentRangeLabel() {
    return `Last ${formatNumber(this.limit)} full ${this.periodUnitLabel}`;
  }

  get previousRangeLabel() {
    return `Previous ${formatNumber(this.limit)} full ${this.periodUnitLabel}`;
  }

  get currentRangeDateLabel() {
    return plainText(this.periodSummary?.labels?.current, "—");
  }

  get previousRangeDateLabel() {
    return plainText(this.periodSummary?.labels?.previous, "—");
  }

  get comparisonRows() {
    const current = safeObject(this.periodSummary?.current);
    const previous = safeObject(this.periodSummary?.previous);
    const delta = safeObject(this.periodSummary?.delta);

    return COMPARISON_METRICS.map((metric) => {
      const rowDelta = safeObject(delta?.[metric.key]);
      return {
        key: metric.key,
        label: metric.label,
        currentLabel: formatMetric(current?.[metric.key], metric.type),
        previousLabel: formatMetric(previous?.[metric.key], metric.type),
        changeLabel: formatDeltaValue(rowDelta, metric.type),
        percentLabel: formatDeltaPercent(rowDelta),
        changeClass: `mg-stats__delta is-${plainText(rowDelta?.direction, "flat")}`,
      };
    });
  }

  get decoratedInsights() {
    return this.insights.map((insight, index) => {
      const severity = plainText(insight?.severity, "info").toLowerCase();
      return {
        key: `${severity}-${index}`,
        severity,
        title: plainText(insight?.title, "Insight"),
        message: plainText(insight?.message, "—"),
        action: plainText(insight?.action, "—"),
        className: `mg-stats__insight is-${severity}`,
      };
    });
  }

  get summaryCards() {
    const summary = this.summary || {};
    const quality = this.quality || {};
    const reportTotals = safeObject(this.moderation?.totals?.combined);
    return [
      {
        key: "items",
        label: "Total media",
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
        label: "Open reports",
        value: formatNumber(summary.open_reports),
        meta: `${formatNumber(reportTotals.total ?? summary.total_reports)} total · ${formatNumber(reportTotals.rejected)} rejected`,
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

  get durationBuckets() {
    return coerceArray(this.contentProfile?.duration_buckets).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get processedSizeBuckets() {
    return coerceArray(this.contentProfile?.processed_size_buckets).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get orientationBuckets() {
    const rows = coerceArray(this.contentProfile?.resolution_buckets).filter((row) =>
      ["unknown", "vertical", "square", "landscape"].includes(String(row?.name || ""))
    );
    return rows.map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get resolutionBuckets() {
    const rows = coerceArray(this.contentProfile?.resolution_buckets).filter((row) =>
      ["unknown", "hd_or_larger", "full_hd_or_larger"].includes(String(row?.name || ""))
    );
    return rows.map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get tagUsageRows() {
    const total = coerceArray(this.contentProfile?.tag_usage).reduce((sum, row) => sum + numberValue(row?.count), 0);
    return coerceArray(this.contentProfile?.tag_usage).map((row) => decorateBreakdown(row, total));
  }

  get visibilityRows() {
    return coerceArray(this.contentProfile?.visibility).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get hlsCatalogRows() {
    return coerceArray(this.contentProfile?.hls_catalog).map((row) => decorateBreakdown(row, this.summary?.total_items));
  }

  get processingPerformanceCards() {
    const completed = safeObject(this.processingPerformance?.completed_latency);
    const queue = safeObject(this.processingPerformance?.queue_age);
    return [
      { key: "completed-count", label: "Completed items", value: formatNumber(completed.count), meta: "With stored processing run timing in selected range" },
      { key: "completed-median", label: "Median processing", value: formatDuration(completed.median_seconds), meta: `Average ${formatDuration(completed.average_seconds)} · p90 ${formatDuration(completed.p90_seconds)}` },
      { key: "completed-max", label: "Slowest completed", value: formatDuration(completed.max_seconds), meta: "Stored processing run duration" },
      { key: "queue-count", label: "Active queue", value: formatNumber(queue.count), meta: `Median age ${formatDuration(queue.median_seconds)} · p90 ${formatDuration(queue.p90_seconds)}` },
    ];
  }

  get processingLatencyBuckets() {
    const total = coerceArray(this.processingPerformance?.latency_buckets).reduce((sum, row) => sum + numberValue(row?.count), 0);
    return coerceArray(this.processingPerformance?.latency_buckets).map((row) => decorateBreakdown(row, total));
  }

  get metadataCoverageRows() {
    return coerceArray(this.metadataCompleteness?.coverage).map((row) => {
      const percent = row?.percent === null || row?.percent === undefined ? ratio(row?.count, row?.total) : Number(row.percent);
      const width = Number.isFinite(percent) ? Math.max(2, Math.round(percent)) : 2;
      return {
        key: plainText(row?.name, plainText(row?.label, "coverage")),
        label: plainText(row?.label, titleize(row?.name)),
        countLabel: `${formatNumber(row?.count)} / ${formatNumber(row?.total)}`,
        shareLabel: Number.isFinite(percent) ? `${percent.toFixed(percent % 1 === 0 ? 0 : 1)}%` : "—",
        barStyle: `width: ${width}%;`,
      };
    });
  }

  decorateStorageEfficiency(row, fallback = "storage") {
    return {
      key: plainText(row?.name, fallback),
      label: plainText(row?.label, titleize(row?.name)),
      countLabel: formatNumber(row?.count),
      originalLabel: formatBytes(row?.original_bytes),
      processedLabel: formatBytes(row?.processed_bytes),
      changeLabel: formatSignedBytes(row?.delta_bytes ?? -numberValue(row?.saved_bytes)),
      ratioLabel: formatRatio(row?.processed_ratio),
    };
  }

  get storageEfficiencyByType() {
    return coerceArray(this.storageEfficiency?.by_type).map((row) => this.decorateStorageEfficiency(row, "type"));
  }

  get storageEfficiencyByBackend() {
    return coerceArray(this.storageEfficiency?.by_backend).map((row) => this.decorateStorageEfficiency(row, "backend"));
  }

  get engagementRateCards() {
    const rates = safeObject(this.engagementQuality?.rates);
    return [
      { key: "views", label: "Views per item", value: formatMetric(rates.views_per_item), meta: "All-time total views divided by all media items" },
      { key: "plays", label: "Plays per ready item", value: formatMetric(rates.playbacks_per_ready_item), meta: "Playback sessions divided by ready media" },
      { key: "likes", label: "Likes per 100 views", value: formatMetric(rates.likes_per_100_views), meta: "Useful signal for content appreciation" },
      { key: "comments", label: "Comments per 100 views", value: formatMetric(rates.comments_per_100_views), meta: "Conversation depth relative to views" },
      { key: "reports", label: "Reports per 1k views", value: formatMetric(rates.reports_per_1000_views), meta: "Moderation pressure relative to views" },
      { key: "engagement", label: "Engagement per ready item", value: formatMetric(rates.engagement_per_ready_item), meta: "Likes plus comments divided by ready media" },
    ];
  }

  get deliveryReceiptCards() {
    const receipt = safeObject(this.deliveryIntegrity?.receipt_summary);
    return [
      { key: "total", label: "Playback sessions", value: formatNumber(receipt.total_playbacks), meta: "Selected range" },
      { key: "signature", label: "Signatures", value: formatPercent(receipt.signature_coverage_percent), meta: `${formatNumber(receipt.with_delivery_signature)} with delivery signature` },
      { key: "manifest", label: "Manifest SHA", value: formatPercent(receipt.manifest_coverage_percent), meta: `${formatNumber(receipt.with_manifest_sha)} with manifest SHA` },
      { key: "sequence", label: "Variants", value: formatPercent(receipt.sequence_coverage_percent), meta: `${formatNumber(receipt.with_variant_sequence)} with stored variant data` },
      { key: "sequence-length", label: "Avg. HLS length", value: receipt.average_variant_sequence_length ?? "—", meta: "Average stored variant sequence length" },
    ];
  }

  get hlsVariantRows() {
    const total = coerceArray(this.deliveryIntegrity?.hls_variants).reduce((sum, row) => sum + numberValue(row?.count), 0);
    return coerceArray(this.deliveryIntegrity?.hls_variants).map((row) => decorateBreakdown(row, total));
  }

  get topUploaders() {
    return coerceArray(this.contributors?.top_uploaders).map((row) => ({
      key: plainText(row?.user_id, plainText(row?.username, "user")),
      username: plainText(row?.username, "—"),
      uploadsLabel: formatNumber(row?.uploads),
      readyLabel: formatNumber(row?.ready),
      failedLabel: formatNumber(row?.failed),
      viewsLabel: formatNumber(row?.views),
      storageLabel: formatBytes(row?.processed_storage_bytes),
      latestLabel: formatDateTime(row?.latest_upload_at),
    }));
  }

  get topViewers() {
    return coerceArray(this.contributors?.top_viewers).map((row) => ({
      key: plainText(row?.user_id, plainText(row?.username, "user")),
      username: plainText(row?.username, "—"),
      playbacksLabel: formatNumber(row?.playbacks),
      uniqueMediaLabel: formatNumber(row?.unique_media),
      latestLabel: formatDateTime(row?.latest_playback_at),
    }));
  }

  get topCommenters() {
    return coerceArray(this.contributors?.top_commenters).map((row) => ({
      key: plainText(row?.user_id, plainText(row?.username, "user")),
      username: plainText(row?.username, "—"),
      commentsLabel: formatNumber(row?.comments),
      uniqueMediaLabel: formatNumber(row?.unique_media),
      latestLabel: formatDateTime(row?.latest_comment_at),
    }));
  }

  get topLikers() {
    return coerceArray(this.contributors?.top_likers).map((row) => ({
      key: plainText(row?.user_id, plainText(row?.username, "user")),
      username: plainText(row?.username, "—"),
      likesLabel: formatNumber(row?.likes),
      uniqueMediaLabel: formatNumber(row?.unique_media),
      latestLabel: formatDateTime(row?.latest_like_at),
    }));
  }

  get recentFailures() {
    return coerceArray(this.watchlist?.recent_failures).map((row) => ({
      key: plainText(row?.public_id, plainText(row?.title, "failed")),
      title: plainText(row?.title, "Untitled media"),
      publicId: plainText(row?.public_id, "—"),
      uploader: plainText(row?.uploader, "—"),
      typeLabel: titleize(row?.media_type),
      errorMessage: plainText(row?.error_message, "No error message stored."),
      updatedLabel: formatDateTime(row?.updated_at),
    }));
  }

  get processingQueue() {
    return coerceArray(this.watchlist?.processing_queue).map((row) => ({
      key: plainText(row?.public_id, plainText(row?.title, "processing")),
      title: plainText(row?.title, "Untitled media"),
      publicId: plainText(row?.public_id, "—"),
      uploader: plainText(row?.uploader, "—"),
      typeLabel: titleize(row?.media_type),
      statusLabel: titleize(row?.status),
      updatedLabel: formatDateTime(row?.updated_at),
    }));
  }

  get mostReportedMedia() {
    return coerceArray(this.watchlist?.most_reported_media).map((row) => ({
      key: plainText(row?.public_id, plainText(row?.title, "reported")),
      title: plainText(row?.title, "Untitled media"),
      publicId: plainText(row?.public_id, "—"),
      uploader: plainText(row?.uploader, "—"),
      typeLabel: titleize(row?.media_type),
      statusLabel: titleize(row?.status),
      totalReportsLabel: formatNumber(row?.total_reports),
      openReportsLabel: formatNumber(row?.open_reports),
      mediaReportsLabel: formatNumber(row?.media_reports),
    }));
  }

  get mostReportedCommentMedia() {
    return coerceArray(this.watchlist?.most_reported_comments).map((row) => ({
      key: plainText(row?.public_id, plainText(row?.title, "comment-reported")),
      title: plainText(row?.title, "Untitled media"),
      publicId: plainText(row?.public_id, "—"),
      uploader: plainText(row?.uploader, "—"),
      typeLabel: titleize(row?.media_type),
      statusLabel: titleize(row?.status),
      totalReportsLabel: formatNumber(row?.total_reports),
      openReportsLabel: formatNumber(row?.open_reports),
      commentReportsLabel: formatNumber(row?.comment_reports),
    }));
  }

  decorateContentItem(item, fallback = "item") {
    return {
      key: plainText(item?.public_id, plainText(item?.title, fallback)),
      title: plainText(item?.title, "Untitled media"),
      publicId: plainText(item?.public_id, "—"),
      uploader: plainText(item?.uploader, "—"),
      typeLabel: titleize(item?.media_type),
      statusLabel: titleize(item?.status),
      viewsLabel: formatNumber(item?.views_count),
      playsLabel: formatNumber(item?.playbacks),
      likesLabel: formatNumber(item?.likes ?? item?.likes_count),
      commentsLabel: formatNumber(item?.comments ?? item?.comments_count),
      scoreLabel: formatNumber(item?.score),
      createdLabel: formatDateTime(item?.created_at),
    };
  }

  get risingContent() {
    return coerceArray(this.engagementQuality?.rising_content).map((item) => this.decorateContentItem(item, "rising"));
  }

  get quietReadyMedia() {
    return coerceArray(this.contentCuration?.quiet_ready_media).map((item) => this.decorateContentItem(item, "quiet"));
  }

  get staleReadyMedia() {
    return coerceArray(this.contentCuration?.stale_ready_media).map((item) => this.decorateContentItem(item, "stale"));
  }

  get recentSlowProcessing() {
    return coerceArray(this.processingPerformance?.recent_slow_processing).map((item) => ({
      ...this.decorateContentItem(item, "slow-processing"),
      processingLabel: formatDuration(item?.processing_seconds),
      processedSizeLabel: formatBytes(item?.filesize_processed_bytes),
      completedLabel: formatDateTime(item?.completed_at),
    }));
  }

  get queueAgeWatchlist() {
    return coerceArray(this.processingPerformance?.queue_age_watchlist).map((item) => ({
      ...this.decorateContentItem(item, "queue-age"),
      ageLabel: formatDuration(item?.age_seconds),
      updatedLabel: formatDateTime(item?.updated_at),
    }));
  }

  get incompleteMedia() {
    return coerceArray(this.metadataCompleteness?.incomplete_media).map((item) => ({
      ...this.decorateContentItem(item, "incomplete"),
      statusLabel: titleize(item?.status),
      statusClass: statusClassFor(item?.status),
      issueCountLabel: formatNumber(item?.issue_count),
      issuesLabel: coerceArray(item?.issues).join(", ") || "—",
      updatedLabel: formatDateTime(item?.updated_at),
    }));
  }

  get largestProcessedMedia() {
    return coerceArray(this.storageEfficiency?.largest_processed_media).map((item) => ({
      ...this.decorateContentItem(item, "large-processed"),
      originalLabel: formatBytes(item?.original_bytes),
      processedLabel: formatBytes(item?.processed_bytes),
      changeLabel: formatSignedBytes(item?.delta_bytes),
      ratioLabel: formatRatio(item?.processed_ratio),
      storageLabel: plainText(item?.storage_label, "—"),
    }));
  }

  get missingDeliveryReceipts() {
    return coerceArray(this.deliveryIntegrity?.missing_delivery_receipts).map((row) => {
      const missing = [];
      if (row?.missing_signature) {
        missing.push("signature");
      }
      if (row?.missing_manifest) {
        missing.push("manifest");
      }
      if (row?.missing_sequence) {
        missing.push("sequence");
      }

      return {
        key: plainText(row?.id, plainText(row?.public_id, "receipt")),
        title: plainText(row?.title, "Unknown media"),
        publicId: plainText(row?.public_id, "—"),
        user: plainText(row?.user, "—"),
        variant: plainText(row?.hls_variant, "—"),
        playedLabel: formatDateTime(row?.played_at),
        missingLabel: missing.length ? missing.join(", ") : "—",
      };
    });
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

  get periodUnitLabel() {
    switch (this.period) {
      case "week":
        return "weeks";
      case "month":
        return "months";
      case "year":
        return "years";
      default:
        return "days";
    }
  }

  get performanceTimingLabel() {
    if (!this.showPerformanceTimings || !this.lastTimingBreakdown) {
      return "";
    }

    const keys = [
      "summary",
      "trends",
      "breakdowns",
      "top_content",
      "moderation",
      "quality",
      "period_summary",
      "contributors",
      "watchlist",
      "content_profile",
      "engagement_quality",
      "delivery_integrity",
      "content_curation",
      "processing_performance",
      "metadata_completeness",
      "storage_efficiency",
      "insights",
    ];
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
