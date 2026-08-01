import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

function errorMessage(error) {
  return (
    error?.jqXHR?.responseJSON?.error ||
    error?.jqXHR?.responseJSON?.errors?.join(" ") ||
    error?.message ||
    String(error)
  );
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

export default class AdminPluginsMediaGalleryEvidenceCasesController extends Controller {
  @tracked cases = [];
  @tracked selected = null;
  @tracked config = normalizeConfig({});
  @tracked configLoaded = false;
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

  initializeFromModel(model) {
    this.cases = model?.cases || [];
    this.selected = model?.selected || null;
    this.configLoaded = !!model?.config;
    this.config = normalizeConfig(model?.config);
    this.error = model?.error || "";
    this.notice = "";
    this.reviewChecklist = {};
    this.loadSelectedFields();
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

  get selectedFinalization() {
    return this.selected?.finalization || { ready: false, blockers: [], warnings: [] };
  }

  get selectedObjects() {
    return this.selected?.evidence_objects || [];
  }

  get selectedReviews() {
    return this.selected?.reviews || [];
  }

  get reviewChecklistItems() {
    return (this.config?.required_review_checks || []).map((key) => ({
      key,
      checked: this.reviewChecklist[key] === true,
      label: key.replaceAll("_", " ").replace(/^./, (character) => character.toUpperCase()),
    }));
  }

  get reviewChecklistComplete() {
    return this.reviewChecklistItems.length > 0 && this.reviewChecklistItems.every((item) => item.checked);
  }

  get selectedReports() {
    return this.selected?.reports || [];
  }

  get selectedPackages() {
    return this.selected?.packages || [];
  }

  get selectedIdentify() {
    return this.selected?.identify_snapshots?.[0] || null;
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
      this.error = errorMessage(error);
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
  async search(event) {
    event?.preventDefault?.();
    await this.reloadList();
  }

  @action
  async openCase(caseRef) {
    const data = await this.request(`/admin/plugins/media-gallery/evidence-cases/${caseRef}.json`);
    this.selected = data?.case || null;
    if (data?.config) {
      this.config = normalizeConfig(data.config);
      this.configLoaded = true;
    }
    this.loadSelectedFields();
  }

  @action
  closeCase() {
    this.selected = null;
    this.error = "";
    this.notice = "";
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
    this.loadSelectedFields();
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
        throw new Error(data?.error || `Upload failed (${response.status})`);
      }
      this.selected = data.case;
      this.notice = `Evidence object ${data?.object?.object_ref} stored and hashed.`;
      this.uploadFile = null;
      this.uploadDescription = "";
      event?.target?.reset?.();
    } catch (error) {
      this.error = errorMessage(error);
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
    this.notice = `Quarantine status changed to ${status}.`;
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
    this.notice = `${kind} review recorded as ${outcome}.`;
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
    this.notice = data?.verification?.ok ? "Package verification succeeded." : `Package verification failed: ${(data?.verification?.errors || []).join(", ")}`;
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
