import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { htmlSafe } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import {
  ajaxEvidenceErrorMessage,
  evidenceErrorMessage,
  evidenceLabel,
  humanizeEvidenceCode,
} from "../../lib/media-gallery-evidence-ui";

const EVIDENCE_HELP_TOPICS = Object.freeze({
  safety_profile: {
    title: "Safety profile",
    guidance_title: "What this shows",
    guidance: "The report language, package protection, timestamp status, issuer identity and operator identity that will be used for this evidence environment.",
    purpose: "Reviewers can immediately see whether the environment is configured for testing, integrity-only export or stronger production sealing.",
    note: "The CMS key and certificate fields may remain empty when package protection is set to SHA-256 integrity only.",
  },
  media_public_id: {
    title: "Media public ID",
    guidance_title: "What to enter",
    guidance: "Enter the immutable public ID of the Media Library item that the acquired file is believed to correspond to.",
    purpose: "This links the case to the exact reference media, fingerprint assignments and packaging metadata used by Forensics Identify.",
    example: "07ba4140-f69a-4600-8e77-1361338f1e77",
  },
  claimant_reference: {
    title: "Claimant reference",
    guidance_title: "What to enter",
    guidance: "Use an internal, non-sensitive reference for the person or organisation asserting rights in the media.",
    purpose: "The report can refer to the claimant consistently without exposing unnecessary personal details.",
    example: "RC-2026-0041 or LEGAL-TICKET-1842",
    note: "Do not enter an email address, home address or other sensitive identity data here.",
  },
  research_question: {
    title: "Research question",
    guidance_title: "What to enter",
    guidance: "Describe the exact technical question the case must answer, without presuming infringement, intent or personal responsibility.",
    purpose: "A narrowly framed question keeps the report factual and prevents the technical result from being presented as a legal conclusion.",
    example: "Does the acquired file correspond to media item X, and does its forensic pattern meet the recorded attribution criteria within the investigated candidate population?",
  },
  external_url: {
    title: "External URL",
    guidance_title: "What to enter",
    guidance: "Enter the full page URL where staff observed the file or publication. Leave it blank when the evidence was received through another documented channel.",
    purpose: "The URL records source context and supports later review of where the evidence was found.",
    note: "The plugin records this value only. It never opens, crawls or downloads the URL automatically.",
  },
  external_platform: {
    title: "External platform",
    guidance_title: "What to enter",
    guidance: "Enter the public name of the website, forum, social network, file host or other service where the material was observed.",
    purpose: "Platform context helps explain displayed usernames, timestamps and whether the downloaded file may be a transcode.",
    example: "Example Video Host, public forum, received by email",
  },
  external_username: {
    title: "Visible external username",
    guidance_title: "What to enter",
    guidance: "Record only the account name visibly shown by the external platform at the time of observation.",
    purpose: "This preserves what staff actually saw without claiming that the account name identifies a natural person.",
    note: "Do not describe this account as the proven uploader or offender.",
  },
  rights_statement_reference: {
    title: "Rights statement reference",
    guidance_title: "What to enter",
    guidance: "Enter an immutable document, ticket, signed declaration or other record reference for the claimant's rights and authorisation statement.",
    purpose: "Finalisation requires a traceable source for the claimant's assertion; the system does not independently prove ownership or lack of permission.",
    example: "RS-2026-0012 or signed-document SHA-256 reference",
    note: "Store the actual document as a Rights statement evidence object when appropriate.",
  },
  rights_statement_received: {
    title: "Rights statement received",
    guidance_title: "What to enter",
    guidance: "Select the local date and time when staff received the claimant's statement. The server stores the corresponding canonical UTC value.",
    purpose: "This timestamps when the rights assertion entered the evidence process and supports the review sequence.",
  },
  classification: {
    title: "Classification",
    guidance_title: "How to choose",
    guidance: "Use Confidential for standard evidence cases. Use Restricted when access must be limited more tightly because of unusually sensitive content or context.",
    purpose: "The classification communicates handling expectations; it does not change the technical identify result.",
    note: "Restricted does not automatically add identity data or create a Restricted Identity Annex.",
  },
  jurisdiction_context: {
    title: "Jurisdiction context",
    guidance_title: "What to enter",
    guidance: "Record the relevant geographic or legal context known at intake, such as international, Netherlands, European Union or unknown.",
    purpose: "This helps legal reviewers understand which jurisdiction-specific assessment may be needed later.",
    note: "The technical report remains jurisdiction-neutral and does not claim admissibility in any country.",
  },
  observed_by_staff: {
    title: "Observed by staff",
    guidance_title: "What to enter",
    guidance: "Select the local date and time when an authenticated staff member personally observed the external source or received the evidence.",
    purpose: "This is the evidence service's own observation timestamp and is stronger than relying only on a platform-displayed date.",
  },
  platform_displayed_datetime: {
    title: "Platform-displayed date/time",
    guidance_title: "What to enter",
    guidance: "Copy the date/time exactly as displayed by the external platform, including any visible timezone wording or ambiguity.",
    purpose: "The report can distinguish the platform's claim from the independently recorded staff observation time.",
    example: "Uploaded 3 hours ago; 2026-08-01 14:22 UTC; date not displayed",
  },
  evidence_role: {
    title: "Evidence role",
    guidance_title: "How to choose",
    guidance: "Choose the role that describes why the file belongs in the case: acquired external original, analysis working copy, screenshot, HTML/WARC capture, headers, rights statement or other supporting material.",
    purpose: "Correct roles preserve provenance and determine which objects must pass quarantine review before finalisation.",
    note: "Use External original for the file as acquired. Use Working copy only for a separately derived analysis copy.",
  },
  evidence_file: {
    title: "Evidence file",
    guidance_title: "What to select",
    guidance: "Select the exact file to preserve. Avoid editing, recompressing, renaming through another application or otherwise transforming an acquired original before upload.",
    purpose: "The plugin immediately hashes and freezes the uploaded bytes so later changes can be detected.",
    note: "Treat external media as untrusted input and follow your malware/quarantine procedure before marking it clean.",
  },
  evidence_description: {
    title: "Evidence description",
    guidance_title: "What to enter",
    guidance: "Briefly describe how the object was obtained and what it represents in the case.",
    purpose: "A clear description makes the chain of custody understandable without opening the file.",
    example: "File downloaded without transformation from the recorded external URL by staff on 2026-08-01.",
    note: "Do not place passwords, tokens, private messages or unnecessary personal data in this field.",
  },
  stored_evidence_objects: {
    title: "Stored evidence objects",
    guidance_title: "What this section shows",
    guidance: "Every stored object receives a case-specific reference, immutable SHA-256 hash, role, size and quarantine status.",
    purpose: "These records form the technical evidence inventory used by reports, packages and chain-of-custody verification.",
    note: "Mark clean only after the applicable review or scanning process. Reject files that must not be used for finalisation.",
  },
  identify_decision: {
    title: "Identify decision",
    guidance_title: "What this means",
    guidance: "The policy decision produced by the immutable Forensics Identify snapshot, such as conclusive match, likely match, ambiguous or no match.",
    purpose: "The decision controls the permitted conclusion language. It is a technical classification, not a probability of guilt or identity.",
  },
  attributed_account: {
    title: "Attributed distribution account",
    guidance_title: "What this means",
    guidance: "The Discourse account reference whose assigned distribution copy best matches the acquired file under the recorded policy and candidate population.",
    purpose: "This identifies a distribution copy and platform account reference, not the natural person who copied, forwarded or uploaded the file.",
  },
  candidate_population: {
    title: "Candidate population",
    guidance_title: "What this means",
    guidance: "The number and kind of candidate fingerprints compared during the production identify run.",
    purpose: "Attribution is only valid within the investigated population. A fingerprint that was not included cannot be ranked.",
    note: "Synthetic candidates are diagnostic only and must not determine a final evidence attribution.",
  },
  identify_snapshot: {
    title: "Immutable identify snapshot",
    guidance_title: "What this shows",
    guidance: "The server-attested production result, layout, run reference and raw-result SHA-256 captured when the case was created from Forensics Identify.",
    purpose: "Freezing this snapshot prevents later UI, account or settings changes from silently altering the evidence result.",
  },
  claimant_confirmation: {
    title: "Claimant confirmation",
    guidance_title: "What to verify",
    guidance: "Confirm that the rights statement reference and receipt time are correct and that the claimant has explicitly asserted the relevant rights and lack of authorisation as applicable.",
    purpose: "This records receipt and human confirmation of the claimant's statement; it does not independently validate legal ownership.",
    note: "Material case changes invalidate earlier confirmations and approvals.",
  },
  technical_review_checklist: {
    title: "Technical review checklist",
    guidance_title: "How to use it",
    guidance: "Complete every item only after personally reviewing the underlying evidence, hashes, raw result, wording, alternatives and privacy impact.",
    purpose: "The checklist creates a repeatable human-control gate before approvals can be recorded.",
    note: "A conclusive final report requires a different account to perform Senior Staff Review.",
  },
  review_acquisition_reviewed: {
    title: "Acquisition reviewed",
    guidance_title: "What to verify",
    guidance: "Confirm that the source, acquisition method, original file or vault reference, observation time and supporting captures are documented consistently.",
    purpose: "This reduces the risk of analysing the wrong file or presenting undocumented source context.",
  },
  review_hashes_verified: {
    title: "Hashes verified",
    guidance_title: "What to verify",
    guidance: "Confirm that evidence-object hashes, the identify raw-result hash and any relevant report/package hashes are present and internally consistent.",
    purpose: "Hash verification detects byte-level substitution or corruption between acquisition, analysis and export.",
  },
  review_raw_json_reviewed: {
    title: "Raw JSON reviewed",
    guidance_title: "What to verify",
    guidance: "Inspect the immutable raw identify result and confirm that the displayed decision, top candidate, warnings, settings and population agree with it.",
    purpose: "The readable UI is a summary; the raw result is the detailed technical source used for reproducibility.",
  },
  review_decision_language_reviewed: {
    title: "Decision language reviewed",
    guidance_title: "What to verify",
    guidance: "Confirm that the conclusion matches the technical decision and does not accuse a natural person, claim legal wrongdoing or present scores as probability percentages.",
    purpose: "Controlled wording keeps the report within what the fingerprinting evidence actually establishes.",
  },
  review_alternatives_reviewed: {
    title: "Alternatives reviewed",
    guidance_title: "What to verify",
    guidance: "Consider account sharing, compromise, forwarding, screen recording, transcoding, incomplete candidate populations, mixed files and missing historical logs.",
    purpose: "A defensible report must disclose plausible alternative explanations and relevant technical limitations.",
  },
  review_privacy_reviewed: {
    title: "Privacy reviewed",
    guidance_title: "What to verify",
    guidance: "Confirm that the report and standard package exclude personal staff identities, email addresses, IP addresses, credentials, private messages and other unnecessary sensitive data.",
    purpose: "Evidence reporting must remain proportionate and privacy-minimised, especially in an adult-community context.",
  },
  internal_review_notes: {
    title: "Internal review reason / notes",
    guidance_title: "What to enter",
    guidance: "Record concise internal reasoning, exceptions, limitations or the reason for rejecting a review.",
    purpose: "The notes support internal accountability while external exports include only a digest showing that notes existed.",
    note: "Do not copy unnecessary personal or intimate details into free text.",
  },
  finalization_readiness: {
    title: "Finalization readiness",
    guidance_title: "How to read this step",
    guidance: "Required actions are hard blockers enforced by the evidence policy. Advisory notices describe limitations that should be disclosed but do not automatically prevent export.",
    purpose: "This separates missing evidence or approvals from known product limitations such as PDF/A or trusted timestamp configuration.",
  },
  technical_evidence_report: {
    title: "Technical Evidence Report",
    guidance_title: "What is generated",
    guidance: "An English, jurisdiction-neutral PDF summarising the research question, evidence hashes, immutable identify result, controlled conclusion, limitations and review references.",
    purpose: "The draft is for review and is not sealed. The final report is only available after all mandatory controls pass.",
    note: "The report attributes a distribution copy and account reference; it does not prove the conduct or identity of a natural person.",
  },
  sealed_evidence_package: {
    title: "Sealed Evidence Package",
    guidance_title: "What is generated",
    guidance: "A machine-verifiable archive containing the report, manifest, checksums, technical snapshots and chain-of-custody material permitted by the privacy policy.",
    purpose: "The package lets a recipient detect any changed byte and inspect the technical basis independently.",
    note: "Integrity-only mode uses SHA-256 manifests. CMS mode additionally requires a configured signing key and certificate; certificate trust remains a recipient decision.",
  },
  retention_review_due: {
    title: "Retention review due",
    guidance_title: "What this means",
    guidance: "The date on which an administrator should reconsider whether the case still needs to be retained under the applicable policy.",
    purpose: "Periodic review supports storage limitation and prevents evidence cases from being kept indefinitely without a documented reason.",
    note: "This release does not automatically delete a case when the date is reached.",
  },
  legal_hold: {
    title: "Legal hold",
    guidance_title: "What this means",
    guidance: "A legal hold records that normal deletion or retention actions must be suspended because the case is needed for a claim, dispute, investigation or proceeding.",
    purpose: "The hold protects evidence from routine disposal while preserving an auditable reason and status.",
  },
  case_mutability: {
    title: "Case mutability",
    guidance_title: "What this means",
    guidance: "Mutable cases may still receive factual edits, evidence and reviews. After package creation, the case is made immutable so existing report and package bytes cannot be silently replaced.",
    purpose: "Corrections must be handled through versioning rather than overwriting sealed evidence.",
  },
  legal_hold_reason: {
    title: "Legal hold reason",
    guidance_title: "What to enter",
    guidance: "Enter the specific operational or legal reason for placing or releasing the hold, including an internal authority or matter reference where appropriate.",
    purpose: "A documented reason makes the retention override accountable and reviewable.",
    example: "Pending external counsel review under matter LEGAL-2026-018.",
    note: "Avoid unnecessary details about users or the underlying adult content.",
  },
});

