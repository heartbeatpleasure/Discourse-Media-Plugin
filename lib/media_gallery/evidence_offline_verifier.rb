# frozen_string_literal: true

module ::MediaGallery
  module EvidenceOfflineVerifier
    module_function

    VERSION = "1.0.0"

    def script
      <<~'RUBY_SCRIPT'
        #!/usr/bin/env ruby
        # frozen_string_literal: true

        require "digest"
        require "json"
        require "openssl"
        require "optparse"
        require "rubygems/package"
        require "time"
        require "zlib"

        MAX_ENTRIES = 2_000
        MAX_BYTES = 256 * 1024 * 1024

        def safe_path(value)
          path = value.to_s.tr("\\", "/")
          raise "unsafe archive path" if path.empty? || path.start_with?("/") || path.include?("\0")
          parts = path.split("/")
          raise "unsafe archive path" if parts.any? { |part| part.empty? || part == "." || part == ".." }
          path
        end

        def read_archive(path)
          files = {}
          total = 0
          File.open(path, "rb") do |file|
            Zlib::GzipReader.wrap(file) do |gzip|
              Gem::Package::TarReader.new(gzip) do |tar|
                tar.each do |entry|
                  next if entry.directory?
                  raise "too many archive entries" if files.length >= MAX_ENTRIES
                  name = safe_path(entry.full_name)
                  raise "duplicate archive entry: #{name}" if files.key?(name)
                  bytes = entry.read
                  total += bytes.bytesize
                  raise "archive exceeds verification limit" if total > MAX_BYTES
                  files[name] = bytes
                end
              end
            end
          end
          files
        end

        def parse_checksums(bytes)
          raise "checksums missing" if bytes.nil? || bytes.empty?
          bytes.each_line.each_with_object({}) do |line, output|
            line = line.chomp
            next if line.strip.empty?
            match = line.match(/\A([0-9a-fA-F]{64})\s{2}(.+)\z/)
            raise "invalid checksum line" unless match
            output[safe_path(match[2])] = match[1].downcase
          end
        end

        def parse_certificates(bytes)
          return [] if bytes.nil? || bytes.empty?
          blocks = bytes.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
          blocks = [bytes] if blocks.empty?
          blocks.map { |item| OpenSSL::X509::Certificate.new(item) }
        end

        def fingerprint(cert)
          Digest::SHA256.hexdigest(cert.to_der)
        end

        def normalized_fingerprint(value)
          value.to_s.downcase.gsub(/[^0-9a-f]/, "")
        end

        def secure_equal(left, right)
          left = left.to_s
          right = right.to_s
          return false unless left.bytesize == right.bytesize
          result = 0
          left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
          result.zero?
        end

        def canonical_value(value)
          case value
          when Hash
            value.keys.map(&:to_s).sort.each_with_object({}) do |key, output|
              source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
              output[key] = canonical_value(value[source_key])
            end
          when Array
            value.map { |child| canonical_value(child) }
          else
            value
          end
        end

        def canonical_json(value)
          JSON.generate(canonical_value(value))
        end

        def verify_chain_events(bytes, errors)
          if bytes.nil? || bytes.empty?
            errors << "chain_events_missing"
            return
          end
          previous = nil
          bytes.each_line.with_index do |line, index|
            next if line.strip.empty?
            event = JSON.parse(line)
            payload = {
              hash_schema: event["hash_schema"], event_ref: event["event_ref"], case_ref: event["case_ref"],
              event_type: event["event_type"], actor_type: event["actor_type"], actor_ref: event["actor_ref"],
              object_ref: event["object_ref"], reason_present: event["reason_present"] == true,
              reason_sha256: event["reason_sha256"], details_sha256: event["details_sha256"],
              previous_event_hash: event["previous_event_hash"], occurred_at_utc: event["occurred_at_utc"],
            }
            actual = Digest::SHA256.hexdigest(canonical_json(payload))
            errors << "chain_event_hash_mismatch:#{index + 1}" unless secure_equal(actual, event["event_hash"].to_s)
            errors << "chain_previous_hash_mismatch:#{index + 1}" unless event["previous_event_hash"].to_s == previous.to_s
            previous = event["event_hash"].to_s
          end
        rescue JSON::ParserError
          errors << "chain_events_invalid_json"
        end

        options = {
          package: nil,
          cms_ca_bundle: nil,
          tsa_ca_bundle: nil,
          expected_cms_cert_sha256: nil,
          expected_tsa_cert_sha256: nil,
          json: false,
        }

        OptionParser.new do |parser|
          parser.banner = "Usage: verify-evidence-package.rb --package PACKAGE.tar.gz [options]"
          parser.on("--package PATH") { |value| options[:package] = value }
          parser.on("--cms-ca-bundle PATH") { |value| options[:cms_ca_bundle] = value }
          parser.on("--tsa-ca-bundle PATH") { |value| options[:tsa_ca_bundle] = value }
          parser.on("--expected-cms-cert-sha256 HEX") { |value| options[:expected_cms_cert_sha256] = normalized_fingerprint(value) }
          parser.on("--expected-tsa-cert-sha256 HEX") { |value| options[:expected_tsa_cert_sha256] = normalized_fingerprint(value) }
          parser.on("--json") { options[:json] = true }
        end.parse!

        raise "--package is required" if options[:package].to_s.empty?
        files = read_archive(options[:package])
        errors = []
        checksums = parse_checksums(files["00_manifest/checksums.sha256"])
        checksums.each do |name, expected|
          bytes = files[name]
          if bytes.nil?
            errors << "missing:#{name}"
          elsif Digest::SHA256.hexdigest(bytes) != expected
            errors << "hash_mismatch:#{name}"
          end
        end
        (files.keys - checksums.keys - ["00_manifest/checksums.sha256"]).each { |name| errors << "unlisted:#{name}" }

        manifest_bytes = files["00_manifest/manifest.json"]
        begin
          manifest = JSON.parse(manifest_bytes.to_s)
          errors << "manifest_schema_missing" if manifest["schema"].to_s.empty?
          declared = {}
          Array(manifest["files"]).each do |row|
            next unless row.is_a?(Hash)
            name = safe_path(row["path"])
            if declared.key?(name)
              errors << "manifest_duplicate_file:#{name}"
              next
            end
            declared[name] = true
            bytes = files[name]
            errors << "manifest_file_missing:#{name}" if bytes.nil?
            errors << "manifest_file_hash_mismatch:#{name}" if bytes && Digest::SHA256.hexdigest(bytes) != row["sha256"].to_s
            errors << "manifest_file_size_mismatch:#{name}" if bytes && bytes.bytesize != row["size"].to_i
          end
          controls = %w[
            00_manifest/manifest.json 00_manifest/checksums.sha256
            00_manifest/seal-signature.p7s 00_manifest/seal-certificate.pem 00_manifest/seal-certificate-chain.pem
            00_manifest/timestamp-request.tsq 00_manifest/timestamp-response.tsr 00_manifest/timestamp-metadata.json
          ]
          (files.keys - declared.keys - controls).each { |name| errors << "not_declared_in_manifest:#{name}" }
        rescue JSON::ParserError
          manifest = nil
          errors << "manifest_invalid_json"
        end

        report_metadata_bytes = files["01_report/report-metadata.json"]
        report_pdf_bytes = files["01_report/technical-evidence-report.pdf"]
        if report_metadata_bytes
          begin
            report_metadata = JSON.parse(report_metadata_bytes)
            expected_report_data = report_metadata.dig("verification", "report_data_sha256").to_s
            report_payload = Marshal.load(Marshal.dump(report_metadata))
            report_payload["verification"] ||= {}
            report_payload["verification"]["report_data_sha256"] = nil
            report_payload["verification"].delete("pdf_sha256_external")
            report_payload["verification"].delete("pdf_hash_location_note")
            report_payload["verification"].delete("pdf_processing")
            actual_report_data = Digest::SHA256.hexdigest(canonical_json(report_payload))
            errors << "report_data_hash_missing" if expected_report_data.empty?
            errors << "report_data_hash_mismatch" if !expected_report_data.empty? && !secure_equal(actual_report_data, expected_report_data)
            expected_pdf = report_metadata.dig("verification", "pdf_sha256_external").to_s
            errors << "report_pdf_hash_missing" if expected_pdf.empty?
            errors << "report_pdf_hash_mismatch" if !expected_pdf.empty? && report_pdf_bytes && !secure_equal(Digest::SHA256.hexdigest(report_pdf_bytes), expected_pdf)
          rescue JSON::ParserError
            errors << "report_metadata_invalid_json"
          end
        else
          errors << "report_metadata_missing"
        end
        verify_chain_events(files["07_chain-of-custody/events.jsonl"], errors)

        cms = {
          present: false,
          signature_integrity_verified: false,
          certificate_trust_verified: false,
          certificate_pin_verified: false,
        }
        signature = files["00_manifest/seal-signature.p7s"]
        certificate_pem = files["00_manifest/seal-certificate.pem"]
        chain_pem = files["00_manifest/seal-certificate-chain.pem"]
        if signature || certificate_pem
          cms[:present] = true
          if signature.nil? || certificate_pem.nil? || manifest_bytes.nil?
            errors << "incomplete_cms_seal"
          else
            begin
              certificate = OpenSSL::X509::Certificate.new(certificate_pem)
              chain = parse_certificates(chain_pem)
              pkcs7 = OpenSSL::PKCS7.new(signature)
              flags = OpenSSL::PKCS7::NOVERIFY | OpenSSL::PKCS7::BINARY
              cms[:signature_integrity_verified] = pkcs7.verify([certificate] + chain, OpenSSL::X509::Store.new, manifest_bytes, flags)
              errors << "cms_signature_invalid" unless cms[:signature_integrity_verified]
              expected = options[:expected_cms_cert_sha256]
              cms[:certificate_sha256] = fingerprint(certificate)
              cms[:certificate_pin_verified] = expected.nil? || expected.empty? || secure_equal(cms[:certificate_sha256], expected)
              errors << "cms_certificate_pin_mismatch" unless cms[:certificate_pin_verified]
              cms[:certificate_trust_verified] = !expected.to_s.empty? && cms[:certificate_pin_verified]
              if options[:cms_ca_bundle]
                store = OpenSSL::X509::Store.new
                parse_certificates(File.binread(options[:cms_ca_bundle])).each { |cert| store.add_cert(cert) }
                chain_trusted = pkcs7.verify([certificate] + chain, store, manifest_bytes, OpenSSL::PKCS7::BINARY)
                cms[:certificate_trust_verified] = chain_trusted && cms[:certificate_pin_verified]
                errors << "cms_certificate_chain_untrusted" unless chain_trusted
              end
            rescue => e
              errors << "cms_verification_error:#{e.class}:#{e.message}"
            end
          end
        end

        timestamp = {
          present: false,
          verified: false,
          certificate_pin_verified: false,
        }
        request_der = files["00_manifest/timestamp-request.tsq"]
        response_der = files["00_manifest/timestamp-response.tsr"]
        if request_der || response_der
          timestamp[:present] = true
          if request_der.nil? || response_der.nil?
            errors << "incomplete_timestamp"
          elsif !defined?(OpenSSL::Timestamp)
            errors << "timestamp_api_unavailable"
          else
            begin
              request = OpenSSL::Timestamp::Request.new(request_der)
              response = OpenSSL::Timestamp::Response.new(response_der)
              tsa = response.tsa_certificate
              timestamp[:tsa_certificate_sha256] = tsa ? fingerprint(tsa) : nil
              expected = options[:expected_tsa_cert_sha256]
              timestamp[:certificate_pin_verified] = expected.nil? || expected.empty? || (tsa && secure_equal(timestamp[:tsa_certificate_sha256], expected))
              errors << "timestamp_certificate_pin_mismatch" unless timestamp[:certificate_pin_verified]
              info = response.token_info
              token_certs = Array(response.token&.certificates).compact
              intermediates = token_certs.reject { |cert| tsa && cert.to_der == tsa.to_der }
              if tsa
                integrity_store = OpenSSL::X509::Store.new
                ([tsa] + token_certs).uniq { |cert| cert.to_der }.each { |cert| integrity_store.add_cert(cert) }
                integrity_store.time = info.gen_time if info&.gen_time && integrity_store.respond_to?(:time=)
                response.verify(request, integrity_store, intermediates)
                timestamp[:response_integrity_verified] = true
              else
                timestamp[:response_integrity_verified] = false
                errors << "timestamp_tsa_certificate_missing"
              end
              if options[:tsa_ca_bundle] && timestamp[:response_integrity_verified]
                store = OpenSSL::X509::Store.new
                certs = parse_certificates(File.binread(options[:tsa_ca_bundle]))
                certs.each { |cert| store.add_cert(cert) }
                store.time = info.gen_time if info&.gen_time && store.respond_to?(:time=)
                response.verify(request, store, (intermediates + certs).uniq { |cert| cert.to_der })
                timestamp[:certificate_trust_verified] = true
              end
              pin_establishes_trust = !expected.to_s.empty? && timestamp[:certificate_pin_verified]
              timestamp[:verified] = timestamp[:response_integrity_verified] && timestamp[:certificate_pin_verified] && (pin_establishes_trust || timestamp[:certificate_trust_verified])
              errors << "timestamp_verification_failed" unless timestamp[:response_integrity_verified]
              errors << "timestamp_certificate_trust_failed" if options[:tsa_ca_bundle] && !timestamp[:certificate_trust_verified]
              timestamp[:generated_at_utc] = info&.gen_time&.utc&.iso8601
              timestamp[:policy_id] = info&.policy_id
            rescue => e
              errors << "timestamp_verification_error:#{e.class}:#{e.message}"
            end
          end
        end

        result = {
          ok: errors.empty?,
          package_sha256: Digest::SHA256.file(options[:package]).hexdigest,
          manifest_sha256: manifest_bytes ? Digest::SHA256.hexdigest(manifest_bytes) : nil,
          file_count: files.length,
          cms: cms,
          timestamp: timestamp,
          errors: errors,
        }

        if options[:json]
          puts JSON.pretty_generate(result)
        else
          puts(result[:ok] ? "PASS: evidence package integrity verified" : "FAIL: evidence package verification failed")
          puts "Package SHA-256: #{result[:package_sha256]}"
          puts "Manifest SHA-256: #{result[:manifest_sha256]}"
          puts "CMS signature integrity: #{cms[:signature_integrity_verified]}"
          puts "CMS certificate trust: #{cms[:certificate_trust_verified]}"
          puts "RFC 3161 response integrity: #{timestamp[:response_integrity_verified]}"
          puts "RFC 3161 trusted timestamp: #{timestamp[:verified]}"
          errors.each { |error| warn "- #{error}" }
        end
        exit(result[:ok] ? 0 : 1)
      RUBY_SCRIPT
    end
  end
end
