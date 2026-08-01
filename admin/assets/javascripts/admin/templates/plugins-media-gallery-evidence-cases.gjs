import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq, not, or } from "discourse/truth-helpers";

export default RouteTemplate(
  <template>
    <style>
      .mg-evidence { display: grid; gap: 1rem; --mg-border: var(--primary-low); --mg-muted: var(--primary-medium); }
      .mg-evidence h1, .mg-evidence h2, .mg-evidence h3, .mg-evidence p { margin: 0; }
      .mg-ev-panel { border: 1px solid var(--mg-border); border-radius: 16px; background: var(--secondary); padding: 1rem; display: grid; gap: .85rem; min-width: 0; }
      .mg-ev-hero, .mg-ev-head, .mg-ev-actions { display: flex; gap: .75rem; align-items: center; justify-content: space-between; flex-wrap: wrap; }
      .mg-ev-search { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: .75rem; align-items: end; }
      .mg-ev-search input { width: 100%; min-width: 0; height: 40px; box-sizing: border-box; }
      .mg-ev-search .btn { align-self: end; height: 40px; margin: 0; white-space: nowrap; }
      .mg-ev-grid { display: grid; grid-template-columns: minmax(250px,.7fr) minmax(0,1.3fr); gap: 1rem; align-items: start; }
      .mg-ev-form { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: .75rem; }
      .mg-ev-field { display: grid; gap: .3rem; min-width: 0; }
      .mg-ev-field.is-full { grid-column: 1/-1; }
      .mg-ev-field input, .mg-ev-field textarea, .mg-ev-field select { width: 100%; box-sizing: border-box; }
      .mg-ev-field input, .mg-ev-field select { height: 40px; min-height: 40px; }
      .mg-ev-field input[type="datetime-local"] { height: 40px; min-height: 40px; margin: 0; }
      .mg-ev-field textarea { min-height: 90px; }
      .mg-ev-list { display: grid; gap: .65rem; }
      .mg-ev-row { border: 1px solid var(--mg-border); border-radius: 12px; padding: .75rem; background: var(--primary-very-low); display: grid; gap: .4rem; }
      .mg-ev-row.is-clickable { cursor: pointer; }
      .mg-ev-meta { color: var(--mg-muted); font-size: var(--font-down-1); overflow-wrap: anywhere; }
      .mg-ev-badges { display:flex; gap:.4rem; flex-wrap:wrap; }
      .mg-ev-badge { padding:.2rem .55rem; border:1px solid var(--mg-border); border-radius:999px; font-size:var(--font-down-1); }
      .mg-ev-badge.is-ok { background:var(--success-low); color:var(--success); }
      .mg-ev-badge.is-warn { background:var(--highlight-low); }
      .mg-ev-badge.is-danger { background:var(--danger-low); color:var(--danger); }
      .mg-ev-flash { border-radius:12px; padding:.75rem; border:1px solid var(--mg-border); }
      .mg-ev-flash.is-error { background:var(--danger-low); color:var(--danger); }
      .mg-ev-flash.is-success { background:var(--success-low); color:var(--success); }
      .mg-ev-code { font-family:var(--d-font-family--monospace); overflow-wrap:anywhere; font-size:var(--font-down-1); }
      .mg-ev-sections { display:grid; gap:1rem; }
      .mg-ev-checks { display:grid; gap:.5rem; }
      .mg-ev-check { display:flex; gap:.55rem; align-items:flex-start; }
      .mg-ev-check input { margin-top:.2rem; }
      @media (max-width: 900px) { .mg-ev-grid, .mg-ev-form { grid-template-columns:1fr; } .mg-ev-field.is-full { grid-column:auto; } }
      @media (max-width: 520px) { .mg-ev-search { grid-template-columns: 1fr; } .mg-ev-search .btn { width: 100%; } }
    </style>

    <div class="mg-evidence">
      <section class="mg-ev-panel mg-ev-hero">
        <div>
          <h1>Forensic evidence cases</h1>
          <p class="mg-ev-meta">English, jurisdiction-neutral technical reports with immutable snapshots, human review, chain-of-custody hashing and integrity/CMS packages.</p>
        </div>
        <a class="btn btn-default" href="/admin/plugins/media-gallery">Back to Media Library</a>
      </section>

      {{#if @controller.error}}<div class="mg-ev-flash is-error">{{@controller.error}}</div>{{/if}}
      {{#if @controller.notice}}<div class="mg-ev-flash is-success">{{@controller.notice}}</div>{{/if}}

      <section class="mg-ev-panel">
        <div class="mg-ev-head">
          <div><h2>Safety profile</h2><p class="mg-ev-meta">Restricted identity annexes are not included in standard exports. External source URLs are recorded manually and are never fetched automatically by the server.</p></div>
          {{#if @controller.configLoaded}}
            <div class="mg-ev-badges">
              <span class="mg-ev-badge">Report language: {{@controller.reportLanguageLabel}}</span>
              <span class="mg-ev-badge">Package protection: {{@controller.sealModeLabel}}</span>
              <span class="mg-ev-badge">Trusted timestamp: {{@controller.timestampLabel}}</span>
            </div>
          {{else}}
            <span class="mg-ev-badge is-danger">Configuration unavailable</span>
          {{/if}}
        </div>
        {{#if @controller.configLoaded}}
          {{#if @controller.identitySettingsComplete}}
            <div class="mg-ev-meta"><strong>Issuer:</strong> {{@controller.issuerName}} &nbsp;|&nbsp; <strong>Operator:</strong> {{@controller.operatorIdentity}}</div>
          {{else}}
            <div class="mg-ev-flash is-error">
              Evidence identity settings are incomplete. Configure both the non-personal issuer name and operator identity before finalization.
              {{#if @controller.hasIssuerIdentity}}<span> Issuer: {{@controller.issuerName}}.</span>{{/if}}
              {{#if @controller.hasOperatorIdentity}}<span> Operator: {{@controller.operatorIdentity}}.</span>{{/if}}
            </div>
          {{/if}}
          {{#if @controller.config.legal_notice_url}}<div class="mg-ev-meta"><strong>Legal notice:</strong> {{@controller.config.legal_notice_url}}</div>{{/if}}
          {{#if @controller.config.jurisdiction_notice}}<div class="mg-ev-meta">{{@controller.config.jurisdiction_notice}}</div>{{/if}}
        {{else}}
          <div class="mg-ev-meta">The evidence configuration could not be loaded. This is a loading or server-side error, not a field you still need to complete.</div>
          <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{@controller.busy}} {{on "click" @controller.retrySelectedCase}}>Retry loading</button></div>
        {{/if}}
      </section>

      {{#if @controller.pendingCaseLoad}}
        <section class="mg-ev-panel">
          <div>
            <h2>Evidence case details could not be loaded</h2>
            <p class="mg-ev-meta">The case was created as {{@controller.requestedCaseRef}}, but this page could not retrieve its details. The case has not been lost. Retry the request; if it still fails, the readable error above corresponds to a detailed entry in the Discourse server logs.</p>
          </div>
          <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{@controller.busy}} {{on "click" @controller.retrySelectedCase}}>Retry case loading</button><button class="btn btn-default" type="button" {{on "click" @controller.closeCase}}>Back to case list</button></div>
        </section>
      {{/if}}

      {{#unless @controller.hasSelected}}
        <div class="mg-ev-grid">
          <section class="mg-ev-panel">
            <div class="mg-ev-head"><h2>Cases</h2><span class="mg-ev-meta">{{@controller.cases.length}} shown</span></div>
            <form class="mg-ev-search" {{on "submit" @controller.search}}>
              <input type="search" aria-label="Search evidence cases" placeholder="Case, claimant, platform" value={{@controller.query}} {{on "input" (fn @controller.setField "query")}} />
              <button class="btn btn-default" type="submit" disabled={{@controller.busy}}>Search</button>
            </form>
            <div class="mg-ev-list">
              {{#each @controller.caseRows as |row|}}
                <button class="mg-ev-row is-clickable" type="button" {{on "click" (fn @controller.openCase row.case_ref)}}>
                  <strong>{{row.case_ref}}</strong>
                  <div class="mg-ev-badges"><span class="mg-ev-badge">{{row.status_label}}</span><span class="mg-ev-badge">{{row.decision_label}}</span>{{#if row.legal_hold}}<span class="mg-ev-badge is-danger">Legal hold</span>{{/if}}</div>
                  <span class="mg-ev-meta">{{row.media_title}} | {{row.claimant_ref}} | {{row.external_platform}}</span>
                </button>
              {{else}}
                <p class="mg-ev-meta">No evidence cases found.</p>
              {{/each}}
            </div>
          </section>

          <section class="mg-ev-panel">
            <div><h2>New evidence case</h2><p class="mg-ev-meta">Create the case first; upload source capture and acquired evidence separately. URLs are recorded but never fetched by the server.</p></div>
            <form class="mg-ev-form" {{on "submit" @controller.createCase}}>
              <label class="mg-ev-field"><span>Media public ID</span><input value={{@controller.newMediaPublicId}} {{on "input" (fn @controller.setField "newMediaPublicId")}} /></label>
              <label class="mg-ev-field"><span>Claimant reference</span><input required value={{@controller.newClaimantRef}} {{on "input" (fn @controller.setField "newClaimantRef")}} /></label>
              <label class="mg-ev-field is-full"><span>Research question</span><textarea required value={{@controller.newResearchQuestion}} {{on "input" (fn @controller.setField "newResearchQuestion")}}></textarea></label>
              <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{@controller.newExternalUrl}} {{on "input" (fn @controller.setField "newExternalUrl")}} /></label>
              <label class="mg-ev-field"><span>External platform</span><input value={{@controller.newExternalPlatform}} {{on "input" (fn @controller.setField "newExternalPlatform")}} /></label>
              <label class="mg-ev-field"><span>Visible external username</span><input value={{@controller.newExternalUsername}} {{on "input" (fn @controller.setField "newExternalUsername")}} /></label>
              <label class="mg-ev-field"><span>Rights statement reference</span><input value={{@controller.newRightsStatementRef}} {{on "input" (fn @controller.setField "newRightsStatementRef")}} /></label>
              <label class="mg-ev-field"><span>Rights statement received</span><input type="datetime-local" value={{@controller.newRightsStatementReceivedAt}} {{on "input" (fn @controller.setField "newRightsStatementReceivedAt")}} /></label>
              <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit" disabled={{@controller.busy}}>Create case</button></div>
            </form>
          </section>
        </div>
      {{else}}
        <section class="mg-ev-panel">
          <div class="mg-ev-head">
            <div><h2>{{@controller.selected.case_ref}}</h2><p class="mg-ev-meta">{{@controller.selected.research_question}}</p></div>
            <div class="mg-ev-actions"><button class="btn btn-default" type="button" {{on "click" @controller.reloadSelected}}>Refresh</button><button class="btn btn-default" type="button" {{on "click" @controller.closeCase}}>Back to cases</button></div>
          </div>
          <div class="mg-ev-badges"><span class="mg-ev-badge">{{@controller.selectedHeader.status_label}}</span><span class="mg-ev-badge">{{@controller.selectedHeader.decision_label}}</span><span class="mg-ev-badge">{{@controller.selectedHeader.classification_label}}</span>{{#if @controller.selected.claimant_confirmed}}<span class="mg-ev-badge is-ok">Claimant confirmed</span>{{/if}}{{#if @controller.selected.legal_hold}}<span class="mg-ev-badge is-danger">Legal hold</span>{{/if}}</div>
          <div class="mg-ev-meta">Media: {{@controller.selected.media_title}} ({{@controller.selected.media_public_id}}) | Claimant: {{@controller.selected.claimant_ref}} | External: {{@controller.selected.external_platform}} / {{@controller.selected.external_username}}</div>
          <div class="mg-ev-meta">Retention review due: {{@controller.selected.retention_due_at_utc}} (advisory only; no automatic deletion in this release)</div>
          {{#unless @controller.selectedMutable}}<div class="mg-ev-flash is-success">This case is immutable after package creation. Existing report and package bytes remain downloadable and verifiable.</div>{{/unless}}
        </section>

        <div class="mg-ev-grid">
          <div class="mg-ev-sections">
            <section class="mg-ev-panel">
              <div>
                <h3>Case intake</h3>
                <p class="mg-ev-meta">Record the observation and rights-claim context. These fields are factual inputs, not a legal finding. Material edits invalidate prior approvals.</p>
              </div>
              <form class="mg-ev-form" {{on "submit" @controller.saveCase}}>
                <label class="mg-ev-field"><span>Claimant reference</span><input required value={{@controller.editClaimantRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editClaimantRef")}} /></label>
                <label class="mg-ev-field"><span>Classification</span><select value={{@controller.editClassification}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setField "editClassification")}}><option value="confidential">Confidential</option><option value="restricted">Restricted</option></select></label>
                <label class="mg-ev-field is-full"><span>Research question</span><textarea required value={{@controller.editResearchQuestion}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editResearchQuestion")}}></textarea></label>
                <label class="mg-ev-field"><span>Jurisdiction context</span><input value={{@controller.editJurisdictionContext}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editJurisdictionContext")}} /></label>
                <label class="mg-ev-field"><span>External platform</span><input value={{@controller.editExternalPlatform}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalPlatform")}} /></label>
                <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{@controller.editExternalUrl}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUrl")}} /></label>
                <label class="mg-ev-field"><span>Visible external username</span><input value={{@controller.editExternalUsername}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUsername")}} /></label>
                <label class="mg-ev-field"><span>Observed by staff (local time)</span><input type="datetime-local" value={{@controller.editExternalObservedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalObservedAt")}} /></label>
                <label class="mg-ev-field"><span>Platform-displayed date/time</span><input value={{@controller.editExternalDisplayedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalDisplayedAt")}} /></label>
                <label class="mg-ev-field"><span>Rights statement reference</span><input value={{@controller.editRightsStatementRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementRef")}} /></label>
                <label class="mg-ev-field"><span>Rights statement received (local time)</span><input type="datetime-local" value={{@controller.editRightsStatementReceivedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementReceivedAt")}} /></label>
                <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (not @controller.selectedMutable)}}>Save case intake</button></div>
              </form>
            </section>

            <section class="mg-ev-panel">
              <h3>Evidence objects</h3>
              <form class="mg-ev-form" {{on "submit" @controller.uploadObject}}>
                <label class="mg-ev-field"><span>Role</span><select value={{@controller.uploadRole}} {{on "change" (fn @controller.setField "uploadRole")}}><option value="external_original">External original</option><option value="working_copy">Working copy</option><option value="source_screenshot">Source screenshot</option><option value="source_html">Source HTML</option><option value="source_warc">Source WARC</option><option value="source_headers">Source headers</option><option value="rights_statement">Rights statement</option><option value="other">Other</option></select></label>
                <label class="mg-ev-field"><span>File</span><input type="file" required {{on "change" @controller.setUploadFile}} /></label>
                <label class="mg-ev-field is-full"><span>Description</span><input value={{@controller.uploadDescription}} {{on "input" (fn @controller.setField "uploadDescription")}} /></label>
                <button class="btn btn-primary" type="submit" disabled={{or @controller.busy (not @controller.selectedMutable)}}>Store, hash and freeze</button>
              </form>
              <div class="mg-ev-list">
                {{#each @controller.selectedObjects as |object|}}
                  <div class="mg-ev-row"><strong>{{object.object_ref}} · {{object.role_label}}</strong><span class="mg-ev-code">SHA-256 {{object.sha256}}</span><span class="mg-ev-meta">{{object.original_filename}} · {{object.size_bytes}} bytes · Quarantine: {{object.quarantine_status_label}}</span>{{#if (or (eq object.role "external_original") (eq object.role "working_copy"))}}<div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.setQuarantine object.object_ref "clean")}}>Mark clean</button><button class="btn btn-danger" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.setQuarantine object.object_ref "rejected")}}>Reject</button></div>{{/if}}</div>
                {{else}}<p class="mg-ev-meta">No evidence objects stored yet.</p>{{/each}}
              </div>
            </section>

            <section class="mg-ev-panel">
              <h3>Identify snapshot</h3>
              {{#if @controller.selectedIdentify}}
                <div class="mg-ev-row"><strong>{{@controller.selectedIdentify.run_ref}} · {{@controller.selectedIdentify.decision_label}}</strong><span class="mg-ev-meta">{{@controller.selectedIdentify.run_kind_label}} · Candidates: {{@controller.selectedIdentify.candidate_population_count}} · Layout: {{@controller.selectedIdentify.layout}}</span><span class="mg-ev-code">Raw result SHA-256 {{@controller.selectedIdentify.raw_result_sha256}}</span><span>Attributed distribution account: {{@controller.selectedIdentify.attributed_username}} / {{@controller.selectedIdentify.attributed_account_ref}}</span></div>
              {{else}}<p class="mg-ev-meta">No immutable identify result attached. Create a case directly from a completed Forensics Identify result.</p>{{/if}}
            </section>

            <section class="mg-ev-panel">
              <h3>Review and claimant confirmation</h3>
              {{#unless @controller.selected.claimant_confirmed}}<div class="mg-ev-row"><strong>Claimant confirmation required</strong><span>Record the rights claimant confirmation before final human approvals; later material changes invalidate earlier approvals.</span><button class="btn btn-default" type="button" disabled={{not @controller.selectedMutable}} {{on "click" @controller.confirmClaimant}}>Record claimant confirmation</button></div>{{/unless}}
              <div class="mg-ev-checks">
                {{#each @controller.reviewChecklistItems as |item|}}
                  <label class="mg-ev-check"><input type="checkbox" checked={{item.checked}} {{on "change" (fn @controller.setReviewCheck item.key)}} /><span>{{item.label}}</span></label>
                {{/each}}
              </div>
              <label class="mg-ev-field"><span>Internal review reason / notes</span><textarea value={{@controller.reviewReason}} {{on "input" (fn @controller.setField "reviewReason")}}></textarea><small class="mg-ev-meta">Free text remains internal. External reports and packages contain only a SHA-256 digest indicating that notes existed.</small></label>
              <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "technical" "approved")}}>Approve technical review</button>{{#if @controller.config.can_finalize}}<button class="btn btn-default" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "senior" "approved")}}>Approve senior review</button><button class="btn btn-default" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "privacy" "approved")}}>Approve privacy review</button>{{/if}}<button class="btn btn-danger" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.addReview "technical" "rejected")}}>Reject review</button></div>
              <div class="mg-ev-list">{{#each @controller.selectedReviews as |review|}}<div class="mg-ev-row"><strong>{{review.review_kind_label}} · {{review.outcome_label}}</strong><span>{{review.reviewer_role_label}} ({{review.reviewer_ref}})</span><span class="mg-ev-meta">{{review.reviewed_at_utc}} · {{review.reason}}</span></div>{{else}}<p class="mg-ev-meta">No reviews recorded.</p>{{/each}}</div>
            </section>
          </div>

          <div class="mg-ev-sections">
            <section class="mg-ev-panel">
              <div class="mg-ev-head"><h3>Finalization policy</h3>{{#if @controller.selectedFinalization.ready}}<span class="mg-ev-badge is-ok">ready</span>{{else}}<span class="mg-ev-badge is-danger">blocked</span>{{/if}}</div>
              <div class="mg-ev-row"><span>Chain of custody: {{if @controller.selectedChainOk "verified" "invalid"}}</span></div>
              {{#each @controller.selectedFinalizationBlockers as |issue|}}<div class="mg-ev-row"><strong>{{issue.title}}</strong><span>{{issue.message}}</span></div>{{/each}}
              {{#each @controller.selectedFinalizationWarnings as |issue|}}<div class="mg-ev-row"><strong>{{issue.title}}</strong><span>{{issue.message}}</span></div>{{/each}}
            </section>

            <section class="mg-ev-panel">
              <h3>Reports</h3>
              <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.generateReport false)}}>Generate DRAFT PDF</button>{{#if @controller.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" (fn @controller.generateReport true)}}>Generate final report</button>{{/if}}</div>
              <div class="mg-ev-list">{{#each @controller.selectedReports as |report|}}<div class="mg-ev-row"><strong>{{report.report_ref}} · {{report.status_label}}</strong><span class="mg-ev-code">PDF {{report.pdf_sha256}}</span><a class="btn btn-default" href={{report.download_url}}>Download PDF</a></div>{{else}}<p class="mg-ev-meta">No reports generated.</p>{{/each}}</div>
            </section>

            <section class="mg-ev-panel">
              <h3>Evidence packages</h3>
              {{#if @controller.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" @controller.createPackage}}>Generate integrity / CMS package</button>{{/if}}
              <div class="mg-ev-list">{{#each @controller.selectedPackages as |package|}}<div class="mg-ev-row"><strong>{{package.package_ref}} · {{package.status_label}}</strong><span class="mg-ev-code">Package {{package.package_sha256}}</span><span class="mg-ev-code">Manifest {{package.manifest_sha256}}</span><span class="mg-ev-meta">CMS content signature: {{package.cms_signature_integrity_verified}} · certificate trust: external · Timestamp: {{package.timestamp_status_label}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{package.download_url}}>Download tar.gz</a><button class="btn btn-default" type="button" {{on "click" (fn @controller.verifyPackage package.package_ref)}}>Verify</button></div></div>{{else}}<p class="mg-ev-meta">No package generated.</p>{{/each}}</div>
            </section>

            {{#if @controller.config.can_finalize}}<section class="mg-ev-panel"><h3>Legal hold</h3><label class="mg-ev-field"><span>Reason (required)</span><textarea value={{@controller.holdReason}} {{on "input" (fn @controller.setField "holdReason")}}></textarea></label><div class="mg-ev-actions">{{#if @controller.selected.legal_hold}}<button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold false)}}>Release legal hold</button>{{else}}<button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold true)}}>Place legal hold</button>{{/if}}</div></section>{{/if}}
          </div>
        </div>
      {{/unless}}
    </div>
  </template>
);
