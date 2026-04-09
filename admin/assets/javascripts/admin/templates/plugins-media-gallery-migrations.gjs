import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
        .media-gallery-admin-migrations {
          --mg-surface: var(--secondary);
          --mg-surface-alt: var(--primary-very-low);
          --mg-border: var(--primary-low);
          --mg-muted: var(--primary-medium);
          --mg-radius: 18px;
          --mg-gap: 1rem;
          display: flex;
          flex-direction: column;
          gap: 1rem;
        }

        .media-gallery-admin-migrations p {
          margin: 0;
        }

        .mg-migrations__grid,
        .mg-migrations__storage-grid,
        .mg-migrations__state-grid,
        .mg-migrations__role-grid,
        .mg-migrations__summary-grid {
          display: grid;
          gap: 1rem;
        }

        .mg-migrations__storage-grid {
          grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
        }

        .mg-migrations__grid {
          grid-template-columns: minmax(0, 1.2fr) minmax(360px, 0.9fr);
          align-items: start;
        }

        .mg-migrations__summary-grid {
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
        }

        .mg-migrations__state-grid,
        .mg-migrations__role-grid {
          grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        }

        .mg-migrations__panel {
          background: var(--mg-surface);
          border: 1px solid var(--mg-border);
          border-radius: var(--mg-radius);
          padding: 1rem 1.125rem;
          min-width: 0;
          overflow: hidden;
          box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
        }

        .mg-migrations__panel h2,
        .mg-migrations__panel h3 {
          margin: 0;
        }

        .mg-migrations__panel-header {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 0.75rem;
          margin-bottom: 0.9rem;
        }

        .mg-migrations__panel-copy {
          display: flex;
          flex-direction: column;
          gap: 0.25rem;
        }

        .mg-migrations__muted {
          color: var(--mg-muted);
          font-size: var(--font-down-1);
        }

        .mg-migrations__badge {
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

        .mg-migrations__badge.is-success {
          background: var(--success-low);
          color: var(--success);
          border-color: var(--success-low-mid);
        }

        .mg-migrations__badge.is-warning {
          background: var(--tertiary-very-low);
          color: var(--tertiary);
          border-color: var(--tertiary-low);
        }

        .mg-migrations__badge.is-danger {
          background: var(--danger-low);
          color: var(--danger);
          border-color: var(--danger-low-mid);
        }

        .mg-migrations__row-list {
          display: grid;
          gap: 0.55rem;
        }

        .mg-migrations__summary-row {
          display: flex;
          justify-content: space-between;
          gap: 1rem;
          align-items: flex-start;
          padding: 0.35rem 0;
          border-top: 1px solid var(--primary-low);
        }

        .mg-migrations__summary-row:first-child {
          border-top: 0;
          padding-top: 0;
        }

        .mg-migrations__summary-label {
          color: var(--mg-muted);
          font-size: var(--font-down-1);
          min-width: 0;
        }

        .mg-migrations__summary-value {
          text-align: right;
          font-weight: 600;
          min-width: 0;
          overflow-wrap: anywhere;
        }

        .mg-migrations__actions,
        .mg-migrations__toggle-row,
        .mg-migrations__inline-actions,
        .mg-migrations__filters-actions,
        .mg-migrations__bulk-toolbar {
          display: flex;
          flex-wrap: wrap;
          gap: 0.75rem;
        }

        .mg-migrations__filters {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
          gap: 0.85rem;
          align-items: end;
        }

        .mg-migrations__field {
          display: flex;
          flex-direction: column;
          gap: 0.35rem;
          min-width: 0;
        }

        .mg-migrations__field label {
          font-weight: 600;
          font-size: var(--font-down-1);
        }

        .mg-migrations__field input,
        .mg-migrations__field select {
          min-height: 42px;
          box-sizing: border-box;
          width: 100%;
        }

        .mg-migrations__field.is-search {
          grid-column: span 2;
        }

        .mg-migrations__filters-footer {
          display: flex;
          flex-wrap: wrap;
          justify-content: space-between;
          gap: 0.75rem;
          align-items: center;
          margin-top: 1rem;
        }

        .mg-migrations__results-list {
          display: grid;
          gap: 0.85rem;
        }

        .mg-migrations__result-card {
          display: grid;
          grid-template-columns: auto 96px minmax(0, 1fr) auto;
          gap: 0.95rem;
          align-items: center;
          padding: 0.85rem;
          border: 1px solid var(--mg-border);
          border-radius: 16px;
          background: var(--primary-very-low);
        }

        .mg-migrations__result-card.is-selected {
          border-color: var(--tertiary);
          box-shadow: inset 0 0 0 1px var(--tertiary);
          background: var(--secondary);
        }

        .mg-migrations__result-card.is-bulk-selected {
          box-shadow: inset 0 0 0 1px var(--success-low-mid);
        }

        .mg-migrations__thumb,
        .mg-migrations__selected-thumb {
          display: block;
          width: 100%;
          height: 72px;
          object-fit: cover;
          border-radius: 12px;
          background: var(--primary-very-low);
        }

        .mg-migrations__selected-thumb {
          width: 140px;
          height: 96px;
          flex: 0 0 140px;
        }

        .mg-migrations__result-main,
        .mg-migrations__selected-main {
          min-width: 0;
          display: flex;
          flex-direction: column;
          gap: 0.45rem;
        }

        .mg-migrations__result-title,
        .mg-migrations__selected-title {
          font-weight: 700;
          font-size: var(--font-up-1);
          line-height: 1.25;
        }

        .mg-migrations__result-meta,
        .mg-migrations__public-id,
        .mg-migrations__state-detail,
        .mg-migrations__state-meta,
        .mg-migrations__role-locator,
        .mg-migrations__json {
          overflow-wrap: anywhere;
          word-break: break-word;
        }

        .mg-migrations__public-id {
          color: var(--mg-muted);
          font-size: var(--font-down-1);
        }

        .mg-migrations__result-tags,
        .mg-migrations__warning-list {
          display: flex;
          flex-wrap: wrap;
          gap: 0.5rem;
        }

        .mg-migrations__selected-header {
          display: flex;
          gap: 1rem;
          align-items: center;
          min-width: 0;
          margin-bottom: 1rem;
        }

        .mg-migrations__toggle-row label {
          display: inline-flex;
          align-items: center;
          gap: 0.45rem;
          padding: 0.45rem 0.7rem;
          border-radius: 999px;
          background: var(--primary-very-low);
          border: 1px solid var(--mg-border);
          font-size: var(--font-down-1);
        }

        .mg-migrations__state-card,
        .mg-migrations__role-card,
        .mg-migrations__summary-card {
          border: 1px solid var(--mg-border);
          border-radius: 16px;
          padding: 0.9rem;
          background: var(--primary-very-low);
          min-width: 0;
        }

        .mg-migrations__card-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 0.75rem;
          margin-bottom: 0.55rem;
        }

        .mg-migrations__state-title,
        .mg-migrations__role-title,
        .mg-migrations__summary-title {
          font-weight: 700;
        }

        .mg-migrations__state-card .mg-migrations__muted,
        .mg-migrations__role-card .mg-migrations__muted,
        .mg-migrations__summary-card .mg-migrations__muted {
          display: block;
          margin-top: 0.4rem;
        }

        .mg-migrations__warning-list {
          margin-top: 0.75rem;
        }

        .mg-migrations__warning-list .mg-migrations__badge {
          max-width: 100%;
        }


        .mg-migrations__result-select {
          display: flex;
          align-items: center;
          justify-content: center;
        }

        .mg-migrations__result-select input {
          width: 18px;
          height: 18px;
        }

        .mg-migrations__bulk-panel {
          margin-top: 1rem;
          border: 1px solid var(--danger-low-mid);
          background: var(--danger-low);
          border-radius: 16px;
          padding: 1rem;
        }

        .mg-migrations__bulk-panel h3 {
          margin: 0 0 0.35rem;
        }

        .mg-migrations__bulk-toolbar {
          justify-content: space-between;
          align-items: center;
          margin-bottom: 0.75rem;
        }

        .mg-migrations__bulk-confirm {
          display: inline-flex;
          align-items: center;
          gap: 0.5rem;
          margin-top: 0.9rem;
          font-weight: 600;
        }

        .mg-migrations__details {
          margin-top: 1rem;
          border: 1px solid var(--mg-border);
          border-radius: 14px;
          background: var(--primary-very-low);
          overflow: hidden;
        }

        .mg-migrations__details summary {
          cursor: pointer;
          padding: 0.85rem 1rem;
          font-weight: 700;
          list-style: none;
        }

        .mg-migrations__details summary::-webkit-details-marker {
          display: none;
        }

        .mg-migrations__details[open] summary {
          border-bottom: 1px solid var(--mg-border);
        }

        .mg-migrations__json {
          margin: 0;
          padding: 1rem;
          max-height: 360px;
          overflow: auto;
          white-space: pre-wrap;
          background: transparent;
          font-size: 0.9em;
        }

        .mg-migrations__empty {
          border: 1px dashed var(--mg-border);
          border-radius: 16px;
          padding: 1.25rem;
          color: var(--mg-muted);
          text-align: center;
          background: var(--primary-very-low);
        }

        @media (max-width: 1200px) {
          .mg-migrations__grid {
            grid-template-columns: 1fr;
          }
        }

        @media (max-width: 820px) {
          .mg-migrations__field.is-search {
            grid-column: span 1;
          }

          .mg-migrations__result-card {
            grid-template-columns: auto 72px minmax(0, 1fr);
          }

          .mg-migrations__result-card > :last-child {
            grid-column: 1 / -1;
            justify-self: start;
          }

          .mg-migrations__selected-header {
            flex-direction: column;
            align-items: flex-start;
          }

          .mg-migrations__selected-thumb {
            width: 100%;
            height: 180px;
            flex-basis: auto;
          }
        }
    </style>

    <div class="media-gallery-admin-migrations">
      <h1>{{i18n "admin.media_gallery.migrations.title"}}</h1>
      <p class="mg-migrations__muted">{{i18n "admin.media_gallery.migrations.description"}}</p>

      {{#if @controller.storageError}}
        <div class="alert alert-error">{{@controller.storageError}}</div>
      {{/if}}

      <div class="mg-migrations__storage-grid">
        <section class="mg-migrations__panel">
          <div class="mg-migrations__panel-header">
            <div class="mg-migrations__panel-copy">
              <h2>{{@controller.activeStorageCard.title}}</h2>
              <span class="mg-migrations__muted">Quick health check and probe for this storage profile.</span>
            </div>
            <span class={{@controller.activeStorageCard.badgeClass}}>{{@controller.activeStorageCard.badgeLabel}}</span>
          </div>

          <div class="mg-migrations__actions" style="margin-bottom: 0.9rem;">
            <button class="btn" type="button" {{on "click" (fn @controller.loadStorageHealth "active")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.refresh_health"}}
            </button>
            <button class="btn" type="button" {{on "click" (fn @controller.runStorageProbe "active")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.run_probe"}}
            </button>
          </div>

          <div class="mg-migrations__row-list">
            {{#each @controller.activeStorageCard.rows as |row|}}
              <div class="mg-migrations__summary-row">
                <span class="mg-migrations__summary-label">{{row.label}}</span>
                <span class="mg-migrations__summary-value">{{row.value}}</span>
              </div>
            {{/each}}
          </div>

          {{#if @controller.activeStorageCard.validationErrors.length}}
            <div class="mg-migrations__warning-list">
              {{#each @controller.activeStorageCard.validationErrors as |warning|}}
                <span class="mg-migrations__badge is-danger">{{warning}}</span>
              {{/each}}
            </div>
          {{/if}}

          {{#if @controller.activeStorageCard.probeTimings.length}}
            <details class="mg-migrations__details">
              <summary>Probe timings</summary>
              <div class="mg-migrations__row-list" style="padding: 0 1rem 1rem;">
                {{#each @controller.activeStorageCard.probeTimings as |timing|}}
                  <div class="mg-migrations__summary-row">
                    <span class="mg-migrations__summary-label">{{timing.label}}</span>
                    <span class="mg-migrations__summary-value">{{timing.value}}</span>
                  </div>
                {{/each}}
              </div>
            </details>
          {{/if}}

          {{#if @controller.activeStorageCard.probeNote}}
            <p class="mg-migrations__muted" style="margin-top: 0.85rem;">{{@controller.activeStorageCard.probeNote}}</p>
          {{/if}}
        </section>

        <section class="mg-migrations__panel">
          <div class="mg-migrations__panel-header">
            <div class="mg-migrations__panel-copy">
              <h2>{{@controller.targetStorageCard.title}}</h2>
              <span class="mg-migrations__muted">Quick health check and probe for this storage profile.</span>
            </div>
            <span class={{@controller.targetStorageCard.badgeClass}}>{{@controller.targetStorageCard.badgeLabel}}</span>
          </div>

          <div class="mg-migrations__actions" style="margin-bottom: 0.9rem;">
            <button class="btn" type="button" {{on "click" (fn @controller.loadStorageHealth "target")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.refresh_health"}}
            </button>
            <button class="btn" type="button" {{on "click" (fn @controller.runStorageProbe "target")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.run_probe"}}
            </button>
          </div>

          <div class="mg-migrations__row-list">
            {{#each @controller.targetStorageCard.rows as |row|}}
              <div class="mg-migrations__summary-row">
                <span class="mg-migrations__summary-label">{{row.label}}</span>
                <span class="mg-migrations__summary-value">{{row.value}}</span>
              </div>
            {{/each}}
          </div>

          {{#if @controller.targetStorageCard.validationErrors.length}}
            <div class="mg-migrations__warning-list">
              {{#each @controller.targetStorageCard.validationErrors as |warning|}}
                <span class="mg-migrations__badge is-danger">{{warning}}</span>
              {{/each}}
            </div>
          {{/if}}

          {{#if @controller.targetStorageCard.probeTimings.length}}
            <details class="mg-migrations__details">
              <summary>Probe timings</summary>
              <div class="mg-migrations__row-list" style="padding: 0 1rem 1rem;">
                {{#each @controller.targetStorageCard.probeTimings as |timing|}}
                  <div class="mg-migrations__summary-row">
                    <span class="mg-migrations__summary-label">{{timing.label}}</span>
                    <span class="mg-migrations__summary-value">{{timing.value}}</span>
                  </div>
                {{/each}}
              </div>
            </details>
          {{/if}}

          {{#if @controller.targetStorageCard.probeNote}}
            <p class="mg-migrations__muted" style="margin-top: 0.85rem;">{{@controller.targetStorageCard.probeNote}}</p>
          {{/if}}
        </section>
      </div>

      <section class="mg-migrations__panel">
        <div class="mg-migrations__panel-header">
          <div class="mg-migrations__panel-copy">
            <h2>{{i18n "admin.media_gallery.migrations.find_media"}}</h2>
            <span class="mg-migrations__muted">Find a media item, inspect its source/target state, then run copy, switch, or cleanup.</span>
          </div>
        </div>

        <div class="mg-migrations__filters">
          <div class="mg-migrations__field is-search">
            <label>{{i18n "admin.media_gallery.migrations.search_label"}}</label>
            <input
              type="text"
              value={{@controller.searchQuery}}
              placeholder={{i18n "admin.media_gallery.migrations.search_placeholder"}}
              {{on "input" @controller.onSearchInput}}
              {{on "keydown" @controller.onSearchKeydown}}
            />
          </div>

          <div class="mg-migrations__field">
            <label>{{i18n "admin.media_gallery.migrations.backend_filter"}}</label>
            <select value={{@controller.backendFilter}} {{on "change" @controller.onBackendFilterChange}}>
              <option value="all">all</option>
              <option value="local">local</option>
              <option value="s3">s3</option>
            </select>
          </div>

          <div class="mg-migrations__field">
            <label>{{i18n "admin.media_gallery.migrations.status_filter"}}</label>
            <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusFilterChange}}>
              <option value="all">all</option>
              <option value="queued">queued</option>
              <option value="processing">processing</option>
              <option value="ready">ready</option>
              <option value="failed">failed</option>
            </select>
          </div>

          <div class="mg-migrations__field">
            <label>Type</label>
            <select value={{@controller.mediaTypeFilter}} {{on "change" @controller.onMediaTypeFilterChange}}>
              <option value="all">all</option>
              <option value="audio">audio</option>
              <option value="image">image</option>
              <option value="video">video</option>
            </select>
          </div>

          <div class="mg-migrations__field">
            <label>{{i18n "admin.media_gallery.migrations.hls_filter"}}</label>
            <select value={{@controller.hlsFilter}} {{on "change" @controller.onHlsFilterChange}}>
              <option value="all">all</option>
              <option value="yes">yes</option>
              <option value="no">no</option>
            </select>
          </div>

          <div class="mg-migrations__field">
            <label>{{i18n "admin.media_gallery.migrations.limit_label"}}</label>
            <input type="number" min="1" max="100" value={{@controller.limit}} {{on "input" @controller.onLimitInput}} />
          </div>

          <div class="mg-migrations__field">
            <label>{{i18n "admin.media_gallery.migrations.sort_label"}}</label>
            <select value={{@controller.sortBy}} {{on "change" @controller.onSortByChange}}>
              <option value="created_at_desc">newest</option>
              <option value="created_at_asc">oldest</option>
              <option value="title_asc">title A-Z</option>
              <option value="title_desc">title Z-A</option>
              <option value="backend_asc">backend A-Z</option>
              <option value="backend_desc">backend Z-A</option>
            </select>
          </div>
        </div>

        <div class="mg-migrations__filters-footer">
          <span class="mg-migrations__muted">{{@controller.searchInfo}}</span>
          <div class="mg-migrations__filters-actions">
            <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isSearching}}>
              {{if @controller.isSearching "Searching…" (i18n "admin.media_gallery.migrations.search_button")}}
            </button>
            <button class="btn" type="button" {{on "click" @controller.resetFilters}} disabled={{@controller.isSearching}}>
              Reset
            </button>
          </div>
        </div>

        {{#if @controller.bulkActionMessage}}
          <div class="alert alert-info" style="margin-top: 0.85rem;">{{@controller.bulkActionMessage}}</div>
        {{/if}}
        {{#if @controller.bulkActionError}}
          <div class="alert alert-error" style="margin-top: 0.85rem;">{{@controller.bulkActionError}}</div>
        {{/if}}
        {{#if @controller.searchError}}
          <div class="alert alert-error" style="margin-top: 0.85rem;">{{@controller.searchError}}</div>
        {{/if}}

        <div class="mg-migrations__bulk-panel">
          <h3>Migrate multiple selected items</h3>
          <p class="mg-migrations__muted">This queues copy jobs for the items you explicitly selected below. It does not automatically use every search result.</p>
          <div class="mg-migrations__bulk-toolbar" style="margin-top: 0.85rem;">
            <div class="mg-migrations__muted">{{@controller.bulkSelectionCount}} item(s) selected</div>
            <div class="mg-migrations__filters-actions">
              <button class="btn" type="button" {{on "click" @controller.selectAllVisible}} disabled={{@controller.selectAllVisibleDisabled}}>
                {{if @controller.allVisibleSelected "All visible selected" "Select all visible"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.clearBulkSelection}} disabled={{@controller.clearBulkSelectionDisabled}}>
                Clear selection
              </button>
            </div>
          </div>
          <label class="mg-migrations__bulk-confirm">
            <input type="checkbox" checked={{@controller.bulkConfirm}} {{on "change" @controller.onBulkConfirmChange}} />
            I understand this queues migration work for all selected items.
          </label>
          <div class="mg-migrations__filters-actions" style="margin-top: 0.9rem;">
            <button class="btn btn-danger" type="button" {{on "click" @controller.bulkMigrate}} disabled={{@controller.bulkMigrateDisabled}}>
              {{if @controller.isBulkMigrating "Queueing selected items…" "Queue migration for selected items"}}
            </button>
          </div>
        </div>
      </section>

      <div class="mg-migrations__grid">
        <section class="mg-migrations__panel">
          <div class="mg-migrations__panel-header">
            <div class="mg-migrations__panel-copy">
              <h2>{{i18n "admin.media_gallery.migrations.results"}}</h2>
              <span class="mg-migrations__muted">Use “Use” for one item. Use the checkboxes for bulk selection.</span>
            </div>
          </div>

          {{#if @controller.hasSearchResults}}
            <div class="mg-migrations__results-list">
              {{#each @controller.resultCards as |item|}}
                <article class={{item.cardClass}}>
                  <div class="mg-migrations__result-select">
                    <input type="checkbox" checked={{item.isBulkSelected}} {{on "change" (fn @controller.toggleBulkSelection item)}} />
                  </div>
                  <img class="mg-migrations__thumb" src={{item.thumbnailUrl}} alt="" />

                  <div class="mg-migrations__result-main">
                    <div class="mg-migrations__result-title">{{item.titleLabel}}</div>
                    <div class="mg-migrations__public-id">{{item.publicIdLabel}}</div>
                    <div class="mg-migrations__result-meta mg-migrations__muted">{{item.metaLabel}}</div>
                    <div class="mg-migrations__result-tags">
                      <span class={{item.statusClass}}>{{item.statusLabel}}</span>
                      <span class={{item.mediaTypeClass}}>{{item.mediaTypeLabel}}</span>
                      <span class="mg-migrations__badge">{{item.backendLabel}} · {{item.profileLabel}}</span>
                      <span class={{item.hlsClass}}>{{item.hasHlsLabel}}</span>
                    </div>
                  </div>

                  <div class="mg-migrations__inline-actions">
                    <button class="btn btn-small" type="button" {{on "click" (fn @controller.selectItem item)}}>
                      {{if item.isSelected "Selected" (i18n "admin.media_gallery.migrations.select_button")}}
                    </button>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <div class="mg-migrations__empty">No matching media items found.</div>
          {{/if}}
        </section>

        <section class="mg-migrations__panel">
          <div class="mg-migrations__panel-header">
            <div class="mg-migrations__panel-copy">
              <h2>{{i18n "admin.media_gallery.migrations.selected_item"}}</h2>
              <span class="mg-migrations__muted">Keep the overview readable; open the raw JSON only when you need the full payload.</span>
            </div>
          </div>

          {{#if @controller.hasSelectedItem}}
            <div class="mg-migrations__selected-header">
              <img class="mg-migrations__selected-thumb" src={{@controller.selectedThumbnailUrl}} alt="" />
              <div class="mg-migrations__selected-main">
                <div class="mg-migrations__selected-title">{{@controller.selectedDisplayTitle}}</div>
                <div class="mg-migrations__public-id">{{@controller.selectedPublicId}}</div>
                <div class="mg-migrations__summary-grid">
                  {{#each @controller.selectedSummaryRows as |row|}}
                    <div class="mg-migrations__summary-card">
                      <div class="mg-migrations__summary-label">{{row.label}}</div>
                      <div class="mg-migrations__summary-title">{{row.value}}</div>
                    </div>
                  {{/each}}
                </div>
              </div>
            </div>

            <div class="mg-migrations__panel" style="padding: 0.9rem; background: var(--primary-very-low); margin-bottom: 1rem;">
              <div class="mg-migrations__panel-header" style="margin-bottom: 0.75rem;">
                <div class="mg-migrations__panel-copy">
                  <h3>Actions</h3>
                  <span class="mg-migrations__muted">Copy first, then switch. Cleanup only after the target is verified.</span>
                </div>
              </div>

              <div class="mg-migrations__toggle-row" style="margin-bottom: 0.9rem;">
                <label><input type="checkbox" checked={{@controller.autoSwitch}} {{on "change" @controller.onAutoSwitchChange}} /> auto switch after copy</label>
                <label><input type="checkbox" checked={{@controller.autoCleanup}} {{on "change" @controller.onAutoCleanupChange}} /> auto cleanup</label>
                <label><input type="checkbox" checked={{@controller.forceAction}} {{on "change" @controller.onForceActionChange}} /> force</label>
              </div>

              <div class="mg-migrations__actions">
                <button class="btn" type="button" {{on "click" @controller.refreshSelected}} disabled={{@controller.isLoadingSelection}}>
                  {{if @controller.isLoadingSelection "Refreshing…" (i18n "admin.media_gallery.migrations.refresh_selected")}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.copyToTarget}} disabled={{@controller.copyDisabled}}>
                  {{if @controller.isCopying "Copying…" (i18n "admin.media_gallery.migrations.copy_button")}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.verifyTarget}} disabled={{@controller.verifyDisabled}}>
                  {{if @controller.isVerifying "Verifying…" "Verify target"}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.switchToTarget}} disabled={{@controller.switchDisabled}}>
                  {{if @controller.isSwitching "Switching…" (i18n "admin.media_gallery.migrations.switch_button")}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.cleanupSource}} disabled={{@controller.cleanupDisabled}}>
                  {{if @controller.isCleaning "Cleaning…" (i18n "admin.media_gallery.migrations.cleanup_button")}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.rollbackToSource}} disabled={{@controller.rollbackDisabled}}>
                  {{if @controller.isRollingBack "Rolling back…" "Rollback"}}
                </button>
                <button class="btn" type="button" {{on "click" @controller.finalizeMigration}} disabled={{@controller.finalizeDisabled}}>
                  {{if @controller.isFinalizing "Finalizing…" "Finalize"}}
                </button>
              </div>
            </div>

            {{#if @controller.lastActionMessage}}
              <div class="alert alert-info" style="margin-bottom: 1rem;">{{@controller.lastActionMessage}}</div>
            {{/if}}
            {{#if @controller.actionError}}
              <div class="alert alert-error" style="margin-bottom: 1rem;">{{@controller.actionError}}</div>
            {{/if}}
            {{#if @controller.selectedError}}
              <div class="alert alert-error" style="margin-bottom: 1rem;">{{@controller.selectedError}}</div>
            {{/if}}

            <div class="mg-migrations__panel-header">
              <div class="mg-migrations__panel-copy">
                <h3>Current state</h3>
                <span class="mg-migrations__muted">Processing, copy, switch, and cleanup are shown separately so you can see exactly where the item is in the migration flow.</span>
              </div>
            </div>
            <div class="mg-migrations__state-grid">
              {{#each @controller.selectedStateCards as |state|}}
                <div class="mg-migrations__state-card">
                  <div class="mg-migrations__card-header">
                    <span class="mg-migrations__state-title">{{state.title}}</span>
                    <span class={{state.badgeClass}}>{{state.statusLabel}}</span>
                  </div>
                  <div class="mg-migrations__state-detail">{{state.detail}}</div>
                  <span class="mg-migrations__muted mg-migrations__state-meta">{{state.meta}}</span>
                  {{#if state.error}}
                    <span class="mg-migrations__muted" style="color: var(--danger);">{{state.error}}</span>
                  {{/if}}
                </div>
              {{/each}}
            </div>

            <div class="mg-migrations__panel-header" style="margin-top: 1.1rem;">
              <div class="mg-migrations__panel-copy">
                <h3>Current assets</h3>
                <span class="mg-migrations__muted">This shows which managed or legacy roles are currently resolvable for the item.</span>
              </div>
            </div>
            <div class="mg-migrations__role-grid">
              {{#each @controller.selectedRoleCards as |role|}}
                <div class="mg-migrations__role-card">
                  <div class="mg-migrations__card-header">
                    <span class="mg-migrations__role-title">{{role.name}}</span>
                    <span class={{role.badgeClass}}>{{role.existsLabel}}</span>
                  </div>
                  <div>{{role.backendLabel}} · {{role.legacyLabel}}</div>
                  <span class="mg-migrations__muted">{{role.contentType}}</span>
                  <span class="mg-migrations__muted mg-migrations__role-locator">{{role.locator}}</span>
                </div>
              {{/each}}
            </div>

            <div class="mg-migrations__panel-header" style="margin-top: 1.1rem;">
              <div class="mg-migrations__panel-copy">
                <h3>Migration preview</h3>
                <span class="mg-migrations__muted">Load the dry-run preview only when you need to inspect source and target object coverage.</span>
              </div>
              <button class="btn" type="button" {{on "click" @controller.loadSelectedPlan}} disabled={{@controller.loadPlanDisabled}}>
                {{if @controller.isLoadingPlan "Loading preview…" "Load preview"}}
              </button>
            </div>

            {{#if @controller.selectedPlanHint}}
              <p class="mg-migrations__muted" style="margin-bottom: 0.75rem;">{{@controller.selectedPlanHint}}</p>
            {{/if}}

            {{#if @controller.selectedPlanSummary}}
              <div class="mg-migrations__panel-header" style="margin-top: 1.1rem;">
                <div class="mg-migrations__panel-copy">
                  <h3>Migration summary</h3>
                  <span class="mg-migrations__muted">Dry-run preview of the move from the current profile to the configured target profile.</span>
                </div>
              </div>

              <div class="mg-migrations__summary-grid" style="margin-bottom: 1rem;">
                <div class="mg-migrations__summary-card">
                  <div class="mg-migrations__summary-label">Source</div>
                  <div class="mg-migrations__summary-title">{{@controller.selectedPlanSummary.sourceLabel}}</div>
                </div>
                <div class="mg-migrations__summary-card">
                  <div class="mg-migrations__summary-label">Target</div>
                  <div class="mg-migrations__summary-title">{{@controller.selectedPlanSummary.targetLabel}}</div>
                </div>
                <div class="mg-migrations__summary-card">
                  <div class="mg-migrations__summary-label">Objects</div>
                  <div class="mg-migrations__summary-title">{{@controller.selectedPlanSummary.objectCountLabel}}</div>
                  <span class="mg-migrations__muted">{{@controller.selectedPlanSummary.objectCountCaption}}</span>
                  <span class="mg-migrations__muted">{{@controller.selectedPlanSummary.sourceBytesLabel}}</span>
                </div>
                <div class="mg-migrations__summary-card">
                  <div class="mg-migrations__summary-label">Target readiness</div>
                  <div class="mg-migrations__summary-title">{{@controller.selectedPlanSummary.targetExistingLabel}}</div>
                  <span class="mg-migrations__muted">{{@controller.selectedPlanSummary.targetExistingCaption}}</span>
                  <span class="mg-migrations__muted">{{@controller.selectedPlanSummary.targetExistingBytesLabel}}</span>
                  <div class="mg-migrations__warning-list" style="margin-top: 0.65rem;">
                    <span class={{@controller.selectedPlanSummary.missingBadgeClass}}>{{@controller.selectedPlanSummary.missingCountLabel}} missing</span>
                  </div>
                  <span class="mg-migrations__muted">{{@controller.selectedPlanSummary.switchReadinessLabel}}</span>
                </div>
              </div>

              {{#if @controller.selectedPlanSummary.warnings.length}}
                <div class="mg-migrations__warning-list">
                  {{#each @controller.selectedPlanSummary.warnings as |warning|}}
                    <span class="mg-migrations__badge is-warning">{{warning}}</span>
                  {{/each}}
                </div>
              {{/if}}

              {{#if @controller.selectedPlanError}}
                <div class="alert alert-warning" style="margin-top: 1rem;">{{@controller.selectedPlanError}}</div>
              {{/if}}

              <div class="mg-migrations__role-grid" style="margin-top: 1rem;">
                {{#each @controller.selectedPlanRoleCards as |role|}}
                  <div class="mg-migrations__role-card">
                    <div class="mg-migrations__card-header">
                      <span class="mg-migrations__role-title">{{role.name}}</span>
                      <span class={{role.missingBadgeClass}}>{{role.missingCountLabel}} missing</span>
                    </div>
                    <div>{{role.backendLabel}}</div>
                    <span class="mg-migrations__muted">{{role.objectCountLabel}} objects • {{role.sourceBytesLabel}}</span>
                    <span class="mg-migrations__muted">{{role.targetExistingLabel}} already on target</span>
                    {{#if role.warnings.length}}
                      <div class="mg-migrations__warning-list">
                        {{#each role.warnings as |warning|}}
                          <span class="mg-migrations__badge is-warning">{{warning}}</span>
                        {{/each}}
                      </div>
                    {{/if}}
                  </div>
                {{/each}}
              </div>
            {{else if @controller.selectedPlanError}}
              <div class="alert alert-warning" style="margin-top: 1rem;">{{@controller.selectedPlanError}}</div>
            {{/if}}

            {{#if @controller.selectedPlanLoaded}}
              <details class="mg-migrations__details">
                <summary>{{i18n "admin.media_gallery.migrations.plan"}} JSON</summary>
                <pre class="mg-migrations__json">{{@controller.rawPlanJson}}</pre>
              </details>
            {{/if}}

            <details class="mg-migrations__details">
              <summary>{{i18n "admin.media_gallery.migrations.diagnostics"}} JSON</summary>
              <pre class="mg-migrations__json">{{@controller.rawDiagnosticsJson}}</pre>
            </details>
          {{else}}
            <div class="mg-migrations__empty">{{i18n "admin.media_gallery.migrations.no_selection"}}</div>
          {{/if}}
        </section>
      </div>
    </div>
  </template>
);
