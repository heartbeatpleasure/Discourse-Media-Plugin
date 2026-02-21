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
                {{i18n "admin.media_gallery.forensics_identify.file_label"}}
              </label>
              <div class="controls">
                <input type="file" {{on "change" @controller.onFileChange}} />
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

            <div class="alert {{if @controller.weakSignal "alert-warning" "alert-info"}}" style="margin-top: 0.75rem;">
              <strong>Summary</strong>
              <div style="margin-top: 0.5rem;">
                <div><strong>samples:</strong> {{@controller.samples}}</div>
                <div><strong>usable_samples:</strong> {{@controller.usableSamples}}</div>
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
                  (less re-encoded/cropped). The best test is downloading the variant playlist with ffmpeg.
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
          <div class="admin-detail-panel">
            <h3>How to get a better test file</h3>
            <ol>
              <li>Log in as a normal test user and play the video (so you definitely get a personalized stream).</li>
              <li>Open DevTools → Network and find the <strong>variant playlist</strong> URL (.m3u8).</li>
              <li>Download it with ffmpeg (below), then upload the resulting mp4 here.</li>
            </ol>
            <pre style="white-space: pre-wrap;">ffmpeg -i "&lt;variant-playlist.m3u8&gt;" -c copy leaked.mp4</pre>
            <p style="opacity:0.85;">
              If you only have segments, concatenate multiple consecutive segments first; 1 segment often yields 0 usable samples.
            </p>
          </div>
        </div>
      </div>
    </div>
  </template>
);
