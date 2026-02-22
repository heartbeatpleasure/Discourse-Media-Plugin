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

            <div class="alert {{@controller.summaryAlertClass}}" style="margin-top: 0.75rem;">
              <strong>Summary</strong>
              <div style="margin-top: 0.5rem;">
                <div><strong>samples:</strong> {{@controller.samples}}</div>
                <div><strong>usable_samples:</strong> {{@controller.usableSamples}}</div>
                {{#if @controller.topCandidate}}
                  <div>
                    <strong>confidence:</strong>
                    {{@controller.confidenceLabel}}
                    &nbsp;—&nbsp;
                    <strong>top_match:</strong> {{@controller.topCandidate.match_ratio}}
                  </div>
                {{/if}}
                {{#if @controller.meta.duration_seconds}}
                  <div><strong>duration_seconds:</strong> {{@controller.meta.duration_seconds}}</div>
                {{/if}}
                {{#if @controller.meta.layout}}
                  <div><strong>layout:</strong> {{@controller.meta.layout}}</div>
                {{/if}}
              </div>

              {{#if @controller.weakSignal}}
                <div style="margin-top: 0.75rem;">
                  <strong>Tip:</strong>
                  Single segments often contain too little signal. Try a longer file that is closer to the original HLS download
                  (less re-encoded/cropped). The best test is pasting the variant playlist URL (.m3u8).
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
                    <th>Mismatches</th>
                    <th>Best offset</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each @controller.candidates as |c|}}
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
                      <td>{{c.mismatches}} / {{c.compared}}</td>
                      <td>{{c.best_offset_segments}}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
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
          <div class="admin-detail-panel" style="margin-bottom: 1rem;">
            <h3>{{i18n "admin.media_gallery.forensics_identify.find_media_title"}}</h3>
            <div style="display:flex; gap: 0.5rem; align-items:center;">
              <input
                type="text"
                value={{@controller.mediaQuery}}
                placeholder={{i18n "admin.media_gallery.forensics_identify.find_media_placeholder"}}
                {{on "input" @controller.onMediaQueryInput}}
              />
              <button
                type="button"
                class="btn"
                disabled={{@controller.mediaIsSearching}}
                {{on "click" @controller.searchMedia}}
              >
                {{#if @controller.mediaIsSearching}}
                  {{i18n "admin.media_gallery.forensics_identify.find_media_searching"}}
                {{else}}
                  {{i18n "admin.media_gallery.forensics_identify.find_media_search"}}
                {{/if}}
              </button>
            </div>

            <div style="opacity:0.8; margin-top: 0.35rem;">
              {{i18n "admin.media_gallery.forensics_identify.find_media_help"}}
            </div>

            {{#if @controller.mediaSearchError}}
              <div class="alert alert-error" style="margin-top: 0.75rem;">
                {{@controller.mediaSearchError}}
              </div>
            {{/if}}

            {{#if @controller.mediaResults.length}}
              <div style="margin-top: 0.75rem; max-height: 320px; overflow:auto;">
                <table class="table" style="margin: 0;">
                  <thead>
                    <tr>
                      <th>Title</th>
                      <th>public_id</th>
                    </tr>
                  </thead>
                  <tbody>
                    {{#each @controller.mediaResults as |m|}}
                      <tr>
                        <td style="max-width: 200px;">
                          <button
                            type="button"
                            class="btn-link"
                            style="padding:0; text-align:left;"
                            data-public-id={{m.public_id}}
                            {{on "click" @controller.onSelectMediaResult}}
                          >
                            {{m.title}}
                          </button>
                          <div style="opacity:0.7; font-size: 0.85em;">
                            {{#if m.uploader_username}}
                              {{m.uploader_username}} ·
                            {{/if}}
                            {{m.status}}
                            {{#if m.media_type}}
                              · {{m.media_type}}
                            {{/if}}
                          </div>
                        </td>
                        <td style="max-width: 190px;">
                          <code style="word-break: break-word;">{{m.public_id}}</code>
                        </td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </div>
            {{else}}
              {{#if @controller.mediaQuery}}
                <div style="margin-top: 0.75rem; opacity: 0.8;">
                  {{i18n "admin.media_gallery.forensics_identify.find_media_no_results"}}
                </div>
              {{/if}}
            {{/if}}
          </div>

          <div class="admin-detail-panel">
            <h3>Best test method</h3>
            <ol>
              <li>Log in as a normal test user and play the video (so you definitely get a personalized stream).</li>
              <li>Open DevTools → Network and find the <strong>variant playlist</strong> URL (.m3u8).</li>
              <li>Paste that URL into the field on the left (no need to download manually).</li>
            </ol>
            <p style="opacity:0.85;">
              This URL mode is intentionally restricted to your own site for safety.
              For external leaks (mp4 re-uploads), upload the file instead.
            </p>
          </div>
        </div>
      </div>
    </div>
  </template>
);
