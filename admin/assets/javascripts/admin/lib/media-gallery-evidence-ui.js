const FRIENDLY_MESSAGES = {
  evidence_needs_rerun:
    "Run Forensics Identify again and create a new evidence case from the new result.",
  identify_attestation_legacy_result_requires_rerun:
    "This result uses an earlier evidence attestation format. Run Forensics Identify again and create the case from the new result.",
  identify_attestation_result_hash_mismatch:
    "The server-attested identify result changed during browser transport and cannot be imported safely. Run Forensics Identify again; check the server logs if a new result also fails.",
  identify_result_not_server_attested:
    "This identify result is not server-attested. Run Forensics Identify again after evidence reporting is enabled.",
  identify_attestation_signature_invalid:
    "The server attestation signature is invalid. Do not use this result as evidence; run Forensics Identify again and review the server logs if it repeats.",
  identify_attestation_signature_missing:
    "The identify result does not contain a complete server attestation. Run Forensics Identify again.",
  identify_attestation_schema_invalid:
    "The identify result uses an unsupported evidence attestation format. Run Forensics Identify again after updating the plugin.",
  identify_attestation_hash_canonicalization_invalid:
    "The identify result uses an unsupported evidence hash format. Run Forensics Identify again after updating the plugin.",
  case_not_mutable:
    "This evidence case can no longer be changed because it has already entered an immutable lifecycle stage.",
  invalid_datetime:
    "One of the entered dates or times is invalid. Select a valid date and time and try again.",
  rights_statement_missing:
    "Record when the rights claimant statement was received before confirming the claimant.",
  review_checklist_incomplete:
    "Complete every review checklist item before approving the review.",
  review_rejection_reason_missing:
    "Enter a reason before rejecting a review.",
  legal_hold_reason_missing:
    "Enter a reason before placing or releasing a legal hold.",
  final_report_missing:
    "Generate a final report before creating an evidence package.",
  evidence_case_not_ready:
    "This case is not ready for finalization. Complete the remaining items shown under Finalization readiness.",
  cms_seal_key_revoked:
    "The configured CMS signing-key ID is marked as revoked. Select a current key before creating another package.",
  cms_certificate_trust_not_configured:
    "The selected CMS certificate-trust mode is incomplete. Configure the required CA bundle or certificate pin.",
  pdfa_conversion_not_configured:
    "PDF/A-2b is selected, but Ghostscript, the reviewed PDF/A definition file and veraPDF are not all available.",
  pdfa_validation_failed:
    "The converted report did not pass local PDF/A-2b validation and was not accepted.",
  timestamp_not_configured:
    "RFC 3161 timestamping is selected, but the endpoint or trust configuration is incomplete.",
  timestamp_verification_failed:
    "The RFC 3161 response could not be verified against the request and configured trust source.",
  evidence_storage_low_space:
    "The evidence file was not stored because the private evidence filesystem would fall below its configured free-space reserve.",
  evidence_storage_unavailable:
    "The private evidence filesystem is unavailable or not writable. No evidence data was stored.",
  evidence_scan_queue_failed:
    "The evidence security check could not be queued. Check Sidekiq and the Discourse server logs.",
  quarantine_reason_required:
    "Enter a reason for the manual quarantine decision.",
  infected_evidence_cannot_be_marked_clean:
    "Evidence with a malware detection cannot be manually marked clean. Reject it or rescan a new corrected evidence object.",
  record_not_found:
    "The requested evidence case or evidence object could not be found.",
  invalid_access:
    "You do not have permission to perform this evidence action.",
  evidence_request_failed:
    "The evidence request could not be completed because of an internal error. Check the Discourse server logs for the recorded evidence error.",
};

const MACHINE_CODE = /^[a-z][a-z0-9_]*(?::.*)?$/;

const EVIDENCE_ACRONYMS = {
  cms: "CMS",
  hmac: "HMAC",
  id: "ID",
  ip: "IP",
  json: "JSON",
  pdf: "PDF",
  pdfa: "PDF/A",
  sha256: "SHA-256",
  url: "URL",
  utc: "UTC",
  warc: "WARC",
  tcp: "TCP",
  rfc: "RFC",
  tsa: "TSA",
  crl: "CRL",
  clamd: "clamd",
  ffprobe: "ffprobe",
};

function baseCode(value) {
  const raw = String(value || "").trim();
  return raw.split(":", 1)[0];
}

export function humanizeEvidenceCode(value) {
  const code = baseCode(value);
  if (!code) {
    return "Evidence request failed";
  }

  const words = code.split("_").map((word) => EVIDENCE_ACRONYMS[word] || word);
  const label = words.join(" ");
  return label.replace(/^./, (character) => character.toUpperCase());
}

export function evidenceLabel(value) {
  const text = humanizeEvidenceCode(value);
  return text === "Evidence request failed" && !value ? "—" : text;
}

export function evidenceErrorMessage(payloadOrCode, fallback) {
  if (
    typeof payloadOrCode === "string" &&
    payloadOrCode.trim() &&
    !MACHINE_CODE.test(payloadOrCode.trim())
  ) {
    return payloadOrCode.trim();
  }

  const payload =
    payloadOrCode && typeof payloadOrCode === "object" ? payloadOrCode : {};
  const rawCode =
    payload.error_code ?? payload.errorCode ??
    (typeof payloadOrCode === "string" ? payloadOrCode : "");
  const code = baseCode(rawCode);
  if (FRIENDLY_MESSAGES[code]) {
    return FRIENDLY_MESSAGES[code];
  }

  const serverMessage = String(payload.error || payload.message || "").trim();
  if (serverMessage && !MACHINE_CODE.test(serverMessage)) {
    return serverMessage;
  }
  if (serverMessage && FRIENDLY_MESSAGES[baseCode(serverMessage)]) {
    return FRIENDLY_MESSAGES[baseCode(serverMessage)];
  }
  if (serverMessage && MACHINE_CODE.test(serverMessage)) {
    return `${humanizeEvidenceCode(serverMessage)}.`;
  }
  if (code) {
    return `${humanizeEvidenceCode(code)}.`;
  }

  return fallback !== undefined
    ? fallback
    : FRIENDLY_MESSAGES.evidence_request_failed;
}

export function ajaxEvidenceErrorMessage(error, fallback) {
  const response = error?.jqXHR?.responseJSON;
  const errors = response?.errors;
  if (Array.isArray(errors) && errors.length > 0) {
    return errors.map((item) => evidenceErrorMessage(item)).join(" ");
  }
  if (response) {
    return evidenceErrorMessage(response, fallback);
  }

  const message = String(error?.message || "").trim();
  if (message) {
    return evidenceErrorMessage(message, fallback || message);
  }
  return fallback !== undefined
    ? fallback
    : FRIENDLY_MESSAGES.evidence_request_failed;
}
