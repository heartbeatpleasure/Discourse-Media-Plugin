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
      .media-gallery-admin-logs h3 {
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

      .mg-logs__panel-header,
      .mg-logs__actions,
      .mg-logs__toolbar,
      .mg-logs__event-header,
      .mg-logs__event-header-main,
      .mg-logs__event-header-side,
      .mg-logs__event-chip-row,
      .mg-logs__event-topline,
      .mg-logs__summary-row,
      .mg-logs__search-help {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
      }

      .mg-logs__panel-header,
      .mg-logs__summary-row {
        align-items: flex-start;
        justify-content: space-between;
      }

      .mg-logs__panel-copy,
      .mg-logs__field,
      .mg-logs__event-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-logs__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__field {
        gap: 0.35rem;
      }

      .mg-logs__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-logs__search-box {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        min-height: 42px;
        padding: 0.55rem 0.8rem;
      }

      .mg-logs__toolbar {
        align-items: end;
        margin-top: 1rem;
      }

      .mg-logs__search-grow {
        flex: 1 1 520px;
        min-width: 280px;
      }

      .mg-logs__search-help {
        justify-content: space-between;
        align-items: center;
        margin-top: 1rem;
      }

      .mg-logs__stats {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
        gap: 1rem;
      }

      .mg-logs__stat {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
        padding: 0.85rem 0.95rem;
      }

      .mg-logs__stat-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__stat-value {
        margin-top: 0.3rem;
        font-size: 1.45rem;
        font-weight: 700;
        line-height: 1.1;
      }

      .mg-logs__top-list,
      .mg-logs__event-list {
        display: grid;
        gap: 0.85rem;
      }

      .mg-logs__top-item,
      .mg-logs__event {
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      .mg-logs__top-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        padding: 0.8rem 0.95rem;
      }

      .mg-logs__top-item-title {
        font-weight: 600;
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
      }

      .mg-logs__badge.is-info {
        background: var(--primary-very-low);
        color: var(--primary-high);
        border-color: var(--primary-low);
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

      .mg-logs__event {
        padding: 1rem;
      }

      .mg-logs__event-header {
        justify-content: space-between;
        align-items: flex-start;
        gap: 1rem;
      }

      .mg-logs__event-header-main,
      .mg-logs__event-header-side,
      .mg-logs__event-copy {
        min-width: 0;
      }

      .mg-logs__event-header-side {
        justify-content: flex-start;
      }

      .mg-logs__event-title {
        font-size: 1.05rem;
        font-weight: 700;
        line-height: 1.3;
        overflow-wrap: anywhere;
      }

      .mg-logs__event-chip-row,
      .mg-logs__event-topline {
        align-items: center;
      }

      .mg-logs__event-body {
        margin-top: 0.9rem;
        display: grid;
        gap: 0.85rem;
      }

      .mg-logs__summary-grid {
        display: grid;
        gap: 0.65rem;
      }

      .mg-logs__summary-row {
        padding: 0.35rem 0;
        border-top: 1px solid var(--primary-low);
      }

      .mg-logs__summary-grid .mg-logs__summary-row:first-child {
        padding-top: 0;
        border-top: 0;
      }

      .mg-logs__summary-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        min-width: 0;
      }

      .mg-logs__summary-value {
        text-align: right;
        font-weight: 600;
        min-width: 0;
        overflow-wrap: anywhere;
      }

      .mg-logs__message {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--secondary);
        padding: 0.8rem 0.9rem;
      }

      .mg-logs__message-label {
        display: block;
        margin-bottom: 0.25rem;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-logs__details {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--primary-very-low);
        overflow: hidden;
      }

      .mg-logs__details summary {
        cursor: pointer;
        padding: 0.85rem 1rem;
        font-weight: 700;
        list-style: none;
      }

      .mg-logs__details summary::-webkit-details-marker {
        display: none;
      }

      .mg-logs__details[open] summary {
        border-bottom: 1px solid var(--mg-border);
      }

      .mg-logs__json {
        margin: 0;
        padding: 1rem;
        max-height: 360px;
        overflow: auto;
        white-space: pre-wrap;
        background: transparent;
        font-size: 0.9em;
      }

      .mg-logs__empty {
        border: 1px dashed var(--mg-border);
        border-radius: 14px;
        padding: 1rem;
        text-align: center;
        color: var(--mg-muted);
        background: var(--mg-surface-alt);
      }

      .mg-logs__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 900px) {
        .mg-logs__panel-header,
        .mg-logs__event-header,
        .mg-logs__summary-row,
        .mg-logs__search-help {
          flex-direction: column;
          align-items: stretch;
        }

        .mg-logs__summary-value {
          text-align: left;
        }
      }
    </style>

    <div class="media-gallery-admin-logs">
      <section class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div class="mg-logs__panel-copy">
            <h1>{{i18n "admin.media_gallery.logs.title"}}</h1>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.description"}}</p>
          </div>

          <div class="mg-logs__actions">
            <a class="btn" href="/admin/plugins/media-gallery">{{i18n "admin.media_gallery.logs.back_to_overview"}}</a>
            <button
              class="btn btn-primary"
              type="button"
              disabled={{@controller.isLoading}}
              {{on "click" @controller.loadLogs}}
            >
              {{if @controller.isLoading (i18n "admin.media_gallery.logs.refreshing") (i18n "admin.media_gallery.logs.refresh")}}
            </button>
          </div>
        </div>

        <div class="mg-logs__toolbar">
          <div class="mg-logs__field mg-logs__search-grow">
            <label for="media-gallery-admin-logs-search">{{i18n "admin.media_gallery.logs.search_label"}}</label>
            <input
              id="media-gallery-admin-logs-search"
              class="mg-logs__search-box"
              type="text"
              value={{@controller.query}}
              placeholder={{i18n "admin.media_gallery.logs.search_placeholder"}}
              {{on "input" @controller.updateQuery}}
            />
          </div>
        </div>

        <div class="mg-logs__search-help">
          <div class="mg-logs__actions">
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.search}}>
              Search
            </button>
            <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.clearSearch}}>
              Clear
            </button>
          </div>

          {{#if @controller.lastLoadedAt}}
            <span class="mg-logs__muted">{{i18n "admin.media_gallery.logs.last_loaded"}} {{@controller.lastLoadedLabel}}</span>
          {{else}}
            <span class="mg-logs__muted">Click refresh to load the latest log events.</span>
          {{/if}}
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-logs__flash">{{@controller.error}}</div>
      {{/if}}

      <section class="mg-logs__stats">
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Shown rows</div>
          <div class="mg-logs__stat-value">{{@controller.shownRows}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Filtered total</div>
          <div class="mg-logs__stat-value">{{@controller.filteredCount}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Last 24h</div>
          <div class="mg-logs__stat-value">{{@controller.last24hCount}}</div>
        </div>
        <div class="mg-logs__stat">
          <div class="mg-logs__stat-label">Unique users</div>
          <div class="mg-logs__stat-value">{{@controller.uniqueUsers}}</div>
        </div>
      </section>

      <section class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div class="mg-logs__panel-copy">
            <h2>{{i18n "admin.media_gallery.logs.top_events_title"}}</h2>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.top_events_description"}}</p>
          </div>
        </div>

        {{#if @controller.decoratedTopEventTypes.length}}
          <div class="mg-logs__top-list">
            {{#each @controller.decoratedTopEventTypes as |entry|}}
              <div class="mg-logs__top-item">
                <span class="mg-logs__top-item-title">{{entry.label}}</span>
                <span class="mg-logs__badge">{{entry.count}}</span>
              </div>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-logs__empty">{{i18n "admin.media_gallery.logs.no_top_events"}}</div>
        {{/if}}
      </section>

      <section class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div class="mg-logs__panel-copy">
            <h2>{{i18n "admin.media_gallery.logs.recent_events_title"}}</h2>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.recent_events_description"}}</p>
          </div>
        </div>

        {{#if @controller.decoratedEvents.length}}
          <div class="mg-logs__event-list">
            {{#each @controller.decoratedEvents as |event|}}
              <article class="mg-logs__event">
                <div class="mg-logs__event-header">
                  <div class="mg-logs__event-copy">
                    <div class="mg-logs__event-topline">
                      <span class={{event.severityBadgeClass}}>{{event.severityLabel}}</span>
                      <span class="mg-logs__badge">{{event.categoryLabel}}</span>
                    </div>
                    <div class="mg-logs__event-title">{{event.eventLabel}}</div>
                  </div>

                  <div class="mg-logs__event-header-side">
                    <span class="mg-logs__muted">{{event.createdLabel}}</span>
                  </div>
                </div>

                <div class="mg-logs__event-body">
                  <div class="mg-logs__summary-grid">
                    <div class="mg-logs__summary-row">
                      <span class="mg-logs__summary-label">User</span>
                      <span class="mg-logs__summary-value">{{event.userLabel}}</span>
                    </div>
                    <div class="mg-logs__summary-row">
                      <span class="mg-logs__summary-label">Media</span>
                      <span class="mg-logs__summary-value">{{event.mediaLabel}}</span>
                    </div>
                    <div class="mg-logs__summary-row">
                      <span class="mg-logs__summary-label">Request</span>
                      <span class="mg-logs__summary-value">{{event.requestLabel}}</span>
                    </div>
                    {{#if event.ip}}
                      <div class="mg-logs__summary-row">
                        <span class="mg-logs__summary-label">IP</span>
                        <span class="mg-logs__summary-value">{{event.ip}}</span>
                      </div>
                    {{/if}}
                    {{#if event.overlayCode}}
                      <div class="mg-logs__summary-row">
                        <span class="mg-logs__summary-label">Overlay</span>
                        <span class="mg-logs__summary-value">{{event.overlayCode}}</span>
                      </div>
                    {{/if}}
                    {{#if event.fingerprintId}}
                      <div class="mg-logs__summary-row">
                        <span class="mg-logs__summary-label">Fingerprint</span>
                        <span class="mg-logs__summary-value">{{event.fingerprintId}}</span>
                      </div>
                    {{/if}}
                  </div>

                  {{#if event.message}}
                    <div class="mg-logs__message">
                      <span class="mg-logs__message-label">Message</span>
                      <div>{{event.message}}</div>
                    </div>
                  {{/if}}

                  {{#if event.detailsPreview}}
                    <details class="mg-logs__details">
                      <summary>Diagnostics JSON</summary>
                      <pre class="mg-logs__json">{{event.detailsPreview}}</pre>
                    </details>
                  {{/if}}
                </div>
              </article>
            {{/each}}
          </div>
        {{else if @controller.hasLoadedOnce}}
          <div class="mg-logs__empty">{{i18n "admin.media_gallery.logs.no_results"}}</div>
        {{else}}
          <div class="mg-logs__empty">No data loaded yet.</div>
        {{/if}}
      </section>
    </div>
  </template>
);
