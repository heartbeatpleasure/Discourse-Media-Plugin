# frozen_string_literal: true

module ::MediaGallery
  class AdminStorageController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/storage/profiles.json
    def profiles
      default_profile = ::MediaGallery::StorageSettingsResolver.profile_summary("active")
      profiles = ::MediaGallery::StorageSettingsResolver.configured_profiles_summary

      render_json_dump(
        active_profile: default_profile,
        default_profile: default_profile,
        default_target_profile_key: ::MediaGallery::StorageSettingsResolver.target_profile_key,
        target_profiles: profiles,
        profiles: profiles,
        security_review: ::MediaGallery::SecurityReview.global_review(profile: ::MediaGallery::StorageSettingsResolver.active_profile_key)
      )
    end

    # GET /admin/plugins/media-gallery/storage/health.json?profile=active|target|profile_key
    def health
      profile = params[:profile].to_s.presence || "active"
      render_json_dump(::MediaGallery::StorageHealth.health(profile: profile).merge(security_review: ::MediaGallery::SecurityReview.global_review(profile: profile)))
    end

    # POST /admin/plugins/media-gallery/storage/probe.json
    def probe
      profile = params[:profile].to_s.presence || "active"
      render_json_dump(::MediaGallery::StorageHealth.probe!(profile: profile).merge(security_review: ::MediaGallery::SecurityReview.global_review(profile: profile)))
    end
  end
end
