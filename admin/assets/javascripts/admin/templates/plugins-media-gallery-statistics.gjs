import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-statistics {
        --mg-stats-surface: var(--secondary);
        --mg-stats-surface-alt: var(--primary-very-low);
        --mg-stats-border: var(--primary-low);
        --mg-stats-muted: var(--primary-medium);
        --mg-stats-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-statistics h1,
      .media-gallery-statistics h2,
      .media-gallery-statistics h3,
      .media-gallery-statistics p,
      .media-gallery-statistics label {
        margin: 0;
      }

      .mg-stats__hero,
      .mg-stats__panel,
      .mg-stats__card {
        background: var(--mg-stats-surface);
        border: 1px solid var(--mg-stats-border);
        border-radius: var(--mg-stats-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-stats__hero,
      .mg-stats__panel {
        padding: 1rem 1.125rem;
        min-width: 0;
      }

      .mg-stats__hero {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-stats__hero-copy,
      .mg-stats__panel-copy,
      .mg-stats__field,
      .mg-stats__card,
      .mg-stats__empty,
      .mg-stats__note-list {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
      }

      .mg-stats__hero-actions,
      .mg-stats__toolbar,
      .mg-stats__panel-header,
      .mg-stats__row-header,
      .mg-stats__kpi-meta-row {
        display: flex;
        align-items: center;
        gap: 0.75rem;
      }

      .mg-stats__hero-actions {
        justify-content: flex-end;
        flex-wrap: wrap;
      }

      .mg-stats__toolbar {
        align-items: end;
        flex-wrap: wrap;
        gap: 0.85rem;
        margin-top: 0.9rem;
      }

      .mg-stats__panel-header {
        align-items: flex-start;
        justify-content: space-between;
        margin-bottom: 0.9rem;
      }

      .mg-stats__muted,
      .mg-stats__meta,
      .mg-stats__performance,
      .mg-stats__field label,
      .mg-stats__table-meta {
        color: var(--mg-stats-muted);
        font-size: var(--font-down-1);
      }

      .mg-stats__performance {
        margin-top: 0.3rem;
      }

      .mg-stats__field label {
        font-weight: 700;
      }

      .mg-stats__field select {
        width: 100%;
        min-width: 180px;
        min-height: 42px;
        box-sizing: border-box;
        border: 1px solid var(--mg-stats-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0 0.85rem;
      }

      .mg-stats__toolbar-action {
        align-self: flex-end;
        margin-bottom: 10px;
      }

      .mg-stats__kpi-grid,
      .mg-stats__two-column,
      .mg-stats__three-column,
      .mg-stats__breakdown-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-stats__kpi-grid {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }

      .mg-stats__two-column {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-stats__three-column {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }

      .mg-stats__breakdown-grid {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }

      .mg-stats__card {
        padding: 0.9rem 1rem;
        min-width: 0;
      }

      .mg-stats__kpi-value {
        font-size: 1.55rem;
        font-weight: 800;
        line-height: 1.1;
      }

      .mg-stats__kpi-label,
      .mg-stats__row-label {
        font-weight: 700;
      }

      .mg-stats__bar-list,
      .mg-stats__compact-list,
      .mg-stats__top-list {
        display: grid;
        gap: 0.75rem;
      }

      .mg-stats__bar-row,
      .mg-stats__breakdown-row,
      .mg-stats__moderation-row {
        display: grid;
        gap: 0.35rem;
      }

      .mg-stats__row-header {
        justify-content: space-between;
        min-width: 0;
      }

      .mg-stats__row-label {
        min-width: 0;
        overflow-wrap: anywhere;
      }

      .mg-stats__row-value {
        color: var(--primary-high);
        font-weight: 700;
        white-space: nowrap;
      }

      .mg-stats__bar-track {
        width: 100%;
        height: 0.62rem;
        overflow: hidden;
        border-radius: 999px;
        background: var(--primary-low);
      }

      .mg-stats__bar-fill {
        display: block;
        height: 100%;
        border-radius: 999px;
        background: var(--tertiary);
      }

      .mg-stats__bar-fill.is-soft {
        background: var(--tertiary-low);
      }

      .mg-stats__comparison-table,
      .mg-stats__mini-table {
        width: 100%;
        border-collapse: collapse;
      }

      .mg-stats__comparison-table th,
      .mg-stats__comparison-table td,
      .mg-stats__mini-table th,
      .mg-stats__mini-table td {
        border-bottom: 1px solid var(--mg-stats-border);
        padding: 0.55rem 0.45rem;
        text-align: left;
        vertical-align: top;
      }

      .mg-stats__comparison-table th:nth-child(2),
      .mg-stats__comparison-table th:nth-child(3),
      .mg-stats__comparison-table th:nth-child(4),
      .mg-stats__comparison-table th:nth-child(5),
      .mg-stats__comparison-table td:nth-child(2),
      .mg-stats__comparison-table td:nth-child(3),
      .mg-stats__comparison-table td:nth-child(4),
      .mg-stats__comparison-table td:nth-child(5) {
        min-width: 7.5rem;
        white-space: nowrap;
      }

      .mg-stats__comparison-table th,
      .mg-stats__mini-table th {
        color: var(--mg-stats-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
      }

      .mg-stats__delta {
        display: inline-flex;
        align-items: center;
        border-radius: 999px;
        background: var(--primary-very-low);
        border: 1px solid var(--primary-low);
        color: var(--primary-high);
        font-size: var(--font-down-1);
        font-weight: 700;
        line-height: 1;
        padding: 0.3rem 0.5rem;
        white-space: nowrap;
      }

      .mg-stats__insight-list {
        display: grid;
        gap: 0.75rem;
      }

      .mg-stats__insight-list.is-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-stats__kpi-grid.is-two-by-two {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-stats__processing-latency-panel,
      .mg-stats__slow-processing-panel {
        grid-column: 1 / -1;
      }

      .mg-stats__insight {
        display: grid;
        gap: 0.35rem;
        border: 1px solid var(--mg-stats-border);
        border-radius: 14px;
        background: var(--primary-very-low);
        padding: 0.85rem 0.95rem;
      }

      .mg-stats__insight.is-warning {
        border-color: var(--danger-low);
        background: var(--danger-low);
      }

      .mg-stats__insight.is-success {
        border-color: var(--success-low);
        background: var(--success-low);
      }

      .mg-stats__moderation-card-list {
        display: grid;
        gap: 0.65rem;
      }

      .mg-stats__moderation-card {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        border: 1px solid var(--mg-stats-border);
        border-radius: 14px;
        background: var(--primary-very-low);
        padding: 0.8rem 0.9rem;
      }

      .mg-stats__moderation-card-value {
        font-size: 1.15rem;
        font-weight: 800;
        white-space: nowrap;
      }

      .mg-stats__insight-title,
      .mg-stats__mini-title {
        font-weight: 800;
      }

      .mg-stats__mini-code {
        color: var(--mg-stats-muted);
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-stats__table-wrap {
        width: 100%;
        overflow-x: auto;
      }

      .mg-stats__table {
        width: 100%;
        border-collapse: collapse;
        min-width: 760px;
      }

      .mg-stats__table th,
      .mg-stats__table td {
        border-bottom: 1px solid var(--mg-stats-border);
        padding: 0.65rem 0.55rem;
        text-align: left;
        vertical-align: top;
      }

      .mg-stats__table th {
        color: var(--mg-stats-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
      }

      .mg-stats__sort-button {
        display: inline-flex;
        align-items: center;
        gap: 0.25rem;
        border: 0;
        background: transparent;
        color: inherit;
        cursor: pointer;
        font: inherit;
        font-weight: 700;
        padding: 0;
        text-align: left;
      }

      .mg-stats__sort-button::after {
        content: "↕";
        font-size: 0.75em;
        opacity: 0.55;
      }

      .mg-stats__table-title {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-stats__table-code {
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
        color: var(--mg-stats-muted);
        overflow-wrap: anywhere;
      }

      .mg-stats__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-high);
        font-size: var(--font-down-1);
        line-height: 1;
        padding: 0.3rem 0.55rem;
        white-space: nowrap;
      }

      .mg-stats__badge.is-success {
        border-color: var(--success-low);
        background: var(--success-low);
        color: var(--success);
      }

      .mg-stats__badge.is-warning {
        border-color: var(--highlight-low);
        background: var(--highlight-low);
        color: var(--primary-high);
      }

      .mg-stats__badge.is-danger {
        border-color: var(--danger-low);
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-stats__media-card-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.85rem;
      }

      .mg-stats__media-card {
        display: grid;
        gap: 0.75rem;
        border: 1px solid var(--mg-stats-border);
        border-radius: 14px;
        background: var(--mg-stats-surface-alt);
        padding: 0.85rem 0.95rem;
        min-width: 0;
      }

      .mg-stats__media-card-header {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 0.75rem;
      }

      .mg-stats__media-card-meta,
      .mg-stats__stat-label {
        color: var(--mg-stats-muted);
        font-size: var(--font-down-1);
      }

      .mg-stats__stat-list {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.6rem;
      }

      .mg-stats__stat {
        display: flex;
        flex-direction: column;
        gap: 0.2rem;
        border: 1px solid var(--mg-stats-border);
        border-radius: 12px;
        background: var(--mg-stats-surface);
        padding: 0.65rem 0.7rem;
        min-width: 0;
      }

      .mg-stats__stat-value {
        font-weight: 800;
        overflow-wrap: anywhere;
      }

      .mg-stats__empty,
      .mg-stats__notice {
        border: 1px solid var(--mg-stats-border);
        border-radius: 14px;
        background: var(--mg-stats-surface-alt);
        padding: 0.85rem 0.95rem;
      }

      .mg-stats__notice.is-error {
        border-color: var(--danger-low);
        background: var(--danger-low);
      }

      .mg-stats__note-list {
        padding-left: 1.1rem;
        margin: 0;
      }

      @media (max-width: 1200px) {
        .mg-stats__kpi-grid,
        .mg-stats__breakdown-grid,
        .mg-stats__three-column {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 900px) {
        .mg-stats__hero,
        .mg-stats__panel-header,
        .mg-stats__media-card-header {
          flex-direction: column;
        }

        .mg-stats__two-column,
        .mg-stats__three-column,
        .mg-stats__kpi-grid,
        .mg-stats__kpi-grid.is-two-by-two,
        .mg-stats__breakdown-grid,
        .mg-stats__insight-list.is-grid,
        .mg-stats__media-card-grid,
        .mg-stats__stat-list {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-statistics">
      <section class="mg-stats__hero">
        <div class="mg-stats__hero-copy">
          <h1>Media Gallery statistics</h1>
          <p class="mg-stats__muted">
            Read-only analytics dashboard for usage, engagement, moderation and content quality.
          </p>
          {{#if @controller.generatedAtLabel}}
            <p class="mg-stats__meta">Last generated: {{@controller.generatedAtLabel}}</p>
          {{/if}}
          {{#if @controller.performanceTimingLabel}}
            <p class="mg-stats__performance">{{@controller.performanceTimingLabel}}</p>
          {{/if}}
        </div>

        <div class="mg-stats__hero-actions">
          <a class="btn" href="/admin/plugins/media-gallery">Back to Media Gallery</a>
          <button
            type="button"
            class="btn btn-primary"
            {{on "click" @controller.refresh}}
            disabled={{@controller.isLoading}}
          >
            {{#if @controller.isLoading}}Loading…{{else}}Refresh{{/if}}
          </button>
        </div>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Time range</h2>
            <p class="mg-stats__muted">
              Select how trend charts are grouped and how many periods should be shown.
            </p>
          </div>
        </div>

        <div class="mg-stats__toolbar">
          <div class="mg-stats__field">
            <label for="mg-statistics-period">Group by</label>
            <select id="mg-statistics-period" value={{@controller.period}} {{on "change" @controller.updatePeriod}} disabled={{@controller.isLoading}}>
              <option value="day">Day</option>
              <option value="week">Week</option>
              <option value="month">Month</option>
              <option value="year">Year</option>
            </select>
          </div>

          <div class="mg-stats__field">
            <label for="mg-statistics-limit">Periods</label>
            <select id="mg-statistics-limit" value={{@controller.limit}} {{on "change" @controller.updateLimit}} disabled={{@controller.isLoading}}>
              <option value="5">5</option>
              <option value="7">7</option>
              <option value="12">12</option>
              <option value="15">15</option>
              <option value="30">30</option>
              <option value="60">60</option>
              <option value="90">90</option>
              <option value="120">120</option>
            </select>
          </div>

          <button type="button" class="btn mg-stats__toolbar-action" {{on "click" @controller.refresh}} disabled={{@controller.isLoading}}>
            Apply
          </button>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-stats__notice is-error">
          <strong>Statistics could not be fully loaded.</strong>
          <p>{{@controller.error}}</p>
        </div>
      {{/if}}

      <section class="mg-stats__kpi-grid" aria-label="Statistics summary">
        {{#each @controller.summaryCards as |card|}}
          <article class="mg-stats__card">
            <div class="mg-stats__kpi-label">{{card.label}}</div>
            <div class="mg-stats__kpi-value">{{card.value}}</div>
            <div class="mg-stats__meta">{{card.meta}}</div>
          </article>
        {{/each}}
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Actionable insights</h2>
            <p class="mg-stats__muted">Operational signals that need admin attention.</p>
          </div>
        </div>

        <div class="mg-stats__insight-list is-grid">
          {{#each @controller.decoratedInsights as |insight|}}
            <div class={{insight.className}}>
              <div class="mg-stats__insight-title">{{insight.title}}</div>
              <p>{{insight.message}}</p>
              <p class="mg-stats__muted">{{insight.action}}</p>
            </div>
          {{else}}
            <div class="mg-stats__empty">No insights available.</div>
          {{/each}}
        </div>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Current range vs previous range</h2>
            <p class="mg-stats__muted">
              {{@controller.currentRangeLabel}} compared with {{@controller.previousRangeLabel}}.
            </p>
            <p class="mg-stats__meta">
              {{@controller.currentRangeDateLabel}} vs {{@controller.previousRangeDateLabel}}
            </p>
          </div>
        </div>

        <div class="mg-stats__table-wrap">
          <table class="mg-stats__comparison-table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "comparison" "label" "text")}}>Metric</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "comparison" "currentValue" "number")}}>Current</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "comparison" "previousValue" "number")}}>Previous</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "comparison" "changeValue" "number")}}>Change</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "comparison" "percentValue" "number")}}>%</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.comparisonRows as |row|}}
                <tr>
                  <td>{{row.label}}</td>
                  <td>{{row.currentLabel}}</td>
                  <td>{{row.previousLabel}}</td>
                  <td><span class={{row.changeClass}}>{{row.changeLabel}}</span></td>
                  <td><span class={{row.changeClass}}>{{row.percentLabel}}</span></td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Uploads {{@controller.periodLabel}}</h2>
              <p class="mg-stats__muted">New media items created in the selected period.</p>
            </div>
          </div>

          <div class="mg-stats__bar-list">
            {{#each @controller.uploadSeries as |row|}}
              <div class="mg-stats__bar-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No upload data available for this range.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Playback {{@controller.periodLabel}}</h2>
              <p class="mg-stats__muted">Playback sessions created by users.</p>
            </div>
          </div>

          <div class="mg-stats__bar-list">
            {{#each @controller.playbackSeries as |row|}}
              <div class="mg-stats__bar-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No playback data available for this range.</div>
            {{/each}}
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Engagement {{@controller.periodLabel}}</h2>
            <p class="mg-stats__muted">Media likes, comments and comment likes combined.</p>
          </div>
        </div>

        <div class="mg-stats__bar-list">
          {{#each @controller.engagementSeries as |row|}}
            <div class="mg-stats__bar-row">
              <div class="mg-stats__row-header">
                <span class="mg-stats__row-label">{{row.label}}</span>
                <span class="mg-stats__row-value">{{row.totalLabel}}</span>
              </div>
              <div class="mg-stats__meta">
                {{row.likesLabel}} media likes · {{row.commentsLabel}} comments · {{row.commentLikesLabel}} comment likes
              </div>
              <div class="mg-stats__bar-track" aria-hidden="true">
                <span class="mg-stats__bar-fill" style={{row.barStyle}}></span>
              </div>
            </div>
          {{else}}
            <div class="mg-stats__empty">No engagement data available for this range.</div>
          {{/each}}
        </div>
      </section>

      <section class="mg-stats__breakdown-grid">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Status</h2>
              <p class="mg-stats__muted">Current processing state of all media items.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.statusBreakdown as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No status data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Media type</h2>
              <p class="mg-stats__muted">Distribution across video, audio and image.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.typeBreakdown as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No type data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Storage backend</h2>
              <p class="mg-stats__muted">Where media items are currently managed.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.storageBreakdown as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No storage backend data available.</div>
            {{/each}}
          </div>
        </article>
      </section>

      <section class="mg-stats__breakdown-grid">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Duration profile</h2>
              <p class="mg-stats__muted">Length distribution for audio and video content.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.durationBuckets as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No duration data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Processed size profile</h2>
              <p class="mg-stats__muted">How processed files are distributed by storage size.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.processedSizeBuckets as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No processed size data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Orientation</h2>
              <p class="mg-stats__muted">Portrait, square and landscape distribution.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.orientationBuckets as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No orientation data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Resolution level</h2>
              <p class="mg-stats__muted">How much of the catalog reaches common HD thresholds.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.resolutionBuckets as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No resolution data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Top tags</h2>
              <p class="mg-stats__muted">Most used content tags, useful for navigation and cleanup.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.tagUsageRows as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No tag data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Visibility state</h2>
              <p class="mg-stats__muted">Admin-visible versus admin-hidden content.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.visibilityRows as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No visibility data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>HLS catalog</h2>
              <p class="mg-stats__muted">Current HLS and AES protection state across media items.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.hlsCatalogRows as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No HLS catalog data available.</div>
            {{/each}}
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Processing performance</h2>
            <p class="mg-stats__muted">
              Processing duration from stored job-run timing, plus active queue age from created timestamps.
            </p>
          </div>
        </div>
        <div class="mg-stats__kpi-grid is-two-by-two">
          {{#each @controller.processingPerformanceCards as |card|}}
            <article class="mg-stats__card">
              <div class="mg-stats__kpi-label">{{card.label}}</div>
              <div class="mg-stats__kpi-value">{{card.value}}</div>
              <div class="mg-stats__meta">{{card.meta}}</div>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel mg-stats__processing-latency-panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Processing latency buckets</h2>
              <p class="mg-stats__muted">Recently completed items distributed by stored processing run duration.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.processingLatencyBuckets as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No processing latency data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel mg-stats__slow-processing-panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Slow recent processing</h2>
              <p class="mg-stats__muted">Recently completed items with the longest stored processing run duration.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "recentSlowProcessing" "title" "text")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "recentSlowProcessing" "statusLabel" "text")}}>Status</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "recentSlowProcessing" "processingSeconds" "duration")}}>Duration</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "recentSlowProcessing" "processedBytes" "bytes")}}>Size</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "recentSlowProcessing" "completedAt" "date")}}>Completed</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.recentSlowProcessing as |item|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{item.title}}</div>
                      <div class="mg-stats__mini-code">{{item.publicId}}</div>
                    </td>
                    <td><span class="mg-stats__badge">{{item.statusLabel}}</span></td>
                    <td>{{item.processingLabel}}</td>
                    <td>{{item.processedSizeLabel}}</td>
                    <td>{{item.completedLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No slow processing records found for this range.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Active queue age</h2>
            <p class="mg-stats__muted">Queued or processing items ordered by oldest creation time.</p>
          </div>
        </div>
        <div class="mg-stats__table-wrap">
          <table class="mg-stats__mini-table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "title" "text")}}>Media</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "uploader" "text")}}>Uploader</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "typeLabel" "text")}}>Type</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "statusLabel" "text")}}>Status</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "ageSeconds" "duration")}}>Age</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "queueAgeWatchlist" "updatedAt" "date")}}>Updated</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.queueAgeWatchlist as |item|}}
                <tr>
                  <td>
                    <div class="mg-stats__mini-title">{{item.title}}</div>
                    <div class="mg-stats__mini-code">{{item.publicId}}</div>
                  </td>
                  <td>{{item.uploader}}</td>
                  <td><span class="mg-stats__badge">{{item.typeLabel}}</span></td>
                  <td><span class="mg-stats__badge">{{item.statusLabel}}</span></td>
                  <td>{{item.ageLabel}}</td>
                  <td>{{item.updatedLabel}}</td>
                </tr>
              {{else}}
                <tr><td colspan="6">No active queue items found.</td></tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Metadata completeness</h2>
              <p class="mg-stats__muted">Coverage of fields that help discovery, processing diagnostics and playback quality.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.metadataCoverageRows as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No metadata coverage data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Incomplete metadata candidates</h2>
              <p class="mg-stats__muted">Items missing practical metadata used for discovery or processing review.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "incompleteMedia" "title" "text")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "incompleteMedia" "statusLabel" "text")}}>Status</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "incompleteMedia" "issueCount" "number")}}>Issues</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "incompleteMedia" "updatedAt" "date")}}>Updated</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.incompleteMedia as |item|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{item.title}}</div>
                      <div class="mg-stats__mini-code">{{item.publicId}}</div>
                    </td>
                    <td><span class={{item.statusClass}}>{{item.statusLabel}}</span></td>
                    <td>
                      <div class="mg-stats__mini-title">{{item.issueCountLabel}} issue(s)</div>
                      <div class="mg-stats__meta">{{item.issuesLabel}}</div>
                    </td>
                    <td>{{item.updatedLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="4">No incomplete metadata candidates found.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Storage efficiency by type</h2>
              <p class="mg-stats__muted">Original versus processed storage totals grouped by media type.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByType" "label" "text")}}>Type</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByType" "count" "number")}}>Items</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByType" "originalBytes" "bytes")}}>Original</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByType" "processedBytes" "bytes")}}>Processed</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByType" "changeBytes" "bytes")}}>Change</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.storageEfficiencyByType as |row|}}
                  <tr>
                    <td>{{row.label}}</td>
                    <td>{{row.countLabel}}</td>
                    <td>{{row.originalLabel}}</td>
                    <td>{{row.processedLabel}}</td>
                    <td>{{row.changeLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No storage efficiency data by type available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Storage efficiency by storage location</h2>
              <p class="mg-stats__muted">Original versus processed storage totals grouped by configured storage location.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByBackend" "label" "text")}}>Location</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByBackend" "count" "number")}}>Items</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByBackend" "originalBytes" "bytes")}}>Original</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByBackend" "processedBytes" "bytes")}}>Processed</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "storageByBackend" "changeBytes" "bytes")}}>Change</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.storageEfficiencyByBackend as |row|}}
                  <tr>
                    <td>{{row.label}}</td>
                    <td>{{row.countLabel}}</td>
                    <td>{{row.originalLabel}}</td>
                    <td>{{row.processedLabel}}</td>
                    <td>{{row.changeLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No storage efficiency data by storage location available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Largest processed media</h2>
            <p class="mg-stats__muted">Largest processed files, useful for storage review and processing profile decisions.</p>
          </div>
        </div>
        <div class="mg-stats__table-wrap">
          <table class="mg-stats__table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "title" "text")}}>Media</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "uploader" "text")}}>Uploader</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "typeLabel" "text")}}>Type</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "storageLabel" "text")}}>Storage</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "originalBytes" "bytes")}}>Original</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "processedBytes" "bytes")}}>Processed</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "changeBytes" "bytes")}}>Change</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "ratioValue" "number")}}>Ratio</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "largestProcessedMedia" "createdAt" "date")}}>Created</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.largestProcessedMedia as |item|}}
                <tr>
                  <td>
                    <div class="mg-stats__table-title">{{item.title}}</div>
                    <div class="mg-stats__table-code">{{item.publicId}}</div>
                  </td>
                  <td>{{item.uploader}}</td>
                  <td><span class="mg-stats__badge">{{item.typeLabel}}</span></td>
                  <td>{{item.storageLabel}}</td>
                  <td>{{item.originalLabel}}</td>
                  <td>{{item.processedLabel}}</td>
                  <td>{{item.changeLabel}}</td>
                  <td>{{item.ratioLabel}}</td>
                  <td class="mg-stats__table-meta">{{item.createdLabel}}</td>
                </tr>
              {{else}}
                <tr><td colspan="9">No large processed media data available.</td></tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Engagement quality</h2>
            <p class="mg-stats__muted">Rates that help distinguish high-volume usage from high-quality interaction.</p>
          </div>
        </div>
        <div class="mg-stats__kpi-grid">
          {{#each @controller.engagementRateCards as |card|}}
            <article class="mg-stats__card">
              <div class="mg-stats__kpi-label">{{card.label}}</div>
              <div class="mg-stats__kpi-value">{{card.value}}</div>
              <div class="mg-stats__meta">{{card.meta}}</div>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Rising content</h2>
              <p class="mg-stats__muted">Items with recent playbacks, likes or comments in the selected range.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "risingContent" "title" "text")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "risingContent" "playbacks" "number")}}>Plays</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "risingContent" "likes" "number")}}>Likes</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "risingContent" "comments" "number")}}>Comments</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "risingContent" "score" "number")}}>Score</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.risingContent as |item|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{item.title}}</div>
                      <div class="mg-stats__mini-code">{{item.publicId}}</div>
                    </td>
                    <td>{{item.playsLabel}}</td>
                    <td>{{item.likesLabel}}</td>
                    <td>{{item.commentsLabel}}</td>
                    <td>{{item.scoreLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No rising content found for this range.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Quiet ready media</h2>
              <p class="mg-stats__muted">Ready items in the selected range without views, likes or comments.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "quietReadyMedia" "title" "text")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "quietReadyMedia" "uploader" "text")}}>Uploader</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "quietReadyMedia" "typeLabel" "text")}}>Type</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "quietReadyMedia" "createdAt" "date")}}>Created</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.quietReadyMedia as |item|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{item.title}}</div>
                      <div class="mg-stats__mini-code">{{item.publicId}}</div>
                    </td>
                    <td>{{item.uploader}}</td>
                    <td><span class="mg-stats__badge">{{item.typeLabel}}</span></td>
                    <td>{{item.createdLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="4">No quiet ready media found.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Delivery and HLS integrity</h2>
            <p class="mg-stats__muted">Playback receipt coverage and HLS variant distribution for the selected range.</p>
          </div>
        </div>
        <div class="mg-stats__kpi-grid">
          {{#each @controller.deliveryReceiptCards as |card|}}
            <article class="mg-stats__card">
              <div class="mg-stats__kpi-label">{{card.label}}</div>
              <div class="mg-stats__kpi-value">{{card.value}}</div>
              <div class="mg-stats__meta">{{card.meta}}</div>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>HLS variants</h2>
              <p class="mg-stats__muted">Variant labels recorded on playback sessions.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.hlsVariantRows as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No HLS variant data available.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Missing delivery receipts</h2>
              <p class="mg-stats__muted">Recent playback sessions missing HLS receipt fields.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "missingDeliveryReceipts" "title" "text")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "missingDeliveryReceipts" "user" "text")}}>User</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "missingDeliveryReceipts" "variant" "text")}}>Variant</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "missingDeliveryReceipts" "missingCount" "number")}}>Missing</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "missingDeliveryReceipts" "playedAt" "date")}}>Played</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.missingDeliveryReceipts as |row|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{row.title}}</div>
                      <div class="mg-stats__mini-code">{{row.publicId}}</div>
                    </td>
                    <td>{{row.user}}</td>
                    <td>{{row.variant}}</td>
                    <td>{{row.missingLabel}}</td>
                    <td>{{row.playedLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No missing receipt records found.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Stale low-engagement media</h2>
            <p class="mg-stats__muted">Older ready items with almost no interaction, useful for cleanup or featuring decisions.</p>
          </div>
        </div>
        <div class="mg-stats__table-wrap">
          <table class="mg-stats__mini-table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "title" "text")}}>Media</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "uploader" "text")}}>Uploader</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "typeLabel" "text")}}>Type</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "views" "number")}}>Views</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "likes" "number")}}>Likes</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "comments" "number")}}>Comments</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "staleReadyMedia" "createdAt" "date")}}>Created</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.staleReadyMedia as |item|}}
                <tr>
                  <td>
                    <div class="mg-stats__mini-title">{{item.title}}</div>
                    <div class="mg-stats__mini-code">{{item.publicId}}</div>
                  </td>
                  <td>{{item.uploader}}</td>
                  <td><span class="mg-stats__badge">{{item.typeLabel}}</span></td>
                  <td>{{item.viewsLabel}}</td>
                  <td>{{item.likesLabel}}</td>
                  <td>{{item.commentsLabel}}</td>
                  <td>{{item.createdLabel}}</td>
                </tr>
              {{else}}
                <tr><td colspan="7">No stale low-engagement media found.</td></tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Moderation health</h2>
              <p class="mg-stats__muted">Combined media and comment report status.</p>
            </div>
          </div>
          <div class="mg-stats__moderation-card-list">
            {{#each @controller.moderationRows as |row|}}
              <div class="mg-stats__moderation-card">
                <span class="mg-stats__row-label">{{row.label}}</span>
                <span class="mg-stats__moderation-card-value">{{row.value}}</span>
              </div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Log categories</h2>
              <p class="mg-stats__muted">Operational events captured by the module.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.logCategoryBreakdown as |row|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.countLabel}} · {{row.shareLabel}}</span>
                </div>
                <div class="mg-stats__bar-track" aria-hidden="true">
                  <span class="mg-stats__bar-fill is-soft" style={{row.barStyle}}></span>
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No log category data available.</div>
            {{/each}}
          </div>
        </article>
      </section>

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Top uploaders</h2>
              <p class="mg-stats__muted">Users creating the most media in the selected range.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topUploaders" "username" "text")}}>User</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topUploaders" "uploads" "number")}}>Uploads</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topUploaders" "ready" "number")}}>Ready</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topUploaders" "failed" "number")}}>Failed</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topUploaders" "storageBytes" "bytes")}}>Storage</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.topUploaders as |user|}}
                  <tr>
                    <td>
                      <div class="mg-stats__mini-title">{{user.username}}</div>
                      <div class="mg-stats__meta">Latest: {{user.latestLabel}}</div>
                    </td>
                    <td>{{user.uploadsLabel}}</td>
                    <td>{{user.readyLabel}}</td>
                    <td>{{user.failedLabel}}</td>
                    <td>{{user.storageLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="5">No uploader data available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Top viewers</h2>
              <p class="mg-stats__muted">Users with the most playback sessions in the selected range.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topViewers" "username" "text")}}>User</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topViewers" "playbacks" "number")}}>Plays</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topViewers" "uniqueMedia" "number")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topViewers" "latestAt" "date")}}>Latest</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.topViewers as |user|}}
                  <tr>
                    <td><div class="mg-stats__mini-title">{{user.username}}</div></td>
                    <td>{{user.playbacksLabel}}</td>
                    <td>{{user.uniqueMediaLabel}}</td>
                    <td>{{user.latestLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="4">No viewer data available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Top commenters</h2>
              <p class="mg-stats__muted">Users adding the most comments in the selected range.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topCommenters" "username" "text")}}>User</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topCommenters" "comments" "number")}}>Comments</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topCommenters" "uniqueMedia" "number")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topCommenters" "latestAt" "date")}}>Latest</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.topCommenters as |user|}}
                  <tr>
                    <td><div class="mg-stats__mini-title">{{user.username}}</div></td>
                    <td>{{user.commentsLabel}}</td>
                    <td>{{user.uniqueMediaLabel}}</td>
                    <td>{{user.latestLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="4">No commenter data available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Top likers</h2>
              <p class="mg-stats__muted">Users giving the most media likes in the selected range.</p>
            </div>
          </div>
          <div class="mg-stats__table-wrap">
            <table class="mg-stats__mini-table">
              <thead>
                <tr>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topLikers" "username" "text")}}>User</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topLikers" "likes" "number")}}>Likes</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topLikers" "uniqueMedia" "number")}}>Media</button></th>
                  <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topLikers" "latestAt" "date")}}>Latest</button></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.topLikers as |user|}}
                  <tr>
                    <td><div class="mg-stats__mini-title">{{user.username}}</div></td>
                    <td>{{user.likesLabel}}</td>
                    <td>{{user.uniqueMediaLabel}}</td>
                    <td>{{user.latestLabel}}</td>
                  </tr>
                {{else}}
                  <tr><td colspan="4">No liker data available.</td></tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <section class="mg-stats__three-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Recent processing failures</h2>
              <p class="mg-stats__muted">Newest failed items and their stored processing error.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.recentFailures as |item|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{item.title}}</span>
                  <span class="mg-stats__badge">{{item.typeLabel}}</span>
                </div>
                <div class="mg-stats__mini-code">{{item.publicId}}</div>
                <div class="mg-stats__meta">Uploader: {{item.uploader}} · Updated: {{item.updatedLabel}}</div>
                <div>{{item.errorMessage}}</div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No failed items found.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Most reported media</h2>
              <p class="mg-stats__muted">Media items with the most direct file reports.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.mostReportedMedia as |item|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{item.title}}</span>
                  <span class="mg-stats__row-value">{{item.openReportsLabel}} open / {{item.totalReportsLabel}} total</span>
                </div>
                <div class="mg-stats__mini-code">{{item.publicId}}</div>
                <div class="mg-stats__meta">
                  {{item.mediaReportsLabel}} media reports · {{item.statusLabel}}
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No reported media found.</div>
            {{/each}}
          </div>
        </article>

        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Comment report hotspots</h2>
              <p class="mg-stats__muted">Media items accumulating the most comment reports.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.mostReportedCommentMedia as |item|}}
              <div class="mg-stats__breakdown-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{item.title}}</span>
                  <span class="mg-stats__row-value">{{item.openReportsLabel}} open / {{item.totalReportsLabel}} total</span>
                </div>
                <div class="mg-stats__mini-code">{{item.publicId}}</div>
                <div class="mg-stats__meta">
                  {{item.commentReportsLabel}} comment reports · {{item.statusLabel}}
                </div>
              </div>
            {{else}}
              <div class="mg-stats__empty">No comment report hotspots found.</div>
            {{/each}}
          </div>
        </article>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Processing queue watchlist</h2>
            <p class="mg-stats__muted">Oldest queued or processing items, useful when jobs appear stuck.</p>
          </div>
        </div>
        <div class="mg-stats__table-wrap">
          <table class="mg-stats__mini-table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "processingQueue" "title" "text")}}>Media</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "processingQueue" "uploader" "text")}}>Uploader</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "processingQueue" "typeLabel" "text")}}>Type</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "processingQueue" "statusLabel" "text")}}>Status</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "processingQueue" "updatedAt" "date")}}>Updated</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.processingQueue as |item|}}
                <tr>
                  <td>
                    <div class="mg-stats__mini-title">{{item.title}}</div>
                    <div class="mg-stats__mini-code">{{item.publicId}}</div>
                  </td>
                  <td>{{item.uploader}}</td>
                  <td>{{item.typeLabel}}</td>
                  <td><span class="mg-stats__badge">{{item.statusLabel}}</span></td>
                  <td>{{item.updatedLabel}}</td>
                </tr>
              {{else}}
                <tr><td colspan="5">No queued or processing items found.</td></tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

      <section class="mg-stats__panel">
        <div class="mg-stats__panel-header">
          <div class="mg-stats__panel-copy">
            <h2>Top content</h2>
            <p class="mg-stats__muted">Most visible items by current views, likes and comments.</p>
          </div>
        </div>

        <div class="mg-stats__table-wrap">
          <table class="mg-stats__table">
            <thead>
              <tr>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "title" "text")}}>Media</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "uploader" "text")}}>Uploader</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "typeLabel" "text")}}>Type</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "statusLabel" "text")}}>Status</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "views" "number")}}>Views</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "playbacks" "number")}}>Plays</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "likes" "number")}}>Likes</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "comments" "number")}}>Comments</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "reports" "number")}}>Reports</button></th>
                <th><button type="button" class="mg-stats__sort-button" {{on "click" (fn @controller.toggleSort "topContent" "createdAt" "date")}}>Created</button></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.decoratedTopContent as |item|}}
                <tr>
                  <td>
                    <div class="mg-stats__table-title">{{item.title}}</div>
                    <div class="mg-stats__table-code">{{item.publicId}}</div>
                  </td>
                  <td>{{item.uploader}}</td>
                  <td><span class="mg-stats__badge">{{item.typeLabel}}</span></td>
                  <td><span class="mg-stats__badge">{{item.statusLabel}}</span></td>
                  <td>{{item.viewsLabel}}</td>
                  <td>{{item.playsLabel}}</td>
                  <td>{{item.likesLabel}}</td>
                  <td>{{item.commentsLabel}}</td>
                  <td>{{item.reportsLabel}}</td>
                  <td class="mg-stats__table-meta">{{item.createdLabel}}</td>
                </tr>
              {{else}}
                <tr>
                  <td colspan="10">No content available.</td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      </section>

    </div>
  </template>
);
