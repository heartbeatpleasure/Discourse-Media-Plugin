import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-forensics-identify">
      <h1>{{i18n "admin.media_gallery.forensics_identify.title"}}</h1>

      <p>{{i18n "admin.media_gallery.forensics_identify.description"}}</p>

      <div style="display:flex; gap:2rem; flex-wrap:wrap; align-items:flex-start;">
        <div style="flex: 1 1 520px; min-width: 320px;">
          {{#if @controller.error}}
            <div class="alert alert-error" style="margin-bottom: 1rem;">{{@controller.error}}</div>
          {{/if}}

          <div class="form">
            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.public_id_label"}}
              </label>
              <div class="controls">
                <input
                  type="text"
                  value={{@controller.publicId}}
                  placeholder={{i18n "admin.media_gallery.forensics_identify.public_id_placeholder"}}
                  {{on "input" @controller.onPublicIdInput}}
                />
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.source_url_label"}}
              </label>
              <div class="controls">
                <input
                  type="text"
                  value={{@controller.sourceUrl}}
                  placeholder={{i18n "admin.media_gallery.forensics_identify.source_url_placeholder"}}
                  {{on "input" @controller.onSourceUrlInput}}
                />
                <div style="opacity:0.8; margin-top: 0.35rem;">
                  {{i18n "admin.media_gallery.forensics_identify.source_url_help"}}
                </div>
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.file_label"}}
              </label>
              <div class="controls">
                <input type="file" {{on "change" @controller.onFileChange}} />
                <div style="opacity:0.8; margin-top: 0.35rem;">
                  {{i18n "admin.media_gallery.forensics_identify.file_help"}}
                </div>
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.max_samples_label"}}
              </label>
              <div class="controls">
                <input
                  type="number"
                  min="5"
                  max="200"
                  value={{@controller.maxSamples}}
                  {{on "input" @controller.onMaxSamplesInput}}
                />
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.max_offset_label"}}
              </label>
              <div class="controls">
                <input
                  type="number"
                  min="0"
                  max="300"
                  value={{@controller.maxOffsetSegments}}
                  {{on "input" @controller.onMaxOffsetInput}}
                />
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.layout_label"}}
              </label>
              <div class="controls">
                <select value={{@controller.layout}} {{on "change" @controller.onLayoutChange}}>
                  <option value="">{{i18n "admin.media_gallery.forensics_identify.layout_auto"}}</option>
                  <option value="v1_tiles">{{i18n "admin.media_gallery.forensics_identify.layout_v1_tiles"}}</option>
                  <option value="v2_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v2_pairs"}}</option>
                </select>
              </div>
            </div>

            <div class="control-group">
              <label class="control-label">
                {{i18n "admin.media_gallery.forensics_identify.auto_extend_label"}}
              </label>
              <div class="controls">
                <label style="display:flex; gap:0.5rem; align-items:center;">
                  <input
                    type="checkbox"
                    checked={{@controller.autoExtend}}
                    {{on "change" @controller.onAutoExtendChange}}
                  />
                  <span style="opacity:0.9;">
                    {{i18n "admin.media_gallery.forensics_identify.auto_extend_help"}}
                  </span>
                </label>
              </div>
            </div>

            <div class="control-group">
              <div class="controls">
                <button
                  type="button"
                  class="btn btn-primary"
                  disabled={{@controller.isRunning}}
                  {{on "click" @controller.identify}}
                >
                  {{#if @controller.isRunning}}
                    {{i18n "admin.media_gallery.forensics_identify.running"}}
                  {{else}}
                    {{i18n "admin.media_gallery.forensics_identify.identify_button"}}
                  {{/if}}
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
            </div>
          </div>

          {{#if @controller.hasResult}}
            <h2 style="margin-top: 2rem;">{{i18n "admin.media_gallery.forensics_identify.result"}}</h2>

            <div class="alert {{@controller.confidenceClass}}" style="margin-top: 0.75rem;">
              <strong>Summary</strong>
              <div style="margin-top: 0.5rem;">
                <div><strong>samples:</strong> {{@controller.samples}}</div>
                <div><strong>usable_samples:</strong> {{@controller.usableSamples}}</div>
                <div><strong>confidence:</strong> {{@controller.confidence}}</div>
                {{#if @controller.candidates.length}}
                  <div>
                    <strong>top_match:</strong> {{@controller.topMatchRatio}}
                    <span style="opacity:0.85;">(Δ vs #2: {{@controller.matchDelta}})</span>
                  </div>
                {{/if}}
                {{#if @controller.meta.duration_seconds}}
                  <div><strong>duration_seconds:</strong> {{@controller.meta.duration_seconds}}</div>
                {{/if}}
                {{#if @controller.meta.layout}}
                  <div><strong>layout:</strong> {{@controller.meta.layout}}</div>
                {{/if}}

                {{#if @controller.attempts}}
                  <div>
                    <strong>attempts:</strong> {{@controller.attempts}}
                    {{#if @controller.autoExtended}}
                      <span style="opacity:0.85;">(auto-extended)</span>
                    {{/if}}
                    {{#if @controller.maxSamplesUsed}}
                      <span style="opacity:0.85;">(max_samples_used: {{@controller.maxSamplesUsed}})</span>
                    {{/if}}
                  </div>
                {{/if}}
              </div>

              {{#if @controller.showWeakTip}}
                <div style="margin-top: 0.75rem;">
                  <strong>Tip:</strong>
                  Matching is weakest when the leak is short, heavily re-encoded, cropped, or includes overlays.
                  If possible, use a longer sample that is closer to the original HLS stream.
                  URL mode + auto-extend helps, but confidence still depends on usable samples.
                </div>
              {{/if}}

              {{#if @controller.isAmbiguous}}
                <div style="margin-top: 0.75rem;">
                  <strong>Note:</strong>
                  The top two candidates are close. Treat this as ambiguous and gather a longer sample.
                </div>
              {{/if}}
            </div>

            {{#if @controller.observedVariants}}
              <div style="margin-top: 1rem;">
                <strong>Observed variants:</strong>
                <code style="display:block; white-space: pre-wrap; word-break: break-word; margin-top: 0.35rem;">
                  {{@controller.observedVariants}}
                </code>
              </div>
            {{/if}}

            {{#if @controller.candidates.length}}
              <h3 style="margin-top: 1.5rem;">Top candidates</h3>
              <table class="table" style="margin-top: 0.5rem;">
                <thead>
                  <tr>
                    <th>User</th>
                    <th>Fingerprint</th>
                    <th>Match</th>
                    <th>Δ vs #1</th>
                    <th>Mismatches</th>
                    <th>Best offset</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each @controller.topCandidates as |c|}}
                    <tr>
                      <td>
                        {{#if c.username}}
                          {{c.username}} (#{{c.user_id}})
                        {{else}}
                          #{{c.user_id}}
                        {{/if}}
                      </td>
                      <td><code>{{c.fingerprint_id}}</code></td>
                      <td>{{c.match_ratio}}</td>
                      <td>{{c.delta_from_top}}</td>
                      <td>{{c.mismatches}} / {{c.compared}}</td>
                      <td>{{c.best_offset_segments}}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>

              {{#if @controller.hasMoreCandidates}}
                <details style="margin-top: 0.5rem;">
                  <summary>Show all candidates ({{@controller.candidates.length}})</summary>
                  <pre style="margin-top: 0.5rem; white-space: pre-wrap;">{{@controller.resultJson}}</pre>
                </details>
              {{/if}}
            {{else}}
              <p style="margin-top: 1rem;">
                <em>No candidates matched the observed pattern.</em>
              </p>
            {{/if}}

            <details style="margin-top: 1rem;">
              <summary>Raw JSON</summary>
              <pre style="margin-top: 0.5rem; white-space: pre-wrap;">{{@controller.resultJson}}</pre>
            </details>
          {{/if}}
        </div>

        <div style="flex: 0 1 420px; min-width: 280px;">
          <div class="admin-detail-panel">
            <h3>{{i18n "admin.media_gallery.forensics_identify.find_media_title"}}</h3>
            <div style="margin-top: 0.5rem;">
              <input
                type="text"
                value={{@controller.searchQuery}}
                placeholder={{i18n "admin.media_gallery.forensics_identify.find_media_placeholder"}}
                {{on "input" @controller.onSearchInput}}
              />
              <div style="opacity:0.8; margin-top: 0.35rem;">
                {{i18n "admin.media_gallery.forensics_identify.find_media_help"}}
              </div>
            </div>

            {{#if @controller.searchError}}
              <div class="alert alert-error" style="margin-top: 0.75rem;">{{@controller.searchError}}</div>
            {{/if}}

            {{#if @controller.isSearching}}
              <p style="margin-top: 0.75rem; opacity:0.8;">Searching…</p>
            {{/if}}

            {{#if @controller.searchResults.length}}
              <ul style="margin-top: 0.75rem;">
                {{#each @controller.searchResults as |it|}}
                  <li style="margin-bottom: 0.35rem;">
                    <button
                      type="button"
                      class="btn btn-small"
                      {{on "click" (fn @controller.pickPublicId it)}}
                    >
                      Use
                    </button>
                    <span style="margin-left: 0.5rem;">
                      <strong>{{it.title}}</strong>
                      <span style="opacity:0.8;">(#{{it.id}})</span>
                    </span>
                    <div style="opacity:0.8; margin-left: 3.2rem;">
                      <code>{{it.public_id}}</code>
                      {{#if it.username}}
                        <span style="margin-left: 0.5rem;">by {{it.username}}</span>
                      {{/if}}
                    </div>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              {{#if @controller.showNoSearchMatches}}
                <p style="margin-top: 0.75rem; opacity:0.8;">No matches.</p>
              {{/if}}
            {{/if}}

            <hr />

            <h3>Best test method</h3>
            <ol>
              <li>Log in as a normal test user and play the video (so you definitely get a personalized stream).</li>
              <li>Open DevTools → Network and find the <strong>variant playlist</strong> URL (.m3u8).</li>
              <li>Paste that URL into the field on the left (no need to download manually).</li>
            </ol>
            <p style="opacity:0.85;">
              URL mode is restricted to your own site for safety. For external leaks (mp4 re-uploads), upload the file.
            </p>
          </div>
        </div>
      </div>
    </div>
  </template>
);
