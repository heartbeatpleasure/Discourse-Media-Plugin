# frozen_string_literal: true

require "set"

module ::MediaGallery
  module OrphanInspector
    module_function

    def preview_for_item(item, limit: 50)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key_for_item(item)
      backend = item.managed_storage_backend.to_s
      return unavailable_payload("profile_missing") if profile_key.blank? || backend.blank?

      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile_key(profile_key)
      return unavailable_payload("store_missing") if store.blank?

      store.ensure_available!
      prefix = item.public_id.to_s
      listed = Array(store.list_prefix(prefix, limit: limit + 1)).map(&:to_s)
      truncated = listed.length > limit
      actual_keys = truncated ? listed.first(limit) : listed

      expected_keys = Set.new(
        Array(::MediaGallery::MigrationPreview.objects_for_item(item, store: store)).map { |entry| entry[:key].to_s }.reject(&:blank?)
      )
      orphan_keys = actual_keys.reject { |key| expected_keys.include?(key) }

      {
        available: true,
        profile_key: profile_key,
        backend: backend,
        scanned_prefix: prefix,
        listed_count: actual_keys.length,
        candidate_count: orphan_keys.length,
        candidates: orphan_keys,
        truncated: truncated,
      }
    rescue => e
      unavailable_payload("scan_failed", detail: "#{e.class}: #{e.message}")
    end

    def unavailable_payload(reason, detail: nil)
      {
        available: false,
        reason: reason,
        detail: detail,
      }.compact
    end
    private_class_method :unavailable_payload
  end
end
