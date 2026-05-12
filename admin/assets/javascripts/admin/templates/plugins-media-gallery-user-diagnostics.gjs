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
      .mg-userdiag__performance,
      .mg-userdiag__hero-copy p,
      .mg-userdiag__section-description {
        color: var(--mg-muted);
      }

      .mg-userdiag__performance {
        font-size: var(--font-down-1);
        margin-top: 0.65rem;
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

      .mg-userdiag__toolbar .btn {
        align-self: flex-end;
        margin-bottom: 0;
        transform: translateY(-15px);
      }

      .mg-userdiag__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: min(100%, 520px);
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

      .mg-userdiag__account-grid,
      .mg-userdiag__access-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-userdiag__account-grid .mg-userdiag__card:nth-child(n+3):nth-child(-n+6) {
        grid-column: 1 / -1;
      }

      .mg-userdiag__access-grid .mg-userdiag__card {
        border-color: var(--mg-border);
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

      a.mg-userdiag__card {
        display: block;
        color: var(--primary);
        text-decoration: none;
      }

      a.mg-userdiag__card:hover {
        border-color: var(--tertiary);
        box-shadow: inset 0 0 0 1px var(--tertiary-low);
      }

      .mg-userdiag__card-linkhint {
        color: var(--tertiary);
        font-size: var(--font-down-1);
        margin-top: 0.45rem;
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

      .mg-userdiag__card-top {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.5rem;
      }

      .mg-userdiag__info {
        position: relative;
        display: inline-flex;
        flex-shrink: 0;
      }

      .mg-userdiag__info-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 1.35rem;
        height: 1.35rem;
        border: 1px solid var(--tertiary);
        border-radius: 999px;
        background: var(--secondary);
        color: var(--tertiary);
        font-size: 0.78rem;
        font-weight: 700;
        line-height: 1;
        cursor: help;
        user-select: none;
      }

      .mg-userdiag__info-tooltip {
        position: absolute;
        top: calc(100% + 0.45rem);
        right: 0;
        width: min(24rem, calc(100vw - 4rem));
        min-width: min(16rem, calc(100vw - 4rem));
        padding: 0.7rem 0.8rem;
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
        color: var(--primary-high);
        font-size: var(--font-down-1);
        font-weight: 400;
        line-height: 1.38;
        white-space: normal;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
        opacity: 0;
        pointer-events: none;
        transform: translateY(-0.15rem);
        transition: opacity 0.14s ease, transform 0.14s ease;
        z-index: 3000;
      }

      .mg-userdiag__info:hover .mg-userdiag__info-tooltip,
      .mg-userdiag__info:focus-within .mg-userdiag__info-tooltip {
        opacity: 1;
        transform: translateY(0);
      }

      .mg-userdiag__info-row + .mg-userdiag__info-row {
        margin-top: 0.35rem;
      }

      .mg-userdiag__info-label {
        font-weight: 700;
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
      .mg-userdiag__card.is-warning {
        border-color: var(--highlight-medium);
        background: var(--highlight-low);
      }

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

      .mg-userdiag__access-grid .mg-userdiag__card,
      .mg-userdiag__access-grid .mg-userdiag__card.is-success,
      .mg-userdiag__access-grid .mg-userdiag__card.is-warning,
      .mg-userdiag__access-grid .mg-userdiag__card.is-info,
      .mg-userdiag__access-grid .mg-userdiag__card.is-danger {
        border-color: var(--mg-border);
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
        grid-template-columns: minmax(220px, 0.8fr) minmax(0, 1.4fr) auto;
      }

      .mg-userdiag__media-row {
        grid-template-columns: 132px minmax(0, 1fr) auto;
      }

      .mg-userdiag__log-row {
        grid-template-columns: minmax(260px, 1fr) minmax(0, 2fr) auto;
        align-items: center;
      }

      .mg-userdiag__media-thumb,
      .mg-userdiag__media-thumb-placeholder {
        width: 132px;
        aspect-ratio: 16 / 9;
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
      }

      .mg-userdiag__media-thumb {
        object-fit: cover;
      }

      .mg-userdiag__media-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-userdiag__upload-card {
        display: grid;
        grid-template-columns: 128px minmax(0, 1fr) auto;
        grid-template-areas:
          "thumb main action"
          "badges badges badges";
        gap: 0.85rem 1rem;
        align-items: start;
        padding: 0.9rem;
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      .mg-userdiag__upload-card .mg-userdiag__media-thumb,
      .mg-userdiag__upload-card .mg-userdiag__media-thumb-placeholder {
        grid-area: thumb;
        width: 128px;
        border-radius: 14px;
      }

      .mg-userdiag__upload-main {
        grid-area: main;
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-userdiag__upload-action {
        grid-area: action;
        align-self: start;
      }

      .mg-userdiag__upload-badges {
        grid-area: badges;
        display: flex;
        flex-wrap: wrap;
        gap: 0.35rem;
      }

      .mg-userdiag__pagination {
        display: flex;
        align-items: center;
        justify-content: space-between;
        flex-wrap: wrap;
        gap: 0.75rem;
        margin-bottom: 0.85rem;
      }

      .mg-userdiag__pagination-controls {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .mg-userdiag__pagination select {
        min-height: 38px;
      }

      .mg-userdiag__tag-chip {
        display: inline-flex;
        align-items: center;
        border-radius: 999px;
        padding: 0.2rem 0.52rem;
        font-size: var(--font-down-1);
        background: var(--secondary);
        border: 1px solid var(--mg-border);
        color: var(--primary-high);
      }

      .mg-userdiag__report-involvement-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 1rem;
      }

      .mg-userdiag__report-counts {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
        gap: 0.65rem;
        margin-top: 0.85rem;
      }

      .mg-userdiag__report-count-card {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
        padding: 0.75rem;
      }

      .mg-userdiag__report-count-card.is-success {
        border-color: var(--success-low-mid);
        background: var(--success-low);
      }

      .mg-userdiag__report-count-card.is-warning {
        border-color: var(--highlight-medium);
        background: var(--highlight-low);
      }

      .mg-userdiag__report-count-card.is-danger {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
      }


      .mg-userdiag__trend-grid,
      .mg-userdiag__context-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 1rem;
        align-items: stretch;
      }

      .mg-userdiag__trend-grid--behavior {
        grid-template-columns: repeat(2, minmax(320px, 1fr));
      }

      .mg-userdiag__context-grid {
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      }

      @media (max-width: 900px) {
        .mg-userdiag__trend-grid--behavior {
          grid-template-columns: 1fr;
        }
      }

      .mg-userdiag__trend-card {
        display: flex;
        flex-direction: column;
      }

      .mg-userdiag__trend-card-header {
        min-height: 4.15rem;
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-userdiag__trend-card-header h3 {
        line-height: 1.2;
      }

      .mg-userdiag__trend-card-header p {
        line-height: 1.35;
      }

      .mg-userdiag__trend-window {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 0.5rem;
        margin-top: 0.45rem;
        padding: 0.7rem;
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--mg-surface-alt);
      }

      .mg-userdiag__trend-window-title {
        grid-column: 1 / -1;
        font-weight: 700;
      }

      .mg-userdiag__mini-stat-label {
        color: var(--mg-muted);
        font-size: var(--font-down-2);
      }

      .mg-userdiag__mini-stat-value {
        font-weight: 700;
      }

      .mg-userdiag__filter-row {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
        margin-top: 0.75rem;
      }

      .mg-userdiag__activity-sections {
        display: grid;
        gap: 1rem;
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
        .mg-userdiag__report-involvement-grid,
        .mg-userdiag__setting-row,
        .mg-userdiag__activity-row,
        .mg-userdiag__media-row,
        .mg-userdiag__log-row,
        .mg-userdiag__upload-card {
          grid-template-columns: 1fr;
          grid-template-areas:
            "thumb"
            "main"
            "badges"
            "action";
        }

        .mg-userdiag__upload-card .mg-userdiag__media-thumb,
        .mg-userdiag__upload-card .mg-userdiag__media-thumb-placeholder {
          width: 100%;
          max-width: 180px;
        }
      }

      @media (max-width: 700px) {
        .mg-userdiag__trend-card-header {
          min-height: 0;
        }

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
            <p class="mg-userdiag__muted">Search by username, display name, or numeric user ID.</p>
          </div>
        </div>

        <form class="mg-userdiag__toolbar" {{on "submit" @controller.searchUsers}}>
          <div class="mg-userdiag__field">
            <label>User search</label>
            <input
              type="text"
              value={{@controller.searchQuery}}
              placeholder="username, display name, or user ID…"
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
              {{#if @controller.performanceTimingLabel}}
                <div class="mg-userdiag__performance">{{@controller.performanceTimingLabel}}</div>
              {{/if}}
            </div>
            <div class="mg-userdiag__actions">
              <a class="btn" href={{@controller.selectedUser.admin_url}}>Open admin user</a>
              <a class="btn" href={{@controller.selectedUser.profile_url}}>Open profile</a>
            </div>
          </div>

          <div class="mg-userdiag__main-grid">
            <section class="mg-userdiag__section">
              <h3>Account</h3>
              <div class="mg-userdiag__grid mg-userdiag__account-grid" style="margin-top: 0.85rem;">
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
              <div class="mg-userdiag__grid mg-userdiag__access-grid" style="margin-top: 0.85rem;">
                {{#each @controller.mediaAccessCards as |card|}}
                  <div class="mg-userdiag__card {{card.className}}">
                    <div class="mg-userdiag__card-top">
                      <div class="mg-userdiag__card-label">{{card.label}}</div>
                      {{#if card.details.length}}
                        <span class="mg-userdiag__info">
                          <span class="mg-userdiag__info-button" tabindex="0" aria-label="Details">i</span>
                          <span class="mg-userdiag__info-tooltip">
                            {{#each card.details as |detail|}}
                              <div class="mg-userdiag__info-row">
                                <span class="mg-userdiag__info-label">{{detail.label}}:</span>
                                <span>{{detail.value}}</span>
                              </div>
                            {{/each}}
                          </span>
                        </span>
                      {{/if}}
                    </div>
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
              <p class="mg-userdiag__muted">Read-only counters for this user's media activity.</p>
            </div>
          </div>
          <div class="mg-userdiag__grid">
            {{#each @controller.statCards as |stat|}}
              {{#if stat.url}}
                <a class="mg-userdiag__card" href={{stat.url}} target="_blank" rel="noopener noreferrer">
                  <div class="mg-userdiag__card-label">{{stat.label}}</div>
                  <div class="mg-userdiag__card-value">{{stat.value}}</div>
                </a>
              {{else}}
                <div class="mg-userdiag__card">
                  <div class="mg-userdiag__card-label">{{stat.label}}</div>
                  <div class="mg-userdiag__card-value">{{stat.value}}</div>
                </div>
              {{/if}}
            {{/each}}
          </div>
        </section>



        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Report involvement</h2>
              <p class="mg-userdiag__muted">Exact media/comment report counters split between reports submitted by this user, reports on this user's uploads, and reports on comments authored by this user.</p>
            </div>
          </div>

          <div class="mg-userdiag__report-involvement-grid">
            {{#each @controller.reportInvolvementSections as |reportSection|}}
              <section class="mg-userdiag__section">
                <h3>{{reportSection.title}}</h3>
                <div class="mg-userdiag__report-counts">
                  {{#each reportSection.rows as |row|}}
                    <div class="mg-userdiag__report-count-card {{row.tone}}">
                      <div class="mg-userdiag__card-label">{{row.label}}</div>
                      <div class="mg-userdiag__card-value">{{row.value}}</div>
                    </div>
                  {{/each}}
                </div>
              </section>
            {{/each}}
          </div>
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Context signals</h2>
              <p class="mg-userdiag__muted">Contextual indicators about activity under this user's uploads. These numbers can help explain noisy media threads, but they do not directly indicate misconduct by this user.</p>
            </div>
          </div>

          <div class="mg-userdiag__context-grid">
            {{#each @controller.contextReportInvolvementSections as |contextSection|}}
              <section class="mg-userdiag__section">
                <div class="mg-userdiag__panel-header">
                  <div class="mg-userdiag__copy">
                    <h3>{{contextSection.title}}</h3>
                    <p class="mg-userdiag__muted">{{contextSection.subtitle}}</p>
                  </div>
                  {{#if contextSection.url}}
                    <a class="btn" href={{contextSection.url}} target="_blank" rel="noopener noreferrer">Open reports</a>
                  {{/if}}
                </div>
                <div class="mg-userdiag__report-counts">
                  {{#each contextSection.rows as |row|}}
                    <div class="mg-userdiag__report-count-card {{row.tone}}">
                      <div class="mg-userdiag__card-label">{{row.label}}</div>
                      <div class="mg-userdiag__card-value">{{row.value}}</div>
                    </div>
                  {{/each}}
                </div>
              </section>
            {{/each}}

            {{#each @controller.contextModerationTrendSections as |trendSection|}}
              <section class="mg-userdiag__section mg-userdiag__trend-card">
                <div class="mg-userdiag__trend-card-header">
                  <h3>{{trendSection.title}}</h3>
                  <p class="mg-userdiag__muted">{{trendSection.subtitle}}</p>
                </div>
                {{#each trendSection.rows as |window|}}
                  <div class="mg-userdiag__trend-window">
                    <div class="mg-userdiag__trend-window-title">{{window.label}}</div>
                    <div><div class="mg-userdiag__mini-stat-label">Total</div><div class="mg-userdiag__mini-stat-value">{{window.total}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Open</div><div class="mg-userdiag__mini-stat-value">{{window.open}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Accepted</div><div class="mg-userdiag__mini-stat-value">{{window.accepted}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Rejected</div><div class="mg-userdiag__mini-stat-value">{{window.rejected}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Resolved</div><div class="mg-userdiag__mini-stat-value">{{window.resolved}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Auto-hidden</div><div class="mg-userdiag__mini-stat-value">{{window.autoHidden}}</div></div>
                  </div>
                {{/each}}
              </section>
            {{/each}}
          </div>
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Reporting quality signal</h2>
              <p class="mg-userdiag__muted">Adds context to “Reports submitted by user” by looking specifically at rejected reports. This is informational only and never restricts the user automatically.</p>
            </div>
            {{#if @controller.falseReportSignalReportsUrl}}
              <a class="btn" href={{@controller.falseReportSignalReportsUrl}} target="_blank" rel="noopener noreferrer">Open submitted reports</a>
            {{/if}}
          </div>

          {{#if @controller.hasFalseReportHistory}}
            <div class="mg-userdiag__grid">
              {{#each @controller.falseReportSignalCards as |card|}}
                <div class="mg-userdiag__card {{card.tone}}">
                  <div class="mg-userdiag__card-top">
                    <div>
                      <div class="mg-userdiag__card-label">{{card.label}}</div>
                      <div class="mg-userdiag__card-value">{{card.value}}</div>
                      <div class="mg-userdiag__card-reason">{{card.help}}</div>
                    </div>
                  </div>
                </div>
              {{/each}}
            </div>
            <div class="mg-userdiag__report-counts">
              {{#each @controller.falseReportSignalBreakdownRows as |row|}}
                <div class="mg-userdiag__report-count-card {{row.tone}}">
                  <div class="mg-userdiag__card-label">{{row.label}}</div>
                  <div class="mg-userdiag__card-value">{{row.value}}</div>
                </div>
              {{/each}}
            </div>
            <p class="mg-userdiag__muted" style="margin-top: 0.85rem;">{{@controller.falseReportSignalCriteria}}</p>
          {{else}}
            <div class="mg-userdiag__empty">No submitted reports found for this user, so there is no reporting-quality signal yet.</div>
          {{/if}}
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Moderation trends</h2>
              <p class="mg-userdiag__muted">Media and comment report activity over the last 7, 30, and 90 days. Totals include open and reviewed reports.</p>
            </div>
          </div>

          <div class="mg-userdiag__trend-grid mg-userdiag__trend-grid--behavior">
            {{#each @controller.moderationTrendSections as |trendSection|}}
              <section class="mg-userdiag__section mg-userdiag__trend-card">
                <div class="mg-userdiag__trend-card-header">
                  <h3>{{trendSection.title}}</h3>
                  <p class="mg-userdiag__muted">{{trendSection.subtitle}}</p>
                </div>
                {{#each trendSection.rows as |window|}}
                  <div class="mg-userdiag__trend-window">
                    <div class="mg-userdiag__trend-window-title">{{window.label}}</div>
                    <div><div class="mg-userdiag__mini-stat-label">Total</div><div class="mg-userdiag__mini-stat-value">{{window.total}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Open</div><div class="mg-userdiag__mini-stat-value">{{window.open}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Accepted</div><div class="mg-userdiag__mini-stat-value">{{window.accepted}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Rejected</div><div class="mg-userdiag__mini-stat-value">{{window.rejected}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Resolved</div><div class="mg-userdiag__mini-stat-value">{{window.resolved}}</div></div>
                    <div><div class="mg-userdiag__mini-stat-label">Auto-hidden</div><div class="mg-userdiag__mini-stat-value">{{window.autoHidden}}</div></div>
                  </div>
                {{/each}}
              </section>
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

          <div class="mg-userdiag__filter-row">
            {{#each @controller.recentActivityButtons as |filterButton|}}
              <button class={{filterButton.className}} type="button" {{on "click" (fn @controller.setRecentActivityFilter filterButton.key)}}>{{filterButton.label}}</button>
            {{/each}}
          </div>

          <div class="mg-userdiag__activity-sections">
            {{#if @controller.showRecentUploads}}
            <section class="mg-userdiag__section">
              <h3>Recent uploads</h3>
              <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
                {{#if @controller.recentUploads.length}}
                  {{#each @controller.recentUploads as |item|}}
                    <article class="mg-userdiag__upload-card">
                      {{#if item.thumbnail_url}}
                        <img class="mg-userdiag__media-thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                      {{else}}
                        <div class="mg-userdiag__media-thumb-placeholder">No thumbnail</div>
                      {{/if}}

                      <div class="mg-userdiag__upload-main">
                        <div class="mg-userdiag__row-title">{{item.title}}</div>
                        <div class="mg-userdiag__row-meta">{{item.public_id}}</div>
                        <div class="mg-userdiag__row-help">{{item.createdAtLabel}} · {{item.typeLabel}} · {{item.containsLabel}}</div>
                      </div>

                      <a class="btn mg-userdiag__upload-action" href={{item.management_url}} target="_blank" rel="noopener noreferrer">Open</a>

                      <div class="mg-userdiag__upload-badges">
                        <span class="mg-userdiag__badge {{item.visibilityClass}}">{{item.statusLabel}} / {{item.visibilityLabel}}</span>
                        {{#if item.tags.length}}
                          {{#each item.tags as |tag|}}
                            <span class="mg-userdiag__tag-chip">{{tag}}</span>
                          {{/each}}
                        {{else}}
                          <span class="mg-userdiag__tag-chip">No tags</span>
                        {{/if}}
                      </div>
                    </article>
                  {{/each}}
                {{else}}
                  <div class="mg-userdiag__empty">No recent uploads found.</div>
                {{/if}}
              </div>
            </section>
            {{/if}}

            {{#if @controller.showRecentReports}}
            <section class="mg-userdiag__section">
              <h3>Recent reports by user</h3>
              <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
                {{#if @controller.recentReports.length}}
                  {{#each @controller.recentReports as |report|}}
                    <article class="mg-userdiag__activity-row">
                      <div>
                        <div class="mg-userdiag__row-title">{{report.reason_label}}</div>
                        <div class="mg-userdiag__row-meta">{{report.typeLabel}} · {{report.media_title}}</div>
                      </div>
                      <div class="mg-userdiag__row-help">{{report.createdAtLabel}} · {{report.media_public_id}}</div>
                      <div class="mg-userdiag__actions">
                        <span class="mg-userdiag__badge {{report.statusClass}}">{{report.statusLabel}}</span>
                        <a class="btn" href={{report.reportUrl}} target="_blank" rel="noopener noreferrer">Open</a>
                      </div>
                    </article>
                  {{/each}}
                {{else}}
                  <div class="mg-userdiag__empty">No recent reports found.</div>
                {{/if}}
              </div>
            </section>
            {{/if}}
          </div>

          {{#if @controller.showRecentLogs}}
          <section class="mg-userdiag__section" style="margin-top: 1rem;">
            <h3>Recent log events</h3>
            <div class="mg-userdiag__list" style="margin-top: 0.85rem;">
              {{#if @controller.recentLogs.length}}
                {{#each @controller.recentLogs as |event|}}
                  <article class="mg-userdiag__activity-row mg-userdiag__log-row">
                    <div>
                      <div class="mg-userdiag__row-title">{{event.eventLabel}}</div>
                      <div class="mg-userdiag__row-meta">{{event.createdAtLabel}} · {{event.category}}</div>
                    </div>
                    <div class="mg-userdiag__row-help">
                      {{#if event.media_title}}{{event.media_title}} · {{/if}}{{event.message}}
                    </div>
                    <div class="mg-userdiag__actions">
                      <span class="mg-userdiag__badge {{event.severityClass}}">{{event.severityLabel}}</span>
                      <a class="btn" href={{event.logUrl}} target="_blank" rel="noopener noreferrer">Open</a>
                    </div>
                  </article>
                {{/each}}
              {{else}}
                <div class="mg-userdiag__empty">No recent log events found.</div>
              {{/if}}
            </div>
          </section>
          {{/if}}
        </section>

        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__panel-header">
            <div class="mg-userdiag__copy">
              <h2>Uploaded media</h2>
              <p class="mg-userdiag__muted">{{@controller.uploadedMediaCountLabel}}</p>
            </div>
            {{#if @controller.uploadedMediaManagementUrl}}
              <a class="btn" href={{@controller.uploadedMediaManagementUrl}} target="_blank" rel="noopener noreferrer">Open user's videos in Management</a>
            {{/if}}
          </div>

          {{#if @controller.hasUploadedMediaItems}}
            <div class="mg-userdiag__pagination">
              <span class="mg-userdiag__muted">{{@controller.uploadedMediaPageLabel}}</span>
              <div class="mg-userdiag__pagination-controls">
                <label class="mg-userdiag__muted" for="media-gallery-uploaded-media-per-page">Per page</label>
                <select id="media-gallery-uploaded-media-per-page" value={{@controller.uploadedMediaPerPage}} {{on "change" @controller.onUploadedMediaPerPageChange}}>
                  <option value="10">10</option>
                  <option value="20">20</option>
                </select>
                <button class="btn" type="button" disabled={{@controller.uploadedMediaPreviousDisabled}} {{on "click" @controller.previousUploadedMediaPage}}>Previous</button>
                <button class="btn" type="button" disabled={{@controller.uploadedMediaNextDisabled}} {{on "click" @controller.nextUploadedMediaPage}}>Next</button>
              </div>
            </div>
            <div class="mg-userdiag__list">
              {{#each @controller.uploadedMediaItems as |item|}}
                <article class="mg-userdiag__upload-card">
                  {{#if item.thumbnail_url}}
                    <img class="mg-userdiag__media-thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-userdiag__media-thumb-placeholder">No thumbnail</div>
                  {{/if}}
                  <div class="mg-userdiag__upload-main">
                    <div class="mg-userdiag__result-title">{{item.title}}</div>
                    <div class="mg-userdiag__muted">{{item.public_id}} · {{item.createdAtLabel}}</div>
                    <div class="mg-userdiag__muted">{{item.tagsLabel}}</div>
                  </div>
                  <a class="btn mg-userdiag__upload-action" href={{item.management_url}} target="_blank" rel="noopener noreferrer">Manage</a>
                  <div class="mg-userdiag__upload-badges">
                    <span class="mg-userdiag__badge {{item.statusClass}}">{{item.statusLabel}}</span>
                    <span class="mg-userdiag__badge">{{item.typeLabel}}</span>
                    <span class="mg-userdiag__badge">{{item.containsLabel}}</span>
                    <span class="mg-userdiag__badge {{item.visibilityClass}}">{{item.visibilityLabel}}</span>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <div class="mg-userdiag__empty">No uploaded media found for this user.</div>
          {{/if}}
        </section>
      {{else}}
        <section class="mg-userdiag__panel">
          <div class="mg-userdiag__empty">Search and select a user to view media diagnostics.</div>
        </section>
      {{/if}}
    </div>
  </template>
);
