import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-reports {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-reports p,
      .media-gallery-admin-reports h1,
      .media-gallery-admin-reports h2,
      .media-gallery-admin-reports h3 {
        margin: 0;
      }

      .mg-reports__panel {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-reports__grid {
        display: grid;
        grid-template-columns: minmax(0, 1.05fr) minmax(360px, 0.95fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-reports__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-reports__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-reports__filters {
        display: grid;
        grid-template-columns: minmax(0, 1fr) 180px 140px auto auto;
        gap: 0.75rem;
        align-items: end;
      }

      .mg-reports__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-reports__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-reports__field input,
      .mg-reports__field select,
      .mg-reports__field textarea {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        min-height: 42px;
      }

      .mg-reports__field textarea {
        min-height: 112px;
        resize: vertical;
        padding-top: 0.75rem;
      }

      .mg-reports__list,
      .mg-reports__summary-grid,
      .mg-reports__history-list {
        display: grid;
        gap: 0.85rem;
      }

      .mg-reports__report-card {
        display: grid;
        grid-template-columns: 96px minmax(0, 1fr) auto;
        gap: 0.8rem;
        align-items: start;
        padding: 0.9rem;
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      .mg-reports__report-card.is-selected {
        border-color: var(--tertiary);
        box-shadow: inset 0 0 0 1px var(--tertiary);
        background: var(--secondary);
      }

      .mg-reports__thumb,
      .mg-reports__thumb-placeholder {
        width: 96px;
        aspect-ratio: 16 / 9;
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
      }

      .mg-reports__thumb {
        object-fit: cover;
      }

      .mg-reports__thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--mg-muted);
        text-align: center;
        font-size: var(--font-down-1);
        padding: 0.35rem;
        box-sizing: border-box;
      }

      .mg-reports__copy {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-reports__title {
        font-size: 1.08rem;
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-reports__subtitle,
      .mg-reports__message {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-reports__message {
        padding: 0.45rem 0.55rem;
        border-radius: 10px;
        background: var(--secondary);
        border: 1px solid var(--mg-border);
        color: var(--primary);
      }

      .mg-reports__badge-row,
      .mg-reports__actions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
        align-items: center;
      }

      .mg-reports__badge {
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

      .mg-reports__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-reports__badge.is-warning {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-reports__badge.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-reports__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(185px, 1fr));
      }

      .mg-reports__summary-card,
      .mg-reports__section {
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
        padding: 0.95rem;
      }

      .mg-reports__summary-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-reports__summary-value {
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .mg-reports__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--mg-border);
        margin-bottom: 1rem;
      }

      .mg-reports__flash.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-reports__flash.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-reports__empty-state {
        display: grid;
        gap: 0.35rem;
        padding: 1.1rem;
        border: 1px dashed var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      @media (max-width: 1100px) {
        .mg-reports__grid,
        .mg-reports__filters {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 760px) {
        .mg-reports__report-card {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-reports">
      <h1>{{i18n "admin.media_gallery.reports.title"}}</h1>
      <p>{{i18n "admin.media_gallery.reports.description"}}</p>

      <section class="mg-reports__panel">
        <div class="mg-reports__panel-header">
          <div>
            <h2>Find reports</h2>
            <p class="mg-reports__muted">Search reports by media, reporter, reason, or public ID.</p>
          </div>
        </div>

        <div class="mg-reports__filters">
          <div class="mg-reports__field">
            <label>Search</label>
            <input type="text" value={{@controller.searchQuery}} placeholder="Search reports…" {{on "input" @controller.onSearchInput}} />
          </div>

          <div class="mg-reports__field">
            <label>Status</label>
            <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusFilterChange}}>
              <option value="open">Open</option>
              <option value="accepted">Accepted</option>
              <option value="rejected">Rejected</option>
              <option value="resolved">Resolved</option>
              <option value="all">All</option>
            </select>
          </div>

          <div class="mg-reports__field">
            <label>Limit</label>
            <select value={{@controller.limit}} {{on "change" @controller.onLimitChange}}>
              <option value="20">20</option>
              <option value="50">50</option>
              <option value="100">100</option>
              <option value="200">200</option>
            </select>
          </div>

          <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isLoading}}>
            {{if @controller.isLoading "Loading…" "Search"}}
          </button>
          <button class="btn" type="button" {{on "click" @controller.resetFilters}} disabled={{@controller.isLoading}}>Reset</button>
        </div>

        {{#if @controller.loadError}}
          <div class="mg-reports__flash is-danger" style="margin-top: 1rem;">{{@controller.loadError}}</div>
        {{/if}}
      </section>

      <div class="mg-reports__grid">
        <section class="mg-reports__panel">
          <div class="mg-reports__panel-header">
            <div>
              <h2>Reports</h2>
              <span class="mg-reports__muted">Open a report to review the media snapshot and take action.</span>
            </div>
          </div>

          {{#if @controller.decoratedReports.length}}
            <div class="mg-reports__list">
              {{#each @controller.decoratedReports key="id" as |report|}}
                <article class="mg-reports__report-card {{if report.isSelected "is-selected"}}">
                  {{#if report.media.thumbnail_url}}
                    <img class="mg-reports__thumb" loading="lazy" src={{report.media.thumbnail_url}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-reports__thumb-placeholder">No thumbnail</div>
                  {{/if}}

                  <div class="mg-reports__copy">
                    <div class="mg-reports__title">{{report.mediaTitle}}</div>
                    <div class="mg-reports__subtitle">{{report.mediaPublicId}} · reported {{report.createdAtLabel}}</div>
                    <div class="mg-reports__subtitle">Reporter: {{report.reporterLabel}}</div>
                    <div class="mg-reports__badge-row">
                      <span class="mg-reports__badge {{report.statusBadgeClass}}">{{report.statusLabel}}</span>
                      <span class="mg-reports__badge">{{report.reason_label}}</span>
                      <span class="mg-reports__badge {{report.hiddenBadgeClass}}">{{report.hiddenLabel}}</span>
                      <span class="mg-reports__badge {{report.assetBadgeClass}}">{{report.assetLabel}}</span>
                      {{#if report.auto_hidden}}
                        <span class="mg-reports__badge is-warning">Auto-hidden</span>
                      {{/if}}
                    </div>
                    {{#if report.message}}
                      <div class="mg-reports__message">{{report.message}}</div>
                    {{/if}}
                  </div>

                  <button class="btn" type="button" {{on "click" (fn @controller.selectReport report)}}>
                    {{if report.isSelected "Selected" "Open"}}
                  </button>
                </article>
              {{/each}}
            </div>
          {{else}}
            <div class="mg-reports__empty-state">
              <strong>No reports found</strong>
              <span class="mg-reports__muted">Try another status or search term.</span>
            </div>
          {{/if}}
        </section>

        <section class="mg-reports__panel">
          <div class="mg-reports__panel-header">
            <div>
              <h2>Selected report</h2>
              <p class="mg-reports__muted">Accept, hide, delete asset files, reject, or resolve without action.</p>
            </div>
          </div>

          {{#if @controller.noticeMessage}}
            <div class={{@controller.noticeClass}}>{{@controller.noticeMessage}}</div>
          {{/if}}

          {{#if @controller.hasSelectedReport}}
            <div class="mg-reports__summary-grid">
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Media</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.mediaTitle}}</div>
              </div>
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Public ID</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.mediaPublicId}}</div>
              </div>
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Reporter</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.reporterLabel}}</div>
              </div>
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Reason</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.reason_label}}</div>
              </div>
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Status</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.statusLabel}}</div>
              </div>
              <div class="mg-reports__summary-card">
                <div class="mg-reports__summary-label">Decision</div>
                <div class="mg-reports__summary-value">{{@controller.selectedReport.decisionLabel}}</div>
              </div>
            </div>

            {{#if @controller.selectedReport.message}}
              <section class="mg-reports__section" style="margin-top: 1rem;">
                <h3>Reporter note</h3>
                <p style="margin-top: 0.5rem; white-space: pre-wrap; overflow-wrap: anywhere;">{{@controller.selectedReport.message}}</p>
              </section>
            {{/if}}

            <section class="mg-reports__section" style="margin-top: 1rem;">
              <h3>Media snapshot</h3>
              <p class="mg-reports__muted" style="margin-top: 0.3rem;">This snapshot is kept for audit even if the asset files are deleted.</p>
              <div class="mg-reports__summary-grid" style="margin-top: 1rem;">
                {{#each @controller.selectedSnapshotRows as |row|}}
                  <div class="mg-reports__summary-card">
                    <div class="mg-reports__summary-label">{{row.label}}</div>
                    <div class="mg-reports__summary-value">{{row.value}}</div>
                  </div>
                {{/each}}
              </div>
            </section>

            {{#if @controller.selectedIsOpen}}
              <section class="mg-reports__section" style="margin-top: 1rem;">
                <h3>Review action</h3>
                <div class="mg-reports__field" style="margin-top: 0.75rem;">
                  <label>Staff note</label>
                  <textarea value={{@controller.reviewNote}} placeholder="Optional note for the audit trail" {{on "input" @controller.onReviewNote}}></textarea>
                </div>

                <div class="mg-reports__actions" style="margin-top: 1rem;">
                  <button class="btn btn-danger" type="button" disabled={{@controller.reviewDisabled}} {{on "click" (fn @controller.reviewSelected "accept_hide")}}>
                    Accept / Hide asset
                  </button>
                  <button class="btn btn-danger" type="button" disabled={{@controller.reviewDisabled}} {{on "click" (fn @controller.reviewSelected "accept_delete_asset")}}>
                    Accept / Delete asset
                  </button>
                  <button class="btn" type="button" disabled={{@controller.reviewDisabled}} {{on "click" (fn @controller.reviewSelected "resolve")}}>
                    Resolve without action
                  </button>
                  <button class="btn" type="button" disabled={{@controller.reviewDisabled}} {{on "click" (fn @controller.reviewSelected "reject")}}>
                    Reject report
                  </button>
                </div>
              </section>
            {{else}}
              <section class="mg-reports__section" style="margin-top: 1rem;">
                <h3>Review completed</h3>
                <p class="mg-reports__muted" style="margin-top: 0.35rem;">
                  Reviewed {{@controller.selectedReport.reviewedAtLabel}} by {{@controller.selectedReport.reviewed_by_username}}.
                </p>
                {{#if @controller.selectedReport.review_note}}
                  <p style="margin-top: 0.75rem; white-space: pre-wrap; overflow-wrap: anywhere;">{{@controller.selectedReport.review_note}}</p>
                {{/if}}
              </section>
            {{/if}}
          {{else}}
            <div class="mg-reports__empty-state">
              <strong>No report selected</strong>
              <span class="mg-reports__muted">Choose a report from the list to review it here.</span>
            </div>
          {{/if}}
        </section>
      </div>
    </div>
  </template>
);
