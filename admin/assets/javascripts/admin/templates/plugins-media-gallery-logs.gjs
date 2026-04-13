import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
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

      .media-gallery-admin-logs h1,
      .media-gallery-admin-logs h2,
      .media-gallery-admin-logs h3,
      .media-gallery-admin-logs p {
        margin: 0;
      }

      .mg-logs__panel {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        padding: 1rem 1.125rem;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-logs__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-logs__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__filters {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.9rem;
        align-items: end;
      }

      .mg-logs__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-logs__field.is-search {
        grid-column: 1 / -1;
      }

      .mg-logs__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-logs__field input,
      .mg-logs__field select {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        min-height: 42px;
      }

      .mg-logs__filters-footer,
      .mg-logs__header-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
        align-items: center;
      }

      .mg-logs__filters-footer {
        justify-content: space-between;
        margin-top: 1rem;
      }

      .mg-logs__summary-grid {
        display: grid;
        grid-template-columns: repeat(6, minmax(0, 1fr));
        gap: 0.9rem;
      }

      .mg-logs__summary-card {
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
        padding: 0.9rem;
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
      }

      .mg-logs__summary-card.is-warning {
        background: var(--tertiary-very-low);
        border-color: var(--tertiary-low);
      }

      .mg-logs__summary-card.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
      }

      .mg-logs__summary-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-logs__summary-value {
        font-size: 1.55rem;
        font-weight: 700;
        line-height: 1.1;
      }

      .mg-logs__insights-grid {
        display: grid;
        grid-template-columns: minmax(0, 1.15fr) minmax(320px, 0.85fr);
        gap: 1rem;
      }

      .mg-logs__bars {
        display: grid;
        grid-template-columns: repeat(24, minmax(0, 1fr));
        gap: 0.35rem;
        align-items: end;
        min-height: 118px;
        margin-top: 0.75rem;
      }

      .mg-logs__bar {
        display: flex;
        flex-direction: column;
        align-items: stretch;
        justify-content: flex-end;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-logs__bar-fill {
        width: 100%;
        border-radius: 999px;
        background: var(--tertiary);
        min-height: 8px;
      }

      .mg-logs__bar-label {
        font-size: 10px;
        color: var(--mg-muted);
        writing-mode: vertical-rl;
        transform: rotate(180deg);
        white-space: nowrap;
      }

      .mg-logs__top-list {
        display: grid;
        gap: 0.65rem;
        margin-top: 0.75rem;
      }

      .mg-logs__top-row {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.75rem;
        align-items: center;
        padding: 0.7rem 0.8rem;
        border-radius: 14px;
        background: var(--mg-surface-alt);
        border: 1px solid var(--mg-border);
      }

      .mg-logs__table-wrap {
        overflow: auto;
      }

      .mg-logs__table {
        width: 100%;
        border-collapse: separate;
        border-spacing: 0;
      }

      .mg-logs__table th,
      .mg-logs__table td {
        padding: 0.8rem 0.7rem;
        border-bottom: 1px solid var(--mg-border);
        text-align: left;
        vertical-align: top;
      }

      .mg-logs__table th {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
        position: sticky;
        top: 0;
        background: var(--mg-surface);
        z-index: 1;
      }

      .mg-logs__event-meta,
      .mg-logs__event-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
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

      .mg-logs__badge.is-info {
        background: var(--primary-very-low);
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

      .mg-logs__details {
        margin-top: 0.55rem;
      }

      .mg-logs__details summary {
        cursor: pointer;
        color: var(--tertiary);
      }

      .mg-logs__details pre {
        margin: 0.6rem 0 0;
        padding: 0.75rem;
        background: var(--primary-very-low);
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        white-space: pre-wrap;
        word-break: break-word;
        font-size: var(--font-down-1);
      }

      .mg-logs__notice {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--mg-border);
      }

      .mg-logs__notice.is-error {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      @media (max-width: 1100px) {
        .mg-logs__summary-grid,
        .mg-logs__filters,
        .mg-logs__insights-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 800px) {
        .mg-logs__summary-grid,
        .mg-logs__filters,
        .mg-logs__insights-grid {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-logs">
      <div class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div>
            <h1>{{i18n "admin.media_gallery.logs.title"}}</h1>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.description"}}</p>
          </div>
          <div class="mg-logs__header-actions">
            <a class="btn" href="/admin/plugins/media-gallery">{{i18n "admin.media_gallery.logs.back_to_overview"}}</a>
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.refreshLogs}}>
              {{#if @controller.isLoading}}
                {{i18n "admin.media_gallery.logs.refreshing"}}
              {{else}}
                {{i18n "admin.media_gallery.logs.refresh"}}
              {{/if}}
            </button>
          </div>
        </div>

        <form {{on "submit" @controller.submitFilters}}>
          <div class="mg-logs__filters">
            <div class="mg-logs__field is-search">
              <label>{{i18n "admin.media_gallery.logs.search_label"}}</label>
              <input type="text" value={{@controller.query}} placeholder={{i18n "admin.media_gallery.logs.search_placeholder"}} {{on "input" @controller.updateQuery}} />
            </div>

            <div class="mg-logs__field">
              <label>{{i18n "admin.media_gallery.logs.severity_label"}}</label>
              <select value={{@controller.severity}} {{on "change" @controller.updateSeverity}}>
                {{#each @controller.severityOptions as |option|}}
                  <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-logs__field">
              <label>{{i18n "admin.media_gallery.logs.event_type_label"}}</label>
              <select value={{@controller.eventType}} {{on "change" @controller.updateEventType}}>
                {{#each @controller.eventTypeOptions as |option|}}
                  <option value={{option.value}} selected={{option.selected}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-logs__field">
              <label>{{i18n "admin.media_gallery.logs.time_window_label"}}</label>
              <select value={{@controller.hours}} {{on "change" @controller.updateHours}}>
                <option value="24">Last 24 hours</option>
                <option value="72">Last 72 hours</option>
                <option value="168">Last 7 days</option>
                <option value="336">Last 14 days</option>
                <option value="720">Last 30 days</option>
              </select>
            </div>

            <div class="mg-logs__field">
              <label>{{i18n "admin.media_gallery.logs.limit_label"}}</label>
              <select value={{@controller.limit}} {{on "change" @controller.updateLimit}}>
                <option value="50">50</option>
                <option value="100">100</option>
                <option value="150">150</option>
                <option value="250">250</option>
              </select>
            </div>
          </div>

          <div class="mg-logs__filters-footer">
            <div class="mg-logs__muted">
              {{i18n "admin.media_gallery.logs.filters_help"}}
              {{#if @controller.lastLoadedAt}}
                · {{i18n "admin.media_gallery.logs.last_loaded"}} {{@controller.lastLoadedLabel}}
              {{/if}}
            </div>
            <div class="mg-logs__header-actions">
              <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.resetFilters}}>{{i18n "admin.media_gallery.logs.reset"}}</button>
              <button class="btn btn-primary" type="submit" disabled={{@controller.isLoading}}>{{i18n "admin.media_gallery.logs.apply"}}</button>
            </div>
          </div>
        </form>
      </div>

      {{#if @controller.error}}
        <div class="mg-logs__notice is-error">{{@controller.error}}</div>
      {{/if}}

      <div class="mg-logs__summary-grid">
        {{#each @controller.summaryCards as |card|}}
          <div class="mg-logs__summary-card is-{{card.tone}}">
            <div class="mg-logs__summary-label">{{card.label}}</div>
            <div class="mg-logs__summary-value">{{card.value}}</div>
          </div>
        {{/each}}
      </div>

      <div class="mg-logs__insights-grid">
        <div class="mg-logs__panel">
          <div class="mg-logs__panel-header">
            <div>
              <h2>{{i18n "admin.media_gallery.logs.activity_title"}}</h2>
              <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.activity_description"}}</p>
            </div>
          </div>
          <div class="mg-logs__bars">
            {{#each @controller.hourlyBars as |bar|}}
              <div class="mg-logs__bar">
                <div class="mg-logs__bar-fill" style={{bar.style}}></div>
                <div class="mg-logs__bar-label">{{bar.label}}</div>
              </div>
            {{/each}}
          </div>
        </div>

        <div class="mg-logs__panel">
          <div class="mg-logs__panel-header">
            <div>
              <h2>{{i18n "admin.media_gallery.logs.top_events_title"}}</h2>
              <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.top_events_description"}}</p>
            </div>
          </div>
          <div class="mg-logs__top-list">
            {{#if @controller.topEventTypes.length}}
              {{#each @controller.topEventTypes as |entry|}}
                <div class="mg-logs__top-row">
                  <div>{{entry.event_type}}</div>
                  <div class="mg-logs__badge">{{entry.count}}</div>
                </div>
              {{/each}}
            {{else}}
              <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_top_events"}}</div>
            {{/if}}
          </div>
        </div>
      </div>

      <div class="mg-logs__panel">
        <div class="mg-logs__panel-header">
          <div>
            <h2>{{i18n "admin.media_gallery.logs.recent_events_title"}}</h2>
            <p class="mg-logs__muted">{{i18n "admin.media_gallery.logs.recent_events_description"}}</p>
          </div>
        </div>

        {{#if @controller.hasEvents}}
          <div class="mg-logs__table-wrap">
            <table class="mg-logs__table">
              <thead>
                <tr>
                  <th>{{i18n "admin.media_gallery.logs.time_column"}}</th>
                  <th>{{i18n "admin.media_gallery.logs.event_column"}}</th>
                  <th>{{i18n "admin.media_gallery.logs.user_column"}}</th>
                  <th>{{i18n "admin.media_gallery.logs.media_column"}}</th>
                  <th>{{i18n "admin.media_gallery.logs.request_column"}}</th>
                  <th>{{i18n "admin.media_gallery.logs.details_column"}}</th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.decoratedEvents as |event|}}
                  <tr>
                    <td>
                      <div class="mg-logs__event-meta">
                        <strong>{{event.createdLabel}}</strong>
                        <span class="mg-logs__muted">{{event.category}}</span>
                      </div>
                    </td>
                    <td>
                      <div class="mg-logs__event-copy">
                        <div style="display:flex; gap:0.45rem; flex-wrap:wrap; align-items:center;">
                          <span class="mg-logs__badge {{event.severityClass}}">{{event.severityLabel}}</span>
                          <strong>{{event.eventLabel}}</strong>
                        </div>
                        {{#if event.message}}
                          <span class="mg-logs__muted">{{event.message}}</span>
                        {{/if}}
                        {{#if event.overlay_code}}
                          <span class="mg-logs__muted">Overlay {{event.overlay_code}}</span>
                        {{/if}}
                        {{#if event.fingerprint_id}}
                          <span class="mg-logs__muted">Fingerprint {{event.fingerprint_id}}</span>
                        {{/if}}
                      </div>
                    </td>
                    <td>
                      <div class="mg-logs__event-copy">
                        <strong>{{event.userLabel}}</strong>
                        {{#if event.username}}
                          <span class="mg-logs__muted">@{{event.username}}</span>
                        {{/if}}
                        {{#if event.ip}}
                          <span class="mg-logs__muted">{{event.ip}}</span>
                        {{/if}}
                      </div>
                    </td>
                    <td>
                      <div class="mg-logs__event-copy">
                        <strong>{{event.mediaLabel}}</strong>
                        {{#if event.media_public_id}}
                          <span class="mg-logs__muted">{{event.media_public_id}}</span>
                        {{/if}}
                      </div>
                    </td>
                    <td>
                      <div class="mg-logs__event-copy">
                        <strong>{{event.method}}</strong>
                        <span class="mg-logs__muted">{{event.path}}</span>
                        {{#if event.request_id}}
                          <span class="mg-logs__muted">Request {{event.request_id}}</span>
                        {{/if}}
                      </div>
                    </td>
                    <td>
                      {{#if event.hasDetails}}
                        <details class="mg-logs__details">
                          <summary>{{i18n "admin.media_gallery.logs.show_details"}}</summary>
                          <pre>{{event.details_pretty}}</pre>
                        </details>
                      {{else}}
                        <span class="mg-logs__muted">—</span>
                      {{/if}}
                    </td>
                  </tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        {{else}}
          <div class="mg-logs__muted">{{i18n "admin.media_gallery.logs.no_results"}}</div>
        {{/if}}
      </div>
    </div>
  </template>
);
