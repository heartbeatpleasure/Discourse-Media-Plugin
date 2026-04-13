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
      .media-gallery-admin-logs h2 {
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

      .mg-logs__header,
      .mg-logs__actions,
      .mg-logs__search-row,
      .mg-logs__stats,
      .mg-logs__event-meta {
        display: flex;
        gap: 0.75rem;
        flex-wrap: wrap;
        align-items: center;
      }

      .mg-logs__header {
        justify-content: space-between;
      }

      .mg-logs__muted {
        color: var(--mg-muted);
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

      .mg-logs__stats {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
      }

      .mg-logs__stat {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
        padding: 0.85rem 0.9rem;
      }

      .mg-logs__stat-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__stat-value {
        font-size: 1.45rem;
        font-weight: 700;
        line-height: 1.1;
        margin-top: 0.25rem;
      }

      .mg-logs__event-list {
        display: grid;
        gap: 0.85rem;
      }

      .mg-logs__event {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
        padding: 0.9rem;
        display: grid;
        gap: 0.55rem;
      }

      .mg-logs__event-title {
        display: flex;
        gap: 0.5rem;
        align-items: center;
        flex-wrap: wrap;
      }

      .mg-logs__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.22rem 0.58rem;
        font-size: var(--font-down-1);
        line-height: 1.2;
        white-space: nowrap;
        background: var(--primary-very-low);
        color: var(--primary-high);
        border: 1px solid var(--primary-low);
      }

      .mg-logs__top-list {
        display: grid;
        gap: 0.65rem;
      }

      .mg-logs__top-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--mg-surface-alt);
        padding: 0.7rem 0.8rem;
      }

      .mg-logs__details {
        margin: 0;
        padding: 0.7rem;
        background: var(--primary-very-low);
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        white-space: pre-wrap;
        word-break: break-word;
        font-size: var(--font-down-1);
        max-height: 16rem;
        overflow: auto;
      }

      .mg-logs__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 800px) {
        .mg-logs__stats {
          grid-template-columns: 1fr 1fr;
        }
      }

      @media (max-width: 600px) {
        .mg-logs__stats {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-logs">
      <div class="mg-logs__panel">
        <div class="mg-logs__header">
          <div>
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

        <div class="mg-logs__search-row" style="margin-top: 1rem;">
          <input class="mg-logs__search-box" type="text" value={{@controller.query}} placeholder={{i18n "admin.media_gallery.logs.search_placeholder"}} {{on "input" @controller.updateQuery}} />
        </div>

        <div class="mg-logs__actions" style="margin-top: 0.9rem;">
          <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.search}}>Search</button>
          <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.clearSearch}}>Clear</button>
          {{#if @controller.lastLoadedAt}}
            <span class="mg-logs__muted">{{i18n "admin.media_gallery.logs.last_loaded"}} {{@controller.lastLoadedLabel}}</span>
          {{else}}
            <span class="mg-logs__muted">Click refresh to load the latest log events.</span>
          {{/if}}
        </div>
      </div>

      {{#if @controller.error}}
        <div class="mg-logs__flash">{{@controller.error}}</div>
      {{/if}}

      <div class="mg-logs__stats">
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
      </div>

      <div class="mg-logs__panel">
        <h2>{{i18n "admin.media_gallery.logs.top_events_title"}}</h2>
        <p class="mg-logs__muted" style="margin-top: 0.25rem; margin-bottom: 0.9rem;">{{i18n "admin.media_gallery.logs.top_events_description"}}</p>

        {{#if @controller.topEventTypes.length}}
          <div class="mg-logs__top-list">
            {{#each @controller.topEventTypes as |entry|}}
              <div class="mg-logs__top-item">
                <span>{{entry.event_type}}</span>
                <span class="mg-logs__badge">{{entry.count}}</span>
              </div>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_top_events"}}</div>
        {{/if}}
      </div>

      <div class="mg-logs__panel">
        <h2>{{i18n "admin.media_gallery.logs.recent_events_title"}}</h2>
        <p class="mg-logs__muted" style="margin-top: 0.25rem; margin-bottom: 0.9rem;">{{i18n "admin.media_gallery.logs.recent_events_description"}}</p>

        {{#if @controller.decoratedEvents.length}}
          <div class="mg-logs__event-list">
            {{#each @controller.decoratedEvents as |event|}}
              <article class="mg-logs__event">
                <div class="mg-logs__event-title">
                  <span class="mg-logs__badge">{{event.severityLabel}}</span>
                  <strong>{{event.eventLabel}}</strong>
                  <span class="mg-logs__muted">{{event.createdLabel}}</span>
                </div>
                <div class="mg-logs__event-meta">
                  <span class="mg-logs__muted">{{event.category}}</span>
                  <span class="mg-logs__muted">User: {{event.userLabel}}</span>
                  <span class="mg-logs__muted">Media: {{event.mediaLabel}}</span>
                </div>
                {{#if event.message}}<div>{{event.message}}</div>{{/if}}
                <div class="mg-logs__muted">{{event.requestLabel}}</div>
                {{#if event.ip}}<div class="mg-logs__muted">IP: {{event.ip}}</div>{{/if}}
                {{#if event.overlayCode}}<div class="mg-logs__muted">Overlay: {{event.overlayCode}}</div>{{/if}}
                {{#if event.fingerprintId}}<div class="mg-logs__muted">Fingerprint: {{event.fingerprintId}}</div>{{/if}}
                {{#if event.detailsPreview}}<pre class="mg-logs__details">{{event.detailsPreview}}</pre>{{/if}}
              </article>
            {{/each}}
          </div>
        {{else if @controller.hasLoadedOnce}}
          <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_results"}}</div>
        {{else}}
          <div class="mg-logs__muted">No data loaded yet.</div>
        {{/if}}
      </div>
    </div>
  </template>
);
