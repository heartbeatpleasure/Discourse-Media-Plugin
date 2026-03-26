# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module ::MediaGallery
  module ForensicsIdentifyTasks
    module_function

    DEFAULT_ROOT = "/shared/media_gallery/forensics_identify_tasks"
    DEFAULT_RETENTION_HOURS = 24
    TASK_NAMESPACE = "media_gallery_forensics_identify_tasks"

    def root_path
      DEFAULT_ROOT
    end

    def retention_hours
      DEFAULT_RETENTION_HOURS
    end

    def ensure_root!
      FileUtils.mkdir_p(root_path)
      true
    end

    def cleanup!
      return unless Dir.exist?(root_path)
      cutoff = Time.now - retention_hours.hours

      Dir.glob(File.join(root_path, "*", ".task.json")).each do |marker|
        begin
          next if File.mtime(marker) > cutoff
          FileUtils.rm_rf(File.dirname(marker))
        rescue
          nil
        end
      end
    end

    def task_key(task_id)
      task_id.to_s
    end

    def task_dir(task_id)
      File.join(root_path, task_id.to_s)
    end

    def task_marker_path(task_id)
      File.join(task_dir(task_id), ".task.json")
    end

    def staged_input_path(task_id, original_filename = nil)
      ext = File.extname(original_filename.to_s)
      ext = ".bin" if ext.blank?
      File.join(task_dir(task_id), "input#{ext}")
    end

    def create_file_task!(public_id:, media_item_id:, upload:, max_samples:, max_offset_segments:, layout: nil)
      ensure_root!
      cleanup!

      raise Discourse::InvalidParameters.new(:file) if upload.blank?

      source_path = upload.respond_to?(:tempfile) ? upload.tempfile&.path : nil
      raise Discourse::InvalidParameters.new(:file) if source_path.blank? || !File.exist?(source_path)

      task_id = SecureRandom.hex(12)
      dir = task_dir(task_id)
      FileUtils.mkdir_p(dir)

      original_filename = upload.respond_to?(:original_filename) ? upload.original_filename.to_s : "upload.bin"
      input_path = staged_input_path(task_id, original_filename)
      FileUtils.cp(source_path, input_path)

      payload = {
        "task_id" => task_id,
        "public_id" => public_id.to_s,
        "media_item_id" => media_item_id.to_i,
        "mode" => "file",
        "input_file_path" => input_path,
        "original_filename" => original_filename,
        "max_samples" => max_samples.to_i,
        "max_offset_segments" => max_offset_segments.to_i,
        "layout" => layout.to_s.presence,
        "status" => "queued",
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601,
        "result" => nil,
        "error" => nil,
      }

      write_task(task_id, payload)
      File.write(task_marker_path(task_id), JSON.pretty_generate(payload)) rescue nil
      task_id
    end

    def read_task(task_id)
      ::PluginStore.get(TASK_NAMESPACE, task_key(task_id))
    end

    def write_task(task_id, payload)
      payload["updated_at"] = Time.now.utc.iso8601
      ::PluginStore.set(TASK_NAMESPACE, task_key(task_id), payload)
      File.write(task_marker_path(task_id), JSON.pretty_generate(payload)) rescue nil
      payload
    end

    def mark_task_working!(task_id)
      payload = read_task(task_id) || {}
      payload["status"] = "working"
      write_task(task_id, payload)
    end

    def mark_task_complete!(task_id, result)
      payload = read_task(task_id) || {}
      payload["status"] = "complete"
      payload["result"] = result
      payload["error"] = nil
      write_task(task_id, payload)
    end

    def mark_task_failed!(task_id, error_message)
      payload = read_task(task_id) || {}
      payload["status"] = "failed"
      payload["error"] = error_message.to_s
      write_task(task_id, payload)
    end
  end
end
