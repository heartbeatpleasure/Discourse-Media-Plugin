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

    CODEBOOK_REPEAT_INTERLEAVE_V1 = "repeat_interleave_v1"
    CODEBOOK_LOCAL_WINDOW_V2 = "local_window_codelets_v2"

    ECC_LOGICAL_BITS = 16
    ECC_REPEAT = 4
    ECC_BLOCK_SPAN = ECC_LOGICAL_BITS * ECC_REPEAT

    LOCAL_V2_LOGICAL_BITS = 24
    LOCAL_V2_REPEAT = 3
    LOCAL_V2_BLOCK_SPAN = LOCAL_V2_LOGICAL_BITS * LOCAL_V2_REPEAT
    LOCAL_V2_CODELETS = %w[
      ababba
      baabab
      abbaba
      baabba
      aabbab
      bbaaba
      abbaab
      babbaa
    ].freeze

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


    def current_thread_codebook_scheme
      Thread.current[:media_gallery_fingerprint_codebook_scheme].to_s.presence
    rescue
      nil
    end

    def with_codebook_scheme(codebook)
      previous = Thread.current[:media_gallery_fingerprint_codebook_scheme]
      Thread.current[:media_gallery_fingerprint_codebook_scheme] = codebook.to_s.presence
      yield
    ensure
      Thread.current[:media_gallery_fingerprint_codebook_scheme] = previous
    end


    def current_expected_variant_cache
      Thread.current[:media_gallery_expected_variant_cache]
    rescue
      nil
    end

    def with_expected_variant_cache
      previous = Thread.current[:media_gallery_expected_variant_cache]
      Thread.current[:media_gallery_expected_variant_cache] = previous || {}
      yield
    ensure
      Thread.current[:media_gallery_expected_variant_cache] = previous
    end

    def codebook_scheme_for(layout: nil, codebook: nil)
      explicit = codebook.to_s.presence
      return explicit if explicit.present?

      threaded = current_thread_codebook_scheme
      return threaded if threaded.present?

      case layout.to_s
      when "v6_local_sync", "v7_high_separation", "v8_microgrid"
        CODEBOOK_LOCAL_WINDOW_V2
      else
        CODEBOOK_REPEAT_INTERLEAVE_V1
      end
    rescue
      CODEBOOK_REPEAT_INTERLEAVE_V1
    end


    def ecc_profile(codebook: nil, layout: nil)
      scheme = codebook_scheme_for(codebook: codebook, layout: layout)

      if scheme.to_s == CODEBOOK_LOCAL_WINDOW_V2
        {
          logical_bits: LOCAL_V2_LOGICAL_BITS,
          repeat: LOCAL_V2_REPEAT,
          block_span: LOCAL_V2_BLOCK_SPAN,
          scheme: CODEBOOK_LOCAL_WINDOW_V2
        }
      else
        {
          logical_bits: ECC_LOGICAL_BITS,
          repeat: ECC_REPEAT,
          block_span: ECC_BLOCK_SPAN,
          scheme: CODEBOOK_REPEAT_INTERLEAVE_V1
        }
      end
    rescue
      {
        logical_bits: ECC_LOGICAL_BITS,
        repeat: ECC_REPEAT,
        block_span: ECC_BLOCK_SPAN,
        scheme: CODEBOOK_REPEAT_INTERLEAVE_V1
      }
    end

    def logical_slot_for_segment(segment_index:, codebook: nil, layout: nil)
      idx = segment_index.to_i
      idx = 0 if idx.negative?

      profile = ecc_profile(codebook: codebook, layout: layout)
      block_span = [profile[:block_span].to_i, 1].max
      logical_bits = [profile[:logical_bits].to_i, 1].max

      {
        block_index: idx / block_span,
        logical_index: idx % logical_bits,
        block_span: block_span,
        repeat: [profile[:repeat].to_i, 1].max,
        logical_bits: logical_bits,
        scheme: profile[:scheme].to_s
      }
    rescue
      {
        block_index: 0,
        logical_index: 0,
        block_span: ECC_BLOCK_SPAN,
        repeat: ECC_REPEAT,
        logical_bits: ECC_LOGICAL_BITS,
        scheme: CODEBOOK_REPEAT_INTERLEAVE_V1
      }
    end

    def v2_local_codelet_sequence(fingerprint_id:, media_item_id:, block_index:)
      cache = current_expected_variant_cache
      cache_key = [:v2_codelet, fingerprint_id.to_s, media_item_id.to_i, block_index.to_i]
      return cache[cache_key] if cache && cache.key?(cache_key)

      msg = "#{SALT}|fp=#{fingerprint_id}|m=#{media_item_id}|b=#{block_index}|codelets=v2"
      digest = OpenSSL::HMAC.digest("SHA256", secret, msg)
      slots = (LOCAL_V2_LOGICAL_BITS.to_f / 6.0).ceil
      seq = +""

      slots.times do |i|
        byte = digest.getbyte(i % digest.bytesize).to_i
        seq << LOCAL_V2_CODELETS[byte % LOCAL_V2_CODELETS.length]
      end

      result = seq[0, LOCAL_V2_LOGICAL_BITS]
      cache[cache_key] = result if cache
      result
    rescue
      ("ab" * (LOCAL_V2_LOGICAL_BITS / 2 + 1))[0, LOCAL_V2_LOGICAL_BITS]
    end

    def expected_logical_variant(fingerprint_id:, media_item_id:, block_index:, logical_index:, codebook: nil, layout: nil)
      profile = ecc_profile(codebook: codebook, layout: layout)
      block = block_index.to_i
      block = 0 if block.negative?
      logical = logical_index.to_i
      logical = 0 if logical.negative?
      logical %= [profile[:logical_bits].to_i, 1].max

      if profile[:scheme].to_s == CODEBOOK_LOCAL_WINDOW_V2
        v2_local_codelet_sequence(
          fingerprint_id: fingerprint_id,
          media_item_id: media_item_id,
          block_index: block
        )[logical].to_s == "b" ? "b" : "a"
      else
        msg = "#{SALT}|fp=#{fingerprint_id}|m=#{media_item_id}|b=#{block}|l=#{logical}"
        byte0 = OpenSSL::HMAC.digest("SHA256", secret, msg).getbyte(0)
        (byte0 & 1) == 1 ? "b" : "a"
      end
    rescue
      "a"
    end

    # Returns "a" or "b" for the given segment index (0-based).
    #
    # We intentionally use a small repeated/interleaved code block here instead of
    # independent per-segment bits. This acts as lightweight ECC: short leaks often
    # contain multiple observations of the same logical bit, allowing the matcher to
    # majority-vote away isolated bit flips from screen recordings.
    def expected_variant_for_segment(fingerprint_id:, media_item_id:, segment_index:, codebook: nil, layout: nil)
      scheme = codebook_scheme_for(codebook: codebook, layout: layout)
      cache = current_expected_variant_cache
      cache_key = [:expected_variant, fingerprint_id.to_s, media_item_id.to_i, segment_index.to_i, scheme.to_s]
      return cache[cache_key] if cache && cache.key?(cache_key)

      slot = logical_slot_for_segment(segment_index: segment_index, codebook: scheme, layout: layout)
      result = expected_logical_variant(
        fingerprint_id: fingerprint_id,
        media_item_id: media_item_id,
        block_index: slot[:block_index],
        logical_index: slot[:logical_index],
        codebook: scheme,
        layout: layout
      )
      cache[cache_key] = result if cache
      result
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
