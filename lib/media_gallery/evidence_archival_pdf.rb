# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "timeout"
require "time"
require "tmpdir"

module ::MediaGallery
  module EvidenceArchivalPdf
    module_function

    PROFILES = %w[pdf_1_4 pdfa_2b].freeze
    MAX_TOOL_OUTPUT_BYTES = 4 * 1024 * 1024
    MAX_PDF_BYTES = 64 * 1024 * 1024

    def profile
      value = setting(:media_gallery_evidence_pdf_profile, "pdf_1_4")
      PROFILES.include?(value) ? value : "pdf_1_4"
    end

    def enabled?
      profile == "pdfa_2b"
    end

    def configured?
      return true unless enabled?

      executable_path(ghostscript_setting).present? &&
        executable_path(verapdf_setting).present? &&
        File.file?(pdfa_definition_path)
    rescue
      false
    end

    def process(pdf_bytes, final:)
      return builtin_result(pdf_bytes) unless enabled?
      if !configured?
        raise ArgumentError, "pdfa_conversion_not_configured" if final
        return builtin_result(pdf_bytes).merge(
          metadata: builtin_result(pdf_bytes)[:metadata].merge(
            "requested_profile" => "PDF/A-2b",
            "conversion_status" => "not_configured",
          ),
        )
      end

      Dir.mktmpdir("mg-evidence-pdfa-") do |dir|
        File.chmod(0o700, dir)
        input = File.join(dir, "input.pdf")
        output = File.join(dir, "output.pdf")
        File.binwrite(input, pdf_bytes)
        File.chmod(0o600, input)

        gs_stdout, gs_stderr = run_command(ghostscript_command(input, output), timeout_seconds)
        raise "pdfa_output_missing" unless File.file?(output) && File.size(output).positive?
        raise "pdfa_output_too_large" if File.size(output) > MAX_PDF_BYTES

        validation_stdout, validation_stderr = run_command(
          [executable_path(verapdf_setting), "--format", "json", "--flavour", "2b", "--maxfailuresdisplayed", "20", output],
          timeout_seconds,
        )
        validation = parse_validation(validation_stdout)
        raise "pdfa_validation_failed:#{validation[:summary]}" unless validation[:compliant]

        bytes = File.binread(output)
        {
          bytes: bytes,
          metadata: {
            "requested_profile" => "PDF/A-2b",
            "pdf_profile" => "PDF/A-2b",
            "conversion_status" => "converted_and_validated",
            "validator" => "veraPDF",
            "validator_compliant" => true,
            "validator_report_sha256" => Digest::SHA256.hexdigest(validation_stdout),
            "validator_summary" => validation[:summary],
            "ghostscript_version" => tool_version(executable_path(ghostscript_setting), "--version"),
            "verapdf_version" => tool_version(executable_path(verapdf_setting), "--version"),
            "ghostscript_stdout_sha256" => Digest::SHA256.hexdigest(gs_stdout.to_s),
            "ghostscript_stderr_sha256" => Digest::SHA256.hexdigest(gs_stderr.to_s),
            "verapdf_stderr_sha256" => Digest::SHA256.hexdigest(validation_stderr.to_s),
          },
        }
      end
    end

    def health
      result = {
        "profile" => profile,
        "configured" => configured?,
        "ghostscript_path" => executable_path(ghostscript_setting),
        "verapdf_path" => executable_path(verapdf_setting),
        "pdfa_definition_present" => File.file?(pdfa_definition_path),
      }
      return result.merge("status" => "disabled") unless enabled?
      return result.merge("status" => "not_configured") unless configured?

      result.merge(
        "status" => "available",
        "ghostscript_version" => tool_version(executable_path(ghostscript_setting), "--version"),
        "verapdf_version" => tool_version(executable_path(verapdf_setting), "--version"),
      )
    rescue => e
      result.merge("status" => "unavailable", "error" => safe_error(e))
    end

    def builtin_result(pdf_bytes)
      {
        bytes: pdf_bytes,
        metadata: {
          "requested_profile" => "PDF 1.4",
          "pdf_profile" => "PDF 1.4; not certified PDF/A",
          "conversion_status" => "built_in_pdf_1_4",
          "validator_compliant" => false,
        },
      }
    end

    def ghostscript_command(input, output)
      [
        executable_path(ghostscript_setting),
        "-dPDFA=2",
        "-dBATCH",
        "-dNOPAUSE",
        "-dSAFER",
        "-dNOOUTERSAVE",
        "-sDEVICE=pdfwrite",
        "-sColorConversionStrategy=RGB",
        "-sProcessColorModel=DeviceRGB",
        "-dPDFACompatibilityPolicy=1",
        "-sOutputFile=#{output}",
        pdfa_definition_path,
        input,
      ]
    end

    def parse_validation(stdout)
      parsed = JSON.parse(stdout)
      compliant_values = collect_key(parsed, "isCompliant")
      compliant = compliant_values.any? && compliant_values.all? { |value| value == true || value.to_s == "true" }
      failures = collect_key(parsed, "failedChecks").map(&:to_i).sum
      {
        compliant: compliant,
        summary: compliant ? "PDF/A-2b validation passed" : "PDF/A-2b validation failed with #{failures} failed checks",
      }
    rescue JSON::ParserError => e
      raise "verapdf_invalid_json:#{safe_error(e)}"
    end

    def collect_key(value, key)
      case value
      when Hash
        value.each_with_object([]) do |(current_key, child), output|
          output << child if current_key.to_s == key
          output.concat(collect_key(child, key))
        end
      when Array
        value.flat_map { |child| collect_key(child, key) }
      else
        []
      end
    end

    def run_command(command, timeout)
      stdout = nil
      stderr = nil
      status = nil
      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        stdin.close
        out_reader = Thread.new { read_limited(out) }
        err_reader = Thread.new { read_limited(err) }
        begin
          Timeout.timeout(timeout) do
            status = wait_thread.value
            stdout = out_reader.value
            stderr = err_reader.value
          end
        rescue Timeout::Error
          terminate_process(wait_thread.pid)
          raise "archival_pdf_tool_timeout"
        rescue
          terminate_process(wait_thread.pid) if wait_thread.alive?
          raise
        ensure
          out_reader.kill if out_reader.alive?
          err_reader.kill if err_reader.alive?
          out.close rescue nil
          err.close rescue nil
        end
      end
      raise "archival_pdf_tool_failed:#{stderr.to_s.gsub(/[\r\n]+/, ' ').truncate(500)}" unless status&.success?

      [stdout.to_s, stderr.to_s]
    end

    def read_limited(io)
      buffer = +""
      while (chunk = io.read(16 * 1024))
        buffer << chunk
        raise "archival_pdf_tool_output_too_large" if buffer.bytesize > MAX_TOOL_OUTPUT_BYTES
      end
      buffer
    end

    def terminate_process(pid)
      Process.kill("TERM", pid) rescue nil
      sleep 0.2
      Process.kill("KILL", pid) rescue nil
    end

    def tool_version(path, flag)
      stdout = stderr = nil
      status = nil
      Timeout.timeout(5) { stdout, stderr, status = Open3.capture3(path, flag) }
      return "unknown" unless status.success?

      (stdout.presence || stderr).to_s.lines.first.to_s.strip.truncate(200)
    rescue
      "unknown"
    end

    def executable_path(value)
      candidate = value.to_s.strip
      return nil if candidate.blank?
      if candidate.include?(File::SEPARATOR)
        expanded = File.expand_path(candidate)
        return expanded if File.file?(expanded) && File.executable?(expanded)
        return nil
      end

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, candidate)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def ghostscript_setting
      setting(:media_gallery_evidence_pdfa_ghostscript_path, "gs")
    end

    def verapdf_setting
      setting(:media_gallery_evidence_pdfa_verapdf_path, "verapdf")
    end

    def pdfa_definition_path
      value = setting(:media_gallery_evidence_pdfa_definition_path)
      value.present? ? File.expand_path(value) : ""
    end

    def timeout_seconds
      integer_setting(:media_gallery_evidence_pdfa_timeout_seconds, 60).clamp(10, 300)
    end

    def setting(name, default = "")
      return default unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_s.strip
    rescue
      default
    end

    def integer_setting(name, default)
      return default unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_i
    rescue
      default
    end

    def safe_error(error)
      "#{error.class}: #{error.message}".to_s.gsub(/[\r\n]+/, " ").truncate(300)
    end
  end
end
