import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-logs {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-logs p,
      .media-gallery-admin-logs h1,
      .media-gallery-admin-logs h2,
      .media-gallery-admin-logs h3,
      .media-gallery-admin-logs label {
        margin: 0;
      }

      .mg-logs__panel {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-logs__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-logs__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-logs__actions,
      .mg-logs__filters-footer,
      .mg-logs__badge-row {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
        align-items: center;
      }

      .mg-logs__filters-footer {
        justify-content: space-between;
        margin-top: 1rem;
      }

      .mg-logs__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__filter-form {
        display: grid;
        gap: 0.9rem;
      }

      .mg-logs__search-box,
      .mg-logs__field input,
      .mg-logs__field select {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        min-height: 42px;
        padding: 0.55rem 0.8rem;
      }

      .mg-logs__filters {
        display: grid;
        grid-template-columns: repeat(5, minmax(0, 1fr));
        gap: 0.9rem;
      }

      .mg-logs__field {
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
        min-width: 0;
      }

      .mg-logs__field label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-logs__field-hint {
        color: var(--mg-muted);
        font-size: var(--font-down-2);
      }

      .mg-logs__stats {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 1rem;
      }

      .mg-logs__stat {
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface);
        padding: 0.95rem 1rem;
      }

      .mg-logs__stat-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__stat-value {
        font-size: 1.45rem;
        font-weight: 700;
        line-height: 1.1;
        margin-top: 0.35rem;
      }

      .mg-logs__top-list,
      .mg-logs__event-list {
        display: grid;
        gap: 0.85rem;
      }

      .mg-logs__top-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
        padding: 0.8rem 0.9rem;
      }

      .mg-logs__event {
        border: 1px solid var(--mg-border);
        border-radius: 18px;
        background: var(--mg-surface-alt);
        padding: 1rem;
        display: grid;
        gap: 0.95rem;
      }

      .mg-logs__event-header {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.85rem;
        align-items: start;
      }

      .mg-logs__event-heading {
        display: flex;
        flex-direction: column;
        gap: 0.55rem;
        min-width: 0;
      }

      .mg-logs__event-name {
        font-size: var(--font-up-2);
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-logs__event-time {
        color: var(--mg-muted);
        font-size: var(--font-up-1);
        font-weight: 500;
        text-align: right;
        white-space: nowrap;
      }

      .mg-logs__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.25rem 0.65rem;
        font-size: var(--font-down-1);
        line-height: 1.2;
        white-space: nowrap;
        background: var(--primary-very-low);
        color: var(--primary-high);
        border: 1px solid var(--primary-low);
        font-weight: 600;
      }

      .mg-logs__badge.is-info {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-logs__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-logs__badge.is-warning {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-logs__badge.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-logs__badge.is-neutral.is-soft {
        background: var(--secondary);
      }

      .mg-logs__badge.is-soft {
        opacity: 0.92;
      }

      .mg-logs__facts {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.85rem;
      }

      .mg-logs__fact {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--secondary);
        padding: 0.9rem 1rem;
        min-width: 0;
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
      }

      .mg-logs__fact.is-wide {
        grid-column: 1 / -1;
      }

      .mg-logs__fact-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-logs__fact-value {
        color: var(--primary-high);
        font-size: var(--font-up-1);
        font-weight: 700;
        line-height: 1.35;
        overflow-wrap: anywhere;
        word-break: break-word;
      }

      .mg-logs__fact-value--mono {
        font-family: var(--font-family-monospace);
        font-size: var(--font-0);
        font-weight: 600;
      }

      .mg-logs__fact-meta {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
        word-break: break-word;
      }

      .mg-logs__accordion {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--secondary);
        overflow: hidden;
      }

      .mg-logs__accordion-summary {
        cursor: pointer;
        padding: 0.95rem 1rem;
        font-size: var(--font-up-1);
        font-weight: 700;
        list-style: revert;
      }

      .mg-logs__details {
        margin: 0;
        padding: 0 1rem 1rem;
        white-space: pre-wrap;
        word-break: break-word;
        font-size: var(--font-down-1);
        max-height: 20rem;
        overflow: auto;
      }

      .mg-logs__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 1100px) {
        .mg-logs__filters {
          grid-template-columns: repeat(3, minmax(0, 1fr));
        }
      }

      @media (max-width: 900px) {
        .mg-logs__stats {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .mg-logs__event-header,
        .mg-logs__filters-footer {
          grid-template-columns: 1fr;
          display: grid;
        }

        .mg-logs__event-time {
          text-align: left;
          white-space: normal;
        }
      }

      @media (max-width: 700px) {
        .mg-logs__filters,
        .mg-logs__facts,
        .mg-logs__stats {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-logs">
      <div class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div class="mg-logs__panel-copy">
            <h1>{{i18n "admin.media_gallery.logs.title"}}</h1>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.description"}}</p>
          </div>
          <div class="mg-logs__actions">
            <a class="btn" href="/admin/plugins/media-gallery">{{i18n "admin.media_gallery.logs.back_to_overview"}}</a>
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.loadLogs}}>
              {{if @controller.isLoading (i18n "admin.media_gallery.logs.refreshing") (i18n "admin.media_gallery.logs.refresh")}}
            </button>
          </div>
        </div>

        <form class="mg-logs__filter-form" {{on "submit" @controller.search}}>
          <input
            class="mg-logs__search-box"
            type="text"
            value={{@controller.query}}
            placeholder={{i18n "admin.media_gallery.logs.search_placeholder"}}
            {{on "input" @controller.updateQuery}}
          />

          <div class="mg-logs__filters">
            <div class="mg-logs__field">
              <label>Severity</label>
              <select value={{@controller.severityFilter}} {{on "change" @controller.updateSeverityFilter}}>
                <option value="all">All severities</option>
                <option value="info">Info</option>
                <option value="success">Success</option>
                <option value="warning">Warning</option>
                <option value="danger">Error / danger</option>
              </select>
            </div>

            <div class="mg-logs__field">
              <label>Category</label>
              <input
                type="text"
                value={{@controller.categoryFilter}}
                placeholder="playback, security, forensics…"
                {{on "input" @controller.updateCategoryFilter}}
              />
              <div class="mg-logs__field-hint">Partial match</div>
            </div>

            <div class="mg-logs__field">
              <label>Event type</label>
              <input
                type="text"
                value={{@controller.eventTypeFilter}}
                placeholder="play_token_issued…"
                {{on "input" @controller.updateEventTypeFilter}}
              />
              <div class="mg-logs__field-hint">Partial match</div>
            </div>

            <div class="mg-logs__field">
              <label>Time window</label>
              <select value={{@controller.hoursFilter}} {{on "change" @controller.updateHoursFilter}}>
                <option value="24">Last 24 hours</option>
                <option value="72">Last 3 days</option>
                <option value="168">Last 7 days</option>
                <option value="720">Last 30 days</option>
                <option value="2160">Last 90 days</option>
              </select>
            </div>

            <div class="mg-logs__field">
              <label>Limit</label>
              <select value={{@controller.limit}} {{on "change" @controller.updateLimit}}>
                <option value="25">25</option>
                <option value="50">50</option>
                <option value="100">100</option>
                <option value="250">250</option>
              </select>
            </div>
          </div>

          <div class="mg-logs__filters">
            <div class="mg-logs__field">
              <label>Sort</label>
              <select value={{@controller.sortBy}} {{on "change" @controller.updateSort}}>
                <option value="created_at_desc">Newest first</option>
                <option value="created_at_asc">Oldest first</option>
              </select>
            </div>
          </div>

          <div class="mg-logs__filters-footer">
            <div class="mg-logs__actions">
              <button class="btn btn-primary" type="submit" disabled={{@controller.isLoading}}>
                {{if @controller.isLoading "Searching…" "Search"}}
              </button>
              <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.clearFilters}}>Clear</button>
            </div>

            <div class="mg-logs__muted">
              {{@controller.searchInfo}}
              {{#if @controller.lastLoadedAt}}
                · {{i18n "admin.media_gallery.logs.last_loaded"}} {{@controller.lastLoadedLabel}}
              {{/if}}
            </div>
          </div>
        </form>
      </div>

      {{#if @controller.error}}
        <div class="mg-logs__flash">{{@controller.error}}</div>
      {{/if}}

      <div class="mg-logs__stats">
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Visible rows</div>
          <div class="mg-logs__stat-value">{{@controller.shownRows}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">All matches</div>
          <div class="mg-logs__stat-value">{{@controller.filteredCount}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Last 24 hours</div>
          <div class="mg-logs__stat-value">{{@controller.last24hCount}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Unique users</div>
          <div class="mg-logs__stat-value">{{@controller.uniqueUsers}}</div>
        </div>
      </div>

      <div class="mg-logs__panel">
        <div class="mg-logs__panel-copy" style="margin-bottom: 0.9rem;">
          <h2>{{i18n "admin.media_gallery.logs.top_events_title"}}</h2>
          <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.top_events_description"}}</p>
        </div>

        {{#if @controller.decoratedTopEventTypes.length}}
          <div class="mg-logs__top-list">
            {{#each @controller.decoratedTopEventTypes as |entry|}}
              <div class="mg-logs__top-item">
                <span>{{entry.eventLabel}}</span>
                <span class="mg-logs__badge">{{entry.count}}</span>
              </div>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_top_events"}}</div>
        {{/if}}
      </div>

      <div class="mg-logs__panel">
        <div class="mg-logs__panel-copy" style="margin-bottom: 0.9rem;">
          <h2>{{i18n "admin.media_gallery.logs.recent_events_title"}}</h2>
          <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.recent_events_description"}}</p>
        </div>

        {{#if @controller.decoratedEvents.length}}
          <div class="mg-logs__event-list">
            {{#each @controller.decoratedEvents as |event|}}
              <article class="mg-logs__event">
                <div class="mg-logs__event-header">
                  <div class="mg-logs__event-heading">
                    <h3 class="mg-logs__event-name">{{event.eventLabel}}</h3>
                    <div class="mg-logs__badge-row">
                      <span class={{event.severityBadgeClass}}>{{event.severityLabel}}</span>
                      <span class={{event.categoryBadgeClass}}>{{event.categoryLabel}}</span>
                    </div>
                  </div>
                  <div class="mg-logs__event-time">{{event.createdLabel}}</div>
                </div>

                <div class="mg-logs__facts">
                  {{#each event.facts as |fact|}}
                    <div class="mg-logs__fact {{if fact.isWide 'is-wide'}}">
                      <div class="mg-logs__fact-label">{{fact.label}}</div>
                      <div class={{fact.valueClass}}>{{fact.value}}</div>
                      {{#if fact.meta}}
                        <div class="mg-logs__fact-meta">{{fact.meta}}</div>
                      {{/if}}
                    </div>
                  {{/each}}
                </div>

                {{#if event.detailsPreview}}
                  <details class="mg-logs__accordion">
                    <summary class="mg-logs__accordion-summary">Diagnostics JSON</summary>
                    <pre class="mg-logs__details">{{event.detailsPreview}}</pre>
                  </details>
                {{/if}}
              </article>
            {{/each}}
          </div>
        {{else}}
          {{#if @controller.hasLoadedOnce}}
            <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_results"}}</div>
          {{else}}
            <div class="mg-logs__muted">Use the filters above and click search to load log events.</div>
          {{/if}}
        {{/if}}
      </div>
    </div>
  </template>
);
