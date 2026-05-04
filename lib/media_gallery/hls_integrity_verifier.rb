# frozen_string_literal: true

module ::MediaGallery
  module HlsIntegrityVerifier
    module_function

    MAX_SEGMENTS_CHECKED = 50

    def verify(item)
      raise "media_item_required" if item.blank?
      role = ::MediaGallery::AssetManifest.role_for(item, "hls")
      return result(item, status: "not_applicable", checks: [check("ok", "hls_role_absent", "No HLS role is present for this item.")]) if role.blank?

      role = role.deep_stringify_keys
      store = store_for(item, role)
      checks = []

      master_key = role["master_key"].presence || key_join(role["key_prefix"], "master.m3u8")
      checks << object_check(store, key: master_key, label: "Master playlist", required: true)

      variants = Array(role["variants"]).map(&:to_s).reject(&:blank?)
      variants = ["v0"] if variants.blank?
      variant_playlists = []

      variants.each do |variant|
        key = template_key(role["variant_playlist_key_template"], variant: variant) || key_join(role["key_prefix"], variant, "index.m3u8")
        row = object_check(store, key: key, label: "Variant playlist #{variant}", required: true)
        checks << row
        variant_playlists << [variant, key] if row[:status] == "ok"
      end

      segment_checks = []
      variant_playlists.each do |variant, key|
        raw = read_object(store, key)
        segments = parse_playlist_segments(raw)
        checks << check(segments.present? ? "ok" : "warning", "hls_variant_segments_#{variant}", segments.present? ? "Variant #{variant} references #{segments.length} segment(s)." : "Variant #{variant} does not reference media segments.")
        segments.first(MAX_SEGMENTS_CHECKED).each do |seg|
          segment_keys_for(role, variant: variant, segment: seg).each do |entry|
            segment_checks << object_check(store, key: entry[:key], label: entry[:label], required: true)
          end
        end
      rescue => e
        checks << check("warning", "hls_variant_parse_failed_#{variant}", "Variant #{variant} could not be parsed.", "#{e.class}: #{e.message}".truncate(300))
      end
      checks.concat(segment_checks)

      if role["fingerprint_meta_key"].present?
        checks << object_check(store, key: role["fingerprint_meta_key"], label: "Fingerprint metadata", required: true)
      end
      if role["complete_key"].present?
        checks << object_check(store, key: role["complete_key"], label: "HLS complete marker", required: false)
      end

      missing_required = checks.count { |c| c[:required] && c[:status] != "ok" }
      warnings = checks.count { |c| c[:status] == "warning" }
      status = missing_required.positive? ? "critical" : (warnings.positive? ? "warning" : "ok")
      result(item, status: status, checks: checks, role: role, checked_segments: segment_checks.length, segment_sample_limit: MAX_SEGMENTS_CHECKED)
    end

    def result(item, status:, checks:, role: nil, checked_segments: 0, segment_sample_limit: MAX_SEGMENTS_CHECKED)
      {
        ok: status == "ok" || status == "not_applicable",
        status: status,
        public_id: item.public_id,
        media_item_id: item.id,
        checked_at: Time.now.utc.iso8601,
        checked_segments: checked_segments,
        segment_sample_limit: segment_sample_limit,
        role_backend: role&.dig("backend"),
        key_prefix: role&.dig("key_prefix"),
        checks: checks,
        summary: summary_for(status, checks),
      }
    end

    def summary_for(status, checks)
      case status
      when "ok" then "HLS playlists and sampled objects were found."
      when "not_applicable" then "This item does not have an HLS role."
      when "warning" then "HLS integrity check completed with warnings."
      else "HLS integrity check found missing required objects."
      end
    end
    private_class_method :summary_for

    def object_check(store, key:, label:, required: true)
      ok = key.present? && store.present? && store.exists?(key)
      check(ok ? "ok" : (required ? "critical" : "warning"), "hls_object", ok ? "#{label} exists." : "#{label} is missing.", key.to_s, required: required, key: key)
    rescue => e
      check(required ? "critical" : "warning", "hls_object_error", "#{label} could not be checked.", "#{e.class}: #{e.message}".truncate(300), required: required, key: key)
    end
    private_class_method :object_check

    def store_for(item, role)
      backend = role["backend"].presence || item.managed_storage_backend
      profile = role["profile"].presence || item.managed_storage_profile.presence || ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      if backend.to_s == "local" || backend.to_s == "s3"
        ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile)
      else
        nil
      end
    end
    private_class_method :store_for

    def read_object(store, key)
      store.read(key).to_s
    end
    private_class_method :read_object

    def parse_playlist_segments(raw)
      raw.to_s.lines.map(&:strip).reject(&:blank?).reject { |line| line.start_with?("#") }.map { |line| line.split("?").first.split("#").first }.map { |path| File.basename(path) }.reject(&:blank?)
    end
    private_class_method :parse_playlist_segments

    def segment_keys_for(role, variant:, segment:)
      if role["ab_segment_key_template"].present? || ActiveModel::Type::Boolean.new.cast(role["ab_fingerprint"])
        return %w[a b].map do |ab|
          { key: template_key(role["ab_segment_key_template"], variant: variant, segment: segment, ab: ab) || key_join(role["key_prefix"], ab, variant, segment), label: "Segment #{ab}/#{variant}/#{segment}" }
        end
      end

      key = if role["segment_key_template"].present?
        template_key(role["segment_key_template"], variant: variant, segment: segment)
      else
        key_join(role["key_prefix"], variant, segment)
      end
      [{ key: key, label: "Segment #{variant}/#{segment}" }]
    end
    private_class_method :segment_keys_for

    def template_key(template, variant: nil, segment: nil, ab: nil)
      return nil if template.blank?
      template.to_s.gsub("%{variant}", variant.to_s).gsub("%{segment}", segment.to_s).gsub("%{ab}", ab.to_s)
    end
    private_class_method :template_key

    def key_join(*parts)
      parts.flatten.compact.map(&:to_s).reject(&:blank?).join("/").gsub(%r{/+}, "/").sub(%r{\A/}, "")
    end
    private_class_method :key_join

    def check(status, code, message, detail = nil, extra = {})
      { status: status.to_s, code: code.to_s, message: message.to_s, detail: detail.to_s.presence }.merge(extra).compact
    end
    private_class_method :check
  end
end