function evidenceHelpTopic(key) {
  return EVIDENCE_HELP_TOPICS[String(key || "")] || null;
}

function utc(value) {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : `${date.toISOString().replace("T", " ").replace(".000Z", "Z")}`;
}

function localDatetimeInput(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function utcDatetimeInput(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "" : date.toISOString();
}

function normalizeConfig(config) {
  const source = config || {};
  return {
    ...source,
    enabled: source.enabled ?? false,
    can_finalize: source.can_finalize ?? source.canFinalize ?? false,
    issuer_name: source.issuer_name ?? source.issuerName ?? "",
    operator_identity: source.operator_identity ?? source.operatorIdentity ?? "",
    legal_notice_url: source.legal_notice_url ?? source.legalNoticeUrl ?? "",
    jurisdiction_notice: source.jurisdiction_notice ?? source.jurisdictionNotice ?? "",
    seal_mode: source.seal_mode ?? source.sealMode ?? "",
    cms_seal_configured: source.cms_seal_configured ?? source.cmsSealConfigured ?? false,
    timestamp_status: source.timestamp_status ?? source.timestampStatus ?? "",
    report_language: source.report_language ?? source.reportLanguage ?? "en",
    automatic_source_fetch: source.automatic_source_fetch ?? source.automaticSourceFetch ?? false,
    restricted_identity_annex: source.restricted_identity_annex ?? source.restrictedIdentityAnnex ?? false,
    required_review_checks: source.required_review_checks ?? source.requiredReviewChecks ?? [],
    roles: source.roles ?? [],
    classifications: source.classifications ?? [],
    decisions: source.decisions ?? [],
  };
}

const ISSUE_STEP_MAP = {
  rights_statement_missing: "intake",
  rights_statement_reference_missing: "intake",
  external_observation_time_missing: "intake",
  source_capture_missing: "evidence",
  external_evidence_missing: "evidence",
  rejected_evidence_present: "evidence",
  quarantine_review_incomplete: "evidence",
  media_snapshot_missing: "identify",
  identify_snapshot_missing: "identify",
  diagnostic_run_not_evidence: "identify",
  synthetic_population_present: "identify",
  identify_sanity_checks_failed: "identify",
  attributed_account_missing: "identify",
  fingerprint_assignment_missing: "identify",
  assignment_after_observation: "identify",
  claimant_confirmation_missing: "review",
  technical_review_missing: "review",
  senior_review_missing: "review",
  four_eyes_review_missing: "review",
  privacy_review_missing: "review",
  current_review_rejected: "review",
};

const STEP_LABELS = {
  intake: "Case intake",
  evidence: "Evidence acquisition",
  identify: "Identify result",
  review: "Review & confirmation",
  readiness: "Finalization readiness",
  reports: "Reports & packages",
  administration: "Case administration",
};

function issueStep(code) {
  return ISSUE_STEP_MAP[String(code || "")] || "readiness";
}

function cmsSignatureIntegrityLabel(value) {
  if (value === true) {
    return "Verified";
  }
  if (value === false) {
    return "Not verified";
  }
  return "Not included";
}

export default class AdminPluginsMediaGalleryEvidenceCasesController extends Controller {
  @tracked cases = [];
  @tracked selected = null;
  @tracked config = normalizeConfig({});
  @tracked configLoaded = false;
  @tracked requestedCaseRef = "";
  @tracked selectedLoadError = "";
  @tracked busy = false;
  @tracked error = "";
  @tracked notice = "";
  @tracked query = "";
  @tracked newMediaPublicId = "";
  @tracked newClaimantRef = "";
  @tracked newResearchQuestion = "";
  @tracked newExternalUrl = "";
  @tracked newExternalPlatform = "";
  @tracked newExternalUsername = "";
  @tracked newRightsStatementRef = "";
  @tracked newRightsStatementReceivedAt = "";
  @tracked editClaimantRef = "";
  @tracked editResearchQuestion = "";
  @tracked editClassification = "confidential";
  @tracked editJurisdictionContext = "international";
  @tracked editExternalUrl = "";
  @tracked editExternalPlatform = "";
  @tracked editExternalUsername = "";
  @tracked editExternalObservedAt = "";
  @tracked editExternalDisplayedAt = "";
  @tracked editRightsStatementRef = "";
  @tracked editRightsStatementReceivedAt = "";
  @tracked uploadRole = "external_original";
  @tracked uploadFile = null;
  @tracked uploadDescription = "";
  @tracked reviewReason = "";
  @tracked reviewChecklist = {};
  @tracked holdReason = "";
  @tracked activeStep = "intake";
  @tracked activeHelpKey = "";
  @tracked helpOverlayStyle = htmlSafe("");
  @tracked helpOverlayPlacement = "below";
  helpTriggerElement = null;

  initializeFromModel(model) {
    this.cases = model?.cases || [];
    this.selected = model?.selected || null;
    this.configLoaded = !!model?.config;
    this.config = normalizeConfig(model?.config);
    this.requestedCaseRef = model?.requestedCaseRef || "";
    const selectedError = model?.selectedError || model?.selected_error || "";
    this.selectedLoadError = selectedError
      ? evidenceErrorMessage(selectedError)
      : "";
    const modelError = model?.error || "";
    this.error = modelError
      ? evidenceErrorMessage(modelError)
      : this.selectedLoadError;
    this.notice = "";
    this.reviewChecklist = {};
    this.loadSelectedFields();
    this.activeStep = this.hasSelected ? this.recommendedInitialStep : "intake";
  }

  loadSelectedFields() {
    const selected = this.selected || {};
    this.editClaimantRef = selected.claimant_ref || "";
    this.editResearchQuestion = selected.research_question || "";
    this.editClassification = selected.classification || "confidential";
    this.editJurisdictionContext = selected.jurisdiction_context || "international";
    this.editExternalUrl = selected.external_url || "";
    this.editExternalPlatform = selected.external_platform || "";
    this.editExternalUsername = selected.external_username || "";
    this.editExternalObservedAt = localDatetimeInput(selected.external_observed_at_utc);
    this.editExternalDisplayedAt = selected.external_displayed_at || "";
    this.editRightsStatementRef = selected.rights_statement_ref || "";
    this.editRightsStatementReceivedAt = localDatetimeInput(selected.rights_statement_received_at_utc);
  }

  get hasCases() {
    return this.cases.length > 0;
  }

  get hasSelected() {
    return !!this.selected;
  }

  get selectedMutable() {
    return this.selected?.mutable === true;
  }

  get pendingCaseLoad() {
    return !this.hasSelected && this.requestedCaseRef.length > 0;
  }

  get caseRows() {
    return this.cases.map((row) => ({
      ...row,
      status_label: evidenceLabel(row.status),
      decision_label: evidenceLabel(row.decision),
    }));
  }

  get selectedHeader() {
    const selected = this.selected || {};
    return {
      status_label: evidenceLabel(selected.status),
      decision_label: evidenceLabel(selected.decision),
      classification_label: evidenceLabel(selected.classification),
    };
  }

  get selectedFinalization() {
    return this.selected?.finalization || { ready: false, blockers: [], warnings: [] };
  }

  get selectedFinalizationBlockers() {
    return (this.selectedFinalization.blockers || []).map((issue) => {
      const step = issueStep(issue.code);
      return {
        ...issue,
        title: humanizeEvidenceCode(issue.code),
        step,
        step_label: STEP_LABELS[step],
      };
    });
  }

  get selectedFinalizationWarnings() {
    return (this.selectedFinalization.warnings || []).map((issue) => ({
      ...issue,
      title: humanizeEvidenceCode(issue.code),
    }));
  }

  get selectedFinalizationBlockerCodes() {
    return new Set(this.selectedFinalizationBlockers.map((issue) => issue.code));
  }

  hasAnyBlocker(codes) {
    const current = this.selectedFinalizationBlockerCodes;
    return codes.some((code) => current.has(code));
  }

  stepState(key) {
    if (key === "intake") {
      return this.hasAnyBlocker([
        "rights_statement_missing",
        "rights_statement_reference_missing",
        "external_observation_time_missing",
      ]) ? "action" : "complete";
    }

    if (key === "evidence") {
      return this.hasAnyBlocker([
        "source_capture_missing",
        "external_evidence_missing",
        "rejected_evidence_present",
        "quarantine_review_incomplete",
      ]) ? "action" : "complete";
    }

    if (key === "identify") {
      return this.hasAnyBlocker([
        "media_snapshot_missing",
        "identify_snapshot_missing",
        "diagnostic_run_not_evidence",
        "synthetic_population_present",
        "identify_sanity_checks_failed",
        "attributed_account_missing",
        "fingerprint_assignment_missing",
        "assignment_after_observation",
      ]) ? "action" : "complete";
    }

    if (key === "review") {
      return this.hasAnyBlocker([
        "claimant_confirmation_missing",
        "technical_review_missing",
        "senior_review_missing",
        "four_eyes_review_missing",
        "privacy_review_missing",
        "current_review_rejected",
      ]) ? "action" : "complete";
    }

    if (key === "readiness") {
      return this.selectedFinalization.ready ? "complete" : "action";
    }

    if (key === "reports") {
      if (this.selectedPackages.length > 0) {
        return "complete";
      }
      return this.selectedReports.length > 0 ? "progress" : "not_started";
    }

    return this.selected?.legal_hold ? "attention" : "optional";
  }

  stepStateLabel(state) {
    return {
      complete: "Complete",
      action: "Action required",
      progress: "In progress",
      not_started: "Not started",
      attention: "Legal hold active",
      optional: "Optional",
    }[state] || evidenceLabel(state);
  }

  get workflowSteps() {
    return Object.entries(STEP_LABELS).map(([key, label], index) => {
      const state = this.stepState(key);
      return {
        key,
        label,
        number: index + 1,
        state,
        state_label: this.stepStateLabel(state),
        class_name: `mg-ev-step${this.activeStep === key ? " is-active" : ""} is-${state}`,
      };
    });
  }

  get recommendedInitialStep() {
    for (const key of ["intake", "evidence", "identify", "review"]) {
      if (this.stepState(key) === "action") {
        return key;
      }
    }
    return this.selectedFinalization.ready ? "reports" : "readiness";
  }

  get workflowStatusLabel() {
    if (!this.selectedMutable) {
      return `${evidenceLabel(this.selected?.status || "immutable")} · immutable`;
    }
    if (this.selectedFinalization.ready) {
      return "Ready for finalization";
    }
    const firstAction = this.workflowSteps.find((step) => step.state === "action");
    return firstAction ? `${firstAction.label}: action required` : "Review in progress";
  }

  get finalizationBlockerCount() {
    return this.selectedFinalizationBlockers.length;
  }

  get finalizationWarningCount() {
    return this.selectedFinalizationWarnings.length;
  }

  get claimantConfirmationAvailable() {
    return (
      this.selectedMutable &&
      String(this.selected?.rights_statement_ref || "").trim().length > 0 &&
      String(this.selected?.rights_statement_received_at_utc || "").length > 0
    );
  }

  get selectedObjects() {
    return (this.selected?.evidence_objects || []).map((object) => ({
      ...object,
      role_label: evidenceLabel(object.role),
      quarantine_status_label: evidenceLabel(object.quarantine_status),
    }));
  }

  get selectedReviews() {
    return (this.selected?.reviews || []).map((review) => ({
      ...review,
      review_kind_label: evidenceLabel(review.review_kind),
      outcome_label: evidenceLabel(review.outcome),
      reviewer_role_label: evidenceLabel(review.reviewer_role),
    }));
  }

  get reviewChecklistItems() {
    return (this.config?.required_review_checks || []).map((key) => ({
      key,
      checked: this.reviewChecklist[key] === true,
      label: humanizeEvidenceCode(key),
      help_key: `review_${key}`,
      help_label: `Help for ${humanizeEvidenceCode(key)}`,
    }));
  }

  get activeHelp() {
    return evidenceHelpTopic(this.activeHelpKey);
  }

  get helpOverlayClass() {
    return `mg-ev-help-popover is-${this.helpOverlayPlacement}`;
  }

  get reviewChecklistComplete() {
    return this.reviewChecklistItems.length > 0 && this.reviewChecklistItems.every((item) => item.checked);
  }

  get selectedReports() {
    return (this.selected?.reports || []).map((report) => ({
      ...report,
      status_label: evidenceLabel(report.status),
    }));
  }

  get selectedPackages() {
    return (this.selected?.packages || []).map((evidencePackage) => ({
      ...evidencePackage,
      status_label: evidenceLabel(evidencePackage.status),
      timestamp_status_label: evidenceLabel(evidencePackage.timestamp_status),
      cms_signature_integrity_label: cmsSignatureIntegrityLabel(
        evidencePackage.cms_signature_integrity_verified
      ),
    }));
  }

  get selectedIdentify() {
    const identify = this.selected?.identify_snapshots?.[0];
    if (!identify) {
      return null;
    }
    return {
      ...identify,
      decision_label: evidenceLabel(identify.decision),
      run_kind_label: evidenceLabel(identify.run_kind),
    };
  }

  get selectedChainOk() {
    return this.selected?.chain?.verification?.ok === true;
  }

  get reportLanguageLabel() {
    return String(this.config?.report_language || "en").toLowerCase() === "en" ? "English" : String(this.config?.report_language || "").toUpperCase();
  }

  get sealModeLabel() {
    if (this.config?.seal_mode === "cms_detached") {
      return this.config?.cms_seal_configured ? "CMS detached signature" : "CMS selected, not configured";
    }
    if (this.config?.seal_mode === "integrity_only") {
      return "SHA-256 integrity manifest";
    }
    return "configuration unavailable";
  }

  get timestampLabel() {
    return this.config?.timestamp_status === "configured" ? "configured" : "not configured";
  }

  get issuerName() {
    return String(this.config?.issuer_name || "").trim();
  }

  get operatorIdentity() {
    return String(this.config?.operator_identity || "").trim();
  }

  get hasIssuerIdentity() {
    return this.issuerName.length > 0;
  }

  get hasOperatorIdentity() {
    return this.operatorIdentity.length > 0;
  }

  get identitySettingsComplete() {
    return this.hasIssuerIdentity && this.hasOperatorIdentity;
  }

  formatUtc(value) {
    return utc(value);
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  }

  async request(url, options = {}) {
    this.busy = true;
    this.error = "";
    this.notice = "";
    try {
      return await ajax(url, options);
    } catch (error) {
      this.error = ajaxEvidenceErrorMessage(error);
      throw error;
    } finally {
      this.busy = false;
    }
  }

  async reloadList() {
    const q = encodeURIComponent(this.query.trim());
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases.json?limit=50&q=${q}`);
    this.cases = data?.cases || [];
    if (data?.config) {
      this.config = normalizeConfig(data.config);
      this.configLoaded = true;
    }
  }

  async reloadSelected() {
    if (!this.selected?.case_ref) {
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}.json`);
    this.selected = data?.case || null;
    if (data?.config) {
      this.config = normalizeConfig(data.config);
      this.configLoaded = true;
    }
    this.loadSelectedFields();
    const index = this.cases.findIndex((row) => row.case_ref === this.selected?.case_ref);
    if (index >= 0) {
      this.cases = this.cases.map((row, rowIndex) => (rowIndex === index ? { ...row, ...this.selected } : row));
    }
  }

  @action
  setField(field, event) {
    this[field] = event?.target?.value ?? "";
  }

  @action
  setUploadFile(event) {
    this.uploadFile = event?.target?.files?.[0] || null;
  }

  @action
  setReviewCheck(key, event) {
    this.reviewChecklist = { ...this.reviewChecklist, [key]: event?.target?.checked === true };
  }

  @action
  toggleHelp(key, event) {
    event?.preventDefault?.();
    event?.stopPropagation?.();

    if (!evidenceHelpTopic(key)) {
      return;
    }

    if (this.activeHelpKey === key) {
      this.closeHelp();
      return;
    }

    const trigger = event?.currentTarget;
    const rect = trigger?.getBoundingClientRect?.();
    if (!rect || typeof window === "undefined") {
      return;
    }

    const margin = 12;
    const gap = 8;
    const width = Math.min(390, Math.max(0, window.innerWidth - margin * 2));
    const idealLeft = rect.left + rect.width / 2 - width / 2;
    const left = Math.max(
      margin,
      Math.min(idealLeft, window.innerWidth - width - margin)
    );
    const spaceBelow = Math.max(0, window.innerHeight - rect.bottom - margin - gap);
    const spaceAbove = Math.max(0, rect.top - margin - gap);
    const availableSide = Math.max(spaceBelow, spaceAbove);
    const useViewportPanel = availableSide < 140;
    const placeAbove = !useViewportPanel && spaceBelow < 260 && spaceAbove > spaceBelow;
    const availableHeight = useViewportPanel
      ? Math.max(0, window.innerHeight - margin * 2)
      : placeAbove
        ? spaceAbove
        : spaceBelow;
    const top = useViewportPanel
      ? margin
      : placeAbove
        ? rect.top - gap
        : rect.bottom + gap;
    const transform = placeAbove ? "translateY(-100%)" : "none";

    this.helpOverlayPlacement = useViewportPanel
      ? "viewport"
      : placeAbove
        ? "above"
        : "below";
    this.helpOverlayStyle = htmlSafe(
      `left:${Math.round(left)}px;top:${Math.round(top)}px;width:${Math.round(
        width
      )}px;max-height:${Math.floor(availableHeight)}px;transform:${transform};`
    );
    this.helpTriggerElement = trigger;
    this.activeHelpKey = key;
    requestAnimationFrame(() => {
      document.getElementById("mg-ev-help-overlay")?.focus();
    });
  }

  @action
  handleHelpTriggerKeydown(key, event) {
    if (!["Enter", " ", "Spacebar"].includes(event?.key)) {
      return;
    }

    event.preventDefault();
    this.toggleHelp(key, event);
  }

  @action
  closeHelp() {
    const trigger = this.helpTriggerElement;
    this.activeHelpKey = "";
    this.helpOverlayStyle = htmlSafe("");
    this.helpTriggerElement = null;
    requestAnimationFrame(() => {
      if (trigger?.isConnected) {
        trigger.focus();
      }
    });
  }

  @action
  handleHelpKeydown(event) {
    if (event?.key === "Escape") {
      event.preventDefault();
      this.closeHelp();
    }
  }

  @action
  selectWorkflowStep(step) {
    if (!STEP_LABELS[step]) {
      return;
    }
    this.closeHelp();
    this.activeStep = step;
    requestAnimationFrame(() => {
      document.querySelector(".mg-ev-workflow-content")?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
  }

  @action
  goToIssue(issue) {
    this.selectWorkflowStep(issue?.step || "readiness");
  }

  @action
  async search(event) {
    event?.preventDefault?.();
    await this.reloadList();
  }

  @action
  async openCase(caseRef) {
    this.closeHelp();
    this.requestedCaseRef = caseRef;
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${caseRef}.json`);
    this.selected = data?.case || null;
    this.selectedLoadError = "";
    if (data?.config) {
      this.config = normalizeConfig(data.config);
      this.configLoaded = true;
    }
    this.loadSelectedFields();
    this.activeStep = this.recommendedInitialStep;
    window.history.replaceState(
      {},
      "",
      `/admin/plugins/media-gallery-evidence-cases?case_ref=${encodeURIComponent(caseRef)}`
    );
  }

  @action
  async retrySelectedCase() {
    if (!this.requestedCaseRef) {
      await this.reloadList();
      return;
    }

    try {
      await this.reloadList();
      const data = await this.request(
        `/admin/plugins/media-gallery/evidence-cases/${encodeURIComponent(
          this.requestedCaseRef
        )}.json`
      );
      this.selected = data?.case || null;
      this.selectedLoadError = "";
      if (data?.config) {
        this.config = normalizeConfig(data.config);
        this.configLoaded = true;
      }
      this.loadSelectedFields();
      this.activeStep = this.recommendedInitialStep;
      this.error = "";
    } catch (error) {
      this.selectedLoadError = ajaxEvidenceErrorMessage(
        error,
        `Evidence case ${this.requestedCaseRef} could not be loaded.`
      );
      this.error = this.selectedLoadError;
    }
  }

  @action
  closeCase() {
    this.closeHelp();
    this.selected = null;
    this.requestedCaseRef = "";
    this.selectedLoadError = "";
    this.error = "";
    this.notice = "";
    this.activeStep = "intake";
    window.history.replaceState({}, "", "/admin/plugins/media-gallery-evidence-cases");
  }

  @action
  async createCase(event) {
    event?.preventDefault?.();
    const data = await this.request("/admin/plugins/media-gallery/evidence-cases.json", {
      type: "POST",
      data: {
        media_public_id: this.newMediaPublicId,
        claimant_ref: this.newClaimantRef,
        research_question: this.newResearchQuestion,
        external_url: this.newExternalUrl,
        external_platform: this.newExternalPlatform,
        external_username: this.newExternalUsername,
        rights_statement_ref: this.newRightsStatementRef,
        rights_statement_received_at: utcDatetimeInput(this.newRightsStatementReceivedAt),
        classification: "confidential",
        jurisdiction_context: "international",
      },
    });
    this.selected = data?.case;
    this.requestedCaseRef = this.selected?.case_ref || "";
    this.selectedLoadError = "";
    this.loadSelectedFields();
    this.activeStep = "intake";
    this.newMediaPublicId = "";
    this.newClaimantRef = "";
    this.newResearchQuestion = "";
    this.newExternalUrl = "";
    this.newExternalPlatform = "";
    this.newExternalUsername = "";
    this.newRightsStatementRef = "";
    this.newRightsStatementReceivedAt = "";
    await this.reloadList();
    this.notice = `Evidence case ${this.selected?.case_ref} created.`;
    if (this.requestedCaseRef) {
      window.history.replaceState(
        {},
        "",
        `/admin/plugins/media-gallery-evidence-cases?case_ref=${encodeURIComponent(
          this.requestedCaseRef
        )}`
      );
    }
  }

  @action
  async saveCase(event) {
    event?.preventDefault?.();
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}.json`, {
      type: "PUT",
      data: {
        claimant_ref: this.editClaimantRef,
        research_question: this.editResearchQuestion,
        classification: this.editClassification,
        jurisdiction_context: this.editJurisdictionContext,
        external_url: this.editExternalUrl,
        external_platform: this.editExternalPlatform,
        external_username: this.editExternalUsername,
        external_observed_at: utcDatetimeInput(this.editExternalObservedAt),
        external_displayed_at: this.editExternalDisplayedAt,
        rights_statement_ref: this.editRightsStatementRef,
        rights_statement_received_at: utcDatetimeInput(this.editRightsStatementReceivedAt),
      },
    });
    this.selected = data?.case || this.selected;
    this.loadSelectedFields();
    this.notice = "Case intake updated. Existing approvals were invalidated when material fields changed.";
  }

  @action
  async uploadObject(event) {
    event?.preventDefault?.();
    if (!this.selected?.case_ref || !this.uploadFile) {
      this.error = "Select an evidence file first.";
      return;
    }
    this.busy = true;
    this.error = "";
    this.notice = "";
    try {
      const body = new FormData();
      body.append("file", this.uploadFile);
      body.append("role", this.uploadRole);
      body.append("description", this.uploadDescription);
      const response = await fetch(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/objects.json`, {
        method: "POST",
        body,
        credentials: "same-origin",
        headers: { "X-CSRF-Token": this.csrfToken(), "X-Requested-With": "XMLHttpRequest", Accept: "application/json" },
      });
      const data = await response.json();
      if (!response.ok || data?.ok === false) {
        throw new Error(
          evidenceErrorMessage(data, `Evidence upload failed (${response.status}).`)
        );
      }
      this.selected = data.case;
      this.notice = `Evidence object ${data?.object?.object_ref} stored and hashed.`;
      this.uploadFile = null;
      this.uploadDescription = "";
      event?.target?.reset?.();
    } catch (error) {
      this.error = ajaxEvidenceErrorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  @action
  async setQuarantine(objectRef, status) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/objects/${objectRef}/quarantine.json`, {
      type: "POST",
      data: { quarantine_status: status, reason: "Manual evidence quarantine review" },
    });
    this.selected = data.case;
    this.notice = `Quarantine status changed to ${evidenceLabel(status)}.`;
  }

  @action
  async confirmClaimant() {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/claimant-confirmation.json`, {
      type: "POST",
      data: { reason: "Rights claimant confirmation recorded by staff." },
    });
    this.selected = data.case;
    this.notice = "Claimant confirmation recorded.";
  }

  @action
  async addReview(kind, outcome) {
    if (outcome === "approved" && !this.reviewChecklistComplete) {
      this.error = "Complete every review checklist item before approval.";
      return;
    }
    if (outcome === "rejected" && !this.reviewReason.trim()) {
      this.error = "A reason is required when rejecting a review.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/reviews.json`, {
      type: "POST",
      data: { review_kind: kind, outcome, reason: this.reviewReason, checklist: this.reviewChecklist },
    });
    this.selected = data.case;
    this.reviewReason = "";
    this.reviewChecklist = {};
    this.notice = `${evidenceLabel(kind)} review recorded as ${evidenceLabel(outcome).toLowerCase()}.`;
  }

  @action
  async generateReport(final) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/reports.json`, {
      type: "POST",
      data: { final },
    });
    this.selected = data.case;
    this.notice = `${final ? "Final" : "Draft"} technical evidence report generated.`;
  }

  @action
  async createPackage() {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/packages.json`, {
      type: "POST",
      data: {},
    });
    this.selected = data.case;
    this.notice = data?.package?.status === "cms_signed" ? "CMS-signed integrity package generated. The embedded certificate signature verified; certificate-chain trust and timestamp remain external." : "SHA-256 integrity evidence package generated and verified.";
  }

  @action
  async verifyPackage(packageRef) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/packages/${packageRef}/verify.json`, {
      type: "POST",
      data: {},
    });
    this.notice = data?.verification?.ok
      ? "Package verification succeeded."
      : `Package verification failed: ${(data?.verification?.errors || [])
          .map((item) => humanizeEvidenceCode(item))
          .join(", ")}.`;
  }

  @action
  async setLegalHold(active) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/legal-hold.json`, {
      type: "POST",
      data: { active, reason: this.holdReason },
    });
    this.selected = data.case;
    this.holdReason = "";
    this.notice = active ? "Legal hold placed." : "Legal hold released.";
  }
}
