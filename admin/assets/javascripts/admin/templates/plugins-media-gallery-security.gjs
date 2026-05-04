import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-security {
        --mg-security-surface: var(--secondary);
        --mg-security-surface-alt: var(--primary-very-low);
        --mg-security-border: var(--primary-low);
        --mg-security-muted: var(--primary-medium);
        --mg-security-radius: 18px;
        --mg-security-ok-bg: #ebf9ef;
        --mg-security-ok-fg: #0b7a2a;
        --mg-security-ok-border: #92d2a2;
        --mg-security-warn-bg: #fff4e5;
        --mg-security-warn-fg: #b45309;
        --mg-security-warn-border: #fdba74;
        --mg-security-danger-bg: #fee2e2;
        --mg-security-danger-fg: #b91c1c;
        --mg-security-danger-border: #fca5a5;
        --mg-security-info-bg: #eef2ff;
        --mg-security-info-fg: #4338ca;
        --mg-security-info-border: #c7d2fe;
        display: flex;
        flex-direction: column;
        gap: 1.2rem;
      }

      .media-gallery-security h1,
      .media-gallery-security h2,
      .media-gallery-security h3,
      .media-gallery-security p {
        margin: 0;
      }

      .mg-security__panel {
        background: var(--mg-security-surface);
        border: 1px solid var(--mg-security-border);
        border-radius: var(--mg-security-radius);
        padding: 1.1rem 1.2rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-security__header,
      .mg-security__panel-header,
      .mg-security__summary-head,
      .mg-security__item-head,
      .mg-security__profile-head {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-security__copy,
      .mg-security__panel-copy,
      .mg-security__item-copy {
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
        min-width: 0;
      }

      .mg-security__panel-copy {
        gap: 0.35rem;
      }

      .mg-security__actions,
      .mg-security__link-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: flex-end;
        gap: 0.65rem;
      }

      .mg-security__muted {
        color: var(--mg-security-muted);
      }

      .mg-security__summary-grid,
      .mg-security__controls,
      .mg-security__facts,
      .mg-security__settings-grid,
      .mg-security__top-list,
      .mg-security__storage-list {
        display: grid;
        gap: 1rem;
      }

      .mg-security__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      }

      .mg-security__controls {
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      }

      .mg-security__facts {
        grid-template-columns: repeat(auto-fit, minmax(255px, 1fr));
      }

      .mg-security__settings-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-security__section-body {
        margin-top: 1rem;
      }

      .mg-security__summary-card,
      .mg-security__control,
      .mg-security__fact,
      .mg-security__setting,
      .mg-security__profile,
      .mg-security__top-item {
        background: var(--mg-security-surface-alt);
        border: 1px solid var(--mg-security-border);
        border-radius: 16px;
        min-width: 0;
      }

      .mg-security__summary-card,
      .mg-security__control,
      .mg-security__fact,
      .mg-security__setting,
      .mg-security__profile {
        padding: 1rem 1.05rem;
      }

      .mg-security__summary-card,
      .mg-security__control,
      .mg-security__fact,
      .mg-security__setting,
      .mg-security__profile {
        display: flex;
        flex-direction: column;
        gap: 0.65rem;
      }

      .mg-security__eyebrow,
      .mg-security__item-label,
      .mg-security__meta-label {
        color: var(--mg-security-muted);
        font-size: var(--font-down-1);
      }

      .mg-security__summary-value {
        font-size: 1.45rem;
        line-height: 1.15;
        font-weight: 700;
      }

      .mg-security__summary-secondary,
      .mg-security__item-note,
      .mg-security__setting-note,
      .mg-security__setting-recommended,
      .mg-security__meta-value,
      .mg-security__top-empty {
        color: var(--mg-security-muted);
      }

      .mg-security__status-chip {
        display: inline-flex;
        align-items: center;
        gap: 0.45rem;
        white-space: nowrap;
        border-radius: 999px;
        border: 1px solid var(--mg-security-border);
        padding: 0.3rem 0.7rem;
        font-size: var(--font-down-1);
        font-weight: 700;
      }

      .mg-security__status-dot {
        display: inline-flex;
        flex: 0 0 auto;
        width: 0.7rem;
        height: 0.7rem;
        border-radius: 999px;
        border: 1px solid transparent;
      }

      .mg-security__status-chip .mg-security__status-dot {
        width: 0.55rem;
        height: 0.55rem;
      }

      .mg-security__status-chip.is-success,
      .mg-security__status-dot.is-success {
        background: var(--mg-security-ok-bg);
        border-color: var(--mg-security-ok-border);
        color: var(--mg-security-ok-fg);
      }

      .mg-security__status-chip.is-warning,
      .mg-security__status-dot.is-warning {
        background: var(--mg-security-warn-bg);
        border-color: var(--mg-security-warn-border);
        color: var(--mg-security-warn-fg);
      }

      .mg-security__status-chip.is-danger,
      .mg-security__status-dot.is-danger {
        background: var(--mg-security-danger-bg);
        border-color: var(--mg-security-danger-border);
        color: var(--mg-security-danger-fg);
      }

      .mg-security__status-chip.is-info,
      .mg-security__status-dot.is-info {
        background: var(--mg-security-info-bg);
        border-color: var(--mg-security-info-border);
        color: var(--mg-security-info-fg);
      }

      .mg-security__control-copy h3,
      .mg-security__setting-title,
      .mg-security__profile-title,
      .mg-security__fact-value,
      .mg-security__setting-value,
      .mg-security__meta-value strong {
        font-weight: 700;
      }

      .mg-security__fact-value,
      .mg-security__setting-value {
        font-size: 1.05rem;
        line-height: 1.3;
      }

      .mg-security__environment .mg-security__item-head {
        gap: 1.35rem;
      }

      .mg-security__environment .mg-security__item-copy {
        flex: 1 1 auto;
        min-width: 0;
        gap: 0.55rem;
        padding-right: 0.4rem;
      }

      .mg-security__environment .mg-security__fact-value {
        overflow-wrap: anywhere;
        word-break: break-word;
      }

      .mg-security__environment .mg-security__status-chip {
        flex: 0 0 auto;
      }

      .mg-security__setting-value,
      .mg-security__mono {
        font-family: var(--d-font-family--monospace, monospace);
        overflow-wrap: anywhere;
      }

      .mg-security__profile-grid {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 0.85rem;
      }

      .mg-security__profile-meta {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-security__profile-subtitle {
        color: var(--mg-security-muted);
      }

      .mg-security__top-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        padding: 0.8rem 0.95rem;
      }

      .mg-security__top-empty {
        border: 1px dashed var(--mg-security-border);
        border-radius: 14px;
        padding: 0.9rem 1rem;
        background: var(--mg-security-surface-alt);
      }

      .mg-security__error {
        color: var(--danger);
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        border-radius: 14px;
        padding: 0.8rem 0.95rem;
      }

      @media (max-width: 1000px) {
        .mg-security__settings-grid {
          grid-template-columns: 1fr;
        }

        .mg-security__profile-grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 700px) {
        .mg-security__header,
        .mg-security__panel-header,
        .mg-security__summary-head,
        .mg-security__item-head,
        .mg-security__profile-head {
          flex-direction: column;
          align-items: stretch;
        }
      }
    </style>

    <div class="media-gallery-security">
      <section class="mg-security__panel mg-security__header">
        <div class="mg-security__copy">
          <h1>Security status</h1>
          <p class="mg-security__muted">
            Read-only overview of active Media Gallery security, privacy and download-prevention controls. This page avoids listing internal open issues.
          </p>
          <p class="mg-security__muted">Last checked: {{@controller.generatedAtLabel}}</p>
        </div>
        <div class="mg-security__actions">
          <button class="btn btn-primary" type="button" {{on "click" @controller.loadSecurityStatus}} disabled={{@controller.isLoading}}>
            {{#if @controller.isLoading}}Refreshing…{{else}}Refresh{{/if}}
          </button>
          <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-security__error">{{@controller.error}}</div>
      {{/if}}

      <section class="mg-security__summary-grid" aria-label="Security summary">
        {{#each @controller.summaryCards as |card|}}
          <article class="mg-security__summary-card">
            <div class="mg-security__summary-head">
              <div class="mg-security__eyebrow">{{card.label}}</div>
              <span class={{card.statusDotClass}} title={{card.statusTitle}} aria-label={{card.statusTitle}}></span>
            </div>
            <div class="mg-security__summary-value">{{card.value}}</div>
            <div class="mg-security__summary-secondary">{{card.secondary}}</div>
            <p class="mg-security__muted">{{card.detail}}</p>
          </article>
        {{/each}}
      </section>

      <section class="mg-security__panel mg-security__environment">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>HTTPS and canonical URL</h2>
            <p class="mg-security__muted">Read-only warning signal for HTTPS, canonical host and reverse-proxy scheme handling.</p>
          </div>
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.environmentFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Recommended security baseline</h2>
            <p class="mg-security__muted">Current values compared with practical production recommendations. This is guidance only and does not change settings.</p>
          </div>
          <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery">Open settings</a>
        </div>
        <div class="mg-security__settings-grid mg-security__section-body">
          {{#each @controller.baselineRows as |row|}}
            <article class="mg-security__setting">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <h3 class="mg-security__setting-title">{{row.label}}</h3>
                </div>
                <span class={{row.statusChipClass}}>
                  <span class={{row.statusDotClass}}></span>
                  <span>{{row.statusText}}</span>
                </span>
              </div>
              <div class="mg-security__setting-value">{{row.current}}</div>
              <p class="mg-security__setting-note">{{row.note}}</p>
              <p class="mg-security__setting-recommended">Recommended: {{row.recommended}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Control status</h2>
            <p class="mg-security__muted">High-level controls and configuration-dependent protections. No detailed open-issue list is shown here.</p>
          </div>
        </div>
        <div class="mg-security__controls mg-security__section-body">
          {{#each @controller.controls as |control|}}
            <article class="mg-security__control">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <h3>{{control.title}}</h3>
                  <p>{{control.summary}}</p>
                </div>
                <span class={{control.statusChipClass}}>
                  <span class={{control.statusDotClass}}></span>
                  <span>{{control.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__muted">{{control.action}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Download prevention</h2>
            <p class="mg-security__muted">Current protection signals that influence whether users receive HLS-only, fingerprinted or directly streamable media.</p>
          </div>
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.downloadFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Additional security controls</h2>
            <p class="mg-security__muted">Status of hardening controls that complement the recommended security baseline.</p>
          </div>
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.recentControlFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Relevant settings</h2>
            <p class="mg-security__muted">Read-only status of settings that affect media security, privacy, retention and download deterrence.</p>
          </div>
          <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery">Open settings</a>
        </div>
        <div class="mg-security__settings-grid mg-security__section-body">
          {{#each @controller.settings as |setting|}}
            <article class="mg-security__setting">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <h3 class="mg-security__setting-title">{{setting.label}}</h3>
                </div>
                <span class={{setting.statusChipClass}}>
                  <span class={{setting.statusDotClass}}></span>
                  <span>{{setting.statusText}}</span>
                </span>
              </div>
              <div class="mg-security__setting-value">{{setting.displayValue}}</div>
              <p class="mg-security__setting-note">{{setting.note}}</p>
              <p class="mg-security__setting-recommended">Recommended: {{setting.recommended}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Storage profiles</h2>
            <p class="mg-security__muted">Configured storage profiles without credentials or secret values.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-migrations">Open storage tools</a>
        </div>
        <div class="mg-security__storage-list mg-security__section-body">
          {{#each @controller.storageProfiles as |profile|}}
            <article class="mg-security__profile">
              <div class="mg-security__profile-head">
                <div class="mg-security__item-copy">
                  <h3 class="mg-security__profile-title">{{profile.label}}</h3>
                  <p class="mg-security__profile-subtitle">{{profile.profileKey}} · {{profile.backendLabel}} · {{profile.deliveryModeLabel}}</p>
                </div>
                <span class={{profile.statusChipClass}}>
                  <span class={{profile.statusDotClass}}></span>
                  <span>{{profile.statusText}}</span>
                </span>
              </div>
              <div class="mg-security__profile-grid">
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Backend</div>
                  <div class="mg-security__meta-value"><strong>{{profile.backendLabel}}</strong></div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Delivery mode</div>
                  <div class="mg-security__meta-value"><strong>{{profile.deliveryModeLabel}}</strong></div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Bucket</div>
                  <div class="mg-security__meta-value mg-security__mono">{{profile.bucket}}</div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Endpoint</div>
                  <div class="mg-security__meta-value mg-security__mono">{{profile.endpoint}}</div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Prefix / root</div>
                  <div class="mg-security__meta-value mg-security__mono">{{profile.pathValue}}</div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Status</div>
                  <div class="mg-security__meta-value"><strong>{{profile.statusText}}</strong></div>
                </div>
              </div>
            </article>
          {{else}}
            <div class="mg-security__top-empty">No configured storage profiles found.</div>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Forensics and exports</h2>
            <p class="mg-security__muted">Retention, archive and export lifecycle status.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-forensics-exports">Open exports</a>
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.forensicsFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Backup and retention visibility</h2>
            <p class="mg-security__muted">Private paths and export/archive locations. Paths outside /shared may need separate backup or cleanup procedures.</p>
          </div>
        </div>
        <div class="mg-security__storage-list mg-security__section-body">
          {{#each @controller.backupPathFacts as |path|}}
            <article class="mg-security__profile">
              <div class="mg-security__profile-head">
                <div class="mg-security__item-copy">
                  <h3 class="mg-security__profile-title">{{path.label}}</h3>
                  <p class="mg-security__profile-subtitle">{{path.purpose}} · retention {{path.retention}}</p>
                </div>
                <span class={{path.statusChipClass}}>
                  <span class={{path.statusDotClass}}></span>
                  <span>{{path.statusText}}</span>
                </span>
              </div>
              <div class="mg-security__profile-grid">
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Path</div>
                  <div class="mg-security__meta-value mg-security__mono">{{path.path}}</div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Recommendation</div>
                  <div class="mg-security__meta-value">{{path.recommendation}}</div>
                </div>
                <div class="mg-security__profile-meta">
                  <div class="mg-security__meta-label">Status note</div>
                  <div class="mg-security__meta-value">{{path.note}}</div>
                </div>
              </div>
            </article>
          {{else}}
            <div class="mg-security__top-empty">No private path information available.</div>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Processing failure metrics</h2>
            <p class="mg-security__muted">Failed media items grouped by sanitized reason codes. No raw user content is shown in this summary.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-management?status=failed">Open failed items</a>
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.processingFailureSummaryFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
        <div class="mg-security__top-list mg-security__section-body">
          {{#each @controller.processingFailureFacts as |reason|}}
            <div class="mg-security__top-item">
              <span>{{reason.label}}</span>
              <strong>{{reason.count}}</strong>
            </div>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Rate-limit and anomaly tuning</h2>
            <p class="mg-security__muted">Seven-day signals for choosing safe thresholds. Observe normal traffic before enabling stricter blocking.</p>
          </div>
          <span class={{@controller.rateLimitTuningStatusChipClass}}>
            <span class={{@controller.rateLimitTuningStatusDotClass}}></span>
            <span>{{@controller.rateLimitTuningStatusText}}</span>
          </span>
        </div>
        <p class="mg-security__muted mg-security__section-body">{{@controller.rateLimitTuningSummary}}</p>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.rateLimitTuningFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
        <div class="mg-security__facts mg-security__section-body">
          {{#each @controller.rateLimitThresholdFacts as |fact|}}
            <article class="mg-security__fact">
              <div class="mg-security__item-head">
                <div class="mg-security__item-copy">
                  <div class="mg-security__item-label">{{fact.label}}</div>
                  <div class="mg-security__fact-value">{{fact.value}}</div>
                </div>
                <span class={{fact.statusChipClass}}>
                  <span class={{fact.statusDotClass}}></span>
                  <span>{{fact.statusText}}</span>
                </span>
              </div>
              <p class="mg-security__item-note">{{fact.detail}}</p>
            </article>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Recent media security events</h2>
            <p class="mg-security__muted">Top event types from the last 7 days. Use the logs page for details.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-logs">Open logs</a>
        </div>
        <div class="mg-security__top-list mg-security__section-body">
          {{#each @controller.topEventTypes as |event|}}
            <div class="mg-security__top-item">
              <span>{{event.label}}</span>
              <strong>{{event.count}}</strong>
            </div>
          {{else}}
            <div class="mg-security__top-empty">No recent media security events found.</div>
          {{/each}}
        </div>
        <div class="mg-security__top-list mg-security__section-body">
          {{#each @controller.eventCounterFacts as |event|}}
            <div class="mg-security__top-item">
              <span>{{event.label}}</span>
              <strong>{{event.count}}</strong>
            </div>
          {{/each}}
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Quick links</h2>
            <p class="mg-security__muted">Related read-only or admin tools.</p>
          </div>
        </div>
        <div class="mg-security__link-row mg-security__section-body">
          {{#each @controller.quickLinks as |link|}}
            <a class="btn" href={{link.url}}>{{link.label}}</a>
          {{/each}}
        </div>
      </section>
    </div>
  </template>
);
