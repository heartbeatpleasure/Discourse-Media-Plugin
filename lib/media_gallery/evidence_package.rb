# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "rubygems/package"
require "securerandom"
require "zlib"

module ::MediaGallery
  module EvidencePackage
    module_function

    PACKAGE_SCHEMA = "media-gallery-evidence-package-v1.2"
    SUPPORTED_PACKAGE_SCHEMAS = %w[media-gallery-evidence-package-v1.1 media-gallery-evidence-package-v1.2].freeze
    MAX_ARCHIVE_ENTRIES = 2_000
    MAX_VERIFY_UNCOMPRESSED_BYTES = 256 * 1024 * 1024

    Entry = Struct.new(:path, :role, :size, :sha256, :bytes, :source_path, keyword_init: true)

    def create!(evidence_case:, report:, user:)
      ::MediaGallery::EvidenceAuthorization.ensure!(user, :senior_reviewer)
      raise ArgumentError, "report_case_mismatch" unless report.evidence_case_id == evidence_case.id
      raise ArgumentError, "final_report_required" unless %w[final_unsealed final_sealed].include?(report.status)
      latest_final = evidence_case.reports.where(status: %w[final_unsealed final_sealed]).order(version: :desc).first
      raise ArgumentError, "latest_final_report_required" unless latest_final&.id == report.id
      material_cutoff = ::MediaGallery::EvidenceChain.latest_report_material_event_at(evidence_case)
      raise ArgumentError, "final_report_stale_after_material_change" if report.immutable_at.blank? || report.immutable_at < material_cutoff
      raise ArgumentError, "case_not_mutable" unless evidence_case.mutable?
      if ::MediaGallery::EvidencePolicy.seal_mode == "cms_detached" && !::MediaGallery::EvidencePolicy.cms_seal_configured?
        raise ArgumentError, "cms_seal_not_configured"
      end

      policy = ::MediaGallery::EvidencePolicy.finalization_blockers(evidence_case)
      raise ArgumentError, "evidence_case_not_ready:#{policy[:blockers].map { |b| b[:code] }.join(',')}" unless policy[:ready]

      generated_at = Time.now.utc
      version = evidence_case.packages.maximum(:version).to_i + 1
      package_ref = ::MediaGallery::EvidenceReference.package_ref(case_ref: evidence_case.case_ref, version: version)
      entries, exclusions = payload_entries(evidence_case, report)
      package_info = package_info_data(evidence_case, report, package_ref, generated_at)
      entries << bytes_entry("00_manifest/package-info.json", "package_metadata", pretty_json(package_info))
      entries << bytes_entry("00_manifest/verification.txt", "verification_instructions", verification_text(package_ref))

      manifest = manifest_data(evidence_case, report, package_ref, generated_at, entries, exclusions)
      manifest_bytes = canonical_pretty_json(manifest)
      manifest_sha256 = Digest::SHA256.hexdigest(manifest_bytes)
      seal = create_seal(manifest_bytes)

      final_entries = entries.dup
      final_entries << bytes_entry("00_manifest/manifest.json", "canonical_manifest", manifest_bytes)
      if seal[:signature]
        final_entries << bytes_entry("00_manifest/seal-signature.p7s", "cms_detached_signature", seal[:signature])
        final_entries << bytes_entry("00_manifest/seal-certificate.pem", "seal_certificate", seal[:certificate_pem])
      end
      checksums = final_entries.sort_by(&:path).map { |entry| "#{entry.sha256}  #{entry.path}" }.join("\n") + "\n"
      final_entries << bytes_entry("00_manifest/checksums.sha256", "checksum_index", checksums)

      validate_entries!(final_entries)
      storage_ref = "#{package_ref}-#{SecureRandom.hex(6)}"
      path = ::MediaGallery::EvidenceVault.package_path(evidence_case.case_ref, storage_ref)
      write_tar_gz!(path, final_entries)
      package_sha256 = Digest::SHA256.file(path).hexdigest
      verification = verify_path(path, expected_manifest_sha256: manifest_sha256)
      raise "generated_package_verification_failed:#{verification[:errors].join(',')}" unless verification[:ok]

      status = seal[:method] == "cms_detached" && verification[:cms_signature_integrity_verified] ? "cms_signed" : "integrity_only"
      record = nil
      ::MediaGallery::ForensicEvidenceCase.transaction do
        record = ::MediaGallery::ForensicEvidencePackage.create!(
          evidence_case: evidence_case,
          evidence_report: report,
          package_ref: package_ref,
          version: version,
          status: status,
          file_path: ::MediaGallery::EvidenceVault.relative_path(path),
          package_sha256: package_sha256,
          manifest_sha256: manifest_sha256,
          size_bytes: File.size(path),
          seal_method: seal[:method],
          seal_key_id: seal[:key_id],
          signature_verified: verification[:cms_signature_integrity_verified],
          timestamp_status: "not_configured",
          immutable_at: generated_at,
          created_by: user,
          metadata: {
            "package_schema" => PACKAGE_SCHEMA,
            "entry_count" => final_entries.length,
            "excluded_objects" => exclusions,
            "verification" => verification.except(:files),
            "jurisdiction_profile" => "international_technical_core",
            "trusted_timestamp" => "not_configured",
            "certificate_trust" => "not_verified_by_builtin_verifier",
          },
        )
        evidence_case.update!(status: "packaged", updated_by: user)
        ::MediaGallery::EvidenceChain.record!(
          evidence_case: evidence_case,
          event_type: status == "cms_signed" ? "cms_integrity_package_created" : "integrity_package_created",
          user: user,
          object_ref: record.package_ref,
          details: {
            package_version: version,
            package_sha256: package_sha256,
            manifest_sha256: manifest_sha256,
            seal_method: record.seal_method,
            cms_signature_integrity_verified: record.signature_verified,
            certificate_trust_verified: false,
            timestamp_status: record.timestamp_status,
          },
        )
      end
      ::MediaGallery::EvidenceRetention.apply!(evidence_case: evidence_case.reload, user: user, anchor: generated_at, reason: "Evidence package creation changed the retention class.", force: true)
      record
    rescue
      File.chmod(0o640, path) rescue nil if defined?(path) && path.present? && File.file?(path)
      FileUtils.rm_f(path) if defined?(path) && path.present? && (!defined?(record) || record.blank? || !::MediaGallery::ForensicEvidencePackage.where(id: record.id).exists?)
      raise
    end

    def absolute_path(package)
      root = ::MediaGallery::EvidenceVault.ensure_root!
      path = ::MediaGallery::PathSecurity.safe_join!(root, package.file_path.to_s)
      raise Discourse::NotFound unless File.file?(path)
      raise Discourse::NotFound unless ::MediaGallery::PathSecurity.realpath_under?(path, root)
      raise "package_hash_mismatch" unless Digest::SHA256.file(path).hexdigest == package.package_sha256

      path
    end

    def verify(package)
      verify_path(absolute_path(package), expected_manifest_sha256: package.manifest_sha256)
    end

    def verify_path(path, expected_manifest_sha256: nil)
      files = read_tar_entries(path)
      errors = []
      checksum_bytes = files["00_manifest/checksums.sha256"]
      manifest_bytes = files["00_manifest/manifest.json"]
      errors << "checksums_missing" if checksum_bytes.blank?
      errors << "manifest_missing" if manifest_bytes.blank?

      expected = parse_checksums(checksum_bytes)
      expected.each do |entry_path, sha|
        bytes = files[entry_path]
        if bytes.nil?
          errors << "missing:#{entry_path}"
        elsif Digest::SHA256.hexdigest(bytes) != sha
          errors << "hash_mismatch:#{entry_path}"
        end
      end
      unlisted = files.keys - expected.keys - ["00_manifest/checksums.sha256"]
      errors.concat(unlisted.map { |entry_path| "unlisted:#{entry_path}" })

      manifest_sha = manifest_bytes.present? ? Digest::SHA256.hexdigest(manifest_bytes) : nil
      if expected_manifest_sha256.present? && manifest_sha != expected_manifest_sha256.to_s
        errors << "manifest_hash_mismatch"
      end
      manifest = nil
      begin
        manifest = JSON.parse(manifest_bytes) if manifest_bytes.present?
      rescue JSON::ParserError
        errors << "manifest_invalid_json"
      end
      if manifest.is_a?(Hash)
        errors << "manifest_schema_mismatch" unless SUPPORTED_PACKAGE_SCHEMAS.include?(manifest["schema"].to_s)
        manifest_paths = []
        Array(manifest["files"]).each do |row|
          next unless row.is_a?(Hash)
          entry_path = safe_archive_path(row["path"])
          if manifest_paths.include?(entry_path)
            errors << "manifest_duplicate_file:#{entry_path}"
            next
          end
          manifest_paths << entry_path
          bytes = files[entry_path]
          errors << "manifest_file_missing:#{entry_path}" if bytes.nil?
          errors << "manifest_file_hash_mismatch:#{entry_path}" if bytes.present? && Digest::SHA256.hexdigest(bytes) != row["sha256"].to_s
          errors << "manifest_file_size_mismatch:#{entry_path}" if bytes.present? && bytes.bytesize != row["size"].to_i
        end
        control_paths = %w[
          00_manifest/manifest.json 00_manifest/checksums.sha256
          00_manifest/seal-signature.p7s 00_manifest/seal-certificate.pem
        ]
        (files.keys - manifest_paths - control_paths).each { |entry_path| errors << "not_declared_in_manifest:#{entry_path}" }
      end
      verify_report_metadata(
        files["01_report/report-metadata.json"],
        files["01_report/technical-evidence-report.pdf"],
        errors,
      )
      verify_external_chain(files["07_chain-of-custody/events.jsonl"], errors)

      signature_verified = false
      signature = files["00_manifest/seal-signature.p7s"]
      certificate = files["00_manifest/seal-certificate.pem"]
      if signature.present? || certificate.present?
        if signature.blank? || certificate.blank? || manifest_bytes.blank?
          errors << "incomplete_cms_seal"
        else
          signature_verified = verify_cms(signature, certificate, manifest_bytes)
          errors << "cms_signature_invalid" unless signature_verified
        end
      end

      {
        ok: errors.empty?,
        errors: errors,
        manifest_sha256: manifest_sha,
        signature_present: signature.present?,
        signature_verified: signature_verified,
        cms_signature_integrity_verified: signature_verified,
        certificate_trust_verified: false,
        trusted_timestamp_verified: false,
        file_count: files.length,
        files: files.keys.sort,
      }
    rescue => e
      {
        ok: false,
        errors: ["verification_error:#{e.class}:#{e.message}"],
        signature_verified: false,
        cms_signature_integrity_verified: false,
        certificate_trust_verified: false,
        trusted_timestamp_verified: false,
        files: [],
      }
    end

    def payload_entries(evidence_case, report)
      entries = []
      exclusions = []
      report_path = ::MediaGallery::EvidenceReporter.absolute_path(report)
      entries << file_entry("01_report/technical-evidence-report.pdf", "technical_evidence_report", report_path, report.pdf_sha256)
      entries << bytes_entry("01_report/report-metadata.json", "report_metadata", pretty_json(report.metadata))

      source_metadata = {
        "source_url" => evidence_case.external_url,
        "source_url_original_sha256" => evidence_case.external_url_sha256,
        "platform" => evidence_case.external_platform,
        "visible_username" => evidence_case.external_username,
        "observed_at_utc" => evidence_case.external_observed_at&.utc&.iso8601(6),
        "platform_displayed_time" => evidence_case.external_displayed_at,
        "capture_method" => "staff supplied; no automatic server-side fetch",
      }.compact
      entries << bytes_entry("02_external-source/capture-metadata.json", "external_source_metadata", pretty_json(source_metadata))
      entries << bytes_entry("02_external-source/source-url.txt", "source_url", "#{evidence_case.external_url}\n") if evidence_case.external_url.present?

      object_index = evidence_case.evidence_objects.order(:created_at, :id).map { |object| object_manifest(object) }
      entries << bytes_entry("03_evidence-file/evidence-objects.json", "evidence_object_index", pretty_json(object_index))
      evidence_case.evidence_objects.order(:created_at, :id).each do |object|
        folder = folder_for_object(object)
        extension = safe_extension(object.original_filename)
        target_path = "#{folder}/#{object.object_ref}#{extension}"
        privacy_sensitive_original = %w[identify_raw_json external_original].include?(object.role)
        quarantine_allows_embedding = %w[clean not_applicable].include?(object.quarantine_status)
        if object.storage_kind == "file" && object.include_in_package? && !privacy_sensitive_original && quarantine_allows_embedding && object.size_bytes <= ::MediaGallery::EvidenceVault.package_include_max_bytes
          source_path = ::MediaGallery::EvidenceVault.absolute_path(object)
          entries << file_entry(target_path, object.role, source_path, object.sha256)
        else
          ref_payload = {
            "object_ref" => object.object_ref,
            "role" => object.role,
            "storage_kind" => object.storage_kind,
            "vault_reference_present" => object.vault_reference.to_s.present?,
            "vault_reference_sha256" => object.vault_reference.to_s.present? ? Digest::SHA256.hexdigest(object.vault_reference.to_s) : nil,
            "original_filename_included" => false,
            "original_filename_sha256" => object.original_filename.to_s.present? ? Digest::SHA256.hexdigest(object.original_filename.to_s) : nil,
            "original_extension" => safe_extension(object.original_filename),
            "mime_type" => object.mime_type,
            "size_bytes" => object.size_bytes,
            "sha256" => object.sha256,
            "reason_not_included" => if object.role == "identify_raw_json"
              "privacy-sensitive original Raw JSON retained in the private evidence vault; a sanitized derivative is included separately"
            elsif object.role == "external_original"
              "external original is retained in the private evidence vault and is never embedded by this unencrypted package implementation"
            elsif object.storage_kind == "vault_reference"
              "external vault reference"
            elsif !quarantine_allows_embedding
              "object quarantine status does not permit package embedding"
            else
              "size/sensitivity or package inclusion policy"
            end,
          }.compact
          entries << bytes_entry("#{folder}/#{object.object_ref}.reference.json", "evidence_object_reference", pretty_json(ref_payload))
          exclusions << ref_payload
        end
      end

      entries << bytes_entry("04_reference-media/media-item-snapshot.json", "media_item_snapshot", pretty_json(external_media_snapshot(evidence_case)))
      entries << bytes_entry("04_reference-media/settings-snapshot.json", "settings_snapshot", pretty_json(evidence_case.settings_snapshot))
      entries << bytes_entry("04_reference-media/governance-profile.json", "governance_profile", pretty_json(::MediaGallery::EvidenceGovernance.external_profile(evidence_case)))

      snapshot = evidence_case.latest_identify_snapshot
      if snapshot.present?
        sanitized_raw = external_raw_result(snapshot, evidence_case.case_ref)
        entries << bytes_entry("05_forensic-identify/identify-run.json", "identify_run_snapshot", pretty_json(external_identify_snapshot(snapshot, evidence_case.case_ref)))
        entries << bytes_entry("05_forensic-identify/decision-snapshot.json", "decision_snapshot", pretty_json(external_identify_summary(snapshot.summary, evidence_case.case_ref, snapshot_account_ref_map(snapshot))))
        entries << bytes_entry("05_forensic-identify/raw-result.external.json", "privacy_minimized_raw_result", pretty_json(sanitized_raw))
        entries << bytes_entry("05_forensic-identify/raw-result-original-reference.json", "private_raw_result_reference", pretty_json({
          "object_ref" => snapshot.raw_result_object.object_ref,
          "sha256" => snapshot.raw_result_sha256,
          "size_bytes" => snapshot.raw_result_object.size_bytes,
          "retention" => "immutable original retained in private evidence vault",
          "export" => "privacy-minimized derivative included as raw-result.external.json",
        }))
        entries << bytes_entry("06-account-distribution/account-snapshot.json", "account_snapshot", pretty_json(external_account_snapshot(snapshot.account_snapshot)))
        entries << bytes_entry("06-account-distribution/fingerprint-assignment.json", "fingerprint_assignment", pretty_json(external_fingerprint_snapshot(snapshot.fingerprint_snapshot, evidence_case.case_ref)))
        entries << bytes_entry("08_reproducibility/software-attestation.json", "software_attestation", pretty_json(snapshot.software_snapshot))
        entries << bytes_entry("08_reproducibility/analysis-config.json", "analysis_configuration", pretty_json(snapshot.analysis_settings))
      end

      events = evidence_case.chain_events.order(:occurred_at, :id).map { |event| ::MediaGallery::EvidenceChain.external_hash(event) }
      entries << bytes_entry("07_chain-of-custody/events.jsonl", "chain_of_custody", events.map { |event| ::MediaGallery::EvidenceReference.canonical_json(event) }.join("\n") + "\n")
      reviews = evidence_case.reviews.order(:reviewed_at, :id).map do |review|
        {
          "review_ref" => review.review_ref,
          "review_kind" => review.review_kind,
          "reviewer_role" => review.reviewer_role,
          "reviewer_ref" => review.reviewer_ref,
          "outcome" => review.outcome,
          "reason_present" => review.reason.to_s.present?,
          "reason_sha256" => review.reason.to_s.present? ? Digest::SHA256.hexdigest(review.reason.to_s) : nil,
          "checklist" => review.checklist,
          "reviewed_at_utc" => review.reviewed_at&.utc&.iso8601(6),
        }.compact
      end
      entries << bytes_entry("07_chain-of-custody/review-approvals.json", "review_approvals", pretty_json(reviews))
      disclosures = evidence_case.disclosures.order(:released_at, :id).map do |disclosure|
        {
          "disclosure_ref" => disclosure.disclosure_ref,
          "package_ref" => disclosure.evidence_package.package_ref,
          "status" => disclosure.status,
          "released_at_utc" => disclosure.released_at&.utc&.iso8601(6),
          "expires_at_utc" => disclosure.expires_at&.utc&.iso8601(6),
          "max_downloads" => disclosure.max_downloads,
          "download_count" => disclosure.download_count,
          "first_downloaded_at_utc" => disclosure.first_downloaded_at&.utc&.iso8601(6),
          "last_downloaded_at_utc" => disclosure.last_downloaded_at&.utc&.iso8601(6),
          "revoked_at_utc" => disclosure.revoked_at&.utc&.iso8601(6),
          "recipient_ref_sha256" => Digest::SHA256.hexdigest(disclosure.recipient_ref.to_s),
          "purpose_sha256" => Digest::SHA256.hexdigest(disclosure.purpose.to_s),
        }.compact
      end
      disclosure_log = {
        "schema" => "media-gallery-evidence-disclosure-log-v1",
        "scope" => "snapshot_at_package_creation",
        "note" => "This immutable package contains only disclosure records that existed when it was created. Later releases, downloads and revocations remain in the append-only case audit and may be exported as separate release receipts; this package is never rewritten.",
        "disclosures" => disclosures,
      }
      entries << bytes_entry("07_chain-of-custody/disclosure-log.json", "privacy_minimized_disclosure_log", pretty_json(disclosure_log))
      annexes = evidence_case.identity_annexes.order(version: :asc).map do |annex|
        {
          "annex_ref" => annex.annex_ref,
          "version" => annex.version,
          "status" => annex.status,
          "payload_sha256" => annex.payload_sha256,
          "included_in_standard_package" => false,
        }
      end
      annex_notice = {
        "schema" => "media-gallery-restricted-annex-reference-v1",
        "feature_enabled" => ::MediaGallery::EvidenceIdentityAnnex.enabled?,
        "separate_encrypted_product" => true,
        "included_in_standard_package" => false,
        "annexes" => annexes,
        "warning" => "Restricted identity data is never included in the standard evidence package.",
      }
      entries << bytes_entry("09_restricted-annex/annex-reference.json", "restricted_annex_notice", pretty_json(annex_notice))
      [entries, exclusions]
    end

    def manifest_data(evidence_case, report, package_ref, generated_at, entries, exclusions)
      governance = ::MediaGallery::EvidenceGovernance.external_profile(evidence_case)
      issuer = governance["issuer_display_name"].to_s.presence || ::MediaGallery::EvidencePolicy.issuer_name.presence || "Media Library"
      {
        "schema" => PACKAGE_SCHEMA,
        "package_id" => package_ref,
        "case_id" => evidence_case.case_ref,
        "report_id" => report.report_ref,
        "status" => ::MediaGallery::EvidencePolicy.cms_seal_configured? ? "cms_signed_integrity" : "integrity_only",
        "created_at_utc" => generated_at.iso8601(6),
        "issuer" => "#{issuer} Forensic Evidence Service",
        "operator_identity" => governance["operator_display_name"],
        "governance_profile_ref" => evidence_case.governance_profile_ref,
        "governance_profile_sha256" => evidence_case.governance_snapshot.is_a?(Hash) ? evidence_case.governance_snapshot["profile_sha256"] : nil,
        "jurisdiction_profile" => "international_technical_core",
        "files" => entries.sort_by(&:path).map do |entry|
          { "path" => entry.path, "role" => entry.role, "size" => entry.size, "sha256" => entry.sha256 }
        end,
        "excluded_objects" => exclusions,
        "seal" => {
          "requested_method" => ::MediaGallery::EvidencePolicy.seal_mode,
          "key_id" => seal_key_id,
          "trusted_timestamp" => "not_configured",
          "cms_signature_assurance" => "manifest signature checked against the embedded certificate only",
          "certificate_chain_trust" => "must be established independently by recipient",
          "eu_eidas_profile" => "not_claimed_without_external_qualified_trust_service_and_timestamp_configuration",
        }.compact,
        "limitations" => [
          "The package technically documents a distribution-copy attribution and does not identify a natural-person actor.",
          "No legal admissibility, infringement, authorization, liability, intent or damages conclusion is made.",
          "The built-in report is PDF 1.4 and is not certified PDF/A.",
          "A CMS signature, when present, does not by itself establish trust in the embedded certificate.",
          "No trusted timestamp token is included in this release.",
          "Release activity after package creation is preserved in the case audit and separate release receipts; this immutable package is not rewritten.",
        ],
      }.compact
    end

    def package_info_data(evidence_case, report, package_ref, generated_at)
      {
        "package_id" => package_ref,
        "case_id" => evidence_case.case_ref,
        "report_id" => report.report_ref,
        "created_at_utc" => generated_at.iso8601(6),
        "archive_format" => "tar.gz",
        "manifest_path" => "00_manifest/manifest.json",
        "checksums_path" => "00_manifest/checksums.sha256",
        "signature_path" => ::MediaGallery::EvidencePolicy.cms_seal_configured? ? "00_manifest/seal-signature.p7s" : nil,
        "signature_trust_model" => ::MediaGallery::EvidencePolicy.cms_seal_configured? ? "embedded_certificate_integrity_only" : "none",
        "certificate_chain_trust" => "not_verified_by_builtin_verifier",
        "timestamp_status" => "not_configured",
      }.compact
    end

    def verification_text(package_ref)
      <<~TEXT
        Evidence package #{package_ref}

        1. Extract this tar.gz archive with a path-safe archive tool.
        2. Verify every SHA-256 line in 00_manifest/checksums.sha256.
        3. Verify that the SHA-256 of 00_manifest/manifest.json matches the value supplied with the release record.
        4. When seal-signature.p7s is present, verify the detached CMS signature over the exact manifest.json bytes using seal-certificate.pem and the operator's independently trusted certificate chain.
        5. This package does not include a trusted timestamp token unless a future timestamp integration explicitly adds and verifies one.

        A successful integrity check proves that package bytes match the recorded manifest. It does not prove legal identity, conduct, rights, authorization or liability.
      TEXT
    end

    def create_seal(manifest_bytes)
      return { method: "integrity_only", signature: nil, key_id: nil } unless ::MediaGallery::EvidencePolicy.cms_seal_configured?

      key_path = SiteSetting.media_gallery_evidence_seal_private_key_path.to_s
      cert_path = SiteSetting.media_gallery_evidence_seal_certificate_path.to_s
      password = seal_key_password
      key = OpenSSL::PKey.read(File.binread(key_path), password)
      cert = OpenSSL::X509::Certificate.new(File.binread(cert_path))
      flags = OpenSSL::PKCS7::BINARY | OpenSSL::PKCS7::DETACHED
      signature = OpenSSL::PKCS7.sign(cert, key, manifest_bytes, [], flags).to_der
      raise "cms_signature_self_verification_failed" unless verify_cms(signature, cert.to_pem, manifest_bytes)

      { method: "cms_detached", signature: signature, certificate_pem: cert.to_pem, key_id: seal_key_id }
    end

    def verify_cms(signature_der, certificate_pem, content)
      pkcs7 = OpenSSL::PKCS7.new(signature_der)
      cert = OpenSSL::X509::Certificate.new(certificate_pem)
      store = OpenSSL::X509::Store.new
      flags = OpenSSL::PKCS7::NOVERIFY | OpenSSL::PKCS7::BINARY
      pkcs7.verify([cert], store, content, flags)
    rescue
      false
    end

    def seal_key_id
      value = SiteSetting.respond_to?(:media_gallery_evidence_seal_key_id) ? SiteSetting.media_gallery_evidence_seal_key_id.to_s.strip : ""
      value.presence
    end

    def seal_key_password
      env_name = SiteSetting.respond_to?(:media_gallery_evidence_seal_key_password_env) ? SiteSetting.media_gallery_evidence_seal_key_password_env.to_s.strip : ""
      env_name.present? ? ENV[env_name].to_s : nil
    end

    def folder_for_object(object)
      return "02_external-source" if object.role.start_with?("source_") || object.role == "rights_statement"
      return "05_forensic-identify" if object.role == "identify_raw_json"
      return "04_reference-media" if object.role == "reference_snapshot"

      "03_evidence-file"
    end

    def object_manifest(object)
      vault_reference = object.vault_reference.to_s
      original_filename = object.original_filename.to_s
      {
        "object_ref" => object.object_ref,
        "parent_ref" => object.parent&.object_ref,
        "role" => object.role,
        "storage_kind" => object.storage_kind,
        "vault_reference_present" => vault_reference.present?,
        "vault_reference_sha256" => vault_reference.present? ? Digest::SHA256.hexdigest(vault_reference) : nil,
        "original_filename_included" => false,
        "original_filename_sha256" => original_filename.present? ? Digest::SHA256.hexdigest(original_filename) : nil,
        "original_extension" => safe_extension(original_filename),
        "mime_type" => object.mime_type,
        "size_bytes" => object.size_bytes,
        "sha256" => object.sha256,
        "quarantine_status" => object.quarantine_status,
        "scan" => external_scan_metadata(object.respond_to?(:scan_metadata) ? object.scan_metadata : {}),
        "inspection" => external_inspection_metadata(object.respond_to?(:inspection_metadata) ? object.inspection_metadata : {}),
        "include_in_package" => object.include_in_package?,
        "immutable_at_utc" => object.immutable_at&.utc&.iso8601(6),
        "metadata" => external_object_metadata(object.metadata),
      }.compact
    end

    def verify_report_metadata(bytes, pdf_bytes, errors)
      return errors << "report_metadata_missing" if bytes.blank?

      metadata = JSON.parse(bytes)
      expected = metadata.dig("verification", "report_data_sha256").to_s
      payload = metadata.deep_dup
      payload["verification"] ||= {}
      payload["verification"]["report_data_sha256"] = nil
      payload["verification"].delete("pdf_sha256_external")
      payload["verification"].delete("pdf_hash_location_note")
      actual = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload))
      errors << "report_data_hash_missing" if expected.blank?
      errors << "report_data_hash_mismatch" if expected.present? && actual != expected

      expected_pdf = metadata.dig("verification", "pdf_sha256_external").to_s
      errors << "report_pdf_hash_missing" if expected_pdf.blank?
      if expected_pdf.present? && pdf_bytes.present? && Digest::SHA256.hexdigest(pdf_bytes) != expected_pdf
        errors << "report_pdf_hash_mismatch"
      end
    rescue JSON::ParserError
      errors << "report_metadata_invalid_json"
    end

    def verify_external_chain(bytes, errors)
      return errors << "chain_events_missing" if bytes.blank?

      previous_hash = nil
      bytes.to_s.each_line.with_index do |line, index|
        next if line.strip.blank?

        event = JSON.parse(line)
        payload = {
          hash_schema: event["hash_schema"],
          event_ref: event["event_ref"],
          case_ref: event["case_ref"],
          event_type: event["event_type"],
          actor_type: event["actor_type"],
          actor_ref: event["actor_ref"],
          object_ref: event["object_ref"],
          reason_present: event["reason_present"] == true,
          reason_sha256: event["reason_sha256"],
          details_sha256: event["details_sha256"],
          previous_event_hash: event["previous_event_hash"],
          occurred_at_utc: event["occurred_at_utc"],
        }
        actual = Digest::SHA256.hexdigest(::MediaGallery::EvidenceReference.canonical_json(payload))
        errors << "chain_event_hash_mismatch:#{index + 1}" unless actual == event["event_hash"].to_s
        errors << "chain_previous_hash_mismatch:#{index + 1}" unless event["previous_event_hash"].to_s == previous_hash.to_s
        previous_hash = event["event_hash"].to_s
      end
    rescue JSON::ParserError
      errors << "chain_events_invalid_json"
    end

    def external_media_snapshot(evidence_case)
      snapshot = (evidence_case.media_snapshot || {}).deep_dup
      contributor = snapshot["content_contributor"]
      if contributor.is_a?(Hash)
        user_id = contributor.delete("user_id")
        stored_ref = contributor["account_ref"].to_s
        if user_id.to_i.positive?
          contributor["account_ref"] = stored_ref.presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: evidence_case.case_ref, user_id: user_id)
        end
      end
      %w[original_upload processed_upload].each do |key|
        upload = snapshot[key]
        next unless upload.is_a?(Hash)

        upload.delete("upload_id")
        filename = upload.delete("original_filename").to_s
        upload["original_filename_included"] = false
        upload["original_filename_sha256"] = Digest::SHA256.hexdigest(filename) if filename.present?
        upload["original_extension"] = safe_extension(filename) if filename.present?
      end
      snapshot
    end

    def external_identify_snapshot(snapshot, case_ref)
      account_ref_map = snapshot_account_ref_map(snapshot)
      {
        "run_ref" => snapshot.run_ref,
        "run_kind" => snapshot.run_kind,
        "decision" => snapshot.decision,
        "conclusive" => snapshot.conclusive?,
        "synthetic_population" => snapshot.synthetic_population?,
        "candidate_population_count" => snapshot.candidate_population_count,
        "attributed_username" => snapshot.attributed_username,
        "attributed_account_ref" => snapshot.attributed_account_ref,
        "fingerprint_id" => snapshot.fingerprint_id,
        "fingerprint_assigned_at_utc" => snapshot.fingerprint_assigned_at&.utc&.iso8601(6),
        "layout" => snapshot.layout,
        "raw_result_sha256" => snapshot.raw_result_sha256,
        "summary" => external_identify_summary(snapshot.summary, case_ref, account_ref_map),
        "account_snapshot" => external_account_snapshot(snapshot.account_snapshot),
        "fingerprint_snapshot" => external_fingerprint_snapshot(snapshot.fingerprint_snapshot, case_ref),
        "software_snapshot" => snapshot.software_snapshot,
        "analysis_settings" => snapshot.analysis_settings,
        "sanity_checks" => snapshot.sanity_checks,
        "immutable_at_utc" => snapshot.immutable_at&.utc&.iso8601(6),
      }.compact
    end

    def external_identify_summary(summary, case_ref, account_ref_map = {})
      privacy_minimize_identify_data(summary.is_a?(Hash) ? summary : {}, case_ref, account_ref_map)
    end

    def external_raw_result(snapshot, case_ref)
      bytes = ::MediaGallery::EvidenceVault.read_bytes(snapshot.raw_result_object, max_bytes: ::MediaGallery::EvidenceSnapshot::RAW_RESULT_MAX_BYTES)
      parsed = JSON.parse(bytes)
      parsed["meta"] ||= {}
      parsed["meta"]["evidence_attestation"] = snapshot.software_snapshot["identify_evidence_attestation"] if snapshot.software_snapshot.is_a?(Hash)
      transformed = privacy_minimize_identify_data(parsed, case_ref, snapshot_account_ref_map(snapshot))
      {
        "schema" => "media-gallery-privacy-minimized-identify-result-v1",
        "source_raw_result_sha256" => snapshot.raw_result_sha256,
        "transformation" => "user IDs, usernames, email/IP-like fields and other direct candidate identifiers removed or replaced with case-specific account references",
        "result" => transformed,
      }
    rescue JSON::ParserError
      raise "stored_raw_result_invalid_json"
    end

    def privacy_minimize_identify_data(value, case_ref, account_ref_map = {})
      case value
      when Hash
        source = value.deep_stringify_keys
        user_shaped = source.key?("user_id") || source.key?("internal_user_id") || source.key?("assigned_user_id") || source.key?("username")
        user_id = source["user_id"] || source["internal_user_id"] || source["assigned_user_id"] || (user_shaped ? source["id"] : nil)
        output = {}
        source.each do |key, child|
          next if sensitive_identity_key?(key, user_shaped: user_shaped)

          output[key] = privacy_minimize_identify_data(child, case_ref, account_ref_map)
        end
        if user_id.to_i.positive?
          output["account_ref"] = account_ref_map[user_id.to_s].presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id)
        end
        output
      when Array
        value.map { |child| privacy_minimize_identify_data(child, case_ref, account_ref_map) }
      else
        value
      end
    end

    def sensitive_identity_key?(key, user_shaped: false)
      name = key.to_s
      return true if user_shaped && %w[id name display_name login user user_id internal_user_id assigned_user_id username].include?(name)
      return true if name.match?(/(?:^|_)(?:user_id|internal_user_id|assigned_user_id|username|user_name|email|e_mail|ip|ip_address|registration_ip|last_ip)$/i)
      return true if name.match?(/(?:email|e_mail|ip_address|registration_ip|last_ip|username|user_name|authorization|cookie|session_token|access_token|refresh_token|api_key|client_secret)/i)

      false
    end

    def snapshot_account_ref_map(snapshot)
      value = snapshot.account_snapshot.is_a?(Hash) ? snapshot.account_snapshot["candidate_account_refs_by_user_id"] : nil
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def external_account_snapshot(snapshot)
      value = snapshot.is_a?(Hash) ? snapshot.deep_dup : {}
      value.delete("internal_user_id")
      value.delete("candidate_account_refs_by_user_id")
      value
    end

    def external_fingerprint_snapshot(snapshot, case_ref)
      value = snapshot.is_a?(Hash) ? snapshot.deep_dup : {}
      user_id = value.delete("assigned_user_id")
      stored_ref = value["assigned_account_ref"].to_s
      value.delete("fingerprint_record_id")
      value.delete("media_item_id")
      value["assigned_account_ref"] = stored_ref.presence || ::MediaGallery::EvidenceReference.account_ref(case_ref: case_ref, user_id: user_id) if user_id.to_i.positive?
      value
    end

    def external_scan_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      value.slice(
        "provider", "state", "complete", "signature", "scanned_at_utc", "started_at_utc",
        "completed_at_utc", "duration_ms", "size_bytes", "scan_limit_bytes", "version",
        "manual_review_at_utc", "manual_review_reason_sha256"
      ).compact
    end

    def external_inspection_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      value.slice(
        "state", "inspected_at_utc", "declared_mime_type", "detected_file_type", "extension",
        "media_type", "ffprobe", "message", "warnings"
      ).compact
    end

    def external_object_metadata(metadata)
      value = metadata.is_a?(Hash) ? metadata : {}
      allowed = value.slice("source", "production_evidence_eligible", "acquisition_method")
      description = value["staff_description"].to_s
      allowed["staff_description_present"] = description.present?
      allowed["staff_description_sha256"] = Digest::SHA256.hexdigest(description) if description.present?
      allowed
    end

    def safe_extension(filename)
      extension = File.extname(filename.to_s).downcase
      extension.match?(/\A\.[a-z0-9]{1,12}\z/) ? extension : ".bin"
    end

    def bytes_entry(path, role, bytes)
      payload = bytes.to_s.b
      Entry.new(path: safe_archive_path(path), role: role, size: payload.bytesize, sha256: Digest::SHA256.hexdigest(payload), bytes: payload)
    end

    def file_entry(path, role, source_path, expected_sha256)
      size = File.size(source_path)
      actual = Digest::SHA256.file(source_path).hexdigest
      raise "package_source_hash_mismatch" unless actual == expected_sha256.to_s
      Entry.new(path: safe_archive_path(path), role: role, size: size, sha256: actual, source_path: source_path)
    end

    def validate_entries!(entries)
      raise "package_entry_count_exceeded" if entries.length > MAX_ARCHIVE_ENTRIES
      paths = entries.map(&:path)
      raise "duplicate_package_path" unless paths.uniq.length == paths.length
      total = entries.sum { |entry| entry.size.to_i }
      raise "package_total_too_large" if total > MAX_VERIFY_UNCOMPRESSED_BYTES
    end

    def write_tar_gz!(path, entries)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o750)
      tmp = "#{path}.tmp-#{SecureRandom.hex(6)}"
      begin
        Zlib::GzipWriter.open(tmp) do |gzip|
          gzip.mtime = 0
          Gem::Package::TarWriter.new(gzip) do |tar|
            entries.sort_by(&:path).each do |entry|
              tar.add_file_simple(entry.path, 0o440, entry.size) do |io|
                if entry.bytes
                  io.write(entry.bytes)
                else
                  File.open(entry.source_path, "rb") { |source| IO.copy_stream(source, io) }
                end
              end
            end
          end
        end
        File.rename(tmp, path)
        File.chmod(0o440, path) rescue nil
      ensure
        FileUtils.rm_f(tmp) rescue nil
      end
    end

    def read_tar_entries(path)
      files = {}
      total = 0
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          entry_count = 0
          tar.each do |entry|
            next if entry.directory?
            entry_count += 1
            raise "archive_entry_count_exceeded" if entry_count > MAX_ARCHIVE_ENTRIES
            safe = safe_archive_path(entry.full_name)
            raise "duplicate_archive_path" if files.key?(safe)
            raise "archive_entry_too_large" if entry.size > ::MediaGallery::EvidenceVault.max_upload_bytes
            total += entry.size
            ratio_limit = [File.size(path) * 250, 64 * 1024 * 1024].max
            raise "archive_total_too_large" if total > [MAX_VERIFY_UNCOMPRESSED_BYTES, ratio_limit].min
            files[safe] = entry.read
          end
        end
      end
      files
    end

    def parse_checksums(bytes)
      return {} if bytes.blank?

      bytes.to_s.each_line.each_with_object({}) do |line, out|
        line = line.chomp
        next if line.strip.blank?
        match = line.match(/\A([0-9a-f]{64})  (.+)\z/i)
        raise "invalid_checksum_line" unless match
        path = safe_archive_path(match[2])
        raise "duplicate_checksum_path" if out.key?(path)
        out[path] = match[1].downcase
      end
    end

    def safe_archive_path(path)
      value = path.to_s.tr("\\", "/")
      raise "unsafe_archive_path" if value.blank? || value.start_with?("/") || value.include?("\0")
      parts = value.split("/")
      raise "unsafe_archive_path" if parts.any? { |part| part.blank? || part == "." || part == ".." }
      value
    end

    def pretty_json(value)
      canonical_pretty_json(value)
    end

    def canonical_pretty_json(value)
      ::MediaGallery::EvidenceReference.pretty_canonical_json(value) + "\n"
    end

    private_class_method :payload_entries, :manifest_data, :package_info_data, :verification_text,
                         :create_seal, :verify_cms, :seal_key_id, :seal_key_password, :folder_for_object,
                         :object_manifest, :verify_report_metadata, :verify_external_chain, :external_media_snapshot, :external_identify_snapshot,
                         :external_identify_summary, :external_raw_result, :privacy_minimize_identify_data, :sensitive_identity_key?,
                         :snapshot_account_ref_map, :external_account_snapshot, :external_fingerprint_snapshot, :external_scan_metadata,
                         :external_inspection_metadata, :external_object_metadata, :safe_extension,
                         :bytes_entry, :file_entry, :validate_entries!, :write_tar_gz!, :read_tar_entries,
                         :parse_checksums, :safe_archive_path, :pretty_json, :canonical_pretty_json
  end
end
