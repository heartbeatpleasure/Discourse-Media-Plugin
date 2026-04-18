import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-test-downloads {
        --mg-td-surface: var(--secondary);
        --mg-td-surface-alt: var(--primary-very-low);
        --mg-td-border: var(--primary-low);
        --mg-td-muted: var(--primary-medium);
        --mg-td-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-test-downloads h1,
      .media-gallery-admin-test-downloads h2,
      .media-gallery-admin-test-downloads h3,
      .media-gallery-admin-test-downloads p {
        margin: 0;
      }

      .mg-test-downloads__grid,
      .mg-test-downloads__filters,
      .mg-test-downloads__results,
      .mg-test-downloads__artifacts,
      .mg-test-downloads__selected-meta,
      .mg-test-downloads__artifact-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-test-downloads__grid {
        grid-template-columns: minmax(0, 1.15fr) minmax(360px, 0.95fr);
        align-items: start;
      }

      .mg-test-downloads__panel {
        background: var(--mg-td-surface);
        border: 1px solid var(--mg-td-border);
        border-radius: var(--mg-td-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-test-downloads__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-test-downloads__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-test-downloads__muted,
      .mg-test-downloads__meta-label,
      .mg-test-downloads__field label,
      .mg-test-downloads__helper,
      .mg-test-downloads__results-footer,
      .mg-test-downloads__empty,
      .mg-test-downloads__artifact-meta {
        color: var(--mg-td-muted);
      }

      .mg-test-downloads__muted,
      .mg-test-downloads__meta-label,
      .mg-test-downloads__field label,
      .mg-test-downloads__helper,
      .mg-test-downloads__results-footer,
      .mg-test-downloads__artifact-meta {
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__filters {
        grid-template-columns: repeat(4, minmax(0, 1fr));
        align-items: end;
      }

      .mg-test-downloads__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-test-downloads__field.is-search {
        grid-column: 1 / -1;
      }

      .mg-test-downloads__field label {
        font-weight: 600;
      }

      .mg-test-downloads__field input,
      .mg-test-downloads__field select {
        width: 100%;
        box-sizing: border-box;
        min-height: 42px;
        border-radius: 12px;
        border: 1px solid var(--mg-td-border);
        background: var(--primary-very-low);
      }

      .mg-test-downloads__filters-footer,
      .mg-test-downloads__button-row,
      .mg-test-downloads__badge-row {
        display: flex;
        align-items: center;
        gap: 0.75rem;
        flex-wrap: wrap;
      }

      .mg-test-downloads__filters-footer {
        justify-content: space-between;
        margin-top: 1rem;
      }

      .mg-test-downloads__results-wrap,
      .mg-test-downloads__results {
        margin-top: 0.5rem;
      }

      .mg-test-downloads__result-card {
        display: grid;
        grid-template-columns: 128px minmax(0, 1fr) auto;
        grid-template-areas:
          "thumb main action"
          "badges badges badges";
        gap: 0.85rem 1rem;
        align-items: start;
        padding: 0.9rem;
        border: 1px solid var(--mg-td-border);
        border-radius: 16px;
        background: var(--mg-td-surface-alt);
      }

      .mg-test-downloads__result-card.is-selected {
        border-color: var(--tertiary);
        box-shadow: inset 0 0 0 1px var(--tertiary);
        background: var(--secondary);
      }

      .mg-test-downloads__thumb,
      .mg-test-downloads__thumb-placeholder {
        width: 128px;
        aspect-ratio: 16 / 9;
        border-radius: 14px;
        border: 1px solid var(--mg-td-border);
        background: var(--secondary);
        grid-area: thumb;
        align-self: start;
      }

      .mg-test-downloads__thumb {
        object-fit: cover;
      }

      .mg-test-downloads__thumb-placeholder,
      .mg-test-downloads__selected-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 0.5rem;
        text-align: center;
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        box-sizing: border-box;
      }

      .mg-test-downloads__result-copy,
      .mg-test-downloads__selected-copy {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-test-downloads__result-copy {
        grid-area: main;
        align-self: start;
      }

      .mg-test-downloads__result-title,
      .mg-test-downloads__selected-title,
      .mg-test-downloads__artifact-title {
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__result-title {
        font-size: 1.1rem;
      }

      .mg-test-downloads__result-id,
      .mg-test-downloads__result-meta,
      .mg-test-downloads__selected-subtitle {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__result-id {
        font-family: inherit;
        white-space: normal;
        overflow: visible;
        text-overflow: unset;
        word-break: normal;
        overflow-wrap: normal;
      }

      .mg-test-downloads__badge {
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

      .mg-test-downloads__badge.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-test-downloads__badge.is-warning {
        background: var(--highlight-low);
        border-color: var(--highlight-medium);
        color: var(--primary-high);
      }

      .mg-test-downloads__badge.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-test-downloads__result-tags {
        grid-area: badges;
        display: flex;
        align-items: center;
        gap: 0.75rem;
        flex-wrap: wrap;
      }

      .mg-test-downloads__result-action {
        grid-area: action;
        align-self: start;
      }

      .mg-test-downloads__selected-card {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .mg-test-downloads__selected-hero {
        display: grid;
        grid-template-columns: 180px minmax(0, 1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-test-downloads__selected-tags {
        display: flex;
        align-items: center;
        gap: 0.75rem;
        flex-wrap: wrap;
      }

      .mg-test-downloads__selected-thumb,
      .mg-test-downloads__selected-thumb-placeholder {
        width: 180px;
        aspect-ratio: 16 / 9;
        border-radius: 16px;
        border: 1px solid var(--mg-td-border);
        background: var(--secondary);
      }

      .mg-test-downloads__selected-thumb {
        object-fit: cover;
      }

      .mg-test-downloads__selected-meta {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-test-downloads__meta-card,
      .mg-test-downloads__artifact-card {
        border: 1px solid var(--mg-td-border);
        border-radius: 16px;
        background: var(--mg-td-surface-alt);
        padding: 0.9rem 1rem;
      }

      .mg-test-downloads__meta-value {
        font-weight: 700;
        margin-top: 0.2rem;
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__notice {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--mg-td-border);
      }

      .mg-test-downloads__notice.is-info {
        background: var(--primary-very-low);
      }

      .mg-test-downloads__notice.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-test-downloads__notice.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-test-downloads__notice.is-warning {
        background: var(--highlight-low);
        border-color: var(--highlight-medium);
      }

      .mg-test-downloads__empty {
        border: 1px dashed var(--mg-td-border);
        border-radius: 16px;
        padding: 1rem;
        background: var(--mg-td-surface-alt);
      }

      .mg-test-downloads__artifact-grid {
        grid-template-columns: 1fr;
        margin-top: 1rem;
      }

      .mg-test-downloads__artifact-card {
        display: grid;
        grid-template-columns: 200px minmax(0, 1fr) auto;
        grid-template-areas:
          "thumb main action"
          "thumb stats action";
        gap: 0.9rem 1rem;
        align-items: start;
      }

      .mg-test-downloads__artifact-media {
        grid-area: thumb;
        display: flex;
        flex-direction: column;
        gap: 0.6rem;
      }

      .mg-test-downloads__artifact-thumb,
      .mg-test-downloads__artifact-thumb-placeholder {
        width: 100%;
        aspect-ratio: 16 / 9;
        border-radius: 14px;
        border: 1px solid var(--mg-td-border);
        background: var(--secondary);
      }

      .mg-test-downloads__artifact-thumb {
        object-fit: cover;
      }

      .mg-test-downloads__artifact-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        text-align: center;
        padding: 0.75rem;
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        box-sizing: border-box;
      }

      .mg-test-downloads__artifact-copy {
        grid-area: main;
        display: flex;
        flex-direction: column;
        gap: 0.45rem;
        min-width: 0;
      }

      .mg-test-downloads__artifact-title-row {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .mg-test-downloads__artifact-id {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__artifact-actions {
        grid-area: action;
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: 0.75rem;
        min-width: 132px;
      }

      .mg-test-downloads__artifact-stats {
        grid-area: stats;
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 0.75rem;
      }

      .mg-test-downloads__artifact-stat {
        border: 1px solid var(--mg-td-border);
        border-radius: 14px;
        background: var(--secondary);
        padding: 0.75rem 0.85rem;
      }

      .mg-test-downloads__artifact-stat .mg-test-downloads__meta-label {
        display: block;
        margin-bottom: 0.2rem;
      }

      .mg-test-downloads__artifact-stat-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      @media (max-width: 1120px) {
        .mg-test-downloads__grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 900px) {
        .mg-test-downloads__filters,
        .mg-test-downloads__selected-meta,
        .mg-test-downloads__artifact-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .mg-test-downloads__artifact-card {
          grid-template-columns: 160px minmax(0, 1fr);
          grid-template-areas:
            "thumb main"
            "stats stats"
            "action action";
        }

        .mg-test-downloads__artifact-actions {
          align-items: flex-start;
          min-width: 0;
        }

        .mg-test-downloads__artifact-stats {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .mg-test-downloads__result-card {
          grid-template-columns: 128px minmax(0, 1fr);
          grid-template-areas:
            "thumb main"
            "action action"
            "badges badges";
        }

        .mg-test-downloads__selected-hero {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 640px) {
        .mg-test-downloads__filters,
        .mg-test-downloads__selected-meta,
        .mg-test-downloads__artifact-grid,
        .mg-test-downloads__result-card,
        .mg-test-downloads__artifact-stats {
          grid-template-columns: 1fr;
        }

        .mg-test-downloads__artifact-card {
          grid-template-columns: 1fr;
          grid-template-areas:
            "thumb"
            "main"
            "stats"
            "action";
        }

        .mg-test-downloads__artifact-actions {
          align-items: flex-start;
        }

        .mg-test-downloads__result-card {
          grid-template-areas:
            "thumb"
            "main"
            "action"
            "badges";
        }
      }
    </style>

    <div class="media-gallery-admin-test-downloads">
      <section class="mg-test-downloads__panel">
        <div class="mg-test-downloads__panel-header">
          <div class="mg-test-downloads__panel-copy">
            <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
            <p class="mg-test-downloads__muted">Browse videos visually, pick one from the list, then generate a forensic test download for a detected or manual user.</p>
          </div>
        </div>

        <div class="mg-test-downloads__notice is-info">
          This page is admin-only. Start from the video list instead of entering IDs manually whenever possible.
        </div>

        <div class="mg-test-downloads__filters" style="margin-top: 1rem;">
          <div class="mg-test-downloads__field is-search">
            <label>Search</label>
            <input
              class="admin-input"
              type="text"
              autocomplete="off"
              autocapitalize="off"
              autocorrect="off"
              spellcheck="false"
              data-lpignore="true"
              value={{@controller.searchQuery}}
              placeholder="Search by public_id / title / id..."
              {{on "input" @controller.onSearchInput}}
              {{on "keydown" @controller.onSearchKeydown}}
            />
          </div>

          <div class="mg-test-downloads__field">
            <label>Backend</label>
            <select class="combobox" value={{@controller.backendFilter}} {{on "change" @controller.onBackendChange}}>
              <option value="">All</option>
              <option value="local">Local</option>
              <option value="s3">S3</option>
            </select>
          </div>

          <div class="mg-test-downloads__field">
            <label>Status</label>
            <select class="combobox" value={{@controller.statusFilter}} {{on "change" @controller.onStatusChange}}>
              <option value="">All</option>
              <option value="ready">Ready</option>
              <option value="queued">Queued</option>
              <option value="processing">Processing</option>
              <option value="failed">Failed</option>
            </select>
          </div>

          <div class="mg-test-downloads__field">
            <label>HLS</label>
            <select class="combobox" value={{@controller.hasHlsFilter}} {{on "change" @controller.onHasHlsChange}}>
              <option value="true">Ready only</option>
              <option value="false">Without HLS</option>
              <option value="">All</option>
            </select>
          </div>

          <div class="mg-test-downloads__field">
            <label>Sort</label>
            <select class="combobox" value={{@controller.sort}} {{on "change" @controller.onSortChange}}>
              <option value="newest">Newest</option>
              <option value="oldest">Oldest</option>
              <option value="updated_desc">Recently updated</option>
              <option value="title_asc">Title A–Z</option>
              <option value="title_desc">Title Z–A</option>
            </select>
          </div>

          <div class="mg-test-downloads__field">
            <label>Limit</label>
            <select class="combobox" value={{@controller.limit}} {{on "change" @controller.onLimitChange}}>
              <option value="12">12</option>
              <option value="24">24</option>
              <option value="48">48</option>
              <option value="96">96</option>
            </select>
          </div>
        </div>

        <div class="mg-test-downloads__filters-footer">
          <div class="mg-test-downloads__button-row">
            <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.searchButtonDisabled}}>
              {{if @controller.isSearching "Searching…" "Search"}}
            </button>
            <button class="btn" type="button" {{on "click" @controller.clearSearch}} disabled={{@controller.isSearching}}>
              Reset
            </button>
            <button class="btn" type="button" {{on "click" @controller.useTypedPublicId}} disabled={{@controller.useTypedPublicIdDisabled}}>
              Use entered public_id
            </button>
          </div>
          <div class="mg-test-downloads__results-footer">{{@controller.searchInfo}}</div>
        </div>

        {{#if @controller.searchError}}
          <div class="mg-test-downloads__notice is-danger" style="margin-top: 1rem;">{{@controller.searchError}}</div>
        {{/if}}
      </section>

      <div class="mg-test-downloads__grid">
        <section class="mg-test-downloads__panel">
          <div class="mg-test-downloads__panel-header">
            <div class="mg-test-downloads__panel-copy">
              <h2>Results</h2>
              <p class="mg-test-downloads__muted">Choose a video from the current result set to prepare a forensic test download.</p>
            </div>
          </div>

          <div class="mg-test-downloads__results-wrap">
            {{#if @controller.searchResults.length}}
              <div class="mg-test-downloads__results">
                {{#each @controller.searchResults key="public_id" as |item|}}
                  <article class="mg-test-downloads__result-card {{if item.isSelected 'is-selected'}}">
                    {{#if item.thumbnail_url}}
                      <img class="mg-test-downloads__thumb" loading="lazy" src={{item.thumbnail_url}} alt={{item.displayTitle}} />
                    {{else}}
                      <div class="mg-test-downloads__thumb-placeholder">No thumbnail</div>
                    {{/if}}

                    <div class="mg-test-downloads__result-copy">
                      <div class="mg-test-downloads__result-title">{{item.displayTitle}}</div>
                      <div class="mg-test-downloads__result-id">{{item.displayPublicId}}</div>
                      <div class="mg-test-downloads__result-meta">by {{item.displayOwner}} · {{item.displayCreatedAt}}</div>
                    </div>

                    <button class="btn mg-test-downloads__result-action {{if item.isSelected 'btn-primary'}}" type="button" {{on "click" (fn @controller.pickItem item)}}>
                      {{if item.isSelected "Selected" "Use"}}
                    </button>

                    <div class="mg-test-downloads__result-tags">
                      <span class="mg-test-downloads__badge {{item.statusClassName}}">{{item.displayStatus}}</span>
                      <span class="mg-test-downloads__badge">{{item.displayMediaType}}</span>
                      <span class="mg-test-downloads__badge">{{item.displayBackend}}</span>
                      <span class="mg-test-downloads__badge">{{item.hasHlsLabel}}</span>
                    </div>
                  </article>
                {{/each}}
              </div>
            {{else if @controller.hasSearched}}
              <div class="mg-test-downloads__empty">
                No videos found. Try a broader search or reset the filters.
              </div>
            {{/if}}
          </div>
        </section>

        <section class="mg-test-downloads__panel">
          <div class="mg-test-downloads__panel-header">
            <div class="mg-test-downloads__panel-copy">
              <h2>Selected video</h2>
              <p class="mg-test-downloads__muted">Pick a result, choose a user, then generate a full or partial forensic test download.</p>
            </div>
          </div>

          {{#if @controller.selectionMessage}}
            <div class={{@controller.selectionMessageClass}} style="margin-bottom: 1rem;">{{@controller.selectionMessage}}</div>
          {{/if}}

          {{#if @controller.hasSelectedItem}}
            <div class="mg-test-downloads__selected-card">
              <div class="mg-test-downloads__selected-hero">
                {{#if @controller.selectedItem.thumbnail_url}}
                  <img class="mg-test-downloads__selected-thumb" src={{@controller.selectedItem.thumbnail_url}} alt={{@controller.selectedItem.displayTitle}} />
                {{else}}
                  <div class="mg-test-downloads__selected-thumb-placeholder">No thumbnail</div>
                {{/if}}

                <div class="mg-test-downloads__selected-copy">
                  <div class="mg-test-downloads__selected-title">{{@controller.selectedItem.displayTitle}}</div>
                  <div class="mg-test-downloads__selected-subtitle">{{@controller.publicId}}</div>
                </div>
              </div>

              <div class="mg-test-downloads__selected-tags">
                <span class="mg-test-downloads__badge {{@controller.selectedItem.statusClassName}}">{{@controller.selectedItem.displayStatus}}</span>
                <span class="mg-test-downloads__badge">{{@controller.selectedItem.displayMediaType}}</span>
                <span class="mg-test-downloads__badge">{{@controller.selectedItem.displayBackend}}</span>
                <span class="mg-test-downloads__badge">{{@controller.selectedItem.hasHlsLabel}}</span>
              </div>

              <div class="mg-test-downloads__selected-meta">
                <div class="mg-test-downloads__meta-card">
                  <div class="mg-test-downloads__meta-label">Created</div>
                  <div class="mg-test-downloads__meta-value">{{@controller.selectedItem.displayCreatedAt}}</div>
                </div>
                <div class="mg-test-downloads__meta-card">
                  <div class="mg-test-downloads__meta-label">Updated</div>
                  <div class="mg-test-downloads__meta-value">{{@controller.selectedItem.displayUpdatedAt}}</div>
                </div>
              </div>

              <div class="mg-test-downloads__field">
                <label>Users</label>
                <select class="combobox" value={{@controller.selectedUserId}} {{on "change" @controller.onUserSelect}}>
                  <option value="">Select a user</option>
                  {{#each @controller.users key="id" as |user|}}
                    <option value={{user.id}}>{{user.username}} (#{{user.id}})</option>
                  {{/each}}
                </select>
                <div class="mg-test-downloads__helper">Users are loaded from fingerprints and playback sessions for this video.</div>
              </div>

              <div class="mg-test-downloads__button-row">
                <button class="btn" type="button" {{on "click" @controller.loadUsers}} disabled={{@controller.isLoadingUsers}}>
                  {{if @controller.isLoadingUsers "Loading users…" "Reload users"}}
                </button>
              </div>

              {{#if @controller.usersError}}
                <div class="mg-test-downloads__notice is-danger">{{@controller.usersError}}</div>
              {{/if}}

              {{#if @controller.showNoUsersWarning}}
                <div class="mg-test-downloads__notice is-warning">
                  No users found yet for this video. You can still enter a user ID manually.
                </div>
              {{/if}}

              <div class="mg-test-downloads__field">
                <label>Manual user ID</label>
                <input
                  class="admin-input"
                  type="number"
                  autocomplete="off"
                  autocapitalize="off"
                  autocorrect="off"
                  spellcheck="false"
                  data-lpignore="true"
                  min="1"
                  value={{@controller.manualUserId}}
                  placeholder="Enter user ID"
                  {{on "input" @controller.onManualUserIdInput}}
                />
                <div class="mg-test-downloads__helper">Only needed when no user is detected automatically.</div>
              </div>

              <div class="mg-test-downloads__button-row">
                <button class="btn btn-primary" type="button" {{on "click" @controller.generateFull}} disabled={{@controller.generateDisabled}}>
                  Generate full download
                </button>
                <button class="btn" type="button" {{on "click" @controller.generateRandomPartial}} disabled={{@controller.generateDisabled}}>
                  Generate random partial (~40–50%)
                </button>
              </div>

              {{#if @controller.generateError}}
                <div class="mg-test-downloads__notice is-danger">{{@controller.generateError}}</div>
              {{/if}}
            </div>
          {{else}}
            <div class="mg-test-downloads__empty">
              Select a video from the results list to load user options and generate a forensic test download.
            </div>
          {{/if}}
        </section>
      </div>

      <section class="mg-test-downloads__panel">
        <div class="mg-test-downloads__panel-header">
          <div class="mg-test-downloads__panel-copy">
            <h2>{{i18n "admin.media_gallery.test_downloads.generated"}}</h2>
            <p class="mg-test-downloads__muted">Downloads generated during this admin session.</p>
          </div>
        </div>

        {{#if @controller.hasArtifacts}}
          <div class="mg-test-downloads__artifact-grid">
            {{#each @controller.artifacts key="download_url" as |artifact|}}
              <div class="mg-test-downloads__artifact-card">
                <div class="mg-test-downloads__artifact-media">
                  {{#if artifact.thumbUrl}}
                    <img class="mg-test-downloads__artifact-thumb" loading="lazy" src={{artifact.thumbUrl}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-test-downloads__artifact-thumb-placeholder">No thumbnail available</div>
                  {{/if}}
                  <div class="mg-test-downloads__badge-row">
                    <span class="mg-test-downloads__badge {{artifact.modeClassName}}">{{artifact.displayArtifactType}}</span>
                    {{#if artifact.displayRegion}}
                      <span class="mg-test-downloads__badge">{{artifact.displayRegion}}</span>
                    {{/if}}
                  </div>
                </div>

                <div class="mg-test-downloads__artifact-copy">
                  <div class="mg-test-downloads__artifact-title-row">
                    <div>
                      <div class="mg-test-downloads__artifact-title">{{if artifact.displayTitle artifact.displayTitle artifact.displayPublicId}}</div>
                      {{#if artifact.displayTitle}}
                        <div class="mg-test-downloads__artifact-id">{{artifact.displayPublicId}}</div>
                      {{/if}}
                    </div>
                  </div>
                  <div class="mg-test-downloads__artifact-meta">{{artifact.displayCreatedAt}} · {{artifact.displayUser}}</div>
                  <div class="mg-test-downloads__artifact-meta">{{artifact.displayArtifactSummary}}</div>
                </div>

                <div class="mg-test-downloads__artifact-actions">
                  <button class="btn btn-primary" type="button" {{on "click" (fn @controller.downloadArtifact artifact)}}>
                    Download
                  </button>
                  <div class="mg-test-downloads__artifact-meta">MP4 artifact</div>
                </div>

                <div class="mg-test-downloads__artifact-stats">
                  <div class="mg-test-downloads__artifact-stat">
                    <span class="mg-test-downloads__meta-label">Segments</span>
                    <div class="mg-test-downloads__artifact-stat-value">{{artifact.displaySegments}}</div>
                  </div>
                  <div class="mg-test-downloads__artifact-stat">
                    <span class="mg-test-downloads__meta-label">Mode</span>
                    <div class="mg-test-downloads__artifact-stat-value">{{artifact.displayMode}}</div>
                  </div>
                  <div class="mg-test-downloads__artifact-stat">
                    <span class="mg-test-downloads__meta-label">Coverage</span>
                    <div class="mg-test-downloads__artifact-stat-value">{{if artifact.displayClipPercent artifact.displayClipPercent "Full video"}}</div>
                  </div>
                </div>
              </div>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-test-downloads__empty">{{i18n "admin.media_gallery.test_downloads.none_generated"}}</div>
        {{/if}}
      </section>
    </div>
  </template>
);
