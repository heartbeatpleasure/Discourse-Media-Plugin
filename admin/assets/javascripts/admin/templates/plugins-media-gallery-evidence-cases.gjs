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

      {{#if this.error}}<div class="mg-ev-flash is-error">{{this.error}}</div>{{/if}}
      {{#if this.notice}}<div class="mg-ev-flash is-success">{{this.notice}}</div>{{/if}}

      <section class="mg-ev-panel">
        <div class="mg-ev-head">
          <div><h2>Safety profile</h2><p class="mg-ev-meta">Sensitive identity annex and automatic external URL fetching are intentionally disabled.</p></div>
          {{#if this.configLoaded}}
            <div class="mg-ev-badges">
              <span class="mg-ev-badge">Report language: {{this.reportLanguageLabel}}</span>
              <span class="mg-ev-badge">Package protection: {{this.sealModeLabel}}</span>
              <span class="mg-ev-badge">Trusted timestamp: {{this.timestampLabel}}</span>
            </div>
          {{else}}
            <span class="mg-ev-badge is-danger">Configuration unavailable</span>
          {{/if}}
        </div>
        {{#if this.configLoaded}}
          {{#if this.identitySettingsComplete}}
            <div class="mg-ev-meta"><strong>Issuer:</strong> {{this.issuerName}} &nbsp;|&nbsp; <strong>Operator:</strong> {{this.operatorIdentity}}</div>
          {{else}}
            <div class="mg-ev-flash is-error">
              Evidence identity settings are incomplete. Configure both the non-personal issuer name and operator identity before finalization.
              {{#if this.hasIssuerIdentity}}<span> Issuer: {{this.issuerName}}.</span>{{/if}}
              {{#if this.hasOperatorIdentity}}<span> Operator: {{this.operatorIdentity}}.</span>{{/if}}
            </div>
          {{/if}}
          {{#if this.config.legal_notice_url}}<div class="mg-ev-meta"><strong>Legal notice:</strong> {{this.config.legal_notice_url}}</div>{{/if}}
          {{#if this.config.jurisdiction_notice}}<div class="mg-ev-meta">{{this.config.jurisdiction_notice}}</div>{{/if}}
        {{else}}
          <div class="mg-ev-meta">The evidence configuration could not be loaded. This is a loading or server-side error, not a field you still need to complete.</div>
          <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{this.busy}} {{on "click" this.retrySelectedCase}}>Retry loading</button></div>
        {{/if}}
      </section>

      {{#if this.pendingCaseLoad}}
        <section class="mg-ev-panel">
          <div>
            <h2>Evidence case details could not be loaded</h2>
            <p class="mg-ev-meta">The case was created as {{this.requestedCaseRef}}, but this page could not retrieve its details. The case has not been lost. Retry the request; if it still fails, the readable error above corresponds to a detailed entry in the Discourse server logs.</p>
          </div>
          <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{this.busy}} {{on "click" this.retrySelectedCase}}>Retry case loading</button><button class="btn btn-default" type="button" {{on "click" this.closeCase}}>Back to case list</button></div>
        </section>
      {{/if}}

      {{#unless this.hasSelected}}
        <div class="mg-ev-grid">
          <section class="mg-ev-panel">
            <div class="mg-ev-head"><h2>Cases</h2><span class="mg-ev-meta">{{this.cases.length}} shown</span></div>
            <form class="mg-ev-search" {{on "submit" this.search}}>
              <input type="search" aria-label="Search evidence cases" placeholder="Case, claimant, platform" value={{this.query}} {{on "input" (fn this.setField "query")}} />
              <button class="btn btn-default" type="submit" disabled={{this.busy}}>Search</button>
            </form>
            <div class="mg-ev-list">
              {{#each this.caseRows as |row|}}
                <button class="mg-ev-row is-clickable" type="button" {{on "click" (fn this.openCase row.case_ref)}}>
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
            <form class="mg-ev-form" {{on "submit" this.createCase}}>
              <label class="mg-ev-field"><span>Media public ID</span><input value={{this.newMediaPublicId}} {{on "input" (fn this.setField "newMediaPublicId")}} /></label>
              <label class="mg-ev-field"><span>Claimant reference</span><input required value={{this.newClaimantRef}} {{on "input" (fn this.setField "newClaimantRef")}} /></label>
              <label class="mg-ev-field is-full"><span>Research question</span><textarea required value={{this.newResearchQuestion}} {{on "input" (fn this.setField "newResearchQuestion")}}></textarea></label>
              <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{this.newExternalUrl}} {{on "input" (fn this.setField "newExternalUrl")}} /></label>
              <label class="mg-ev-field"><span>External platform</span><input value={{this.newExternalPlatform}} {{on "input" (fn this.setField "newExternalPlatform")}} /></label>
              <label class="mg-ev-field"><span>Visible external username</span><input value={{this.newExternalUsername}} {{on "input" (fn this.setField "newExternalUsername")}} /></label>
              <label class="mg-ev-field"><span>Rights statement reference</span><input value={{this.newRightsStatementRef}} {{on "input" (fn this.setField "newRightsStatementRef")}} /></label>
              <label class="mg-ev-field"><span>Rights statement received</span><input type="datetime-local" value={{this.newRightsStatementReceivedAt}} {{on "input" (fn this.setField "newRightsStatementReceivedAt")}} /></label>
              <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit" disabled={{this.busy}}>Create case</button></div>
            </form>
          </section>
        </div>
      {{else}}
        <section class="mg-ev-panel">
          <div class="mg-ev-head">
            <div><h2>{{this.selected.case_ref}}</h2><p class="mg-ev-meta">{{this.selected.research_question}}</p></div>
            <div class="mg-ev-actions"><button class="btn btn-default" type="button" {{on "click" this.reloadSelected}}>Refresh</button><button class="btn btn-default" type="button" {{on "click" this.closeCase}}>Back to cases</button></div>
          </div>
          <div class="mg-ev-badges"><span class="mg-ev-badge">{{this.selectedHeader.status_label}}</span><span class="mg-ev-badge">{{this.selectedHeader.decision_label}}</span><span class="mg-ev-badge">{{this.selectedHeader.classification_label}}</span>{{#if this.selected.claimant_confirmed}}<span class="mg-ev-badge is-ok">Claimant confirmed</span>{{/if}}{{#if this.selected.legal_hold}}<span class="mg-ev-badge is-danger">Legal hold</span>{{/if}}</div>
          <div class="mg-ev-meta">Media: {{this.selected.media_title}} ({{this.selected.media_public_id}}) | Claimant: {{this.selected.claimant_ref}} | External: {{this.selected.external_platform}} / {{this.selected.external_username}}</div>
          <div class="mg-ev-meta">Retention review due: {{this.selected.retention_due_at_utc}} (advisory only; no automatic deletion in this release)</div>
          {{#unless this.selectedMutable}}<div class="mg-ev-flash is-success">This case is immutable after package creation. Existing report and package bytes remain downloadable and verifiable.</div>{{/unless}}
        </section>

        <div class="mg-ev-grid">
          <div class="mg-ev-sections">
            <section class="mg-ev-panel">
              <div>
                <h3>Case intake</h3>
                <p class="mg-ev-meta">Record the observation and rights-claim context. These fields are factual inputs, not a legal finding. Material edits invalidate prior approvals.</p>
              </div>
              <form class="mg-ev-form" {{on "submit" this.saveCase}}>
                <label class="mg-ev-field"><span>Claimant reference</span><input required value={{this.editClaimantRef}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editClaimantRef")}} /></label>
                <label class="mg-ev-field"><span>Classification</span><select value={{this.editClassification}} disabled={{not this.selectedMutable}} {{on "change" (fn this.setField "editClassification")}}><option value="confidential">Confidential</option><option value="restricted">Restricted</option></select></label>
                <label class="mg-ev-field is-full"><span>Research question</span><textarea required value={{this.editResearchQuestion}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editResearchQuestion")}}></textarea></label>
                <label class="mg-ev-field"><span>Jurisdiction context</span><input value={{this.editJurisdictionContext}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editJurisdictionContext")}} /></label>
                <label class="mg-ev-field"><span>External platform</span><input value={{this.editExternalPlatform}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editExternalPlatform")}} /></label>
                <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{this.editExternalUrl}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editExternalUrl")}} /></label>
                <label class="mg-ev-field"><span>Visible external username</span><input value={{this.editExternalUsername}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editExternalUsername")}} /></label>
                <label class="mg-ev-field"><span>Observed by staff (local time)</span><input type="datetime-local" value={{this.editExternalObservedAt}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editExternalObservedAt")}} /></label>
                <label class="mg-ev-field"><span>Platform-displayed date/time</span><input value={{this.editExternalDisplayedAt}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editExternalDisplayedAt")}} /></label>
                <label class="mg-ev-field"><span>Rights statement reference</span><input value={{this.editRightsStatementRef}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editRightsStatementRef")}} /></label>
                <label class="mg-ev-field"><span>Rights statement received (local time)</span><input type="datetime-local" value={{this.editRightsStatementReceivedAt}} disabled={{not this.selectedMutable}} {{on "input" (fn this.setField "editRightsStatementReceivedAt")}} /></label>
                <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit" disabled={{or this.busy (not this.selectedMutable)}}>Save case intake</button></div>
              </form>
            </section>

            <section class="mg-ev-panel">
              <h3>Evidence objects</h3>
              <form class="mg-ev-form" {{on "submit" this.uploadObject}}>
                <label class="mg-ev-field"><span>Role</span><select value={{this.uploadRole}} {{on "change" (fn this.setField "uploadRole")}}><option value="external_original">External original</option><option value="working_copy">Working copy</option><option value="source_screenshot">Source screenshot</option><option value="source_html">Source HTML</option><option value="source_warc">Source WARC</option><option value="source_headers">Source headers</option><option value="rights_statement">Rights statement</option><option value="other">Other</option></select></label>
                <label class="mg-ev-field"><span>File</span><input type="file" required {{on "change" this.setUploadFile}} /></label>
                <label class="mg-ev-field is-full"><span>Description</span><input value={{this.uploadDescription}} {{on "input" (fn this.setField "uploadDescription")}} /></label>
                <button class="btn btn-primary" type="submit" disabled={{or this.busy (not this.selectedMutable)}}>Store, hash and freeze</button>
              </form>
              <div class="mg-ev-list">
                {{#each this.selectedObjects as |object|}}
                  <div class="mg-ev-row"><strong>{{object.object_ref}} · {{object.role_label}}</strong><span class="mg-ev-code">SHA-256 {{object.sha256}}</span><span class="mg-ev-meta">{{object.original_filename}} · {{object.size_bytes}} bytes · Quarantine: {{object.quarantine_status_label}}</span>{{#if (or (eq object.role "external_original") (eq object.role "working_copy"))}}<div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not this.selectedMutable}} {{on "click" (fn this.setQuarantine object.object_ref "clean")}}>Mark clean</button><button class="btn btn-danger" type="button" disabled={{not this.selectedMutable}} {{on "click" (fn this.setQuarantine object.object_ref "rejected")}}>Reject</button></div>{{/if}}</div>
                {{else}}<p class="mg-ev-meta">No evidence objects stored yet.</p>{{/each}}
              </div>
            </section>

            <section class="mg-ev-panel">
              <h3>Identify snapshot</h3>
              {{#if this.selectedIdentify}}
                <div class="mg-ev-row"><strong>{{this.selectedIdentify.run_ref}} · {{this.selectedIdentify.decision_label}}</strong><span class="mg-ev-meta">{{this.selectedIdentify.run_kind_label}} · Candidates: {{this.selectedIdentify.candidate_population_count}} · Layout: {{this.selectedIdentify.layout}}</span><span class="mg-ev-code">Raw result SHA-256 {{this.selectedIdentify.raw_result_sha256}}</span><span>Attributed distribution account: {{this.selectedIdentify.attributed_username}} / {{this.selectedIdentify.attributed_account_ref}}</span></div>
              {{else}}<p class="mg-ev-meta">No immutable identify result attached. Create a case directly from a completed Forensics Identify result.</p>{{/if}}
            </section>

            <section class="mg-ev-panel">
              <h3>Review and claimant confirmation</h3>
              {{#unless this.selected.claimant_confirmed}}<div class="mg-ev-row"><strong>Claimant confirmation required</strong><span>Record the rights claimant confirmation before final human approvals; later material changes invalidate earlier approvals.</span><button class="btn btn-default" type="button" disabled={{not this.selectedMutable}} {{on "click" this.confirmClaimant}}>Record claimant confirmation</button></div>{{/unless}}
              <div class="mg-ev-checks">
                {{#each this.reviewChecklistItems as |item|}}
                  <label class="mg-ev-check"><input type="checkbox" checked={{item.checked}} {{on "change" (fn this.setReviewCheck item.key)}} /><span>{{item.label}}</span></label>
                {{/each}}
              </div>
              <label class="mg-ev-field"><span>Internal review reason / notes</span><textarea value={{this.reviewReason}} {{on "input" (fn this.setField "reviewReason")}}></textarea><small class="mg-ev-meta">Free text remains internal. External reports and packages contain only a SHA-256 digest indicating that notes existed.</small></label>
              <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{or (not this.reviewChecklistComplete) (not this.selectedMutable)}} {{on "click" (fn this.addReview "technical" "approved")}}>Approve technical review</button>{{#if this.config.can_finalize}}<button class="btn btn-default" type="button" disabled={{or (not this.reviewChecklistComplete) (not this.selectedMutable)}} {{on "click" (fn this.addReview "senior" "approved")}}>Approve senior review</button><button class="btn btn-default" type="button" disabled={{or (not this.reviewChecklistComplete) (not this.selectedMutable)}} {{on "click" (fn this.addReview "privacy" "approved")}}>Approve privacy review</button>{{/if}}<button class="btn btn-danger" type="button" disabled={{not this.selectedMutable}} {{on "click" (fn this.addReview "technical" "rejected")}}>Reject review</button></div>
              <div class="mg-ev-list">{{#each this.selectedReviews as |review|}}<div class="mg-ev-row"><strong>{{review.review_kind_label}} · {{review.outcome_label}}</strong><span>{{review.reviewer_role_label}} ({{review.reviewer_ref}})</span><span class="mg-ev-meta">{{review.reviewed_at_utc}} · {{review.reason}}</span></div>{{else}}<p class="mg-ev-meta">No reviews recorded.</p>{{/each}}</div>
            </section>
          </div>

          <div class="mg-ev-sections">
            <section class="mg-ev-panel">
              <div class="mg-ev-head"><h3>Finalization policy</h3>{{#if this.selectedFinalization.ready}}<span class="mg-ev-badge is-ok">ready</span>{{else}}<span class="mg-ev-badge is-danger">blocked</span>{{/if}}</div>
              <div class="mg-ev-row"><span>Chain of custody: {{if this.selectedChainOk "verified" "invalid"}}</span></div>
              {{#each this.selectedFinalizationBlockers as |issue|}}<div class="mg-ev-row"><strong>{{issue.title}}</strong><span>{{issue.message}}</span></div>{{/each}}
              {{#each this.selectedFinalizationWarnings as |issue|}}<div class="mg-ev-row"><strong>{{issue.title}}</strong><span>{{issue.message}}</span></div>{{/each}}
            </section>

            <section class="mg-ev-panel">
              <h3>Reports</h3>
              <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not this.selectedMutable}} {{on "click" (fn this.generateReport false)}}>Generate DRAFT PDF</button>{{#if this.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not this.selectedFinalization.ready) (not this.selectedMutable)}} {{on "click" (fn this.generateReport true)}}>Generate final report</button>{{/if}}</div>
              <div class="mg-ev-list">{{#each this.selectedReports as |report|}}<div class="mg-ev-row"><strong>{{report.report_ref}} · {{report.status_label}}</strong><span class="mg-ev-code">PDF {{report.pdf_sha256}}</span><a class="btn btn-default" href={{report.download_url}}>Download PDF</a></div>{{else}}<p class="mg-ev-meta">No reports generated.</p>{{/each}}</div>
            </section>

            <section class="mg-ev-panel">
              <h3>Evidence packages</h3>
              {{#if this.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not this.selectedFinalization.ready) (not this.selectedMutable)}} {{on "click" this.createPackage}}>Generate integrity / CMS package</button>{{/if}}
              <div class="mg-ev-list">{{#each this.selectedPackages as |package|}}<div class="mg-ev-row"><strong>{{package.package_ref}} · {{package.status_label}}</strong><span class="mg-ev-code">Package {{package.package_sha256}}</span><span class="mg-ev-code">Manifest {{package.manifest_sha256}}</span><span class="mg-ev-meta">CMS content signature: {{package.cms_signature_integrity_verified}} · certificate trust: external · Timestamp: {{package.timestamp_status_label}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{package.download_url}}>Download tar.gz</a><button class="btn btn-default" type="button" {{on "click" (fn this.verifyPackage package.package_ref)}}>Verify</button></div></div>{{else}}<p class="mg-ev-meta">No package generated.</p>{{/each}}</div>
            </section>

            {{#if this.config.can_finalize}}<section class="mg-ev-panel"><h3>Legal hold</h3><label class="mg-ev-field"><span>Reason (required)</span><textarea value={{this.holdReason}} {{on "input" (fn this.setField "holdReason")}}></textarea></label><div class="mg-ev-actions">{{#if this.selected.legal_hold}}<button class="btn btn-danger" type="button" {{on "click" (fn this.setLegalHold false)}}>Release legal hold</button>{{else}}<button class="btn btn-danger" type="button" {{on "click" (fn this.setLegalHold true)}}>Place legal hold</button>{{/if}}</div></section>{{/if}}
          </div>
        </div>
      {{/unless}}
    </div>
  </template>
);
