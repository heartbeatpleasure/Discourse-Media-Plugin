import RouteTemplate from "ember-route-template";
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
        min-width: 160px;
        min-height: 42px;
        box-sizing: border-box;
        border: 1px solid var(--mg-stats-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0 0.85rem;
      }

      .mg-stats__kpi-grid,
      .mg-stats__two-column,
      .mg-stats__three-column,
      .mg-stats__breakdown-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-stats__kpi-grid {
        grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      }

      .mg-stats__two-column {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-stats__three-column {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }

      .mg-stats__breakdown-grid {
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
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

      @media (max-width: 900px) {
        .mg-stats__hero,
        .mg-stats__panel-header {
          flex-direction: column;
        }

        .mg-stats__two-column,
        .mg-stats__three-column {
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
              Select the grouping used for trend charts. Counts are based on existing Media Gallery records.
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
            <label for="mg-statistics-limit">Buckets</label>
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

          <button type="button" class="btn" {{on "click" @controller.refresh}} disabled={{@controller.isLoading}}>
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
              <p class="mg-stats__muted">Distribution across video, audio and image items.</p>
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

      <section class="mg-stats__two-column">
        <article class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Moderation health</h2>
              <p class="mg-stats__muted">Combined media and comment report status.</p>
            </div>
          </div>
          <div class="mg-stats__compact-list">
            {{#each @controller.moderationRows as |row|}}
              <div class="mg-stats__moderation-row">
                <div class="mg-stats__row-header">
                  <span class="mg-stats__row-label">{{row.label}}</span>
                  <span class="mg-stats__row-value">{{row.value}}</span>
                </div>
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
                <th>Media</th>
                <th>Uploader</th>
                <th>Type</th>
                <th>Status</th>
                <th>Views</th>
                <th>Plays</th>
                <th>Likes</th>
                <th>Comments</th>
                <th>Reports</th>
                <th>Created</th>
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

      {{#if @controller.notes}}
        <section class="mg-stats__panel">
          <div class="mg-stats__panel-header">
            <div class="mg-stats__panel-copy">
              <h2>Notes and next iterations</h2>
              <p class="mg-stats__muted">Implementation notes for interpreting this first dashboard version.</p>
            </div>
          </div>
          <ul class="mg-stats__note-list">
            {{#each @controller.notes as |note|}}
              <li>{{note}}</li>
            {{/each}}
          </ul>
        </section>
      {{/if}}
    </div>
  </template>
);
