import RouteTemplate from "ember-route-template";
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
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
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
        padding: 0.75rem 0.85rem;
        border: 1px solid var(--success-low-mid);
        background: var(--success-low);
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
            <span class="mg-health__badge {{@controller.overallBadgeClass}}">{{@controller.overallSeverityLabel}}</span>
            <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.refresh}}>
              {{if @controller.isLoading "Loading…" "Refresh"}}
            </button>
            <button class="btn btn-primary" type="button" disabled={{@controller.isLoading}} {{on "click" @controller.runFullStorage}}>
              Run full storage check
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
            <div style="margin-top: 0.5rem;"><span class="mg-health__badge {{card.badgeClass}}">{{card.severity}}</span></div>
          </article>
        {{/each}}
      </section>

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
                              <a class="mg-health__example-title" href={{example.url}}>{{example.title}}</a>
                            {{else}}
                              <div class="mg-health__example-title">{{example.title}}</div>
                            {{/if}}
                            {{#if example.subtitle}}
                              <div class="mg-health__example-subtitle">{{example.subtitle}}</div>
                            {{/if}}
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
