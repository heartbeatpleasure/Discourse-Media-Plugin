import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
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
                  <option value="v3_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v3_pairs"}}</option>
                  <option value="v4_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v4_pairs"}}</option>
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

          {{#if @controller.statusMessage}}
            <div class="alert alert-info" style="margin-top: 1rem;">{{@controller.statusMessage}}</div>
          {{/if}}

          {{#if @controller.hasResult}}
            <h2 style="margin-top: 2rem;">{{i18n "admin.media_gallery.forensics_identify.result"}}</h2>

            <div class="alert {{@controller.confidenceClass}}" style="margin-top: 0.75rem;">
              <strong>Summary</strong>
              <div style="margin-top: 0.5rem;">
                <div><strong>samples:</strong> {{@controller.samples}}</div>
                <div><strong>usable_samples:</strong> {{@controller.usableSamples}}</div>
                {{#if @controller.decisionText}}
                  <div><strong>decision:</strong> {{@controller.decisionText}}</div>
                {{/if}}
                <div><strong>confidence:</strong> {{@controller.confidence}}</div>

                {{#if @controller.meta.user_message}}
                  <div style="margin-top: 0.5rem; opacity: 0.95;">
                    <strong>note:</strong> {{@controller.meta.user_message}}
                  </div>
                {{/if}}
                {{#if @controller.candidates.length}}
                  <div>
                    <strong>top_match:</strong> {{@controller.topMatchRatio}}
                    <span style="opacity:0.85;">(Δ vs #2: {{@controller.matchDelta}})</span>
                  </div>

                  {{#if @controller.shortlistEvidenceGap}}
                    <div style="opacity:0.95;">
                      <strong>shortlist gap:</strong> {{@controller.shortlistEvidenceGap}}
                    </div>
                  {{/if}}

                  {{#if @controller.topCandidateWhy}}
                    <div style="opacity:0.95; margin-top:0.25rem;">
                      <strong>top evidence:</strong> {{@controller.topCandidateWhy}}
                    </div>
                  {{/if}}

                  {{#if @controller.poolSize}}
                    <div style="margin-top: 0.25rem; opacity:0.95;">
                      <strong>pool_size:</strong> {{@controller.poolSize}}
                      <span style="opacity:0.85;">(reference: {{@controller.referencePoolSize}})</span>
                    </div>
                  {{/if}}

                  {{#if @controller.topSignalZ}}
                    <div style="opacity:0.95;">
                      <strong>signal_z:</strong> {{@controller.topSignalZ}}
                      {{#if @controller.topPValue}}
                        <span style="opacity:0.85;">(p≈{{@controller.topPValue}})</span>
                      {{/if}}
                    </div>
                  {{/if}}

                  {{#if @controller.topExpectedFalsePositivesPool}}
                    <div style="opacity:0.95;">
                      <strong>E[false positives]:</strong>
                      {{@controller.topExpectedFalsePositivesPool}} (pool)
                      <span style="opacity:0.85;">/ {{@controller.topExpectedFalsePositives2000}} (at {{@controller.referencePoolSize}})</span>
                    </div>
                  {{/if}}
                {{/if}}
                {{#if @controller.meta.duration_seconds}}
                  <div><strong>duration_seconds:</strong> {{@controller.meta.duration_seconds}}</div>
                {{/if}}
                {{#if @controller.meta.layout}}
                  <div><strong>layout:</strong> {{@controller.meta.layout}}</div>
                {{/if}}
                {{#if @controller.syncPeriod}}
                  <div>
                    <strong>sync layer:</strong> period {{@controller.syncPeriod}}
                    {{#if @controller.syncPairsCount}}
                      <span style="opacity:0.85;">({{@controller.syncPairsCount}} safe-zone pairs)</span>
                    {{/if}}
                  </div>
                {{/if}}
                {{#if @controller.eccScheme}}
                  <div>
                    <strong>ecc:</strong> {{@controller.eccScheme}}
                    {{#if @controller.eccGroupsUsed}}
                      <span style="opacity:0.85;">(logical groups: {{@controller.eccGroupsUsed}}{{#if @controller.eccRawUsableSamples}}, raw usable: {{@controller.eccRawUsableSamples}}{{/if}})</span>
                    {{/if}}
                  </div>
                {{/if}}
                {{#if @controller.phaseSearchUsed}}
                  <div>
                    <strong>phase:</strong>
                    {{#if @controller.chosenPhaseSeconds}}
                      {{@controller.chosenPhaseSeconds}}s
                    {{else}}
                      0.0s
                    {{/if}}
                    {{#if @controller.denseStepSeconds}}
                      <span style="opacity:0.85;">(dense_step: {{@controller.denseStepSeconds}}s)</span>
                    {{/if}}
                  </div>
                {{/if}}
                <div>
                  <strong>offset expansion:</strong>
                  {{#if @controller.offsetExpansionApplied}}applied{{else}}not applied{{/if}}
                  {{#if @controller.offsetExpansionReason}}
                    <span style="opacity:0.85;">({{@controller.offsetExpansionReason}})</span>
                  {{/if}}
                </div>
                <div>
                  <strong>phase refinement:</strong>
                  {{#if @controller.phaseRefinementAttempted}}
                    {{#if @controller.phaseRefinementApplied}}applied{{else}}rejected{{/if}}
                  {{else}}
                    not attempted
                  {{/if}}
                  {{#if @controller.phaseRefinementReason}}
                    <span style="opacity:0.85;">({{@controller.phaseRefinementReason}})</span>
                  {{/if}}
                </div>
                {{#if @controller.chunkedResyncUsed}}
                  <div>
                    <strong>chunked re-sync:</strong>
                    {{@controller.chunkedResyncChunksUsed}} chunks
                    {{#if @controller.chunkedResyncWindowSegments}}
                      <span style="opacity:0.85;">(window: {{@controller.chunkedResyncWindowSegments}} seg)</span>
                    {{/if}}
                    {{#if @controller.chunkedResyncOffsets.length}}
                      <div style="opacity:0.85; margin-left: 1rem;">
                        offsets: {{@controller.chunkedResyncOffsets}}
                      </div>
                    {{/if}}
                    {{#if @controller.chunkedResyncRanges.length}}
                      <div style="opacity:0.85; margin-left: 1rem;">
                        ranges: {{@controller.chunkedResyncRanges}}
                      </div>
                    {{/if}}
                  </div>
                {{else}}
                  <div>
                    <strong>chunked re-sync:</strong> not applied
                    {{#if @controller.chunkedResyncReason}}
                      <span style="opacity:0.85;">({{@controller.chunkedResyncReason}})</span>
                    {{/if}}
                  </div>
                {{/if}}
                <div>
                  <strong>multisample refine:</strong>
                  {{#if @controller.multisampleRefineUsed}}
                    {{#if @controller.multisampleRefineApplied}}applied{{else}}rejected{{/if}}
                  {{else}}
                    not applied
                  {{/if}}
                  {{#if @controller.multisampleRefineReason}}
                    <span style="opacity:0.85;">({{@controller.multisampleRefineReason}})</span>
                  {{/if}}
                </div>
                <div>
                  <strong>variant polarity:</strong> {{@controller.variantPolarity}}
                  {{#if @controller.polarityFlipUsed}}
                    <span style="opacity:0.85;">(A/B flipped during matching{{#if @controller.polarityScoreDelta}}, score Δ: {{@controller.polarityScoreDelta}}{{/if}})</span>
                  {{/if}}
                </div>

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

                {{#if @controller.configuredFilemodeSoftBudgetSeconds}}
                  <div>
                    <strong>file-mode budgets:</strong>
                    soft {{@controller.configuredFilemodeSoftBudgetSeconds}}s
                    {{#if @controller.configuredFilemodeEngineBudgetSeconds}}
                      <span style="opacity:0.85;">/ engine {{@controller.configuredFilemodeEngineBudgetSeconds}}s</span>
                    {{/if}}
                  </div>
                {{/if}}

                {{#if @controller.timeoutKind}}
                  <div style="opacity:0.95;">
                    <strong>timeout kind:</strong> {{@controller.timeoutKind}}
                    {{#if @controller.likelyTimeoutLayer}}
                      <span style="opacity:0.85;">({{@controller.likelyTimeoutLayer}})</span>
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
                    {{#if @controller.decisionReasons.length}}
                      <div style="margin-top: 0.35rem; opacity:0.9;">
                        <strong>Policy why:</strong>
                        {{@controller.decisionReasonsText}}
                      </div>
                    {{/if}}
                  {{#if @controller.recommendation}}
                    <div style="margin-top: 0.35rem; opacity:0.9;">
                      <strong>Recommendation:</strong> {{@controller.recommendation}}
                    </div>
                  {{/if}}
                </div>
              {{/if}}

              {{#if @controller.isAmbiguous}}
                <div style="margin-top: 0.75rem;">
                  <strong>Note:</strong>
                  The top two candidates are close. Treat this as ambiguous and gather a longer sample.
                </div>
              {{/if}}
            </div>

            {{#if @controller.hasAlignmentDebug}}
              <div style="margin-top: 1rem;">
                <strong>Observed variants:</strong>
                <code style="display:block; white-space: pre-wrap; word-break: break-word; margin-top: 0.35rem;">
                  {{@controller.observedVariants}}
                </code>

                {{#if @controller.expectedVariantsTopCandidate}}
                  <div style="margin-top: 0.65rem;">
                    <strong>Expected top candidate:</strong>
                    <code style="display:block; white-space: pre-wrap; word-break: break-word; margin-top: 0.35rem;">
                      {{@controller.expectedVariantsTopCandidate}}
                    </code>
                  </div>
                {{/if}}

                {{#if @controller.referenceSegmentIndicesText}}
                  <div style="margin-top: 0.65rem;">
                    <strong>Reference segment indices:</strong>
                    <code style="display:block; white-space: pre-wrap; word-break: break-word; margin-top: 0.35rem;">
                      {{@controller.referenceSegmentIndicesText}}
                    </code>
                  </div>
                {{/if}}

                {{#if @controller.mismatchPositions.length}}
                  <div style="margin-top: 0.65rem;">
                    <strong>Mismatch positions:</strong>
                    <code style="display:block; white-space: pre-wrap; word-break: break-word; margin-top: 0.35rem;">
                      {{@controller.mismatchPositionsText}}
                    </code>
                  </div>
                {{/if}}
              </div>
            {{/if}}

            {{#if @controller.candidates.length}}
              {{#if @controller.conclusive}}
                <h3 style="margin-top: 1.5rem;">Top candidates</h3>
              {{else}}
                <h3 style="margin-top: 1.5rem;">Candidates (not conclusive)</h3>
                <div class="alert alert-warning" style="margin-top: 0.5rem;">
                  Do not treat this as definitive. Gather a longer sample to increase usable_samples and separation from #2.
                </div>
              {{/if}}

              <details style="margin-top: 0.5rem;" open={{@controller.conclusive}}>
                <summary>Show candidates</summary>
                <table class="table" style="margin-top: 0.5rem;">
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
                        <td>
                          {{#if c.username}}
                            {{c.username}} (#{{c.user_id}})
                          {{else}}
                            #{{c.user_id}}
                          {{/if}}
                        </td>
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
                            <div style="opacity:0.75; max-width:18rem;">{{c.why}}</div>
                          {{/if}}
                        </td>
                        <td>{{c.mismatches}} / {{c.compared}}</td>
                        <td>{{c.best_offset_segments}}</td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </details>

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
