import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-forensics-identify {
        --mg-fi-surface: var(--secondary);
        --mg-fi-surface-alt: var(--primary-very-low);
        --mg-fi-border: var(--primary-low);
        --mg-fi-muted: var(--primary-medium);
        --mg-fi-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-forensics-identify h1,
      .media-gallery-forensics-identify h2,
      .media-gallery-forensics-identify h3,
      .media-gallery-forensics-identify p,
      .media-gallery-forensics-identify ul,
      .media-gallery-forensics-identify ol,
      .media-gallery-forensics-identify pre {
        margin: 0;
      }

      .mg-fi__panel {
        background: var(--mg-fi-surface);
        border: 1px solid var(--mg-fi-border);
        border-radius: var(--mg-fi-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: visible;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-fi__panel-header {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        margin-bottom: 0.9rem;
      }

      .mg-fi__muted,
      .mg-fi__helper,
      .mg-fi__meta-label,
      .mg-fi__result-subtitle,
      .mg-fi__result-meta,
      .mg-fi__search-footer,
      .mg-fi__empty {
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
      }

      .mg-fi__filters-grid,
      .mg-fi__summary-grid,
      .mg-fi__meta-list,
      .mg-fi__form-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-fi__filters-grid {
        grid-template-columns: repeat(4, minmax(0, 1fr));
        margin-top: 1rem;
        align-items: end;
      }

      .mg-fi__form-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
        align-items: end;
      }

      .mg-fi__grid {
        display: grid;
        grid-template-columns: minmax(0, 1.1fr) minmax(340px, 0.9fr);
        gap: 1rem;
        align-items: start;
      }

      .mg-fi__sidebar-stack {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .mg-fi__field {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-fi__field.is-full {
        grid-column: 1 / -1;
      }

      .mg-fi__field label {
        font-weight: 600;
        font-size: var(--font-down-1);
      }

      .mg-fi__field input,
      .mg-fi__field select {
        width: 100%;
        box-sizing: border-box;
        min-height: 42px;
        border-radius: 12px;
        border: 1px solid var(--mg-fi-border);
        background: var(--primary-very-low);
        padding: 0.625rem 0.85rem;
      }

      .mg-fi__field input[type="file"] {
        padding: 0.5rem;
        min-height: auto;
      }

      .mg-fi__filters-footer,
      .mg-fi__actions,
      .mg-fi__lookup-actions,
      .mg-fi__result-badges,
      .mg-fi__toggle-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.75rem;
      }

      .mg-fi__filters-footer {
        justify-content: space-between;
        margin-top: 1rem;
      }

      .mg-fi__search-status {
        margin-top: 0.75rem;
      }

      .mg-fi__results-list {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .mg-fi__result-card {
        display: grid;
        grid-template-columns: 112px minmax(0, 1fr) auto;
        gap: 0.9rem 1rem;
        align-items: start;
        border: 1px solid var(--mg-fi-border);
        border-radius: 18px;
        background: var(--mg-fi-surface-alt);
        padding: 0.95rem;
      }

      .mg-fi__thumb,
      .mg-fi__thumb-placeholder {
        width: 112px;
        height: 112px;
        border-radius: 18px;
        object-fit: cover;
        background: var(--primary-very-low);
        border: 1px solid var(--mg-fi-border);
      }

      .mg-fi__thumb-placeholder {
        display: flex;
        align-items: center;
        justify-content: center;
        text-align: center;
        padding: 0.75rem;
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
      }

      .mg-fi__result-copy {
        min-width: 0;
      }

      .mg-fi__result-title {
        font-size: 1.15rem;
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-fi__result-subtitle {
        margin-top: 0.2rem;
        font-family: var(--font-family);
        overflow-wrap: anywhere;
      }

      .mg-fi__result-meta {
        margin-top: 0.3rem;
      }

      .mg-fi__result-action {
        align-self: start;
      }

      .mg-fi__result-badges {
        grid-column: 1 / -1;
      }

      .mg-fi__badge {
        display: inline-flex;
        align-items: center;
        min-height: 30px;
        padding: 0 0.85rem;
        border-radius: 999px;
        border: 1px solid var(--mg-fi-border);
        background: var(--secondary);
        color: var(--primary-high);
      }

      .mg-fi__badge.is-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-fi__badge.is-warning {
        background: var(--highlight-low);
        border-color: var(--highlight-medium);
      }

      .mg-fi__badge.is-danger {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-fi__checkbox-row {
        display: flex;
        align-items: center;
        gap: 0.65rem;
        min-height: 42px;
      }

      .mg-fi__checkbox-row label {
        display: inline-flex;
        align-items: center;
        gap: 0.65rem;
        margin: 0;
        font-weight: 600;
      }

      .mg-fi__checkbox-row input {
        margin: 0;
        width: 18px;
        height: 18px;
        accent-color: var(--tertiary);
      }

      .mg-fi__notice {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--mg-fi-border);
      }

      .mg-fi__notice.is-info {
        background: var(--primary-very-low);
      }

      .mg-fi__notice.is-success,
      .mg-fi__notice.alert-success {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .mg-fi__notice.is-warning,
      .mg-fi__notice.alert-warning,
      .mg-fi__notice.alert-info {
        background: var(--highlight-low);
        border-color: var(--highlight-medium);
        color: var(--primary-high);
      }

      .mg-fi__notice.is-danger,
      .mg-fi__notice.alert-error {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .mg-fi__section-title {
        margin: 0 0 0.9rem;
        font-size: 1rem;
        font-weight: 700;
      }

      .mg-fi__table-wrap {
        overflow: auto;
        border: 1px solid var(--mg-fi-border);
        border-radius: 14px;
        background: var(--mg-fi-surface-alt);
      }

      .mg-fi__table-wrap table {
        margin: 0;
      }

      .mg-fi__summary-grid {
        grid-template-columns: repeat(4, minmax(0, 1fr));
        margin-bottom: 1.25rem;
      }

      .mg-fi__meta-card {
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 0.9rem 1rem;
        min-width: 0;
      }

      .mg-fi__meta-card.is-span-2 {
        grid-column: span 2;
      }

      .mg-fi__metric-heading {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.5rem;
        margin-bottom: 0.15rem;
      }

      .mg-fi__meta-label {
        font-weight: 600;
      }

      .mg-fi__metric-heading {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.5rem;
        margin-bottom: 0.15rem;
        position: relative;
      }

      .mg-fi__meta-label {
        font-weight: 600;
      }

      .mg-fi__metric-help {
        position: relative;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 1.35rem;
        height: 1.35rem;
        border: 1px solid var(--tertiary);
        border-radius: 999px;
        background: var(--tertiary);
        color: var(--secondary);
        font-size: 0.76rem;
        font-weight: 700;
        line-height: 1;
        cursor: help;
        flex-shrink: 0;
        user-select: none;
      }

      .mg-fi__metric-tooltip {
        position: absolute;
        bottom: calc(100% + 0.5rem);
        right: 0;
        width: min(100%, 22rem);
        min-width: min(14rem, 100%);
        padding: 0.7rem 0.8rem;
        border-radius: 12px;
        border: 1px solid var(--mg-fi-border);
        background: var(--secondary);
        color: var(--primary-high);
        font-size: var(--font-down-1);
        font-weight: 400;
        line-height: 1.4;
        white-space: normal;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
        opacity: 0;
        pointer-events: none;
        transform: translateY(0.15rem);
        transition: opacity 0.14s ease, transform 0.14s ease;
        z-index: 3000;
      }

      .mg-fi__metric-heading.is-tooltip-left .mg-fi__metric-tooltip {
        left: 0;
        right: auto;
      }

      .mg-fi__metric-help:hover + .mg-fi__metric-tooltip,
      .mg-fi__metric-help:focus-visible + .mg-fi__metric-tooltip {
        opacity: 1;
        transform: translateY(0);
      }

      .mg-fi__meta-value {
        font-size: 1.1rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-fi__meta-value.is-code {
        font-family: var(--font-family-monospace);
        font-size: 1rem;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .mg-fi__result-section {
        margin-top: 1.5rem;
      }

      .mg-fi__candidate-summary-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 1rem;
        margin-top: 0.35rem;
      }

      .mg-fi__candidate-note-card {
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 1rem;
        margin-top: 1rem;
      }

      .mg-fi__candidate-note-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.75rem;
        margin-top: 0.75rem;
      }

      .mg-fi__candidate-score-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.75rem;
        margin-top: 0.75rem;
      }

      .mg-fi__candidate-detail-row td {
        background: var(--secondary);
      }

      .mg-fi__candidate-detail-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.75rem;
        margin-top: 0.25rem;
      }

      .mg-fi__candidate-detail-card {
        border: 1px solid var(--mg-fi-border);
        border-radius: 14px;
        background: var(--mg-fi-surface-alt);
        padding: 0.8rem 0.9rem;
        min-width: 0;
      }

      .mg-fi__candidate-detail-label {
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-fi__candidate-detail-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-fi__candidate-why {
        max-width: 24rem;
        overflow-wrap: anywhere;
      }

      .mg-fi__candidate-list {
        display: flex;
        flex-direction: column;
        gap: 0.85rem;
        margin-top: 0.75rem;
      }

      .mg-fi__candidate-header-row,
      .mg-fi__candidate-toggle-inner {
        display: grid;
        grid-template-columns: 28px minmax(0, 1.15fr) minmax(0, 1.9fr) minmax(72px, 0.55fr) minmax(90px, 0.7fr) minmax(90px, 0.7fr) minmax(80px, 0.6fr);
        gap: 1rem;
        align-items: center;
      }

      .mg-fi__candidate-header-row {
        padding: 0 1rem;
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-fi__candidate-header-row > :first-child {
        visibility: hidden;
      }

      .mg-fi__candidate-item {
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        overflow: hidden;
      }

      .mg-fi__candidate-item[open] {
        background: var(--secondary);
      }

      .mg-fi__candidate-item > summary,
      .mg-fi__candidate-toggle {
        display: block !important;
        list-style: none !important;
        list-style-type: none !important;
        list-style-image: none !important;
        appearance: none !important;
        -webkit-appearance: none !important;
        padding-inline-start: 0 !important;
      }

      .mg-fi__candidate-item > summary::-webkit-details-marker,
      .mg-fi__candidate-toggle::-webkit-details-marker {
        display: none !important;
      }

      .mg-fi__candidate-item > summary::marker,
      .mg-fi__candidate-toggle::marker {
        content: "" !important;
        display: none !important;
      }

      .mg-fi__candidate-item > summary::before,
      .mg-fi__candidate-item > summary::after,
      .mg-fi__candidate-toggle::before,
      .mg-fi__candidate-toggle::after {
        content: none !important;
        display: none !important;
      }

      .mg-fi__candidate-toggle {
        padding: 0.95rem 1rem;
        cursor: pointer;
      }

      .mg-fi__candidate-toggle-inner {
        width: 100%;
      }

      .mg-fi__candidate-chevron {
        width: 0;
        height: 0;
        border-top: 0.5rem solid transparent;
        border-bottom: 0.5rem solid transparent;
        border-left: 0.75rem solid var(--primary-high);
        transition: transform 0.14s ease;
        transform-origin: 35% 50%;
      }

      .mg-fi__candidate-item[open] .mg-fi__candidate-chevron {
        transform: rotate(90deg);
      }

      .mg-fi__candidate-user {
        display: flex;
        align-items: center;
        min-width: 0;
        font-weight: 700;
      }

      .mg-fi__candidate-fingerprint code {
        display: block;
        overflow-wrap: anywhere;
        word-break: break-word;
      }

      .mg-fi__candidate-body {
        border-top: 1px solid var(--mg-fi-border);
        padding: 0.95rem 1rem 1rem;
      }

      .mg-fi__candidate-subsection-title {
        font-size: var(--font-down-1);
        font-weight: 700;
        color: var(--mg-fi-muted);
        margin-bottom: 0.6rem;
      }

      .mg-fi__candidate-rationale-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.75rem;
      }

      .mg-fi__overlay-list {
        display: flex;
        flex-direction: column;
        gap: 0.9rem;
      }

      .mg-fi__overlay-card {
        display: grid;
        grid-template-columns: 112px minmax(0, 1fr) auto;
        gap: 0.9rem 1rem;
        align-items: start;
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 0.95rem 1rem;
      }

      .mg-fi__overlay-copy {
        min-width: 0;
      }

      .mg-fi__overlay-title {
        font-size: 1.05rem;
        font-weight: 700;
        line-height: 1.25;
      }

      .mg-fi__overlay-subtitle {
        margin-top: 0.2rem;
        color: var(--mg-fi-muted);
        overflow-wrap: anywhere;
      }

      .mg-fi__overlay-meta {
        margin-top: 0.3rem;
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
      }

      .mg-fi__overlay-action {
        align-self: start;
      }

      .mg-fi__overlay-badges {
        grid-column: 1 / -1;
        display: flex;
        flex-wrap: wrap;
        gap: 0.65rem;
      }

      .mg-fi__overlay-info-grid {
        grid-column: 1 / -1;
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.75rem;
      }

      .mg-fi__overlay-info-card {
        border: 1px solid var(--mg-fi-border);
        border-radius: 14px;
        background: var(--secondary);
        padding: 0.8rem 0.9rem;
        min-width: 0;
      }

      .mg-fi__overlay-label {
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
        margin-bottom: 0.2rem;
      }

      .mg-fi__overlay-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-fi__prose-card,
      .mg-fi__details {
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 0.9rem 1rem;
      }

      .mg-fi__details + .mg-fi__details,
      .mg-fi__prose-card + .mg-fi__details,
      .mg-fi__notice + .mg-fi__details,
      .mg-fi__details + .mg-fi__notice {
        margin-top: 1rem;
      }

      .mg-fi__details summary {
        cursor: pointer;
        font-weight: 700;
      }

      .mg-fi__code-block {
        display: block;
        white-space: pre-wrap;
        word-break: break-word;
        margin-top: 0.5rem;
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
      }

      .mg-fi__meta-list {
        grid-template-columns: repeat(2, minmax(0, 1fr));
        margin-top: 0.75rem;
      }

      .mg-fi__meta-list div {
        min-width: 0;
      }

      .mg-fi__empty {
        border: 1px dashed var(--mg-fi-border);
        border-radius: 16px;
        padding: 1rem;
        background: var(--mg-fi-surface-alt);
      }

      @media (max-width: 1100px) {
        .mg-fi__grid {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 900px) {
        .mg-fi__filters-grid,
        .mg-fi__summary-grid,
        .mg-fi__meta-list,
        .mg-fi__form-grid,
        .mg-fi__overlay-info-grid,
        .mg-fi__candidate-summary-grid,
        .mg-fi__candidate-detail-grid,
        .mg-fi__candidate-note-grid,
        .mg-fi__candidate-score-grid,
        .mg-fi__candidate-rationale-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .mg-fi__candidate-header-row,
        .mg-fi__candidate-toggle-inner {
          grid-template-columns: 28px minmax(0, 1fr) minmax(0, 1.3fr) repeat(4, minmax(70px, 0.7fr));
        }
      }

      @media (max-width: 640px) {
        .mg-fi__filters-grid,
        .mg-fi__summary-grid,
        .mg-fi__meta-list,
        .mg-fi__form-grid,
        .mg-fi__result-card,
        .mg-fi__overlay-card,
        .mg-fi__overlay-info-grid,
        .mg-fi__candidate-summary-grid,
        .mg-fi__candidate-detail-grid,
        .mg-fi__candidate-note-grid,
        .mg-fi__candidate-score-grid,
        .mg-fi__candidate-rationale-grid {
          grid-template-columns: 1fr;
        }

        .mg-fi__candidate-header-row {
          display: none;
        }

        .mg-fi__candidate-toggle {
          grid-template-columns: 1fr;
        }

        .mg-fi__meta-card.is-span-2 {
          grid-column: span 1;
        }

        .mg-fi__meta-value.is-code {
          white-space: normal;
          overflow: visible;
          text-overflow: initial;
        }

        .mg-fi__thumb,
        .mg-fi__thumb-placeholder {
          width: 100%;
          max-width: 180px;
          height: 120px;
        }
      }
    </style>

    <div class="media-gallery-forensics-identify">
      <section class="mg-fi__panel">
        <div class="mg-fi__panel-header">
          <h1>{{i18n "admin.media_gallery.forensics_identify.title"}}</h1>
          <p class="mg-fi__muted">Find a media item first, then run identify against an HLS playlist URL, an uploaded leak file, or use an overlay/session code match to fill the public_id.</p>
        </div>

        <div class="mg-fi__field is-full">
          <label>Search</label>
          <input
            class="admin-input"
            type="text"
            value={{@controller.searchQuery}}
            placeholder="Search by public_id / title / database row id / username / overlay or session code…"
            {{on "input" @controller.onSearchInput}}
            {{on "keydown" @controller.onSearchKeydown}}
          />
          <div class="mg-fi__helper">Search by title, public_id, uploader name, database row id, or an overlay/session code. Click <strong>Use</strong> to replace the selected public_id on the right.</div>
        </div>

        <div class="mg-fi__filters-grid">
          <div class="mg-fi__field">
            <label>Backend</label>
            <select value={{@controller.searchBackendFilter}} {{on "change" @controller.onSearchBackendFilterChange}}>
              <option value="all">All</option>
              <option value="local">Local</option>
              <option value="s3">S3</option>
            </select>
          </div>

          <div class="mg-fi__field">
            <label>Status</label>
            <select value={{@controller.searchStatusFilter}} {{on "change" @controller.onSearchStatusFilterChange}}>
              <option value="all">All</option>
              <option value="ready">Ready</option>
              <option value="processing">Processing</option>
              <option value="queued">Queued</option>
              <option value="failed">Failed</option>
            </select>
          </div>

          <div class="mg-fi__field">
            <label>Type</label>
            <select value={{@controller.searchTypeFilter}} {{on "change" @controller.onSearchTypeFilterChange}}>
              <option value="all">All</option>
              <option value="video">Video</option>
              <option value="audio">Audio</option>
              <option value="image">Image</option>
            </select>
          </div>

          <div class="mg-fi__field">
            <label>HLS</label>
            <select value={{@controller.searchHlsFilter}} {{on "change" @controller.onSearchHlsFilterChange}}>
              <option value="all">All</option>
              <option value="yes">HLS ready</option>
              <option value="no">No HLS</option>
            </select>
          </div>

          <div class="mg-fi__field">
            <label>Limit</label>
            <select value={{@controller.searchLimit}} {{on "change" @controller.onSearchLimitChange}}>
              <option value="20">20</option>
              <option value="50">50</option>
              <option value="100">100</option>
            </select>
          </div>

          <div class="mg-fi__field">
            <label>Sort</label>
            <select value={{@controller.searchSort}} {{on "change" @controller.onSearchSortChange}}>
              <option value="newest">Newest</option>
              <option value="oldest">Oldest</option>
              <option value="title_asc">Title A–Z</option>
              <option value="title_desc">Title Z–A</option>
            </select>
          </div>
        </div>

        <div class="mg-fi__filters-footer">
          <div class="mg-fi__actions">
            <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isSearching}}>
              {{if @controller.isSearching "Searching…" "Search"}}
            </button>
            <button class="btn" type="button" {{on "click" @controller.resetSearchFilters}} disabled={{@controller.isSearching}}>
              Recent items
            </button>
          </div>
          <span class="mg-fi__muted">{{@controller.searchResultsCount}} result(s)</span>
        </div>

        {{#if @controller.searchError}}
          <div class="mg-fi__notice is-danger mg-fi__search-status">{{@controller.searchError}}</div>
        {{/if}}
      </section>

      {{#if @controller.lookupCode}}
        <section class="mg-fi__panel">
          <div class="mg-fi__panel-header">
            <h2>Overlay / session code results</h2>
            <p class="mg-fi__muted">Search query <code>{{@controller.lookupCode}}</code> was also checked as an overlay/session code and any matching media is shown here.</p>
          </div>

          {{#if @controller.lookupBusy}}
            <div class="mg-fi__notice is-info">Searching overlay/session codes…</div>
          {{else if @controller.hasOverlaySearchMatches}}
            <div class="mg-fi__overlay-list">
              {{#each @controller.decoratedOverlayMatches key="media_public_id" as |match|}}
                <article class="mg-fi__overlay-card">
                  {{#if match.thumbnailUrl}}
                    <img class="mg-fi__thumb" loading="lazy" src={{match.thumbnailUrl}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-fi__thumb-placeholder">No thumbnail</div>
                  {{/if}}

                  <div class="mg-fi__overlay-copy">
                    <div class="mg-fi__overlay-title">{{match.displayTitle}}</div>
                    <div class="mg-fi__overlay-subtitle">{{match.media_public_id}}</div>
                    <div class="mg-fi__overlay-meta">{{match.displayMeta}}</div>
                  </div>

                  <button type="button" class="btn mg-fi__overlay-action" {{on "click" (fn @controller.pickPublicIdFromLookup match)}}>
                    Use media
                  </button>

                  <div class="mg-fi__overlay-badges">
                    <span class="mg-fi__badge is-success">Code {{match.displayCode}}</span>
                    <span class="mg-fi__badge">{{match.displayType}}</span>
                  </div>

                  <div class="mg-fi__overlay-info-grid">
                    <div class="mg-fi__overlay-info-card">
                      <div class="mg-fi__overlay-label">Uploader</div>
                      <div class="mg-fi__overlay-value">{{match.displayUploader}}</div>
                    </div>
                    <div class="mg-fi__overlay-info-card">
                      <div class="mg-fi__overlay-label">Fingerprint</div>
                      <div class="mg-fi__overlay-value">{{match.displayFingerprint}}</div>
                    </div>
                    <div class="mg-fi__overlay-info-card">
                      <div class="mg-fi__overlay-label">Seen at</div>
                      <div class="mg-fi__overlay-value">{{match.displaySeenAt}}</div>
                    </div>
                    <div class="mg-fi__overlay-info-card">
                      <div class="mg-fi__overlay-label">Matched code</div>
                      <div class="mg-fi__overlay-value">{{match.displayCode}}</div>
                    </div>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else if @controller.lookupError}}
            <div class="mg-fi__notice is-warning">{{@controller.lookupError}}</div>
          {{/if}}
        </section>
      {{/if}}

      <div class="mg-fi__grid">
        <section class="mg-fi__panel">
          <div class="mg-fi__panel-header">
            <h2>Results</h2>
            <p class="mg-fi__muted">Click ‘Use’ to fill the public_id in the identify form.</p>
          </div>

          {{#if @controller.isSearching}}
            <div class="mg-fi__notice is-info">Searching…</div>
          {{else if @controller.hasSearchResults}}
            <div class="mg-fi__results-list">
              {{#each @controller.decoratedSearchResults key="public_id" as |it|}}
                <article class="mg-fi__result-card">
                  {{#if it.thumbnail_url}}
                    <img class="mg-fi__thumb" loading="lazy" src={{it.thumbnail_url}} alt="thumbnail" />
                  {{else}}
                    <div class="mg-fi__thumb-placeholder">No thumbnail</div>
                  {{/if}}

                  <div class="mg-fi__result-copy">
                    <div class="mg-fi__result-title">{{it.displayTitle}}</div>
                    <div class="mg-fi__result-subtitle">{{it.public_id}}</div>
                    {{#if it.displayMeta}}
                      <div class="mg-fi__result-meta">{{it.displayMeta}}</div>
                    {{/if}}
                  </div>

                  <button type="button" class="btn mg-fi__result-action" {{on "click" (fn @controller.pickPublicId it)}}>
                    Use
                  </button>

                  <div class="mg-fi__result-badges">
                    <span class="mg-fi__badge {{it.statusBadgeClass}}">{{it.displayStatus}}</span>
                    <span class="mg-fi__badge">{{it.displayMediaType}}</span>
                    <span class="mg-fi__badge">{{it.displayStorage}}</span>
                    <span class="mg-fi__badge {{it.hlsBadgeClass}}">{{it.displayHls}}</span>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <div class="mg-fi__empty">No media matches yet. Search by title, public_id, uploader, database row id, or overlay/session code, or use “Recent items”.</div>
          {{/if}}
        </section>

        <aside class="mg-fi__sidebar-stack">
          <section class="mg-fi__panel">
            <div class="mg-fi__panel-header">
              <h2>Forensics identify</h2>
              <p class="mg-fi__muted">Use the selected public_id, then provide either a variant playlist URL or an uploaded leak file.</p>
            </div>

            {{#if @controller.error}}
              <div class="mg-fi__notice is-danger" style="margin-bottom: 1rem;">{{@controller.error}}</div>
            {{/if}}

            <div class="mg-fi__form-grid">
              <div class="mg-fi__field is-full">
                <label>{{i18n "admin.media_gallery.forensics_identify.public_id_label"}}</label>
                <input
                  class="admin-input"
                  type="text"
                  value={{@controller.publicId}}
                  placeholder={{i18n "admin.media_gallery.forensics_identify.public_id_placeholder"}}
                  {{on "input" @controller.onPublicIdInput}}
                />
                <div class="mg-fi__helper">Searching above does not replace this field until you click <strong>Use</strong> again.</div>
              </div>

              <div class="mg-fi__field is-full">
                <label>HLS / video URL (optional)</label>
                <input
                  class="admin-input"
                  type="text"
                  value={{@controller.sourceUrl}}
                  placeholder="Paste variant .m3u8 or direct mp4/ts URL"
                  {{on "input" @controller.onSourceUrlInput}}
                />
                <div class="mg-fi__helper">Recommended: paste the personalized variant playlist URL (.m3u8) from DevTools → Network. Direct mp4/ts URLs can also work. If you fill this field, uploading a file is optional. For safety, only URLs from this site are allowed.</div>
              </div>

              <div class="mg-fi__field is-full">
                <label>{{i18n "admin.media_gallery.forensics_identify.file_label"}}</label>
                <input type="file" {{on "change" @controller.onFileChange}} />
                <div class="mg-fi__helper">Upload a leaked mp4/ts/sample file when you do not have the original HLS playlist URL.</div>
              </div>

              <div class="mg-fi__field">
                <label>{{i18n "admin.media_gallery.forensics_identify.max_samples_label"}}</label>
                <input
                  class="admin-input"
                  type="number"
                  min="5"
                  max="200"
                  value={{@controller.maxSamples}}
                  {{on "input" @controller.onMaxSamplesInput}}
                />
              </div>

              <div class="mg-fi__field">
                <label>{{i18n "admin.media_gallery.forensics_identify.max_offset_label"}}</label>
                <input
                  class="admin-input"
                  type="number"
                  min="0"
                  max="300"
                  value={{@controller.maxOffsetSegments}}
                  {{on "input" @controller.onMaxOffsetInput}}
                />
              </div>

              <div class="mg-fi__field is-full">
                <label>{{i18n "admin.media_gallery.forensics_identify.layout_label"}}</label>
                <select class="combobox" value={{@controller.layout}} {{on "change" @controller.onLayoutChange}}>
                  <option value="">{{i18n "admin.media_gallery.forensics_identify.layout_auto"}}</option>
                  <option value="v1_tiles">{{i18n "admin.media_gallery.forensics_identify.layout_v1_tiles"}}</option>
                  <option value="v2_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v2_pairs"}}</option>
                  <option value="v3_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v3_pairs"}}</option>
                  <option value="v4_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v4_pairs"}}</option>
                  <option value="v5_screen_safe">{{i18n "admin.media_gallery.forensics_identify.layout_v5_screen_safe"}}</option>
                  <option value="v6_local_sync">{{i18n "admin.media_gallery.forensics_identify.layout_v6_local_sync"}}</option>
                  <option value="v7_high_separation">{{i18n "admin.media_gallery.forensics_identify.layout_v7_high_separation"}}</option>
                </select>
              </div>

              <div class="mg-fi__field is-full">
                <div class="mg-fi__checkbox-row">
                  <label>
                    <input type="checkbox" checked={{@controller.autoExtend}} {{on "change" @controller.onAutoExtendChange}} />
                    <span>Auto-extend</span>
                  </label>
                </div>
                <div class="mg-fi__helper">If the first result is weak or ambiguous, retry automatically with a longer sample. URL mode only.</div>
              </div>
            </div>

            <div class="mg-fi__actions" style="margin-top: 1rem;">
              <button type="button" class="btn btn-primary" disabled={{@controller.isRunning}} {{on "click" @controller.identify}}>
                {{if @controller.isRunning (i18n "admin.media_gallery.forensics_identify.running") (i18n "admin.media_gallery.forensics_identify.identify_button")}}
              </button>

              <button type="button" class="btn" disabled={{@controller.isRunning}} {{on "click" @controller.clear}}>
                Clear
              </button>
            </div>

            {{#if @controller.statusMessage}}
              <div class="mg-fi__notice is-info" style="margin-top: 1rem;">{{@controller.statusMessage}}</div>
            {{/if}}
          </section>

          <section class="mg-fi__panel">
            <div class="mg-fi__panel-header">
              <h2>Best test method</h2>
              <p class="mg-fi__muted">Use the top search for title, uploader, public_id, database row id, or overlay/session codes. Then run identify with either the original variant playlist or a leak file.</p>
            </div>
            <ol style="padding-left: 1.2rem; line-height: 1.5;">
              <li>Find the media item above and click <strong>Use</strong> to fill the public_id.</li>
              <li>For the strongest result, copy the personalized <strong>variant playlist</strong> URL (.m3u8) from DevTools → Network.</li>
              <li>For external leaks such as mp4 re-uploads, upload the leak file instead.</li>
            </ol>
          </section>

        </aside>
      </div>
      {{#if @controller.hasResult}}
        <section class="mg-fi__panel">
          <div class="mg-fi__panel-header">
            <h2>{{i18n "admin.media_gallery.forensics_identify.result"}}</h2>
            <p class="mg-fi__muted">Review the match confidence, policy decision, and candidate evidence.</p>
          </div>

          <div class="mg-fi__summary-grid">
            {{#each @controller.resultSummaryCards as |card|}}
              <div class={{if card.span2 "mg-fi__meta-card is-span-2" "mg-fi__meta-card"}}>
                <div class="mg-fi__metric-heading {{if card.tooltipAlignLeft "is-tooltip-left" ""}}">
                  <div class="mg-fi__meta-label">{{card.label}}</div>
                  {{#if card.help}}
                    <span class="mg-fi__metric-help" aria-label={{card.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{card.help}}</span>
                  {{/if}}
                </div>
                <div class={{if card.code "mg-fi__meta-value is-code" "mg-fi__meta-value"}}>{{card.value}}</div>
              </div>
            {{/each}}
          </div>

          <div class="mg-fi__notice {{@controller.confidenceClass}}">
            <strong>Summary</strong>
            <div class="mg-fi__meta-list">
              {{#if @controller.meta.user_message}}
                <div><strong>Note:</strong> {{@controller.meta.user_message}}</div>
              {{/if}}
              {{#if @controller.showShortlistEvidenceGap}}
                <div><strong>Shortlist gap:</strong> {{@controller.shortlistEvidenceGapDisplay}}</div>
              {{/if}}
              {{#if @controller.poolSize}}
                <div><strong>Pool size:</strong> {{@controller.poolSize}} <span class="mg-fi__muted">(reference {{@controller.referencePoolSize}})</span></div>
              {{/if}}
              {{#if @controller.syncPeriod}}
                <div><strong>Sync layer:</strong> period {{@controller.syncPeriod}} {{#if @controller.syncPairsCount}}<span class="mg-fi__muted">({{@controller.syncPairsCount}} safe-zone pairs)</span>{{/if}}</div>
              {{/if}}
              {{#if @controller.eccScheme}}
                <div><strong>ECC:</strong> {{@controller.eccScheme}} {{#if @controller.eccGroupsUsed}}<span class="mg-fi__muted">(groups {{@controller.eccGroupsUsed}}{{#if @controller.eccRawUsableSamples}}, raw usable {{@controller.eccRawUsableSamples}}{{/if}})</span>{{/if}}</div>
              {{/if}}
              {{#if @controller.phaseSearchUsed}}
                <div><strong>Phase:</strong> {{if @controller.chosenPhaseSeconds @controller.chosenPhaseSeconds "0.0"}}s {{#if @controller.denseStepSeconds}}<span class="mg-fi__muted">(dense step {{@controller.denseStepSeconds}}s)</span>{{/if}}</div>
              {{/if}}
              <div><strong>Offset expansion:</strong> {{if @controller.offsetExpansionApplied "applied" "not applied"}} {{#if @controller.offsetExpansionReason}}<span class="mg-fi__muted">({{@controller.offsetExpansionReason}})</span>{{/if}}</div>
              <div><strong>Phase refinement:</strong> {{#if @controller.phaseRefinementAttempted}}{{if @controller.phaseRefinementApplied "applied" "rejected"}}{{else}}not attempted{{/if}} {{#if @controller.phaseRefinementReason}}<span class="mg-fi__muted">({{@controller.phaseRefinementReason}})</span>{{/if}}</div>
              {{#if @controller.chunkedResyncUsed}}
                <div><strong>Chunked re-sync:</strong> {{@controller.chunkedResyncChunksUsed}} chunks {{#if @controller.chunkedResyncWindowSegments}}<span class="mg-fi__muted">(window {{@controller.chunkedResyncWindowSegments}} seg)</span>{{/if}}</div>
              {{else}}
                <div><strong>Chunked re-sync:</strong> not applied {{#if @controller.chunkedResyncReason}}<span class="mg-fi__muted">({{@controller.chunkedResyncReason}})</span>{{/if}}</div>
              {{/if}}
              <div><strong>Multisample refine:</strong> {{#if @controller.multisampleRefineUsed}}{{if @controller.multisampleRefineApplied "applied" "rejected"}}{{else}}not applied{{/if}} {{#if @controller.multisampleRefineReason}}<span class="mg-fi__muted">({{@controller.multisampleRefineReason}})</span>{{/if}}</div>
              <div><strong>Variant polarity:</strong> {{@controller.variantPolarity}} {{#if @controller.polarityFlipUsed}}<span class="mg-fi__muted">(A/B flipped{{#if @controller.polarityScoreDelta}}, score Δ {{@controller.polarityScoreDelta}}{{/if}})</span>{{/if}}</div>
              {{#if @controller.attempts}}
                <div><strong>Attempts:</strong> {{@controller.attempts}} {{#if @controller.autoExtended}}<span class="mg-fi__muted">(auto-extended)</span>{{/if}} {{#if @controller.maxSamplesUsed}}<span class="mg-fi__muted">(max {{@controller.maxSamplesUsed}})</span>{{/if}}</div>
              {{/if}}
              {{#if @controller.configuredFilemodeSoftBudgetSeconds}}
                <div><strong>File-mode budgets:</strong> soft {{@controller.configuredFilemodeSoftBudgetSeconds}}s {{#if @controller.configuredFilemodeEngineBudgetSeconds}}<span class="mg-fi__muted">/ engine {{@controller.configuredFilemodeEngineBudgetSeconds}}s</span>{{/if}}</div>
              {{/if}}
              {{#if @controller.timeoutKind}}
                <div><strong>Timeout kind:</strong> {{@controller.timeoutKind}} {{#if @controller.likelyTimeoutLayer}}<span class="mg-fi__muted">({{@controller.likelyTimeoutLayer}})</span>{{/if}}</div>
              {{/if}}
            </div>
          </div>

                    {{#if @controller.topCandidate}}
            <div class="mg-fi__result-section">
              <h3 class="mg-fi__section-title">Top candidate</h3>
              <div class="mg-fi__candidate-summary-grid">
                {{#each @controller.topCandidateSummaryCards as |card|}}
                  <div class={{if card.span2 "mg-fi__meta-card is-span-2" "mg-fi__meta-card"}}>
                    <div class="mg-fi__metric-heading {{if card.tooltipAlignLeft "is-tooltip-left" ""}}">
                      <div class="mg-fi__meta-label">{{card.label}}</div>
                      {{#if card.help}}
                        <span class="mg-fi__metric-help" aria-label={{card.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{card.help}}</span>
                      {{/if}}
                    </div>
                    <div class={{if card.code "mg-fi__meta-value is-code" "mg-fi__meta-value"}}>{{card.value}}</div>
                  </div>
                {{/each}}
              </div>

              <div class="mg-fi__candidate-note-card">
                <div class="mg-fi__metric-heading">
                  <strong>Top candidate rationale</strong>
                </div>
                {{#if @controller.topCandidateRationaleMetrics.length}}
                  <div class="mg-fi__candidate-note-grid">
                    {{#each @controller.topCandidateRationaleMetrics as |metric|}}
                      <div class="mg-fi__candidate-detail-card">
                        <div class="mg-fi__metric-heading">
                          <div class="mg-fi__candidate-detail-label">{{metric.label}}</div>
                          {{#if metric.help}}
                            <span class="mg-fi__metric-help" aria-label={{metric.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{metric.help}}</span>
                          {{/if}}
                        </div>
                        <div class="mg-fi__candidate-detail-value">{{metric.value}}</div>
                      </div>
                    {{/each}}
                  </div>
                {{/if}}
                <div class="mg-fi__candidate-score-grid">
                  {{#each @controller.topCandidateScoringMetrics as |metric|}}
                    <div class="mg-fi__candidate-detail-card">
                      <div class="mg-fi__metric-heading {{if metric.tooltipAlignLeft "is-tooltip-left" ""}}">
                        <div class="mg-fi__candidate-detail-label">{{metric.label}}</div>
                        {{#if metric.help}}
                          <span class="mg-fi__metric-help" aria-label={{metric.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{metric.help}}</span>
                        {{/if}}
                      </div>
                      <div class="mg-fi__candidate-detail-value">{{metric.value}}</div>
                    </div>
                  {{/each}}
                </div>
                {{#if @controller.topCandidateScoringNote}}
                  <div class="mg-fi__muted" style="margin-top: 0.75rem;">{{@controller.topCandidateScoringNote}}</div>
                {{/if}}
                {{#if @controller.statisticalConfidenceNote}}
                  <div class="mg-fi__muted" style="margin-top: 0.5rem;">{{@controller.statisticalConfidenceNote}}</div>
                {{/if}}
              </div>
            </div>
          {{/if}}

{{#if @controller.showWeakTip}}
            <div class="mg-fi__notice is-warning" style="margin-top: 1rem;">
              <strong>Tip:</strong>
              Matching is weakest when the leak is short, heavily re-encoded, cropped, or includes overlays. If possible, use a longer sample that is closer to the original HLS stream. URL mode + auto-extend helps, but confidence still depends on usable samples.
              {{#if @controller.decisionReasons.length}}
                <div style="margin-top: 0.35rem;"><strong>Policy why:</strong> {{@controller.decisionReasonsText}}</div>
              {{/if}}
              {{#if @controller.recommendation}}
                <div style="margin-top: 0.35rem;"><strong>Recommendation:</strong> {{@controller.recommendation}}</div>
              {{/if}}
            </div>
          {{/if}}

          {{#if @controller.isAmbiguous}}
            <div class="mg-fi__notice is-warning" style="margin-top: 1rem;">
              <strong>Note:</strong> The top two candidates are close. Treat this as ambiguous and gather a longer sample.
            </div>
          {{/if}}

          {{#if @controller.hasAlignmentDebug}}
            <details class="mg-fi__details" style="margin-top: 1rem;">
              <summary>Alignment debug</summary>
              <div style="margin-top: 0.75rem;">
                <strong>Observed variants</strong>
                <code class="mg-fi__code-block">{{@controller.observedVariants}}</code>

                {{#if @controller.expectedVariantsTopCandidate}}
                  <div style="margin-top: 0.75rem;">
                    <strong>Expected top candidate</strong>
                    <code class="mg-fi__code-block">{{@controller.expectedVariantsTopCandidate}}</code>
                  </div>
                {{/if}}

                {{#if @controller.referenceSegmentIndicesText}}
                  <div style="margin-top: 0.75rem;">
                    <strong>Reference segment indices</strong>
                    <code class="mg-fi__code-block">{{@controller.referenceSegmentIndicesText}}</code>
                  </div>
                {{/if}}

                {{#if @controller.mismatchPositions.length}}
                  <div style="margin-top: 0.75rem;">
                    <strong>Mismatch positions</strong>
                    <code class="mg-fi__code-block">{{@controller.mismatchPositionsText}}</code>
                  </div>
                {{/if}}
              </div>
            </details>
          {{/if}}

          {{#if @controller.candidates.length}}
            <div class="mg-fi__result-section">
              {{#unless @controller.conclusive}}
                <div class="mg-fi__notice is-warning" style="margin-bottom: 1rem;">
                  Do not treat this as definitive. Gather a longer sample to increase usable_samples and separation from #2.
                </div>
              {{/unless}}

              <details class="mg-fi__details" open={{@controller.conclusive}}>
                <summary>{{if @controller.conclusive "Top candidates" "Candidates (not conclusive)"}}</summary>
                <div class="mg-fi__candidate-list">
                  <div class="mg-fi__candidate-header-row">
                    <div></div>
                    <div>User</div>
                    <div>Fingerprint</div>
                    <div>Match</div>
                    <div>Mis / Comp</div>
                    <div>Best offset</div>
                    <div>Δ vs #1</div>
                  </div>

                  {{#each @controller.topCandidates as |c|}}
                    <details class="mg-fi__candidate-item" open={{c.isPrimary}}>
                      <summary class="mg-fi__candidate-toggle">
                        <div class="mg-fi__candidate-toggle-inner">
                          <div class="mg-fi__candidate-chevron"></div>
                          <div class="mg-fi__candidate-user">{{c.displayUser}}</div>
                          <div class="mg-fi__candidate-fingerprint"><code>{{c.displayFingerprint}}</code></div>
                          <div>{{c.displayMatch}}</div>
                          <div>{{c.displayMisComp}}</div>
                          <div>{{c.displayBestOffset}}</div>
                          <div>{{c.displayDeltaFromTop}}</div>
                        </div>
                      </summary>

                      <div class="mg-fi__candidate-body">
                        {{#if c.hasRationaleMetrics}}
                          <div class="mg-fi__candidate-subsection-title">Rationale</div>
                          <div class="mg-fi__candidate-rationale-grid">
                            {{#each c.rationaleMetrics as |metric|}}
                              <div class="mg-fi__candidate-detail-card">
                                <div class="mg-fi__metric-heading">
                                  <div class="mg-fi__candidate-detail-label">{{metric.label}}</div>
                                  {{#if metric.help}}
                                    <span class="mg-fi__metric-help" aria-label={{metric.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{metric.help}}</span>
                                  {{/if}}
                                </div>
                                <div class="mg-fi__candidate-detail-value">{{metric.value}}</div>
                              </div>
                            {{/each}}
                          </div>
                        {{/if}}

                        <div class="mg-fi__candidate-subsection-title" style={{if c.hasRationaleMetrics "margin-top: 0.85rem;" ""}}>Supporting statistics</div>
                        <div class="mg-fi__candidate-detail-grid">
                          {{#each c.statsMetrics as |metric|}}
                            <div class="mg-fi__candidate-detail-card">
                              <div class="mg-fi__metric-heading">
                                <div class="mg-fi__candidate-detail-label">{{metric.label}}</div>
                                {{#if metric.help}}
                                  <span class="mg-fi__metric-help" aria-label={{metric.help}} tabindex="0">i</span><span class="mg-fi__metric-tooltip">{{metric.help}}</span>
                                {{/if}}
                              </div>
                              <div class="mg-fi__candidate-detail-value">{{metric.value}}</div>
                            </div>
                          {{/each}}
                        </div>
                      </div>
                    </details>
                  {{/each}}
                </div>
              </details>

              {{#if @controller.hasMoreCandidates}}
                <details class="mg-fi__details">
                  <summary>Show all candidates ({{@controller.candidates.length}})</summary>
                  <pre class="mg-fi__code-block">{{@controller.resultJson}}</pre>
                </details>
              {{/if}}
            </div>
          {{else}}
            <div class="mg-fi__empty" style="margin-top: 1rem;">
              <em>No candidates matched the observed pattern.</em>
            </div>
          {{/if}}

          <details class="mg-fi__details">
            <summary>Raw JSON</summary>
            <pre class="mg-fi__code-block">{{@controller.resultJson}}</pre>
          </details>
        </section>
      {{/if}}
    </div>
  </template>
);
