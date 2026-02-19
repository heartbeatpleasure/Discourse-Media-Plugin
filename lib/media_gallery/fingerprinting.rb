# frozen_string_literal: true

require "openssl"
require "securerandom"

module ::MediaGallery
  # Segment-level A/B fingerprinting (forensic watermark scaffolding).
  #
  # Milestone (this patch):
  # - Deterministic fingerprint_id per (user_id, media_item_id) using a secret.
  # - Per-segment expected A/B bit derived from fingerprint_id + segment index.
  # - HLS playlists are assembled per user (token), pointing to /seg/.../a|b/...
  #
  # Note:
  # - This does NOT change the media bytes yet (A and B may still point to the same file).
  # - Next milestone: generate real A/B segment media so the pattern is detectable in leaked copies.
  module Fingerprinting
    module_function

    SALT = "media_gallery_fingerprint_v1"

    def enabled?
      SiteSetting.respond_to?(:media_gallery_fingerprint_enabled) && SiteSetting.media_gallery_fingerprint_enabled
    end

    # Admin-provided secret. If empty, fallback to Rails secret_key_base.
    def secret
      s =
        if SiteSetting.respond_to?(:media_gallery_fingerprint_secret)
          SiteSetting.media_gallery_fingerprint_secret.to_s
        else
          ""
        end

      s = s.strip
      s = Rails.application.secret_key_base.to_s if s.blank?
      s
    end

    # Stable id per (user, media_item). This prevents users from "re-rolling" their pattern
    # by requesting multiple play tokens.
    def fingerprint_id_for(user_id:, media_item_id:)
      msg = "#{SALT}|u#{user_id}|m#{media_item_id}"
      OpenSSL::HMAC.hexdigest("SHA256", secret, msg)[0, 32]
    end

    # Returns "a" or "b" for the given segment index (0-based).
    def expected_variant_for_segment(fingerprint_id:, media_item_id:, segment_index:)
      idx = segment_index.to_i
      idx = 0 if idx.negative?
      msg = "#{SALT}|fp=#{fingerprint_id}|m=#{media_item_id}|s=#{idx}"
      byte0 = OpenSSL::HMAC.digest("SHA256", secret, msg).getbyte(0)
      (byte0 & 1) == 1 ? "b" : "a"
    rescue
      "a"
    end

    # Parses a segment index from our ffmpeg naming convention: seg_00012.ts
    # Returns integer or nil when unknown.
    def segment_index_from_filename(filename)
      f = File.basename(filename.to_s)
      m = f.match(/\Aseg_(\d+)\.(ts|m4s)\z/i)
      return nil if m.blank?
      m[1].to_i
    end

    # Best-effort persistence so later forensics can search the set of users who actually played.
    # Upserts by (user_id, media_item_id).
    def touch_fingerprint_record!(user_id:, media_item_id:, ip: nil)
      return if user_id.blank? || media_item_id.blank?

      fp = fingerprint_id_for(user_id: user_id, media_item_id: media_item_id)

      rec = MediaGallery::MediaFingerprint.find_by(user_id: user_id.to_i, media_item_id: media_item_id.to_i)
      if rec
        rec.update_columns(fingerprint_id: fp, ip: ip.to_s.presence, last_seen_at: Time.now)
      else
        MediaGallery::MediaFingerprint.create!(
          user_id: user_id.to_i,
          media_item_id: media_item_id.to_i,
          fingerprint_id: fp,
          ip: ip.to_s.presence,
          last_seen_at: Time.now
        )
      end

      fp
    rescue => e
      Rails.logger.warn("[media_gallery] fingerprint touch failed user_id=#{user_id} media_item_id=#{media_item_id} error=#{e.class}: #{e.message}")
      fingerprint_id_for(user_id: user_id, media_item_id: media_item_id)
    end
  end
end
