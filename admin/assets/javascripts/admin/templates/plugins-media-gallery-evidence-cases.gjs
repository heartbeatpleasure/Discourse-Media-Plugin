import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq, not, or } from "discourse/truth-helpers";

export default RouteTemplate(
  <template>
    <style>
      .mg-evidence { display: grid; gap: 1rem; --mg-border: var(--primary-low); --mg-muted: var(--primary-medium); --mg-soft: var(--primary-very-low); }
      .mg-evidence h1, .mg-evidence h2, .mg-evidence h3, .mg-evidence h4, .mg-evidence p { margin: 0; }
      .mg-ev-panel { border: 1px solid var(--mg-border); border-radius: 16px; background: var(--secondary); padding: 1rem; display: grid; gap: .9rem; min-width: 0; }
      .mg-ev-hero, .mg-ev-head, .mg-ev-actions { display: flex; gap: .75rem; align-items: center; justify-content: space-between; flex-wrap: wrap; }
      .mg-ev-head.is-start { align-items: flex-start; }
      .mg-ev-actions { justify-content: flex-start; }
      .mg-ev-actions.is-end { justify-content: flex-end; }
      .mg-ev-actions.is-full { grid-column: 1 / -1; }
      .mg-ev-actions .btn { width: auto; max-width: 100%; white-space: normal; }
      .mg-ev-search { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: .75rem; align-items: end; }
      .mg-ev-search input { width: 100%; min-width: 0; height: 40px; box-sizing: border-box; }
      .mg-ev-search .btn { align-self: end; height: 40px; margin: 0; white-space: nowrap; }
      .mg-ev-index-grid { display: grid; grid-template-columns: minmax(320px,.8fr) minmax(440px,1.2fr); gap: 1rem; align-items: start; }
      .mg-ev-form { display: grid; grid-template-columns: repeat(2,minmax(280px,1fr)); gap: .85rem; align-items: start; }
      .mg-ev-form.is-upload { grid-template-columns: minmax(220px,.55fr) minmax(320px,1.45fr); }
      .mg-ev-field { display: grid; gap: .35rem; min-width: 0; align-content: start; }
      .mg-ev-field > span:first-child { font-weight: 600; line-height: 1.25; }
      .mg-ev-field.is-full { grid-column: 1 / -1; }
      .mg-ev-field input, .mg-ev-field textarea, .mg-ev-field select { width: 100%; box-sizing: border-box; min-width: 0; }
      .mg-ev-field input:not([type="file"]), .mg-ev-field select { height: 42px; min-height: 42px; margin: 0; }
      .mg-ev-field input[type="datetime-local"] { height: 42px; min-height: 42px; margin: 0; }
      .mg-ev-field input[type="file"] { min-height: 42px; padding: .45rem; border: 1px solid var(--primary-low-mid); background: var(--secondary); }
      .mg-ev-field textarea { min-height: 110px; resize: vertical; }
      .mg-ev-field textarea.is-large { min-height: 150px; }
      .mg-ev-form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: .75rem; flex-wrap: wrap; padding-top: .85rem; border-top: 1px solid var(--mg-border); }
      .mg-ev-form-actions .btn { width: auto; max-width: 100%; white-space: normal; }
      .mg-ev-list { display: grid; gap: .65rem; }
      .mg-ev-row { border: 1px solid var(--mg-border); border-radius: 12px; padding: .8rem; background: var(--mg-soft); display: grid; gap: .45rem; min-width: 0; }
      .mg-ev-row.is-clickable { cursor: pointer; text-align: left; width: 100%; }
      .mg-ev-row.is-blocker { border-left: 4px solid var(--danger); background: var(--danger-low); }
      .mg-ev-row.is-warning { border-left: 4px solid var(--tertiary); background: var(--highlight-low); }
      .mg-ev-row.is-verified { border-left: 4px solid var(--success); background: var(--success-low); }
      .mg-ev-meta { color: var(--mg-muted); font-size: var(--font-down-1); overflow-wrap: anywhere; }
      .mg-ev-badges { display:flex; gap:.4rem; flex-wrap:wrap; align-items:center; }
      .mg-ev-badge { padding:.2rem .55rem; border:1px solid var(--mg-border); border-radius:999px; font-size:var(--font-down-1); }
      .mg-ev-badge.is-ok { background:var(--success-low); color:var(--success); }
      .mg-ev-badge.is-warn { background:var(--highlight-low); }
      .mg-ev-badge.is-danger { background:var(--danger-low); color:var(--danger); }
      .mg-ev-flash { border-radius:12px; padding:.75rem; border:1px solid var(--mg-border); }
      .mg-ev-flash.is-error { background:var(--danger-low); color:var(--danger); }
      .mg-ev-flash.is-success { background:var(--success-low); color:var(--success); }
      .mg-ev-flash.is-info { background:var(--tertiary-very-low); }
      .mg-ev-code { font-family:var(--d-font-family--monospace); overflow-wrap:anywhere; font-size:var(--font-down-1); }
      .mg-ev-checks { display:grid; grid-template-columns:repeat(2,minmax(260px,1fr)); gap:.65rem 1.25rem; }
      .mg-ev-check { display:flex; gap:.55rem; align-items:flex-start; padding:.55rem .65rem; border:1px solid var(--mg-border); border-radius:10px; background:var(--mg-soft); }
      .mg-ev-check input { margin-top:.2rem; flex:0 0 auto; }
      .mg-ev-case-summary { display:grid; gap:.65rem; }
      .mg-ev-case-title { display:flex; gap:.75rem; align-items:center; flex-wrap:wrap; }
      .mg-ev-case-title h2 { overflow-wrap:anywhere; }
      .mg-ev-summary-line { display:flex; gap:.55rem 1rem; flex-wrap:wrap; color:var(--mg-muted); font-size:var(--font-down-1); }
      .mg-ev-workflow { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:.6rem; padding-bottom:.2rem; }
      .mg-ev-step { border:1px solid var(--mg-border); border-radius:12px; background:var(--secondary); color:var(--primary); padding:.7rem; min-width:155px; display:grid; grid-template-columns:auto 1fr; gap:.6rem; align-items:start; text-align:left; cursor:pointer; }
      .mg-ev-step:hover { background:var(--primary-very-low); }
      .mg-ev-step.is-active { border-color:var(--tertiary); box-shadow:inset 0 0 0 1px var(--tertiary); background:var(--tertiary-very-low); }
      .mg-ev-step-number { display:grid; place-items:center; width:1.7rem; height:1.7rem; border-radius:999px; background:var(--primary-low); font-weight:700; }
      .mg-ev-step.is-complete .mg-ev-step-number { background:var(--success-low); color:var(--success); }
      .mg-ev-step.is-action .mg-ev-step-number { background:var(--danger-low); color:var(--danger); }
      .mg-ev-step.is-progress .mg-ev-step-number, .mg-ev-step.is-attention .mg-ev-step-number { background:var(--highlight-low); }
      .mg-ev-step-copy { display:grid; gap:.2rem; line-height:1.2; }
      .mg-ev-step-copy small { color:var(--mg-muted); }
      .mg-ev-workflow-content { display:grid; gap:1rem; scroll-margin-top:1rem; }
      .mg-ev-section-intro { display:grid; gap:.3rem; max-width:820px; }
      .mg-ev-stat-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:.75rem; }
      .mg-ev-stat { border:1px solid var(--mg-border); border-radius:12px; padding:.85rem; background:var(--mg-soft); display:grid; gap:.3rem; min-width:0; }
      .mg-ev-stat strong { font-size:var(--font-up-1); overflow-wrap:anywhere; }
      .mg-ev-object { border:1px solid var(--mg-border); border-radius:12px; padding:.85rem; background:var(--mg-soft); display:grid; grid-template-columns:minmax(0,1fr) auto; gap:.65rem 1rem; align-items:start; }
      .mg-ev-object-main { display:grid; gap:.4rem; min-width:0; }
      .mg-ev-object-actions { display:flex; gap:.5rem; flex-wrap:wrap; justify-content:flex-end; }
      .mg-ev-object .mg-ev-code { grid-column:1 / -1; }
      .mg-ev-readiness-summary { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }
      .mg-ev-issue-head { display:flex; justify-content:space-between; gap:.75rem; align-items:flex-start; flex-wrap:wrap; }
      .mg-ev-subsection { display:grid; gap:.7rem; }
      .mg-ev-subsection + .mg-ev-subsection { border-top:1px solid var(--mg-border); padding-top:1rem; }
      .mg-ev-report-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:1rem; }
      .mg-ev-action-card { border:1px solid var(--mg-border); border-radius:14px; padding:1rem; background:var(--mg-soft); display:grid; gap:.75rem; align-content:start; }
      .mg-ev-help { padding:.65rem .75rem; border-left:3px solid var(--tertiary); background:var(--tertiary-very-low); color:var(--primary-high); font-size:var(--font-down-1); }
      .mg-ev-help.is-full { grid-column:1 / -1; }
      @media (max-width: 900px) { .mg-ev-index-grid, .mg-ev-form, .mg-ev-form.is-upload, .mg-ev-stat-grid, .mg-ev-report-grid { grid-template-columns:1fr; } .mg-ev-field.is-full, .mg-ev-form-actions { grid-column:auto; } .mg-ev-checks { grid-template-columns:1fr; } }
      @media (max-width: 620px) { .mg-ev-search { grid-template-columns:1fr; } .mg-ev-search .btn { width:100%; } .mg-ev-object { grid-template-columns:1fr; } .mg-ev-object-actions { justify-content:flex-start; } .mg-ev-object .mg-ev-code { grid-column:auto; } .mg-ev-form-actions { justify-content:stretch; } .mg-ev-form-actions .btn { width:100%; } }
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
        <div class="mg-ev-head is-start">
          <div class="mg-ev-section-intro"><h2>Safety profile</h2><p class="mg-ev-meta">Restricted identity annexes are not included in standard exports. External source URLs are recorded manually and are never fetched automatically by the server.</p></div>
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
            <div class="mg-ev-flash is-error">Evidence identity settings are incomplete. Configure both the non-personal issuer name and operator identity before finalization.</div>
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
          <div class="mg-ev-section-intro"><h2>Evidence case details could not be loaded</h2><p class="mg-ev-meta">The case was created as {{@controller.requestedCaseRef}}, but this page could not retrieve its details. The case has not been lost.</p></div>
          <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{@controller.busy}} {{on "click" @controller.retrySelectedCase}}>Retry case loading</button><button class="btn btn-default" type="button" {{on "click" @controller.closeCase}}>Back to case list</button></div>
        </section>
      {{/if}}

      {{#unless @controller.hasSelected}}
        <div class="mg-ev-index-grid">
          <section class="mg-ev-panel">
            <div class="mg-ev-head"><h2>Cases</h2><span class="mg-ev-meta">{{@controller.cases.length}} shown</span></div>
            <form class="mg-ev-search" {{on "submit" @controller.search}}>
              <input type="search" aria-label="Search evidence cases" placeholder="Case, claimant or platform" value={{@controller.query}} {{on "input" (fn @controller.setField "query")}} />
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
            <div class="mg-ev-section-intro"><h2>New evidence case</h2><p class="mg-ev-meta">Create the case first; source capture and acquired evidence are added in the guided workflow. URLs are recorded but never fetched by the server.</p></div>
            <form class="mg-ev-form" {{on "submit" @controller.createCase}}>
              <label class="mg-ev-field"><span>Media public ID</span><input value={{@controller.newMediaPublicId}} {{on "input" (fn @controller.setField "newMediaPublicId")}} /></label>
              <label class="mg-ev-field"><span>Claimant reference</span><input required value={{@controller.newClaimantRef}} {{on "input" (fn @controller.setField "newClaimantRef")}} /></label>
              <label class="mg-ev-field is-full"><span>Research question</span><textarea required value={{@controller.newResearchQuestion}} {{on "input" (fn @controller.setField "newResearchQuestion")}}></textarea></label>
              <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{@controller.newExternalUrl}} {{on "input" (fn @controller.setField "newExternalUrl")}} /></label>
              <label class="mg-ev-field"><span>External platform</span><input value={{@controller.newExternalPlatform}} {{on "input" (fn @controller.setField "newExternalPlatform")}} /></label>
              <label class="mg-ev-field"><span>Visible external username</span><input value={{@controller.newExternalUsername}} {{on "input" (fn @controller.setField "newExternalUsername")}} /></label>
              <label class="mg-ev-field"><span>Rights statement reference</span><input value={{@controller.newRightsStatementRef}} {{on "input" (fn @controller.setField "newRightsStatementRef")}} /></label>
              <label class="mg-ev-field"><span>Rights statement received</span><input type="datetime-local" value={{@controller.newRightsStatementReceivedAt}} {{on "input" (fn @controller.setField "newRightsStatementReceivedAt")}} /></label>
              <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{@controller.busy}}>Create case</button></div>
            </form>
          </section>
        </div>
      {{else}}
        <section class="mg-ev-panel mg-ev-case-summary">
          <div class="mg-ev-head is-start">
            <div class="mg-ev-case-summary">
              <div class="mg-ev-case-title"><h2>{{@controller.selected.case_ref}}</h2><span class="mg-ev-badge is-warn">{{@controller.workflowStatusLabel}}</span></div>
              <div class="mg-ev-summary-line"><span><strong>Media:</strong> {{@controller.selected.media_title}}</span><span><strong>Decision:</strong> {{@controller.selectedHeader.decision_label}}</span><span><strong>Classification:</strong> {{@controller.selectedHeader.classification_label}}</span><span><strong>Claimant:</strong> {{@controller.selected.claimant_ref}}</span></div>
              <div class="mg-ev-summary-line"><span>{{@controller.finalizationBlockerCount}} required action(s)</span><span>{{@controller.finalizationWarningCount}} advisory notice(s)</span><span>Retention review: {{@controller.selected.retention_due_at_utc}}</span></div>
            </div>
            <div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{@controller.busy}} {{on "click" @controller.reloadSelected}}>Refresh</button><button class="btn btn-default" type="button" {{on "click" @controller.closeCase}}>Back to cases</button></div>
          </div>
          <div class="mg-ev-badges"><span class="mg-ev-badge">{{@controller.selectedHeader.status_label}}</span>{{#if @controller.selected.claimant_confirmed}}<span class="mg-ev-badge is-ok">Claimant confirmed</span>{{/if}}{{#if @controller.selected.legal_hold}}<span class="mg-ev-badge is-danger">Legal hold</span>{{/if}}</div>
          {{#unless @controller.selectedMutable}}<div class="mg-ev-flash is-success">This case is immutable after package creation. Existing report and package bytes remain downloadable and verifiable.</div>{{/unless}}
        </section>

        <nav class="mg-ev-workflow" aria-label="Evidence case workflow">
          {{#each @controller.workflowSteps as |step|}}
            <button class={{step.class_name}} type="button" aria-current={{if (eq @controller.activeStep step.key) "step" false}} {{on "click" (fn @controller.selectWorkflowStep step.key)}}>
              <span class="mg-ev-step-number">{{step.number}}</span>
              <span class="mg-ev-step-copy"><strong>{{step.label}}</strong><small>{{step.state_label}}</small></span>
            </button>
          {{/each}}
        </nav>

        <div class="mg-ev-workflow-content">
          {{#if (eq @controller.activeStep "intake")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>1. Case intake</h2><p class="mg-ev-meta">Record the observation, source context and rights-claim details. These are factual inputs, not legal findings. Material edits invalidate previous approvals.</p></div>
              <form class="mg-ev-form" {{on "submit" @controller.saveCase}}>
                <label class="mg-ev-field"><span>Claimant reference</span><input required value={{@controller.editClaimantRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editClaimantRef")}} /></label>
                <label class="mg-ev-field"><span>Classification</span><select value={{@controller.editClassification}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setField "editClassification")}}><option value="confidential">Confidential</option><option value="restricted">Restricted</option></select></label>
                <label class="mg-ev-field is-full"><span>Research question</span><textarea class="is-large" required value={{@controller.editResearchQuestion}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editResearchQuestion")}}></textarea></label>
                <label class="mg-ev-field"><span>Jurisdiction context</span><input value={{@controller.editJurisdictionContext}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editJurisdictionContext")}} /></label>
                <label class="mg-ev-field"><span>External platform</span><input value={{@controller.editExternalPlatform}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalPlatform")}} /></label>
                <label class="mg-ev-field is-full"><span>External URL</span><input type="url" value={{@controller.editExternalUrl}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUrl")}} /></label>
                <label class="mg-ev-field"><span>Visible external username</span><input value={{@controller.editExternalUsername}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUsername")}} /></label>
                <label class="mg-ev-field"><span>Observed by staff (local time)</span><input type="datetime-local" value={{@controller.editExternalObservedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalObservedAt")}} /></label>
                <label class="mg-ev-field"><span>Platform-displayed date/time</span><input value={{@controller.editExternalDisplayedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalDisplayedAt")}} /></label>
                <label class="mg-ev-field"><span>Rights statement received (local time)</span><input type="datetime-local" value={{@controller.editRightsStatementReceivedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementReceivedAt")}} /></label>
                <label class="mg-ev-field is-full"><span>Rights statement reference</span><input value={{@controller.editRightsStatementRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementRef")}} /></label>
                <div class="mg-ev-help is-full">Use an immutable document or record reference. Do not put sensitive identity data in this field.</div>
                <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (not @controller.selectedMutable)}}>Save case intake</button><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "evidence")}}>Continue to evidence acquisition</button></div>
              </form>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "evidence")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>2. Evidence acquisition</h2><p class="mg-ev-meta">Store the acquired external file and supporting source captures. Each object is hashed immediately and frozen as an evidence record.</p></div>
              <form class="mg-ev-form is-upload" {{on "submit" @controller.uploadObject}}>
                <label class="mg-ev-field"><span>Evidence role</span><select value={{@controller.uploadRole}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setField "uploadRole")}}><option value="external_original">External original</option><option value="working_copy">Working copy</option><option value="source_screenshot">Source screenshot</option><option value="source_html">Source HTML</option><option value="source_warc">Source WARC</option><option value="source_headers">Source headers</option><option value="rights_statement">Rights statement</option><option value="other">Other</option></select></label>
                <label class="mg-ev-field"><span>File</span><input type="file" required disabled={{not @controller.selectedMutable}} {{on "change" @controller.setUploadFile}} /></label>
                <label class="mg-ev-field is-full"><span>Description</span><input value={{@controller.uploadDescription}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "uploadDescription")}} /></label>
                <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (not @controller.selectedMutable)}}>Store, hash and freeze evidence</button></div>
              </form>
              <div class="mg-ev-subsection">
                <div class="mg-ev-head"><h3>Stored evidence objects</h3><span class="mg-ev-meta">{{@controller.selectedObjects.length}} object(s)</span></div>
                <div class="mg-ev-list">
                  {{#each @controller.selectedObjects as |object|}}
                    <article class="mg-ev-object">
                      <div class="mg-ev-object-main"><strong>{{object.object_ref}} · {{object.role_label}}</strong><span class="mg-ev-meta">{{object.original_filename}} · {{object.size_bytes}} bytes</span><div class="mg-ev-badges"><span class="mg-ev-badge">Quarantine: {{object.quarantine_status_label}}</span></div></div>
                      {{#if (or (eq object.role "external_original") (eq object.role "working_copy"))}}<div class="mg-ev-object-actions"><button class="btn btn-default" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.setQuarantine object.object_ref "clean")}}>Mark clean</button><button class="btn btn-danger" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.setQuarantine object.object_ref "rejected")}}>Reject</button></div>{{/if}}
                      <span class="mg-ev-code">SHA-256 {{object.sha256}}</span>
                    </article>
                  {{else}}
                    <p class="mg-ev-meta">No evidence objects stored yet. Add at least the acquired external evidence file and either an external URL or a source-capture object.</p>
                  {{/each}}
                </div>
              </div>
              <div class="mg-ev-actions is-end"><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "identify")}}>Continue to identify result</button></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "identify")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>3. Identify result</h2><p class="mg-ev-meta">Review the immutable production snapshot attached by Forensics Identify. Evidence reporting does not modify the detector, scoring policy or candidate ranking.</p></div>
              {{#if @controller.selectedIdentify}}
                <div class="mg-ev-stat-grid">
                  <div class="mg-ev-stat"><span class="mg-ev-meta">Decision</span><strong>{{@controller.selectedIdentify.decision_label}}</strong></div>
                  <div class="mg-ev-stat"><span class="mg-ev-meta">Attributed distribution account</span><strong>{{@controller.selectedIdentify.attributed_username}}</strong><span class="mg-ev-code">{{@controller.selectedIdentify.attributed_account_ref}}</span></div>
                  <div class="mg-ev-stat"><span class="mg-ev-meta">Candidate population</span><strong>{{@controller.selectedIdentify.candidate_population_count}}</strong><span class="mg-ev-meta">{{@controller.selectedIdentify.run_kind_label}} candidates</span></div>
                </div>
                <div class="mg-ev-row is-verified"><strong>Immutable identify snapshot attached</strong><span>Run {{@controller.selectedIdentify.run_ref}} · Layout {{@controller.selectedIdentify.layout}}</span><span class="mg-ev-code">Raw result SHA-256 {{@controller.selectedIdentify.raw_result_sha256}}</span></div>
              {{else}}
                <div class="mg-ev-flash is-error">No immutable identify result is attached. Create the evidence case directly from a completed production Forensics Identify result.</div>
              {{/if}}
              <div class="mg-ev-actions is-end"><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "review")}}>Continue to review and confirmation</button></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "review")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>4. Review & claimant confirmation</h2><p class="mg-ev-meta">Confirm the rights statement and record human review. A conclusive final report requires a Staff Reviewer and a different Senior Staff Reviewer.</p></div>
              <div class="mg-ev-subsection">
                <h3>Claimant confirmation</h3>
                {{#if @controller.selected.claimant_confirmed}}
                  <div class="mg-ev-row is-verified"><strong>Claimant confirmation recorded</strong><span>Material changes after confirmation invalidate previous approvals and require review again.</span></div>
                {{else}}
                  <div class="mg-ev-row"><strong>Confirmation required</strong><span>Save both the rights statement reference and received date in Case intake before recording claimant confirmation.</span><div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not @controller.claimantConfirmationAvailable}} {{on "click" @controller.confirmClaimant}}>Record claimant confirmation</button><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "intake")}}>Go to case intake</button></div></div>
                {{/if}}
              </div>
              <div class="mg-ev-subsection">
                <div class="mg-ev-head"><div><h3>Technical review checklist</h3><p class="mg-ev-meta">Complete every check for each approval action.</p></div>{{#if @controller.reviewChecklistComplete}}<span class="mg-ev-badge is-ok">Checklist complete</span>{{else}}<span class="mg-ev-badge is-warn">Checklist incomplete</span>{{/if}}</div>
                <div class="mg-ev-checks">
                  {{#each @controller.reviewChecklistItems as |item|}}
                    <label class="mg-ev-check"><input type="checkbox" checked={{item.checked}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setReviewCheck item.key)}} /><span>{{item.label}}</span></label>
                  {{/each}}
                </div>
                <label class="mg-ev-field"><span>Internal review reason / notes</span><textarea class="is-large" value={{@controller.reviewReason}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "reviewReason")}}></textarea><small class="mg-ev-meta">Free text remains internal. External reports and packages contain only a SHA-256 digest indicating that notes existed.</small></label>
                <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "technical" "approved")}}>Approve technical review</button>{{#if @controller.config.can_finalize}}<button class="btn btn-default" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "senior" "approved")}}>Approve senior review</button><button class="btn btn-default" type="button" disabled={{or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable)}} {{on "click" (fn @controller.addReview "privacy" "approved")}}>Approve privacy review</button>{{/if}}<button class="btn btn-danger" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.addReview "technical" "rejected")}}>Reject technical review</button></div>
                <div class="mg-ev-help">For a conclusive report, use a second admin account for Senior Staff Review. The same account cannot satisfy both sides of the four-eyes requirement.</div>
              </div>
              <div class="mg-ev-subsection">
                <h3>Recorded reviews</h3>
                <div class="mg-ev-list">{{#each @controller.selectedReviews as |review|}}<div class="mg-ev-row"><strong>{{review.review_kind_label}} · {{review.outcome_label}}</strong><span>{{review.reviewer_role_label}} ({{review.reviewer_ref}})</span><span class="mg-ev-meta">{{review.reviewed_at_utc}} · {{review.reason}}</span></div>{{else}}<p class="mg-ev-meta">No reviews recorded.</p>{{/each}}</div>
              </div>
              <div class="mg-ev-actions is-end"><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "readiness")}}>Check finalization readiness</button></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "readiness")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-head is-start"><div class="mg-ev-section-intro"><h2>5. Finalization readiness</h2><p class="mg-ev-meta">Required actions block finalization. Advisory notices describe known limitations but do not by themselves block a report.</p></div>{{#if @controller.selectedFinalization.ready}}<span class="mg-ev-badge is-ok">Ready</span>{{else}}<span class="mg-ev-badge is-danger">Blocked</span>{{/if}}</div>
              <div class="mg-ev-readiness-summary"><span class="mg-ev-badge is-danger">{{@controller.finalizationBlockerCount}} required</span><span class="mg-ev-badge is-warn">{{@controller.finalizationWarningCount}} advisory</span></div>
              <div class="mg-ev-subsection">
                <h3>Verified safeguards</h3>
                <div class="mg-ev-list"><div class={{if @controller.selectedChainOk "mg-ev-row is-verified" "mg-ev-row is-blocker"}}><strong>Chain of custody</strong><span>{{if @controller.selectedChainOk "The append-only event hash chain verified successfully." "The evidence event hash chain did not verify."}}</span></div>{{#if @controller.selectedIdentify}}<div class="mg-ev-row is-verified"><strong>Immutable identify snapshot</strong><span>Production analysis output is frozen and linked by SHA-256.</span></div>{{/if}}</div>
              </div>
              <div class="mg-ev-subsection">
                <h3>Required before finalization</h3>
                <div class="mg-ev-list">
                  {{#each @controller.selectedFinalizationBlockers as |issue|}}
                    <div class="mg-ev-row is-blocker"><div class="mg-ev-issue-head"><div><strong>{{issue.title}}</strong><div>{{issue.message}}</div></div>{{#unless (eq issue.step "readiness")}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.goToIssue issue)}}>Go to {{issue.step_label}}</button>{{/unless}}</div></div>
                  {{else}}
                    <div class="mg-ev-row is-verified"><strong>All required controls are satisfied</strong><span>The case can proceed to report and package generation.</span></div>
                  {{/each}}
                </div>
              </div>
              <div class="mg-ev-subsection">
                <h3>Advisory notices</h3>
                <div class="mg-ev-list">{{#each @controller.selectedFinalizationWarnings as |issue|}}<div class="mg-ev-row is-warning"><strong>{{issue.title}}</strong><span>{{issue.message}}</span></div>{{else}}<p class="mg-ev-meta">No advisory notices.</p>{{/each}}</div>
              </div>
              <div class="mg-ev-actions is-end"><button class="btn btn-primary" type="button" disabled={{not @controller.selectedFinalization.ready}} {{on "click" (fn @controller.selectWorkflowStep "reports")}}>Continue to reports and packages</button></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "reports")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>6. Reports & packages</h2><p class="mg-ev-meta">Generate a reviewable draft at any time. Final reports and integrity/CMS packages remain blocked until all required controls are satisfied.</p></div>
              <div class="mg-ev-report-grid">
                <div class="mg-ev-action-card"><h3>Technical Evidence Report</h3><p class="mg-ev-meta">The English report contains the research question, evidence hashes, identify method, controlled conclusion and mandatory limitations.</p><div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{not @controller.selectedMutable}} {{on "click" (fn @controller.generateReport false)}}>Generate DRAFT PDF</button>{{#if @controller.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" (fn @controller.generateReport true)}}>Generate final report</button>{{/if}}</div></div>
                <div class="mg-ev-action-card"><h3>Sealed Evidence Package</h3><p class="mg-ev-meta">Creates a manifest, checksums, technical artefacts and the configured integrity or CMS protection.</p>{{#if @controller.config.can_finalize}}<div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" @controller.createPackage}}>Generate integrity / CMS package</button></div>{{/if}}</div>
              </div>
              <div class="mg-ev-subsection"><h3>Generated reports</h3><div class="mg-ev-list">{{#each @controller.selectedReports as |report|}}<div class="mg-ev-row"><strong>{{report.report_ref}} · {{report.status_label}}</strong><span class="mg-ev-code">PDF SHA-256 {{report.pdf_sha256}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{report.download_url}}>Download PDF</a></div></div>{{else}}<p class="mg-ev-meta">No reports generated.</p>{{/each}}</div></div>
              <div class="mg-ev-subsection"><h3>Generated packages</h3><div class="mg-ev-list">{{#each @controller.selectedPackages as |package|}}<div class="mg-ev-row"><strong>{{package.package_ref}} · {{package.status_label}}</strong><span class="mg-ev-code">Package SHA-256 {{package.package_sha256}}</span><span class="mg-ev-code">Manifest SHA-256 {{package.manifest_sha256}}</span><span class="mg-ev-meta">CMS content signature: {{package.cms_signature_integrity_label}} · Certificate trust: external · Timestamp: {{package.timestamp_status_label}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{package.download_url}}>Download tar.gz</a><button class="btn btn-default" type="button" {{on "click" (fn @controller.verifyPackage package.package_ref)}}>Verify package</button></div></div>{{else}}<p class="mg-ev-meta">No package generated.</p>{{/each}}</div></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "administration")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>7. Case administration</h2><p class="mg-ev-meta">Retention and legal hold controls are administrative safeguards. They do not change the forensic identify result.</p></div>
              <div class="mg-ev-stat-grid"><div class="mg-ev-stat"><span class="mg-ev-meta">Retention review due</span><strong>{{@controller.selected.retention_due_at_utc}}</strong><span class="mg-ev-meta">Advisory only; no automatic deletion in this release.</span></div><div class="mg-ev-stat"><span class="mg-ev-meta">Legal hold</span><strong>{{if @controller.selected.legal_hold "Active" "Not active"}}</strong></div><div class="mg-ev-stat"><span class="mg-ev-meta">Case mutability</span><strong>{{if @controller.selectedMutable "Mutable" "Immutable"}}</strong></div></div>
              {{#if @controller.config.can_finalize}}<div class="mg-ev-subsection"><h3>Legal hold</h3><label class="mg-ev-field"><span>Reason (required)</span><textarea class="is-large" value={{@controller.holdReason}} {{on "input" (fn @controller.setField "holdReason")}}></textarea></label><div class="mg-ev-actions">{{#if @controller.selected.legal_hold}}<button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold false)}}>Release legal hold</button>{{else}}<button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold true)}}>Place legal hold</button>{{/if}}</div></div>{{/if}}
            </section>
          {{/if}}
        </div>
      {{/unless}}
    </div>
  </template>
);
