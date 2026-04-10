# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "tmpdir"

module ::MediaGallery
  module TestDownloads
    module_function

    DEFAULT_ROOT = "/shared/media_gallery/test_downloads"
    DEFAULT_RETENTION_HOURS = 24
    DEFAULT_VARIANT = ::MediaGallery::Hls::DEFAULT_VARIANT rescue "v0"

    def enabled?
      SiteSetting.respond_to?(:media_gallery_forensics_test_downloads_enabled) &&
        SiteSetting.media_gallery_forensics_test_downloads_enabled
    end

    def root_path
      p = SiteSetting.media_gallery_forensics_test_downloads_root_path.to_s.strip
      p = DEFAULT_ROOT if p.blank?
      p
    end

    def retention_hours
      hours = SiteSetting.media_gallery_forensics_test_downloads_retention_hours.to_i
      hours = DEFAULT_RETENTION_HOURS if hours <= 0
      hours
    rescue
      DEFAULT_RETENTION_HOURS
    end

    def packaged_codebook_scheme_for(item)
      meta = fingerprint_meta_for(item)
      return nil unless meta.is_a?(Hash)

      meta["codebook_scheme"].to_s.presence ||
        ::MediaGallery::Fingerprinting.codebook_scheme_for(layout: meta["layout"].to_s)
    rescue
      nil
    end

    def ensure_root!
      FileUtils.mkdir_p(root_path)
      test = File.join(root_path, ".writable_test_#{SecureRandom.hex(4)}")
      File.write(test, "ok")
      FileUtils.rm_f(test)
      true
    end

    def cleanup!
      return unless Dir.exist?(root_path)
      cutoff = Time.now - retention_hours.hours

      Dir.glob(File.join(root_path, "*", "*", ".complete")).each do |marker|
        begin
          next if File.mtime(marker) > cutoff
          FileUtils.rm_rf(File.dirname(marker))
        rescue
          nil
        end
      end
    end

    TASK_NAMESPACE = "media_gallery_test_downloads"

    def task_key(task_id)
      task_id.to_s
    end

    def create_task!(public_id:, user_id:, mode:, start_segment: 0, segment_count: nil)
      task_id = SecureRandom.hex(12)
      payload = {
        "task_id" => task_id,
        "public_id" => public_id.to_s,
        "user_id" => user_id.to_i,
        "mode" => mode.to_s,
        "start_segment" => start_segment.to_i,
        "segment_count" => segment_count.to_i > 0 ? segment_count.to_i : nil,
        "status" => "queued",
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601,
        "artifact" => nil,
        "error" => nil,
      }
      ::PluginStore.set(TASK_NAMESPACE, task_key(task_id), payload)
      task_id
    end

    def read_task(task_id)
      ::PluginStore.get(TASK_NAMESPACE, task_key(task_id))
    end

    def write_task(task_id, payload)
      payload["updated_at"] = Time.now.utc.iso8601
      ::PluginStore.set(TASK_NAMESPACE, task_key(task_id), payload)
      payload
    end

    def mark_task_working!(task_id)
      payload = read_task(task_id) || {}
      payload["status"] = "working"
      write_task(task_id, payload)
    end

    def mark_task_complete!(task_id, artifact_meta)
      payload = read_task(task_id) || {}
      payload["status"] = "complete"
      payload["artifact"] = artifact_meta
      payload["error"] = nil
      write_task(task_id, payload)
    end

    def mark_task_failed!(task_id, error_message)
      payload = read_task(task_id) || {}
      payload["status"] = "failed"
      payload["error"] = error_message.to_s
      write_task(task_id, payload)
    end

    def item_dir(public_id)
      File.join(root_path, public_id.to_s)
    end

    def artifact_dir(public_id, artifact_id)
      File.join(item_dir(public_id), artifact_id.to_s)
    end

    def artifact_meta_path(public_id, artifact_id)
      File.join(artifact_dir(public_id, artifact_id), "meta.json")
    end

    def artifact_file_path(public_id, artifact_id, ext = "mp4")
      File.join(artifact_dir(public_id, artifact_id), "artifact.#{ext}")
    end

    def template_playlist_path(item, variant: DEFAULT_VARIANT)
      access = managed_hls_access_for(item)
      return ::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: access[:role]) if access.present?

      ::MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
    end

    def parse_template_segments(item, variant: DEFAULT_VARIANT)
      raw = template_playlist_raw(item, variant: variant)
      raise Discourse::NotFound if raw.blank?

      names = []
      raw.to_s.each_line do |line|
        l = line.to_s.strip
        next if l.blank? || l.start_with?("#")
        names << File.basename(l)
      end
      names
    end

    def choose_random_partial(total_segments)
      total = total_segments.to_i
      raise "no_hls_segments" if total <= 0

      min_count = [[(total * 0.40).floor, 1].max, total].min
      max_count = [[(total * 0.50).ceil, min_count].max, total].min
      count = max_count <= min_count ? min_count : rand(min_count..max_count)

      region = %w[start middle end].sample
      start_idx =
        case region
        when "start"
          0
        when "middle"
          [(total - count) / 2, 0].max
        else
          [total - count, 0].max
        end

      {
        start_segment: start_idx,
        segment_count: count,
        region: region,
        total_segments: total,
        percent_of_video: total > 0 ? ((count.to_f / total) * 100.0).round(1) : 0.0,
      }
    end

    def resolve_segment_selection(seg_names:, mode:, start_segment:, segment_count:)
      total = seg_names.length
      raise "no_hls_segments" if total <= 0

      selection = {
        mode: mode.to_s,
        start_segment: [start_segment.to_i, 0].max,
        segment_count: segment_count.to_i > 0 ? segment_count.to_i : nil,
        total_segments: total,
        random_clip_region: nil,
        clip_percent_of_video: nil,
      }

      if mode.to_s == "random_partial"
        random_sel = choose_random_partial(total)
        selection[:start_segment] = random_sel[:start_segment]
        selection[:segment_count] = random_sel[:segment_count]
        selection[:random_clip_region] = random_sel[:region]
        selection[:clip_percent_of_video] = random_sel[:percent_of_video]
      end

      start_idx = [selection[:start_segment].to_i, 0].max
      chosen = seg_names.drop(start_idx)
      chosen = chosen.first(selection[:segment_count].to_i) if selection[:segment_count].to_i > 0
      raise "no_segments_selected" if chosen.blank?

      selection.merge(chosen_segment_names: chosen)
    end

    def select_segments(item:, user_id:, mode:, start_segment: 0, segment_count: nil, variant: DEFAULT_VARIANT)
      seg_names = parse_template_segments(item, variant: variant)
      selection = resolve_segment_selection(
        seg_names: seg_names,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      fingerprint_id = ::MediaGallery::Fingerprinting.fingerprint_id_for(user_id: user_id.to_i, media_item_id: item.id)
      codebook_scheme = packaged_codebook_scheme_for(item)

      segment_entries = selection[:chosen_segment_names].map do |filename|
        seg_idx = ::MediaGallery::Fingerprinting.segment_index_from_filename(filename)
        raise "invalid_segment_filename: #{filename}" if seg_idx.nil?

        ab = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: fingerprint_id,
          media_item_id: item.id,
          segment_index: seg_idx,
          codebook: codebook_scheme,
        )

        { filename: filename, ab: ab.to_s, segment_index: seg_idx }
      end

      {
        segment_entries: segment_entries,
        fingerprint_id: fingerprint_id,
        start_segment: selection[:start_segment],
        segment_count: segment_entries.length,
        total_segments: selection[:total_segments],
        random_clip_region: selection[:random_clip_region],
        clip_percent_of_video: selection[:clip_percent_of_video],
        variant: variant.to_s,
      }
    end

    def build_artifact!(item:, user_id:, mode:, start_segment: 0, segment_count: nil)
      raise Discourse::InvalidAccess unless enabled?

      ensure_root!
      cleanup!

      selected = select_segments(
        item: item,
        user_id: user_id,
        mode: mode,
        start_segment: start_segment,
        segment_count: segment_count,
      )

      artifact_id = SecureRandom.hex(12)
      dir = artifact_dir(item.public_id, artifact_id)
      FileUtils.mkdir_p(dir)

      output_path = artifact_file_path(item.public_id, artifact_id, "mp4")
      concat_list = File.join(dir, "concat.txt")

      Dir.mktmpdir("media_gallery_test_download") do |stage_dir|
        staged_paths = stage_selected_segments!(item: item, selection: selected, stage_dir: stage_dir)
        File.write(concat_list, staged_paths.map { |p| "file '#{p.gsub("'", %q('\\''))}'" }.join("\n") + "\n")

        ::MediaGallery::Ffmpeg.concat_ts_segments_to_mp4(
          concat_file_path: concat_list,
          output_path: output_path,
        )
      end

      user = ::User.find_by(id: user_id.to_i)

      meta = {
        "artifact_id" => artifact_id,
        "public_id" => item.public_id,
        "media_item_id" => item.id,
        "user_id" => user_id.to_i,
        "username" => user&.username,
        "fingerprint_id" => selected[:fingerprint_id],
        "mode" => mode.to_s,
        "variant" => selected[:variant],
        "start_segment" => selected[:start_segment],
        "segment_count" => selected[:segment_count],
        "total_segments" => selected[:total_segments],
        "random_clip_region" => selected[:random_clip_region],
        "clip_percent_of_video" => selected[:clip_percent_of_video],
        "segment_seconds" => ::MediaGallery::Hls.segment_duration_seconds,
        "created_at" => Time.now.utc.iso8601,
        "file_path" => output_path,
        "file_size_bytes" => File.size?(output_path).to_i,
      }

      File.write(artifact_meta_path(item.public_id, artifact_id), JSON.pretty_generate(meta))
      File.write(File.join(dir, ".complete"), Time.now.utc.iso8601)
      meta
    rescue => e
      begin
        FileUtils.rm_rf(dir) if dir.present? && Dir.exist?(dir)
      rescue
        nil
      end
      raise e
    end

    def read_meta!(public_id, artifact_id)
      path = artifact_meta_path(public_id, artifact_id)
      raise Discourse::NotFound unless File.exist?(path)
      JSON.parse(File.read(path))
    end

    def template_playlist_raw(item, variant: DEFAULT_VARIANT)
      access = managed_hls_access_for(item)
      if access.present?
        key = ::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: access[:role])
        return access[:store].read(key)
      end

      path = ::MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
      raise Discourse::NotFound if path.blank? || !File.exist?(path)
      File.read(path)
    end
    private_class_method :template_playlist_raw

    def fingerprint_meta_for(item)
      access = managed_hls_access_for(item)
      if access.present?
        key = ::MediaGallery::Hls.fingerprint_meta_key_for(item, role: access[:role])
        begin
          raw = access[:store].read(key)
          meta = JSON.parse(raw) rescue nil
          return meta if meta.is_a?(Hash)
        rescue
          nil
        end
      end

      root = ::MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
      meta_path = File.join(root, "fingerprint_meta.json")
      return nil unless File.exist?(meta_path)

      meta = JSON.parse(File.read(meta_path)) rescue nil
      meta.is_a?(Hash) ? meta : nil
    rescue
      nil
    end
    private_class_method :fingerprint_meta_for

    def managed_hls_access_for(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      return nil unless role.present?
      return nil unless ::MediaGallery::Hls.managed_role_ready?(item, role)

      store = ::MediaGallery::Hls.store_for_managed_role(item, role)
      return nil if store.blank?

      { role: role.deep_stringify_keys, store: store }
    rescue
      nil
    end
    private_class_method :managed_hls_access_for

    def stage_selected_segments!(item:, selection:, stage_dir:)
      access = managed_hls_access_for(item)

      Array(selection[:segment_entries]).map.with_index do |entry, idx|
        filename = entry[:filename].to_s
        ab = entry[:ab].to_s
        dest = File.join(stage_dir, format("%05d_%s", idx, filename))

        if access.present?
          key = ::MediaGallery::Hls.segment_key_for(
            item,
            selection[:variant],
            filename,
            ab: ab,
            role: access[:role]
          )
          access[:store].download_to_file!(key, dest)
        else
          base = ::MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
          source = File.join(base, ab, selection[:variant].to_s, filename)
          raise "missing_segment_file: #{source}" unless File.exist?(source)
          FileUtils.cp(source, dest)
        end

        raise "staged_segment_missing: #{dest}" unless File.exist?(dest)
        dest
      end
    end
    private_class_method :stage_selected_segments!
  end
end
