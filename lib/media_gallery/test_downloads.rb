# frozen_string_literal: true

require "digest"
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
      meta = ::MediaGallery::Hls.fingerprint_meta_for(item)
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

    def metadata_url_for(public_id, artifact_id)
      "/admin/plugins/media-gallery/test-downloads/#{public_id}/#{artifact_id}?meta=1"
    end

    def download_url_for(public_id, artifact_id)
      "/admin/plugins/media-gallery/test-downloads/#{public_id}/#{artifact_id}"
    end

    def recent_artifacts_for(public_id, limit: 10)
      root = item_dir(public_id)
      return [] unless Dir.exist?(root)

      entries = Dir.children(root).sort_by do |artifact_id|
        dir = artifact_dir(public_id, artifact_id)
        begin
          -File.mtime(File.join(dir, ".complete")).to_f
        rescue
          begin
            -File.mtime(artifact_meta_path(public_id, artifact_id)).to_f
          rescue
            0
          end
        end
      end

      entries.first([limit.to_i, 1].max).filter_map do |artifact_id|
        begin
          meta = read_meta!(public_id, artifact_id)
          artifact_summary_from_meta(meta)
        rescue
          nil
        end
      end
    rescue
      []
    end

    def template_playlist_path(item, variant: DEFAULT_VARIANT)
      access = managed_hls_access_for(item)
      return ::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: access[:role]) if access.present?

      ::MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
    end

    def parse_template_segment_entries(item, variant: DEFAULT_VARIANT)
      raw = template_playlist_raw(item, variant: variant)
      raise Discourse::NotFound if raw.blank?

      entries = []
      last_extinf = nil

      raw.to_s.each_line do |line|
        l = line.to_s.strip
        next if l.blank?

        if l.start_with?("#EXTINF:")
          dur_s = l.sub("#EXTINF:", "").split(",").first.to_s
          dur = dur_s.to_f
          last_extinf = (dur > 0.0 ? dur : nil)
          next
        end

        next if l.start_with?("#")

        entries << {
          filename: File.basename(l),
          duration: last_extinf.to_f > 0.0 ? last_extinf.to_f : nil,
        }
        last_extinf = nil
      end

      entries
    end

    def parse_template_segments(item, variant: DEFAULT_VARIANT)
      parse_template_segment_entries(item, variant: variant).map { |entry| entry[:filename] }
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
      template_entries = parse_template_segment_entries(item, variant: variant)
      seg_names = template_entries.map { |entry| entry[:filename] }
      duration_by_name = template_entries.each_with_object({}) do |entry, acc|
        acc[entry[:filename].to_s] = entry[:duration].to_f
      end

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

        {
          filename: filename,
          ab: ab.to_s,
          segment_index: seg_idx,
          duration: duration_by_name[filename.to_s].to_f,
        }
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

      user = ::User.find_by(id: user_id.to_i)
      provenance = build_provenance_context(item: item, user: user, user_id: user_id.to_i, selection: selected)
      verify_selection_provenance!(item: item, selection: selected, provenance: provenance)

      artifact_id = SecureRandom.hex(12)
      dir = artifact_dir(item.public_id, artifact_id)
      FileUtils.mkdir_p(dir)

      output_path = artifact_file_path(item.public_id, artifact_id, "mp4")
      concat_list = File.join(dir, "concat.txt")

      generation_method = "concat_copy_primary"
      generation_error = nil
      verification = nil
      staged_entries = []

      Dir.mktmpdir("media_gallery_test_download") do |stage_dir|
        staged_entries = stage_selected_segments!(item: item, selection: selected, stage_dir: stage_dir)
        verification = verify_staged_selection!(selection: selected, staged_entries: staged_entries)
        raise "artifact_provenance_guard_failed: staged_selection_mismatch" unless verification["verified"]

        playlist_path = File.join(stage_dir, "artifact.m3u8")
        build_local_hls_playlist!(playlist_path: playlist_path, staged_entries: staged_entries)
        begin
          File.write(concat_list, staged_entries.map { |entry| "file '#{entry[:path].to_s.gsub("'", %q('\\''))}'" }.join("\n") + "\n")

          ::MediaGallery::Ffmpeg.concat_ts_segments_to_mp4(
            concat_file_path: concat_list,
            output_path: output_path,
          )
        rescue => e
          generation_error = "#{e.class}: #{e.message}"
          ::MediaGallery::Ffmpeg.remux_local_hls_to_mp4(
            playlist_path: playlist_path,
            output_path: output_path,
          )
          generation_method = "hls_playlist_fallback"
        end
      end

      raise "artifact_output_missing" unless File.exist?(output_path)
      verification ||= {}
      verification["artifact_file_present"] = File.exist?(output_path)
      checks = verification.reject { |k, _| k.to_s == "warnings" || k.to_s == "verified" }
      verification["verified"] = checks.values.all? { |v| v == true }

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
        "generation_method" => generation_method,
        "generation_method_fallback_error" => generation_error,
        "segment_indices" => Array(selected[:segment_entries]).map { |entry| entry[:segment_index].to_i },
        "segment_filenames" => Array(selected[:segment_entries]).map { |entry| entry[:filename].to_s },
        "segment_variants" => Array(selected[:segment_entries]).map { |entry| entry[:ab].to_s },
        "segment_durations" => Array(selected[:segment_entries]).map { |entry| entry[:duration].to_f.round(6) },
        "segment_source_locators" => Array(staged_entries).map { |entry| entry[:source_locator].to_s },
        "provenance" => provenance,
        "verification" => verification,
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

    def artifact_summary_from_meta(meta)
      return nil unless meta.is_a?(Hash)

      {
        "artifact_id" => meta["artifact_id"].to_s,
        "public_id" => meta["public_id"].to_s,
        "media_item_id" => meta["media_item_id"].to_i,
        "user_id" => meta["user_id"].to_i,
        "username" => meta["username"],
        "fingerprint_id" => meta["fingerprint_id"],
        "mode" => meta["mode"],
        "variant" => meta["variant"],
        "segment_count" => meta["segment_count"].to_i,
        "random_clip_region" => meta["random_clip_region"],
        "created_at" => meta["created_at"],
        "file_size_bytes" => meta["file_size_bytes"].to_i,
        "download_url" => download_url_for(meta["public_id"], meta["artifact_id"]),
        "metadata_url" => metadata_url_for(meta["public_id"], meta["artifact_id"]),
        "provenance_verified" => !!meta.dig("verification", "verified"),
        "segment_variants_sha256" => meta.dig("provenance", "segment_variants_sha256").to_s.presence,
        "segment_manifest_sha256" => meta.dig("provenance", "segment_manifest_sha256").to_s.presence,
        "packaged_layout" => meta.dig("provenance", "packaged_layout").to_s.presence,
        "packaged_codebook_scheme" => meta.dig("provenance", "packaged_codebook_scheme").to_s.presence,
      }.compact
    rescue
      nil
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

    def build_provenance_context(item:, user:, user_id:, selection:)
      package_meta = ::MediaGallery::Hls.fingerprint_meta_for(item)
      requested_fingerprint_id = ::MediaGallery::Fingerprinting.fingerprint_id_for(
        user_id: user_id.to_i,
        media_item_id: item.id,
      )
      segment_entries = Array(selection[:segment_entries])
      variants = segment_entries.map { |entry| entry[:ab].to_s }
      segment_manifest = segment_entries.map do |entry|
        [entry[:segment_index].to_i, entry[:filename].to_s, entry[:ab].to_s]
      end
      warnings = []
      warnings << "missing_packaged_fingerprint_meta" unless package_meta.is_a?(Hash)
      warnings << "selection_all_same_variant" if variants.uniq.length <= 1

      {
        "requested_user_id" => user_id.to_i,
        "requested_username" => user&.username,
        "requested_fingerprint_id" => requested_fingerprint_id,
        "selection_fingerprint_id" => selection[:fingerprint_id].to_s,
        "segment_variants_compact" => variants.join,
        "segment_variants_sha256" => Digest::SHA256.hexdigest(variants.join),
        "segment_manifest_sha256" => Digest::SHA256.hexdigest(JSON.dump(segment_manifest)),
        "segment_variant_counts" => {
          "a" => variants.count("a"),
          "b" => variants.count("b"),
        },
        "packaged_layout" => package_meta.is_a?(Hash) ? package_meta["layout"].to_s.presence : nil,
        "packaged_configured_layout" => package_meta.is_a?(Hash) ? package_meta["configured_layout"].to_s.presence : nil,
        "packaged_layout_selection_reason" => package_meta.is_a?(Hash) ? package_meta["layout_selection_reason"].to_s.presence : nil,
        "packaged_legacy_layout_auto_upgraded" => package_meta.is_a?(Hash) ? !!ActiveModel::Type::Boolean.new.cast(package_meta["legacy_layout_auto_upgraded"]) : nil,
        "packaged_codebook_scheme" => package_meta.is_a?(Hash) ? package_meta["codebook_scheme"].to_s.presence : nil,
        "packaged_profile" => package_meta.is_a?(Hash) ? package_meta["profile"].to_s.presence : nil,
        "packaged_generated_at" => package_meta.is_a?(Hash) ? package_meta["generated_at"] : nil,
        "warnings" => warnings,
      }.compact
    end
    private_class_method :build_provenance_context

    def verify_selection_provenance!(item:, selection:, provenance:)
      errors = []
      requested_fp = provenance["requested_fingerprint_id"].to_s
      selected_fp = selection[:fingerprint_id].to_s
      errors << "fingerprint_id_mismatch" unless requested_fp.present? && requested_fp == selected_fp

      codebook_scheme = provenance["packaged_codebook_scheme"].to_s.presence || packaged_codebook_scheme_for(item)
      Array(selection[:segment_entries]).each do |entry|
        expected = ::MediaGallery::Fingerprinting.expected_variant_for_segment(
          fingerprint_id: selected_fp,
          media_item_id: item.id,
          segment_index: entry[:segment_index].to_i,
          codebook: codebook_scheme,
        )
        next if expected.to_s == entry[:ab].to_s

        errors << "variant_mismatch_at_segment_#{entry[:segment_index]}"
        break
      end

      raise "artifact_provenance_guard_failed: #{errors.join(', ')}" if errors.present?
      true
    end
    private_class_method :verify_selection_provenance!

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

    def build_local_hls_playlist!(playlist_path:, staged_entries:)
      entries = Array(staged_entries)
      raise "no_staged_segments" if entries.blank?

      target_duration = entries.map { |entry| entry[:duration].to_f }.select { |v| v > 0.0 }.max.to_f.ceil
      target_duration = 1 if target_duration <= 0

      body = []
      body << "#EXTM3U"
      body << "#EXT-X-VERSION:3"
      body << "#EXT-X-PLAYLIST-TYPE:VOD"
      body << "#EXT-X-TARGETDURATION:#{target_duration}"
      body << "#EXT-X-MEDIA-SEQUENCE:0"

      entries.each do |entry|
        dur = entry[:duration].to_f
        dur = ::MediaGallery::Hls.segment_duration_seconds.to_f if dur <= 0.0
        body << format("#EXTINF:%.6f,", dur)
        body << File.basename(entry[:path].to_s)
      end

      body << "#EXT-X-ENDLIST"
      File.write(playlist_path, body.join("\n") + "\n")
      playlist_path
    end
    private_class_method :build_local_hls_playlist!

    def verify_staged_selection!(selection:, staged_entries:)
      expected = Array(selection[:segment_entries])
      actual = Array(staged_entries)
      checks = {
        "selection_count_matches_staged" => expected.length == actual.length,
        "segment_indices_match_staged" => expected.map { |entry| entry[:segment_index].to_i } == actual.map { |entry| entry[:segment_index].to_i },
        "segment_filenames_match_staged" => expected.map { |entry| entry[:filename].to_s } == actual.map { |entry| entry[:filename].to_s },
        "segment_variants_match_staged" => expected.map { |entry| entry[:ab].to_s } == actual.map { |entry| entry[:ab].to_s },
        "source_locators_present" => actual.all? { |entry| entry[:source_locator].to_s.present? },
        "staged_files_present" => actual.all? { |entry| File.exist?(entry[:path].to_s) },
      }
      {
        "verified" => checks.values.all? { |v| v == true },
        "warnings" => [],
      }.merge(checks)
    end
    private_class_method :verify_staged_selection!

    def stage_selected_segments!(item:, selection:, stage_dir:)
      access = managed_hls_access_for(item)

      Array(selection[:segment_entries]).map.with_index do |entry, idx|
        filename = entry[:filename].to_s
        ab = entry[:ab].to_s
        dest = File.join(stage_dir, format("%05d_%s", idx, filename))
        source_locator = nil

        if access.present?
          key = ::MediaGallery::Hls.segment_key_for(
            item,
            selection[:variant],
            filename,
            ab: ab,
            role: access[:role]
          )
          access[:store].download_to_file!(key, dest)
          source_locator = "managed:#{key}"
        else
          base = ::MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
          relative = File.join(ab, selection[:variant].to_s, filename)
          source = File.join(base, relative)
          raise "missing_segment_file: #{source}" unless File.exist?(source)
          FileUtils.cp(source, dest)
          source_locator = "local:#{relative}"
        end

        raise "staged_segment_missing: #{dest}" unless File.exist?(dest)
        {
          path: dest,
          filename: filename,
          segment_index: entry[:segment_index].to_i,
          duration: entry[:duration].to_f,
          ab: ab,
          source_locator: source_locator,
        }
      end
    end
    private_class_method :stage_selected_segments!
  end
end
