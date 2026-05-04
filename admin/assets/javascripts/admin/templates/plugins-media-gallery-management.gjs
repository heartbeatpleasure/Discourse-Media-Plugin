import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-management {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-management p,
      .media-gallery-admin-management h1,
      .media-gallery-admin-management h2,
      .media-gallery-admin-management h3 {
        margin: 0;
      }

      .mg-management__grid,
      .mg-management__filters,
      .mg-management__summary-grid,
      .mg-management__edit-grid,
      .mg-management__history-list,
      .mg-management__results-list {
        display: grid;
        gap: 1rem;
      }

      .mg-management__grid {
        grid-template-columns: minmax(0, 1.15fr) minmax(360px, 0.95fr);
        align-items: start;
      }

      .mg-management__panel {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-management__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-management__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-management__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-management__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--mg-border);
        margin-bottom: 1rem;
      }

      .mg-management__flash.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-management__flash.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-management__processing-error {
        display: grid;
        grid-template-columns: minmax(0, 1fr);
        gap: 0.35rem;
        margin-top: 1rem;
        padding: 0.85rem 1rem;
        border: 1px solid var(--danger-low-mid);
        border-radius: 14px;
        background: var(--danger-low);
        color: var(--primary-high);
        overflow-wrap: anywhere;
      }

      .mg-management__processing-error-title {
        color: var(--danger);
        font-weight: 700;
      }

      .mg-management__processing-error-message,
      .mg-management__processing-error-advice,
      .mg-management__processing-error-retry,
      .mg-management__processing-error-raw {
        line-height: 1.45;
        white-space: normal;
        word-break: normal;
        overflow-wrap: anywhere;
      }

      .mg-management__processing-error-raw {
        color: var(--mg-muted);
        font-family: var(--d-font-family--monospace, monospace);
        font-size: var(--font-down-1);
      }

      .mg-management__filters {
        grid-template-columns: repeat(4, minmax(0, 1fr));
        align-items: end;
      }

      .mg-management__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-management__field.is-search {
        grid-column: 1 / -1;
      }

      .mg-management__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-management__field input,
      .mg-management__field select,
      .mg-management__field textarea {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--mg-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        min-height: 42px;
      }

      .mg-management__field textarea {
        min-height: 118px;
        resize: vertical;
        padding-top: 0.75rem;
      }

      .mg-management__filters-footer,
      .mg-management__actions,
      .mg-management__tag-picker {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
        align-items: center;
      }

      .mg-management__filters-footer {
        justify-content: space-between;
        margin-top: 1rem;
      }

      .mg-management__action-groups {
        display: grid;
        gap: 0.75rem;
        margin-top: 1rem;
      }

      .mg-management__action-row {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem;
        align-items: center;
      }

      .mg-management__action-row-label {
        flex: 0 0 110px;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-management__results-wrap {
        margin-top: 0.5rem;
      }

      .mg-management__result-card {
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

      .mg-management__result-card.is-selected {
        border-color: var(--tertiary);
        box-shadow: inset 0 0 0 1px var(--tertiary);
        background: var(--secondary);
      }

      .mg-management__thumb,
      .mg-management__thumb-placeholder {
        width: 128px;
        aspect-ratio: 16 / 9;
        border-radius: 14px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
        grid-area: thumb;
        align-self: start;
      }

      .mg-management__thumb {
        object-fit: cover;
      }

      .mg-management__thumb-placeholder,
      .mg-management__selected-thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        text-align: center;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        padding: 0.5rem;
        box-sizing: border-box;
      }

      .mg-management__result-copy,
      .mg-management__selected-header-copy {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-management__result-copy {
        grid-area: main;
        align-self: start;
      }

      .mg-management__result-title,
      .mg-management__selected-title {
        font-size: 1.35rem;
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-management__result-title {
        font-size: 1.1rem;
      }

      .mg-management__result-subtitle,
      .mg-management__selected-subtitle {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-management__badge-row {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .mg-management__badge-row.is-compact {
        gap: 0.35rem;
      }

      .mg-management__result-badges {
        grid-area: badges;
      }

      .mg-management__result-action {
        grid-area: action;
        align-self: start;
      }

      .mg-management__badge,
      .mg-management__tag-chip {
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

      .mg-management__tag-chip {
        cursor: pointer;
      }

      .mg-management__tag-chip.is-selected,
      .mg-management__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-management__badge.is-warning {
        background: var(--highlight-low, #fff7cc);
        color: var(--primary-high);
        border-color: var(--highlight-medium, #f2d675);
      }

      .mg-management__badge.is-danger {
        background: var(--danger-low);
        color: var(--danger);
        border-color: var(--danger-low-mid);
      }

      .mg-management__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      }

      .mg-management__summary-card,
      .mg-management__editor-section,
      .mg-management__history-card {
        border: 1px solid var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
        padding: 0.95rem;
      }

      .mg-management__editor-section.is-warning {
        background: var(--tertiary-very-low);
        border-color: var(--tertiary-low);
      }

      .mg-management__editor-section.is-duplicate-section {
        background: var(--mg-surface);
        border-color: var(--mg-border);
      }

      .mg-management__summary-card {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
      }

      .mg-management__summary-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-management__summary-value {
        font-weight: 600;
        overflow-wrap: anywhere;
      }


      .mg-management__hls-card {
        gap: 0.5rem;
      }

      .mg-management__hls-card .mg-management__badge,
      .mg-management__hls-status-card .mg-management__badge {
        align-self: flex-start;
        padding: 0.15rem 0.5rem;
        font-size: var(--font-down-2);
      }

      .mg-management__hls-detail {
        color: var(--mg-muted);
        font-family: var(--d-font-family--monospace, monospace);
        font-size: var(--font-down-1);
        line-height: 1.35;
        overflow-wrap: anywhere;
      }


      .mg-management__summary-card.is-wide {
        grid-column: 1 / -1;
      }

      .mg-management__section-title-row {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.65rem;
        position: relative;
      }

      .mg-management__help-item {
        position: relative;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
      }

      .mg-management__help-icon {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 1.35rem;
        height: 1.35rem;
        border-radius: 999px;
        border: 1px solid var(--tertiary);
        background: var(--tertiary);
        color: var(--secondary);
        font-size: 0.76rem;
        font-weight: 700;
        line-height: 1;
        cursor: help;
        user-select: none;
      }

      .mg-management__help-text {
        position: absolute;
        right: 0;
        bottom: calc(100% + 0.5rem);
        z-index: 3000;
        width: min(19rem, calc(100vw - 3rem));
        max-width: 19rem;
        padding: 0.75rem 0.85rem;
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
        color: var(--primary-high);
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
        white-space: normal;
        overflow-wrap: anywhere;
        font-size: var(--font-down-1);
        font-weight: 400;
        line-height: 1.4;
        opacity: 0;
        pointer-events: none;
        transform: translateY(0.15rem);
        transition: opacity 0.14s ease, transform 0.14s ease;
      }

      .mg-management__help-item:hover .mg-management__help-text,
      .mg-management__help-item:focus-within .mg-management__help-text {
        opacity: 1;
        transform: translateY(0);
      }

      .mg-management__selected-header {
        display: grid;
        grid-template-columns: 180px minmax(0, 1fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-management__selected-thumb,
      .mg-management__selected-thumb-placeholder {
        width: 100%;
        aspect-ratio: 16 / 9;
        border-radius: 16px;
        border: 1px solid var(--mg-border);
        background: var(--secondary);
      }

      .mg-management__selected-thumb {
        object-fit: cover;
      }

      .mg-management__selected-badges {
        grid-column: 1 / -1;
        padding-top: 0.1rem;
      }

      .mg-management__editor {
        display: grid;
        gap: 1rem;
        margin-top: 1rem;
      }

      .mg-management__edit-grid {
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      }

      .mg-management__history-list {
        gap: 0.9rem;
      }

      .mg-management__history-card {
        display: grid;
        gap: 0.7rem;
        background: var(--secondary);
        box-shadow: inset 0 0 0 1px var(--mg-border);
      }

      .mg-management__history-meta {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem 0.85rem;
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-management__history-note {
        padding: 0.55rem 0.7rem;
        border-radius: 12px;
        border: 1px solid var(--mg-border);
        background: var(--mg-surface-alt);
      }

      .mg-management__history-row {
        display: grid;
        gap: 0.25rem;
      }

      .mg-management__history-row-label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-management__history-row-values {
        display: flex;
        flex-wrap: wrap;
        gap: 0.4rem;
        align-items: center;
        padding: 0.55rem 0.65rem;
        border-radius: 10px;
        background: var(--mg-surface-alt);
        border: 1px solid var(--mg-border);
        font-size: var(--font-down-1);
      }

      .mg-management__history-arrow {
        color: var(--mg-muted);
      }

      .mg-management__empty-state {
        display: grid;
        gap: 0.35rem;
        padding: 1.1rem;
        border: 1px dashed var(--mg-border);
        border-radius: 16px;
        background: var(--mg-surface-alt);
      }

      @media (max-width: 1100px) {
        .mg-management__grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 800px) {
        .mg-management__selected-header,
        .mg-management__filters {
          grid-template-columns: 1fr;
        }

        .mg-management__result-card {
          grid-template-columns: 1fr;
          grid-template-areas:
            "thumb"
            "main"
            "badges"
            "action";
        }

        .mg-management__thumb,
        .mg-management__thumb-placeholder {
          width: 100%;
          max-width: 180px;
        }
      }
    </style>

    <div class="media-gallery-admin-management">
      <h1>{{i18n "admin.media_gallery.management.title"}}</h1>
      <p>{{i18n "admin.media_gallery.management.description"}}</p>

      <section class="mg-management__panel">
        <div class="mg-management__panel-header">
          <div class="mg-management__panel-copy">
            <h2>Find media</h2>
            <p class="mg-management__muted">Search by title, public ID, or owner, then open an item to manage it.</p>
          </div>
        </div>

        <div class="mg-management__filters">
          <div class="mg-management__field is-search">
            <label>Search</label>
            <input type="text" value={{@controller.searchQuery}} placeholder="Search by public_id / title / id..." {{on "input" @controller.onSearchInput}} />
          </div>

          <div class="mg-management__field">
            <label>Backend</label>
            <select value={{@controller.backendFilter}} {{on "change" @controller.onBackendFilterChange}}>
              <option value="all">All</option>
              <option value="local">Local</option>
              <option value="s3">S3</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Storage profile</label>
            <select value={{@controller.profileFilter}} {{on "change" @controller.onProfileFilterChange}}>
              <option value="all">All</option>
              {{#each @controller.profileOptions as |profile|}}
                <option value={{profile.value}} selected={{profile.selected}}>{{profile.label}}</option>
              {{/each}}
            </select>
          </div>

          <div class="mg-management__field">
            <label>Status</label>
            <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusFilterChange}}>
              <option value="all">All</option>
              <option value="ready">Ready</option>
              <option value="queued">Queued</option>
              <option value="processing">Processing</option>
              <option value="failed">Failed</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Type</label>
            <select value={{@controller.mediaTypeFilter}} {{on "change" @controller.onMediaTypeFilterChange}}>
              <option value="all">All</option>
              <option value="image">Image</option>
              <option value="audio">Audio</option>
              <option value="video">Video</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>HLS AES</label>
            <select value={{@controller.hlsAes128Filter}} {{on "change" @controller.onHlsAes128FilterChange}}>
              <option value="all">All</option>
              <option value="ready">AES-ready</option>
              <option value="needs_backfill">Needs AES backfill (eligible)</option>
              <option value="not_encrypted">All legacy / no AES</option>
              <option value="not_ready">AES metadata/key issue</option>
              <option value="no_hls">No HLS</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Visibility</label>
            <select value={{@controller.hiddenFilter}} {{on "change" @controller.onHiddenFilterChange}}>
              <option value="all">All</option>
              <option value="visible">Visible</option>
              <option value="hidden">Hidden</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Duplicates</label>
            <select value={{@controller.duplicateFilter}} {{on "change" @controller.onDuplicateFilterChange}}>
              <option value="all">All</option>
              <option value="possible">Possible duplicates only</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>The file contains</label>
            <select value={{@controller.genderFilter}} {{on "change" @controller.onGenderFilterChange}}>
              <option value="all">All</option>
              <option value="male">Male hearts</option>
              <option value="female">Female hearts</option>
              <option value="both">Both male and female hearts</option>
              <option value="non_binary">Non-binary hearts</option>
              <option value="objects">Heart-related objects</option>
              <option value="other">Other</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Limit</label>
            <select value={{@controller.limit}} {{on "change" @controller.onLimitChange}}>
              <option value="20">20</option>
              <option value="50">50</option>
              <option value="100">100</option>
            </select>
          </div>

          <div class="mg-management__field">
            <label>Sort</label>
            <select value={{@controller.sortBy}} {{on "change" @controller.onSortChange}}>
              <option value="newest">Newest</option>
              <option value="oldest">Oldest</option>
              <option value="updated_desc">Recently updated</option>
              <option value="title_asc">Title A–Z</option>
              <option value="title_desc">Title Z–A</option>
            </select>
          </div>
        </div>

        <div class="mg-management__filters-footer">
          <div class="mg-management__actions">
            <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isSearching}}>
              {{if @controller.isSearching "Searching…" "Search"}}
            </button>
            <button class="btn" type="button" {{on "click" @controller.resetFilters}} disabled={{@controller.isSearching}}>Reset</button>
            <button class="btn" type="button" {{on "click" @controller.bulkQueueAesBackfill}} disabled={{@controller.bulkAesBackfillDisabled}}>
              {{if @controller.isBulkAesBackfilling "Queuing AES…" "Queue AES backfill for filtered"}}
            </button>
          </div>
          {{#if @controller.searchInfo}}
            <span class="mg-management__muted">{{@controller.searchInfo}}</span>
          {{/if}}
        </div>

        {{#if @controller.searchError}}
          <div class="mg-management__flash is-danger" style="margin-top: 1rem;">{{@controller.searchError}}</div>
        {{/if}}
      </section>

      <div class="mg-management__grid">
        <section class="mg-management__panel">
          <div class="mg-management__panel-header">
            <div class="mg-management__panel-copy">
              <h2>Results</h2>
              <span class="mg-management__muted">Open an item from the current search result to manage it.</span>
            </div>
          </div>

          <div class="mg-management__results-wrap">
            {{#if @controller.searchResults.length}}
              <div class="mg-management__results-list">
                {{#each @controller.decoratedSearchResults key="public_id" as |item|}}
                  <article class="mg-management__result-card {{if item.isSelected "is-selected"}}">
                    {{#if item.thumbnail_url}}
                      <img class="mg-management__thumb" loading="lazy" src={{item.thumbnail_url}} alt="thumbnail" />
                    {{else}}
                      <div class="mg-management__thumb-placeholder">No thumbnail</div>
                    {{/if}}

                    <div class="mg-management__result-copy">
                      <div class="mg-management__result-title">{{item.title}}</div>
                      <div class="mg-management__result-subtitle">{{item.public_id}}</div>
                      {{#if item.displayMeta}}
                        <div class="mg-management__muted">{{item.displayMeta}}</div>
                      {{/if}}
                    </div>

                    <button class="btn mg-management__result-action" type="button" {{on "click" (fn @controller.selectItem item)}}>
                      {{if item.isSelected "Selected" "Open"}}
                    </button>

                    <div class="mg-management__badge-row is-compact mg-management__result-badges">
                      <span class="mg-management__badge {{item.statusBadgeClass}}">{{item.displayStatus}}</span>
                      <span class="mg-management__badge">{{item.displayMediaType}}</span>
                      <span class="mg-management__badge">{{item.displayStorage}}</span>
                      {{#if item.aesBadge}}
                        <span class="mg-management__badge {{item.aesBadge.className}}" title={{item.aesBadge.title}}>{{item.aesBadge.label}}</span>
                      {{/if}}
                      <span class="mg-management__badge {{item.visibilityBadgeClass}}">{{item.displayVisibility}}</span>
                      {{#if item.displayDuplicate}}
                        <span class="mg-management__badge {{item.duplicateBadgeClass}}">{{item.displayDuplicate}}</span>
                      {{/if}}
                    </div>
                  </article>
                {{/each}}
              </div>
            {{else if @controller.hasSearched}}
              <div class="mg-management__empty-state">
                <strong>No items found</strong>
                <span class="mg-management__muted">Try a broader search or reset the filters.</span>
              </div>
            {{/if}}
          </div>
        </section>

        <section class="mg-management__panel">
          <div class="mg-management__panel-header">
            <div class="mg-management__panel-copy">
              <h2>Selected item</h2>
              <p class="mg-management__muted">Inspect the item, update metadata, or change visibility from one place.</p>
            </div>
          </div>

          {{#if @controller.noticeMessage}}
            <div class={{@controller.noticeClass}}>{{@controller.noticeMessage}}</div>
          {{/if}}
          {{#if @controller.selectionError}}
            <div class="mg-management__flash is-danger">{{@controller.selectionError}}</div>
          {{/if}}

          {{#if @controller.hasSelectedItem}}
            <div class="mg-management__selected-header">
              {{#if @controller.selectedItem.thumbnail_url}}
                <img class="mg-management__selected-thumb" loading="lazy" src={{@controller.selectedItem.thumbnail_url}} alt="thumbnail" />
              {{else}}
                <div class="mg-management__selected-thumb-placeholder">No thumbnail available</div>
              {{/if}}

              <div class="mg-management__selected-header-copy">
                <div class="mg-management__selected-title">{{@controller.selectedItem.title}}</div>
                <div class="mg-management__selected-subtitle">{{@controller.selectedItem.public_id}}</div>
              </div>

              <div class="mg-management__badge-row mg-management__selected-badges">
                <span class="mg-management__badge {{@controller.selectedStatusBadgeClass}}">{{@controller.selectedDisplayStatus}}</span>
                <span class="mg-management__badge">{{@controller.selectedDisplayMediaType}}</span>
                <span class="mg-management__badge">{{@controller.selectedDisplayStorage}}</span>
                {{#if @controller.selectedAesBadge}}
                  <span class="mg-management__badge {{@controller.selectedAesBadge.className}}" title={{@controller.selectedAesBadge.title}}>{{@controller.selectedAesBadge.label}}</span>
                {{/if}}
                <span class="mg-management__badge {{@controller.selectedVisibilityBadgeClass}}">{{if @controller.selectedItem.hidden "Hidden" "Visible"}}</span>
                {{#if @controller.selectedHasPossibleDuplicate}}
                  <span class="mg-management__badge {{@controller.selectedDuplicateBadgeClass}}">Possible duplicate</span>
                {{/if}}
              </div>
            </div>

            {{#if @controller.selectedProcessingErrorMessage}}
              <div class="mg-management__processing-error">
                <div class="mg-management__processing-error-title">{{@controller.selectedProcessingErrorTitle}}</div>
                <div class="mg-management__processing-error-message">{{@controller.selectedProcessingErrorSummary}}</div>
                {{#if @controller.selectedProcessingErrorAdvice}}
                  <div class="mg-management__processing-error-advice">{{@controller.selectedProcessingErrorAdvice}}</div>
                {{/if}}
                {{#if @controller.selectedProcessingErrorRetry}}
                  <div class="mg-management__processing-error-retry">{{@controller.selectedProcessingErrorRetry}}</div>
                {{/if}}
                <div class="mg-management__processing-error-raw">Raw code: {{@controller.selectedProcessingErrorMessage}}</div>
              </div>
            {{/if}}

            <div class="mg-management__summary-grid" style="margin-top: 1rem;">
              {{#each @controller.selectedMetaRows as |row|}}
                <div class="mg-management__summary-card">
                  <div class="mg-management__summary-label">{{row.label}}</div>
                  <div class="mg-management__summary-value">{{row.value}}</div>
                </div>
              {{/each}}
            </div>

            {{#if @controller.selectedHasPossibleDuplicate}}
              <section class="mg-management__editor-section is-duplicate-section" style="margin-top: 1rem;">
                <h3>Duplicate detection</h3>
                <p class="mg-management__muted" style="margin-top: 0.3rem;">
                  This item was created after an exact SHA1 + file size match with an existing media item. Review the match before deciding whether to keep, hide, or delete this item.
                </p>
                <div class="mg-management__summary-grid" style="margin-top: 1rem;">
                  {{#each @controller.selectedDuplicateDetectionRows as |row|}}
                    <div class="mg-management__summary-card {{if row.wide "is-wide"}}">
                      <div class="mg-management__summary-label">{{row.label}}</div>
                      <div class="mg-management__summary-value">{{row.value}}</div>
                    </div>
                  {{/each}}
                </div>
              </section>
            {{/if}}

            <div class="mg-management__editor">
              <section class="mg-management__editor-section">
                <div class="mg-management__field">
                  <label>Title</label>
                  <input type="text" value={{@controller.editTitle}} {{on "input" @controller.onEditTitle}} />
                </div>

                <div class="mg-management__field" style="margin-top: 1rem;">
                  <label>Description</label>
                  <textarea rows="5" value={{@controller.editDescription}} {{on "input" @controller.onEditDescription}}></textarea>
                </div>

                <div class="mg-management__edit-grid" style="margin-top: 1rem;">
                  <div class="mg-management__field">
                    <label>The file contains</label>
                    <select value={{@controller.editGender}} {{on "change" @controller.onEditGender}}>
                      <option value="">{{i18n "media_gallery.genders.select_placeholder"}}</option>
                      <option value="male">{{i18n "media_gallery.genders.male"}}</option>
                      <option value="female">{{i18n "media_gallery.genders.female"}}</option>
                      <option value="both">{{i18n "media_gallery.genders.both"}}</option>
                      <option value="non_binary">{{i18n "media_gallery.genders.non_binary"}}</option>
                      <option value="objects">{{i18n "media_gallery.genders.objects"}}</option>
                      <option value="other">{{i18n "media_gallery.genders.other"}}</option>
                    </select>
                  </div>

                  <div class="mg-management__field">
                    <label>Tags</label>
                    {{#if @controller.usingAllowedTags}}
                      <div class="mg-management__tag-picker">
                        {{#each @controller.decoratedAllowedTagOptions as |tag|}}
                          <button type="button" class="mg-management__tag-chip {{if tag.isSelected "is-selected"}}" {{on "click" (fn @controller.toggleTag tag.value)}}>
                            {{tag.label}}
                          </button>
                        {{/each}}
                      </div>
                    {{else}}
                      <input type="text" value={{@controller.editTagsText}} placeholder="comma,separated,tags" {{on "input" @controller.onEditTagsText}} />
                    {{/if}}
                  </div>
                </div>

                <div class="mg-management__field" style="margin-top: 1rem;">
                  <label>Admin note / reason</label>
                  <textarea rows="3" value={{@controller.adminNote}} placeholder="Optional note for save, hide, unhide, or delete" {{on "input" @controller.onAdminNote}}></textarea>
                </div>
              </section>

              {{#if @controller.hlsIntegrityResult}}
                <section class="mg-management__editor-section" style="margin-top: 1rem;">
                  <h3>HLS integrity verification</h3>
                  <p class="mg-management__muted" style="margin-top: 0.3rem;">{{@controller.hlsIntegrityResult.summary}}</p>
                  <div class="mg-management__summary-card mg-management__hls-status-card" style="margin-top: 1rem;">
                    <div class="mg-management__summary-label">Status</div>
                    <span class={{@controller.hlsIntegrityStatusBadgeClass}}>{{@controller.hlsIntegrityStatusLabel}}</span>
                  </div>
                  <div class="mg-management__summary-grid" style="margin-top: 1rem;">
                    {{#each @controller.hlsIntegrityChecks as |check|}}
                      <div class="mg-management__summary-card mg-management__hls-card">
                        <div class="mg-management__summary-label">{{check.message}}</div>
                        <span class={{check.statusBadgeClass}}>{{check.statusLabel}}</span>
                        {{#if check.displayDetail}}<div class="mg-management__hls-detail">{{check.displayDetail}}</div>{{/if}}
                      </div>
                    {{/each}}
                  </div>
                </section>
              {{/if}}

              <section class="mg-management__editor-section">
                <h3>Actions</h3>
                <p class="mg-management__muted" style="margin-top: 0.3rem;">Save metadata, add an admin note, toggle visibility, queue a retry for failed items, change uploader access, or remove the item.</p>
                <div class="mg-management__summary-card" style="margin-top: 1rem;">
                  <div class="mg-management__section-title-row">
                    <div>
                      <div class="mg-management__summary-label">Uploader access to media section</div>
                      <div class="mg-management__summary-value">{{@controller.ownerMediaAccessLabel}}</div>
                    </div>
                    <div class="mg-management__help-item">
                      <span class="mg-management__help-icon" tabindex="0" aria-label="Uploader access help">i</span>
                      <div class="mg-management__help-text">{{@controller.ownerMediaAccessHelp}}</div>
                    </div>
                  </div>
                </div>

                <div class="mg-management__action-groups">
                  <div class="mg-management__action-row">
                    <span class="mg-management__action-row-label">Item</span>
                    <button class="btn btn-primary" type="button" {{on "click" @controller.saveChanges}} disabled={{@controller.saveDisabled}}>
                      {{if @controller.isSaving "Saving…" "Save changes"}}
                    </button>
                    <button class="btn" type="button" {{on "click" @controller.toggleHidden}} disabled={{@controller.toggleHiddenDisabled}}>
                      {{if @controller.isTogglingHidden "Updating…" @controller.hiddenButtonLabel}}
                    </button>
                    <button class="btn" type="button" {{on "click" @controller.retryProcessing}} disabled={{@controller.retryDisabled}}>
                      {{if @controller.isRetrying "Queuing…" "Retry processing"}}
                    </button>
                    <button class="btn" type="button" {{on "click" @controller.refreshSelected}} disabled={{@controller.isLoadingSelection}}>
                      {{if @controller.isLoadingSelection "Refreshing…" "Refresh"}}
                    </button>
                  </div>

                  <div class="mg-management__action-row">
                    <span class="mg-management__action-row-label">HLS</span>
                    <button class="btn" type="button" {{on "click" @controller.queueAesBackfill}} disabled={{@controller.selectedAesBackfillDisabled}}>
                      {{@controller.selectedAesBackfillButtonLabel}}
                    </button>
                    <button class="btn" type="button" {{on "click" @controller.verifyHlsIntegrity}} disabled={{@controller.isVerifyingHlsIntegrity}}>
                      {{if @controller.isVerifyingHlsIntegrity "Checking HLS…" "Verify HLS integrity"}}
                    </button>
                    <button class="btn" type="button" {{on "click" @controller.copyDiagnosticsBundle}} disabled={{@controller.isCopyingDiagnostics}}>
                      {{if @controller.isCopyingDiagnostics "Copying diagnostics…" "Copy diagnostics"}}
                    </button>
                  </div>

                  <div class="mg-management__action-row">
                    <span class="mg-management__action-row-label">View access</span>
                    <button class="btn btn-danger" type="button" {{on "click" (fn @controller.toggleOwnerMediaBlock "view-block")}} disabled={{@controller.ownerViewBlockDisabled}}>
                      Block view & upload
                    </button>
                    <button class="btn" type="button" {{on "click" (fn @controller.toggleOwnerMediaBlock "view-unblock")}} disabled={{@controller.ownerViewUnblockDisabled}}>
                      Restore view
                    </button>
                  </div>

                  <div class="mg-management__action-row">
                    <span class="mg-management__action-row-label">Upload access</span>
                    <button class="btn btn-danger" type="button" {{on "click" (fn @controller.toggleOwnerMediaBlock "upload-block")}} disabled={{@controller.ownerUploadBlockDisabled}}>
                      Block upload only
                    </button>
                    <button class="btn" type="button" {{on "click" (fn @controller.toggleOwnerMediaBlock "upload-unblock")}} disabled={{@controller.ownerUploadUnblockDisabled}}>
                      Restore upload
                    </button>
                  </div>

                  <div class="mg-management__action-row">
                    <span class="mg-management__action-row-label">Danger zone</span>
                    <button class="btn btn-danger" type="button" {{on "click" @controller.deleteItem}} disabled={{@controller.deleteDisabled}}>
                      {{if @controller.isDeleting "Deleting…" "Delete item"}}
                    </button>
                  </div>
                </div>
              </section>

              <section class="mg-management__editor-section">
                <h3>Admin history</h3>
                <p class="mg-management__muted" style="margin-top: 0.3rem;">Track changes made by admins, including optional notes.</p>

                {{#if @controller.historyEntries.length}}
                  <div class="mg-management__history-list" style="margin-top: 1rem;">
                    {{#each @controller.historyEntries as |entry|}}
                      <article class="mg-management__history-card">
                        <div class="mg-management__history-meta">
                          <span>{{entry.prettyAt}}</span>
                          <span>{{entry.admin_username}}</span>
                          <strong>{{entry.actionLabel}}</strong>
                        </div>
                        {{#if entry.note}}
                          <div class="mg-management__history-note">{{entry.note}}</div>
                        {{/if}}
                        {{#if entry.changeRows.length}}
                          <div class="mg-management__history-list">
                            {{#each entry.changeRows as |row|}}
                              <div class="mg-management__history-row">
                                <div class="mg-management__history-row-label">{{row.label}}</div>
                                <div class="mg-management__history-row-values">
                                  <span>{{row.from}}</span>
                                  <span class="mg-management__history-arrow">→</span>
                                  <span>{{row.to}}</span>
                                </div>
                              </div>
                            {{/each}}
                          </div>
                        {{/if}}
                      </article>
                    {{/each}}
                  </div>
                {{else}}
                  <div class="mg-management__empty-state" style="margin-top: 1rem;">
                    <strong>No admin changes recorded yet</strong>
                    <span class="mg-management__muted">History entries will appear here after edits or visibility changes.</span>
                  </div>
                {{/if}}
              </section>
            </div>
          {{else}}
            <div class="mg-management__empty-state">
              <strong>No item selected</strong>
              <span class="mg-management__muted">Choose an item from the results list to inspect and manage it here.</span>
            </div>
          {{/if}}
        </section>
      </div>
    </div>
  </template>
);
