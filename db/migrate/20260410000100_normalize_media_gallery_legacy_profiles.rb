# frozen_string_literal: true

require "json"
require "time"

class NormalizeMediaGalleryLegacyProfiles < ActiveRecord::Migration[7.0]
  class MigrationMediaItem < ActiveRecord::Base
    self.table_name = "media_gallery_media_items"
  end

  PROFILE_KEY_MAP = {
    "active_local" => "local",
    "target_local" => "local",
    "active_s3" => "s3_1",
    "target_s3" => "s3_1",
    "target_s3_2" => "s3_2",
    "target_s3_3" => "s3_3",
  }.freeze

  PROFILE_KEY_FIELDS = %w[
    profile_key
    source_profile_key
    target_profile_key
    switched_profile_key
  ].freeze

  def up
    say_with_time("Normalizing legacy Media Gallery storage profiles") do
      require File.expand_path("../../lib/media_gallery/storage_settings_resolver", __dir__)
      require File.expand_path("../../lib/media_gallery/private_storage", __dir__)
      require File.expand_path("../../lib/media_gallery/asset_store", __dir__)
      require File.expand_path("../../lib/media_gallery/local_asset_store", __dir__)
      require File.expand_path("../../lib/media_gallery/s3_asset_store", __dir__)

      MigrationMediaItem.reset_column_information

      changed = 0
      MigrationMediaItem.find_in_batches(batch_size: 100) do |items|
        items.each do |item|
          changed += 1 if normalize_item!(item)
        end
      end
      changed
    end
  end

  def down
    # Irreversible normalization. Legacy profile keys are intentionally phased out.
  end

  private

  def normalize_item!(item)
    canonical_profile = canonical_profile_key_for_item(item)
    return false if canonical_profile.blank?

    canonical_backend = backend_for_profile_key(canonical_profile)
    return false if canonical_backend.blank?

    original_manifest = item.storage_manifest.is_a?(Hash) ? deep_dup_json(item.storage_manifest) : {}
    original_meta = item.extra_metadata.is_a?(Hash) ? deep_dup_json(item.extra_metadata) : {}

    store = build_store_for_profile(canonical_profile)
    manifest = normalize_manifest(item, manifest: original_manifest, backend: canonical_backend, store: store)
    meta = normalize_profile_keys_in_object(original_meta)

    changes = {}
    if item.managed_storage_profile.to_s != canonical_profile.to_s
      changes[:managed_storage_profile] = canonical_profile
    end

    if item.managed_storage_backend.to_s != canonical_backend.to_s
      changes[:managed_storage_backend] = canonical_backend
    end

    if manifest != original_manifest
      changes[:storage_manifest] = manifest
    end

    if meta != original_meta
      changes[:extra_metadata] = meta
    end

    return false if changes.empty?

    changes[:updated_at] = Time.now.utc if item.has_attribute?(:updated_at)
    item.update_columns(changes)
    true
  end

  def normalize_manifest(item, manifest:, backend:, store:)
    manifest_hash = manifest.is_a?(Hash) ? deep_dup_json(manifest) : {}
    manifest_hash["schema_version"] ||= 1
    manifest_hash["public_id"] ||= item.public_id.to_s
    manifest_hash["generated_at"] ||= Time.now.utc.iso8601

    roles = manifest_hash["roles"].is_a?(Hash) ? deep_dup_json(manifest_hash["roles"]) : {}

    normalized_main = normalize_single_role(
      existing_role: roles["main"],
      desired_role: desired_main_role(item, backend),
      backend: backend,
      store: store,
    )
    if normalized_main.present?
      roles["main"] = normalized_main
    else
      roles.delete("main")
    end

    normalized_thumbnail = normalize_single_role(
      existing_role: roles["thumbnail"],
      desired_role: desired_thumbnail_role(item, backend),
      backend: backend,
      store: store,
    )
    if normalized_thumbnail.present?
      roles["thumbnail"] = normalized_thumbnail
    else
      roles.delete("thumbnail")
    end

    normalized_hls = normalize_hls_role(item, existing_role: roles["hls"], backend: backend, store: store)
    if normalized_hls.present?
      roles["hls"] = normalized_hls
    else
      roles.delete("hls")
    end

    manifest_hash["roles"] = roles
    manifest_hash
  end

  def normalize_single_role(existing_role:, desired_role:, backend:, store:)
    existing = existing_role.is_a?(Hash) ? deep_stringify(existing_role) : nil
    desired = desired_role.is_a?(Hash) ? deep_stringify(desired_role) : nil
    return existing if role_canonical_for_backend?(existing, backend)
    return desired if desired.present? && role_exists_in_store?(desired, store)
    return desired if desired.present? && existing.present?

    existing
  end

  def normalize_hls_role(item, existing_role:, backend:, store:)
    existing = existing_role.is_a?(Hash) ? deep_stringify(existing_role) : nil
    return existing if role_canonical_for_backend?(existing, backend)

    return nil unless should_consider_hls_role?(item, existing, store)

    desired = desired_hls_role(item, backend, store)
    return desired if desired.present?

    nil
  end

  def desired_main_role(item, backend)
    {
      "backend" => backend.to_s,
      "key" => ::MediaGallery::PrivateStorage.processed_rel_path(item),
      "content_type" => inferred_main_content_type(item),
    }
  end

  def desired_thumbnail_role(item, backend)
    {
      "backend" => backend.to_s,
      "key" => ::MediaGallery::PrivateStorage.thumbnail_rel_path(item),
      "content_type" => "image/jpeg",
    }
  end

  def desired_hls_role(item, backend, store)
    prefix = File.join(item.public_id.to_s, "hls")
    keys = list_prefix_safe(store, prefix)
    return nil if keys.blank?

    variants = keys.filter_map do |key|
      key.match(%r{\A#{Regexp.escape(prefix)}/([^/]+)/index\.m3u8\z})&.captures&.first
    end.uniq.sort

    ab_variants = keys.filter_map do |key|
      key.match(%r{\A#{Regexp.escape(prefix)}/[ab]/([^/]+)/})&.captures&.first
    end.uniq.sort

    variants = (variants + ab_variants).uniq.sort
    variants = ["v0"] if variants.blank?

    role = {
      "backend" => backend.to_s,
      "key_prefix" => prefix,
      "master_key" => File.join(prefix, "master.m3u8"),
      "complete_key" => File.join(prefix, ".complete"),
      "variant_playlist_key_template" => File.join(prefix, "%{variant}", "index.m3u8"),
      "segment_key_template" => File.join(prefix, "%{variant}", "%{segment}"),
      "variants" => variants,
      "ready" => true,
    }

    if keys.include?(File.join(prefix, "fingerprint_meta.json"))
      role["fingerprint_meta_key"] = File.join(prefix, "fingerprint_meta.json")
    end

    if keys.any? { |key| key.start_with?(File.join(prefix, "a") + "/") } && keys.any? { |key| key.start_with?(File.join(prefix, "b") + "/") }
      role["ab_fingerprint"] = true
      role["ab_layout"] = "hls/{a|b}/%{variant}/%{segment}"
      role["ab_segment_key_template"] = File.join(prefix, "%{ab}", "%{variant}", "%{segment}")
    end

    hls_meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata["hls"] : nil
    if hls_meta.is_a?(Hash)
      role["segment_duration_seconds"] = hls_meta["segment_duration_seconds"] if hls_meta["segment_duration_seconds"].present?
      role["generated_at"] = hls_meta["generated_at"] if hls_meta["generated_at"].present?
      if hls_meta["ab_fingerprint"] && role["ab_fingerprint"].blank?
        role["ab_fingerprint"] = true
        role["ab_layout"] = hls_meta["ab_layout"].presence || "hls/{a|b}/%{variant}/%{segment}"
        role["ab_segment_key_template"] ||= File.join(prefix, "%{ab}", "%{variant}", "%{segment}")
      end
    end

    role
  end

  def role_canonical_for_backend?(role, backend)
    return false unless role.is_a?(Hash)

    role_backend = role["backend"].to_s
    return false if role_backend.blank?
    return false if role["legacy"]

    role_backend == backend.to_s
  end

  def role_exists_in_store?(role, store)
    return false unless role.is_a?(Hash)
    return false if store.blank?

    backend = role["backend"].to_s
    return false if backend.present? && backend != store.backend.to_s

    if role["key_prefix"].present?
      list_prefix_safe(store, role["key_prefix"].to_s).present?
    elsif role["key"].present?
      store.exists?(role["key"].to_s)
    else
      false
    end
  rescue
    false
  end

  def should_consider_hls_role?(item, existing_role, store)
    return true if existing_role.present?

    hls_meta = item.extra_metadata.is_a?(Hash) ? item.extra_metadata["hls"] : nil
    return true if hls_meta.is_a?(Hash) && hls_meta.present?
    return false unless item.media_type.to_s == "video"

    prefix = File.join(item.public_id.to_s, "hls")
    list_prefix_safe(store, prefix, limit: 1).present?
  end

  def list_prefix_safe(store, prefix, limit: nil)
    return [] if store.blank? || prefix.to_s.blank?

    Array(store.list_prefix(prefix, limit: limit)).compact.map(&:to_s).uniq.sort
  rescue
    []
  end

  def canonical_profile_key_for_item(item)
    stored = item.managed_storage_profile.to_s.strip
    canonical = canonical_profile_key(stored)
    return canonical if canonical.present?

    backend = item.managed_storage_backend.to_s.strip
    return "s3_1" if backend == "s3"
    return "local" if backend == "local"

    roles = item.storage_manifest.is_a?(Hash) ? item.storage_manifest["roles"] : nil
    if roles.is_a?(Hash)
      backends = roles.values.select { |value| value.is_a?(Hash) }.map { |value| value["backend"].to_s }.uniq
      return "s3_1" if backends.include?("s3")
      return "local" if backends.include?("local")
    end

    nil
  end

  def canonical_profile_key(value)
    key = value.to_s.strip
    return key if %w[local s3_1 s3_2 s3_3].include?(key)

    PROFILE_KEY_MAP[key]
  end

  def backend_for_profile_key(profile_key)
    case profile_key.to_s
    when "local"
      "local"
    when "s3_1", "s3_2", "s3_3"
      "s3"
    else
      nil
    end
  end

  def build_store_for_profile(profile_key)
    ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
  rescue
    nil
  end

  def normalize_profile_keys_in_object(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), acc|
        string_key = key.to_s
        normalized_child = normalize_profile_keys_in_object(child)
        if PROFILE_KEY_FIELDS.include?(string_key)
          acc[string_key] = canonical_profile_key(normalized_child) || normalized_child
        else
          acc[string_key] = normalized_child
        end
      end
    when Array
      value.map { |entry| normalize_profile_keys_in_object(entry) }
    else
      value
    end
  end

  def inferred_main_content_type(item)
    case item.media_type.to_s
    when "video" then "video/mp4"
    when "audio" then "audio/mpeg"
    when "image" then "image/jpeg"
    else "application/octet-stream"
    end
  end

  def deep_dup_json(value)
    JSON.parse(value.to_json)
  end

  def deep_stringify(value)
    JSON.parse(value.to_json)
  end
end
