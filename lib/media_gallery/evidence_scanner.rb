# frozen_string_literal: true

require "time"
require "socket"
require "timeout"

module ::MediaGallery
  module EvidenceScanner
    module_function

    MODES = %w[disabled clamd_tcp].freeze
    STREAM_CHUNK_BYTES = 1024 * 1024
    MAX_RESPONSE_BYTES = 16 * 1024

    def mode
      configured = setting_string(:media_gallery_evidence_malware_scanner, "disabled")
      MODES.include?(configured) ? configured : "disabled"
    end

    def enabled?
      mode != "disabled"
    end

    def scan_max_bytes
      setting_integer(:media_gallery_evidence_scan_max_mb, 512, min: 1, max: 10_240) * 1024 * 1024
    end

    def connect_timeout
      setting_integer(:media_gallery_evidence_scan_connect_timeout_seconds, 3, min: 1, max: 30)
    end

    def scan_timeout
      setting_integer(:media_gallery_evidence_scan_timeout_seconds, 180, min: 10, max: 3600)
    end

    def clamd_host
      setting_string(:media_gallery_evidence_clamd_host, "")
    end

    def clamd_port
      setting_integer(:media_gallery_evidence_clamd_port, 3310, min: 1, max: 65_535)
    end

    def scan(path)
      return disabled_result unless enabled?
      raise ArgumentError, "evidence_scan_file_missing" unless File.file?(path)

      size = File.size(path)
      if size > scan_max_bytes
        return base_result("skipped_size").merge(
          "complete" => false,
          "size_bytes" => size,
          "scan_limit_bytes" => scan_max_bytes,
          "message" => "File exceeds the configured automatic scanner size limit.",
        )
      end

      case mode
      when "clamd_tcp"
        scan_with_clamd_tcp(path, size)
      else
        disabled_result
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, IOError => e
      base_result("scanner_unavailable").merge(
        "complete" => false,
        "error_class" => e.class.name,
        "message" => safe_message(e),
      )
    rescue Timeout::Error => e
      base_result("scan_failed").merge(
        "complete" => false,
        "error_class" => e.class.name,
        "message" => "Malware scan timed out after #{scan_timeout} seconds.",
      )
    rescue => e
      base_result("scan_failed").merge(
        "complete" => false,
        "error_class" => e.class.name,
        "message" => safe_message(e),
      )
    end

    def health
      result = {
        "mode" => mode,
        "enabled" => enabled?,
        "scan_max_bytes" => scan_max_bytes,
        "host_configured" => clamd_host.present?,
      }
      return result.merge("status" => "disabled", "available" => false) unless enabled?
      return result.merge("status" => "misconfigured", "available" => false, "message" => "ClamAV host is not configured.") if clamd_host.blank?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = clamd_command("VERSION", timeout_seconds: [connect_timeout + 2, 5].min)
      result.merge(
        "status" => "available",
        "available" => true,
        "version" => response.to_s.strip,
        "latency_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      )
    rescue => e
      result.merge(
        "status" => "unavailable",
        "available" => false,
        "error_class" => e.class.name,
        "message" => safe_message(e),
      )
    end

    def disabled_result
      base_result("disabled").merge(
        "complete" => false,
        "message" => "Automatic malware scanning is disabled; staff quarantine review is required.",
      )
    end

    def scan_with_clamd_tcp(path, size)
      raise ArgumentError, "evidence_clamd_host_missing" if clamd_host.blank?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = nil
      Timeout.timeout(scan_timeout) do
        Socket.tcp(clamd_host, clamd_port, connect_timeout: connect_timeout) do |socket|
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil
          socket.write("zINSTREAM\0")
          File.open(path, "rb") do |input|
            while (chunk = input.read(STREAM_CHUNK_BYTES))
              socket.write([chunk.bytesize].pack("N"))
              socket.write(chunk)
            end
          end
          socket.write([0].pack("N"))
          response = read_terminated(socket)
        end
      end

      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      result = parse_scan_response(response).merge(
        "size_bytes" => size,
        "duration_ms" => elapsed,
        "scan_limit_bytes" => scan_max_bytes,
      )
      begin
        result["version"] = clamd_command("VERSION", timeout_seconds: [connect_timeout + 2, 5].min).to_s.strip
      rescue => e
        result["version_error"] = e.class.name
      end
      result
    end
    private_class_method :scan_with_clamd_tcp

    def clamd_command(command, timeout_seconds:)
      raise ArgumentError, "evidence_clamd_host_missing" if clamd_host.blank?

      Timeout.timeout(timeout_seconds) do
        Socket.tcp(clamd_host, clamd_port, connect_timeout: connect_timeout) do |socket|
          socket.write("z#{command}\0")
          return read_terminated(socket)
        end
      end
    end
    private_class_method :clamd_command

    def read_terminated(socket)
      output = +""
      loop do
        chunk = socket.readpartial(4096)
        output << chunk
        raise IOError, "clamd_response_too_large" if output.bytesize > MAX_RESPONSE_BYTES
        break if output.include?("\0") || output.include?("\n")
      end
      output.delete_suffix("\0").strip
    rescue EOFError
      output.strip
    end
    private_class_method :read_terminated

    def parse_scan_response(response)
      text = response.to_s.strip
      if text.match?(/:\s+OK\z/i)
        return base_result("clean").merge("complete" => true, "response" => text)
      end

      if (match = text.match(/:\s+(.+?)\s+FOUND\z/i))
        return base_result("infected").merge(
          "complete" => true,
          "signature" => match[1].to_s.strip,
          "response" => text,
        )
      end

      state = text.match?(/size limit exceeded/i) ? "skipped_size" : "scan_failed"
      base_result(state).merge(
        "complete" => false,
        "response" => text,
        "message" => text.presence || "ClamAV returned an empty response.",
      )
    end
    private_class_method :parse_scan_response

    def base_result(state)
      {
        "provider" => mode,
        "state" => state,
        "scanned_at_utc" => Time.now.utc.iso8601(6),
      }
    end
    private_class_method :base_result

    def safe_message(error)
      error.message.to_s.truncate(500).presence || error.class.name
    end
    private_class_method :safe_message

    def setting_string(name, fallback)
      return fallback unless SiteSetting.respond_to?(name)

      SiteSetting.public_send(name).to_s.strip.presence || fallback
    rescue
      fallback
    end
    private_class_method :setting_string

    def setting_integer(name, fallback, min:, max:)
      value = SiteSetting.respond_to?(name) ? SiteSetting.public_send(name).to_i : fallback
      [[value, min].max, max].min
    rescue
      fallback
    end
    private_class_method :setting_integer
  end
end
