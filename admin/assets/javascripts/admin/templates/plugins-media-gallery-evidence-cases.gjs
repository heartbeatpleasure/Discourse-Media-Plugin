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
      .mg-ev-field-label, .mg-ev-title-with-help, .mg-ev-stat-label { display: flex; align-items: center; gap: .4rem; min-width: 0; }
      .mg-ev-field-label { justify-content: space-between; }
      .mg-ev-field-label label, .mg-ev-field-label > span:first-child { font-weight: 600; line-height: 1.25; }
      .mg-ev-title-with-help h2, .mg-ev-title-with-help h3, .mg-ev-stat-label span { min-width: 0; }
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
      .mg-ev-step.is-progress .mg-ev-step-number, .mg-ev-step.is-attention .mg-ev-step-number, .mg-ev-step.is-ready .mg-ev-step-number { background:var(--highlight-low); }
      .mg-ev-step-copy { display:grid; gap:.2rem; line-height:1.2; }
      .mg-ev-step-copy small { color:var(--mg-muted); }
      .mg-ev-workflow-content { display:grid; gap:1rem; scroll-margin-top:1rem; }
      .mg-ev-section-intro { display:grid; gap:.3rem; max-width:820px; }
      .mg-ev-stat-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:.75rem; }
      .mg-ev-security-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:.75rem; }
      .mg-ev-security-card { border:1px solid var(--mg-border); border-radius:12px; padding:.8rem; background:var(--mg-soft); display:grid; gap:.3rem; min-width:0; }
      .mg-ev-object-details { display:grid; gap:.25rem; font-size:var(--font-down-1); color:var(--mg-muted); }
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
      .mg-ev-release-link { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:.65rem; align-items:end; padding:.85rem; border:1px solid var(--success); border-radius:12px; background:var(--success-low); }
      .mg-ev-release-link input { width:100%; box-sizing:border-box; font-family:var(--d-font-family--monospace); }
      .mg-ev-lifecycle-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:1rem; }
      .mg-ev-help { padding:.65rem .75rem; border-left:3px solid var(--tertiary); background:var(--tertiary-very-low); color:var(--primary-high); font-size:var(--font-down-1); }
      .mg-ev-help.is-full { grid-column:1 / -1; }
      .mg-ev-info { position:relative; z-index:1; display:inline-flex; align-items:center; justify-content:center; width:1.35rem; height:1.35rem; min-width:1.35rem; min-height:1.35rem; box-sizing:border-box; padding:0; margin:0; border-radius:999px; border:1px solid var(--primary-low-mid, currentColor); background:var(--primary-very-low, transparent); color:var(--primary-high, currentColor); font-family:Arial, sans-serif; font-size:var(--font-down-1, .875rem); font-weight:700; font-style:normal; line-height:1; cursor:help; box-shadow:none; flex:0 0 auto; user-select:none; }
      .mg-ev-info:hover, .mg-ev-info:focus-visible, .mg-ev-info[aria-expanded="true"] { border-color:var(--tertiary, currentColor); background:var(--tertiary-low, var(--primary-low)); color:var(--tertiary, currentColor); outline:none; }
      .mg-ev-info:focus-visible { outline:2px solid var(--tertiary, currentColor); outline-offset:2px; }
      .mg-ev-check { justify-content:space-between; }
      .mg-ev-check > label { display:flex; gap:.55rem; align-items:flex-start; min-width:0; flex:1 1 auto; cursor:pointer; }
      .mg-ev-check > label input { margin-top:.2rem; }
      .mg-ev-help-backdrop { position:fixed; inset:0; z-index:19998; border:0; padding:0; margin:0; background:transparent; cursor:default; }
      .mg-ev-help-popover { position:fixed; z-index:19999; overflow:auto; border:1px solid var(--primary-low-mid); border-radius:14px; background:var(--secondary); color:var(--primary); box-shadow:0 14px 42px rgba(0,0,0,.28); padding:.9rem; display:grid; gap:.8rem; overscroll-behavior:contain; }
      .mg-ev-help-popover-header { display:flex; align-items:flex-start; justify-content:space-between; gap:.75rem; position:sticky; top:-.9rem; margin:-.9rem -.9rem 0; padding:.9rem .9rem .65rem; background:var(--secondary); border-bottom:1px solid var(--primary-low); z-index:1; }
      .mg-ev-help-popover-header > div { display:grid; gap:.15rem; min-width:0; }
      .mg-ev-help-popover-kicker { color:var(--tertiary); font-size:var(--font-down-1); font-weight:700; text-transform:uppercase; letter-spacing:.04em; }
      .mg-ev-help-popover-close { display:grid; place-items:center; width:1.8rem; height:1.8rem; min-width:1.8rem; padding:0; border:0; border-radius:999px; background:var(--primary-very-low); color:var(--primary); font-size:1.25rem; line-height:1; cursor:pointer; }
      .mg-ev-help-popover-close:hover, .mg-ev-help-popover-close:focus-visible { background:var(--primary-low); outline:2px solid var(--tertiary); outline-offset:1px; }
      .mg-ev-help-popover-body { display:grid; gap:.7rem; }
      .mg-ev-help-popover-section { display:grid; gap:.2rem; }
      .mg-ev-help-popover-section strong { font-size:var(--font-down-1); color:var(--primary-high); }
      .mg-ev-help-popover-example, .mg-ev-help-popover-note { padding:.6rem .7rem; border-radius:10px; background:var(--primary-very-low); overflow-wrap:anywhere; }
      .mg-ev-help-popover-note { border-left:3px solid var(--tertiary); }
      @media (max-width: 900px) { .mg-ev-index-grid, .mg-ev-form, .mg-ev-form.is-upload, .mg-ev-stat-grid, .mg-ev-security-grid, .mg-ev-report-grid, .mg-ev-lifecycle-grid { grid-template-columns:1fr; } .mg-ev-field.is-full, .mg-ev-form-actions { grid-column:auto; } .mg-ev-checks { grid-template-columns:1fr; } }
      @media (max-width: 620px) { .mg-ev-search, .mg-ev-release-link { grid-template-columns:1fr; } .mg-ev-release-link .btn { width:100%; } .mg-ev-search .btn { width:100%; } .mg-ev-object { grid-template-columns:1fr; } .mg-ev-object-actions { justify-content:flex-start; } .mg-ev-object .mg-ev-code { grid-column:auto; } .mg-ev-form-actions { justify-content:stretch; } .mg-ev-form-actions .btn { width:100%; } }
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
          <div class="mg-ev-section-intro"><div class="mg-ev-title-with-help"><h2>Safety profile</h2><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Safety profile" aria-expanded={{eq @controller.activeHelpKey "safety_profile"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "safety_profile")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "safety_profile")}}>i</span></div><p class="mg-ev-meta">Restricted identity annexes are not included in standard exports. External source URLs are recorded manually and are never fetched automatically by the server.</p></div>
          {{#if @controller.configLoaded}}
            <div class="mg-ev-badges">
              <span class="mg-ev-badge">Report language: {{@controller.reportLanguageLabel}}</span>
              <span class="mg-ev-badge">Package protection: {{@controller.sealModeLabel}}</span>
              <span class="mg-ev-badge">Trusted timestamp: {{@controller.timestampLabel}}</span>
              <span class="mg-ev-badge">Release transport: {{@controller.releaseTransportLabel}}</span>
            </div>
          {{else}}
            <span class="mg-ev-badge is-danger">Configuration unavailable</span>
          {{/if}}
        </div>
        {{#if @controller.configLoaded}}
          {{#unless @controller.releaseTransportReady}}<div class="mg-ev-flash is-error">Controlled package release is blocked until the configured site URL uses HTTPS. An explicit insecure test-only override is available for isolated test environments, but must remain disabled in production.</div>{{/unless}}
          {{#if @controller.hasIssuerIdentity}}
            <div class="mg-ev-meta"><strong>Issuer:</strong> {{@controller.issuerName}}{{#if @controller.hasOperatorIdentity}} &nbsp;|&nbsp; <strong>Operator:</strong> {{@controller.operatorIdentity}}{{/if}}</div>
          {{else}}
            <div class="mg-ev-flash is-error">Configure a non-personal evidence issuer name before finalization. Operator identity remains optional and is omitted when blank.</div>
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
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-media-public-id">Media public ID</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Media public ID" aria-expanded={{eq @controller.activeHelpKey "media_public_id"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "media_public_id")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "media_public_id")}}>i</span></div><input id="mg-ev-new-media-public-id" value={{@controller.newMediaPublicId}} {{on "input" (fn @controller.setField "newMediaPublicId")}} /></div>
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-claimant-ref">Claimant reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Claimant reference" aria-expanded={{eq @controller.activeHelpKey "claimant_reference"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "claimant_reference")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "claimant_reference")}}>i</span></div><input id="mg-ev-new-claimant-ref" required value={{@controller.newClaimantRef}} {{on "input" (fn @controller.setField "newClaimantRef")}} /></div>
              <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-new-research-question">Research question</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Research question" aria-expanded={{eq @controller.activeHelpKey "research_question"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "research_question")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "research_question")}}>i</span></div><textarea id="mg-ev-new-research-question" required value={{@controller.newResearchQuestion}} {{on "input" (fn @controller.setField "newResearchQuestion")}}></textarea></div>
              <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-new-external-url">External URL</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for External URL" aria-expanded={{eq @controller.activeHelpKey "external_url"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_url")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_url")}}>i</span></div><input id="mg-ev-new-external-url" type="url" value={{@controller.newExternalUrl}} {{on "input" (fn @controller.setField "newExternalUrl")}} /></div>
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-external-platform">External platform</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for External platform" aria-expanded={{eq @controller.activeHelpKey "external_platform"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_platform")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_platform")}}>i</span></div><input id="mg-ev-new-external-platform" value={{@controller.newExternalPlatform}} {{on "input" (fn @controller.setField "newExternalPlatform")}} /></div>
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-external-username">Visible external username</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Visible external username" aria-expanded={{eq @controller.activeHelpKey "external_username"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_username")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_username")}}>i</span></div><input id="mg-ev-new-external-username" value={{@controller.newExternalUsername}} {{on "input" (fn @controller.setField "newExternalUsername")}} /></div>
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-rights-statement-ref">Rights statement reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Rights statement reference" aria-expanded={{eq @controller.activeHelpKey "rights_statement_reference"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "rights_statement_reference")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "rights_statement_reference")}}>i</span></div><input id="mg-ev-new-rights-statement-ref" value={{@controller.newRightsStatementRef}} {{on "input" (fn @controller.setField "newRightsStatementRef")}} /></div>
              <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-new-rights-statement-received">Rights statement received (local time)</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Rights statement received" aria-expanded={{eq @controller.activeHelpKey "rights_statement_received"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "rights_statement_received")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "rights_statement_received")}}>i</span></div><input id="mg-ev-new-rights-statement-received" type="datetime-local" value={{@controller.newRightsStatementReceivedAt}} {{on "input" (fn @controller.setField "newRightsStatementReceivedAt")}} /></div>
              <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (not @controller.canOperateCases)}}>Create case</button></div>
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
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-claimant-ref">Claimant reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Claimant reference" aria-expanded={{eq @controller.activeHelpKey "claimant_reference"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "claimant_reference")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "claimant_reference")}}>i</span></div><input id="mg-ev-edit-claimant-ref" required value={{@controller.editClaimantRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editClaimantRef")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-classification">Classification</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Classification" aria-expanded={{eq @controller.activeHelpKey "classification"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "classification")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "classification")}}>i</span></div><select id="mg-ev-edit-classification" value={{@controller.editClassification}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setField "editClassification")}}><option value="confidential">Confidential</option><option value="restricted">Restricted</option></select></div>
                <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-edit-research-question">Research question</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Research question" aria-expanded={{eq @controller.activeHelpKey "research_question"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "research_question")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "research_question")}}>i</span></div><textarea id="mg-ev-edit-research-question" class="is-large" required value={{@controller.editResearchQuestion}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editResearchQuestion")}}></textarea></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-jurisdiction">Jurisdiction context</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Jurisdiction context" aria-expanded={{eq @controller.activeHelpKey "jurisdiction_context"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "jurisdiction_context")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "jurisdiction_context")}}>i</span></div><input id="mg-ev-edit-jurisdiction" value={{@controller.editJurisdictionContext}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editJurisdictionContext")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-external-platform">External platform</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for External platform" aria-expanded={{eq @controller.activeHelpKey "external_platform"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_platform")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_platform")}}>i</span></div><input id="mg-ev-edit-external-platform" value={{@controller.editExternalPlatform}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalPlatform")}} /></div>
                <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-edit-external-url">External URL</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for External URL" aria-expanded={{eq @controller.activeHelpKey "external_url"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_url")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_url")}}>i</span></div><input id="mg-ev-edit-external-url" type="url" value={{@controller.editExternalUrl}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUrl")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-external-username">Visible external username</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Visible external username" aria-expanded={{eq @controller.activeHelpKey "external_username"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "external_username")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "external_username")}}>i</span></div><input id="mg-ev-edit-external-username" value={{@controller.editExternalUsername}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalUsername")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-observed-at">Observed by staff (local time)</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Observed by staff" aria-expanded={{eq @controller.activeHelpKey "observed_by_staff"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "observed_by_staff")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "observed_by_staff")}}>i</span></div><input id="mg-ev-edit-observed-at" type="datetime-local" value={{@controller.editExternalObservedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalObservedAt")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-platform-time">Platform-displayed date/time</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Platform-displayed date and time" aria-expanded={{eq @controller.activeHelpKey "platform_displayed_datetime"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "platform_displayed_datetime")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "platform_displayed_datetime")}}>i</span></div><input id="mg-ev-edit-platform-time" value={{@controller.editExternalDisplayedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editExternalDisplayedAt")}} /></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-edit-rights-received">Rights statement received (local time)</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Rights statement received" aria-expanded={{eq @controller.activeHelpKey "rights_statement_received"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "rights_statement_received")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "rights_statement_received")}}>i</span></div><input id="mg-ev-edit-rights-received" type="datetime-local" value={{@controller.editRightsStatementReceivedAt}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementReceivedAt")}} /></div>
                <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-edit-rights-ref">Rights statement reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Rights statement reference" aria-expanded={{eq @controller.activeHelpKey "rights_statement_reference"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "rights_statement_reference")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "rights_statement_reference")}}>i</span></div><input id="mg-ev-edit-rights-ref" value={{@controller.editRightsStatementRef}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "editRightsStatementRef")}} /></div>
                <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (or (not @controller.selectedMutable) (not @controller.canOperateCases))}}>Save case intake</button><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "evidence")}}>Continue to evidence acquisition</button></div>
              </form>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "evidence")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><h2>2. Evidence acquisition</h2><p class="mg-ev-meta">Store the acquired external file and supporting source captures. Each object is hashed immediately and frozen as an evidence record.</p></div>
              <div class="mg-ev-subsection">
                <div class="mg-ev-title-with-help"><h3>Acquisition security</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for acquisition security" aria-expanded={{eq @controller.activeHelpKey "acquisition_security"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "acquisition_security")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "acquisition_security")}}>i</span></div>
                <div class="mg-ev-security-grid">
                  <div class="mg-ev-security-card">
                    <div class="mg-ev-title-with-help"><span class="mg-ev-meta">Malware scanner</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for malware scan status" aria-expanded={{eq @controller.activeHelpKey "malware_scan_status"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "malware_scan_status")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "malware_scan_status")}}>i</span></div>
                    <strong>{{@controller.scannerHealthLabel}}</strong>
                    {{#if @controller.scannerHealth.version}}<span class="mg-ev-meta">{{@controller.scannerHealth.version}}</span>{{/if}}
                  </div>
                  <div class="mg-ev-security-card">
                    <div class="mg-ev-title-with-help"><span class="mg-ev-meta">Technical inspection</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for technical inspection status" aria-expanded={{eq @controller.activeHelpKey "technical_inspection_status"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "technical_inspection_status")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "technical_inspection_status")}}>i</span></div>
                    <strong>{{@controller.inspectorHealthLabel}}</strong>
                    {{#if @controller.inspectorHealth.version}}<span class="mg-ev-meta">{{@controller.inspectorHealth.version}}</span>{{/if}}
                  </div>
                  <div class="mg-ev-security-card">
                    <div class="mg-ev-title-with-help"><span class="mg-ev-meta">Private evidence storage</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for private evidence storage" aria-expanded={{eq @controller.activeHelpKey "acquisition_security"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "acquisition_security")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "acquisition_security")}}>i</span></div>
                    <strong>{{@controller.storageHealthLabel}}</strong>
                    {{#if @controller.storageHealth.minimum_free_bytes}}<span class="mg-ev-meta">Reserve: {{@controller.storageReserveLabel}}</span>{{/if}}
                  </div>
                </div>
                {{#unless @controller.config.malware_scanner_enabled}}<div class="mg-ev-flash is-info">Automatic malware scanning is optional and currently disabled. Evidence is still hashed and inspected, but staff must record a manual quarantine decision before finalisation.</div>{{/unless}}
              </div>
              <form class="mg-ev-form is-upload" {{on "submit" @controller.uploadObject}}>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-upload-role">Evidence role</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Evidence role" aria-expanded={{eq @controller.activeHelpKey "evidence_role"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "evidence_role")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "evidence_role")}}>i</span></div><select id="mg-ev-upload-role" value={{@controller.uploadRole}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setField "uploadRole")}}><option value="external_original">External original</option><option value="working_copy">Working copy</option><option value="source_screenshot">Source screenshot</option><option value="source_html">Source HTML</option><option value="source_warc">Source WARC</option><option value="source_headers">Source headers</option><option value="rights_statement">Rights statement</option><option value="other">Other</option></select></div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-upload-file">File</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Evidence file" aria-expanded={{eq @controller.activeHelpKey "evidence_file"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "evidence_file")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "evidence_file")}}>i</span></div><input id="mg-ev-upload-file" type="file" required disabled={{not @controller.selectedMutable}} {{on "change" @controller.setUploadFile}} /></div>
                <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-upload-description">Description</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Evidence description" aria-expanded={{eq @controller.activeHelpKey "evidence_description"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "evidence_description")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "evidence_description")}}>i</span></div><input id="mg-ev-upload-description" value={{@controller.uploadDescription}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "uploadDescription")}} /></div>
                <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{or @controller.busy (or (not @controller.selectedMutable) (not @controller.canOperateCases))}}>Store, hash and freeze evidence</button></div>
              </form>
              <div class="mg-ev-subsection">
                <div class="mg-ev-head"><div class="mg-ev-title-with-help"><h3>Stored evidence objects</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Stored evidence objects" aria-expanded={{eq @controller.activeHelpKey "stored_evidence_objects"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "stored_evidence_objects")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "stored_evidence_objects")}}>i</span></div><span class="mg-ev-meta">{{@controller.selectedObjects.length}} object(s)</span></div>
                <div class="mg-ev-list">
                  {{#each @controller.selectedObjects as |object|}}
                    <article class="mg-ev-object">
                      <div class="mg-ev-object-main">
                        <strong>{{object.object_ref}} · {{object.role_label}}</strong>
                        <span class="mg-ev-meta">{{object.original_filename}} · {{object.size_bytes}} bytes</span>
                        <div class="mg-ev-badges">
                          <span class="mg-ev-badge">Quarantine: {{object.quarantine_status_label}}</span>
                          <span class="mg-ev-badge">Malware scan: {{object.scan_state_label}}</span>
                          <span class="mg-ev-badge">Inspection: {{object.inspection_state_label}}</span>
                        </div>
                        <div class="mg-ev-object-details">
                          {{#if object.scan_signature}}<span>Detection: {{object.scan_signature}}</span>{{/if}}
                          {{#if object.inspection_message}}<span>{{object.inspection_message}}</span>{{/if}}
                          {{#if object.inspection_warnings}}<span>{{object.inspection_warnings}}</span>{{/if}}
                        </div>
                      </div>
                      <div class="mg-ev-object-actions">
                        {{#if object.can_rescan}}<button class="btn btn-default" type="button" disabled={{or @controller.busy (or (not @controller.selectedMutable) (not @controller.canOperateCases))}} {{on "click" (fn @controller.rescanObject object.object_ref)}}>Run security checks</button>{{/if}}
                        {{#if object.can_manual_review}}
                          {{#if object.can_mark_clean}}<button class="btn btn-default" type="button" disabled={{or @controller.busy (or (not @controller.selectedMutable) (not @controller.canOperateCases))}} {{on "click" (fn @controller.setQuarantine object.object_ref "clean")}}>Record manual clean review</button>{{/if}}
                          <button class="btn btn-danger" type="button" disabled={{or @controller.busy (or (not @controller.selectedMutable) (not @controller.canOperateCases))}} {{on "click" (fn @controller.setQuarantine object.object_ref "rejected")}}>Reject</button>
                        {{/if}}
                      </div>
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
                  <div class="mg-ev-stat"><div class="mg-ev-stat-label"><span class="mg-ev-meta">Decision</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Identify decision" aria-expanded={{eq @controller.activeHelpKey "identify_decision"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "identify_decision")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "identify_decision")}}>i</span></div><strong>{{@controller.selectedIdentify.decision_label}}</strong></div>
                  <div class="mg-ev-stat"><div class="mg-ev-stat-label"><span class="mg-ev-meta">Attributed distribution account</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Attributed distribution account" aria-expanded={{eq @controller.activeHelpKey "attributed_account"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "attributed_account")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "attributed_account")}}>i</span></div><strong>{{@controller.selectedIdentify.attributed_username}}</strong><span class="mg-ev-code">{{@controller.selectedIdentify.attributed_account_ref}}</span></div>
                  <div class="mg-ev-stat"><div class="mg-ev-stat-label"><span class="mg-ev-meta">Candidate population</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Candidate population" aria-expanded={{eq @controller.activeHelpKey "candidate_population"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "candidate_population")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "candidate_population")}}>i</span></div><strong>{{@controller.selectedIdentify.candidate_population_count}}</strong><span class="mg-ev-meta">{{@controller.selectedIdentify.run_kind_label}} candidates</span></div>
                </div>
                <div class="mg-ev-row is-verified"><div class="mg-ev-title-with-help"><strong>Immutable identify snapshot attached</strong><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Immutable identify snapshot" aria-expanded={{eq @controller.activeHelpKey "identify_snapshot"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "identify_snapshot")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "identify_snapshot")}}>i</span></div><span>Run {{@controller.selectedIdentify.run_ref}} · Layout {{@controller.selectedIdentify.layout}}</span><span class="mg-ev-code">Raw result SHA-256 {{@controller.selectedIdentify.raw_result_sha256}}</span></div>
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
                <div class="mg-ev-title-with-help"><h3>Claimant confirmation</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Claimant confirmation" aria-expanded={{eq @controller.activeHelpKey "claimant_confirmation"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "claimant_confirmation")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "claimant_confirmation")}}>i</span></div>
                {{#if @controller.selected.claimant_confirmed}}
                  <div class="mg-ev-row is-verified"><strong>Claimant confirmation recorded</strong><span>Material changes after confirmation invalidate previous approvals and require review again.</span></div>
                {{else}}
                  <div class="mg-ev-row"><strong>Confirmation required</strong><span>Save both the rights statement reference and received date in Case intake before recording claimant confirmation.</span><div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{or (not @controller.claimantConfirmationAvailable) (not @controller.canOperateCases)}} {{on "click" @controller.confirmClaimant}}>Record claimant confirmation</button><button class="btn btn-default" type="button" {{on "click" (fn @controller.selectWorkflowStep "intake")}}>Go to case intake</button></div></div>
                {{/if}}
              </div>
              <div class="mg-ev-subsection">
                <div class="mg-ev-head"><div><div class="mg-ev-title-with-help"><h3>Technical review checklist</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Technical review checklist" aria-expanded={{eq @controller.activeHelpKey "technical_review_checklist"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "technical_review_checklist")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "technical_review_checklist")}}>i</span></div><p class="mg-ev-meta">Complete every check for each approval action.</p></div>{{#if @controller.reviewChecklistComplete}}<span class="mg-ev-badge is-ok">Checklist complete</span>{{else}}<span class="mg-ev-badge is-warn">Checklist incomplete</span>{{/if}}</div>
                <div class="mg-ev-checks">
                  {{#each @controller.reviewChecklistItems as |item|}}
                    <div class="mg-ev-check"><label><input type="checkbox" checked={{item.checked}} disabled={{not @controller.selectedMutable}} {{on "change" (fn @controller.setReviewCheck item.key)}} /><span>{{item.label}}</span></label><span class="mg-ev-info" role="button" tabindex="0" aria-label={{item.help_label}} aria-expanded={{eq @controller.activeHelpKey item.help_key}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp item.help_key)}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown item.help_key)}}>i</span></div>
                  {{/each}}
                </div>
                <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-review-notes">Internal review reason / notes</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Internal review notes" aria-expanded={{eq @controller.activeHelpKey "internal_review_notes"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "internal_review_notes")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "internal_review_notes")}}>i</span></div><textarea id="mg-ev-review-notes" class="is-large" value={{@controller.reviewReason}} disabled={{not @controller.selectedMutable}} {{on "input" (fn @controller.setField "reviewReason")}}></textarea><small class="mg-ev-meta">Free text remains internal. External reports and packages contain only a SHA-256 digest indicating that notes existed.</small></div>
                <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{or (not @controller.canReviewTechnically) (or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable))}} {{on "click" (fn @controller.addReview "technical" "approved")}}>Approve technical review</button>{{#if @controller.config.can_finalize}}<button class="btn btn-default" type="button" disabled={{or (not @controller.canReviewSenior) (or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable))}} {{on "click" (fn @controller.addReview "senior" "approved")}}>Approve senior review</button><button class="btn btn-default" type="button" disabled={{or (not @controller.canAccessRestrictedAnnex) (or (not @controller.reviewChecklistComplete) (not @controller.selectedMutable))}} {{on "click" (fn @controller.addReview "privacy" "approved")}}>Approve privacy review</button>{{/if}}<button class="btn btn-danger" type="button" disabled={{or (not @controller.selectedMutable) (not @controller.canReviewTechnically)}} {{on "click" (fn @controller.addReview "technical" "rejected")}}>Reject technical review</button></div>
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
              <div class="mg-ev-head is-start"><div class="mg-ev-section-intro"><div class="mg-ev-title-with-help"><h2>5. Finalization readiness</h2><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Finalization readiness" aria-expanded={{eq @controller.activeHelpKey "finalization_readiness"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "finalization_readiness")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "finalization_readiness")}}>i</span></div><p class="mg-ev-meta">Required actions block finalization. Advisory notices describe known limitations but do not by themselves block a report.</p></div>{{#if @controller.selectedFinalization.ready}}<span class="mg-ev-badge is-ok">Ready</span>{{else}}<span class="mg-ev-badge is-danger">Blocked</span>{{/if}}</div>
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
                <div class="mg-ev-action-card"><div class="mg-ev-title-with-help"><h3>Technical Evidence Report</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Technical Evidence Report" aria-expanded={{eq @controller.activeHelpKey "technical_evidence_report"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "technical_evidence_report")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "technical_evidence_report")}}>i</span></div><p class="mg-ev-meta">The English report contains the research question, evidence hashes, identify method, controlled conclusion and mandatory limitations.</p><div class="mg-ev-actions"><button class="btn btn-default" type="button" disabled={{or (not @controller.selectedMutable) (not @controller.canReviewTechnically)}} {{on "click" (fn @controller.generateReport false)}}>Generate DRAFT PDF</button>{{#if @controller.config.can_finalize}}<button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" (fn @controller.generateReport true)}}>Generate final report</button>{{/if}}</div></div>
                <div class="mg-ev-action-card"><div class="mg-ev-title-with-help"><h3>Sealed Evidence Package</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Sealed Evidence Package" aria-expanded={{eq @controller.activeHelpKey "sealed_evidence_package"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "sealed_evidence_package")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "sealed_evidence_package")}}>i</span></div><p class="mg-ev-meta">Creates a manifest, checksums, technical artefacts and the configured integrity or CMS protection.</p>{{#if @controller.config.can_finalize}}<div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{or (not @controller.selectedFinalization.ready) (not @controller.selectedMutable)}} {{on "click" @controller.createPackage}}>Generate integrity / CMS package</button></div>{{/if}}</div>
              </div>
              <div class="mg-ev-subsection"><h3>Generated reports</h3><div class="mg-ev-list">{{#each @controller.selectedReports as |report|}}<div class="mg-ev-row"><strong>{{report.report_ref}} · {{report.status_label}}</strong><span class="mg-ev-code">PDF SHA-256 {{report.pdf_sha256}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{report.download_url}}>Download PDF</a></div></div>{{else}}<p class="mg-ev-meta">No reports generated.</p>{{/each}}</div></div>
              <div class="mg-ev-subsection"><h3>Generated packages</h3><div class="mg-ev-list">{{#each @controller.selectedPackages as |package|}}<div class="mg-ev-row"><strong>{{package.package_ref}} · {{package.status_label}}</strong><span class="mg-ev-code">Package SHA-256 {{package.package_sha256}}</span><span class="mg-ev-code">Manifest SHA-256 {{package.manifest_sha256}}</span><span class="mg-ev-meta">CMS content signature: {{package.cms_signature_integrity_label}} · Certificate trust: external · Timestamp: {{package.timestamp_status_label}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{package.download_url}}>Download tar.gz</a><button class="btn btn-default" type="button" {{on "click" (fn @controller.verifyPackage package.package_ref)}}>Verify package</button></div></div>{{else}}<p class="mg-ev-meta">No package generated.</p>{{/each}}</div></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "release")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro"><div class="mg-ev-title-with-help"><h2>7. Controlled release</h2><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Controlled package release" aria-expanded={{eq @controller.activeHelpKey "controlled_release"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "controlled_release")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "controlled_release")}}>i</span></div><p class="mg-ev-meta">Create an expiring, download-limited link to the latest verified evidence package. The raw token is shown only once and every release or revocation is added to the chain of custody.</p></div>
              {{#if @controller.releaseUrl}}
                <div class="mg-ev-release-link">
                  <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-url">Release link (shown once)</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Release link shown once" aria-expanded={{eq @controller.activeHelpKey "release_link"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_link")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_link")}}>i</span></div><input id="mg-ev-release-url" type="text" value={{@controller.releaseUrl}} readonly /></div>
                  <button class="btn btn-primary" type="button" {{on "click" @controller.copyReleaseUrl}}>Copy link</button>
                  <p class="mg-ev-meta" style="grid-column:1 / -1;">Copy and send this link now. Its secret stays in the URL fragment so it is not sent in the initial server request or written to normal access logs. The link cannot be reconstructed or shown again after a page reload.</p>
                </div>
              {{/if}}
              {{#if @controller.releaseCanCreate}}
                <form class="mg-ev-form" {{on "submit" @controller.createRelease}}>
                  <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-package">Package to release</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Package to release" aria-expanded={{eq @controller.activeHelpKey "release_package"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_package")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_package")}}>i</span></div><select id="mg-ev-release-package" value={{@controller.releasePackageRef}} {{on "change" (fn @controller.setField "releasePackageRef")}}>{{#each @controller.selectedPackages as |package|}}<option value={{package.package_ref}} selected={{eq @controller.releasePackageRef package.package_ref}}>{{package.package_ref}} · {{package.status_label}}</option>{{/each}}</select></div>
                  <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-recipient">Recipient reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Recipient reference" aria-expanded={{eq @controller.activeHelpKey "release_recipient_ref"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_recipient_ref")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_recipient_ref")}}>i</span></div><input id="mg-ev-release-recipient" type="text" value={{@controller.releaseRecipientRef}} placeholder="COUNSEL-2026-014" {{on "input" (fn @controller.setField "releaseRecipientRef")}} /></div>
                  <div class="mg-ev-field is-full"><div class="mg-ev-field-label"><label for="mg-ev-release-purpose">Authorised purpose</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Release purpose" aria-expanded={{eq @controller.activeHelpKey "release_purpose"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_purpose")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_purpose")}}>i</span></div><textarea id="mg-ev-release-purpose" value={{@controller.releasePurpose}} placeholder="Independent technical review for matter ..." {{on "input" (fn @controller.setField "releasePurpose")}}></textarea></div>
                  <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-expiry">Link validity in hours</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Link expiry" aria-expanded={{eq @controller.activeHelpKey "release_expiry"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_expiry")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_expiry")}}>i</span></div><input id="mg-ev-release-expiry" type="number" min="1" max={{@controller.config.release_max_hours}} value={{@controller.releaseExpiresInHours}} {{on "input" (fn @controller.setField "releaseExpiresInHours")}} /><small class="mg-ev-meta">Server maximum: {{@controller.config.release_max_hours}} hours.</small></div>
                  <div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-downloads">Maximum downloads</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Download limit" aria-expanded={{eq @controller.activeHelpKey "release_download_limit"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_download_limit")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_download_limit")}}>i</span></div><input id="mg-ev-release-downloads" type="number" min="1" max={{@controller.config.release_max_downloads}} value={{@controller.releaseMaxDownloads}} {{on "input" (fn @controller.setField "releaseMaxDownloads")}} /><small class="mg-ev-meta">One authorised response is recommended; server maximum: {{@controller.config.release_max_downloads}}.</small></div>
                  <div class="mg-ev-form-actions"><button class="btn btn-primary" type="submit" disabled={{@controller.busy}}>Create controlled release link</button></div>
                </form>
              {{else}}
                {{#if (not @controller.config.can_finalize)}}
                  <div class="mg-ev-flash is-info">Controlled package release is restricted to administrators.</div>
                {{else if (not @controller.releaseTransportReady)}}
                  <div class="mg-ev-flash is-error">Controlled release requires HTTPS. Configure the site base URL for HTTPS, or enable the explicit insecure test-only override only while testing in an isolated environment.</div>
                {{else}}
                  <div class="mg-ev-flash is-info">Generate a verified evidence package first, or open the current non-withdrawn case version.</div>
                {{/if}}
              {{/if}}
              <div class="mg-ev-subsection"><h3>Release history</h3><div class="mg-ev-field"><div class="mg-ev-field-label"><label for="mg-ev-release-revocation-reason">Revocation reason (required before revoking)</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Release revocation reason" aria-expanded={{eq @controller.activeHelpKey "release_revocation_reason"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "release_revocation_reason")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "release_revocation_reason")}}>i</span></div><input id="mg-ev-release-revocation-reason" type="text" value={{@controller.releaseRevocationReason}} placeholder="Reason for revoking an active link" {{on "input" (fn @controller.setField "releaseRevocationReason")}} /></div><div class="mg-ev-list">{{#each @controller.selectedDisclosures as |disclosure|}}<div class="mg-ev-row"><div class="mg-ev-head"><strong>{{disclosure.disclosure_ref}} · {{disclosure.status_label}}</strong><span class="mg-ev-badge">{{disclosure.download_count}} / {{disclosure.max_downloads}} authorised response(s)</span></div><span>Package: {{disclosure.package_ref}}</span><span>Recipient reference: {{disclosure.recipient_ref}}</span><span>Purpose: {{disclosure.purpose}}</span><span class="mg-ev-meta">Created {{disclosure.released_at_label}} · Expires {{disclosure.expires_at_label}} · Last authorised response {{disclosure.last_downloaded_at_label}}</span><div class="mg-ev-actions"><a class="btn btn-default" href={{disclosure.receipt_download_url}}>Download release receipt</a>{{#if disclosure.active}}<button class="btn btn-danger" type="button" {{on "click" (fn @controller.revokeRelease disclosure.disclosure_ref)}}>Revoke link</button>{{/if}}</div></div>{{else}}<p class="mg-ev-meta">No controlled release links have been created.</p>{{/each}}</div></div>
            </section>
          {{/if}}

          {{#if (eq @controller.activeStep "administration")}}
            <section class="mg-ev-panel">
              <div class="mg-ev-section-intro">
                <h2>8. Case administration</h2>
                <p class="mg-ev-meta">Governance snapshots, retention reviews, privacy requests, legal hold and lifecycle controls preserve accountability without rewriting existing report or package bytes.</p>
              </div>

              <div class="mg-ev-stat-grid">
                <div class="mg-ev-stat">
                  <div class="mg-ev-stat-label"><span class="mg-ev-meta">Governance profile</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for governance profile" aria-expanded={{eq @controller.activeHelpKey "governance_profile"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "governance_profile")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "governance_profile")}}>i</span></div>
                  <strong>{{if @controller.selected.governance_profile_ref @controller.selected.governance_profile_ref "Not captured"}}</strong>
                  <span class="mg-ev-meta">{{if @controller.selected.governance_matches_current "Matches current settings" "Snapshot differs from current settings"}}</span>
                </div>
                <div class="mg-ev-stat">
                  <div class="mg-ev-stat-label"><span class="mg-ev-meta">Retention review due</span><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for retention review" aria-expanded={{eq @controller.activeHelpKey "retention_review"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "retention_review")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "retention_review")}}>i</span></div>
                  <strong>{{if @controller.selected.retention_review_due_at_utc @controller.selected.retention_review_due_at_utc "Not calculated"}}</strong>
                  <span class="mg-ev-meta">{{@controller.selected.retention_class}} · No automatic deletion</span>
                </div>
                <div class="mg-ev-stat">
                  <span class="mg-ev-meta">Privacy processing status</span>
                  <strong>{{if @controller.selected.processing_restricted "Restricted" "Normal"}}</strong>
                  <span class="mg-ev-meta">{{if @controller.selected.privacy_request_open "Open privacy request" "No open privacy request"}}</span>
                </div>
                <div class="mg-ev-stat">
                  <span class="mg-ev-meta">Legal hold</span>
                  <strong>{{if @controller.selected.legal_hold "Active" "Not active"}}</strong>
                  <span class="mg-ev-meta">{{#if @controller.selected.legal_hold}}Review due {{if @controller.selected.legal_hold_review_due_at_utc @controller.selected.legal_hold_review_due_at_utc "not calculated"}}{{else}}Case is {{if @controller.selectedMutable "mutable" "immutable"}}{{/if}}</span>
                </div>
              </div>

              <div class="mg-ev-subsection">
                <div class="mg-ev-title-with-help"><h3>Platform governance snapshot</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for governance profile" aria-expanded={{eq @controller.activeHelpKey "governance_profile"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "governance_profile")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "governance_profile")}}>i</span></div>
                <p class="mg-ev-meta">The full privacy policy remains outside this report. This snapshot records only the generic configured profile needed to reproduce who issued the case and which optional fields were visible.</p>
                <div class="mg-ev-stat-grid">
                  <div class="mg-ev-stat"><span class="mg-ev-meta">Current configured profile</span><strong>{{if @controller.currentGovernanceProfile.profile_ref @controller.currentGovernanceProfile.profile_ref "Derived when captured"}}</strong><span class="mg-ev-meta">{{@controller.currentGovernanceProfile.issuer_display_name}}</span></div>
                  <div class="mg-ev-stat"><span class="mg-ev-meta">Case snapshot</span><strong>{{if @controller.selectedGovernanceProfile.profile_ref @controller.selectedGovernanceProfile.profile_ref "Not captured"}}</strong><span class="mg-ev-meta">{{@controller.selectedGovernanceProfile.issuer_display_name}}</span></div>
                </div>
                {{#if @controller.canAdministerPolicy}}
                  {{#if @controller.selected.governance_profile_ref}}
                    <div class="mg-ev-field is-full"><label for="mg-ev-governance-reason">Reason for replacing the snapshot</label><textarea id="mg-ev-governance-reason" value={{@controller.governanceReason}} {{on "input" (fn @controller.setField "governanceReason")}}></textarea></div>
                  {{/if}}
                  <div class="mg-ev-actions"><button class="btn btn-primary" type="button" disabled={{not @controller.selectedMutable}} {{on "click" @controller.captureGovernanceProfile}}>{{if @controller.selected.governance_profile_ref "Replace with current profile" "Capture current profile"}}</button></div>
                {{else}}
                  <div class="mg-ev-flash is-info">Only a configured policy administrator can capture or replace governance snapshots.</div>
                {{/if}}
              </div>

              <div class="mg-ev-subsection">
                <div class="mg-ev-title-with-help"><h3>Retention review</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for retention review" aria-expanded={{eq @controller.activeHelpKey "retention_review"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "retention_review")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "retention_review")}}>i</span></div>
                <p class="mg-ev-meta">Retention dates are review deadlines. This module never deletes evidence automatically.</p>
                {{#if @controller.canAdministerPolicy}}
                  <form class="mg-ev-form-grid" {{on "submit" @controller.recordRetentionReview}}>
                    <div class="mg-ev-field"><label for="mg-ev-retention-action">Decision</label><select id="mg-ev-retention-action" value={{@controller.retentionAction}} {{on "change" (fn @controller.setField "retentionAction")}}>{{#each @controller.retentionActionOptions as |action|}}<option value={{action.value}}>{{action.label}}</option>{{/each}}</select></div>
                    <div class="mg-ev-field"><label for="mg-ev-retention-days">Extension days (retain only)</label><input id="mg-ev-retention-days" type="number" min="1" max="3650" value={{@controller.retentionExtensionDays}} placeholder="Use policy default" {{on "input" (fn @controller.setField "retentionExtensionDays")}} /></div>
                    <div class="mg-ev-field is-full"><label for="mg-ev-retention-reason">Reason</label><textarea id="mg-ev-retention-reason" value={{@controller.retentionReason}} {{on "input" (fn @controller.setField "retentionReason")}}></textarea></div>
                    <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit">Record retention review</button></div>
                  </form>
                {{/if}}
                <div class="mg-ev-list">{{#each @controller.selectedRetentionReviews as |review|}}<div class="mg-ev-row"><div><strong>{{review.action_label}}</strong><span>{{review.retention_class_label}} · {{review.occurred_at_label}}</span><span>{{review.reason}}</span></div><div><span class="mg-ev-meta">Next review</span><strong>{{review.next_due_at_label}}</strong></div></div>{{else}}<p class="mg-ev-meta">No retention reviews have been recorded.</p>{{/each}}</div>
              </div>

              <div class="mg-ev-subsection">
                <div class="mg-ev-title-with-help"><h3>Privacy requests</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for privacy requests" aria-expanded={{eq @controller.activeHelpKey "privacy_request"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "privacy_request")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "privacy_request")}}>i</span></div>
                <p class="mg-ev-meta">This records workflow and decisions only. It does not decide whether a request must be granted.</p>
                {{#if @controller.canAdministerPolicy}}
                  <form class="mg-ev-form-grid" {{on "submit" @controller.createPrivacyRequest}}>
                    <div class="mg-ev-field"><label for="mg-ev-privacy-type">Request type</label><select id="mg-ev-privacy-type" value={{@controller.privacyRequestType}} {{on "change" (fn @controller.setField "privacyRequestType")}}>{{#each @controller.config.privacy_request_types as |requestType|}}<option value={{requestType}}>{{requestType}}</option>{{/each}}</select></div>
                    <div class="mg-ev-field"><label for="mg-ev-privacy-requester">Requester reference</label><input id="mg-ev-privacy-requester" type="text" value={{@controller.privacyRequesterRef}} placeholder="PRIVACY-TICKET-..." {{on "input" (fn @controller.setField "privacyRequesterRef")}} /></div>
                    <div class="mg-ev-field"><label for="mg-ev-privacy-received">Received at</label><input id="mg-ev-privacy-received" type="datetime-local" value={{@controller.privacyReceivedAt}} {{on "input" (fn @controller.setField "privacyReceivedAt")}} /></div>
                    <div class="mg-ev-field"><label class="mg-ev-check"><input type="checkbox" checked={{@controller.privacyRestrictProcessing}} {{on "change" (fn @controller.setBooleanField "privacyRestrictProcessing")}} /> Restrict new finalization and disclosure while open</label></div>
                    <div class="mg-ev-field is-full"><label for="mg-ev-privacy-reason">Context or reason</label><textarea id="mg-ev-privacy-reason" value={{@controller.privacyReason}} {{on "input" (fn @controller.setField "privacyReason")}}></textarea></div>
                    <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit">Record privacy request</button></div>
                  </form>
                  <div class="mg-ev-field is-full"><label for="mg-ev-privacy-decision">Decision for closing an existing request</label><textarea id="mg-ev-privacy-decision" value={{@controller.privacyDecision}} {{on "input" (fn @controller.setField "privacyDecision")}}></textarea></div>
                {{/if}}
                <div class="mg-ev-list">{{#each @controller.selectedPrivacyRequests as |request|}}<div class="mg-ev-row"><div><strong>{{request.request_type_label}} · {{request.status_label}}</strong><span>{{request.request_ref}} · received {{request.received_at_label}} · due {{request.due_at_label}}</span><span>Requester: {{request.requester_ref}}{{#if request.processing_restricted}} · processing restricted{{/if}}</span>{{#if request.decision}}<span>{{request.decision}}</span>{{/if}}</div>{{#if @controller.canAdministerPolicy}}<div class="mg-ev-actions">{{#if request.open}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.updatePrivacyRequest request.request_ref "under_review")}}>Mark under review</button>{{#if request.processing_restricted}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.updatePrivacyRequest request.request_ref request.status false)}}>Resume processing</button>{{else}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.updatePrivacyRequest request.request_ref request.status true)}}>Restrict processing</button>{{/if}}<button class="btn btn-primary" type="button" {{on "click" (fn @controller.updatePrivacyRequest request.request_ref "resolved")}}>Resolve</button><button class="btn btn-danger" type="button" {{on "click" (fn @controller.updatePrivacyRequest request.request_ref "rejected")}}>Reject</button>{{/if}}</div>{{/if}}</div>{{else}}<p class="mg-ev-meta">No privacy requests have been recorded for this case.</p>{{/each}}</div>
              </div>

              {{#if @controller.config.restricted_identity_annex}}
                <div class="mg-ev-subsection">
                  <div class="mg-ev-title-with-help"><h3>Restricted Identity Annex</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for restricted annex" aria-expanded={{eq @controller.activeHelpKey "restricted_annex"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "restricted_annex")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "restricted_annex")}}>i</span></div>
                  <p class="mg-ev-meta">This optional annex is separately encrypted and never enters the standard report or evidence package.</p>
                  {{#unless @controller.config.restricted_identity_annex_configured}}<div class="mg-ev-flash is-danger">The annex is enabled but its external encryption key or key identifier is not configured.</div>{{/unless}}
                  {{#unless @controller.canAccessRestrictedAnnex}}<div class="mg-ev-flash is-info">Access requires explicit membership in a configured restricted-data approver group. Administrator status alone is not sufficient.</div>{{/unless}}
                  {{#if @controller.canAccessRestrictedAnnex}}
                    <form class="mg-ev-form-grid" {{on "submit" @controller.createIdentityAnnex}}>
                      <div class="mg-ev-field is-full"><label>Permitted account fields</label><div class="mg-ev-check-grid"><label class="mg-ev-check"><input type="checkbox" checked={{@controller.annexSelections.account_username}} {{on "change" (fn @controller.setAnnexSelection "account_username")}} /> Username</label><label class="mg-ev-check"><input type="checkbox" checked={{@controller.annexSelections.internal_account_id}} {{on "change" (fn @controller.setAnnexSelection "internal_account_id")}} /> Internal account ID</label>{{#if @controller.annexAllowEmail}}<label class="mg-ev-check"><input type="checkbox" checked={{@controller.annexSelections.email_address}} {{on "change" (fn @controller.setAnnexSelection "email_address")}} /> Email address</label>{{/if}}</div></div>
                      {{#if @controller.annexHasOptionalEvents}}
                        <div class="mg-ev-field"><div class="mg-ev-title-with-help"><label for="mg-ev-annex-event-category">Optional selected event/reference</label><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for selected restricted event" aria-expanded={{eq @controller.activeHelpKey "annex_event"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "annex_event")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "annex_event")}}>i</span></div><select id="mg-ev-annex-event-category" value={{@controller.annexEventCategory}} {{on "change" (fn @controller.setField "annexEventCategory")}}>{{#if @controller.annexAllowSelectedIp}}<option value="selected_ip_event">Selected IP event</option>{{/if}}{{#if @controller.annexAllowSelectedAccess}}<option value="selected_access_event">Selected access event</option>{{/if}}{{#if @controller.annexAllowDeviceHint}}<option value="device_hint">Device hint</option>{{/if}}{{#if @controller.annexAllowCustomReference}}<option value="custom_identity_reference">Custom identity reference</option>{{/if}}</select></div>
                        <div class="mg-ev-field"><label for="mg-ev-annex-event-value">Value</label><input id="mg-ev-annex-event-value" type="text" value={{@controller.annexEventValue}} {{on "input" (fn @controller.setField "annexEventValue")}} /></div>
                        <div class="mg-ev-field"><label for="mg-ev-annex-event-time">Event time</label><input id="mg-ev-annex-event-time" type="text" value={{@controller.annexEventTime}} placeholder="UTC timestamp or recorded wording" {{on "input" (fn @controller.setField "annexEventTime")}} /></div>
                        <div class="mg-ev-field"><label for="mg-ev-annex-event-source">Source reference</label><input id="mg-ev-annex-event-source" type="text" value={{@controller.annexEventSourceRef}} {{on "input" (fn @controller.setField "annexEventSourceRef")}} /></div>
                        <div class="mg-ev-field is-full"><label for="mg-ev-annex-event-necessity">Why this event is necessary</label><textarea id="mg-ev-annex-event-necessity" value={{@controller.annexEventNecessity}} {{on "input" (fn @controller.setField "annexEventNecessity")}}></textarea></div>
                        <div class="mg-ev-field is-full"><label for="mg-ev-annex-event-limit">Reliability or limitation note</label><textarea id="mg-ev-annex-event-limit" value={{@controller.annexEventLimitation}} {{on "input" (fn @controller.setField "annexEventLimitation")}}></textarea></div>
                      {{/if}}
                      <div class="mg-ev-field is-full"><label for="mg-ev-annex-necessity">Overall necessity reason</label><textarea id="mg-ev-annex-necessity" value={{@controller.annexNecessityReason}} {{on "input" (fn @controller.setField "annexNecessityReason")}}></textarea></div>
                      <div class="mg-ev-actions is-full"><button class="btn btn-primary" type="submit" disabled={{not @controller.restrictedAnnexAvailable}}>Create encrypted annex</button></div>
                    </form>
                    <div class="mg-ev-form-grid"><div class="mg-ev-field"><label for="mg-ev-annex-recipient">Export recipient reference</label><input id="mg-ev-annex-recipient" type="text" value={{@controller.annexRecipientRef}} {{on "input" (fn @controller.setField "annexRecipientRef")}} /></div><div class="mg-ev-field"><label for="mg-ev-annex-passphrase">Export passphrase (16+ characters)</label><input id="mg-ev-annex-passphrase" type="password" value={{@controller.annexExportPassphrase}} autocomplete="new-password" {{on "input" (fn @controller.setField "annexExportPassphrase")}} /></div><div class="mg-ev-field is-full"><label for="mg-ev-annex-purpose">Authorized export purpose</label><textarea id="mg-ev-annex-purpose" value={{@controller.annexExportPurpose}} {{on "input" (fn @controller.setField "annexExportPurpose")}}></textarea></div></div>
                  {{/if}}
                  <div class="mg-ev-list">{{#each @controller.selectedIdentityAnnexes as |annex|}}<div class="mg-ev-row"><div><strong>{{annex.annex_ref}} · {{annex.status_label}}</strong><span>Version {{annex.version}} · {{annex.categories_label}} · key {{annex.key_id}}</span><span>Created {{annex.created_at_label}}</span></div>{{#if @controller.canAccessRestrictedAnnex}}<div class="mg-ev-actions"><button class="btn btn-default" type="button" {{on "click" (fn @controller.viewIdentityAnnex annex.annex_ref)}}>Authorized view</button>{{#if @controller.canReviewSenior}}{{#unless annex.senior_approved_at_utc}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.approveIdentityAnnex annex.annex_ref "senior")}}>Senior approval</button>{{/unless}}{{/if}}{{#unless annex.privacy_approved_at_utc}}<button class="btn btn-default" type="button" {{on "click" (fn @controller.approveIdentityAnnex annex.annex_ref "privacy")}}>Privacy approval</button>{{/unless}}{{#if annex.fully_approved}}<button class="btn btn-primary" type="button" {{on "click" (fn @controller.exportIdentityAnnex annex.annex_ref)}}>Export encrypted annex</button>{{/if}}</div>{{/if}}</div>{{else}}<p class="mg-ev-meta">No Restricted Identity Annexes have been created.</p>{{/each}}</div>
                  {{#if @controller.annexPreview}}<div class="mg-ev-flash is-info"><strong>Authorized decrypted view</strong><pre>{{@controller.annexPreviewText}}</pre><button class="btn btn-default" type="button" {{on "click" @controller.closeAnnexPreview}}>Close view</button></div>{{/if}}
                </div>
              {{/if}}

              <div class="mg-ev-stat-grid"><div class="mg-ev-stat"><span class="mg-ev-meta">Supersedes case</span><strong>{{if @controller.selected.supersedes_case_ref @controller.selected.supersedes_case_ref "—"}}</strong></div><div class="mg-ev-stat"><span class="mg-ev-meta">Superseded by case</span><strong>{{if @controller.selected.superseded_by_case_ref @controller.selected.superseded_by_case_ref "—"}}</strong></div><div class="mg-ev-stat"><span class="mg-ev-meta">Closed at</span><strong>{{if @controller.selected.closed_at_utc @controller.selected.closed_at_utc "—"}}</strong></div></div>
              {{#if @controller.canReviewSenior}}
                <div class="mg-ev-subsection"><h3>Case lifecycle</h3>{{#if @controller.selectedLifecycleClosed}}<div class="mg-ev-flash is-info">This case is {{@controller.selectedHeader.status_label}}. Its records remain available for audit, but it cannot be released as the current case version.</div>{{#if @controller.selected.lifecycle_reason}}<div class="mg-ev-row"><strong>Recorded lifecycle reason</strong><span>{{@controller.selected.lifecycle_reason}}</span></div>{{/if}}{{else}}<div class="mg-ev-field is-full"><label for="mg-ev-lifecycle-reason">Reason for withdrawal or supersession</label><textarea id="mg-ev-lifecycle-reason" value={{@controller.lifecycleReason}} {{on "input" (fn @controller.setField "lifecycleReason")}}></textarea></div><div class="mg-ev-lifecycle-grid"><div class="mg-ev-action-card"><h3>Withdraw case</h3><p class="mg-ev-meta">Marks this case as withdrawn without deleting immutable evidence.</p><div class="mg-ev-actions"><button class="btn btn-danger" type="button" {{on "click" (fn @controller.applyLifecycleAction "withdraw")}}>Withdraw case</button></div></div><div class="mg-ev-action-card"><h3>Supersede with replacement case</h3><div class="mg-ev-field"><label for="mg-ev-replacement-case">Replacement case reference</label><input id="mg-ev-replacement-case" type="text" value={{@controller.replacementCaseRef}} placeholder="CASE-2026-..." {{on "input" (fn @controller.setField "replacementCaseRef")}} /></div><div class="mg-ev-actions"><button class="btn btn-danger" type="button" {{on "click" (fn @controller.applyLifecycleAction "supersede")}}>Supersede case</button></div></div></div>{{/if}}</div>
                <div class="mg-ev-subsection">
                  <div class="mg-ev-title-with-help"><h3>Legal hold</h3><span class="mg-ev-info" role="button" tabindex="0" aria-label="Help for Legal hold" aria-expanded={{eq @controller.activeHelpKey "legal_hold"}} aria-controls="mg-ev-help-overlay" {{on "click" (fn @controller.toggleHelp "legal_hold")}} {{on "keydown" (fn @controller.handleHelpTriggerKeydown "legal_hold")}}>i</span></div>
                  <p class="mg-ev-meta">A legal hold blocks disposal. Its review deadline is a reminder only and never releases the hold automatically.</p>
                  <div class="mg-ev-form-grid">
                    <div class="mg-ev-field is-full"><label for="mg-ev-hold-reason">Reason (required)</label><textarea id="mg-ev-hold-reason" class="is-large" value={{@controller.holdReason}} {{on "input" (fn @controller.setField "holdReason")}}></textarea></div>
                    <div class="mg-ev-field is-full"><label for="mg-ev-hold-authority">Authority or case reference (optional)</label><input id="mg-ev-hold-authority" type="text" value={{@controller.holdAuthorityRef}} {{on "input" (fn @controller.setField "holdAuthorityRef")}} /></div>
                  </div>
                  <div class="mg-ev-actions">
                    {{#if @controller.selected.legal_hold}}
                      <button class="btn btn-primary" type="button" {{on "click" @controller.reviewLegalHold}}>Review and extend legal hold</button>
                      <button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold false)}}>Release legal hold</button>
                    {{else}}
                      <button class="btn btn-danger" type="button" {{on "click" (fn @controller.setLegalHold true)}}>Place legal hold</button>
                    {{/if}}
                  </div>
                  <div class="mg-ev-list">{{#each @controller.selectedLegalHolds as |hold|}}<div class="mg-ev-row"><div><strong>{{hold.action_label}}</strong><span>{{hold.hold_ref}} · {{hold.occurred_at_label}}</span><span>{{hold.reason}}</span></div><div><span class="mg-ev-meta">Review due</span><strong>{{hold.review_due_at_label}}</strong></div></div>{{else}}<p class="mg-ev-meta">No legal hold events have been recorded.</p>{{/each}}</div>
                </div>
              {{/if}}
            </section>
          {{/if}}
        </div>
      {{/unless}}

      {{#if @controller.activeHelp}}
        <button class="mg-ev-help-backdrop" type="button" tabindex="-1" aria-label="Close field guidance" {{on "click" @controller.closeHelp}}></button>
        <aside id="mg-ev-help-overlay" class={{@controller.helpOverlayClass}} style={{@controller.helpOverlayStyle}} role="dialog" aria-modal="false" aria-label={{@controller.activeHelp.title}} tabindex="-1" {{on "keydown" @controller.handleHelpKeydown}}>
          <div class="mg-ev-help-popover-header">
            <div><span class="mg-ev-help-popover-kicker">Field guidance</span><h3>{{@controller.activeHelp.title}}</h3></div>
            <button class="mg-ev-help-popover-close" type="button" aria-label="Close guidance" {{on "click" @controller.closeHelp}}>×</button>
          </div>
          <div class="mg-ev-help-popover-body">
            {{#if @controller.activeHelp.guidance}}
              <div class="mg-ev-help-popover-section"><strong>{{@controller.activeHelp.guidance_title}}</strong><p>{{@controller.activeHelp.guidance}}</p></div>
            {{/if}}
            {{#if @controller.activeHelp.purpose}}
              <div class="mg-ev-help-popover-section"><strong>Why it matters</strong><p>{{@controller.activeHelp.purpose}}</p></div>
            {{/if}}
            {{#if @controller.activeHelp.example}}
              <div class="mg-ev-help-popover-example"><strong>Example</strong><div>{{@controller.activeHelp.example}}</div></div>
            {{/if}}
            {{#if @controller.activeHelp.note}}
              <div class="mg-ev-help-popover-note"><strong>Important</strong><div>{{@controller.activeHelp.note}}</div></div>
            {{/if}}
          </div>
        </aside>
      {{/if}}
    </div>
  </template>
);
