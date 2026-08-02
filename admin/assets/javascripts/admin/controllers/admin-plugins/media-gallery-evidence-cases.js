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
    guidance: "The report language and PDF profile, package protection, certificate-trust mode, RFC 3161 timestamp status, release transport and configured issuer details for this evidence environment.",
    purpose: "Reviewers can distinguish basic SHA-256 integrity, CMS signature integrity, locally established certificate trust and an independently signed timestamp instead of treating them as one assurance level.",
    note: "PDF/A-2b, CMS and RFC 3161 are optional. Empty CMS or timestamp settings are correct when those features are not selected.",
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
    guidance: "Record the relevant geographic or legal context known at intake, such as a country or region relevant to the case, international, or unknown.",
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
  acquisition_security: {
    title: "Acquisition security",
    guidance_title: "How to read this status",
    guidance: "This panel shows whether optional private malware scanning, bounded ffprobe inspection and the private evidence filesystem are available.",
    purpose: "A scanner outage, size limit or low-storage condition must be visible and must never be interpreted as a clean result.",
    note: "ClamAV is optional and disabled by default. When disabled, staff must document a manual quarantine review before finalisation.",
  },
  malware_scan_status: {
    title: "Malware scan status",
    guidance_title: "What this means",
    guidance: "The status records whether a private ClamAV scan was queued, completed cleanly, detected malware, failed, was unavailable or skipped the file because of a configured size limit.",
    purpose: "The evidence workflow fails closed: only a clean scan or an explicitly documented manual review can satisfy quarantine policy.",
    note: "A clean result reduces risk but is not a guarantee that a file is harmless.",
  },
  technical_inspection_status: {
    title: "Technical inspection status",
    guidance_title: "What this means",
    guidance: "The plugin performs bounded, read-only technical inspection. Primary media is checked with ffprobe; screenshots, WARC, HTML, headers and rights statements receive role-appropriate file checks.",
    purpose: "This catches obvious type mismatches and records reproducible media metadata without modifying or transcoding the evidence bytes.",
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
    guidance: "An English, jurisdiction-neutral PDF summarising the research question, evidence hashes, immutable identify result, controlled conclusion, limitations and review references. The default output is deterministic PDF 1.4. Optional PDF/A-2b output is only claimed after local conversion and successful veraPDF validation.",
    purpose: "The draft is for review and is not sealed. The final report is only available after all mandatory controls and the selected PDF profile pass.",
    note: "The report attributes a distribution copy and account reference; it does not prove the conduct or identity of a natural person.",
  },
  sealed_evidence_package: {
    title: "Sealed Evidence Package",
    guidance_title: "What is generated",
    guidance: "A machine-verifiable archive containing the report, manifest, checksums, technical snapshots, chain-of-custody material and a self-contained offline verifier. CMS and RFC 3161 artefacts are included only when those generic options are configured.",
    purpose: "The package lets a recipient detect changed bytes, verify signature integrity, independently establish certificate trust and verify that a timestamp response covers the exact canonical manifest.",
    note: "The module does not assume or claim a qualified trust-service-provider status. Cryptographic integrity, certificate trust, timestamp verification and legal admissibility remain separate questions.",
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
    purpose: "The hold protects evidence from routine disposal while preserving an auditable reason, authority reference and periodic review history.",
    note: "An overdue review shows a warning but never releases the hold automatically. Use Review and extend legal hold to record a fresh review deadline.",
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
  controlled_release: {
    title: "Controlled package release",
    guidance_title: "What this does",
    guidance: "Creates an opaque, short-lived download link for one verified evidence package. The raw link token is shown only once and is never stored by the plugin.",
    purpose: "This lets an authorised lawyer, expert or other recipient obtain the exact immutable package without receiving an administrator account.",
    note: "Use HTTPS and send the link through an appropriately secure channel. A release link is not a legal approval by itself.",
  },
  release_package: {
    title: "Package to release",
    guidance_title: "How to choose",
    guidance: "Select the latest verified evidence package. Older package versions cannot be released through a new link because they may no longer represent the current case version.",
    purpose: "Tying each release to one package hash prevents ambiguity about which bytes were disclosed.",
  },
  release_recipient_ref: {
    title: "Recipient reference",
    guidance_title: "What to enter",
    guidance: "Enter a non-sensitive internal reference for the authorised recipient, such as a legal matter contact code, law firm reference or expert reference.",
    purpose: "The release audit can identify the authorised recipient context without exposing unnecessary personal information.",
    example: "COUNSEL-2026-014 or EXPERT-REF-82",
    note: "Do not enter an email address, private phone number or full personal identity unless your approved policy specifically requires it.",
  },
  release_purpose: {
    title: "Release purpose",
    guidance_title: "What to enter",
    guidance: "Describe why this package may be disclosed and what the recipient is authorised to do with it.",
    purpose: "Purpose limitation is an important privacy and accountability control, especially for evidence from an adult community.",
    example: "Independent technical review for matter LEGAL-2026-018.",
  },
  release_expiry: {
    title: "Link expiry",
    guidance_title: "How to choose",
    guidance: "Set how many hours the link remains usable. The configured server maximum is enforced even when a larger value is entered.",
    purpose: "Short expiry reduces the period in which a copied or intercepted link can be used.",
    note: "Use the shortest practical period and create a new link rather than extending an old one.",
  },
  release_download_limit: {
    title: "Download limit",
    guidance_title: "How to choose",
    guidance: "Choose how many download responses the server may authorise before the link is consumed.",
    purpose: "A one-response link is safest. A slightly higher limit can provide a controlled retry if a transfer is interrupted after the server has already authorised it.",
  },
  release_link: {
    title: "Release link shown once",
    guidance_title: "How to handle it",
    guidance: "Copy and deliver this link now. Its secret is placed after the # character, which browsers do not send in the initial server request. The plugin stores only a SHA-256 digest, so the link cannot be displayed again after leaving or reloading the page.",
    purpose: "Keeping the secret out of ordinary access logs and out of the database reduces accidental exposure.",
  },
  release_revocation_reason: {
    title: "Release revocation reason",
    guidance_title: "What to enter",
    guidance: "Explain why an active release link must be disabled, for example because it was sent to the wrong recipient, is no longer needed or may have been exposed.",
    purpose: "The reason is added to the append-only chain of custody so revocation remains accountable.",
    note: "Revocation prevents future downloads but cannot recall a package that was already downloaded.",
  },
  lifecycle_reason: {
    title: "Lifecycle reason",
    guidance_title: "What to enter",
    guidance: "Record the factual reason for withdrawing this case or replacing it with a newer case version.",
    purpose: "A clear reason explains why the old case remains preserved but should no longer be treated as the current technical record.",
    note: "Do not use accusatory language or include unnecessary sensitive personal information.",
  },
  replacement_case: {
    title: "Replacement case reference",
    guidance_title: "What to enter",
    guidance: "Enter the CASE-... reference of the newer evidence case that replaces this one. It must refer to the same media item and must not itself be withdrawn or superseded.",
    purpose: "The reciprocal link lets reviewers trace the correction without overwriting or deleting the older case.",
  },
  case_withdrawal: {
    title: "Withdraw case",
    guidance_title: "When to use",
    guidance: "Withdraw a case when the technical record should no longer be relied on because of an error, invalid scope, new information or another documented reason.",
    purpose: "Withdrawal preserves the immutable audit history while clearly preventing further release as a current case.",
    note: "Active release links are revoked automatically. Existing downloaded packages cannot be remotely recalled.",
  },
  case_supersession: {
    title: "Supersede case",
    guidance_title: "When to use",
    guidance: "Link this case to a newer replacement case for the same media item when a corrected or expanded investigation has been created.",
    purpose: "The old case remains intact and auditable, while recipients can be directed to the replacement case.",
    note: "Active release links for the old case are revoked automatically.",
  },
  governance_profile: {
    title: "Platform governance snapshot",
    guidance_title: "What this records",
    guidance: "Captures the current generic issuer, operator, website and optional policy/contact settings into this case. It does not copy your full privacy policy into the evidence report.",
    purpose: "A snapshot keeps old cases reproducible when the site operator, policy reference or report visibility settings change later.",
    note: "All platform values come from settings. No platform, country or legal basis is hardcoded in this module.",
  },
  retention_review: {
    title: "Retention review",
    guidance_title: "How to use it",
    guidance: "Record whether the case remains necessary, should be proposed for controlled disposal, or should have a previous disposal proposal cancelled.",
    purpose: "The module turns retention promises into reviewable actions without deleting evidence automatically.",
    note: "A disposal request is only a recorded proposal. It does not remove files and cannot be recorded while a legal hold is active.",
  },
  privacy_request: {
    title: "Privacy request",
    guidance_title: "What this records",
    guidance: "Register a request concerning access, rectification, erasure, restriction or objection using a non-sensitive requester reference.",
    purpose: "This preserves the request timeline and can temporarily restrict new final reports, packages, releases and annex exports while the request is reviewed.",
    note: "The module records workflow and decisions; it does not make the legal decision automatically.",
  },
  restricted_annex: {
    title: "Restricted Identity Annex",
    guidance_title: "When to use it",
    guidance: "Create a separately encrypted annex only when a concrete case requires specifically selected identity fields. It is disabled by default and never enters the standard report or package.",
    purpose: "Field-level selection, two-person approval and separate encryption reduce unnecessary disclosure of sensitive account data.",
    note: "Administrator status alone does not grant access. An explicit restricted-data group and an external encryption key are required.",
  },
  annex_event: {
    title: "Selected restricted event",
    guidance_title: "What to enter",
    guidance: "Enter one relevant IP, access, device or external identity event together with its source, time, necessity and limitations.",
    purpose: "The module intentionally avoids bulk history exports and requires a reason for every manually entered event.",
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

function displayJurisdictionContext(value) {
  const context = String(value || "").trim();
  return context.toLowerCase() === "international" ? "International" : context;
}

function canonicalJurisdictionContext(value) {
  const context = String(value || "").trim();
  return context.toLowerCase() === "international" ? "international" : context;
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
    seal_health: source.seal_health ?? source.sealHealth ?? {},
    timestamp_status: source.timestamp_status ?? source.timestampStatus ?? "",
    timestamp_health: source.timestamp_health ?? source.timestampHealth ?? {},
    pdf_profile: source.pdf_profile ?? source.pdfProfile ?? "pdf_1_4",
    pdf_health: source.pdf_health ?? source.pdfHealth ?? {},
    report_language: source.report_language ?? source.reportLanguage ?? "en",
    automatic_source_fetch: source.automatic_source_fetch ?? source.automaticSourceFetch ?? false,
    restricted_identity_annex: source.restricted_identity_annex ?? source.restrictedIdentityAnnex ?? false,
    restricted_identity_annex_configured: source.restricted_identity_annex_configured ?? source.restrictedIdentityAnnexConfigured ?? false,
    restricted_identity_annex_allowed_categories: source.restricted_identity_annex_allowed_categories ?? source.restrictedIdentityAnnexAllowedCategories ?? [],
    capabilities: source.capabilities ?? {},
    governance_current_profile: source.governance_current_profile ?? source.governanceCurrentProfile ?? {},
    retention_classes: source.retention_classes ?? source.retentionClasses ?? [],
    retention_actions: source.retention_actions ?? source.retentionActions ?? [],
    privacy_request_types: source.privacy_request_types ?? source.privacyRequestTypes ?? [],
    privacy_request_statuses: source.privacy_request_statuses ?? source.privacyRequestStatuses ?? [],
    release_transport_secure: source.release_transport_secure ?? source.releaseTransportSecure ?? false,
    release_insecure_test_override: source.release_insecure_test_override ?? source.releaseInsecureTestOverride ?? false,
    release_default_hours: source.release_default_hours ?? source.releaseDefaultHours ?? 72,
    release_max_hours: source.release_max_hours ?? source.releaseMaxHours ?? 168,
    release_max_downloads: source.release_max_downloads ?? source.releaseMaxDownloads ?? 5,
    acquisition_health: source.acquisition_health ?? source.acquisitionHealth ?? {},
    malware_scanner_mode: source.malware_scanner_mode ?? source.malwareScannerMode ?? "disabled",
    malware_scanner_enabled: source.malware_scanner_enabled ?? source.malwareScannerEnabled ?? false,
    scan_on_upload: source.scan_on_upload ?? source.scanOnUpload ?? false,
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
  evidence_inspection_incomplete: "evidence",
  evidence_role_validation_failed: "evidence",
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
  governance_profile_missing: "administration",
  retention_disposal_requested: "administration",
  privacy_processing_restricted: "administration",
};

const STEP_LABELS = {
  intake: "Case intake",
  evidence: "Evidence acquisition",
  identify: "Identify result",
  review: "Review & confirmation",
  readiness: "Finalization readiness",
  reports: "Reports & packages",
  release: "Controlled release",
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
  @tracked indexView = "cases";
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
  @tracked editJurisdictionContext = "International";
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
  @tracked holdAuthorityRef = "";
  @tracked releasePackageRef = "";
  @tracked releaseRecipientRef = "";
  @tracked releasePurpose = "";
  @tracked releaseExpiresInHours = "72";
  @tracked releaseMaxDownloads = "1";
  @tracked releaseRevocationReason = "";
  @tracked releaseUrl = "";
  @tracked lifecycleReason = "";
  @tracked replacementCaseRef = "";
  @tracked governanceReason = "";
  @tracked retentionAction = "retain";
  @tracked retentionExtensionDays = "";
  @tracked retentionReason = "";
  @tracked privacyRequestType = "access";
  @tracked privacyRequesterRef = "";
  @tracked privacyReceivedAt = "";
  @tracked privacyRestrictProcessing = false;
  @tracked privacyReason = "";
  @tracked privacyDecision = "";
  @tracked annexNecessityReason = "";
  @tracked annexSelections = { account_username: true, internal_account_id: true };
  @tracked annexEventCategory = "selected_ip_event";
  @tracked annexEventValue = "";
  @tracked annexEventTime = "";
  @tracked annexEventSourceRef = "";
  @tracked annexEventNecessity = "";
  @tracked annexEventLimitation = "";
  @tracked annexRecipientRef = "";
  @tracked annexExportPurpose = "";
  @tracked annexExportPassphrase = "";
  @tracked annexPreview = null;
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
    this.indexView = this.hasSelected || this.cases.length > 0 ? "cases" : "new";
  }

  loadSelectedFields() {
    const selected = this.selected || {};
    this.editClaimantRef = selected.claimant_ref || "";
    this.editResearchQuestion = selected.research_question || "";
    this.editClassification = selected.classification || "confidential";
    this.editJurisdictionContext = displayJurisdictionContext(selected.jurisdiction_context || "International");
    this.editExternalUrl = selected.external_url || "";
    this.editExternalPlatform = selected.external_platform || "";
    this.editExternalUsername = selected.external_username || "";
    this.editExternalObservedAt = localDatetimeInput(selected.external_observed_at_utc);
    this.editExternalDisplayedAt = selected.external_displayed_at || "";
    this.editRightsStatementRef = selected.rights_statement_ref || "";
    this.editRightsStatementReceivedAt = localDatetimeInput(selected.rights_statement_received_at_utc);
    this.releasePackageRef = selected.packages?.[0]?.package_ref || "";
    this.releaseExpiresInHours = String(this.config?.release_default_hours || 72);
    this.releaseMaxDownloads = "1";
    this.releaseUrl = "";
    this.governanceReason = "";
    this.retentionAction = "retain";
    this.retentionExtensionDays = "";
    this.retentionReason = "";
    this.privacyRequestType = "access";
    this.privacyRequesterRef = "";
    this.privacyReceivedAt = "";
    this.privacyRestrictProcessing = false;
    this.privacyReason = "";
    this.privacyDecision = "";
    this.annexPreview = null;
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

  get selectedRetentionReviewLabel() {
    return utc(this.selected?.retention_due_at_utc);
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
        "evidence_inspection_incomplete",
        "evidence_role_validation_failed",
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

    if (key === "release") {
      if (["withdrawn", "superseded"].includes(this.selected?.status)) {
        return "attention";
      }
      if (this.selectedPackages.length === 0) {
        return "not_started";
      }
      if (this.selectedDisclosures.some((item) => item.download_count > 0)) {
        return "complete";
      }
      if (this.selectedDisclosures.some((item) => item.active === true)) {
        return "progress";
      }
      return "ready";
    }

    if (["withdrawn", "superseded"].includes(this.selected?.status)) {
      return "attention";
    }
    if (this.selected?.legal_hold || this.selected?.privacy_request_open || this.selected?.processing_restricted || this.selected?.retention_review_overdue || !this.selected?.governance_profile_ref) {
      return "attention";
    }
    return "optional";
  }

  stepStateLabel(state) {
    return {
      complete: "Complete",
      action: "Action required",
      progress: "In progress",
      not_started: "Not started",
      attention: "Attention",
      ready: "Ready",
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
    if (this.stepState("administration") === "attention" && (this.hasAnyBlocker(["governance_profile_missing", "retention_disposal_requested", "privacy_processing_restricted"]) || this.selected?.retention_review_overdue)) {
      return "administration";
    }
    if (!this.selectedFinalization.ready) {
      return "readiness";
    }
    if (this.selectedPackages.length === 0) {
      return "reports";
    }
    if (["withdrawn", "superseded"].includes(this.selected?.status)) {
      return "administration";
    }
    return this.stepState("release") === "complete" ? "administration" : "release";
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
    const manualRoles = new Set([
      "external_original", "working_copy", "source_screenshot", "source_html",
      "source_warc", "source_headers", "rights_statement", "other",
    ]);
    return (this.selected?.evidence_objects || []).map((object) => {
      const scan = object.scan_metadata || {};
      const inspection = object.inspection_metadata || {};
      return {
        ...object,
        role_label: evidenceLabel(object.role),
        quarantine_status_label: evidenceLabel(object.quarantine_status),
        scan_state: scan.state || "not_recorded",
        scan_state_label: evidenceLabel(scan.state || "not_recorded"),
        scan_provider_label: evidenceLabel(scan.provider || this.config?.malware_scanner_mode || "disabled"),
        scan_signature: scan.signature || "",
        inspection_state: inspection.state || "not_recorded",
        inspection_state_label: evidenceLabel(inspection.state || "not_recorded"),
        inspection_message: inspection.message || "",
        inspection_warnings: Array.isArray(inspection.warnings)
          ? inspection.warnings.join(" ")
          : "",
        can_rescan:
          object.can_rescan === true &&
          (this.config?.malware_scanner_enabled === true || object.quarantine_status === "clean"),
        can_manual_review: manualRoles.has(object.role),
        can_mark_clean: manualRoles.has(object.role) && object.quarantine_status !== "infected",
      };
    });
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
      pdf_profile_label: report.pdf_profile || "PDF profile not recorded",
    }));
  }

  get selectedPackages() {
    return (this.selected?.packages || []).map((evidencePackage) => ({
      ...evidencePackage,
      status_label: evidenceLabel(evidencePackage.status),
      timestamp_status_label: evidenceLabel(evidencePackage.timestamp_status),
      timestamp_generated_at_label: utc(evidencePackage.timestamp_generated_at_utc),
      cms_signature_integrity_label: cmsSignatureIntegrityLabel(
        evidencePackage.cms_signature_integrity_verified
      ),
      certificate_trust_label: evidencePackage.certificate_trust_verified
        ? "verified"
        : evidencePackage.seal_method === "cms_detached"
          ? evidenceLabel(evidencePackage.certificate_trust_mode || "not_verified")
          : "not applicable",
      trusted_timestamp_label: evidencePackage.trusted_timestamp_verified
        ? "verified"
        : evidenceLabel(evidencePackage.timestamp_status || "not_configured"),
    }));
  }

  get selectedDisclosures() {
    return (this.selected?.disclosures || []).map((disclosure) => ({
      ...disclosure,
      status_label: evidenceLabel(disclosure.status),
      released_at_label: utc(disclosure.released_at_utc),
      expires_at_label: utc(disclosure.expires_at_utc),
      last_downloaded_at_label: utc(disclosure.last_downloaded_at_utc),
    }));
  }

  get releaseTransportReady() {
    return this.config?.release_transport_secure === true || this.config?.release_insecure_test_override === true;
  }

  get releaseTransportLabel() {
    if (this.config?.release_transport_secure === true) {
      return "HTTPS";
    }
    if (this.config?.release_insecure_test_override === true) {
      return "HTTP test override";
    }
    return "Blocked: HTTPS required";
  }

  get releaseCanCreate() {
    return (
      this.config?.can_finalize === true &&
      this.releaseTransportReady &&
      this.selectedPackages.length > 0 &&
      !["withdrawn", "superseded"].includes(this.selected?.status)
    );
  }

  get selectedLifecycleClosed() {
    return ["withdrawn", "superseded"].includes(this.selected?.status);
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

  get acquisitionHealth() {
    return this.config?.acquisition_health || {};
  }

  get scannerHealth() {
    return this.acquisitionHealth?.scanner || {};
  }

  get inspectorHealth() {
    return this.acquisitionHealth?.inspector || {};
  }

  get storageHealth() {
    return this.acquisitionHealth?.storage || {};
  }

  get scannerHealthLabel() {
    if (this.config?.malware_scanner_enabled !== true) {
      return "Disabled — manual quarantine review";
    }
    return evidenceLabel(this.scannerHealth.status || "unavailable");
  }

  get inspectorHealthLabel() {
    return evidenceLabel(this.inspectorHealth.status || "unavailable");
  }

  get storageHealthLabel() {
    const health = this.storageHealth;
    if (["available", "limited_space", "low_space"].includes(health.status)) {
      const prefix = health.status === "available" ? "" : `${evidenceLabel(health.status)} · `;
      return `${prefix}${this.formatBytes(health.free_bytes)} free · ${health.used_percent ?? "?"}% used`;
    }
    return evidenceLabel(health.status || "unavailable");
  }

  get storageReserveLabel() {
    return this.formatBytes(this.storageHealth?.minimum_free_bytes);
  }

  formatBytes(value) {
    const bytes = Number(value || 0);
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return "0 bytes";
    }
    const units = ["bytes", "KB", "MB", "GB", "TB"];
    const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    const amount = bytes / 1024 ** index;
    return `${amount >= 10 || index === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
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
    if (this.config?.timestamp_status === "configured") {
      return "RFC 3161 configured";
    }
    if (this.config?.timestamp_status === "disabled") {
      return "disabled (optional)";
    }
    return "selected, not configured";
  }

  get sealTrustLabel() {
    const health = this.config?.seal_health || {};
    if (this.config?.seal_mode !== "cms_detached") {
      return "not applicable";
    }
    if (health.trust_mode === "embedded_only") {
      return "embedded certificate only";
    }
    return health.trust_configured ? evidenceLabel(health.trust_mode) : "trust not configured";
  }

  get pdfProfileLabel() {
    const health = this.config?.pdf_health || {};
    if (this.config?.pdf_profile === "pdfa_2b") {
      return health.configured ? "PDF/A-2b configured" : "PDF/A-2b selected, not configured";
    }
    return "PDF 1.4";
  }

  get packageConfigurationReady() {
    const sealHealth = this.config?.seal_health || {};
    const timestampHealth = this.config?.timestamp_health || {};
    if (this.config?.seal_mode === "cms_detached") {
      if (!sealHealth.configured || sealHealth.key_revoked) {
        return false;
      }
      if (sealHealth.trust_mode !== "embedded_only" && !sealHealth.trust_configured) {
        return false;
      }
    }
    if (timestampHealth.mode === "rfc3161" && !timestampHealth.configured) {
      return false;
    }
    return true;
  }

  get packageConfigurationMessage() {
    if (this.packageConfigurationReady) {
      return "";
    }
    return "Complete the selected CMS or RFC 3161 configuration in Media Library settings before generating a package.";
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

  get capabilities() {
    return this.config?.capabilities || {};
  }

  get canOperateCases() {
    return this.capabilities.case_operator === true;
  }

  get canReviewTechnically() {
    return this.capabilities.technical_reviewer === true;
  }

  get canReviewSenior() {
    return this.capabilities.senior_reviewer === true;
  }

  get canAdministerPolicy() {
    return this.capabilities.policy_administrator === true;
  }

  get canAccessRestrictedAnnex() {
    return this.capabilities.restricted_approver === true;
  }

  get currentGovernanceProfile() {
    return this.config?.governance_current_profile || {};
  }

  get selectedGovernanceProfile() {
    return this.selected?.governance_snapshot || {};
  }

  get retentionActionOptions() {
    return (this.config?.retention_actions || []).map((value) => ({ value, label: evidenceLabel(value) }));
  }

  get selectedLegalHolds() {
    return (this.selected?.legal_holds || []).map((hold) => ({
      ...hold,
      action_label: evidenceLabel(hold.action),
      occurred_at_label: utc(hold.occurred_at_utc),
      review_due_at_label: utc(hold.review_due_at_utc),
    }));
  }

  get latestLegalHoldReview() {
    const rows = this.selectedLegalHolds;
    return rows.length > 0 ? rows[rows.length - 1] : null;
  }

  get selectedRetentionReviews() {
    return (this.selected?.retention_reviews || []).map((review) => ({
      ...review,
      action_label: evidenceLabel(review.action),
      retention_class_label: evidenceLabel(review.retention_class),
      occurred_at_label: utc(review.occurred_at_utc),
      next_due_at_label: utc(review.next_due_at_utc),
    }));
  }

  get selectedPrivacyRequests() {
    return (this.selected?.privacy_requests || []).map((request) => ({
      ...request,
      request_type_label: evidenceLabel(request.request_type),
      status_label: evidenceLabel(request.status),
      received_at_label: utc(request.received_at_utc),
      due_at_label: utc(request.due_at_utc),
      open: ["open", "under_review"].includes(request.status),
    }));
  }

  get selectedIdentityAnnexes() {
    return (this.selected?.identity_annexes || []).map((annex) => ({
      ...annex,
      status_label: evidenceLabel(annex.status),
      categories_label: (annex.categories || []).map((item) => evidenceLabel(item)).join(", "),
      created_at_label: utc(annex.created_at_utc),
    }));
  }

  get annexAllowedCategories() {
    return this.config?.restricted_identity_annex_allowed_categories || [];
  }

  annexCategoryAllowed(category) {
    return this.annexAllowedCategories.includes(category);
  }

  get restrictedAnnexAvailable() {
    return this.config?.restricted_identity_annex === true && this.config?.restricted_identity_annex_configured === true;
  }

  get annexAllowEmail() { return this.annexCategoryAllowed("email_address"); }
  get annexAllowSelectedIp() { return this.annexCategoryAllowed("selected_ip_event"); }
  get annexAllowSelectedAccess() { return this.annexCategoryAllowed("selected_access_event"); }
  get annexAllowDeviceHint() { return this.annexCategoryAllowed("device_hint"); }
  get annexAllowCustomReference() { return this.annexCategoryAllowed("custom_identity_reference"); }
  get annexHasOptionalEvents() {
    return this.annexAllowSelectedIp || this.annexAllowSelectedAccess || this.annexAllowDeviceHint || this.annexAllowCustomReference;
  }

  get annexPreviewText() {
    return this.annexPreview ? JSON.stringify(this.annexPreview, null, 2) : "";
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
  selectIndexView(view) {
    if (!["cases", "new"].includes(view)) {
      return;
    }
    this.closeHelp();
    this.indexView = view;
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
  setBooleanField(field, event) {
    this[field] = event?.target?.checked === true;
  }

  @action
  setAnnexSelection(key, event) {
    this.annexSelections = { ...this.annexSelections, [key]: event?.target?.checked === true };
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
    this.indexView = "cases";
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
        jurisdiction_context: canonicalJurisdictionContext(this.editJurisdictionContext),
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
      if (this.config?.scan_on_upload && this.config?.malware_scanner_enabled) {
        this.notice = `Evidence object ${data?.object?.object_ref} stored, hashed and queued for private malware scanning and technical inspection.`;
      } else if (this.config?.scan_on_upload) {
        this.notice = `Evidence object ${data?.object?.object_ref} stored and hashed. Record a manual clean review before technical inspection can run.`;
      } else {
        this.notice = `Evidence object ${data?.object?.object_ref} stored and hashed. Complete the quarantine review and run the security checks manually.`;
      }
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
    const defaultReason = status === "clean"
      ? "Manual quarantine review completed; no suspicious indicators were observed."
      : "Evidence rejected during manual quarantine review.";
    const reason = window.prompt("Record the reason for this manual quarantine decision:", defaultReason);
    if (reason === null) {
      return;
    }
    if (!String(reason).trim()) {
      this.error = "Enter a reason for the manual quarantine decision.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/objects/${objectRef}/quarantine.json`, {
      type: "POST",
      data: { quarantine_status: status, reason: String(reason).trim() },
    });
    this.selected = data.case;
    this.notice = status === "clean" && data?.object?.storage_kind === "file"
      ? "Manual clean review recorded; bounded technical inspection was queued."
      : `Quarantine status changed to ${evidenceLabel(status)}.`;
  }

  @action
  async rescanObject(objectRef) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/objects/${objectRef}/rescan.json`, {
      type: "POST",
      data: {},
    });
    this.selected = data.case;
    this.notice = "Evidence security checks were queued. Refresh this case after the background job completes.";
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
    this.releasePackageRef = data?.package?.package_ref || this.selectedPackages[0]?.package_ref || "";
    if (data?.package?.status === "sealed") {
      this.notice = "Evidence package generated with a locally verified RFC 3161 timestamp.";
    } else if (data?.package?.status === "cms_signed") {
      this.notice = data?.package?.certificate_trust_verified
        ? "CMS-signed evidence package generated with locally verified certificate trust."
        : "CMS-signed integrity package generated; signature integrity verified against the embedded certificate.";
    } else {
      this.notice = "SHA-256 integrity evidence package generated and verified.";
    }
  }

  @action
  async verifyPackage(packageRef) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/packages/${packageRef}/verify.json`, {
      type: "POST",
      data: {},
    });
    if (data?.verification?.ok) {
      const warnings = (data?.verification?.warnings || [])
        .map((item) => humanizeEvidenceCode(item))
        .join(", ");
      this.notice = `Package integrity verification succeeded. CMS trust: ${data?.verification?.certificate_trust_verified ? "verified" : "not currently established"}; RFC 3161 timestamp: ${data?.verification?.trusted_timestamp_verified ? "verified" : "not present or not currently established"}.${warnings ? ` Current assurance warnings: ${warnings}.` : ""}`;
    } else {
      this.notice = `Package verification failed: ${(data?.verification?.errors || [])
        .map((item) => humanizeEvidenceCode(item))
        .join(", ")}.`;
    }
  }

  @action
  async createRelease(event) {
    event?.preventDefault?.();
    if (!this.releasePackageRef) {
      this.error = "Select an evidence package first.";
      return;
    }
    if (!this.releaseRecipientRef.trim()) {
      this.error = "Enter a non-sensitive recipient reference.";
      return;
    }
    if (!this.releasePurpose.trim()) {
      this.error = "Describe the authorised purpose for this release.";
      return;
    }

    const data = await this.request(
      `/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/releases.json`,
      {
        type: "POST",
        data: {
          package_ref: this.releasePackageRef,
          recipient_ref: this.releaseRecipientRef,
          purpose: this.releasePurpose,
          expires_in_hours: this.releaseExpiresInHours,
          max_downloads: this.releaseMaxDownloads,
        },
      }
    );
    this.selected = data.case;
    this.releaseUrl = data.release_url || "";
    this.releaseRecipientRef = "";
    this.releasePurpose = "";
    this.notice = "Controlled release link created. Copy it now; the raw token will not be shown again.";
  }

  @action
  async revokeRelease(disclosureRef) {
    if (!this.releaseRevocationReason.trim()) {
      this.error = "Enter a revocation reason before revoking a release link.";
      return;
    }
    if (!window.confirm("Revoke this evidence release link? Existing downloaded copies cannot be recalled.")) {
      return;
    }
    const data = await this.request(
      `/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/releases/${encodeURIComponent(disclosureRef)}/revoke.json`,
      {
        type: "POST",
        data: { reason: this.releaseRevocationReason },
      }
    );
    this.selected = data.case;
    this.releaseRevocationReason = "";
    this.releaseUrl = "";
    this.notice = "Evidence release link revoked.";
  }

  @action
  async copyReleaseUrl() {
    if (!this.releaseUrl) {
      return;
    }
    try {
      if (window.isSecureContext && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(this.releaseUrl);
      } else {
        const input = document.getElementById("mg-ev-release-url");
        input?.focus();
        input?.select();
        if (!document.execCommand?.("copy")) {
          throw new Error("clipboard_copy_unavailable");
        }
      }
      this.notice = "Release link copied to the clipboard.";
    } catch {
      this.error = "The browser could not copy the link. Select and copy it manually.";
    }
  }

  @action
  async applyLifecycleAction(action) {
    if (!this.lifecycleReason.trim()) {
      this.error = "Enter a reason for the lifecycle action.";
      return;
    }
    if (action === "supersede" && !this.replacementCaseRef.trim()) {
      this.error = "Enter the replacement case reference.";
      return;
    }
    const confirmation = action === "withdraw"
      ? "Withdraw this evidence case and revoke all active release links?"
      : `Supersede this case with ${this.replacementCaseRef.trim()} and revoke all active release links?`;
    if (!window.confirm(confirmation)) {
      return;
    }
    const data = await this.request(
      `/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/lifecycle.json`,
      {
        type: "POST",
        data: {
          lifecycle_action: action,
          reason: this.lifecycleReason,
          replacement_case_ref: this.replacementCaseRef,
        },
      }
    );
    this.selected = data.case;
    this.lifecycleReason = "";
    this.replacementCaseRef = "";
    this.releaseUrl = "";
    await this.reloadList();
    this.notice = action === "withdraw"
      ? "Evidence case withdrawn."
      : "Evidence case superseded by the replacement case.";
  }

  @action
  async captureGovernanceProfile() {
    const force = Boolean(this.selected?.governance_profile_ref);
    if (force && !this.governanceReason.trim()) {
      this.error = "Enter a reason before replacing the case governance snapshot.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/governance.json`, {
      type: "POST",
      data: { force, reason: this.governanceReason },
    });
    this.selected = data.case;
    if (data.config) {
      this.config = normalizeConfig(data.config);
    }
    this.governanceReason = "";
    this.notice = force ? "Governance profile snapshot replaced and audited." : "Current governance profile captured for this case.";
  }

  @action
  async recordRetentionReview(event) {
    event?.preventDefault?.();
    if (!this.retentionReason.trim()) {
      this.error = "Enter a reason for the retention decision.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/retention-reviews.json`, {
      type: "POST",
      data: {
        retention_action: this.retentionAction,
        extension_days: this.retentionExtensionDays,
        reason: this.retentionReason,
      },
    });
    this.selected = data.case;
    this.retentionReason = "";
    this.retentionExtensionDays = "";
    this.notice = "Retention review recorded. No evidence was deleted.";
  }

  @action
  async createPrivacyRequest(event) {
    event?.preventDefault?.();
    if (!this.privacyRequesterRef.trim()) {
      this.error = "Enter a non-sensitive requester reference.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/privacy-requests.json`, {
      type: "POST",
      data: {
        request_type: this.privacyRequestType,
        privacy_requester_ref: this.privacyRequesterRef,
        received_at: utcDatetimeInput(this.privacyReceivedAt),
        processing_restricted: this.privacyRestrictProcessing,
        privacy_reason: this.privacyReason,
      },
    });
    this.selected = data.case;
    this.privacyRequesterRef = "";
    this.privacyReceivedAt = "";
    this.privacyRestrictProcessing = false;
    this.privacyReason = "";
    this.notice = "Privacy request recorded.";
  }

  @action
  async updatePrivacyRequest(requestRef, status, processingRestricted) {
    const closed = ["resolved", "rejected", "withdrawn"].includes(status);
    if (closed && !this.privacyDecision.trim()) {
      this.error = "Enter the decision before closing a privacy request.";
      return;
    }
    const payload = {
      status,
      privacy_decision: this.privacyDecision,
      privacy_reason: this.privacyReason,
    };
    if (typeof processingRestricted === "boolean") {
      payload.processing_restricted = processingRestricted;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/privacy-requests/${encodeURIComponent(requestRef)}.json`, {
      type: "PUT",
      data: payload,
    });
    this.selected = data.case;
    this.privacyDecision = "";
    this.privacyReason = "";
    this.notice = `Privacy request marked ${evidenceLabel(status).toLowerCase()}.`;
  }

  @action
  async createIdentityAnnex(event) {
    event?.preventDefault?.();
    if (!this.annexNecessityReason.trim()) {
      this.error = "Explain why the selected restricted identity fields are necessary.";
      return;
    }
    const selections = { ...this.annexSelections };
    if (this.annexEventValue.trim() && this.annexCategoryAllowed(this.annexEventCategory)) {
      selections[this.annexEventCategory] = {
        value: this.annexEventValue,
        event_time: this.annexEventTime,
        source_ref: this.annexEventSourceRef,
        necessity: this.annexEventNecessity,
        limitation: this.annexEventLimitation,
      };
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/identity-annexes.json`, {
      type: "POST",
      data: { annex_selections: selections, annex_necessity_reason: this.annexNecessityReason },
    });
    this.selected = data.case;
    this.annexNecessityReason = "";
    this.annexEventValue = "";
    this.annexEventTime = "";
    this.annexEventSourceRef = "";
    this.annexEventNecessity = "";
    this.annexEventLimitation = "";
    this.notice = "Encrypted Restricted Identity Annex created and submitted for two-person approval.";
  }

  @action
  async viewIdentityAnnex(annexRef) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/identity-annexes/${encodeURIComponent(annexRef)}.json`);
    this.annexPreview = data.payload || null;
    this.notice = "Restricted annex decrypted for this authorized view. The access was audited.";
  }

  @action
  closeAnnexPreview() {
    this.annexPreview = null;
  }

  @action
  async approveIdentityAnnex(annexRef, approvalKind) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/identity-annexes/${encodeURIComponent(annexRef)}/approve.json`, {
      type: "POST",
      data: { approval_kind: approvalKind, reason: this.annexNecessityReason },
    });
    this.selected = data.case;
    this.notice = `${evidenceLabel(approvalKind)} annex approval recorded.`;
  }

  @action
  async exportIdentityAnnex(annexRef) {
    if (!this.annexRecipientRef.trim() || !this.annexExportPurpose.trim()) {
      this.error = "Enter a recipient reference and authorized export purpose.";
      return;
    }
    if (this.annexExportPassphrase.length < 16) {
      this.error = "Use an annex export passphrase of at least 16 characters.";
      return;
    }
    this.busy = true;
    this.error = "";
    try {
      const body = new URLSearchParams({
        annex_recipient_ref: this.annexRecipientRef,
        annex_purpose: this.annexExportPurpose,
        annex_passphrase: this.annexExportPassphrase,
      });
      const response = await fetch(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/identity-annexes/${encodeURIComponent(annexRef)}/export`, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-CSRF-Token": this.csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
        },
        body,
      });
      if (!response.ok) {
        let payload = null;
        try { payload = await response.json(); } catch {}
        throw new Error(evidenceErrorMessage(payload, `Restricted annex export failed (${response.status}).`));
      }
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `${annexRef}-encrypted.json`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
      this.annexRecipientRef = "";
      this.annexExportPurpose = "";
      this.annexExportPassphrase = "";
      await this.reloadSelected();
      this.notice = "Encrypted Restricted Identity Annex exported. Deliver the passphrase through a separate secure channel.";
    } catch (error) {
      this.error = ajaxEvidenceErrorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  @action
  async setLegalHold(active) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/legal-hold.json`, {
      type: "POST",
      data: { active, reason: this.holdReason, authority_ref: this.holdAuthorityRef },
    });
    this.selected = data.case;
    this.holdReason = "";
    this.holdAuthorityRef = "";
    this.notice = active ? "Legal hold placed." : "Legal hold released.";
  }

  @action
  async reviewLegalHold() {
    if (!this.holdReason.trim()) {
      this.error = "Enter a reason for the legal hold review.";
      return;
    }
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${this.selected.case_ref}/legal-hold/review.json`, {
      type: "POST",
      data: { reason: this.holdReason, authority_ref: this.holdAuthorityRef },
    });
    this.selected = data.case;
    this.holdReason = "";
    this.holdAuthorityRef = "";
    this.notice = "Legal hold reviewed and its review deadline extended.";
  }
}
