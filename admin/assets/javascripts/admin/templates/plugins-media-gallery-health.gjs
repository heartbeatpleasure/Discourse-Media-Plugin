import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-health {
        --mg-health-surface: var(--secondary);
        --mg-health-surface-alt: var(--primary-very-low);
        --mg-health-border: var(--primary-low);
        --mg-health-muted: var(--primary-medium);
        --mg-health-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-health h1,
      .media-gallery-health h2,
      .media-gallery-health h3,
      .media-gallery-health p,
      .media-gallery-health ul {
        margin: 0;
      }

      .mg-health__panel {
        background: var(--mg-health-surface);
        border: 1px solid var(--mg-health-border);
        border-radius: var(--mg-health-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: visible;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-health__header,
      .mg-health__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-health__header-copy,
      .mg-health__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-health__muted,
      .mg-health__item-detail,
      .mg-health__example-subtitle,
      .mg-health__alert-label {
        color: var(--mg-health-muted);
        font-size: var(--font-down-1);
      }

      .mg-health__actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: flex-end;
        gap: 0.75rem;
      }

      .mg-health__summary-grid,
      .mg-health__sections,
      .mg-health__issue-list,
      .mg-health__example-list,
      .mg-health__alert-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-health__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      }

      .mg-health__summary-card,
      .mg-health__alert-card {
        background: var(--mg-health-surface-alt);
        border: 1px solid var(--mg-health-border);
        border-radius: 16px;
        padding: 0.9rem 1rem;
        min-width: 0;
      }

      .mg-health__alert-card {
        position: relative;
      }

      .mg-health__alert-card > .mg-health__info {
        position: absolute;
        right: 0.75rem;
        top: 0.75rem;
      }

      .mg-health__alert-card.has-help {
        padding-right: 2.75rem;
      }

      .mg-health__operational-card {
        position: relative;
        padding-right: 5.2rem;
      }

      .mg-health__operational-card > .mg-health__badge {
        position: absolute;
        top: 0.85rem;
        right: 0.85rem;
        margin: 0;
      }

      .mg-health__operational-card .mg-health__alert-value {
        margin-top: 0.2rem;
      }

      .mg-health__profile-list {
        display: grid;
        gap: 0.65rem;
        margin-top: 1rem;
      }

      .mg-health__profile-chips {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.5rem;
      }

      .mg-health__profile-chip {
        display: inline-flex;
        align-items: center;
        gap: 0.4rem;
        border: 1px solid var(--mg-health-border);
        border-radius: 999px;
        padding: 0.32rem 0.65rem;
        background: var(--mg-health-surface-alt);
        max-width: 100%;
      }

      .mg-health__profile-chip-name {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-health__profile-chip-meta {
        color: var(--mg-health-muted);
        font-size: var(--font-down-1);
      }

      .mg-health__toolbar {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
        align-items: end;
        margin-top: 0.85rem;
      }

      .mg-health__export-panel {
        margin-top: 1rem;
        border: 1px solid var(--mg-health-border);
        border-radius: 16px;
        background: var(--mg-health-surface-alt);
        padding: 0.95rem 1rem;
      }

      .mg-health__toolbar-field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: min(440px, 100%);
      }

      .mg-health__toolbar-field label {
        color: var(--mg-health-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
      }

      .mg-health__toolbar-field select,
      .mg-health__modal textarea,
      .mg-health__modal select {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--primary-low);
        border-radius: 10px;
        background: var(--secondary);
      }

      .mg-health__history-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
        gap: 0.75rem;
        margin-top: 1rem;
      }

      .mg-health__history-card {
        border: 1px solid var(--mg-health-border);
        border-radius: 14px;
        background: var(--mg-health-surface-alt);
        padding: 0.75rem;
        min-width: 0;
      }

      .mg-health__history-title {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem;
        font-weight: 700;
      }

      .mg-health__history-grid-small {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.4rem 0.65rem;
        margin-top: 0.65rem;
      }

      .mg-health__history-kv {
        min-width: 0;
      }

      .mg-health__history-kv-label {
        color: var(--mg-health-muted);
        font-size: var(--font-down-1);
      }

      .mg-health__history-kv-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-health__modal-backdrop {
        position: fixed;
        inset: 0;
        z-index: 1000;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 1rem;
        background: rgba(0, 0, 0, 0.42);
      }

      .mg-health__modal {
        width: min(760px, 100%);
        max-height: min(760px, calc(100vh - 2rem));
        overflow: auto;
        border-radius: 18px;
        background: var(--secondary);
        border: 1px solid var(--primary-low);
        box-shadow: 0 18px 70px rgba(0, 0, 0, 0.28);
        padding: 1.15rem 1.25rem;
      }

      .mg-health__modal-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 1rem;
      }

      .mg-health__modal-close {
        min-height: 0;
        padding: 0.25rem 0.55rem;
        font-size: 1.35rem;
        line-height: 1;
      }

      .mg-health__modal-form {
        display: grid;
        gap: 1rem;
      }

      .mg-health__modal-row {
        display: grid;
        grid-template-columns: 120px minmax(0, 1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-health__modal-row--compact {
        align-items: center;
      }

      .mg-health__modal-row .mg-health__alert-label {
        padding-top: 0.65rem;
        font-weight: 700;
      }

      .mg-health__modal-row--compact .mg-health__alert-label {
        padding-top: 0;
      }

      .mg-health__modal-field {
        min-width: 0;
      }

      .mg-health__modal-form textarea {
        min-height: 150px;
        resize: vertical;
        padding: 0.75rem 0.85rem;
      }

      .mg-health__modal-form select {
        max-width: 460px;
        min-height: 42px;
        padding: 0.55rem 0.7rem;
      }

      .mg-health__summary-card {
        position: relative;
        padding-right: 2.6rem;
      }

      .mg-health__summary-card > .mg-health__status-dot {
        position: absolute;
        right: 1rem;
        top: 1rem;
      }

      .mg-health__status-dot {
        display: inline-flex;
        width: 0.8rem;
        height: 0.8rem;
        border-radius: 999px;
        flex: 0 0 auto;
        border: 2px solid var(--secondary);
        box-shadow: 0 0 0 1px var(--primary-low);
        background: var(--primary-low-mid);
      }

      .mg-health__status-dot.is-success {
        background: var(--success);
        box-shadow: 0 0 0 1px var(--success-low-mid);
      }

      .mg-health__status-dot.is-warning {
        background: #d98700;
        box-shadow: 0 0 0 1px #ffc66d;
      }

      .mg-health__status-dot.is-danger {
        background: var(--danger);
        box-shadow: 0 0 0 1px var(--danger-low-mid);
      }

      .mg-health__status-row {
        display: inline-flex;
        align-items: center;
        gap: 0.45rem;
      }

      .mg-health__summary-label {
        color: var(--mg-health-muted);
        font-size: var(--font-down-1);
        margin-bottom: 0.25rem;
      }

      .mg-health__summary-value,
      .mg-health__alert-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-health__badge {
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

      .mg-health__badge.is-success,
      .mg-health__icon.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-health__badge.is-warning,
      .mg-health__icon.is-warning {
        background: #fff3d6;
        color: #9a5b00;
        border-color: #ffc66d;
      }

      .mg-health__badge.is-danger,
      .mg-health__icon.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-health__issue {
        display: grid;
        grid-template-columns: auto minmax(0, 1fr) auto;
        gap: 0.75rem;
        align-items: start;
        border-top: 1px solid var(--mg-health-border);
        padding-top: 0.85rem;
      }

      .mg-health__issue:first-child {
        border-top: 0;
        padding-top: 0;
      }

      .mg-health__icon {
        width: 1.8rem;
        height: 1.8rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        border: 1px solid var(--primary-low);
        font-weight: 700;
        line-height: 1;
      }

      .mg-health__issue-title {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.5rem;
        font-weight: 700;
      }

      .mg-health__issue-message {
        margin-top: 0.25rem;
        overflow-wrap: anywhere;
      }

      .mg-health__item-detail {
        margin-top: 0.25rem;
        overflow-wrap: anywhere;
      }

      .mg-health__examples {
        margin-top: 0.75rem;
        display: grid;
        gap: 0.5rem;
      }

      .mg-health__example {
        background: var(--primary-very-low);
        border: 1px solid var(--primary-low);
        border-radius: 12px;
        padding: 0.65rem 0.75rem;
        min-width: 0;
      }

      .mg-health__example-title {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-health__example-subtitle {
        margin-top: 0.2rem;
        overflow-wrap: anywhere;
      }

      .mg-health__example-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
        margin-top: 0.55rem;
      }

      .mg-health__example-actions .btn {
        font-size: var(--font-down-1);
        min-height: 0;
        padding: 0.35rem 0.6rem;
      }

      .mg-health__info {
        position: relative;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 1.35rem;
        height: 1.35rem;
        border-radius: 999px;
        border: 1px solid var(--primary-low-mid);
        color: var(--primary-high);
        background: var(--primary-very-low);
        font-size: var(--font-down-1);
        font-weight: 700;
        cursor: help;
        flex: 0 0 auto;
      }

      .mg-health__info-text {
        display: none;
        position: absolute;
        right: 0;
        top: calc(100% + 0.35rem);
        z-index: 5;
        width: min(360px, calc(100vw - 4rem));
        padding: 0.75rem 0.85rem;
        border-radius: 12px;
        border: 1px solid var(--primary-low);
        background: var(--secondary);
        color: var(--primary);
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16);
        font-weight: 400;
        line-height: 1.35;
      }

      .mg-health__info:hover .mg-health__info-text,
      .mg-health__info:focus .mg-health__info-text {
        display: block;
      }

      .mg-health__notice {
        border-radius: 12px;
        padding: 0.65rem 0.75rem;
        border: 1px solid var(--success-low-mid);
        background: var(--secondary);
        color: var(--success);
      }

      .mg-health__error {
        border-radius: 12px;
        padding: 0.75rem 0.85rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 760px) {
        .mg-health__header,
        .mg-health__panel-header {
          flex-direction: column;
        }

        .mg-health__actions {
          justify-content: flex-start;
        }

        .mg-health__issue {
          grid-template-columns: auto minmax(0, 1fr);
        }

        .mg-health__issue > .mg-health__badge {
          grid-column: 2;
          justify-self: start;
        }

        .mg-health__modal-row {
          grid-template-columns: 1fr;
          gap: 0.35rem;
        }

        .mg-health__modal-row .mg-health__alert-label {
          padding-top: 0;
        }
      }
    </style>

    <div class="media-gallery-health">
      <section class="mg-health__panel">
        <div class="mg-health__header">
          <div class="mg-health__header-copy">
            <h1>{{i18n "admin.media_gallery.health.title"}}</h1>
            <p class="mg-health__muted">{{i18n "admin.media_gallery.health.description"}}</p>
            <p class="mg-health__muted">Last checked: {{@controller.generatedAtLabel}}</p>
          </div>
          <div class="mg-health__actions">
            <span class="mg-health__status-row" title={{@controller.overallSeverityLabel}}>
              <span class="mg-health__status-dot {{@controller.overallBadgeClass}}"></span>
              <span>{{@controller.overallSeverityLabel}}</span>
            </span>
            <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.refresh}}>
              {{if @controller.isLoading "Loading…" "Refresh"}}
            </button>
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.runFullStorage}}>
              Run full storage check
            </button>
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.runReconciliation}}>
              Run storage reconciliation
            </button>
            <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.exportReconciliation}}>
              Export reconciliation
            </button>
            <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
          </div>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-health__error">{{@controller.error}}</div>
      {{/if}}

      {{#if @controller.notice}}
        <div class="mg-health__notice">{{@controller.notice}}</div>
      {{/if}}

      <section class="mg-health__summary-grid">
        {{#each @controller.summaryCards as |card|}}
          <article class="mg-health__summary-card">
            <div class="mg-health__summary-label">{{card.label}}</div>
            <div class="mg-health__summary-value">{{card.value}}</div>
            <span class="mg-health__status-dot {{card.badgeClass}}" title={{card.severityLabel}}></span>
          </article>
        {{/each}}
      </section>

      <section class="mg-health__panel">
        <div class="mg-health__panel-header">
          <div class="mg-health__panel-copy">
            <h2>Storage reconciliation</h2>
            <p class="mg-health__muted">Read-only reconciliation compares media records, manifests, and configured storage profiles. Cleanup is intentionally not available in this iteration.</p>
          </div>
          <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">Run reconciliation manually when you want to review missing assets, orphan candidates, deleted media leftovers, and invalid storage references. Export downloads the latest stored report as JSON.</span></span>
        </div>

        {{#if @controller.hasReconciliation}}
          <div class="mg-health__alert-grid" style="grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-top: 1rem;">
            {{#each @controller.reconciliationStatsRows as |row|}}
              <div class="mg-health__alert-card {{if row.help "has-help"}}">
                <div class="mg-health__alert-label">{{row.label}}</div>
                <div class="mg-health__alert-value">{{row.value}}</div>
                {{#if row.help}}
                  <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">{{row.help}}</span></span>
                {{/if}}
              </div>
            {{/each}}
          </div>

          {{#if @controller.hasReconciliationProfiles}}
            <div class="mg-health__profile-list">
              <div class="mg-health__alert-label">Checked storage profiles</div>

              {{#if @controller.hasReconciliationNamedProfiles}}
                <div class="mg-health__profile-chips">
                  {{#each @controller.reconciliationNamedProfiles as |profile|}}
                    <span class="mg-health__profile-chip">
                      <span class="mg-health__status-dot {{profile.statusClass}}" title={{profile.statusLabel}}></span>
                      <span class="mg-health__profile-chip-name">{{profile.displayName}}</span>
                      <span class="mg-health__profile-chip-meta">{{profile.objectsScannedLabel}} objects</span>
                      {{#if profile.truncated}}
                        <span class="mg-health__profile-chip-meta">limit reached</span>
                      {{/if}}
                    </span>
                  {{/each}}
                </div>
              {{/if}}

              <div class="mg-health__muted">{{@controller.reconciliationProfilesHelpText}}</div>
            </div>
          {{/if}}

          <div class="mg-health__export-panel">
            <div class="mg-health__alert-label">Export report</div>
            <div class="mg-health__toolbar">
              <div class="mg-health__toolbar-field">
                <label>Export category</label>
                <select value={{@controller.exportCategory}} disabled={{@controller.isLoading}} {{on "change" @controller.setExportCategory}}>
                  {{#each @controller.reconciliationExportCategories as |category|}}
                    <option value={{category.id}}>{{category.title}}</option>
                  {{/each}}
                </select>
              </div>
              <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.exportReconciliation}}>
                Export JSON
              </button>
              <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.exportReconciliationCsv}}>
                Export CSV
              </button>
            </div>
          </div>
        {{else}}
          <p class="mg-health__muted" style="margin-top: 1rem;">Storage reconciliation has not been run yet.</p>
        {{/if}}
      </section>

      {{#if @controller.hasReconciliationHistory}}
        <section class="mg-health__panel">
          <div class="mg-health__panel-header">
            <div class="mg-health__panel-copy">
              <h2>Reconciliation history</h2>
              <p class="mg-health__muted">Latest stored reconciliation runs. New and resolved counts compare each run with the previous run.</p>
            </div>
            <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">History is read-only and stored as lightweight summaries. It helps spot recurring or newly resolved storage issues without changing files.</span></span>
          </div>

          <div class="mg-health__history-grid">
            {{#each @controller.decoratedReconciliationHistory as |run|}}
              <article class="mg-health__history-card">
                <div class="mg-health__history-title">
                  <span>{{run.generatedAtLabel}}</span>
                  <span class="mg-health__status-dot {{run.badgeClass}}" title={{run.severityLabel}}></span>
                </div>
                {{#if run.generatedAtRelativeLabel}}
                  <div class="mg-health__muted" style="margin-top: 0.2rem;">{{run.generatedAtRelativeLabel}}</div>
                {{/if}}
                <div class="mg-health__history-grid-small">
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">Active</div>
                    <div class="mg-health__history-kv-value">{{run.activeFindingsLabel}}</div>
                  </div>
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">Ignored</div>
                    <div class="mg-health__history-kv-value">{{run.ignoredFindingsLabel}}</div>
                  </div>
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">New</div>
                    <div class="mg-health__history-kv-value">{{run.newFindingsLabel}}</div>
                  </div>
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">Resolved</div>
                    <div class="mg-health__history-kv-value">{{run.resolvedFindingsLabel}}</div>
                  </div>
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">Duration</div>
                    <div class="mg-health__history-kv-value">{{run.durationLabel}}</div>
                  </div>
                  <div class="mg-health__history-kv">
                    <div class="mg-health__history-kv-label">Objects</div>
                    <div class="mg-health__history-kv-value">{{run.objectsScannedLabel}}</div>
                  </div>
                </div>
                {{#if run.profilesLabel}}
                  <div class="mg-health__example-subtitle" style="margin-top: 0.65rem;">Profiles: {{run.profilesLabel}}</div>
                {{/if}}
                {{#if run.truncatedProfilesLabel}}
                  <div class="mg-health__example-subtitle" style="margin-top: 0.25rem;">Partial: {{run.truncatedProfilesLabel}}</div>
                {{/if}}
              </article>
            {{/each}}
          </div>
        </section>
      {{/if}}

      {{#if @controller.hasOperationalSafetyCards}}
        <section class="mg-health__panel">
          <div class="mg-health__panel-header">
            <div class="mg-health__panel-copy">
              <h2>Operational safety checks</h2>
              <p class="mg-health__muted">Read-only checks added for storage profile safety and stale Media Gallery temp/workspace cleanup.</p>
            </div>
            <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">These checks do not change files or settings. They summarize operational risks so admins can review storage configuration and old temporary workspaces.</span></span>
          </div>

          <div class="mg-health__alert-grid" style="grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); margin-top: 1rem;">
            {{#each @controller.operationalSafetyCards as |card|}}
              <article class="mg-health__alert-card mg-health__operational-card">
                <span class="mg-health__badge {{card.badgeClass}}">{{card.severityLabel}}</span>
                <div class="mg-health__alert-label">{{card.label}}</div>
                <div class="mg-health__alert-value">{{card.value}}</div>
                <p class="mg-health__muted" style="margin-top: 0.65rem;">{{card.detail}}</p>
              </article>
            {{/each}}
          </div>
        </section>
      {{/if}}

      {{#if @controller.hasAttentionIssues}}
        <section class="mg-health__panel">
          <div class="mg-health__panel-header">
            <div class="mg-health__panel-copy">
              <h2>Issues requiring attention</h2>
              <p class="mg-health__muted">These are the current warning or critical findings. Use the links and details below to investigate or fix them.</p>
            </div>
            <span class="mg-health__status-row" title={{@controller.overallSeverityLabel}}>
              <span class="mg-health__status-dot {{@controller.overallBadgeClass}}"></span>
              <span>{{@controller.overallSeverityLabel}}</span>
            </span>
          </div>

          <div class="mg-health__issue-list" style="margin-top: 1rem;">
            {{#each @controller.attentionIssues as |issue|}}
              <article class="mg-health__issue">
                <span class="mg-health__icon {{issue.iconClass}}">{{issue.icon}}</span>
                <div>
                  <div class="mg-health__issue-title">
                    <span>{{issue.label}}</span>
                    <span class="mg-health__badge">{{issue.sectionTitle}}</span>
                    {{#if issue.countLabel}}
                      <span class="mg-health__badge">{{issue.countLabel}}</span>
                    {{/if}}
                  </div>
                  <p class="mg-health__issue-message">{{issue.message}}</p>
                  {{#if issue.hasDetail}}
                    <p class="mg-health__item-detail">{{issue.detail}}</p>
                  {{/if}}
                  {{#if issue.hasExamples}}
                    <div class="mg-health__examples">
                      {{#each issue.examples as |example|}}
                        <div class="mg-health__example">
                          {{#if example.url}}
                            <a class="mg-health__example-title" href={{example.url}} target="_blank" rel="noopener noreferrer">{{example.title}}</a>
                          {{else}}
                            <div class="mg-health__example-title">{{example.title}}</div>
                          {{/if}}
                          {{#if example.subtitle}}
                            <div class="mg-health__example-subtitle">{{example.subtitle}}</div>
                          {{/if}}
                          {{#if example.hasDetail}}
                            <div class="mg-health__example-subtitle">{{example.detail}}</div>
                          {{/if}}
                          {{#if example.hasSuggestion}}
                            <div class="mg-health__example-subtitle"><strong>Suggested action:</strong> {{example.suggestion}}</div>
                          {{/if}}
                          <div class="mg-health__example-actions">
                            {{#if example.url}}
                              <a class="btn" href={{example.url}} target="_blank" rel="noopener noreferrer">Open in management</a>
                            {{/if}}
                            {{#if example.canIgnore}}
                              <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" (fn @controller.ignoreFinding issue example)}}>Ignore finding</button>
                            {{/if}}
                          </div>
                        </div>
                      {{/each}}
                    </div>
                  {{/if}}
                </div>
                <span class="mg-health__badge {{issue.badgeClass}}">{{issue.severityLabel}}</span>
              </article>
            {{/each}}
          </div>
        </section>
      {{/if}}

      {{#if @controller.hasIgnoredFindings}}
        <section class="mg-health__panel">
          <div class="mg-health__panel-header">
            <div class="mg-health__panel-copy">
              <h2>Ignored findings</h2>
              <p class="mg-health__muted">These findings no longer affect the health status. Restore them if they should be checked again.</p>
            </div>
            <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">Ignored storage findings are excluded from warning and critical status. They are not deleted; they are only suppressed for health reporting until an admin restores them.</span></span>
          </div>
          <div class="mg-health__examples" style="margin-top: 1rem;">
            {{#each @controller.ignoredFindings as |finding|}}
              <div class="mg-health__example">
                {{#if finding.url}}
                  <a class="mg-health__example-title" href={{finding.url}} target="_blank" rel="noopener noreferrer">{{finding.title}}</a>
                {{else}}
                  <div class="mg-health__example-title">{{finding.title}}</div>
                {{/if}}
                {{#if finding.subtitle}}
                  <div class="mg-health__example-subtitle">{{finding.subtitle}}</div>
                {{/if}}
                {{#if finding.reason}}
                  <div class="mg-health__example-subtitle">{{finding.reason}}</div>
                {{/if}}
                <div class="mg-health__example-subtitle">Expires: {{finding.expiresAtLabel}}</div>
                <div class="mg-health__example-actions">
                  {{#if finding.url}}
                    <a class="btn" href={{finding.url}} target="_blank" rel="noopener noreferrer">Open in management</a>
                  {{/if}}
                  <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" (fn @controller.unignoreFinding finding)}}>Stop ignoring</button>
                </div>
              </div>
            {{/each}}
          </div>
        </section>
      {{/if}}

      <section class="mg-health__panel">
        <div class="mg-health__panel-header">
          <div class="mg-health__panel-copy">
            <h2>Watchdog notifications</h2>
            <p class="mg-health__muted">Critical or warning health issues are deduplicated before admins are notified.</p>
          </div>
          <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">The scheduled watchdog runs hourly. It sends a group PM only when severity meets the configured threshold and the alert signature changed or the cooldown expired.</span></span>
        </div>
        <div class="mg-health__alert-grid" style="grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-top: 1rem;">
          {{#each @controller.alertStateRows as |row|}}
            <div class="mg-health__alert-card">
              <div class="mg-health__alert-label">{{row.label}}</div>
              <div class="mg-health__alert-value">{{row.value}}</div>
            </div>
          {{/each}}
        </div>
      </section>

      {{#if @controller.ignoreModalOpen}}
        <div class="mg-health__modal-backdrop">
          <div class="mg-health__modal" role="dialog" aria-modal="true">
            <div class="mg-health__modal-header">
              <div>
                <h2>Ignore finding</h2>
                <p class="mg-health__muted">Ignoring suppresses this finding from Health status. It does not delete or change any media files.</p>
              </div>
            </div>

            <div class="mg-health__modal-form">
              <div>
                <strong>{{@controller.ignoreTargetTitle}}</strong>
              </div>

              <div class="mg-health__modal-row">
                <label class="mg-health__alert-label" for="media-gallery-health-ignore-reason">Reason</label>
                <div class="mg-health__modal-field">
                  <textarea id="media-gallery-health-ignore-reason" value={{@controller.ignoreReason}} maxlength="500" {{on "input" @controller.setIgnoreReason}}></textarea>
                </div>
              </div>

              <div class="mg-health__modal-row mg-health__modal-row--compact">
                <label class="mg-health__alert-label" for="media-gallery-health-ignore-expiry">Expires</label>
                <div class="mg-health__modal-field">
                  <select id="media-gallery-health-ignore-expiry" value={{@controller.ignoreExpiresInDays}} {{on "change" @controller.setIgnoreExpiry}}>
                    <option value="0">Never</option>
                    <option value="7">In 7 days</option>
                    <option value="30">In 30 days</option>
                    <option value="90">In 90 days</option>
                    <option value="365">In 365 days</option>
                  </select>
                </div>
              </div>

              <div class="mg-health__actions">
                <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.cancelIgnoreFinding}}>Cancel</button>
                <button class="btn btn-primary" type="button" disabled={{@controller.ignoreSubmitDisabled}} {{on "click" @controller.submitIgnoreFinding}}>
                  Ignore finding
                </button>
              </div>
            </div>
          </div>
        </div>
      {{/if}}

      <div class="mg-health__sections">
        {{#each @controller.sections as |section|}}
          <section class="mg-health__panel">
            <div class="mg-health__panel-header">
              <div class="mg-health__panel-copy">
                <h2>{{section.title}}</h2>
                <p class="mg-health__muted">{{section.description}}</p>
              </div>
              <div class="mg-health__actions">
                {{#if section.hasHelp}}
                  <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">{{section.help}}</span></span>
                {{/if}}
                <span class="mg-health__badge {{section.badgeClass}}">{{section.severityLabel}}</span>
              </div>
            </div>

            <div class="mg-health__issue-list" style="margin-top: 1rem;">
              {{#each section.issues as |issue|}}
                <article class="mg-health__issue">
                  <span class="mg-health__icon {{issue.iconClass}}">{{issue.icon}}</span>
                  <div>
                    <div class="mg-health__issue-title">
                      <span>{{issue.label}}</span>
                      {{#if issue.countLabel}}
                        <span class="mg-health__badge">{{issue.countLabel}}</span>
                      {{/if}}
                    </div>
                    <p class="mg-health__issue-message">{{issue.message}}</p>
                    {{#if issue.hasDetail}}
                      <p class="mg-health__item-detail">{{issue.detail}}</p>
                    {{/if}}
                    {{#if issue.hasExamples}}
                      <div class="mg-health__examples">
                        {{#each issue.examples as |example|}}
                          <div class="mg-health__example">
                            {{#if example.url}}
                              <a class="mg-health__example-title" href={{example.url}} target="_blank" rel="noopener noreferrer">{{example.title}}</a>
                            {{else}}
                              <div class="mg-health__example-title">{{example.title}}</div>
                            {{/if}}
                            {{#if example.subtitle}}
                              <div class="mg-health__example-subtitle">{{example.subtitle}}</div>
                            {{/if}}
                            {{#if example.hasDetail}}
                              <div class="mg-health__example-subtitle">{{example.detail}}</div>
                            {{/if}}
                            {{#if example.hasSuggestion}}
                              <div class="mg-health__example-subtitle"><strong>Suggested action:</strong> {{example.suggestion}}</div>
                            {{/if}}
                            <div class="mg-health__example-actions">
                              {{#if example.url}}
                                <a class="btn" href={{example.url}} target="_blank" rel="noopener noreferrer">Open in management</a>
                              {{/if}}
                              {{#if example.canIgnore}}
                                <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" (fn @controller.ignoreFinding issue example)}}>Ignore finding</button>
                              {{/if}}
                            </div>
                          </div>
                        {{/each}}
                      </div>
                    {{/if}}
                  </div>
                  <span class="mg-health__badge {{issue.badgeClass}}">{{issue.severityLabel}}</span>
                </article>
              {{/each}}
            </div>
          </section>
        {{/each}}
      </div>
    </div>
  </template>
);
