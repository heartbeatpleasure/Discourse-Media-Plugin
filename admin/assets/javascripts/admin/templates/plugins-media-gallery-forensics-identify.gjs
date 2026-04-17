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

      .mg-fi__grid,
      .mg-fi__fields,
      .mg-fi__search-results,
      .mg-fi__summary-grid,
      .mg-fi__meta-list {
        display: grid;
        gap: 1rem;
      }

      .mg-fi__grid {
        grid-template-columns: minmax(0, 1.15fr) minmax(320px, 0.85fr);
        align-items: start;
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
      .mg-fi__result-id,
      .mg-fi__result-meta,
      .mg-fi__search-footer,
      .mg-fi__empty {
        color: var(--mg-fi-muted);
        font-size: var(--font-down-1);
      }

      .mg-fi__fields {
        grid-template-columns: repeat(2, minmax(0, 1fr));
        align-items: end;
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

      .mg-fi__checkbox-row,
      .mg-fi__actions,
      .mg-fi__lookup-actions,
      .mg-fi__result-tags {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.75rem;
      }

      .mg-fi__checkbox-row {
        min-height: 42px;
        border: 1px solid var(--mg-fi-border);
        border-radius: 12px;
        background: var(--primary-very-low);
        padding: 0.65rem 0.85rem;
      }

      .mg-fi__checkbox-row input {
        margin: 0;
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

      .mg-fi__search-results {
        margin-top: 1rem;
      }

      .mg-fi__search-card {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.75rem 1rem;
        align-items: start;
        border: 1px solid var(--mg-fi-border);
        border-radius: 16px;
        background: var(--mg-fi-surface-alt);
        padding: 0.9rem;
      }

      .mg-fi__search-title {
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .mg-fi__result-id code,
      .mg-fi__table-wrap code,
      .mg-fi__code-block code {
        white-space: pre-wrap;
        word-break: break-word;
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
        .mg-fi__fields,
        .mg-fi__summary-grid,
        .mg-fi__meta-list {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 640px) {
        .mg-fi__fields,
        .mg-fi__summary-grid,
        .mg-fi__meta-list,
        .mg-fi__search-card {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-forensics-identify">
      <div class="mg-fi__grid">
        <section class="mg-fi__panel">
          <div class="mg-fi__panel-header">
            <h1>{{i18n "admin.media_gallery.forensics_identify.title"}}</h1>
            <p class="mg-fi__muted">{{i18n "admin.media_gallery.forensics_identify.description"}}</p>
          </div>

          {{#if @controller.error}}
            <div class="mg-fi__notice is-danger" style="margin-bottom: 1rem;">{{@controller.error}}</div>
          {{/if}}

          <div class="mg-fi__fields">
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
              <label>{{i18n "admin.media_gallery.forensics_identify.source_url_label"}}</label>
              <input
                class="admin-input"
                type="text"
                value={{@controller.sourceUrl}}
                placeholder={{i18n "admin.media_gallery.forensics_identify.source_url_placeholder"}}
                {{on "input" @controller.onSourceUrlInput}}
              />
              <div class="mg-fi__helper">{{i18n "admin.media_gallery.forensics_identify.source_url_help"}}</div>
            </div>

            <div class="mg-fi__field is-full">
              <label>{{i18n "admin.media_gallery.forensics_identify.file_label"}}</label>
              <input type="file" {{on "change" @controller.onFileChange}} />
              <div class="mg-fi__helper">{{i18n "admin.media_gallery.forensics_identify.file_help"}}</div>
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
              <label>{{i18n "admin.media_gallery.forensics_identify.auto_extend_label"}}</label>
              <label class="mg-fi__checkbox-row">
                <input
                  type="checkbox"
                  checked={{@controller.autoExtend}}
                  {{on "change" @controller.onAutoExtendChange}}
                />
                <span>{{i18n "admin.media_gallery.forensics_identify.auto_extend_help"}}</span>
              </label>
            </div>
          </div>

          <h3 class="mg-fi__section-title">Overlay/session code lookup</h3>
          <div class="mg-fi__lookup-actions">
            <input
              class="admin-input"
              type="text"
              value={{@controller.lookupCode}}
              placeholder="e.g. 7KQ2AB"
              maxlength="12"
              {{on "input" @controller.onLookupCodeInput}}
              style="max-width: 220px;"
            />
            <button
              type="button"
              class="btn"
              disabled={{@controller.lookupBusy}}
              {{on "click" @controller.lookupOverlayCode}}
            >
              {{if @controller.lookupBusy "Searching…" "Lookup code"}}
            </button>
            <button
              type="button"
              class="btn"
              disabled={{@controller.lookupBusy}}
              {{on "click" @controller.clearLookup}}
            >
              Clear lookup
            </button>
          </div>
          <div class="mg-fi__helper" style="margin-top: 0.45rem;">
            Searches the frontend playback overlay/session code. If a public_id is filled in above, the lookup is narrowed to that media item.
          </div>

          {{#if @controller.lookupError}}
            <div class="mg-fi__notice is-warning" style="margin-top: 0.75rem;">{{@controller.lookupError}}</div>
          {{/if}}

          {{#if @controller.hasLookupMatches}}
            <div class="mg-fi__table-wrap" style="margin-top: 0.9rem;">
              <table class="table">
                <thead>
                  <tr>
                    <th>Code</th>
                    <th>User</th>
                    <th>Media</th>
                    <th>Type</th>
                    <th>Fingerprint</th>
                    <th>Seen</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each @controller.lookupMatches as |match|}}
                    <tr>
                      <td><code>{{match.overlay_code}}</code></td>
                      <td>
                        {{#if match.name}}
                          {{match.name}} ·
                        {{/if}}
                        {{match.username}}
                        {{#if match.user_id}}
                          <div class="mg-fi__muted">ID {{match.user_id}}</div>
                        {{/if}}
                      </td>
                      <td>
                        {{match.media_public_id}}
                        {{#if match.media_title}}
                          <div class="mg-fi__muted">{{match.media_title}}</div>
                        {{/if}}
                      </td>
                      <td>{{match.media_type}}</td>
                      <td>{{if match.fingerprint_id match.fingerprint_id "—"}}</td>
                      <td>
                        {{if match.updated_at match.updated_at match.created_at}}
                        {{#if match.rendered_text}}
                          <div class="mg-fi__muted">{{match.rendered_text}}</div>
                        {{/if}}
                      </td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          {{/if}}

          <div class="mg-fi__actions" style="margin-top: 1rem;">
            <button
              type="button"
              class="btn btn-primary"
              disabled={{@controller.isRunning}}
              {{on "click" @controller.identify}}
            >
              {{if @controller.isRunning (i18n "admin.media_gallery.forensics_identify.running") (i18n "admin.media_gallery.forensics_identify.identify_button")}}
            </button>

            <button
              type="button"
              class="btn"
              disabled={{@controller.isRunning}}
              {{on "click" @controller.clear}}
            >
              Clear
            </button>
          </div>

          {{#if @controller.statusMessage}}
            <div class="mg-fi__notice is-info" style="margin-top: 1rem;">{{@controller.statusMessage}}</div>
          {{/if}}
        </section>

        <aside class="mg-fi__panel">
          <div class="mg-fi__panel-header">
            <h2>{{i18n "admin.media_gallery.forensics_identify.find_media_title"}}</h2>
            <p class="mg-fi__muted">{{i18n "admin.media_gallery.forensics_identify.find_media_help"}}</p>
          </div>

          <div class="mg-fi__field is-full">
            <label>Search</label>
            <input
              class="admin-input"
              type="text"
              value={{@controller.searchQuery}}
              placeholder={{i18n "admin.media_gallery.forensics_identify.find_media_placeholder"}}
              {{on "input" @controller.onSearchInput}}
            />
          </div>

          {{#if @controller.searchError}}
            <div class="mg-fi__notice is-danger" style="margin-top: 0.75rem;">{{@controller.searchError}}</div>
          {{/if}}

          {{#if @controller.isSearching}}
            <div class="mg-fi__notice is-info" style="margin-top: 0.75rem;">Searching…</div>
          {{/if}}

          {{#if @controller.searchResults.length}}
            <div class="mg-fi__search-results">
              {{#each @controller.searchResults key="public_id" as |it|}}
                <article class="mg-fi__search-card">
                  <div>
                    <div class="mg-fi__search-title">{{it.title}}</div>
                    <div class="mg-fi__result-id"><code>{{it.public_id}}</code></div>
                    <div class="mg-fi__result-meta">
                      #{{it.id}}
                      {{#if it.username}}
                        · by {{it.username}}
                      {{/if}}
                    </div>
                  </div>
                  <button
                    type="button"
                    class="btn"
                    {{on "click" (fn @controller.pickPublicId it)}}
                  >
                    Use
                  </button>
                </article>
              {{/each}}
            </div>
          {{else if @controller.showNoSearchMatches}}
            <div class="mg-fi__empty" style="margin-top: 0.75rem;">No matches.</div>
          {{/if}}

          <div class="mg-fi__prose-card" style="margin-top: 1rem;">
            <h3>Best test method</h3>
            <ol style="margin-top: 0.75rem; padding-left: 1.2rem;">
              <li>Log in as a normal test user and play the video so you definitely get a personalized stream.</li>
              <li>Open DevTools → Network and find the <strong>variant playlist</strong> URL (.m3u8).</li>
              <li>Paste that URL into the field on the left. No manual download is needed.</li>
            </ol>
            <p class="mg-fi__muted" style="margin-top: 0.75rem;">
              URL mode is restricted to your own site for safety. For external leaks such as mp4 re-uploads, upload the file instead.
            </p>
          </div>
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
