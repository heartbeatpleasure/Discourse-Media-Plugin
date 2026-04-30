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
        display: flex;
        flex-direction: column;
        gap: 1rem;
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
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-security__header,
      .mg-security__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-security__copy,
      .mg-security__panel-copy,
      .mg-security__control-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-security__muted,
      .mg-security__meta,
      .mg-security__setting-recommended {
        color: var(--mg-security-muted);
        font-size: var(--font-down-1);
      }

      .mg-security__actions,
      .mg-security__badge-row,
      .mg-security__link-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.65rem;
      }

      .mg-security__summary-grid,
      .mg-security__metrics-grid,
      .mg-security__storage-grid,
      .mg-security__settings-grid,
      .mg-security__controls {
        display: grid;
        gap: 1rem;
      }

      .mg-security__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(165px, 1fr));
      }

      .mg-security__metrics-grid {
        grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      }

      .mg-security__storage-grid {
        grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      }

      .mg-security__settings-grid {
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      }

      .mg-security__summary-card,
      .mg-security__metric,
      .mg-security__profile,
      .mg-security__setting,
      .mg-security__control {
        background: var(--mg-security-surface-alt);
        border: 1px solid var(--mg-security-border);
        border-radius: 16px;
        padding: 0.9rem 1rem;
        min-width: 0;
      }

      .mg-security__summary-value,
      .mg-security__metric-value {
        font-size: 1.35rem;
        font-weight: 700;
        line-height: 1.15;
        margin-top: 0.25rem;
      }

      .mg-security__control {
        display: grid;
        gap: 0.65rem;
      }

      .mg-security__control-header,
      .mg-security__setting-header,
      .mg-security__profile-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .mg-security__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.28rem 0.65rem;
        font-size: var(--font-down-1);
        font-weight: 700;
        line-height: 1.2;
        white-space: nowrap;
        border: 1px solid var(--primary-low);
        background: var(--primary-very-low);
        color: var(--primary-high);
      }

      .mg-security__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-security__badge.is-warning {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-security__badge.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-security__badge.is-info {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-security__setting-value,
      .mg-security__mono {
        font-family: var(--d-font-family--monospace, monospace);
        overflow-wrap: anywhere;
      }

      .mg-security__facts {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(155px, 1fr));
        gap: 0.65rem;
      }

      .mg-security__fact {
        border: 1px solid var(--mg-security-border);
        border-radius: 14px;
        background: var(--mg-security-surface-alt);
        padding: 0.75rem 0.85rem;
      }

      .mg-security__fact-label {
        color: var(--mg-security-muted);
        font-size: var(--font-down-1);
      }

      .mg-security__fact-value {
        font-weight: 700;
        margin-top: 0.2rem;
      }

      .mg-security__top-list {
        display: grid;
        gap: 0.55rem;
      }

      .mg-security__top-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        border: 1px solid var(--mg-security-border);
        border-radius: 14px;
        background: var(--mg-security-surface-alt);
        padding: 0.7rem 0.85rem;
      }

      .mg-security__error {
        color: var(--danger);
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        border-radius: 14px;
        padding: 0.8rem 0.95rem;
      }

      @media (max-width: 700px) {
        .mg-security__header,
        .mg-security__panel-header,
        .mg-security__control-header,
        .mg-security__setting-header,
        .mg-security__profile-header {
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
          <p class="mg-security__muted">Last checked: {{this.generatedAtLabel}}</p>
        </div>
        <div class="mg-security__actions">
          <button class="btn btn-primary" type="button" {{on "click" this.loadSecurityStatus}} disabled={{this.isLoading}}>
            {{#if this.isLoading}}Refreshing…{{else}}Refresh{{/if}}
          </button>
          <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
        </div>
      </section>

      {{#if this.error}}
        <div class="mg-security__error">{{this.error}}</div>
      {{/if}}

      <section class="mg-security__summary-grid" aria-label="Security summary">
        <div class="mg-security__summary-card">
          <div class="mg-security__muted">Overall posture</div>
          <div class="mg-security__summary-value">{{this.summary.posture}}</div>
          <span class={{this.postureBadgeClass}}>{{this.summary.posture}}</span>
        </div>
        <div class="mg-security__summary-card">
          <div class="mg-security__muted">Download prevention</div>
          <div class="mg-security__summary-value">{{this.summary.download_prevention_level}}</div>
          <span class={{this.downloadBadgeClass}}>{{this.summary.download_prevention_level}}</span>
        </div>
        <div class="mg-security__summary-card">
          <div class="mg-security__muted">Controls</div>
          <div class="mg-security__summary-value">{{this.summary.controls_total}}</div>
          <p class="mg-security__muted">
            OK {{this.summary.ok_count}} · Partial {{this.summary.partial_count}} · Attention {{this.summary.attention_count}}
          </p>
        </div>
        <div class="mg-security__summary-card">
          <div class="mg-security__muted">Events last 7 days</div>
          <div class="mg-security__summary-value">{{this.recentEvents.total_7d}}</div>
          <p class="mg-security__muted">Warnings/danger: {{this.recentEvents.warning_or_danger_7d}}</p>
        </div>
      </section>

      <section class="mg-security__panel">
        <div class="mg-security__panel-header">
          <div class="mg-security__panel-copy">
            <h2>Control status</h2>
            <p class="mg-security__muted">High-level controls and configuration-dependent protections. No detailed open-issue list is shown here.</p>
          </div>
        </div>
        <div class="mg-security__controls">
          {{#each this.controls as |control|}}
            <article class="mg-security__control">
              <div class="mg-security__control-header">
                <div class="mg-security__control-copy">
                  <h3>{{control.title}}</h3>
                  <p>{{control.summary}}</p>
                </div>
                <span class={{control.badgeClass}}>{{control.label}}</span>
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
        <div class="mg-security__facts">
          <div class="mg-security__fact"><div class="mg-security__fact-label">HLS enabled</div><div class="mg-security__fact-value">{{this.download.hls_enabled}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">HLS-only video</div><div class="mg-security__fact-value">{{this.download.hls_only_enabled}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Fingerprinting</div><div class="mg-security__fact-value">{{this.download.fingerprint_enabled}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Watermarking</div><div class="mg-security__fact-value">{{this.download.watermark_enabled}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Stream token TTL</div><div class="mg-security__fact-value">{{this.download.stream_token_ttl_minutes}} min</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Token binding</div><div class="mg-security__fact-value">User {{this.download.bind_to_user}} · Session {{this.download.bind_to_session}} · IP {{this.download.bind_to_ip}}</div></div>
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
        <div class="mg-security__settings-grid">
          {{#each this.settings as |setting|}}
            <article class="mg-security__setting">
              <div class="mg-security__setting-header">
                <div>
                  <h3>{{setting.label}}</h3>
                  <p class="mg-security__setting-value">{{setting.value}}</p>
                </div>
                <span class={{setting.badgeClass}}>{{setting.presentLabel}}</span>
              </div>
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
        <div class="mg-security__storage-grid">
          {{#each this.profiles as |profile|}}
            <article class="mg-security__profile">
              <div class="mg-security__profile-header">
                <div>
                  <h3>{{profile.label}}</h3>
                  <p class="mg-security__muted">{{profile.profile_key}} · {{profile.backendLabel}} · {{profile.deliveryModeLabel}}</p>
                </div>
              </div>
              <p class="mg-security__meta mg-security__mono">Endpoint: {{profile.endpoint}}</p>
              <p class="mg-security__meta mg-security__mono">Bucket: {{profile.bucket}}</p>
              <p class="mg-security__meta mg-security__mono">Prefix/root: {{profile.prefix}}{{profile.rootPath}}</p>
            </article>
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
        <div class="mg-security__facts">
          <div class="mg-security__fact"><div class="mg-security__fact-label">Export count</div><div class="mg-security__fact-value">{{this.forensics.export_count}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Expired pending cleanup</div><div class="mg-security__fact-value">{{this.forensics.expired_exports}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Latest export</div><div class="mg-security__fact-value">{{this.forensicsLatestExportLabel}}</div></div>
          <div class="mg-security__fact"><div class="mg-security__fact-label">Manual delete</div><div class="mg-security__fact-value">{{this.forensics.delete_action_available}}</div></div>
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
        <div class="mg-security__top-list">
          {{#each this.topEventTypes as |event|}}
            <div class="mg-security__top-item">
              <span>{{event.label}}</span>
              <strong>{{event.count}}</strong>
            </div>
          {{else}}
            <p class="mg-security__muted">No recent media security events found.</p>
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
        <div class="mg-security__link-row">
          {{#each this.links as |link|}}
            <a class="btn" href={{link.url}}>{{link.label}}</a>
          {{/each}}
        </div>
      </section>
    </div>
  </template>
);
