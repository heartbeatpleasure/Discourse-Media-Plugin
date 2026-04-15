import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-test-downloads {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
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
      .mg-test-downloads__results-list,
      .mg-test-downloads__artifacts-list,
      .mg-test-downloads__meta-grid,
      .mg-test-downloads__selected-meta,
      .mg-test-downloads__user-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-test-downloads__grid {
        grid-template-columns: minmax(0, 1.2fr) minmax(360px, 0.9fr);
        align-items: start;
      }

      .mg-test-downloads__panel,
      .mg-test-downloads__flash,
      .mg-test-downloads__metric,
      .mg-test-downloads__result-card,
      .mg-test-downloads__artifact-card {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-test-downloads__panel,
      .mg-test-downloads__flash {
        padding: 1rem 1.125rem;
      }

      .mg-test-downloads__panel-header,
      .mg-test-downloads__section-header,
      .mg-test-downloads__selected-header,
      .mg-test-downloads__artifact-header,
      .mg-test-downloads__result-header {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 0.85rem;
      }

      .mg-test-downloads__panel-header,
      .mg-test-downloads__section-header {
        margin-bottom: 0.9rem;
      }

      .mg-test-downloads__panel-copy,
      .mg-test-downloads__section-copy,
      .mg-test-downloads__selected-copy,
      .mg-test-downloads__result-copy,
      .mg-test-downloads__artifact-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-test-downloads__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__notice {
        display: inline-flex;
        align-items: center;
        gap: 0.35rem;
        padding: 0.32rem 0.65rem;
        border-radius: 999px;
        font-size: var(--font-down-1);
        background: var(--primary-very-low);
        border: 1px solid var(--primary-low);
        color: var(--primary-high);
      }

      .mg-test-downloads__flash.is-info {
        background: var(--primary-very-low);
      }

      .mg-test-downloads__flash.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-test-downloads__flash.is-warning {
        background: var(--tertiary-very-low);
        border-color: var(--tertiary-low);
        color: var(--primary-high);
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
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__field input,
      .mg-test-downloads__field select {
        min-height: 42px;
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
      }

      .mg-test-downloads__filters-footer,
      .mg-test-downloads__actions,
      .mg-test-downloads__user-actions,
      .mg-test-downloads__artifact-actions,
      .mg-test-downloads__result-actions,
      .mg-test-downloads__badge-row {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
      }

      .mg-test-downloads__filters-footer {
        margin-top: 1rem;
        align-items: center;
        justify-content: space-between;
      }

      .mg-test-downloads__badge,
      .mg-test-downloads__chip {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.24rem 0.62rem;
        font-size: var(--font-down-1);
        line-height: 1.2;
        white-space: nowrap;
        background: var(--primary-very-low);
        color: var(--primary-high);
        border: 1px solid var(--primary-low);
      }

      .mg-test-downloads__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-test-downloads__badge.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-test-downloads__results-list,
      .mg-test-downloads__artifacts-list {
        margin-top: 1rem;
      }

      .mg-test-downloads__result-card,
      .mg-test-downloads__artifact-card {
        padding: 0.95rem;
        background: var(--mg-surface-alt);
      }

      .mg-test-downloads__result-card {
        display: grid;
        grid-template-columns: 152px minmax(0, 1fr) auto;
        grid-template-areas:
          "thumb main actions"
          "thumb meta meta";
        gap: 0.9rem 1rem;
        align-items: start;
      }

      .mg-test-downloads__thumb,
      .mg-test-downloads__thumb-placeholder,
      .mg-test-downloads__selected-thumb,
      .mg-test-downloads__selected-thumb-placeholder {
        width: 100%;
        aspect-ratio: 16 / 9;
        border-radius: 14px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
        object-fit: cover;
      }

      .mg-test-downloads__thumb-wrap {
        grid-area: thumb;
        align-self: start;
      }

      .mg-test-downloads__thumb-placeholder,
      .mg-test-downloads__selected-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--mg-muted);
        text-align: center;
        padding: 0.5rem;
        box-sizing: border-box;
        font-size: var(--font-down-1);
      }

      .mg-test-downloads__result-main {
        grid-area: main;
        min-width: 0;
      }

      .mg-test-downloads__result-actions {
        grid-area: actions;
        justify-content: flex-end;
      }

      .mg-test-downloads__meta-grid {
        grid-area: meta;
        grid-template-columns: repeat(4, minmax(0, 1fr));
      }

      .mg-test-downloads__metric {
        padding: 0.8rem 0.95rem;
        min-width: 0;
      }

      .mg-test-downloads__metric-label {
        display: block;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        margin-bottom: 0.25rem;
      }

      .mg-test-downloads__metric-value {
        font-size: 1.15rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__result-title,
      .mg-test-downloads__selected-title,
      .mg-test-downloads__artifact-title {
        font-size: 1.15rem;
        font-weight: 700;
        line-height: 1.25;
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__result-subtitle,
      .mg-test-downloads__selected-subtitle,
      .mg-test-downloads__artifact-subtitle {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-test-downloads__selected-layout {
        display: grid;
        grid-template-columns: 180px minmax(0, 1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-test-downloads__selected-meta,
      .mg-test-downloads__user-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-test-downloads__artifact-card {
        display: grid;
        gap: 0.9rem;
      }

      .mg-test-downloads__artifact-top {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.9rem;
        align-items: start;
      }

      .mg-test-downloads__artifact-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.85rem;
      }

      .mg-test-downloads__empty {
        border: 1px dashed var(--mg-border);
        border-radius: 16px;
        padding: 1.1rem;
        text-align: center;
        color: var(--mg-muted);
        background: var(--primary-very-low);
      }

      @media (max-width: 1100px) {
        .mg-test-downloads__grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 900px) {
        .mg-test-downloads__filters,
        .mg-test-downloads__meta-grid,
        .mg-test-downloads__artifact-grid,
        .mg-test-downloads__selected-meta,
        .mg-test-downloads__user-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .mg-test-downloads__result-card,
        .mg-test-downloads__selected-layout,
        .mg-test-downloads__artifact-top {
          grid-template-columns: 1fr;
        }

        .mg-test-downloads__result-card {
          grid-template-areas:
            "thumb"
            "main"
            "actions"
            "meta";
        }
      }

      @media (max-width: 640px) {
        .mg-test-downloads__filters,
        .mg-test-downloads__meta-grid,
        .mg-test-downloads__artifact-grid,
        .mg-test-downloads__selected-meta,
        .mg-test-downloads__user-grid {
          grid-template-columns: 1fr;
        }

        .mg-test-downloads__filters-footer,
        .mg-test-downloads__panel-header,
        .mg-test-downloads__section-header,
        .mg-test-downloads__result-header,
        .mg-test-downloads__selected-header,
        .mg-test-downloads__artifact-header {
          flex-direction: column;
        }
      }
    </style>

    <div class="media-gallery-admin-test-downloads">
      <section class="mg-test-downloads__panel">
        <div class="mg-test-downloads__panel-header">
          <div class="mg-test-downloads__panel-copy">
            <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
            <p class="mg-test-downloads__muted">{{i18n "admin.media_gallery.test_downloads.description"}}</p>
          </div>
          <span class="mg-test-downloads__notice">Admin only · backend setting still enforced</span>
        </div>
      </section>

      {{#if @controller.selectionMessage}}
        <div class="mg-test-downloads__flash is-info">
          {{@controller.selectionMessage}}
        </div>
      {{/if}}

      {{#if @controller.searchError}}
        <div class="mg-test-downloads__flash is-danger">{{@controller.searchError}}</div>
      {{/if}}

      {{#if @controller.generateError}}
        <div class="mg-test-downloads__flash is-danger">{{@controller.generateError}}</div>
      {{/if}}

      <div class="mg-test-downloads__grid">
        <section class="mg-test-downloads__panel">
          <div class="mg-test-downloads__section-header">
            <div class="mg-test-downloads__section-copy">
              <h2>{{i18n "admin.media_gallery.test_downloads.search_label"}}</h2>
              <p class="mg-test-downloads__muted">{{i18n "admin.media_gallery.test_downloads.search_help"}}</p>
            </div>
            {{#if @controller.isSearching}}
              <span class="mg-test-downloads__badge">Searching…</span>
            {{else}}
              <span class="mg-test-downloads__muted">Browse recent video items or search by title / public_id</span>
            {{/if}}
          </div>

          <div class="mg-test-downloads__filters">
            <div class="mg-test-downloads__field is-search">
              <label>{{i18n "admin.media_gallery.test_downloads.search_label"}}</label>
              <input
                type="text"
                autocomplete="off"
                autocapitalize="off"
                autocorrect="off"
                spellcheck="false"
                data-lpignore="true"
                value={{@controller.searchQuery}}
                placeholder={{i18n "admin.media_gallery.test_downloads.search_placeholder"}}
                {{on "input" @controller.onSearchInput}}
                {{on "keydown" @controller.onSearchKeydown}}
              />
            </div>

            <div class="mg-test-downloads__field">
              <label>Type</label>
              <select value={{@controller.mediaTypeFilter}} {{on "change" @controller.onMediaTypeChange}}>
                {{#each @controller.mediaTypeOptions as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Status</label>
              <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusChange}}>
                {{#each @controller.statusOptions as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Backend</label>
              <select value={{@controller.backendFilter}} {{on "change" @controller.onBackendChange}}>
                {{#each @controller.backendOptions as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Sort</label>
              <select value={{@controller.sort}} {{on "change" @controller.onSortChange}}>
                {{#each @controller.sortOptions as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-test-downloads__field">
              <label>Limit</label>
              <select value={{@controller.limit}} {{on "change" @controller.onLimitChange}}>
                {{#each @controller.limitOptions as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>
          </div>

          <div class="mg-test-downloads__filters-footer">
            <div class="mg-test-downloads__actions">
              <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.searchButtonDisabled}}>
                {{if @controller.isSearching "Searching…" "Search"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.useTypedPublicId}} disabled={{@controller.useTypedPublicIdDisabled}}>
                Use entered public_id
              </button>
            </div>
            {{#if @controller.searchInfo}}
              <span class="mg-test-downloads__muted">{{@controller.searchInfo}}</span>
            {{/if}}
          </div>

          {{#if @controller.searchResults.length}}
            <div class="mg-test-downloads__results-list">
              {{#each @controller.decoratedSearchResults key="public_id" as |item|}}
                <article class="mg-test-downloads__result-card">
                  <div class="mg-test-downloads__thumb-wrap">
                    {{#if item.thumbnail_url}}
                      <img class="mg-test-downloads__thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                    {{else}}
                      <div class="mg-test-downloads__thumb-placeholder">No thumbnail</div>
                    {{/if}}
                  </div>

                  <div class="mg-test-downloads__result-main">
                    <div class="mg-test-downloads__result-header">
                      <div class="mg-test-downloads__result-copy">
                        <div class="mg-test-downloads__result-title">{{item.displayTitle}}</div>
                        <div class="mg-test-downloads__result-subtitle">{{item.public_id}}</div>
                      </div>
                    </div>
                    <div class="mg-test-downloads__badge-row" style="margin-top: 0.55rem;">
                      <span class={{item.statusBadgeClass}}>{{item.displayStatus}}</span>
                      <span class="mg-test-downloads__badge">{{item.displayType}}</span>
                      <span class="mg-test-downloads__badge">{{item.displayStorage}}</span>
                      {{#if item.profileLabel}}
                        <span class="mg-test-downloads__chip">{{item.profileLabel}}</span>
                      {{/if}}
                      {{#if item.has_hls}}
                        <span class="mg-test-downloads__chip">HLS ready</span>
                      {{/if}}
                    </div>
                  </div>

                  <div class="mg-test-downloads__result-actions">
                    <button class="btn" type="button" {{on "click" (fn @controller.pickItem item)}}>
                      Use
                    </button>
                  </div>

                  <div class="mg-test-downloads__meta-grid">
                    <div class="mg-test-downloads__metric">
                      <span class="mg-test-downloads__metric-label">Owner</span>
                      <div class="mg-test-downloads__metric-value">{{if item.username item.username "—"}}</div>
                    </div>
                    <div class="mg-test-downloads__metric">
                      <span class="mg-test-downloads__metric-label">Created</span>
                      <div class="mg-test-downloads__metric-value">{{item.createdLabel}}</div>
                    </div>
                    <div class="mg-test-downloads__metric">
                      <span class="mg-test-downloads__metric-label">Updated</span>
                      <div class="mg-test-downloads__metric-value">{{item.updatedLabel}}</div>
                    </div>
                    <div class="mg-test-downloads__metric">
                      <span class="mg-test-downloads__metric-label">Processed size</span>
                      <div class="mg-test-downloads__metric-value">{{item.sizeLabel}}</div>
                    </div>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else if @controller.showNoResults}}
            <div class="mg-test-downloads__empty" style="margin-top: 1rem;">
              No media items found. If you already know the exact public_id, use the button above to continue directly.
            </div>
          {{/if}}
        </section>

        <section class="mg-test-downloads__panel">
          {{#if @controller.hasSelectedItem}}
            <div class="mg-test-downloads__section-header">
              <div class="mg-test-downloads__section-copy">
                <h2>{{i18n "admin.media_gallery.test_downloads.selected_media"}}</h2>
                <p class="mg-test-downloads__muted">Choose a user and generate a personalized download variant.</p>
              </div>
            </div>

            <div class="mg-test-downloads__selected-layout">
              <div>
                {{#if @controller.decoratedSelectedItem.thumbnail_url}}
                  <img class="mg-test-downloads__selected-thumb" loading="lazy" src={{@controller.decoratedSelectedItem.thumbnail_url}} alt="thumbnail" />
                {{else}}
                  <div class="mg-test-downloads__selected-thumb-placeholder">No thumbnail</div>
                {{/if}}
              </div>

              <div>
                <div class="mg-test-downloads__selected-header">
                  <div class="mg-test-downloads__selected-copy">
                    <div class="mg-test-downloads__selected-title">{{@controller.decoratedSelectedItem.displayTitle}}</div>
                    <div class="mg-test-downloads__selected-subtitle">{{@controller.decoratedSelectedItem.public_id}}</div>
                  </div>
                </div>

                <div class="mg-test-downloads__badge-row" style="margin-top: 0.65rem;">
                  <span class={{@controller.decoratedSelectedItem.statusBadgeClass}}>{{@controller.decoratedSelectedItem.displayStatus}}</span>
                  <span class="mg-test-downloads__badge">{{@controller.decoratedSelectedItem.displayType}}</span>
                  <span class="mg-test-downloads__badge">{{@controller.decoratedSelectedItem.displayStorage}}</span>
                  {{#if @controller.decoratedSelectedItem.profileLabel}}
                    <span class="mg-test-downloads__chip">{{@controller.decoratedSelectedItem.profileLabel}}</span>
                  {{/if}}
                </div>
              </div>
            </div>

            <div class="mg-test-downloads__selected-meta" style="margin-top: 1rem;">
              <div class="mg-test-downloads__metric">
                <span class="mg-test-downloads__metric-label">Owner</span>
                <div class="mg-test-downloads__metric-value">{{if @controller.decoratedSelectedItem.username @controller.decoratedSelectedItem.username "—"}}</div>
              </div>
              <div class="mg-test-downloads__metric">
                <span class="mg-test-downloads__metric-label">Created</span>
                <div class="mg-test-downloads__metric-value">{{@controller.decoratedSelectedItem.createdLabel}}</div>
              </div>
              <div class="mg-test-downloads__metric">
                <span class="mg-test-downloads__metric-label">Updated</span>
                <div class="mg-test-downloads__metric-value">{{@controller.decoratedSelectedItem.updatedLabel}}</div>
              </div>
              <div class="mg-test-downloads__metric">
                <span class="mg-test-downloads__metric-label">Processed size</span>
                <div class="mg-test-downloads__metric-value">{{@controller.decoratedSelectedItem.sizeLabel}}</div>
              </div>
            </div>

            <div class="mg-test-downloads__user-grid" style="margin-top: 1rem;">
              <div class="mg-test-downloads__field">
                <label>{{i18n "admin.media_gallery.test_downloads.users_label"}}</label>
                <select value={{@controller.selectedUserId}} {{on "change" @controller.onUserSelect}}>
                  <option value="">-- select user --</option>
                  {{#each @controller.users as |user|}}
                    <option value={{user.id}}>{{user.username}} (#{{user.id}})</option>
                  {{/each}}
                </select>
                <span class="mg-test-downloads__muted">{{i18n "admin.media_gallery.test_downloads.users_help"}}</span>
              </div>

              <div class="mg-test-downloads__field">
                <label>{{i18n "admin.media_gallery.test_downloads.manual_user_id_label"}}</label>
                <input
                  type="number"
                  autocomplete="off"
                  autocapitalize="off"
                  autocorrect="off"
                  spellcheck="false"
                  data-lpignore="true"
                  min="1"
                  value={{@controller.manualUserId}}
                  placeholder={{i18n "admin.media_gallery.test_downloads.manual_user_id_placeholder"}}
                  {{on "input" @controller.onManualUserIdInput}}
                />
                <span class="mg-test-downloads__muted">Use manual input when no known users are listed yet.</span>
              </div>
            </div>

            <div class="mg-test-downloads__user-actions" style="margin-top: 1rem;">
              <button class="btn" type="button" {{on "click" @controller.loadUsers}} disabled={{@controller.isLoadingUsers}}>
                {{if @controller.isLoadingUsers "Loading users…" "Reload users"}}
              </button>
              <button class="btn btn-primary" type="button" {{on "click" @controller.generateFull}} disabled={{@controller.generateDisabled}}>
                {{if @controller.isGenerating "Generating…" "Generate full download"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.generateRandomPartial}} disabled={{@controller.generateDisabled}}>
                Generate random partial (~40–50%)
              </button>
            </div>

            {{#if @controller.usersError}}
              <div class="mg-test-downloads__flash is-danger" style="margin-top: 1rem;">{{@controller.usersError}}</div>
            {{/if}}

            {{#if @controller.showNoUsersWarning}}
              <div class="mg-test-downloads__flash is-warning" style="margin-top: 1rem;">
                No users found from fingerprints or playback sessions for this public_id yet. You can still enter a user ID manually.
              </div>
            {{/if}}
          {{else}}
            <div class="mg-test-downloads__section-header">
              <div class="mg-test-downloads__section-copy">
                <h2>{{i18n "admin.media_gallery.test_downloads.selected_media"}}</h2>
                <p class="mg-test-downloads__muted">Select a result or use an exact public_id to prepare a personalized test download.</p>
              </div>
            </div>
            <div class="mg-test-downloads__empty">
              No media selected yet.
            </div>
          {{/if}}
        </section>
      </div>

      <section class="mg-test-downloads__panel">
        <div class="mg-test-downloads__section-header">
          <div class="mg-test-downloads__section-copy">
            <h2>{{i18n "admin.media_gallery.test_downloads.generated"}}</h2>
            <p class="mg-test-downloads__muted">Artifacts generated in this admin session, ready to download as MP4.</p>
          </div>
        </div>

        {{#if @controller.hasArtifacts}}
          <div class="mg-test-downloads__artifacts-list">
            {{#each @controller.artifactCards key="artifact_id" as |artifact|}}
              <article class="mg-test-downloads__artifact-card">
                <div class="mg-test-downloads__artifact-top">
                  <div class="mg-test-downloads__artifact-copy">
                    <div class="mg-test-downloads__artifact-title">{{artifact.public_id}}</div>
                    <div class="mg-test-downloads__artifact-subtitle">{{artifact.username}} (#{{artifact.user_id}}) · {{artifact.createdLabel}}</div>
                  </div>
                  <div class="mg-test-downloads__artifact-actions">
                    <button class="btn btn-primary" type="button" {{on "click" (fn @controller.downloadArtifact artifact)}}>
                      Download MP4
                    </button>
                  </div>
                </div>

                <div class="mg-test-downloads__badge-row">
                  <span class="mg-test-downloads__badge is-success">{{artifact.modeLabel}}</span>
                  {{#if artifact.regionSummary}}
                    <span class="mg-test-downloads__chip">{{artifact.regionSummary}}</span>
                  {{/if}}
                  <span class="mg-test-downloads__chip">{{artifact.segmentSummary}}</span>
                </div>

                <div class="mg-test-downloads__artifact-grid">
                  <div class="mg-test-downloads__metric">
                    <span class="mg-test-downloads__metric-label">File size</span>
                    <div class="mg-test-downloads__metric-value">{{artifact.sizeLabel}}</div>
                  </div>
                  <div class="mg-test-downloads__metric">
                    <span class="mg-test-downloads__metric-label">Variant</span>
                    <div class="mg-test-downloads__metric-value">{{artifact.variant}}</div>
                  </div>
                  <div class="mg-test-downloads__metric">
                    <span class="mg-test-downloads__metric-label">Segments</span>
                    <div class="mg-test-downloads__metric-value">{{artifact.segment_count}} / {{artifact.total_segments}}</div>
                  </div>
                  <div class="mg-test-downloads__metric">
                    <span class="mg-test-downloads__metric-label">Artifact ID</span>
                    <div class="mg-test-downloads__metric-value">{{artifact.artifact_id}}</div>
                  </div>
                </div>
              </article>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-test-downloads__empty">{{i18n "admin.media_gallery.test_downloads.none_generated"}}</div>
        {{/if}}
      </section>
    </div>
  </template>
);
