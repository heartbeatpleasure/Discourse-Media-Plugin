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
        grid-template-columns: minmax(0, 1.18fr) minmax(360px, 0.92fr);
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
        margin-bottom: 1rem;
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

      .mg-test-downloads__results {
        margin-top: 1rem;
      }

      .mg-test-downloads__result-card {
        display: grid;
        grid-template-columns: 152px minmax(0, 1fr) auto;
        gap: 0.85rem 1rem;
        align-items: start;
        padding: 1rem;
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
        width: 152px;
        aspect-ratio: 16 / 9;
        border-radius: 14px;
        border: 1px solid var(--mg-td-border);
        background: var(--secondary);
      }

      .mg-test-downloads__thumb {
        object-fit: cover;
      }

      .mg-test-downloads__thumb-placeholder {
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
        gap: 0.3rem;
        min-width: 0;
      }

      .mg-test-downloads__result-main {
        display: contents;
      }

      .mg-test-downloads__result-title,
      .mg-test-downloads__selected-title,
      .mg-test-downloads__artifact-title {
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__result-title {
        font-size: 1.08rem;
      }

      .mg-test-downloads__result-id {
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
        color: var(--mg-td-muted);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .mg-test-downloads__selected-title {
        font-size: 1.35rem;
      }

      .mg-test-downloads__result-subtitle,
      .mg-test-downloads__selected-subtitle {
        font-size: var(--font-down-1);
        color: var(--mg-td-muted);
        overflow-wrap: anywhere;
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

      .mg-test-downloads__result-meta {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__result-tags {
        grid-column: 1 / -1;
        display: flex;
        align-items: center;
        gap: 0.75rem;
        flex-wrap: wrap;
        padding-top: 0.15rem;
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

      .mg-test-downloads__selected-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 0.5rem;
        text-align: center;
        color: var(--mg-td-muted);
        box-sizing: border-box;
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
        grid-template-columns: repeat(2, minmax(0, 1fr));
        margin-top: 1rem;
      }

      .mg-test-downloads__artifact-card {
        display: flex;
        flex-direction: column;
        gap: 0.6rem;
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

        .mg-test-downloads__result-card {
          grid-template-columns: 128px minmax(0, 1fr);
        }

        .mg-test-downloads__result-tags {
          grid-column: 1 / -1;
        }

        .mg-test-downloads__selected-hero {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 640px) {
        .mg-test-downloads__filters,
        .mg-test-downloads__selected-meta,
        .mg-test-downloads__artifact-grid,
        .mg-test-downloads__result-card {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-test-downloads">
      <div class="mg-test-downloads__panel">
        <div class="mg-test-downloads__panel-header">
          <div class="mg-test-downloads__panel-copy">
            <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
            <p class="mg-test-downloads__muted">{{i18n "admin.media_gallery.test_downloads.description"}}</p>
          </div>
        </div>
        <div class="mg-test-downloads__notice is-info">
          This page is admin-only. Choose a video, select a user found in fingerprints or playback sessions, then generate a forensic test download.
        </div>
      </div>

      <div class="mg-test-downloads__grid">
        <div class="mg-test-downloads__panel">
          <div class="mg-test-downloads__panel-header">
            <div class="mg-test-downloads__panel-copy">
              <h2>Browse videos</h2>
              <p class="mg-test-downloads__muted">Search by title or public_id and work from a visual list instead of entering IDs manually.</p>
            </div>
          </div>

          <div class="mg-test-downloads__filters">
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
                placeholder="Search by title or public_id"
                {{on "input" @controller.onSearchInput}}
                {{on "keydown" @controller.onSearchKeydown}}
              />
            </div>

            <div class="mg-test-downloads__field">
              <label>Backend</label>
              <select class="combobox" value={{@controller.backendFilter}} {{on "change" @controller.onBackendChange}}>
                <option value="">All backends</option>
                <option value="local">Local</option>
                <option value="s3">S3</option>
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Status</label>
              <select class="combobox" value={{@controller.statusFilter}} {{on "change" @controller.onStatusChange}}>
                <option value="">All statuses</option>
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
                <option value="">All videos</option>
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Sort</label>
              <select class="combobox" value={{@controller.sort}} {{on "change" @controller.onSortChange}}>
                <option value="newest">Newest first</option>
                <option value="oldest">Oldest first</option>
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
                Reset filters
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

          {{#if @controller.showNoResults}}
            <div class="mg-test-downloads__empty" style="margin-top: 1rem;">
              No videos found for the current filters. Try broadening the search or use an exact public_id.
            </div>
          {{/if}}

          {{#if @controller.searchResults.length}}
            <div class="mg-test-downloads__results">
              {{#each @controller.searchResults key="public_id" as |item|}}
                <div class="mg-test-downloads__result-card {{if item.isSelected 'is-selected'}}">
                  {{#if item.thumbnail_url}}
                    <img class="mg-test-downloads__thumb" src={{item.thumbnail_url}} alt={{item.displayTitle}} loading="lazy" />
                  {{else}}
                    <div class="mg-test-downloads__thumb-placeholder">No thumbnail</div>
                  {{/if}}

                  <div class="mg-test-downloads__result-copy">
                    <div class="mg-test-downloads__result-title">{{item.displayTitle}}</div>
                    <div class="mg-test-downloads__result-id">{{item.displayPublicId}}</div>
                    <div class="mg-test-downloads__result-meta">by {{item.displayOwner}} · {{item.displayCreatedAt}}</div>
                  </div>

                  <div>
                    <button class="btn {{if item.isSelected 'btn-primary'}}" type="button" {{on "click" (fn @controller.pickItem item)}}>
                      {{if item.isSelected "Selected" "Use"}}
                    </button>
                  </div>

                  <div class="mg-test-downloads__result-tags">
                    <span class="mg-test-downloads__badge {{item.statusClassName}}">{{item.displayStatus}}</span>
                    <span class="mg-test-downloads__badge">{{item.displayMediaType}}</span>
                    <span class="mg-test-downloads__badge">{{item.displayBackend}}</span>
                    <span class="mg-test-downloads__badge">{{item.hasHlsLabel}}</span>
                  </div>
                </div>
              {{/each}}
            </div>
          {{/if}}
        </div>

        <div class="mg-test-downloads__panel">
          <div class="mg-test-downloads__panel-header">
            <div class="mg-test-downloads__panel-copy">
              <h2>Selected video</h2>
              <p class="mg-test-downloads__muted">Pick a result, choose a user, then generate a full or partial forensic test download.</p>
            </div>
          </div>

          {{#if @controller.selectionMessage}}
            <div class="mg-test-downloads__notice is-info" style="margin-bottom: 1rem;">{{@controller.selectionMessage}}</div>
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
                  <div class="mg-test-downloads__selected-subtitle">{{@controller.selectedItem.displayOwner}}</div>
                  <div class="mg-test-downloads__selected-subtitle"><code>{{@controller.publicId}}</code></div>
                  <div class="mg-test-downloads__badge-row">
                    <span class="mg-test-downloads__badge {{@controller.selectedItem.statusClassName}}">{{@controller.selectedItem.displayStatus}}</span>
                    <span class="mg-test-downloads__badge">{{@controller.selectedItem.displayBackend}}</span>
                    <span class="mg-test-downloads__badge">{{@controller.selectedItem.hasHlsLabel}}</span>
                  </div>
                </div>
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
              Select a video from the list on the left to load user options and generate a forensic test download.
            </div>
          {{/if}}
        </div>
      </div>

      <div class="mg-test-downloads__panel">
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
                <div class="mg-test-downloads__artifact-title">{{artifact.public_id}}</div>
                <div class="mg-test-downloads__artifact-meta">{{artifact.displayCreatedAt}} · {{artifact.displayUser}}</div>
                <div class="mg-test-downloads__badge-row">
                  <span class="mg-test-downloads__badge">{{artifact.displayMode}}</span>
                  {{#if artifact.displayRegion}}
                    <span class="mg-test-downloads__badge">{{artifact.displayRegion}}</span>
                  {{/if}}
                </div>
                <div class="mg-test-downloads__artifact-meta">{{artifact.displaySegments}}</div>
                <div>
                  <button class="btn btn-primary" type="button" {{on "click" (fn @controller.downloadArtifact artifact)}}>
                    Download
                  </button>
                </div>
              </div>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-test-downloads__empty">{{i18n "admin.media_gallery.test_downloads.none_generated"}}</div>
        {{/if}}
      </div>
    </div>
  </template>
);
