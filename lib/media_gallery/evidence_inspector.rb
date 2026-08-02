# frozen_string_literal: true

require "time"
require "json"
require "open3"
require "timeout"

module ::MediaGallery
  module EvidenceInspector
    module_function

    MAX_STDOUT_BYTES = 2 * 1024 * 1024
    MAX_STDERR_BYTES = 64 * 1024

    def enabled?
      return true unless SiteSetting.respond_to?(:media_gallery_evidence_ffprobe_inspection_enabled)

      SiteSetting.media_gallery_evidence_ffprobe_inspection_enabled
    rescue
      true
    end

    def timeout_seconds
      value = SiteSetting.respond_to?(:media_gallery_evidence_ffprobe_timeout_seconds) ? SiteSetting.media_gallery_evidence_ffprobe_timeout_seconds.to_i : 30
      [[value, 5].max, 300].min
    rescue
      30
    end

    def inspect(record, path)
      return not_applicable("Inspection is disabled in site settings.") unless enabled?
      return not_applicable("This evidence role does not require technical file inspection.") unless inspectable_role?(record.role)

      header = File.binread(path, 8192)
      detected = detect_magic(header)
      result = {
        "state" => "valid",
        "inspected_at_utc" => Time.now.utc.iso8601(6),
        "declared_mime_type" => record.mime_type.to_s,
        "detected_file_type" => detected,
        "extension" => File.extname(record.original_filename.to_s).downcase,
      }

      case record.role
      when "external_original", "working_copy"
        result.merge!(inspect_media(path))
      when "source_screenshot"
        unless %w[png jpeg webp gif].include?(detected)
          result["state"] = "invalid"
          result["message"] = "Source screenshots must be a supported image file."
        end
      when "rights_statement"
        unless %w[pdf png jpeg webp gif text].include?(detected)
          result["state"] = "invalid"
          result["message"] = "Rights statements must be PDF, image or plain text evidence."
        end
      when "source_html"
        unless detected == "html" || text_like?(header)
          result["state"] = "invalid"
          result["message"] = "Source HTML does not appear to contain text or HTML."
        end
      when "source_warc"
        unless detected == "warc"
          result["state"] = "invalid"
          result["message"] = "The file does not begin with a WARC record header."
        end
      when "source_headers"
        unless detected == "json" || text_like?(header)
          result["state"] = "invalid"
          result["message"] = "Source headers must be JSON or plain text."
        end
      end

      warnings = consistency_warnings(record, detected)
      if warnings.any?
        result["warnings"] = warnings
        result["state"] = "warning" if result["state"] == "valid"
      end
      result
    rescue Timeout::Error
      {
        "state" => "failed",
        "inspected_at_utc" => Time.now.utc.iso8601(6),
        "message" => "Technical media inspection timed out after #{timeout_seconds} seconds.",
      }
    rescue => e
      {
        "state" => "failed",
        "inspected_at_utc" => Time.now.utc.iso8601(6),
        "error_class" => e.class.name,
        "message" => safe_error_message(e, path),
      }
    end

    def health
      return { "enabled" => false, "status" => "disabled" } unless enabled?

      path = ::MediaGallery::Ffmpeg.ffprobe_path
      stdout, stderr, status = Open3.capture3(path, "-version")
      first_line = stdout.to_s.lines.first.to_s.strip
      if status.success?
        { "enabled" => true, "status" => "available", "path" => path, "version" => first_line }
      else
        { "enabled" => true, "status" => "unavailable", "path" => path, "message" => ::MediaGallery::Ffmpeg.short_err(stderr) }
      end
    rescue => e
      { "enabled" => true, "status" => "unavailable", "message" => e.message.to_s.truncate(500) }
    end

    def inspectable_role?(role)
      %w[external_original working_copy source_screenshot source_html source_warc source_headers rights_statement].include?(role.to_s)
    end

    def inspect_media(path)
      probe = run_ffprobe(path)
      media_type = ::MediaGallery::TypeDetector.infer_from_probe(probe)
      summary = summarize_probe(probe)
      if %w[video audio].include?(media_type)
        {
          "state" => "valid",
          "media_type" => media_type,
          "ffprobe" => summary,
        }
      else
        {
          "state" => "invalid",
          "media_type" => media_type,
          "ffprobe" => summary,
          "message" => "Primary external evidence must contain an audio or video stream recognised by ffprobe.",
        }
      end
    end
    private_class_method :inspect_media

    def run_ffprobe(path)
      command = [
        ::MediaGallery::Ffmpeg.ffprobe_path,
        "-v", "error",
        "-protocol_whitelist", "file,pipe,crypto,data",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        path,
      ]

      stdout = nil
      stderr = nil
      status = nil
      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        stdin.close
        out_reader = Thread.new { read_limited(out, MAX_STDOUT_BYTES) }
        err_reader = Thread.new { read_limited(err, MAX_STDERR_BYTES) }
        begin
          Timeout.timeout(timeout_seconds) do
            stdout = out_reader.value
            stderr = err_reader.value
            status = wait_thread.value
          end
        rescue Timeout::Error
          terminate_process(wait_thread.pid)
          out_reader.kill
          err_reader.kill
          raise
        end
      end
      raise "ffprobe_failed: #{::MediaGallery::Ffmpeg.short_err(stderr)}" unless status&.success?

      JSON.parse(stdout)
    end
    private_class_method :run_ffprobe

    def read_limited(io, limit)
      buffer = +""
      while (chunk = io.read(16 * 1024))
        buffer << chunk
        raise IOError, "inspection_output_too_large" if buffer.bytesize > limit
      end
      buffer
    end
    private_class_method :read_limited

    def terminate_process(pid)
      Process.kill("TERM", pid) rescue nil
      sleep 0.2
      Process.kill("KILL", pid) rescue nil
    end
    private_class_method :terminate_process

    def summarize_probe(probe)
      format = probe["format"].is_a?(Hash) ? probe["format"] : {}
      streams = Array(probe["streams"]).map do |stream|
        {
          "index" => stream["index"],
          "codec_type" => stream["codec_type"],
          "codec_name" => stream["codec_name"],
          "profile" => stream["profile"],
          "width" => stream["width"],
          "height" => stream["height"],
          "sample_rate" => stream["sample_rate"],
          "channels" => stream["channels"],
          "avg_frame_rate" => stream["avg_frame_rate"],
          "duration" => stream["duration"],
          "bit_rate" => stream["bit_rate"],
        }.compact
      end
      {
        "format_name" => format["format_name"],
        "format_long_name" => format["format_long_name"],
        "duration" => format["duration"],
        "size" => format["size"],
        "bit_rate" => format["bit_rate"],
        "streams" => streams,
      }.compact
    end
    private_class_method :summarize_probe


    def consistency_warnings(record, detected)
      extension = File.extname(record.original_filename.to_s).downcase
      allowed_extensions = {
        "pdf" => %w[.pdf],
        "png" => %w[.png],
        "jpeg" => %w[.jpg .jpeg],
        "webp" => %w[.webp],
        "gif" => %w[.gif],
        "warc" => %w[.warc],
        "json" => %w[.json],
        "html" => %w[.html .htm],
        "text" => %w[.txt .text .log .headers],
      }[detected]
      warnings = []
      if extension.present? && allowed_extensions.present? && !allowed_extensions.include?(extension)
        warnings << "The filename extension #{extension} does not match the detected #{detected} content type."
      end

      declared = record.mime_type.to_s.downcase
      expected_prefixes = {
        "pdf" => %w[application/pdf],
        "png" => %w[image/png],
        "jpeg" => %w[image/jpeg],
        "webp" => %w[image/webp],
        "gif" => %w[image/gif],
        "warc" => %w[application/warc application/octet-stream],
        "json" => %w[application/json text/json text/plain application/octet-stream],
        "html" => %w[text/html text/plain application/octet-stream],
        "text" => %w[text/plain application/octet-stream],
      }[detected]
      if declared.present? && expected_prefixes.present? && !expected_prefixes.any? { |value| declared.start_with?(value) }
        warnings << "The declared MIME type #{declared} does not match the detected #{detected} content type."
      end
      warnings
    end
    private_class_method :consistency_warnings

    def detect_magic(header)
      bytes = header.to_s.b
      return "pdf" if bytes.start_with?("%PDF-")
      return "png" if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return "jpeg" if bytes.start_with?("\xFF\xD8\xFF".b)
      return "gif" if bytes.start_with?("GIF87a", "GIF89a")
      return "webp" if bytes.bytesize >= 12 && bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP"
      return "warc" if bytes.start_with?("WARC/")
      return "json" if valid_json?(bytes)
      return "html" if bytes.lstrip.match?(/\A(?:<!doctype\s+html|<html\b|<head\b|<body\b)/i)
      return "text" if text_like?(bytes)

      "binary"
    end
    private_class_method :detect_magic

    def valid_json?(bytes)
      value = bytes.to_s.strip
      return false unless value.start_with?("{", "[")

      JSON.parse(value)
      true
    rescue JSON::ParserError
      false
    end
    private_class_method :valid_json?

    def text_like?(bytes)
      value = bytes.to_s.b
      return false if value.include?("\x00")
      return true if value.empty?

      printable = value.bytes.count { |byte| byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126) || byte >= 160 }
      printable.fdiv(value.bytesize) >= 0.9
    end
    private_class_method :text_like?


    def safe_error_message(error, path)
      message = error.message.to_s
      message = message.gsub(path.to_s, "[evidence-file]") if path.present?
      message.truncate(500).presence || error.class.name
    end
    private_class_method :safe_error_message

    def not_applicable(message)
      {
        "state" => "not_applicable",
        "inspected_at_utc" => Time.now.utc.iso8601(6),
        "message" => message,
      }
    end
    private_class_method :not_applicable
  end
end
