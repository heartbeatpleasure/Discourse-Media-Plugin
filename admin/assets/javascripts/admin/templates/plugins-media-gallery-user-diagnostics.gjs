import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-user-diagnostics {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-user-diagnostics h1,
      .media-gallery-user-diagnostics h2,
      .media-gallery-user-diagnostics h3,
      .media-gallery-user-diagnostics p {
        margin: 0;
      }

      .mg-userdiag__hero,
      .mg-userdiag__panel,
      .mg-userdiag__card,
      .mg-userdiag__section {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-userdiag__hero {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
        padding: 1.25rem 1.35rem;
      }

      .mg-userdiag__hero-copy,
      .mg-userdiag__copy {
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
        min-width: 0;
      }

      .mg-userdiag__muted,
      .mg-userdiag__hero-copy p,
      .mg-userdiag__section-description {
        color: var(--mg-muted);
      }

      .mg-userdiag__panel {
        padding: 1rem 1.1rem;
      }

      .mg-userdiag__panel-header,
      .mg-userdiag__toolbar,
      .mg-userdiag__actions,
      .mg-userdiag__badge-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.7rem;
      }

      .mg-userdiag__panel-header {
        justify-content: space-between;
        margin-bottom: 0.9rem;
      }

      .mg-userdiag__toolbar {
        align-items: flex-end;
      }

      .mg-userdiag__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: min(100%, 420px);
      }

      .mg-userdiag__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-userdiag__field input {
        width: 100%;
        box-sizing: border-box;
        min-height: 42px;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0.45rem 0.65rem;
      }

      .mg-userdiag__grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
        gap: 0.85rem;
      }

      .mg-userdiag__main-grid {
        display: grid;
        grid-template-columns: minmax(0, 0.9fr) minmax(420px, 1.1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-userdiag__card,
      .mg-userdiag__section {
        padding: 0.95rem;
      }

      .mg-userdiag__card-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        margin-bottom: 0.2rem;
      }

      .mg-userdiag__card-value {
        font-size: 1.15rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-userdiag__card-reason {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        line-height: 1.35;
        margin-top: 0.35rem;
      }

      .mg-userdiag__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.23rem 0.58rem;
        font-size: var(--font-down-1);
        line-height: 1.2;
        white-space: nowrap;
        background: var(--primary-very-low);
        color: var(--primary-high);
        border: 1px solid var(--primary-low);
      }

      .mg-userdiag__badge.is-success,
      .mg-userdiag__card.is-success {
        border-color: var(--success-low-mid);
        background: var(--success-low);
      }

      .mg-userdiag__badge.is-warning,
      .mg-userdiag__card.is-warning,
      .mg-userdiag__badge.is-info,
      .mg-userdiag__card.is-info {
        border-color: var(--tertiary-low);
        background: var(--tertiary-very-low);
      }

      .mg-userdiag__badge.is-danger,
      .mg-userdiag__card.is-danger {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
      }

      .mg-userdiag__results,
      .mg-userdiag__list {
        display: grid;
        gap: 0.7rem;
      }

      .mg-userdiag__result {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.85rem;
        padding: 0.85rem;
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      .mg-userdiag__result-title {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-userdiag__setting-row,
      .mg-userdiag__activity-row {
        display: grid;
        grid-template-columns: minmax(180px, 0.8fr) minmax(0, 1fr) minmax(160px, 0.75fr);
        gap: 0.75rem;
        align-items: start;
        padding: 0.75rem;
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
      }

      .mg-userdiag__activity-row {
        grid-template-columns: minmax(170px, 0.7fr) minmax(0, 1fr) auto;
      }

      .mg-userdiag__row-title {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-userdiag__row-meta,
      .mg-userdiag__row-help {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        line-height: 1.35;
        overflow-wrap: anywhere;
      }

      .mg-userdiag__flash {
        border-radius: 12px;
        padding: 0.8rem 0.95rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-userdiag__empty {
        padding: 1rem;
        border: 1px dashed var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
        color: var(--mg-muted);
      }

      @media (max-width: 1100px) {
        .mg-userdiag__main-grid,
        .mg-userdiag__setting-row,
        .mg-userdiag__activity-row {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 700px) {
        .mg-userdiag__hero,
        .mg-userdiag__result {
          flex-direction: column;
          align-items: flex-start;
        }
      }
    </style>

    <div class="media-gallery-user-diagnostics">
      <section class="mg-userdiag__hero">
        <div class="mg-userdiag__hero-copy">
          <h1>{{i18n "admin.media_gallery.user_diagnostics.title"}}</h1>
          <p>{{i18n "admin.media_gallery.user_diagnostics.description"}}</p>
        </div>
        <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
      </section>

      <section class="mg-userdiag__panel">
        <div class="mg-userdiag__panel-header">
          <div class="mg-userdiag__copy">
            <h2>Find user</h2>
            <p class="mg-userdiag__muted">Search by username, display name, email address, or numeric user ID.</p>
          </div>
        </div>

        <form class="mg-userdiag__toolbar" {{on "submit" @controller.searchUsers}}>
          <div class="mg-userdiag__field">
            <label>User search</label>
            <input
              type="text"
              value={{@controller.searchQuery}}
              placeholder="username, email, name, or user ID…"
              {{on "input" @controller.updateSearchQuery}}
            />
          </div>
          <button class="btn btn-primary" type="submit" disabled={{@controller.isSearching}}>
            {{if @controller.isSearching "Searching…" "Search"}}
          </button>
        </form>

        {{#if @controller.searchError}}
          <div class="mg-userdiag__flash" style="margin-top: 1rem;">{{@controller.searchError}}</div>
        {{/if}}

        {{#if @controller.hasSearchResults}}
          <div class="mg-userdiag__results" style="margin-top: 1rem;">
            {{#each @controller.searchResults as |user|}}
              <article class="mg-userdiag__result">
                <div class="mg-userdiag__copy">
                  <div class="mg-userdiag__result-title">{{user.username}}</div>
                  <div class="mg-userdiag__row-meta">
                    {{#if user.name}}{{user.name}} · {{/if}}#{{user.id}} · TL{{user.trust_level}}
                    {{#if user.email}} · {{user.email}}{{/if}}
                  </div>
                </div>
                <button class="btn" type="button" {{on "click" (fn @controller.selectUser user)}}>
                  Open diagnostics
                </button>
              </article>
            {{/each}}
          </div>
        {{/if}}
      </section>

      {{#if @controller.loadError}}
        <div class="mg-userdiag__flash">{{@controller.loadError}}</div>
      {{/if}}

      {{#if @controller.hasSelectedUser}}
        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>{{@controller.userNameLabel}}</h2>
              <div class="mg-userdiag__badge-row">
                {{#each @controller.roleBadges as |badge|}}
                  <span class="mg-userdiag__badge {{badge.className}}">{{badge.label}}</span>
                {{/each}}
              </div>
            </div>
            <div class="mg-userdiag__actions">
              <a class="btn" href={{@controller.selectedUser.admin_url}}>Open admin user</a>
              <a class="btn" href={{@controller.selectedUser.profile_url}}>Open profile</a>
            </div>
          </div>

          <div class="mg-userdiag__main-grid">
            <section class="mg-userdiag__section">
              <h3>Account</h3>
              <div class="mg-userdiag__grid" style="margin-top: 0.85rem;">
                {{#each @controller.accountRows as |row|}}
                  <div class="mg-userdiag__card">
                    <div class="mg-userdiag__card-label">{{row.label}}</div>
                    <div class="mg-userdiag__card-value">{{row.value}}</div>
                  </div>
                {{/each}}
              </div>
              <div class="mg-userdiag__section" style="margin-top: 1rem; box-shadow: none;">
                <div class="mg-userdiag__card-label">Groups</div>
                <div class="mg-userdiag__row-help">{{@controller.groupNames}}</div>
              </div>
            </section>

            <section class="mg-userdiag__section">
              <h3>Media access summary</h3>
              <div class="mg-userdiag__grid" style="margin-top: 0.85rem;">
                {{#each @controller.mediaAccessCards as |card|}}
                  <div class="mg-userdiag__card {{card.className}}">
                    <div class="mg-userdiag__card-label">{{card.label}}</div>
                    <div class="mg-userdiag__card-value">{{card.value}}</div>
                    <div class="mg-userdiag__card-reason">{{card.reason}}</div>
                  </div>
                {{/each}}
              </div>
            </section>
          </div>
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Relevant settings evaluation</h2>
              <p class="mg-userdiag__muted">Read-only explanation of which media settings match this user and what effect they have.</p>
            </div>
          </div>

          <div class="mg-userdiag__list">
            {{#each @controller.settingsRows as |row|}}
              <article class="mg-userdiag__setting-row">
                <div>
                  <div class="mg-userdiag__row-title">{{row.label}}</div>
                  <div class="mg-userdiag__row-meta">{{row.setting}}</div>
                </div>
                <div>
                  <div class="mg-userdiag__row-meta">Configured</div>
                  <div class="mg-userdiag__row-title">{{row.configured}}</div>
                  <div class="mg-userdiag__row-help">{{row.effect}}</div>
                </div>
                <div>
                  <span class="mg-userdiag__badge {{if row.matched "is-success"}}">{{row.matches}}</span>
                </div>
              </article>
            {{/each}}
          </div>
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Media activity stats</h2>
              <p class="mg-userdiag__muted">Bounded read-only counters for this user's media activity.</p>
            </div>
          </div>
          <div class="mg-userdiag__grid">
            {{#each @controller.statCards as |stat|}}
              <div class="mg-userdiag__card">
                <div class="mg-userdiag__card-label">{{stat.label}}</div>
                <div class="mg-userdiag__card-value">{{stat.value}}</div>
              </div>
            {{/each}}
          </div>
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Recent activity</h2>
              <p class="mg-userdiag__muted">Recent uploads, reports, and log events. This page does not change user or media state.</p>
            </div>
          </div>

          <div class="mg-userdiag__main-grid">
            <section class="mg-userdiag__section">
              <h3>Recent uploads</h3>
              <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
                {{#if @controller.recentUploads.length}}
                  {{#each @controller.recentUploads as |item|}}
                    <article class="mg-userdiag__activity-row">
                      <div>
                        <div class="mg-userdiag__row-title">{{item.title}}</div>
                        <div class="mg-userdiag__row-meta">{{item.public_id}}</div>
                      </div>
                      <div class="mg-userdiag__row-help">{{item.createdAtLabel}} · {{item.typeLabel}}</div>
                      <span class="mg-userdiag__badge {{item.visibilityClass}}">{{item.statusLabel}} / {{item.visibilityLabel}}</span>
                    </article>
                  {{/each}}
                {{else}}
                  <div class="mg-userdiag__empty">No recent uploads found.</div>
                {{/if}}
              </div>
            </section>

            <section class="mg-userdiag__section">
              <h3>Recent reports by user</h3>
              <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
                {{#if @controller.recentReports.length}}
                  {{#each @controller.recentReports as |report|}}
                    <article class="mg-userdiag__activity-row">
                      <div>
                        <div class="mg-userdiag__row-title">{{report.reason_label}}</div>
                        <div class="mg-userdiag__row-meta">{{report.media_title}}</div>
                      </div>
                      <div class="mg-userdiag__row-help">{{report.createdAtLabel}} · {{report.media_public_id}}</div>
                      <span class="mg-userdiag__badge {{report.statusClass}}">{{report.statusLabel}}</span>
                    </article>
                  {{/each}}
                {{else}}
                  <div class="mg-userdiag__empty">No recent reports found.</div>
                {{/if}}
              </div>
            </section>
          </div>

          <section class="mg-userdiag__section" style="margin-top: 1rem;">
            <h3>Recent log events</h3>
            <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
              {{#if @controller.recentLogs.length}}
                {{#each @controller.recentLogs as |event|}}
                  <article class="mg-userdiag__activity-row">
                    <div>
                      <div class="mg-userdiag__row-title">{{event.eventLabel}}</div>
                      <div class="mg-userdiag__row-meta">{{event.createdAtLabel}} · {{event.category}}</div>
                    </div>
                    <div class="mg-userdiag__row-help">
                      {{#if event.media_title}}{{event.media_title}} · {{/if}}{{event.message}}
                    </div>
                    <span class="mg-userdiag__badge {{event.severityClass}}">{{event.severity}}</span>
                  </article>
                {{/each}}
              {{else}}
                <div class="mg-userdiag__empty">No recent log events found.</div>
              {{/if}}
            </div>
          </section>
        </section>
      {{else}}
        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__empty">Search and select a user to view media diagnostics.</div>
        </section>
      {{/if}}
    </div>
  </template>
);
