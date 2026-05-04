# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"
require "json"
require "digest"
require "tmpdir"

require_relative "fingerprint_watermark"

module ::MediaGallery
  # HLS packaging + readiness + managed-store publishing.
  #
  # Current rollout strategy:
  # - packaging happens inside a processing workspace / scratch directory
  # - the finalized package is published from scratch into the active managed
  #   store only after validation succeeds
  # - for non-local backends we keep a best-effort local mirror for backwards
  #   compatibility with older admin / tooling flows while managed storage stays
  #   the canonical source of truth
  module Hls
    module_function

    DEFAULT_VARIANT = "v0"

    def fingerprinting_enabled?
      defined?(::MediaGallery::Fingerprinting) && ::MediaGallery::Fingerprinting.enabled?
    rescue
      false
    end

    def enabled?
      SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled
    end

    # AES-128 HLS hardening helpers.
    #
    # The AES implementation is intentionally incremental. These helpers expose
    # site-wide status and metadata while the packaging/controller layers opt in
    # only when the full guarded path is available.
    def aes128_setting_enabled?
      SiteSetting.respond_to?(:media_gallery_hls_aes128_enabled) &&
        ActiveModel::Type::Boolean.new.cast(SiteSetting.media_gallery_hls_aes128_enabled)
    rescue
      false
    end

    def aes128_enabled?
      enabled? && aes128_setting_enabled?
    rescue
      false
    end

    def aes128_required?
      aes128_enabled? &&
        SiteSetting.respond_to?(:media_gallery_hls_aes128_required) &&
        ActiveModel::Type::Boolean.new.cast(SiteSetting.media_gallery_hls_aes128_required)
    rescue
      false
    end

    def aes128_key_rotation_segments
      value =
        if SiteSetting.respond_to?(:media_gallery_hls_aes128_key_rotation_segments)
          SiteSetting.media_gallery_hls_aes128_key_rotation_segments.to_i
        else
          0
        end

      value = 0 if value.negative?
      value = 1000 if value > 1000
      value
    rescue
      0
    end

    def aes128_key_denial_logging_enabled?
      SiteSetting.respond_to?(:media_gallery_log_hls_aes128_key_denials) &&
        ActiveModel::Type::Boolean.new.cast(SiteSetting.media_gallery_log_hls_aes128_key_denials)
    rescue
      false
    end

    def aes128_encryption_meta_for(item, role: nil)
      role ||= managed_role_for(item)
      return nil unless role.is_a?(Hash)

      encryption = role["encryption"]
      return nil unless encryption.is_a?(Hash)

      encryption = encryption.deep_stringify_keys
      return nil unless encryption["method"].to_s.casecmp("AES-128").zero?

      encryption
    rescue
      nil
    end

    def aes128_ready?(item, role: nil)
      encryption = aes128_encryption_meta_for(item, role: role)
      return false unless encryption.is_a?(Hash)

      ActiveModel::Type::Boolean.new.cast(encryption["ready"]) &&
        encryption["key_id"].to_s.present? &&
        encryption["scheme"].to_s.present?
    rescue
      false
    end

    def aes128_status_for(item, role: nil)
      role ||= managed_role_for(item)
      encryption = aes128_encryption_meta_for(item, role: role)

      {
        "enabled" => aes128_enabled?,
        "required" => aes128_required?,
        "ready" => aes128_ready?(item, role: role),
        "method" => encryption.is_a?(Hash) ? encryption["method"].to_s.presence : nil,
        "scheme" => encryption.is_a?(Hash) ? encryption["scheme"].to_s.presence : nil,
        "key_rotation_segments" => aes128_key_rotation_segments,
      }.compact
    rescue
      {
        "enabled" => false,
        "required" => false,
        "ready" => false,
        "key_rotation_segments" => 0,
      }
    end

    def segment_duration_seconds
      s = 0
      begin
        s = SiteSetting.media_gallery_hls_segment_duration_seconds.to_i
      rescue
        s = 0
      end

      s = 6 if s <= 0
      s = 2 if s < 2
      s = 10 if s > 10
      s
    end

    def variants
      [DEFAULT_VARIANT]
    end

    def variant_allowed?(variant)
      variants.include?(variant.to_s)
    end

    def managed_role_for(item)
      role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      return nil unless role.is_a?(Hash)
      role.deep_stringify_keys
    rescue
      nil
    end

    def managed_role_ready?(item, role)
      return false unless role.is_a?(Hash)
      backend = role["backend"].to_s
      return false if backend.blank?

      store = store_for_managed_role(item, role)
      return false if store.blank?

      master_key = master_key_for(item, role: role)
      complete_key = complete_key_for(item, role: role)
      return false if master_key.blank? || complete_key.blank?
      return false unless store.exists?(master_key) && store.exists?(complete_key)

      role_variants = role_variants_for(role)
      role_variants.all? do |v|
        playlist_key = variant_playlist_key_for(item, v, role: role)
        next false if playlist_key.blank? || !store.exists?(playlist_key)

        if role_uses_ab_layout?(role)
          a_prefix = ab_variant_prefix_for(item, v, "a", role: role)
          b_prefix = ab_variant_prefix_for(item, v, "b", role: role)
          next false if a_prefix.blank? || b_prefix.blank?

          a_has = store.list_prefix(a_prefix, limit: 1).any?
          b_has = store.list_prefix(b_prefix, limit: 1).any?
          a_has && b_has
        else
          seg_prefix = segment_prefix_for(item, v, role: role)
          seg_prefix.present? && store.list_prefix(seg_prefix, limit: 1).any?
        end
      end
    rescue => e
      Rails.logger.warn("[media_gallery] HLS managed readiness check failed public_id=#{item&.public_id} backend=#{backend} error=#{e.class}: #{e.message}")
      false
    end

    def store_for_managed_role(item, role)
      return nil unless role.is_a?(Hash)

      profile_key = item.try(:managed_storage_profile).to_s.presence
      store = profile_key.present? ? ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key) : nil
      store ||= ::MediaGallery::StorageSettingsResolver.build_store(role["backend"].to_s)
      return nil if store.blank?
      return nil if role["backend"].to_s.present? && store.backend.to_s != role["backend"].to_s

      store
    rescue => e
      Rails.logger.warn("[media_gallery] HLS managed store resolve failed public_id=#{item&.public_id} backend=#{role['backend']} profile_key=#{profile_key} error=#{e.class}: #{e.message}")
      nil
    end

    def ready?(item)
      return false unless enabled?
      return false unless item&.public_id.present?

      role = managed_role_for(item)
      return true if managed_role_ready?(item, role)

      legacy_local_ready?(item)
    end

    def package_video!(item, input_path:, workspace: nil, aes128: nil)
      return nil unless enabled?
      return nil unless item&.media_type.to_s == "video"
      return nil if input_path.blank? || !File.exist?(input_path)

      variant = DEFAULT_VARIANT
      build_root, cleanup_after_publish = build_root_for_package(workspace: workspace)
      FileUtils.rm_rf(build_root) if build_root.present? && Dir.exist?(build_root)
      FileUtils.mkdir_p(build_root)

      aes128_packaging_enabled = aes128.nil? ? aes128_enabled? : ActiveModel::Type::Boolean.new.cast(aes128)
      aes128_material = nil
      aes128_keyinfo_file = nil
      if aes128_packaging_enabled
        aes128_material = ::MediaGallery::HlsAes128.generate_key_material(key_id: variant)
        aes128_files = ::MediaGallery::HlsAes128.write_key_files!(
          workspace_dir: File.join(build_root, ".aes128"),
          key_id: aes128_material["key_id"],
          key_bytes: aes128_material["key_bytes"],
          iv_hex: aes128_material["iv_hex"]
        )
        aes128_keyinfo_file = aes128_files[:keyinfo_path]
      end

      wm_profile = nil
      wm_layout = nil
      if fingerprinting_enabled?
        tmp_variant_dir = File.join(build_root, variant)
        FileUtils.mkdir_p(tmp_variant_dir)

        tmp_a_dir = File.join(build_root, "a", variant)
        tmp_b_dir = File.join(build_root, "b", variant)
        FileUtils.mkdir_p(tmp_a_dir)
        FileUtils.mkdir_p(tmp_b_dir)

        v_kbps = estimate_video_bitrate_kbps(item)
        wm_selection = MediaGallery::FingerprintWatermark.packaging_layout_selection
        wm_layout = wm_selection[:effective_layout].to_s
        wm_profile = MediaGallery::FingerprintWatermark.hls_packaging_profile(layout: wm_layout)

        if wm_selection[:auto_upgraded]
          Rails.logger.info(
            "[media_gallery] fingerprint packaging auto-upgraded legacy layout public_id=#{item.public_id} configured_layout=#{wm_selection[:configured_layout]} effective_layout=#{wm_layout}"
          )
        end

        vf_a = MediaGallery::FingerprintWatermark.vf_for(media_item_id: item.id, variant: "a", layout: wm_layout, profile: wm_profile)
        vf_b = MediaGallery::FingerprintWatermark.vf_for(media_item_id: item.id, variant: "b", layout: wm_layout, profile: wm_profile)

        MediaGallery::Ffmpeg.package_hls_ab_variants(
          input_path: input_path,
          output_dir_a: tmp_a_dir,
          output_dir_b: tmp_b_dir,
          segment_seconds: segment_duration_seconds,
          vf_a: vf_a,
          vf_b: vf_b,
          video_bitrate_kbps: v_kbps,
          audio_bitrate_kbps: SiteSetting.media_gallery_audio_bitrate_kbps.to_i,
          hls_key_info_file: aes128_keyinfo_file
        )

        a_pl = File.join(tmp_a_dir, "index.m3u8")
        tmp_variant_pl = File.join(tmp_variant_dir, "index.m3u8")
        raise "hls_ab_playlist_missing" unless File.exist?(a_pl)
        FileUtils.cp(a_pl, tmp_variant_pl)
      else
        tmp_variant_dir = File.join(build_root, variant)
        FileUtils.mkdir_p(tmp_variant_dir)

        MediaGallery::Ffmpeg.package_hls_single_variant(
          input_path: input_path,
          output_dir: tmp_variant_dir,
          segment_seconds: segment_duration_seconds,
          hls_key_info_file: aes128_keyinfo_file
        )
      end

      File.write(File.join(build_root, "master.m3u8"), master_playlist_content(item: item, variant: variant))
      File.write(File.join(build_root, ".complete"), Time.now.utc.iso8601)

      meta = {
        "ready" => true,
        "variant" => variant,
        "segment_duration_seconds" => segment_duration_seconds,
        "generated_at" => Time.now.utc.iso8601,
        "build_root" => build_root,
        "cleanup_build_root_after_publish" => cleanup_after_publish
      }

      if aes128_material.present?
        meta["encryption"] = ::MediaGallery::HlsAes128.public_metadata_for(aes128_material)
      end

      if fingerprinting_enabled?
        meta["ab_fingerprint"] = true
        meta["ab_layout"] = "hls/{a|b}/#{variant}/seg_XXXXX.ts"
        wm_spec = MediaGallery::FingerprintWatermark.spec_for(media_item_id: item.id, layout: wm_layout, profile: wm_profile)
        wm_layout = wm_spec[:layout].to_s
        codebook_scheme = ::MediaGallery::Fingerprinting.ecc_profile(layout: wm_layout)[:scheme]
        meta["watermark"] = {
          "type" => wm_layout,
          "configured_type" => wm_selection[:configured_layout].to_s.presence,
          "selection_reason" => wm_selection[:reason].to_s.presence,
          "legacy_layout_auto_upgraded" => !!wm_selection[:auto_upgraded],
          "profile" => wm_profile.to_s.presence,
          "opacity" => wm_spec[:opacity],
          "box_size_frac" => wm_spec[:box_size_frac],
          "margin" => wm_spec[:margin],
          "count" => (wm_spec[:pairs] || wm_spec[:tiles] || []).length,
          "sync_count" => Array(wm_spec[:sync_pairs]).length,
          "sync_period" => wm_spec[:sync_period],
          "codebook_scheme" => codebook_scheme,
        }

        begin
          serialized_wm_spec =
            begin
              if wm_spec.respond_to?(:deep_stringify_keys)
                JSON.parse(JSON.dump(wm_spec.deep_stringify_keys))
              else
                JSON.parse(JSON.dump(wm_spec))
              end
            rescue
              {
                "layout" => wm_layout,
                "kind" => wm_spec[:kind].to_s,
                "opacity" => wm_spec[:opacity],
                "box_size_frac" => wm_spec[:box_size_frac],
                "margin" => wm_spec[:margin],
                "pairs" => wm_spec[:pairs],
                "tiles" => wm_spec[:tiles],
                "sync_pairs" => wm_spec[:sync_pairs],
                "sync_pattern" => wm_spec[:sync_pattern],
                "sync_period" => wm_spec[:sync_period],
                "sync_opacity" => wm_spec[:sync_opacity],
                "sync_box_size_frac" => wm_spec[:sync_box_size_frac],
                "analysis" => wm_spec[:analysis],
              }
            end

          File.write(
            File.join(build_root, "fingerprint_meta.json"),
            JSON.pretty_generate({
              "layout" => wm_layout,
              "configured_layout" => wm_selection[:configured_layout].to_s.presence,
              "layout_selection_reason" => wm_selection[:reason].to_s.presence,
              "legacy_layout_auto_upgraded" => !!wm_selection[:auto_upgraded],
              "codebook_scheme" => codebook_scheme,
              "profile" => wm_profile.to_s.presence,
              "segment_seconds" => segment_duration_seconds,
              "watermark_spec" => serialized_wm_spec,
              "generated_at" => Time.now.utc.iso8601,
              "media_item_id" => item.id,
              "public_id" => item.public_id
            })
          )
          meta["fingerprint_meta_present"] = true
        rescue => e
          Rails.logger.warn("[media_gallery] failed to write fingerprint_meta.json public_id=#{item.public_id} error=#{e.class}: #{e.message}")
        end
      end

      validate_packaged_video!(build_root: build_root, variant: variant, ab_fingerprint: meta["ab_fingerprint"], aes128: aes128_material.present?)

      if aes128_material.present?
        ::MediaGallery::HlsAes128.store_key!(item: item, material: aes128_material, variant: variant)
      end

      meta
    rescue => e
      Rails.logger.warn("[media_gallery] HLS packaging failed public_id=#{item&.public_id} error=#{e.class}: #{e.message}")
      begin
        FileUtils.rm_rf(build_root) if build_root.present? && Dir.exist?(build_root)
      rescue
      end
      nil
    end

    # Publish the finalized scratch HLS package into the target managed store and
    # return the manifest role that playback should use.
    def publish_packaged_video!(item, store:, hls_meta:)
      raise "managed_store_unavailable" if store.blank?
      raise "hls_meta_missing" unless hls_meta.is_a?(Hash)

      packaged_root = packaged_root_for(item, hls_meta)
      raise "hls_packaged_root_missing" unless packaged_root.present? && Dir.exist?(packaged_root)

      store.ensure_available!

      each_packaged_file(packaged_root) do |abs_path, rel_path|
        key = File.join(item.public_id.to_s, "hls", rel_path)
        store.put_file!(
          abs_path,
          key: key,
          content_type: content_type_for_rel_path(rel_path),
          metadata: {
            "media_item_id" => item.id,
            "public_id" => item.public_id,
            "role" => "hls"
          }
        )
      end

      mirror_packaged_video_to_legacy_root!(item, packaged_root: packaged_root) if store.backend.to_s != "local"
      build_role_for_store(item, backend: store.backend, hls_meta: hls_meta, packaged_root: packaged_root)
    ensure
      cleanup_packaged_root!(hls_meta)
    end

    def master_key_for(item, role: nil)
      role ||= managed_role_for(item)
      return role["master_key"].to_s if role.is_a?(Hash) && role["master_key"].present?
      File.join(item.public_id.to_s, "hls", "master.m3u8")
    end

    def complete_key_for(item, role: nil)
      role ||= managed_role_for(item)
      return role["complete_key"].to_s if role.is_a?(Hash) && role["complete_key"].present?
      File.join(item.public_id.to_s, "hls", ".complete")
    end

    def fingerprint_meta_key_for(item, role: nil)
      role ||= managed_role_for(item)
      return role["fingerprint_meta_key"].to_s if role.is_a?(Hash) && role["fingerprint_meta_key"].present?
      File.join(item.public_id.to_s, "hls", "fingerprint_meta.json")
    end

    def fingerprint_meta_for(item, role: nil, store: nil)
      role ||= managed_role_for(item)
      if role.is_a?(Hash)
        key = fingerprint_meta_key_for(item, role: role)
        resolved_store = store || store_for_managed_role(item, role)
        if key.present? && resolved_store.present?
          raw = resolved_store.read(key)
          meta = JSON.parse(raw) rescue nil
          return meta.deep_stringify_keys if meta.is_a?(Hash)
        end
      end

      path = File.join(::MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id), "fingerprint_meta.json")
      return nil unless File.exist?(path)

      meta = JSON.parse(File.read(path)) rescue nil
      meta.is_a?(Hash) ? meta.deep_stringify_keys : nil
    rescue
      nil
    end

    def variant_playlist_key_for(item, variant, role: nil)
      role ||= managed_role_for(item)
      if role.is_a?(Hash) && role["variant_playlist_key_template"].present?
        return format_template(role["variant_playlist_key_template"], variant: variant)
      end
      File.join(item.public_id.to_s, "hls", variant.to_s, "index.m3u8")
    end

    def segment_key_for(item, variant, segment, ab: nil, role: nil)
      role ||= managed_role_for(item)
      if ab.present?
        if role.is_a?(Hash) && role["ab_segment_key_template"].present?
          return format_template(role["ab_segment_key_template"], variant: variant, segment: segment, ab: ab)
        end
        return File.join(item.public_id.to_s, "hls", ab.to_s, variant.to_s, segment.to_s)
      end

      if role.is_a?(Hash) && role["segment_key_template"].present?
        return format_template(role["segment_key_template"], variant: variant, segment: segment)
      end
      File.join(item.public_id.to_s, "hls", variant.to_s, segment.to_s)
    end

    def segment_prefix_for(item, variant, role: nil)
      key = segment_key_for(item, variant, "__probe__.ts", role: role)
      key.to_s.sub(%r{/__probe__\.ts\z}, "")
    end

    def ab_variant_prefix_for(item, variant, ab, role: nil)
      key = segment_key_for(item, variant, "__probe__.ts", ab: ab, role: role)
      key.to_s.sub(%r{/__probe__\.ts\z}, "")
    end

    def role_variants_for(role)
      arr = Array(role.is_a?(Hash) ? role["variants"] : nil).map(&:to_s).reject(&:blank?)
      arr.present? ? arr : variants
    end

    def role_uses_ab_layout?(role)
      return false unless role.is_a?(Hash)
      ActiveModel::Type::Boolean.new.cast(role["ab_fingerprint"]) || role["ab_segment_key_template"].present?
    rescue
      role["ab_fingerprint"].to_s == "true"
    end

    def content_type_for_rel_path(rel_path)
      case File.extname(rel_path.to_s).downcase
      when ".m3u8"
        "application/vnd.apple.mpegurl"
      when ".ts"
        "video/MP2T"
      when ".m4s"
        "video/iso.segment"
      when ".mp4"
        "video/mp4"
      when ".json"
        "application/json"
      else
        "application/octet-stream"
      end
    end

    def cleanup_build_artifacts!
      return unless MediaGallery::PrivateStorage.enabled?

      root = MediaGallery::PrivateStorage.private_root.to_s
      return if root.blank? || !Dir.exist?(root)

      ttl = SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
      keep_seconds = [ttl + 300, 30.minutes.to_i].max
      cutoff = Time.now - keep_seconds

      patterns = [
        File.join(root, "*", "hls__tmp_*"),
        File.join(root, "*", "hls__old_*"),
      ]

      patterns.each do |glob|
        Dir.glob(glob).each do |path|
          next unless File.directory?(path)

          begin
            m = File.mtime(path)
          rescue
            next
          end

          next if m > cutoff
          FileUtils.rm_rf(path)
        end
      end

      true
    rescue => e
      Rails.logger.warn("[media_gallery] HLS cleanup_build_artifacts failed: #{e.class}: #{e.message}")
      false
    end

    def estimate_video_bitrate_kbps(item)
      dur = item&.duration_seconds.to_f
      bytes = item&.filesize_processed_bytes.to_i
      return 5000 if dur <= 0 || bytes <= 0

      kbps = ((bytes * 8.0) / dur) / 1000.0
      kbps = kbps.round
      kbps = 800 if kbps < 800
      kbps = 12_000 if kbps > 12_000
      kbps
    rescue
      5000
    end

    def legacy_local_ready?(item)
      return false unless MediaGallery::PrivateStorage.enabled?

      master = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      complete = MediaGallery::PrivateStorage.hls_complete_abs_path(item.public_id)

      return false if master.blank? || complete.blank?
      return false unless File.exist?(master) && File.exist?(complete)

      variants.all? do |v|
        pl = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, v)
        next false if pl.blank? || !File.exist?(pl)

        vdir = MediaGallery::PrivateStorage.hls_variant_abs_dir(item.public_id, v)
        next false if vdir.blank? || !Dir.exist?(vdir)

        if fingerprinting_enabled?
          hls_root = MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
          a_dir = File.join(hls_root, "a", v.to_s)
          b_dir = File.join(hls_root, "b", v.to_s)

          next false unless a_dir.present? && b_dir.present?
          next false unless Dir.exist?(a_dir) && Dir.exist?(b_dir)

          a_has = Dir.glob(File.join(a_dir, "*.ts")).any? || Dir.glob(File.join(a_dir, "*.m4s")).any?
          b_has = Dir.glob(File.join(b_dir, "*.ts")).any? || Dir.glob(File.join(b_dir, "*.m4s")).any?
          a_has && b_has
        else
          Dir.glob(File.join(vdir, "*.ts")).any? || Dir.glob(File.join(vdir, "*.m4s")).any?
        end
      end
    end
    private_class_method :legacy_local_ready?

    def local_role_ready?(item, role)
      master = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      complete = MediaGallery::PrivateStorage.hls_complete_abs_path(item.public_id)
      return false unless File.exist?(master) && File.exist?(complete)

      role_variants_for(role).all? do |v|
        pl = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, v)
        next false unless File.exist?(pl)

        if role_uses_ab_layout?(role)
          a_dir = File.join(MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id), "a", v.to_s)
          b_dir = File.join(MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id), "b", v.to_s)
          next false unless Dir.exist?(a_dir) && Dir.exist?(b_dir)
          a_has = Dir.glob(File.join(a_dir, "*.ts")).any? || Dir.glob(File.join(a_dir, "*.m4s")).any?
          b_has = Dir.glob(File.join(b_dir, "*.ts")).any? || Dir.glob(File.join(b_dir, "*.m4s")).any?
          a_has && b_has
        else
          vdir = MediaGallery::PrivateStorage.hls_variant_abs_dir(item.public_id, v)
          Dir.exist?(vdir) && (Dir.glob(File.join(vdir, "*.ts")).any? || Dir.glob(File.join(vdir, "*.m4s")).any?)
        end
      end
    end
    private_class_method :local_role_ready?

    def each_packaged_file(final_root)
      Dir.glob(File.join(final_root, "**", "*"), File::FNM_DOTMATCH).sort.each do |abs_path|
        next if File.directory?(abs_path)
        rel_path = abs_path.sub(%r{\A#{Regexp.escape(final_root.to_s.chomp('/'))}/?}, "")
        next if rel_path.blank?
        next if rel_path.split(File::SEPARATOR).include?(".aes128")
        next if defined?(::MediaGallery::HlsAes128) && ::MediaGallery::HlsAes128.hls_key_artifact_rel_path?(rel_path)

        yield abs_path, rel_path
      end
    end
    private_class_method :each_packaged_file

    def build_role_for_store(item, backend:, hls_meta:, packaged_root: nil)
      key_prefix = File.join(item.public_id.to_s, "hls")
      role = {
        backend: backend.to_s,
        key_prefix: key_prefix,
        master_key: File.join(key_prefix, "master.m3u8"),
        complete_key: File.join(key_prefix, ".complete"),
        variant_playlist_key_template: File.join(key_prefix, "%{variant}", "index.m3u8"),
        segment_key_template: File.join(key_prefix, "%{variant}", "%{segment}"),
        variants: variants,
        ready: true,
        segment_duration_seconds: hls_meta["segment_duration_seconds"],
        generated_at: hls_meta["generated_at"]
      }

      encryption = sanitized_aes128_encryption_meta(hls_meta["encryption"])
      role[:encryption] = encryption if encryption.present?

      packaged_root ||= packaged_root_for(item, hls_meta)
      if packaged_root.present? && File.exist?(File.join(packaged_root, "fingerprint_meta.json"))
        role[:fingerprint_meta_key] = File.join(key_prefix, "fingerprint_meta.json")
      end

      if hls_meta["ab_fingerprint"]
        role[:ab_fingerprint] = true
        role[:ab_layout] = hls_meta["ab_layout"]
        role[:ab_segment_key_template] = File.join(key_prefix, "%{ab}", "%{variant}", "%{segment}")
      end

      role.deep_stringify_keys
    end
    private_class_method :build_role_for_store

    def sanitized_aes128_encryption_meta(encryption)
      return nil unless encryption.is_a?(Hash)

      encryption = encryption.deep_stringify_keys
      method = encryption["method"].to_s
      return nil unless method.casecmp("AES-128").zero?

      {
        "method" => "AES-128",
        "scheme" => encryption["scheme"].to_s.presence,
        "key_id" => encryption["key_id"].to_s.presence,
        "iv_hex" => encryption["iv_hex"].to_s.presence,
        "ready" => ActiveModel::Type::Boolean.new.cast(encryption["ready"]),
        "generated_at" => encryption["generated_at"].to_s.presence,
        "key_rotation_segments" => encryption["key_rotation_segments"].to_i,
      }.compact
    rescue
      nil
    end
    private_class_method :sanitized_aes128_encryption_meta

    def build_root_for_package(workspace: nil)
      if workspace.present?
        root =
          if workspace.respond_to?(:ensure_dir!)
            workspace.ensure_dir!("hls_build_#{SecureRandom.hex(6)}")
          elsif workspace.respond_to?(:root)
            File.join(workspace.root.to_s, "hls_build_#{SecureRandom.hex(6)}")
          end

        if root.present?
          FileUtils.mkdir_p(root)
          return [root, false]
        end
      end

      configured_root = ::MediaGallery::StorageSettingsResolver.processing_root_path
      if configured_root.present?
        FileUtils.mkdir_p(configured_root)
        return [Dir.mktmpdir("media-gallery-hls", configured_root), true]
      end

      [Dir.mktmpdir("media-gallery-hls"), true]
    end
    private_class_method :build_root_for_package

    def validate_packaged_video!(build_root:, variant:, ab_fingerprint: false, aes128: false)
      master_path = File.join(build_root, "master.m3u8")
      complete_path = File.join(build_root, ".complete")
      variant_playlist = File.join(build_root, variant.to_s, "index.m3u8")
      raise "hls_outputs_incomplete" unless File.exist?(master_path) && File.exist?(complete_path) && File.exist?(variant_playlist)

      if ab_fingerprint
        a_dir = File.join(build_root, "a", variant.to_s)
        b_dir = File.join(build_root, "b", variant.to_s)
        raise "hls_ab_segments_missing" unless hls_segments_present?(a_dir) && hls_segments_present?(b_dir)
      else
        variant_dir = File.join(build_root, variant.to_s)
        raise "hls_segments_missing" unless hls_segments_present?(variant_dir)
      end

      if aes128
        playlists = [variant_playlist]
        if ab_fingerprint
          playlists << File.join(build_root, "a", variant.to_s, "index.m3u8")
          playlists << File.join(build_root, "b", variant.to_s, "index.m3u8")
        end

        playlists.uniq.each do |playlist|
          raise "hls_aes128_playlist_missing" unless File.exist?(playlist)
          raise "hls_aes128_key_tag_missing" unless playlist_has_aes128_key_tag?(playlist)
        end
      end

      true
    end
    private_class_method :validate_packaged_video!

    def playlist_has_aes128_key_tag?(playlist_path)
      File.read(playlist_path).each_line.any? do |line|
        line.match?(/^#EXT-X-KEY:.*METHOD=AES-128/i) &&
          line.include?(::MediaGallery::HlsAes128.key_uri_placeholder(DEFAULT_VARIANT))
      end
    rescue
      false
    end
    private_class_method :playlist_has_aes128_key_tag?

    def hls_segments_present?(dir)
      return false unless dir.present? && Dir.exist?(dir)
      Dir.glob(File.join(dir, "*.ts")).any? || Dir.glob(File.join(dir, "*.m4s")).any?
    end
    private_class_method :hls_segments_present?

    def packaged_root_for(item, hls_meta)
      root = hls_meta["build_root"].to_s.presence
      return root if root.present? && Dir.exist?(root)
      MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
    end
    private_class_method :packaged_root_for

    def mirror_packaged_video_to_legacy_root!(item, packaged_root:)
      return false if packaged_root.blank? || !Dir.exist?(packaged_root)
      return false unless MediaGallery::PrivateStorage.enabled?

      item_root = MediaGallery::PrivateStorage.item_private_dir(item.public_id)
      final_root = MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
      MediaGallery::PrivateStorage.ensure_dir!(item_root)

      tmp_root = File.join(item_root, "hls__tmp_#{SecureRandom.hex(8)}")
      FileUtils.rm_rf(tmp_root) if Dir.exist?(tmp_root)
      FileUtils.mkdir_p(tmp_root)

      each_packaged_file(packaged_root) do |abs_path, rel_path|
        dest = File.join(tmp_root, rel_path)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(abs_path, dest)
      end

      swap_in_packaged_hls!(final_root: final_root, tmp_root: tmp_root, item_root: item_root)
      true
    rescue => e
      Rails.logger.warn("[media_gallery] failed to mirror packaged HLS to legacy root public_id=#{item&.public_id} error=#{e.class}: #{e.message}")
      false
    end
    private_class_method :mirror_packaged_video_to_legacy_root!

    def cleanup_packaged_root!(hls_meta)
      return unless hls_meta.is_a?(Hash)
      return unless ActiveModel::Type::Boolean.new.cast(hls_meta["cleanup_build_root_after_publish"])

      root = hls_meta["build_root"].to_s
      return if root.blank? || !Dir.exist?(root)

      FileUtils.rm_rf(root)
    rescue => e
      Rails.logger.warn("[media_gallery] failed to cleanup packaged HLS build root=#{root} error=#{e.class}: #{e.message}")
    end
    private_class_method :cleanup_packaged_root!

    def swap_in_packaged_hls!(final_root:, tmp_root:, item_root:)
      return if final_root.blank? || tmp_root.blank? || item_root.blank?

      old_root = nil
      if Dir.exist?(final_root)
        old_root = File.join(item_root, "hls__old_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}_#{SecureRandom.hex(4)}")
        FileUtils.mv(final_root, old_root)
      end

      FileUtils.mv(tmp_root, final_root)
      true
    rescue => e
      begin
        FileUtils.rm_rf(final_root) if final_root.present? && Dir.exist?(final_root)
        FileUtils.mv(old_root, final_root) if old_root.present? && Dir.exist?(old_root)
      rescue
      end
      raise e
    end
    private_class_method :swap_in_packaged_hls!

    def format_template(template, variant:, segment: nil, ab: nil)
      format(template.to_s, variant: variant.to_s, segment: segment.to_s, ab: ab.to_s)
    rescue KeyError
      template.to_s
    end
    private_class_method :format_template

    def master_playlist_content(item:, variant:)
      dur = item.duration_seconds.to_i
      bytes = item.filesize_processed_bytes.to_i
      bps = (dur > 0 && bytes > 0) ? ((bytes * 8) / dur) : 5_000_000
      bps = 500_000 if bps < 500_000

      w = item.width.to_i
      h = item.height.to_i
      res = (w > 0 && h > 0) ? "RESOLUTION=#{w}x#{h}," : ""

      <<~M3U
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:#{res}BANDWIDTH=#{bps},AVERAGE-BANDWIDTH=#{bps}
        #{variant}/index.m3u8
      M3U
    end
    private_class_method :master_playlist_content
  end
end
