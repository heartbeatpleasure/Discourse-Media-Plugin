import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-test-downloads {
        --mg-td-border: var(--primary-low);
        --mg-td-muted: var(--primary-medium);
        --mg-td-radius: 16px;
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

      .mg-td__panel,
      .mg-td__flash,
      .mg-td__metric,
      .mg-td__result,
      .mg-td__artifact {
        background: var(--secondary);
        border: 1px solid var(--mg-td-border);
        border-radius: var(--mg-td-radius);
      }

      .mg-td__panel,
      .mg-td__flash {
        padding: 1rem 1.125rem;
      }

      .mg-td__panel-header,
      .mg-td__section-header,
      .mg-td__result-top,
      .mg-td__artifact-top {
        display: flex;
        gap: 1rem;
        justify-content: space-between;
        align-items: flex-start;
      }

      .mg-td__section-header,
      .mg-td__panel-header {
        margin-bottom: 0.9rem;
      }

      .mg-td__muted {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
      }

      .mg-td__notice,
      .mg-td__badge,
      .mg-td__chip {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 0.35rem;
        padding: 0.3rem 0.7rem;
        border-radius: 999px;
        border: 1px solid var(--primary-low);
        background: var(--primary-very-low);
        font-size: var(--font-down-1);
        color: var(--primary-high);
      }

      .mg-td__badge.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-td__badge.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-td__flash.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-td__flash.is-warning {
        background: var(--tertiary-very-low);
      }

      .mg-td__layout,
      .mg-td__filters,
      .mg-td__result-meta,
      .mg-td__selected-meta,
      .mg-td__artifact-meta,
      .mg-td__user-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-td__layout {
        grid-template-columns: minmax(0, 1.25fr) minmax(340px, 0.9fr);
        align-items: start;
      }

      .mg-td__filters {
        grid-template-columns: repeat(4, minmax(0, 1fr));
        align-items: end;
      }

      .mg-td__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-td__field.is-search {
        grid-column: 1 / -1;
      }

      .mg-td__field label {
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-td__field input,
      .mg-td__field select {
        min-height: 44px;
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-td-border);
        border-radius: 12px;
        background: var(--primary-very-low);
      }

      .mg-td__actions,
      .mg-td__result-actions,
      .mg-td__user-actions,
      .mg-td__artifact-actions,
      .mg-td__badge-row,
      .mg-td__filters-footer {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
      }

      .mg-td__filters-footer {
        justify-content: space-between;
        align-items: center;
        margin-top: 1rem;
      }

      .mg-td__results,
      .mg-td__artifacts {
        display: flex;
        flex-direction: column;
        gap: 1rem;
        margin-top: 1rem;
      }

      .mg-td__result,
      .mg-td__artifact {
        padding: 1rem;
        background: var(--primary-very-low);
      }

      .mg-td__result-main,
      .mg-td__selected-main,
      .mg-td__artifact-main {
        display: flex;
        flex-direction: column;
        gap: 0.6rem;
        min-width: 0;
        flex: 1 1 auto;
      }

      .mg-td__result-title,
      .mg-td__selected-title,
      .mg-td__artifact-title {
        font-size: 1.1rem;
        font-weight: 700;
        line-height: 1.25;
        overflow-wrap: anywhere;
      }

      .mg-td__result-subtitle,
      .mg-td__selected-subtitle,
      .mg-td__artifact-subtitle {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-td__thumb,
      .mg-td__thumb-placeholder {
        width: 168px;
        height: 94px;
        object-fit: cover;
        border-radius: 12px;
        border: 1px solid var(--mg-td-border);
        background: var(--secondary);
        flex: 0 0 auto;
      }

      .mg-td__thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        text-align: center;
        padding: 0.5rem;
        box-sizing: border-box;
      }

      .mg-td__result-meta,
      .mg-td__selected-meta,
      .mg-td__artifact-meta,
      .mg-td__user-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-td__metric {
        padding: 0.85rem 0.95rem;
        min-width: 0;
      }

      .mg-td__metric-label {
        display: block;
        font-size: var(--font-down-1);
        color: var(--mg-td-muted);
        margin-bottom: 0.25rem;
      }

      .mg-td__metric-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-td__selected-layout {
        display: grid;
        grid-template-columns: 168px minmax(0, 1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-td__empty {
        border: 1px dashed var(--mg-td-border);
        border-radius: 14px;
        padding: 1rem;
        text-align: center;
        color: var(--mg-td-muted);
        background: var(--primary-very-low);
      }

      @media (max-width: 1000px) {
        .mg-td__layout {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 800px) {
        .mg-td__filters,
        .mg-td__result-meta,
        .mg-td__selected-meta,
        .mg-td__artifact-meta,
        .mg-td__user-grid,
        .mg-td__selected-layout {
          grid-template-columns: 1fr;
        }

        .mg-td__result-top,
        .mg-td__artifact-top,
        .mg-td__panel-header,
        .mg-td__section-header,
        .mg-td__filters-footer {
          flex-direction: column;
        }
      }
    </style>

    <div class="media-gallery-admin-test-downloads">
      <section class="mg-td__panel">
        <div class="mg-td__panel-header">
          <div>
            <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
            <p class="mg-td__muted">{{i18n "admin.media_gallery.test_downloads.description"}}</p>
          </div>
          <span class="mg-td__notice">Admin only · backend setting still enforced</span>
        </div>
      </section>

      {{#if @controller.selectionMessage}}
        <div class="mg-td__flash">{{@controller.selectionMessage}}</div>
      {{/if}}

      {{#if @controller.searchError}}
        <div class="mg-td__flash is-danger">{{@controller.searchError}}</div>
      {{/if}}

      {{#if @controller.generateError}}
        <div class="mg-td__flash is-danger">{{@controller.generateError}}</div>
      {{/if}}

      <div class="mg-td__layout">
        <section class="mg-td__panel">
          <div class="mg-td__section-header">
            <div>
              <h2>{{i18n "admin.media_gallery.test_downloads.search_label"}}</h2>
              <p class="mg-td__muted">Find a media item by public_id or title, then generate a personalized test download.</p>
            </div>
            {{#if @controller.isSearching}}
              <span class="mg-td__badge">Searching…</span>
            {{/if}}
          </div>

          <div class="mg-td__filters">
            <div class="mg-td__field is-search">
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

            <div class="mg-td__field">
              <label>Type</label>
              <select value={{@controller.mediaTypeFilter}} {{on "change" @controller.onMediaTypeChange}}>
                {{#each @controller.mediaTypeOptions key="value" as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-td__field">
              <label>Status</label>
              <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusChange}}>
                {{#each @controller.statusOptions key="value" as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-td__field">
              <label>Backend</label>
              <select value={{@controller.backendFilter}} {{on "change" @controller.onBackendChange}}>
                {{#each @controller.backendOptions key="value" as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-td__field">
              <label>Sort</label>
              <select value={{@controller.sort}} {{on "change" @controller.onSortChange}}>
                {{#each @controller.sortOptions key="value" as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>

            <div class="mg-td__field">
              <label>Limit</label>
              <select value={{@controller.limit}} {{on "change" @controller.onLimitChange}}>
                {{#each @controller.limitOptions key="value" as |option|}}
                  <option value={{option.value}}>{{option.label}}</option>
                {{/each}}
              </select>
            </div>
          </div>

          <div class="mg-td__filters-footer">
            <div class="mg-td__actions">
              <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.searchButtonDisabled}}>
                {{if @controller.isSearching "Searching…" "Search"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.useTypedPublicId}} disabled={{@controller.useTypedPublicIdDisabled}}>
                Use entered public_id
              </button>
            </div>
            {{#if @controller.searchInfo}}
              <span class="mg-td__muted">{{@controller.searchInfo}}</span>
            {{/if}}
          </div>

          {{#if @controller.searchResults.length}}
            <div class="mg-td__results">
              {{#each @controller.searchResults key="id" as |item|}}
                <article class="mg-td__result">
                  <div class="mg-td__result-top">
                    {{#if item.thumbnail_url}}
                      <img class="mg-td__thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                    {{else}}
                      <div class="mg-td__thumb-placeholder">No thumbnail</div>
                    {{/if}}

                    <div class="mg-td__result-main">
                      <div class="mg-td__result-title">{{item.displayTitle}}</div>
                      <div class="mg-td__result-subtitle">{{item.public_id}}</div>
                      <div class="mg-td__badge-row">
                        <span class={{item.statusBadgeClass}}>{{item.displayStatus}}</span>
                        <span class="mg-td__badge">{{item.displayType}}</span>
                        <span class="mg-td__badge">{{item.displayStorage}}</span>
                        {{#if item.has_hls}}
                          <span class="mg-td__chip">HLS ready</span>
                        {{/if}}
                      </div>
                    </div>

                    <div class="mg-td__result-actions">
                      <button class="btn" type="button" {{on "click" (fn @controller.pickItem item)}}>
                        Use
                      </button>
                    </div>
                  </div>

                  <div class="mg-td__result-meta" style="margin-top: 1rem;">
                    <div class="mg-td__metric">
                      <span class="mg-td__metric-label">Owner</span>
                      <div class="mg-td__metric-value">{{item.ownerLabel}}</div>
                    </div>
                    <div class="mg-td__metric">
                      <span class="mg-td__metric-label">Created</span>
                      <div class="mg-td__metric-value">{{item.createdLabel}}</div>
                    </div>
                    <div class="mg-td__metric">
                      <span class="mg-td__metric-label">Updated</span>
                      <div class="mg-td__metric-value">{{item.updatedLabel}}</div>
                    </div>
                    <div class="mg-td__metric">
                      <span class="mg-td__metric-label">Processed size</span>
                      <div class="mg-td__metric-value">{{item.sizeLabel}}</div>
                    </div>
                  </div>
                </article>
              {{/each}}
            </div>
          {{/if}}

          {{#if @controller.showNoResults}}
            <div class="mg-td__empty" style="margin-top: 1rem;">
              No media items found. If you already know the exact public_id, use the button above to continue directly.
            </div>
          {{/if}}
        </section>

        <section class="mg-td__panel">
          <div class="mg-td__section-header">
            <div>
              <h2>{{i18n "admin.media_gallery.test_downloads.selected_media"}}</h2>
              <p class="mg-td__muted">Choose a user and generate a personalized download variant.</p>
            </div>
          </div>

          {{#if @controller.hasSelectedItem}}
            <div class="mg-td__selected-layout">
              <div>
                {{#if @controller.selectedItem.thumbnail_url}}
                  <img class="mg-td__thumb" loading="lazy" src={{@controller.selectedItem.thumbnail_url}} alt="thumbnail" />
                {{else}}
                  <div class="mg-td__thumb-placeholder">No thumbnail</div>
                {{/if}}
              </div>

              <div class="mg-td__selected-main">
                <div class="mg-td__selected-title">{{@controller.selectedItem.displayTitle}}</div>
                <div class="mg-td__selected-subtitle">{{@controller.publicId}}</div>
                <div class="mg-td__badge-row">
                  <span class={{@controller.selectedItem.statusBadgeClass}}>{{@controller.selectedItem.displayStatus}}</span>
                  <span class="mg-td__badge">{{@controller.selectedItem.displayType}}</span>
                  <span class="mg-td__badge">{{@controller.selectedItem.displayStorage}}</span>
                </div>
              </div>
            </div>

            <div class="mg-td__selected-meta" style="margin-top: 1rem;">
              <div class="mg-td__metric">
                <span class="mg-td__metric-label">Owner</span>
                <div class="mg-td__metric-value">{{@controller.selectedItem.ownerLabel}}</div>
              </div>
              <div class="mg-td__metric">
                <span class="mg-td__metric-label">Created</span>
                <div class="mg-td__metric-value">{{@controller.selectedItem.createdLabel}}</div>
              </div>
              <div class="mg-td__metric">
                <span class="mg-td__metric-label">Updated</span>
                <div class="mg-td__metric-value">{{@controller.selectedItem.updatedLabel}}</div>
              </div>
              <div class="mg-td__metric">
                <span class="mg-td__metric-label">Processed size</span>
                <div class="mg-td__metric-value">{{@controller.selectedItem.sizeLabel}}</div>
              </div>
            </div>

            <div class="mg-td__user-grid" style="margin-top: 1rem;">
              <div class="mg-td__field">
                <label>{{i18n "admin.media_gallery.test_downloads.users_label"}}</label>
                <select value={{@controller.selectedUserId}} {{on "change" @controller.onUserSelect}}>
                  <option value="">-- select user --</option>
                  {{#each @controller.users key="id" as |user|}}
                    <option value={{user.id}}>{{user.username}} (#{{user.id}})</option>
                  {{/each}}
                </select>
                <span class="mg-td__muted">{{i18n "admin.media_gallery.test_downloads.users_help"}}</span>
              </div>

              <div class="mg-td__field">
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
                <span class="mg-td__muted">Use manual input when no known users are listed yet.</span>
              </div>
            </div>

            <div class="mg-td__user-actions" style="margin-top: 1rem;">
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
              <div class="mg-td__flash is-danger" style="margin-top: 1rem;">{{@controller.usersError}}</div>
            {{/if}}

            {{#if @controller.showNoUsersWarning}}
              <div class="mg-td__flash is-warning" style="margin-top: 1rem;">
                No users found from fingerprints or playback sessions for this public_id yet. You can still enter a user ID manually.
              </div>
            {{/if}}
          {{else}}
            <div class="mg-td__empty">
              No media selected yet.
            </div>
          {{/if}}
        </section>
      </div>

      <section class="mg-td__panel">
        <div class="mg-td__section-header">
          <div>
            <h2>{{i18n "admin.media_gallery.test_downloads.generated"}}</h2>
            <p class="mg-td__muted">Artifacts generated in this admin session, ready to download as MP4.</p>
          </div>
        </div>

        {{#if @controller.hasArtifacts}}
          <div class="mg-td__artifacts">
            {{#each @controller.artifacts key="artifact_id" as |artifact|}}
              <article class="mg-td__artifact">
                <div class="mg-td__artifact-top">
                  <div class="mg-td__artifact-main">
                    <div class="mg-td__artifact-title">{{artifact.public_id}}</div>
                    <div class="mg-td__artifact-subtitle">{{artifact.userLabel}} · {{artifact.createdLabel}}</div>
                    <div class="mg-td__badge-row">
                      <span class="mg-td__badge is-success">{{artifact.modeLabel}}</span>
                      {{#if artifact.regionLabel}}
                        <span class="mg-td__chip">{{artifact.regionLabel}}</span>
                      {{/if}}
                    </div>
                  </div>
                  <div class="mg-td__artifact-actions">
                    <button class="btn btn-primary" type="button" {{on "click" (fn @controller.downloadArtifact artifact)}}>
                      Download MP4
                    </button>
                  </div>
                </div>

                <div class="mg-td__artifact-meta" style="margin-top: 1rem;">
                  <div class="mg-td__metric">
                    <span class="mg-td__metric-label">File size</span>
                    <div class="mg-td__metric-value">{{artifact.fileSizeLabel}}</div>
                  </div>
                  <div class="mg-td__metric">
                    <span class="mg-td__metric-label">Variant</span>
                    <div class="mg-td__metric-value">{{artifact.variant}}</div>
                  </div>
                  <div class="mg-td__metric">
                    <span class="mg-td__metric-label">Segments</span>
                    <div class="mg-td__metric-value">{{artifact.segmentSummary}}</div>
                  </div>
                  <div class="mg-td__metric">
                    <span class="mg-td__metric-label">Artifact ID</span>
                    <div class="mg-td__metric-value">{{artifact.artifact_id}}</div>
                  </div>
                </div>
              </article>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-td__empty">{{i18n "admin.media_gallery.test_downloads.none_generated"}}</div>
        {{/if}}
      </section>
    </div>
  </template>
);
