# frozen_string_literal: true

require "openssl"
require "securerandom"
require "digest/sha2"

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

      # Prefer the AR model when available, but fall back to a raw SQL upsert.
      # Why: in some deployments autoloading can be finicky during early boot/migrations;
      # we still want the fingerprint mapping to be persisted reliably.
      begin
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
      rescue NameError, ActiveRecord::StatementInvalid
        conn = ::ActiveRecord::Base.connection
        return fp unless conn.data_source_exists?("media_gallery_media_fingerprints")

        now = Time.now
        sql = <<~SQL
          INSERT INTO media_gallery_media_fingerprints
            (user_id, media_item_id, fingerprint_id, ip, last_seen_at, created_at, updated_at)
          VALUES
            ($1, $2, $3, $4, $5, $6, $6)
          ON CONFLICT (user_id, media_item_id)
          DO UPDATE SET
            fingerprint_id = EXCLUDED.fingerprint_id,
            ip = EXCLUDED.ip,
            last_seen_at = EXCLUDED.last_seen_at,
            updated_at = EXCLUDED.updated_at;
        SQL

        conn.exec_query(
          sql,
          "media_gallery_fingerprint_upsert",
          [
            [nil, user_id.to_i],
            [nil, media_item_id.to_i],
            [nil, fp.to_s],
            [nil, ip.to_s.presence],
            [nil, now],
            [nil, now]
          ]
        )
      end

      fp
    rescue => e
      Rails.logger.warn("[media_gallery] fingerprint touch failed user_id=#{user_id} media_item_id=#{media_item_id} error=#{e.class}: #{e.message}")
      fp
    end

    # Best-effort per-play session record. This is useful for investigations:
    # "who actually played this media and received which fingerprint_id".
    #
    # We intentionally store only a SHA256 of the token (not the raw token).
    def log_playback_session!(user_id:, media_item_id:, fingerprint_id:, token:, ip: nil, user_agent: nil)
      return if user_id.blank? || media_item_id.blank? || fingerprint_id.blank?

      token_sha256 =
        begin
          Digest::SHA256.hexdigest(token.to_s)
        rescue
          nil
        end

      MediaGallery::MediaPlaybackSession.create!(
        user_id: user_id.to_i,
        media_item_id: media_item_id.to_i,
        fingerprint_id: fingerprint_id.to_s,
        token_sha256: token_sha256,
        ip: ip.to_s.presence,
        user_agent: user_agent.to_s.presence,
        played_at: Time.now
      )
      true
    rescue => e
      Rails.logger.warn(
        "[media_gallery] playback session log failed user_id=#{user_id} media_item_id=#{media_item_id} error=#{e.class}: #{e.message}"
      )
      false
    end

  end
end
