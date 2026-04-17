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
        overflow: hidden;
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

      .mg-fi__toggle-card {
        min-height: 48px;
        border: 1px solid var(--mg-fi-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0.45rem 0.85rem;
        display: flex;
        align-items: center;
      }

      .mg-fi__toggle-row {
        width: 100%;
        align-items: center;
        min-height: 30px;
        gap: 0.65rem;
      }

      .mg-fi__toggle-row input {
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
        margin: 1rem 0 0.65rem;
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
        margin-bottom: 1rem;
      }

      .mg-fi__meta-card {
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 0.9rem 1rem;
      }

      .mg-fi__meta-label {
        font-weight: 600;
        margin-bottom: 0.15rem;
      }

      .mg-fi__meta-value {
        font-size: 1.1rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-fi__overlay-list {
        display: flex;
        flex-direction: column;
        gap: 0.9rem;
      }

      .mg-fi__overlay-card {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.85rem 1rem;
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

      .mg-fi__overlay-badges {
        grid-column: 1 / -1;
        display: flex;
        flex-wrap: wrap;
        gap: 0.65rem;
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
        .mg-fi__form-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 640px) {
        .mg-fi__filters-grid,
        .mg-fi__summary-grid,
        .mg-fi__meta-list,
        .mg-fi__form-grid,
        .mg-fi__result-card {
          grid-template-columns: 1fr;
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
          <p class="mg-fi__muted">Find a media item first, then run identify against an HLS playlist URL or an uploaded leak file.</p>
        </div>

        <div class="mg-fi__field is-full">
          <label>Search</label>
          <input
            class="admin-input"
            type="text"
            value={{@controller.searchQuery}}
            placeholder={{i18n "admin.media_gallery.forensics_identify.find_media_placeholder"}}
            {{on "input" @controller.onSearchInput}}
            {{on "keydown" @controller.onSearchKeydown}}
          />
          <div class="mg-fi__helper">Search by title, public_id, uploader name, internal numeric id, or an overlay/session code. <strong>public_id</strong> is the stable media identifier used in URLs; <strong>id</strong> is the internal database row id.</div>
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
            <p class="mg-fi__muted">Search query <code>{{@controller.lookupCode}}</code> was also checked as an overlay/session code.</p>
          </div>

          {{#if @controller.lookupBusy}}
            <div class="mg-fi__notice is-info">Searching overlay/session codes…</div>
          {{else if @controller.hasOverlaySearchMatches}}
            <div class="mg-fi__overlay-list">
              {{#each @controller.decoratedOverlayMatches key="media_public_id" as |match|}}
                <article class="mg-fi__overlay-card">
                  <div class="mg-fi__overlay-copy">
                    <div class="mg-fi__overlay-title">{{match.displayTitle}}</div>
                    <div class="mg-fi__overlay-subtitle">{{match.media_public_id}}</div>
                    <div class="mg-fi__overlay-meta">{{match.displayMeta}}</div>
                  </div>

                  <button type="button" class="btn" {{on "click" (fn @controller.pickPublicIdFromLookup match)}}>
                    Use media
                  </button>

                  <div class="mg-fi__overlay-badges">
                    <span class="mg-fi__badge is-success">Code {{match.displayCode}}</span>
                    <span class="mg-fi__badge">{{match.displayType}}</span>
                    <span class="mg-fi__badge">Fingerprint {{match.displayFingerprint}}</span>
                    <span class="mg-fi__badge">Seen {{match.displaySeen}}</span>
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
            <div class="mg-fi__empty">No media matches yet. Search by title, public_id, uploader, internal id, or use “Recent items”.</div>
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
              </div>

              <div class="mg-fi__field is-full">
                <label>HLS / video URL (optional)</label>
                <input
                  class="admin-input"
                  type="text"
                  value={{@controller.sourceUrl}}
                  placeholder="Paste a .m3u8 variant playlist or direct mp4/ts URL"
                  {{on "input" @controller.onSourceUrlInput}}
                />
                <div class="mg-fi__helper">Recommended: paste the variant playlist URL from DevTools → Network. If you fill this field, uploading a file is optional. For safety, only URLs from this site are allowed.</div>
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

              <div class="mg-fi__field">
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
                <div class="mg-fi__toggle-card">
                  <label class="mg-fi__toggle-row">
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
              <p class="mg-fi__muted">Use the top search for title, uploader, media ids, or overlay/session codes. Then run identify with either the original variant playlist or a leak file.</p>
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
            <div class="mg-fi__meta-card">
              <div class="mg-fi__meta-label">Decision</div>
              <div class="mg-fi__meta-value">{{if @controller.decisionText @controller.decisionText "Pending"}}</div>
            </div>
            <div class="mg-fi__meta-card">
              <div class="mg-fi__meta-label">Confidence</div>
              <div class="mg-fi__meta-value">{{@controller.confidence}}</div>
            </div>
            <div class="mg-fi__meta-card">
              <div class="mg-fi__meta-label">Samples</div>
              <div class="mg-fi__meta-value">{{@controller.samples}}</div>
            </div>
            <div class="mg-fi__meta-card">
              <div class="mg-fi__meta-label">Usable samples</div>
              <div class="mg-fi__meta-value">{{@controller.usableSamples}}</div>
            </div>
            {{#if @controller.candidates.length}}
              <div class="mg-fi__meta-card">
                <div class="mg-fi__meta-label">Top match</div>
                <div class="mg-fi__meta-value">{{@controller.topMatchRatio}}</div>
              </div>
            {{/if}}
            {{#if @controller.matchDelta}}
              <div class="mg-fi__meta-card">
                <div class="mg-fi__meta-label">Δ vs #2</div>
                <div class="mg-fi__meta-value">{{@controller.matchDelta}}</div>
              </div>
            {{/if}}
            {{#if @controller.meta.layout}}
              <div class="mg-fi__meta-card">
                <div class="mg-fi__meta-label">Layout</div>
                <div class="mg-fi__meta-value">{{@controller.meta.layout}}</div>
              </div>
            {{/if}}
            {{#if @controller.meta.duration_seconds}}
              <div class="mg-fi__meta-card">
                <div class="mg-fi__meta-label">Duration seconds</div>
                <div class="mg-fi__meta-value">{{@controller.meta.duration_seconds}}</div>
              </div>
            {{/if}}
          </div>

          <div class="mg-fi__notice {{@controller.confidenceClass}}">
            <strong>Summary</strong>
            <div class="mg-fi__meta-list">
              {{#if @controller.meta.user_message}}
                <div><strong>Note:</strong> {{@controller.meta.user_message}}</div>
              {{/if}}
              {{#if @controller.shortlistEvidenceGap}}
                <div><strong>Shortlist gap:</strong> {{@controller.shortlistEvidenceGap}}</div>
              {{/if}}
              {{#if @controller.topCandidateWhy}}
                <div><strong>Top evidence:</strong> {{@controller.topCandidateWhy}}</div>
              {{/if}}
              {{#if @controller.poolSize}}
                <div><strong>Pool size:</strong> {{@controller.poolSize}} <span class="mg-fi__muted">(reference {{@controller.referencePoolSize}})</span></div>
              {{/if}}
              {{#if @controller.topSignalZ}}
                <div><strong>Signal Z:</strong> {{@controller.topSignalZ}} {{#if @controller.topPValue}}<span class="mg-fi__muted">(p≈{{@controller.topPValue}})</span>{{/if}}</div>
              {{/if}}
              {{#if @controller.topExpectedFalsePositivesPool}}
                <div><strong>E[false positives]:</strong> {{@controller.topExpectedFalsePositivesPool}} <span class="mg-fi__muted">(pool / {{@controller.topExpectedFalsePositives2000}} at {{@controller.referencePoolSize}})</span></div>
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
            <h3 class="mg-fi__section-title">{{if @controller.conclusive "Top candidates" "Candidates (not conclusive)"}}</h3>
            {{#unless @controller.conclusive}}
              <div class="mg-fi__notice is-warning" style="margin-bottom: 1rem;">
                Do not treat this as definitive. Gather a longer sample to increase usable_samples and separation from #2.
              </div>
            {{/unless}}

            <details class="mg-fi__details" open={{@controller.conclusive}}>
              <summary>Show candidates</summary>
              <div class="mg-fi__table-wrap" style="margin-top: 0.75rem;">
                <table class="table">
                  <thead>
                    <tr>
                      <th>User</th>
                      <th>Fingerprint</th>
                      <th>Match</th>
                      <th>Z</th>
                      <th>p</th>
                      <th>E[FP] pool</th>
                      <th>E[FP] 2000</th>
                      <th>Δ vs #1</th>
                      <th>Evidence</th>
                      <th>Mismatches</th>
                      <th>Best offset</th>
                    </tr>
                  </thead>
                  <tbody>
                    {{#each @controller.topCandidates as |c|}}
                      <tr>
                        <td>{{#if c.username}}{{c.username}} (#{{c.user_id}}){{else}}#{{c.user_id}}{{/if}}</td>
                        <td><code>{{c.fingerprint_id}}</code></td>
                        <td>{{c.match_ratio}}</td>
                        <td>{{c.signal_z}}</td>
                        <td>{{c.p_value}}</td>
                        <td>{{c.expected_false_positives_pool}}</td>
                        <td>{{c.expected_false_positives_2000}}</td>
                        <td>{{c.delta_from_top}}</td>
                        <td>
                          {{c.evidence_score}}
                          {{#if c.why}}
                            <div class="mg-fi__muted" style="max-width:18rem;">{{c.why}}</div>
                          {{/if}}
                        </td>
                        <td>{{c.mismatches}} / {{c.compared}}</td>
                        <td>{{c.best_offset_segments}}</td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </div>
            </details>

            {{#if @controller.hasMoreCandidates}}
              <details class="mg-fi__details">
                <summary>Show all candidates ({{@controller.candidates.length}})</summary>
                <pre class="mg-fi__code-block">{{@controller.resultJson}}</pre>
              </details>
            {{/if}}
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
