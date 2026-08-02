# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "securerandom"

module ::MediaGallery
  module EvidenceVault
    module_function

    DEFAULT_ROOT = "/shared/media_gallery/evidence_cases"
    BUFFER_SIZE = 1024 * 1024

    def root_path
      configured = if SiteSetting.respond_to?(:media_gallery_evidence_root_path)
        SiteSetting.media_gallery_evidence_root_path.to_s.strip
      else
        ""
      end
      File.expand_path(configured.presence || DEFAULT_ROOT)
    end

    def ensure_root!
      root = root_path
      raise ArgumentError, "unsafe_evidence_root" if root == File::SEPARATOR

      FileUtils.mkdir_p(root, mode: 0o750)
      raise ArgumentError, "evidence_root_symlink_not_allowed" if File.lstat(root).symlink?
      File.chmod(0o750, root) rescue nil
      root
    end

    def max_upload_bytes
      mb = if SiteSetting.respond_to?(:media_gallery_evidence_max_upload_mb)
        SiteSetting.media_gallery_evidence_max_upload_mb.to_i
      else
        1024
      end
      mb = 1024 if mb <= 0
      mb * 1024 * 1024
    end

    def package_include_max_bytes
      mb = if SiteSetting.respond_to?(:media_gallery_evidence_package_include_max_mb)
        SiteSetting.media_gallery_evidence_package_include_max_mb.to_i
      else
        20
      end
      mb = 20 if mb <= 0
      [mb, 256].min * 1024 * 1024
    end

    def store_upload!(evidence_case:, upload:, role:, user:, parent: nil, metadata: {}, include_in_package: nil)
      source_path = upload.respond_to?(:tempfile) ? upload.tempfile&.path : nil
      raise Discourse::InvalidParameters.new(:file) if source_path.blank? || !File.file?(source_path)

      original_filename = upload.respond_to?(:original_filename) ? upload.original_filename.to_s : "evidence.bin"
      mime_type = upload.respond_to?(:content_type) ? upload.content_type.to_s : "application/octet-stream"
      store_file!(
        evidence_case: evidence_case,
        source_path: source_path,
        original_filename: original_filename,
        mime_type: mime_type,
        role: role,
        user: user,
        parent: parent,
        metadata: metadata,
        include_in_package: include_in_package,
      )
    end

    def store_file!(evidence_case:, source_path:, original_filename:, mime_type:, role:, user:, parent: nil, metadata: {}, include_in_package: nil)
      validate_role!(role)
      source_stat = File.lstat(source_path)
      raise ArgumentError, "evidence_source_symlink_not_allowed" if source_stat.symlink?
      size = source_stat.size
      raise ArgumentError, "evidence_file_empty" if size <= 0
      raise ArgumentError, "evidence_file_too_large" if size > max_upload_bytes
      ensure_capacity!(size)

      object_ref = ::MediaGallery::EvidenceReference.object_ref
      safe_name = ::MediaGallery::EvidenceReference.safe_filename(original_filename)
      destination = object_path(evidence_case.case_ref, object_ref, safe_name)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o750)

      digest = Digest::SHA256.new
      bytes_written = 0
      temporary = "#{destination}.pending-#{SecureRandom.hex(8)}"
      begin
        File.open(source_path, "rb") do |input|
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o640) do |output|
            while (chunk = input.read(BUFFER_SIZE))
              digest.update(chunk)
              output.write(chunk)
              bytes_written += chunk.bytesize
            end
            output.flush
            output.fsync rescue nil
          end
        end

        raise "evidence_copy_size_mismatch" unless bytes_written == size
        temporary_hash = Digest::SHA256.file(temporary).hexdigest
        raise "evidence_copy_hash_mismatch" unless temporary_hash == digest.hexdigest
        raise "evidence_destination_exists" if File.exist?(destination)

        File.rename(temporary, destination)
        fsync_directory(File.dirname(destination))
        destination_hash = Digest::SHA256.file(destination).hexdigest
        raise "evidence_post_commit_hash_mismatch" unless destination_hash == temporary_hash

        record = ::MediaGallery::ForensicEvidenceObject.create!(
          evidence_case: evidence_case,
          parent: parent,
          object_ref: object_ref,
          role: role.to_s,
          storage_kind: "file",
          storage_path: relative_path(destination),
          original_filename: safe_name,
          mime_type: mime_type.to_s.presence || "application/octet-stream",
          size_bytes: size,
          sha256: destination_hash,
          quarantine_status: default_quarantine_status(role),
          include_in_package: include_in_package.nil? ? default_include_in_package?(role, size) : !!include_in_package,
          immutable_at: Time.now.utc,
          created_by: user,
          metadata: metadata.is_a?(Hash) ? metadata : {},
        )
        File.chmod(0o440, destination) rescue nil
        record
      rescue
        FileUtils.rm_f(temporary) rescue nil if defined?(temporary)
        FileUtils.rm_f(destination) rescue nil
        raise
      end
    end

    def store_bytes!(evidence_case:, bytes:, filename:, mime_type:, role:, user:, metadata: {}, quarantine_status: "not_applicable", include_in_package: true)
      validate_role!(role)
      payload = bytes.to_s.b
      raise ArgumentError, "evidence_file_empty" if payload.empty?
      raise ArgumentError, "evidence_file_too_large" if payload.bytesize > max_upload_bytes
      ensure_capacity!(payload.bytesize)

      object_ref = ::MediaGallery::EvidenceReference.object_ref
      safe_name = ::MediaGallery::EvidenceReference.safe_filename(filename)
      destination = object_path(evidence_case.case_ref, object_ref, safe_name)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o750)
      temporary = "#{destination}.pending-#{SecureRandom.hex(8)}"
      expected_sha = Digest::SHA256.hexdigest(payload)

      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o640) do |output|
          output.write(payload)
          output.flush
          output.fsync rescue nil
        end
        temporary_sha = Digest::SHA256.file(temporary).hexdigest
        raise "evidence_write_hash_mismatch" unless temporary_sha == expected_sha
        raise "evidence_destination_exists" if File.exist?(destination)

        File.rename(temporary, destination)
        fsync_directory(File.dirname(destination))
        sha = Digest::SHA256.file(destination).hexdigest
        raise "evidence_post_commit_hash_mismatch" unless sha == expected_sha

        record = ::MediaGallery::ForensicEvidenceObject.create!(
          evidence_case: evidence_case,
          object_ref: object_ref,
          role: role.to_s,
          storage_kind: "file",
          storage_path: relative_path(destination),
          original_filename: safe_name,
          mime_type: mime_type.to_s,
          size_bytes: payload.bytesize,
          sha256: sha,
          quarantine_status: quarantine_status,
          include_in_package: !!include_in_package,
          immutable_at: Time.now.utc,
          created_by: user,
          metadata: metadata.is_a?(Hash) ? metadata : {},
        )
        File.chmod(0o440, destination) rescue nil
        record
      rescue
        FileUtils.rm_f(temporary) rescue nil if defined?(temporary)
        FileUtils.rm_f(destination) rescue nil
        raise
      end
    end

    def register_vault_reference!(evidence_case:, vault_reference:, sha256:, size_bytes:, role:, user:, mime_type: nil, original_filename: nil, metadata: {})
      validate_role!(role)
      sha = sha256.to_s.downcase
      raise ArgumentError, "invalid_sha256" unless sha.match?(/\A[0-9a-f]{64}\z/)
      raise ArgumentError, "vault_reference_missing" if vault_reference.to_s.strip.blank?
      raise ArgumentError, "invalid_size_bytes" if size_bytes.to_i.negative?

      ::MediaGallery::ForensicEvidenceObject.create!(
        evidence_case: evidence_case,
        object_ref: ::MediaGallery::EvidenceReference.object_ref,
        role: role.to_s,
        storage_kind: "vault_reference",
        vault_reference: vault_reference.to_s.strip,
        original_filename: ::MediaGallery::EvidenceReference.safe_filename(original_filename, fallback: "external-evidence.bin"),
        mime_type: mime_type.to_s.presence || "application/octet-stream",
        size_bytes: size_bytes.to_i,
        sha256: sha,
        quarantine_status: "pending",
        include_in_package: false,
        immutable_at: Time.now.utc,
        created_by: user,
        metadata: metadata.is_a?(Hash) ? metadata : {},
      )
    end

    def absolute_path(record)
      raise ArgumentError, "not_file_backed" unless record.storage_kind == "file"

      path = ::MediaGallery::PathSecurity.safe_join!(ensure_root!, record.storage_path.to_s)
      raise Discourse::NotFound unless File.file?(path)
      raise Discourse::NotFound unless ::MediaGallery::PathSecurity.realpath_under?(path, ensure_root!)

      path
    end

    def read_bytes(record, max_bytes: nil)
      path = absolute_path(record)
      size = File.size(path)
      raise ArgumentError, "evidence_read_limit_exceeded" if max_bytes.present? && size > max_bytes.to_i

      bytes = File.binread(path)
      raise "evidence_hash_mismatch" unless Digest::SHA256.hexdigest(bytes) == record.sha256
      bytes
    end

    # Removes only a file created by a failed, rolled-back operation. It refuses cleanup when the
    # evidence-object row still exists, preserving immutable committed evidence.
    def discard_uncommitted_file!(record)
      return if record.blank? || record.storage_kind.to_s != "file" || record.storage_path.to_s.blank?
      return if record.id.present? && ::MediaGallery::ForensicEvidenceObject.where(id: record.id).exists?

      root = ensure_root!
      path = ::MediaGallery::PathSecurity.safe_join!(root, record.storage_path.to_s)
      return unless File.file?(path) && ::MediaGallery::PathSecurity.realpath_under?(path, root)

      File.chmod(0o640, path) rescue nil
      FileUtils.rm_f(path)
      parent = File.dirname(path)
      3.times do
        break unless parent.start_with?(root) && parent != root
        break unless Dir.exist?(parent) && Dir.empty?(parent)

        Dir.rmdir(parent)
        parent = File.dirname(parent)
      end
    rescue => e
      Rails.logger.warn("[media_gallery] failed to remove rolled-back evidence file: #{e.class}: #{e.message}") if defined?(Rails)
      nil
    end

    def minimum_free_space_bytes
      mb = if SiteSetting.respond_to?(:media_gallery_evidence_min_free_space_mb)
        SiteSetting.media_gallery_evidence_min_free_space_mb.to_i
      else
        2048
      end
      mb = 2048 if mb <= 0
      mb * 1024 * 1024
    rescue
      2048 * 1024 * 1024
    end

    def ensure_capacity!(incoming_bytes)
      health = storage_health
      unless health["available"] == true && health["writable"] == true
        raise ArgumentError, "evidence_storage_unavailable"
      end

      free = health["free_bytes"].to_i
      required = incoming_bytes.to_i + minimum_free_space_bytes
      raise ArgumentError, "evidence_storage_low_space" if free < required

      true
    end

    def storage_health
      root = ensure_root!
      stdout, stderr, status = Open3.capture3("df", "-Pk", root)
      unless status.success?
        return {
          "status" => "unavailable",
          "available" => false,
          "root" => root,
          "message" => stderr.to_s.truncate(500),
          "minimum_free_bytes" => minimum_free_space_bytes,
        }
      end

      line = stdout.to_s.lines.reject { |row| row.strip.blank? }.last.to_s
      fields = line.split
      blocks = fields[-5].to_i
      used = fields[-4].to_i
      available = fields[-3].to_i
      total_bytes = blocks * 1024
      free_bytes = available * 1024
      used_bytes = used * 1024
      reserve = minimum_free_space_bytes
      writable = File.writable?(root)
      used_percent = total_bytes.positive? ? ((used_bytes.to_f / total_bytes) * 100).round(1) : nil
      status = if !writable
        "unavailable"
      elsif free_bytes < reserve
        "low_space"
      elsif used_percent.present? && used_percent >= 90
        "limited_space"
      else
        "available"
      end
      {
        "status" => status,
        "available" => writable,
        "root" => root,
        "total_bytes" => total_bytes,
        "used_bytes" => used_bytes,
        "free_bytes" => free_bytes,
        "used_percent" => used_percent,
        "minimum_free_bytes" => reserve,
        "writable" => writable,
      }.compact
    rescue => e
      {
        "status" => "unavailable",
        "available" => false,
        "root" => root_path,
        "minimum_free_bytes" => minimum_free_space_bytes,
        "message" => e.message.to_s.truncate(500),
      }
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue
      nil
    end
    private_class_method :fsync_directory

    def object_path(case_ref, object_ref, filename)
      root = ensure_root!
      ::MediaGallery::PathSecurity.safe_join!(root, "cases", safe_component(case_ref), "objects", safe_component(object_ref), filename)
    end

    def report_path(case_ref, report_ref)
      root = ensure_root!
      ::MediaGallery::PathSecurity.safe_join!(root, "cases", safe_component(case_ref), "reports", "#{safe_component(report_ref)}.pdf")
    end

    def package_path(case_ref, package_ref)
      root = ensure_root!
      ::MediaGallery::PathSecurity.safe_join!(root, "cases", safe_component(case_ref), "packages", "#{safe_component(package_ref)}.tar.gz")
    end

    def atomic_write!(path, bytes, mode: 0o440)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o750)
      tmp = "#{path}.tmp-#{SecureRandom.hex(6)}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o640) do |file|
          file.write(bytes.to_s.b)
          file.flush
          file.fsync rescue nil
        end
        File.rename(tmp, path)
        File.chmod(mode, path) rescue nil
      ensure
        FileUtils.rm_f(tmp) rescue nil
      end
      path
    end

    def relative_path(path)
      root = ensure_root!
      expanded = File.expand_path(path)
      prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      raise ArgumentError, "path_outside_evidence_root" unless expanded.start_with?(prefix)

      expanded.delete_prefix(prefix)
    end

    def validate_role!(role)
      return if ::MediaGallery::ForensicEvidenceObject::ROLES.include?(role.to_s)

      raise ArgumentError, "invalid_evidence_role"
    end

    def default_quarantine_status(role)
      %w[identify_raw_json reference_snapshot report_pdf package].include?(role.to_s) ? "not_applicable" : "pending"
    end

    def default_include_in_package?(role, size)
      return false if role.to_s == "external_original"
      return false if size.to_i > package_include_max_bytes

      %w[source_screenshot source_html source_warc source_headers reference_snapshot].include?(role.to_s)
    end

    def safe_component(value)
      ::MediaGallery::PathSecurity.normalize_path_component!(value.to_s, name: "evidence_component")
    end
    private_class_method :safe_component
  end
end
