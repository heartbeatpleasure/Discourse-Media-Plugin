import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { i18n } from "discourse-i18n";

function formatDateTime(value) {
  if (!value) {
    return "";
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

function hlsReady(item) {
  return !!(
    item?.hls_ready ||
    item?.has_hls ||
    item?.playback_hls_ready ||
    item?.hls_playlist_url ||
    item?.playlist_url
  );
}

function isOverlayLikeQuery(value) {
  const query = String(value || "").trim();
  return /^[A-Za-z0-9]{4,12}$/.test(query);
}

function formatRatio(value, digits = 4) {
  const num = typeof value === "number" ? value : parseFloat(value);
  if (!Number.isFinite(num)) {
    return "—";
  }
  return num.toFixed(digits).replace(/\.?0+$/, "");
}

function formatCompactStat(value) {
  const num = typeof value === "number" ? value : parseFloat(value);
  if (!Number.isFinite(num)) {
    return "—";
  }

  const abs = Math.abs(num);
  if (abs === 0) {
    return "0";
  }
  if (abs >= 100) {
    return num.toFixed(0);
  }
  if (abs >= 10) {
    return num.toFixed(2).replace(/\.?0+$/, "");
  }
  if (abs >= 1) {
    return num.toFixed(4).replace(/\.?0+$/, "");
  }
  if (abs >= 0.001) {
    return num.toFixed(6).replace(/\.?0+$/, "");
  }
  return num.toExponential(2);
}

function formatProbability(value) {
  const num = typeof value === "number" ? value : parseFloat(value);
  if (!Number.isFinite(num)) {
    return "—";
  }
  if (num <= 0) {
    return "<1e-308";
  }
  if (num >= 0.01) {
    return num.toFixed(4).replace(/\.?0+$/, "");
  }
  if (num >= 0.0001) {
    return num.toFixed(6).replace(/\.?0+$/, "");
  }
  return num.toExponential(2);
}

function candidateUserLabel(candidate) {
  if (!candidate) {
    return "—";
  }
  if (candidate?.username) {
    return `${candidate.username} (#${candidate.user_id})`;
  }
  if (candidate?.user_id) {
    return `#${candidate.user_id}`;
  }
  return "—";
}


const METRIC_HELP = {
  decision: "Final decision for this forensic run. This still follows the current policy thresholds and is not yet driven directly by the new statistical values.",
  confidence: "Human-readable confidence bucket derived from the current decision policy and supporting match signals.",
  samples: "Total samples considered during this forensic run before unusable samples were filtered out.",
  usable_samples: "Samples that remained usable after extraction, sync, filtering and other guardrails.",
  top_match: "The winning candidate's final match ratio. In the current engine this prefers the weighted match ratio when available, otherwise the raw match ratio.",
  delta_vs_second: "Difference between the best candidate and the runner-up. Larger separation generally means a clearer winner.",
  layout: "Detected or forced watermark layout used during forensic extraction. Layout affects extraction geometry but not the final candidate table structure.",
  winner: "Winning user / account for the current forensic run.",
  fingerprint: "Fingerprint identifier associated with the winning candidate.",
  mis_comp: "Mismatches over compared positions for this candidate. Lower is better; 0 / N means perfect agreement on all compared positions.",
  best_offset: "Best segment offset that aligned this candidate with the observed sample during matching.",
  z_score: "Supportive significance based on compared vs mismatches under a random 50/50 agreement baseline. Higher is stronger: around 0 is weak/no separation, above 3 is strong, above 5 is very strong. There is no hard maximum. If this is blank, the candidate usually had no compared positions to score.",
  p_value: "One-sided binomial tail probability under a random 50/50 agreement baseline. Lower is stronger: below 0.05 is notable, below 0.01 is strong, below 0.001 is very strong. Very small values can appear in scientific notation, for example 3.55e-15. Minimum approaches 0. If this is blank, the candidate usually had no compared positions to score.",
  efp_pool: "Expected false positives in the current candidate pool, calculated as p-value × current pool size. Lower is better: below 1 is good, below 0.1 is strong, and values shown in scientific notation such as 7.11e-15 are extremely small (therefore extremely strong). Values above 1 mean chance matches become more plausible in this pool. If blank, there was not enough compared data to calculate it.",
  efp_2000: "Expected false positives normalized to a reference pool of 2000 candidates. Lower is better and easier to compare across runs: below 1 is good, below 0.1 is strong, and scientific-notation values such as 7.11e-12 are extremely strong. If blank, there was not enough compared data to calculate it.",
  shortlist_gap: "Difference between the winning shortlist evidence score and the runner-up shortlist evidence score. Shown only when a runner-up exists.",
  evidence_score: "Primary evidence score produced by the current engine for this candidate. There is no fixed universal scale; compare it against other candidates in the same run. Higher is better. A large positive lead over the runner-up is strong; negative values are poor.",
  rank_score: "Ranking score used to order shortlist candidates. There is no fixed universal scale; compare it against other candidates in the same run. Higher is better. In very small pools it can equal the evidence score.",
  weighted_mis_comp: "Weighted mismatches over weighted compared samples. Lower is better; 0 / N means perfect weighted agreement on all weighted comparisons.",
  chunk_llr: "Chunk-level log-likelihood style score accumulated across stable chunks. There is no fixed universal scale; compare it against other candidates in the same run. Higher is better.",
  why: "Compact explanation of why this candidate ranked where it did. These are engine signals, not end-user facing policy text. The cards below break this summary into separate metrics.",
  llr: "Chunk-level log-likelihood style contribution reported by the engine for this candidate. Higher is better, but use it comparatively within the same run rather than as an absolute scale.",
  median_chunk: "Median per-chunk support value observed for this candidate. Higher generally means more consistent chunk-level support across the sample.",
  stable_chunks: "Stable chunks compared to total chunks. More stable chunks usually means a more trustworthy comparison; a value like 24/24 is excellent.",
  weighted_match: "Weighted match ratio reported by the engine when weighted comparison is available. It usually ranges from 0 to 1, and higher is better.",
  local_offsets: "Local offset selections chosen during shortlist verification across chunks. Matching or tightly clustered offsets usually indicate a more stable local alignment.",
  local_stable: "Chunks whose local offset stayed stable versus total locally checked chunks. Higher is better; values near the full total mean the candidate stayed locally aligned across the sample.",
  anchor_dist: "Distance between the candidate's best global offset and the preferred anchor offset. Lower is better; 0 means it stayed exactly on the anchor.",
  pairwise_margin: "Total pairwise comparison margin collected across chunk rows. Higher positive values mean this candidate won those pairwise chunk comparisons more decisively.",
  pairwise_wins: "Pairwise chunk rows won versus rows compared. Higher is better; a value like 4/7 means this candidate won 4 of 7 pairwise chunk decisions.",
  pairwise_losses: "Pairwise chunk rows lost. Lower is better; losses indicate chunk rows where another explanation looked stronger.",
  disc_margin: "Discriminative margin accumulated when directly separating this candidate from nearby shortlist alternatives. Higher positive values are better; 0 or negative values mean weak separation.",
  disc_diff: "Number of positions that differed in the discriminative comparison stage. This is context only: more differing positions can give the discriminator more room to separate candidates.",
  disc_wins: "Discriminative comparisons won versus total. Higher is better; it shows how often this candidate beat the competing candidate in the direct discriminator.",
  disc_losses: "Discriminative comparisons lost. Lower is better; losses mean the competing candidate won more direct discriminator checks.",
};

const RATIONALE_LABELS = {
  llr: "LLR",
  median_chunk: "Median chunk",
  stable_chunks: "Stable chunks",
  weighted_match: "Weighted match",
  local_offsets: "Local offsets",
  local_stable: "Local stable",
  anchor_dist: "Anchor distance",
  pairwise_margin: "Pairwise margin",
  pairwise_wins: "Pairwise wins",
  pairwise_losses: "Pairwise losses",
  disc_margin: "Disc margin",
  disc_diff: "Disc diff",
  disc_wins: "Disc wins",
  disc_losses: "Disc losses",
  score: "Evidence score",
  rank: "Rank score",
};

const RATIONALE_HELP_KEYS = {
  llr: "llr",
  median_chunk: "median_chunk",
  stable_chunks: "stable_chunks",
  weighted_match: "weighted_match",
  local_offsets: "local_offsets",
  local_stable: "local_stable",
  anchor_dist: "anchor_dist",
  pairwise_margin: "pairwise_margin",
  pairwise_wins: "pairwise_wins",
  pairwise_losses: "pairwise_losses",
  disc_margin: "disc_margin",
  disc_diff: "disc_diff",
  disc_wins: "disc_wins",
  disc_losses: "disc_losses",
  score: "evidence_score",
  rank: "rank_score",
};

function metricHelp(key) {
  return METRIC_HELP[key] || "";
}

function fallbackRationaleMetricHelp(key) {
  const label = titleize(key);
  return `${label} is an engine-specific rationale signal emitted by shortlist verification. Use it comparatively within the same run rather than as an absolute universal scale.`;
}

function parseWhyMetrics(value) {
  return String(value || "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const idx = part.indexOf("=");
      if (idx === -1) {
        return null;
      }
      const key = part.slice(0, idx).trim();
      const rawValue = part.slice(idx + 1).trim();
      return key && rawValue ? { key, rawValue } : null;
    })
    .filter(Boolean);
}

export default class AdminPluginsMediaGalleryForensicsIdentifyController extends Controller {
  @tracked publicId = "";
  @tracked file = null;
  @tracked sourceUrl = "";
  @tracked maxSamples = 60;
  @tracked maxOffsetSegments = 30;
  @tracked layout = "";
  @tracked autoExtend = true;
  @tracked isRunning = false;

  // public_id finder
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked isSearching = false;
  @tracked searchError = "";
  @tracked searchTypeFilter = "all";
  @tracked searchStatusFilter = "all";
  @tracked searchBackendFilter = "all";
  @tracked searchHlsFilter = "all";
  @tracked searchLimit = 20;
  @tracked searchSort = "newest";
  _searchTimer = null;

  // Raw + parsed result
  @tracked result = null;
  @tracked resultJson = "";
  @tracked error = "";
  @tracked statusMessage = "";
  @tracked activeTaskId = null;

  // Overlay/session code lookup (fed from the main search bar)
  @tracked lookupMatches = [];
  @tracked lookupBusy = false;
  @tracked lookupError = "";
  @tracked lookupCode = "";

  get decoratedSearchResults() {
    const items = Array.isArray(this.searchResults) ? [...this.searchResults] : [];

    const filtered = items.filter((item) => {
      if (this.searchTypeFilter !== "all" && item?.media_type !== this.searchTypeFilter) {
        return false;
      }

      if (this.searchHlsFilter === "yes" && !hlsReady(item)) {
        return false;
      }

      if (this.searchHlsFilter === "no" && hlsReady(item)) {
        return false;
      }

      return true;
    });

    filtered.sort((left, right) => {
      const leftDate = new Date(left?.created_at || 0).getTime() || 0;
      const rightDate = new Date(right?.created_at || 0).getTime() || 0;

      switch (this.searchSort) {
        case "oldest":
          return leftDate - rightDate;
        case "title_asc":
          return String(left?.title || left?.public_id || "").localeCompare(String(right?.title || right?.public_id || ""));
        case "title_desc":
          return String(right?.title || right?.public_id || "").localeCompare(String(left?.title || left?.public_id || ""));
        case "newest":
        default:
          return rightDate - leftDate;
      }
    });

    return filtered.map((item) => ({
      ...item,
      displayTitle: item?.title || item?.public_id || `#${item?.id || ""}`,
      displayStatus: titleize(item?.status || "unknown"),
      displayMediaType: titleize(item?.media_type || "media"),
      displayStorage:
        item?.managed_storage_profile_label ||
        item?.managed_storage_profile ||
        titleize(item?.managed_storage_backend || item?.storage_backend || "local storage"),
      displayHls: hlsReady(item) ? "HLS ready" : "No HLS",
      displayMeta: [item?.username ? `by ${item.username}` : "", formatDateTime(item?.created_at)]
        .filter(Boolean)
        .join(" • "),
      statusBadgeClass:
        item?.status === "ready"
          ? "is-success"
          : item?.status === "failed"
            ? "is-danger"
            : item?.status === "processing" || item?.status === "queued"
              ? "is-warning"
              : "",
      hlsBadgeClass: hlsReady(item) ? "is-success" : "",
    }));
  }

  get hasSearchResults() {
    return this.decoratedSearchResults.length > 0;
  }

  get searchResultsCount() {
    return this.decoratedSearchResults.length;
  }

  get decoratedOverlayMatches() {
    return Array.isArray(this.lookupMatches)
      ? this.lookupMatches.map((match) => {
          const uploader = match?.name || match?.username || "Unknown user";
          const seenAt = formatDateTime(match?.updated_at || match?.created_at);
          const mediaPublicId = match?.media_public_id || "";

          return {
            ...match,
            displayTitle: match?.media_title || mediaPublicId || "Unknown media",
            displayMeta: [`by ${uploader}`, seenAt].filter(Boolean).join(" • "),
            displayType: titleize(match?.media_type || "media"),
            displayFingerprint: match?.fingerprint_id || "—",
            displayCode: match?.overlay_code || this.lookupCode,
            displaySeenAt: seenAt || "—",
            displayUploader: uploader,
            thumbnailUrl:
              match?.thumbnail_url ||
              (mediaPublicId ? `/media/${mediaPublicId}/thumbnail?admin_preview=1` : ""),
          };
        })
      : [];
  }

  get hasOverlaySearchMatches() {
    return this.decoratedOverlayMatches.length > 0;
  }

  get hasResult() {
    return !!this.result;
  }

  get meta() {
    return this.result?.meta;
  }

  get candidates() {
    return this.result?.candidates || [];
  }

  get topCandidates() {
    const cands = this.candidates || [];
    const top = this.topMatchRatio;
    return cands.slice(0, 5).map((candidate, idx) => this._decorateCandidate(candidate, idx, top));
  }

  get poolSize() {
    return this.meta?.pool_size ?? null;
  }

  get statisticalConfidenceNote() {
    return this.meta?.statistical_confidence_note || "";
  }

  get referencePoolSize() {
    return this.meta?.reference_pool_size ?? 2000;
  }

  get hasRunnerUp() {
    return !!this.secondCandidate;
  }

  get shortlistEvidenceGapDisplay() {
    return this.showShortlistEvidenceGap ? formatCompactStat(this.shortlistEvidenceGap) : "—";
  }

  get showShortlistEvidenceGap() {
    return this.hasRunnerUp && this.shortlistEvidenceGap !== null;
  }

  get resultSummaryCards() {
    const cards = [
      { label: "Decision", value: this.decisionText || "Pending", help: metricHelp("decision") },
      { label: "Confidence", value: this.confidence, help: metricHelp("confidence") },
      { label: "Samples", value: String(this.samples), help: metricHelp("samples") },
      { label: "Usable samples", value: String(this.usableSamples), help: metricHelp("usable_samples") },
      { label: "Top match", value: this.topMatchRatioDisplay, help: metricHelp("top_match") },
      { label: "Δ vs #2", value: this.topDeltaVsSecondDisplay, help: metricHelp("delta_vs_second") },
      { label: "Layout", value: this.meta?.layout || "—", help: metricHelp("layout") },
    ];

    return cards;
  }

  get topCandidateSummaryCards() {
    if (!this.topCandidate) {
      return [];
    }

    return [
      { label: "Winner", value: this.topCandidateUserLabel, help: metricHelp("winner") },
      { label: "Fingerprint", value: this.topCandidateFingerprintLabel, help: metricHelp("fingerprint"), span2: true, code: true },
      { label: "Top match", value: this.topMatchRatioDisplay, help: metricHelp("top_match") },
      { label: "Δ vs #2", value: this.topDeltaVsSecondDisplay, help: metricHelp("delta_vs_second") },
      { label: "Mis / Comp", value: this.topCandidateMisComp, help: metricHelp("mis_comp") },
      { label: "Best offset", value: this.topCandidateBestOffset, help: metricHelp("best_offset") },
      { label: "Z-score", value: this.topSignalZDisplay, help: metricHelp("z_score") },
      { label: "p-value", value: this.topPValueDisplay, help: metricHelp("p_value") },
      { label: "E[FP] pool", value: this.topExpectedFalsePositivesPoolDisplay, help: metricHelp("efp_pool") },
      { label: "E[FP] 2000", value: this.topExpectedFalsePositives2000Display, help: metricHelp("efp_2000") },
    ];
  }

  get topCandidateRationaleMetrics() {
    const parsed = parseWhyMetrics(this.topCandidateWhy);
    return parsed
      .filter((item) => !["score", "rank", "llr"].includes(item.key))
      .map((item) => ({
        label: RATIONALE_LABELS[item.key] || titleize(item.key),
        value: item.rawValue,
        help: metricHelp(RATIONALE_HELP_KEYS[item.key] || item.key) || fallbackRationaleMetricHelp(item.key),
      }));
  }

  get topCandidateScoringMetrics() {
    return [
      { label: "Evidence score", value: this.topEvidenceScoreDisplay, help: metricHelp("evidence_score") },
      { label: "Rank score", value: this.topRankScoreDisplay, help: metricHelp("rank_score") },
    ];
  }

  get topCandidateScoringNote() {
    if (!this.topCandidate) {
      return "";
    }

    if (!this.hasRunnerUp && this.topEvidenceScoreDisplay !== "—" && this.topEvidenceScoreDisplay === this.topRankScoreDisplay) {
      return "In a single-candidate pool, evidence score and rank score can coincide because there is no runner-up candidate to separate against.";
    }

    if (this.topEvidenceScoreDisplay !== "—" && this.topEvidenceScoreDisplay === this.topRankScoreDisplay) {
      return "Evidence score and rank score can coincide when ranking is driven almost entirely by the same evidence inputs for the surviving shortlist.";
    }

    return "";
  }

  get topCandidateUserLabel() {
    return candidateUserLabel(this.topCandidate);
  }

  get topCandidateFingerprintLabel() {
    return this.topCandidate?.fingerprint_id || "—";
  }

  get topCandidateMisComp() {
    const mismatches = this.topCandidate?.mismatches ?? 0;
    const compared = this.topCandidate?.compared ?? 0;
    return `${mismatches} / ${compared}`;
  }

  get topCandidateBestOffset() {
    const value = this.topCandidate?.best_offset_segments;
    return value === null || value === undefined ? "—" : String(value);
  }

  get topDeltaVsSecond() {
    return this.secondCandidate ? this.matchDelta : null;
  }

  get topMatchRatioDisplay() {
    return formatRatio(this.topMatchRatio);
  }

  get topDeltaVsSecondDisplay() {
    return this.topDeltaVsSecond === null ? "—" : formatRatio(this.topDeltaVsSecond);
  }

  get topSignalZDisplay() {
    return this.topSignalZ === null ? "—" : formatCompactStat(this.topSignalZ);
  }

  get topPValueDisplay() {
    return this.topPValue === null ? "—" : formatProbability(this.topPValue);
  }

  get topExpectedFalsePositivesPoolDisplay() {
    return this.topExpectedFalsePositivesPool === null ? "—" : formatProbability(this.topExpectedFalsePositivesPool);
  }

  get topExpectedFalsePositives2000Display() {
    return this.topExpectedFalsePositives2000 === null ? "—" : formatProbability(this.topExpectedFalsePositives2000);
  }

  get topEvidenceScoreDisplay() {
    return this.topCandidate?.evidence_score == null ? "—" : formatCompactStat(this.topCandidate.evidence_score);
  }

  get topRankScoreDisplay() {
    return this.topCandidate?.rank_score == null ? "—" : formatCompactStat(this.topCandidate.rank_score);
  }

  get topPValue() {
    const v = this.topCandidate?.p_value;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get topSignalZ() {
    const v = this.topCandidate?.signal_z;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get topExpectedFalsePositivesPool() {
    const v = this.topCandidate?.expected_false_positives_pool;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get topExpectedFalsePositives2000() {
    const v = this.topCandidate?.expected_false_positives_2000;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get topCandidate() {
    return this.candidates?.[0] || null;
  }

  get secondCandidate() {
    return this.candidates?.[1] || null;
  }

  get topMatchRatio() {
    return this._candidateRatio(this.topCandidate);
  }

  get secondMatchRatio() {
    return this._candidateRatio(this.secondCandidate);
  }

  get matchDelta() {
    return Math.max(0, this.topMatchRatio - this.secondMatchRatio);
  }

  get confidence() {
    // Prefer the server-side decision policy when present.
    const decision = this.decision;
    if (decision) {
      switch (decision) {
        case "conclusive_match":
          return "strong";
        case "likely_match":
          return "medium";
        case "ambiguous":
          return "weak";
        case "no_signal":
        case "timeout":
        case "error":
          return "none";
        default:
          return "none";
      }
    }

    const usable = this.usableSamples;
    const top = this.topMatchRatio;
    const delta = this.matchDelta;

    if (!this.candidates?.length || usable < 5 || top <= 0) {
      return "none";
    }

    // Heuristics: we care about (1) enough usable samples, (2) a high match ratio,
    // and (3) clear separation from #2.
    if (usable >= 12 && top >= 0.85 && delta >= 0.2) {
      return "strong";
    }

    if (usable >= 8 && top >= 0.7 && delta >= 0.15) {
      return "medium";
    }

    if (usable >= 5 && top >= 0.55 && delta >= 0.1) {
      return "weak";
    }

    return "none";
  }

  get confidenceClass() {
    switch (this.confidence) {
      case "strong":
        return "alert-success";
      case "medium":
        return "alert-info";
      case "weak":
        return "alert-warning";
      default:
        return "alert-error";
    }
  }

  get decision() {
    return this.meta?.decision || "";
  }

  get conclusive() {
    return !!this.meta?.conclusive;
  }

  get recommendation() {
    return this.meta?.recommendation || "";
  }

  get decisionText() {
    switch (this.decision) {
      case "conclusive_match":
        return "Conclusive match";
      case "likely_match":
        return "Likely match (not conclusive)";
      case "ambiguous":
        return "Ambiguous";
      case "insufficient_samples":
        return "Insufficient usable samples";
      case "no_signal":
        return "No reliable watermark signal";
      case "timeout":
        return "Timed out";
      case "error":
        return "Error";
      case "no_match":
        return "No match";
      default:
        return "";
    }
  }

  get observedVariants() {
    return this.result?.observed?.variants || "";
  }

  get samples() {
    return this.meta?.samples ?? 0;
  }

  get usableSamples() {
    return this.meta?.usable_samples ?? 0;
  }

  get weakSignal() {
    // Heuristic: if we have almost no usable samples, matching will be unreliable.
    return this.usableSamples === 0 || this.usableSamples < 5;
  }

  get showWeakTip() {
    return (
      this.weakSignal ||
      this.confidence === "weak" ||
      this.confidence === "none" ||
      (this.decision && !this.conclusive)
    );
  }

  get isAmbiguous() {
    if (this.decision === "ambiguous") {
      return true;
    }
    return (this.candidates?.length || 0) > 1 && this.matchDelta < 0.1;
  }

  get attempts() {
    return this.meta?.attempts ?? 1;
  }

  get autoExtended() {
    return !!this.meta?.auto_extended;
  }

  get maxSamplesUsed() {
    return this.meta?.max_samples_used ?? null;
  }

  get chosenPhaseSeconds() {
    const v = this.meta?.chosen_phase_seconds;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get denseStepSeconds() {
    const v = this.meta?.dense_step_seconds;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get chunkedResyncUsed() {
    return !!this.meta?.chunked_resync_used;
  }

  get chunkedResyncChunksUsed() {
    return this.meta?.chunked_resync_chunks_used ?? null;
  }

  get chunkedResyncWindowSegments() {
    return this.meta?.chunked_resync_window_segments ?? null;
  }

  get chunkedResyncOffsets() {
    return this.meta?.chunked_resync_offsets || [];
  }

  get chunkedResyncRanges() {
    return this.meta?.chunked_resync_ranges || [];
  }

  get chunkedResyncReason() {
    return this.meta?.chunked_resync_reason || "";
  }

  get offsetExpansionApplied() {
    return !!this.meta?.offset_expansion_applied;
  }

  get offsetExpansionReason() {
    return this.meta?.offset_expansion_reason || "";
  }

  get phaseRefinementAttempted() {
    return !!this.meta?.phase_search_refinement_attempted;
  }

  get phaseRefinementApplied() {
    return !!this.meta?.phase_search_refinement_applied;
  }

  get phaseRefinementReason() {
    return this.meta?.phase_search_refinement_reason || "";
  }

  get multisampleRefineUsed() {
    return !!this.meta?.multisample_refine_used;
  }

  get multisampleRefineApplied() {
    return !!this.meta?.multisample_refine_applied;
  }

  get multisampleRefineReason() {
    return this.meta?.multisample_refine_reason || "";
  }

  get shortlistEvidenceGap() {
    const v = this.meta?.shortlist_evidence_gap;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get decisionReasons() {
    return Array.isArray(this.meta?.decision_reasons) ? this.meta.decision_reasons : [];
  }

  get decisionReasonsText() {
    return this.decisionReasons.join(", ");
  }

  get topCandidateWhy() {
    return this.meta?.top_candidate_why || this.topCandidate?.why || "";
  }

  get configuredFilemodeSoftBudgetSeconds() {
    const v = this.meta?.configured_filemode_soft_time_budget_seconds;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get configuredFilemodeEngineBudgetSeconds() {
    const v = this.meta?.configured_filemode_engine_time_budget_seconds;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get timeoutKind() {
    return this.meta?.timeout_kind || "";
  }

  get likelyTimeoutLayer() {
    return this.meta?.likely_timeout_layer || "";
  }

  get syncPeriod() {
    const v = this.meta?.sync_period;
    const f = typeof v === "number" ? v : parseInt(v, 10);
    return Number.isFinite(f) ? f : null;
  }

  get syncPairsCount() {
    const v = this.meta?.sync_pairs_count;
    const f = typeof v === "number" ? v : parseInt(v, 10);
    return Number.isFinite(f) ? f : null;
  }

  get eccScheme() {
    return this.meta?.ecc_scheme || "";
  }

  get eccGroupsUsed() {
    const v = this.meta?.ecc_groups_used;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get eccRawUsableSamples() {
    const v = this.meta?.ecc_raw_usable_samples;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get variantPolarity() {
    return this.meta?.variant_polarity || this.topCandidate?.variant_polarity || "normal";
  }

  get polarityFlipUsed() {
    return !!(this.meta?.polarity_flip_used || this.topCandidate?.polarity_flip_used);
  }

  get polarityScoreDelta() {
    const v = this.meta?.polarity_score_delta;
    const f = typeof v === "number" ? v : parseFloat(v);
    return Number.isFinite(f) ? f : null;
  }

  get expectedVariantsTopCandidate() {
    return this.meta?.expected_variants_top_candidate || this.topCandidate?.expected_variants || "";
  }

  get mismatchPositions() {
    const arr = this.meta?.mismatch_positions || this.topCandidate?.mismatch_positions || [];
    return Array.isArray(arr) ? arr : [];
  }

  get mismatchPositionsText() {
    return this.mismatchPositions.length ? this.mismatchPositions.join(", ") : "";
  }

  get referenceSegmentIndicesText() {
    const arr = this.meta?.reference_segment_indices_used || this.topCandidate?.reference_segment_indices_used || [];
    if (!Array.isArray(arr) || !arr.length) {
      return "";
    }
    return arr.map((v) => (v === null || v === undefined ? "." : String(v))).join(", ");
  }

  get phaseSearchUsed() {
    return !!this.meta?.phase_search_used;
  }

  _decorateCandidate(candidate, idx, topRatio) {
    const matchRatio = this._candidateRatio(candidate);
    const deltaFromTop = idx === 0 ? 0 : Math.max(0, topRatio - matchRatio);
    const mismatches = candidate?.mismatches ?? 0;
    const compared = candidate?.compared ?? 0;
    const weightedMismatches = candidate?.mismatches_weighted;
    const weightedCompared = candidate?.compared_weighted;
    const parsedWhy = parseWhyMetrics(candidate?.why);

    const rationaleMetrics = parsedWhy
      .filter((item) => !["score", "rank", "llr"].includes(item.key))
      .map((item) => ({
        label: RATIONALE_LABELS[item.key] || titleize(item.key),
        value: item.rawValue,
        help: metricHelp(RATIONALE_HELP_KEYS[item.key] || item.key) || fallbackRationaleMetricHelp(item.key),
      }));

    const statsMetrics = [
      { label: "Evidence score", value: candidate?.evidence_score === null || candidate?.evidence_score === undefined ? "—" : formatCompactStat(candidate.evidence_score), help: metricHelp("evidence_score") },
      { label: "Rank score", value: candidate?.rank_score === null || candidate?.rank_score === undefined ? "—" : formatCompactStat(candidate.rank_score), help: metricHelp("rank_score") },
      { label: "Weighted mis / comp", value: weightedCompared === null || weightedCompared === undefined || Number(weightedCompared) <= 0 ? "—" : `${formatCompactStat(weightedMismatches)} / ${formatCompactStat(weightedCompared)}`, help: metricHelp("weighted_mis_comp") },
      { label: "Chunk LLR", value: candidate?.chunk_llr_total === null || candidate?.chunk_llr_total === undefined ? "—" : formatCompactStat(candidate.chunk_llr_total), help: metricHelp("chunk_llr") },
      { label: "Z-score", value: candidate?.signal_z === null || candidate?.signal_z === undefined ? "—" : formatCompactStat(candidate.signal_z), help: metricHelp("z_score") },
      { label: "p-value", value: candidate?.p_value === null || candidate?.p_value === undefined ? "—" : formatProbability(candidate.p_value), help: metricHelp("p_value") },
      { label: "E[FP] pool", value: candidate?.expected_false_positives_pool === null || candidate?.expected_false_positives_pool === undefined ? "—" : formatProbability(candidate.expected_false_positives_pool), help: metricHelp("efp_pool") },
      { label: "E[FP] 2000", value: candidate?.expected_false_positives_2000 === null || candidate?.expected_false_positives_2000 === undefined ? "—" : formatProbability(candidate.expected_false_positives_2000), help: metricHelp("efp_2000") },
    ];

    return {
      ...candidate,
      _idx: idx,
      displayUser: candidateUserLabel(candidate),
      displayFingerprint: candidate?.fingerprint_id || "—",
      displayMatch: formatRatio(matchRatio),
      displayMisComp: `${mismatches} / ${compared}`,
      displayBestOffset:
        candidate?.best_offset_segments === null || candidate?.best_offset_segments === undefined
          ? "—"
          : String(candidate.best_offset_segments),
      displayDeltaFromTop: formatRatio(deltaFromTop),
      displayWhy: "",
      rationaleMetrics,
      statsMetrics,
      hasRationaleMetrics: rationaleMetrics.length > 0,
      isPrimary: idx === 0,
      delta_from_top: deltaFromTop,
    };
  }

  _candidateRatio(candidate) {
    const weighted = candidate?.match_ratio_weighted;
    const weightedFloat = typeof weighted === "number" ? weighted : parseFloat(weighted);
    if (Number.isFinite(weightedFloat) && weightedFloat > 0) {
      return weightedFloat;
    }

    const raw = candidate?.match_ratio;
    const rawFloat = typeof raw === "number" ? raw : parseFloat(raw);
    return Number.isFinite(rawFloat) ? rawFloat : 0;
  }

  get hasAlignmentDebug() {
    return !!(
      this.observedVariants ||
      this.expectedVariantsTopCandidate ||
      this.referenceSegmentIndicesText ||
      this.mismatchPositions.length
    );
  }

  get hasMoreCandidates() {
    return (this.candidates?.length || 0) > this.topCandidates.length;
  }

  get hasLookupMatches() {
    return this.hasOverlaySearchMatches;
  }

  get showNoSearchMatches() {
    const q = this.searchQuery || "";
    return (
      !this.isSearching &&
      q.length >= 3 &&
      (this.searchResults?.length || 0) === 0 &&
      !this.searchError
    );
  }

  @action
  onSearchKeydown(event) {
    if (event?.key === "Enter") {
      event.preventDefault();
      this.search();
    }
  }

  @action
  onSearchTypeFilterChange(event) {
    this.searchTypeFilter = event?.target?.value || "all";
  }

  @action
  onSearchStatusFilterChange(event) {
    this.searchStatusFilter = event?.target?.value || "all";
  }

  @action
  onSearchBackendFilterChange(event) {
    this.searchBackendFilter = event?.target?.value || "all";
  }

  @action
  onSearchHlsFilterChange(event) {
    this.searchHlsFilter = event?.target?.value || "all";
  }

  @action
  onSearchLimitChange(event) {
    const value = parseInt(event?.target?.value, 10);
    this.searchLimit = Number.isFinite(value) && value > 0 ? value : 20;
  }

  @action
  onSearchSortChange(event) {
    this.searchSort = event?.target?.value || "newest";
  }

  @action
  resetSearchFilters() {
    this.searchQuery = "";
    this.searchTypeFilter = "all";
    this.searchStatusFilter = "all";
    this.searchBackendFilter = "all";
    this.searchHlsFilter = "all";
    this.searchLimit = 20;
    this.searchSort = "newest";
    this.searchError = "";
    this.lookupCode = "";
    this.lookupError = "";
    this.lookupMatches = [];
    this.search();
  }

  @action
  onPublicIdInput(event) {
    this.publicId = (event?.target?.value || "").trim();
  }

  @action
  onSearchInput(event) {
    this.searchQuery = (event?.target?.value || "").trim();
    this._debouncedSearch();
  }

  _debouncedSearch() {
    if (this._searchTimer) {
      clearTimeout(this._searchTimer);
    }

    this._searchTimer = setTimeout(() => {
      this._searchTimer = null;
      this.search();
    }, 300);
  }

  async search() {
    this.searchError = "";
    this.lookupError = "";
    this.lookupMatches = [];
    this.lookupCode = "";
    this.isSearching = true;
    this.lookupBusy = false;

    try {
      const q = (this.searchQuery || "").trim();
      if (q && q.length < 3) {
        this.searchResults = [];
        return;
      }

      const params = new URLSearchParams();
      params.set("q", q || "");
      params.set("limit", String(this.searchLimit || 20));
      params.set("sort", this.searchSort || "newest");

      if (this.searchTypeFilter !== "all") {
        params.set("media_type", this.searchTypeFilter);
      }

      if (this.searchStatusFilter !== "all") {
        params.set("status", this.searchStatusFilter);
      }

      if (this.searchBackendFilter !== "all") {
        params.set("backend", this.searchBackendFilter);
      }

      if (this.searchHlsFilter === "yes") {
        params.set("has_hls", "true");
      } else if (this.searchHlsFilter === "no") {
        params.set("has_hls", "false");
      }

      const requests = [
        fetch(`/admin/plugins/media-gallery/media-items/search.json?${params.toString()}`, {
          method: "GET",
          headers: { Accept: "application/json" },
          credentials: "same-origin",
        }),
      ];

      const shouldLookupOverlay = isOverlayLikeQuery(q);
      if (shouldLookupOverlay) {
        this.lookupBusy = true;
        this.lookupCode = q.toUpperCase();
        requests.push(
          fetch(
            `/admin/plugins/media-gallery/forensics-identify/overlay-lookup.json?${new URLSearchParams({ code: this.lookupCode }).toString()}`,
            {
              method: "GET",
              headers: { Accept: "application/json" },
              credentials: "same-origin",
            }
          )
        );
      }

      const [searchResponse, overlayResponse] = await Promise.all(requests);

      if (!searchResponse.ok) {
        const err = await this._extractError(searchResponse);
        this.searchError = `HTTP ${searchResponse.status}: ${err}`;
        this.searchResults = [];
      } else {
        const json = await searchResponse.json();
        this.searchResults = Array.isArray(json?.items) ? json.items : [];
      }

      if (overlayResponse) {
        if (!overlayResponse.ok) {
          const err = await this._extractError(overlayResponse);
          this.lookupError = `HTTP ${overlayResponse.status}: ${err}`;
        } else {
          const json = await overlayResponse.json();
          this.lookupMatches = Array.isArray(json?.matches) ? json.matches : [];
          if (!this.lookupMatches.length) {
            this.lookupError = "No overlay/session code matches found.";
          }
        }
      }
    } catch (e) {
      this.searchError = e?.message || String(e);
      this.searchResults = [];
      this.lookupMatches = [];
    } finally {
      this.lookupBusy = false;
      this.isSearching = false;
    }
  }

  @action
  pickPublicId(item) {
    const pid = item?.public_id;
    if (pid) {
      this.publicId = pid;
    }
  }

  @action
  pickPublicIdFromLookup(match) {
    const pid = match?.media_public_id;
    if (pid) {
      this.publicId = pid;
    }
  }

  @action
  onFileChange(event) {
    const files = event?.target?.files;
    this.file = files && files.length ? files[0] : null;
  }

  @action
  onSourceUrlInput(event) {
    this.sourceUrl = (event?.target?.value || "").trim();
  }

  @action
  onLookupCodeInput(event) {
    this.lookupCode = String(event?.target?.value || "")
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "")
      .trim();
  }

  @action
  onMaxSamplesInput(event) {
    const v = parseInt(event?.target?.value, 10);
    this.maxSamples = Number.isFinite(v) ? v : 60;
  }

  @action
  onMaxOffsetInput(event) {
    const v = parseInt(event?.target?.value, 10);
    this.maxOffsetSegments = Number.isFinite(v) ? v : 30;
  }

  @action
  onLayoutChange(event) {
    this.layout = event?.target?.value || "";
  }

  @action
  onAutoExtendChange(event) {
    this.autoExtend = !!event?.target?.checked;
  }

  @action
  clearLookup() {
    this.lookupCode = "";
    this.lookupError = "";
    this.lookupMatches = [];
  }

  @action
  clear() {
    this.error = "";
    this.statusMessage = "";
    this.activeTaskId = null;
    if (this._statusPollTimer) {
      clearTimeout(this._statusPollTimer);
      this._statusPollTimer = null;
    }
    this.result = null;
    this.resultJson = "";
  }

  @action
  async lookupOverlayCode() {
    this.lookupError = "";
    this.lookupMatches = [];

    const code = String(this.lookupCode || this.searchQuery || "")
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "")
      .trim();

    if (!code) {
      this.lookupError = "Enter a session code first.";
      return;
    }

    this.lookupBusy = true;
    try {
      const params = new URLSearchParams({ code });
      if (this.publicId) {
        params.set("public_id", this.publicId);
      }

      const response = await fetch(`/admin/plugins/media-gallery/forensics-identify/overlay-lookup.json?${params.toString()}`, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.lookupError = `HTTP ${response.status}: ${err}`;
        return;
      }

      const json = await response.json();
      this.lookupMatches = Array.isArray(json?.matches) ? json.matches : [];
      if (!this.lookupMatches.length) {
        this.lookupError = "No matches found for that session code.";
      }
    } catch (e) {
      this.lookupError = e?.message || String(e);
    } finally {
      this.lookupBusy = false;
    }
  }

  async _extractError(response) {
    // Try JSON error first, then fall back to text.
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) {
        return json.errors.join(" ");
      }
      if (json?.error) {
        return String(json.error);
      }
    } catch {
      // ignore
    }

    try {
      const text = await response.text();
      if (text) {
        // Keep it short-ish.
        return text.length > 500 ? `${text.slice(0, 500)}…` : text;
      }
    } catch {
      // ignore
    }

    return `HTTP ${response.status}`;
  }

  _scheduleStatusPoll(statusUrl) {
    if (this._statusPollTimer) {
      clearTimeout(this._statusPollTimer);
    }

    this._statusPollTimer = setTimeout(() => {
      this._statusPollTimer = null;
      this._pollStatus(statusUrl);
    }, 1500);
  }

  async _pollStatus(statusUrl) {
    try {
      const response = await fetch(statusUrl, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.error = `HTTP ${response.status}: ${err}`;
        this.statusMessage = "";
        this.isRunning = false;
        return;
      }

      const json = await response.json();
      const status = json?.status || "queued";
      this.activeTaskId = json?.task_id || this.activeTaskId;

      if (status === "complete") {
        this.result = json?.result || null;
        this.resultJson = this.result ? JSON.stringify(this.result, null, 2) : "";
        this.statusMessage = "Background analysis completed.";
        this.isRunning = false;
        return;
      }

      if (status === "failed") {
        this.error = json?.error || "Background analysis failed.";
        this.statusMessage = "";
        this.isRunning = false;
        return;
      }

      this.statusMessage = status === "working" ? "Background analysis running…" : "Background analysis queued…";
      this._scheduleStatusPoll(statusUrl);
    } catch (e) {
      this.error = e?.message || String(e);
      this.statusMessage = "";
      this.isRunning = false;
    }
  }

  @action
  async identify() {
    this.error = "";
    this.statusMessage = "";
    this.result = null;
    this.resultJson = "";

    if (!this.publicId) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_public_id");
      return;
    }

    const hasUrl = !!this.sourceUrl;
    const hasFile = !!this.file;

    if (!hasUrl && !hasFile) {
      this.error = i18n("admin.media_gallery.forensics_identify.error_missing_file_or_url");
      return;
    }

    const csrfToken = document
      .querySelector("meta[name='csrf-token']")
      ?.getAttribute("content");

    const form = new FormData();
    if (hasFile) {
      form.append("file", this.file);
    }
    if (hasUrl && !hasFile) {
      form.append("source_url", this.sourceUrl);
    }

    form.append("max_samples", String(this.maxSamples || 60));
    form.append("max_offset_segments", String(this.maxOffsetSegments || 30));
    if (this.layout) {
      form.append("layout", this.layout);
    }
    form.append("auto_extend", this.autoExtend ? "1" : "0");

    const syncUrl = `/admin/plugins/media-gallery/forensics-identify/${encodeURIComponent(
      this.publicId
    )}.json`;
    const queueUrl = `/admin/plugins/media-gallery/forensics-identify/${encodeURIComponent(
      this.publicId
    )}/queue`;

    this.isRunning = true;
    try {
      const response = await fetch(hasFile ? queueUrl : syncUrl, {
        method: "POST",
        headers: {
          ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
          Accept: "application/json",
        },
        body: form,
        credentials: "same-origin",
      });

      if (!response.ok) {
        const err = await this._extractError(response);
        this.error = `HTTP ${response.status}: ${err}`;
        return;
      }

      const json = await response.json();

      if (hasFile) {
        const statusUrl = json?.status_url;
        this.activeTaskId = json?.task_id || null;
        this.statusMessage = "Background analysis queued…";

        if (!statusUrl) {
          this.error = "Queue response did not include a status URL.";
          this.isRunning = false;
          return;
        }

        this._scheduleStatusPoll(statusUrl);
        return;
      }

      this.result = json;
      this.resultJson = JSON.stringify(json, null, 2);
    } catch (e) {
      this.error = e?.message || String(e);
    } finally {
      if (!hasFile) {
        this.isRunning = false;
      }
    }
  }
}

