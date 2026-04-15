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

      .mg-td__panel {
        background: var(--mg-td-surface);
        border: 1px solid var(--mg-td-border);
        border-radius: var(--mg-td-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-td__panel-header,
      .mg-td__section-header,
      .mg-td__search-row,
      .mg-td__selected-top {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.9rem;
      }

      .mg-td__panel-header,
      .mg-td__section-header {
        margin-bottom: 0.9rem;
      }

      .mg-td__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-td__muted,
      .mg-td__desc {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
      }

      .mg-td__notice,
      .mg-td__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 0.28rem 0.68rem;
        border-radius: 999px;
        border: 1px solid var(--primary-low);
        background: var(--primary-very-low);
        font-size: var(--font-down-1);
        color: var(--primary-high);
        line-height: 1.2;
      }

      .mg-td__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--primary-low);
        background: var(--primary-very-low);
      }

      .mg-td__flash.is-error {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-td__flash.is-warning {
        background: var(--tertiary-very-low);
      }

      .mg-td__search-stack,
      .mg-td__selected-stack {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .mg-td__search-row {
        flex-wrap: wrap;
        align-items: center;
      }

      .mg-td__search-row input,
      .mg-td__field input,
      .mg-td__field select {
        width: 100%;
        min-height: 42px;
        box-sizing: border-box;
        border: 1px solid var(--mg-td-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0.55rem 0.8rem;
      }

      .mg-td__search-input-wrap {
        min-width: 320px;
        flex: 1 1 30rem;
      }

      .mg-td__actions {
        display: flex;
        gap: 0.75rem;
        flex-wrap: wrap;
        align-items: center;
      }

      .mg-td__results-table,
      .mg-td__artifacts-table {
        width: 100%;
        border-collapse: separate;
        border-spacing: 0;
      }

      .mg-td__results-table th,
      .mg-td__results-table td,
      .mg-td__artifacts-table th,
      .mg-td__artifacts-table td {
        padding: 0.8rem 0.75rem;
        border-bottom: 1px solid var(--mg-td-border);
        vertical-align: middle;
        text-align: left;
      }

      .mg-td__results-table thead th,
      .mg-td__artifacts-table thead th {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-td__results-table tbody tr:last-child td,
      .mg-td__artifacts-table tbody tr:last-child td {
        border-bottom: 0;
      }

      .mg-td__thumb,
      .mg-td__thumb-placeholder {
        width: 124px;
        height: 70px;
        border-radius: 12px;
        border: 1px solid var(--mg-td-border);
        object-fit: cover;
        background: var(--mg-td-surface-alt);
      }

      .mg-td__thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
      }

      .mg-td__code {
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
        word-break: break-word;
      }

      .mg-td__selected-card {
        border: 1px solid var(--mg-td-border);
        border-radius: 16px;
        background: var(--mg-td-surface-alt);
        padding: 1rem;
      }

      .mg-td__selected-top {
        align-items: stretch;
      }

      .mg-td__selected-copy {
        display: flex;
        flex-direction: column;
        gap: 0.45rem;
        min-width: 0;
        flex: 1 1 auto;
        justify-content: center;
      }

      .mg-td__selected-title {
        font-size: 1.1rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-td__selected-meta {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.9rem;
        margin-top: 1rem;
      }

      .mg-td__metric {
        border: 1px solid var(--mg-td-border);
        border-radius: 14px;
        background: var(--mg-td-surface);
        padding: 0.85rem 0.95rem;
      }

      .mg-td__metric-label {
        display: block;
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        margin-bottom: 0.25rem;
      }

      .mg-td__metric-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-td__field-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 1rem;
      }

      .mg-td__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
      }

      .mg-td__field label {
        color: var(--mg-td-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-td__empty {
        border: 1px dashed var(--mg-td-border);
        border-radius: 14px;
        background: var(--mg-td-surface-alt);
        padding: 1rem;
        text-align: center;
        color: var(--mg-td-muted);
      }

      @media (max-width: 900px) {
        .mg-td__selected-meta,
        .mg-td__field-grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 760px) {
        .mg-td__panel-header,
        .mg-td__section-header,
        .mg-td__search-row,
        .mg-td__selected-top {
          flex-direction: column;
        }

        .mg-td__results-table,
        .mg-td__artifacts-table {
          display: block;
          overflow-x: auto;
        }
      }
    </style>

    <div class="media-gallery-admin-test-downloads">
      <section class="mg-td__panel">
        <div class="mg-td__panel-header">
          <div class="mg-td__panel-copy">
            <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
            <p class="mg-td__muted">{{i18n "admin.media_gallery.test_downloads.description"}}</p>
          </div>
          <span class="mg-td__notice">Admin only · backend setting still enforced</span>
        </div>
      </section>

      <section class="mg-td__panel">
        <div class="mg-td__section-header">
          <div class="mg-td__panel-copy">
            <h2>{{i18n "admin.media_gallery.test_downloads.search_label"}}</h2>
            <p class="mg-td__muted">Find media by public_id or title, then continue directly or pick a result.</p>
          </div>
          {{#if @controller.isSearching}}
            <span class="mg-td__badge">Searching…</span>
          {{/if}}
        </div>

        <div class="mg-td__search-stack">
          <div class="mg-td__search-row">
            <div class="mg-td__search-input-wrap">
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

            <div class="mg-td__actions">
              <button class="btn" type="button" {{on "click" @controller.search}} disabled={{@controller.searchButtonDisabled}}>
                Search
              </button>
              <button class="btn btn-primary" type="button" {{on "click" @controller.useTypedPublicId}} disabled={{@controller.useTypedPublicIdDisabled}}>
                Use entered public_id
              </button>
            </div>
          </div>

          <div class="mg-td__desc">Best: paste the full public_id. Search is optional; you can also continue directly with the entered public_id.</div>

          {{#if @controller.selectionMessage}}
            <div class="mg-td__flash">{{@controller.selectionMessage}}</div>
          {{/if}}

          {{#if @controller.searchInfo}}
            <div class="mg-td__flash">{{@controller.searchInfo}}</div>
          {{/if}}

          {{#if @controller.searchError}}
            <div class="mg-td__flash is-error">{{@controller.searchError}}</div>
          {{/if}}

          {{#if @controller.showNoResults}}
            <div class="mg-td__flash is-warning">No media items found for this search. If you entered an exact public_id, click <strong>Use entered public_id</strong>.</div>
          {{/if}}

          {{#if @controller.searchResults.length}}
            <div>
              <table class="mg-td__results-table">
                <thead>
                  <tr>
                    <th>Preview</th>
                    <th>public_id</th>
                    <th>Title</th>
                    <th>Owner</th>
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {{#each @controller.searchResults as |item|}}
                    <tr>
                      <td>
                        {{#if item.thumbnail_url}}
                          <img class="mg-td__thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                        {{else}}
                          <div class="mg-td__thumb-placeholder">No thumbnail</div>
                        {{/if}}
                      </td>
                      <td><div class="mg-td__code">{{item.public_id}}</div></td>
                      <td>{{item.title}}</td>
                      <td>{{item.username}}</td>
                      <td>{{item.status}}</td>
                      <td>
                        <button class="btn btn-small" type="button" {{on "click" (fn @controller.pickItem item)}}>
                          Use
                        </button>
                      </td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          {{/if}}
        </div>
      </section>

      <section class="mg-td__panel">
        <div class="mg-td__section-header">
          <div class="mg-td__panel-copy">
            <h2>{{i18n "admin.media_gallery.test_downloads.selected_media"}}</h2>
            <p class="mg-td__muted">Select a user and generate a personalized test download for the chosen media item.</p>
          </div>
        </div>

        {{#if @controller.hasSelectedItem}}
          <div class="mg-td__selected-stack">
            <div class="mg-td__selected-card">
              <div class="mg-td__selected-top">
                <div>
                  {{#if @controller.selectedItem.thumbnail_url}}
                    <img class="mg-td__thumb" loading="lazy" src={{@controller.selectedItem.thumbnail_url}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-td__thumb-placeholder">No thumbnail</div>
                  {{/if}}
                </div>

                <div class="mg-td__selected-copy">
                  <div class="mg-td__selected-title">{{#if @controller.selectedItem.title}}{{@controller.selectedItem.title}}{{else}}Selected media{{/if}}</div>
                  <div class="mg-td__code">{{@controller.publicId}}</div>
                </div>
              </div>

              <div class="mg-td__selected-meta">
                <div class="mg-td__metric">
                  <span class="mg-td__metric-label">Owner</span>
                  <div class="mg-td__metric-value">{{if @controller.selectedItem.username @controller.selectedItem.username "—"}}</div>
                </div>
                <div class="mg-td__metric">
                  <span class="mg-td__metric-label">Status</span>
                  <div class="mg-td__metric-value">{{if @controller.selectedItem.status @controller.selectedItem.status "—"}}</div>
                </div>
              </div>
            </div>

            <div class="mg-td__field-grid">
              <div class="mg-td__field">
                <label>{{i18n "admin.media_gallery.test_downloads.users_label"}}</label>
                <select value={{@controller.selectedUserId}} {{on "change" @controller.onUserSelect}}>
                  <option value="">-- select user --</option>
                  {{#each @controller.users as |user|}}
                    <option value={{user.id}}>{{user.username}} (#{{user.id}})</option>
                  {{/each}}
                </select>
                <div class="mg-td__desc">Users are auto-loaded after selecting a public_id. You can reload them here or fill a user ID manually below.</div>
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
                <div class="mg-td__desc">Use this if no users are listed automatically.</div>
              </div>
            </div>

            <div class="mg-td__actions">
              <button class="btn" type="button" {{on "click" @controller.loadUsers}} disabled={{@controller.isLoadingUsers}}>
                {{if @controller.isLoadingUsers "Loading users…" "Reload users"}}
              </button>
              <button class="btn btn-primary" type="button" {{on "click" @controller.generateFull}} disabled={{@controller.generateDisabled}}>
                Generate full download
              </button>
              <button class="btn" type="button" {{on "click" @controller.generateRandomPartial}} disabled={{@controller.generateDisabled}}>
                Generate random partial (~40–50%)
              </button>
            </div>

            {{#if @controller.usersError}}
              <div class="mg-td__flash is-error">{{@controller.usersError}}</div>
            {{/if}}

            {{#if @controller.showNoUsersWarning}}
              <div class="mg-td__flash is-warning">No users found from fingerprints/playback sessions for this public_id yet. You can still enter a user ID manually.</div>
            {{/if}}

            {{#if @controller.generateError}}
              <div class="mg-td__flash is-error">{{@controller.generateError}}</div>
            {{/if}}
          </div>
        {{else}}
          <div class="mg-td__empty">No media selected yet.</div>
        {{/if}}
      </section>

      <section class="mg-td__panel">
        <div class="mg-td__section-header">
          <div class="mg-td__panel-copy">
            <h2>{{i18n "admin.media_gallery.test_downloads.generated"}}</h2>
            <p class="mg-td__muted">Artifacts generated in this admin session, ready to download.</p>
          </div>
        </div>

        {{#if @controller.hasArtifacts}}
          <table class="mg-td__artifacts-table">
            <thead>
              <tr>
                <th>Created</th>
                <th>public_id</th>
                <th>User</th>
                <th>Mode</th>
                <th>Segments</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.artifacts as |artifact|}}
                <tr>
                  <td>{{artifact.created_at}}</td>
                  <td><div class="mg-td__code">{{artifact.public_id}}</div></td>
                  <td>{{artifact.username}} (#{{artifact.user_id}})</td>
                  <td>
                    {{artifact.mode}}
                    {{#if artifact.random_clip_region}}
                      — {{artifact.random_clip_region}} ({{artifact.clip_percent_of_video}}%)
                    {{/if}}
                  </td>
                  <td>start {{artifact.start_segment}}, count {{artifact.segment_count}} / {{artifact.total_segments}}</td>
                  <td>
                    <button class="btn btn-small" type="button" {{on "click" (fn @controller.downloadArtifact artifact)}}>
                      Download
                    </button>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{else}}
          <div class="mg-td__empty">{{i18n "admin.media_gallery.test_downloads.none_generated"}}</div>
        {{/if}}
      </section>
    </div>
  </template>
);
