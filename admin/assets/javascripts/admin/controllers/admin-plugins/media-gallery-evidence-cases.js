import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import {
  ajaxEvidenceErrorMessage,
  evidenceErrorMessage,
  evidenceLabel,
  humanizeEvidenceCode,
} from "../../lib/media-gallery-evidence-ui";

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
    }));
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
  selectWorkflowStep(step) {
    if (!STEP_LABELS[step]) {
      return;
    }
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
