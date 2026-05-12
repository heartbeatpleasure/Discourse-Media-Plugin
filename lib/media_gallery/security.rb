# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

# Best-effort playback hardening helpers.
#
# Notes:
# - Without DRM it's impossible to fully prevent downloading.
# - These controls aim to reduce casual abuse:
#   * early token revocation on overlay close/ended
#   * concurrent session limits using a lightweight client heartbeat
#   * active token limits (per user / per IP)

module ::MediaGallery
  module Security
    module_function

    def redis
      Discourse.redis
    end

    # -----------------
    # Settings helpers
    # -----------------

    def revoke_enabled?
      !!SiteSetting.media_gallery_revoke_enabled
    end

    def heartbeat_enabled?
      !!SiteSetting.media_gallery_heartbeat_enabled
    end

    def heartbeat_interval_seconds
      v = SiteSetting.media_gallery_heartbeat_interval_seconds.to_i
      v = 15 if v <= 0
      v
    end

    def heartbeat_ttl_seconds
      v = SiteSetting.media_gallery_heartbeat_ttl_seconds.to_i
      # Ensure TTL is always > interval so the session doesn't flap.
      min = heartbeat_interval_seconds + 10
      v = min if v < min
      v
    end

    def max_concurrent_sessions_per_user
      SiteSetting.media_gallery_max_concurrent_sessions_per_user.to_i
    end

    def max_concurrent_sessions_per_ip
      SiteSetting.media_gallery_max_concurrent_sessions_per_ip.to_i
    end

    def max_active_tokens_per_user
      SiteSetting.media_gallery_max_active_tokens_per_user.to_i
    end

    def max_active_tokens_per_ip
      SiteSetting.media_gallery_max_active_tokens_per_ip.to_i
    end

    def hls_playback_sessions_enabled?
      SiteSetting.respond_to?(:media_gallery_hls_playback_sessions_enabled) && SiteSetting.media_gallery_hls_playback_sessions_enabled
    rescue
      false
    end

    def hls_manifest_receipt_logging_enabled?
      SiteSetting.respond_to?(:media_gallery_hls_manifest_receipt_logging_enabled) && SiteSetting.media_gallery_hls_manifest_receipt_logging_enabled
    rescue
      false
    end

    def hls_manifest_receipt_required?
      SiteSetting.respond_to?(:media_gallery_hls_manifest_receipt_required) && SiteSetting.media_gallery_hls_manifest_receipt_required
    rescue
      false
    end

    def hls_recent_heartbeat_logging_enabled?
      SiteSetting.respond_to?(:media_gallery_hls_recent_heartbeat_logging_enabled) && SiteSetting.media_gallery_hls_recent_heartbeat_logging_enabled
    rescue
      false
    end

    def hls_recent_heartbeat_required?
      SiteSetting.respond_to?(:media_gallery_hls_recent_heartbeat_required) && SiteSetting.media_gallery_hls_recent_heartbeat_required
    rescue
      false
    end

    def hls_recent_heartbeat_grace_seconds
      v = SiteSetting.respond_to?(:media_gallery_hls_recent_heartbeat_grace_seconds) ? SiteSetting.media_gallery_hls_recent_heartbeat_grace_seconds.to_i : 120
      v = 120 if v <= 0
      [[v, 30].max, 900].min
    rescue
      120
    end

    # -----------------
    # Redis keys
    # -----------------

    TOKEN_KEY_PREFIX = "media_gallery:token:sha256:"
    REVOKED_KEY_PREFIX = "media_gallery:revoked:sha256:"
    SESSION_KEY_PREFIX = "media_gallery:session:sha256:"
    HLS_PLAYBACK_SESSION_KEY_PREFIX = "media_gallery:hls:playback_session:sha256:"

    def token_sha256(token)
      value = token.to_s
      return nil if value.blank?

      Digest::SHA256.hexdigest(value)
    rescue
      nil
    end

    def token_sha256_label(token)
      digest = token_sha256(token)
      digest.present? ? "sha256:#{digest}" : nil
    end

    def token_key(token)
      digest = token_sha256(token)
      digest.present? ? "#{TOKEN_KEY_PREFIX}#{digest}" : nil
    end

    def revoked_key(token)
      digest = token_sha256(token)
      digest.present? ? "#{REVOKED_KEY_PREFIX}#{digest}" : nil
    end

    def session_key(token)
      digest = token_sha256(token)
      digest.present? ? "#{SESSION_KEY_PREFIX}#{digest}" : nil
    end

    def new_hls_playback_session_id
      "v1:#{SecureRandom.hex(16)}"
    end

    def hls_playback_session_key(session_id)
      value = session_id.to_s
      return nil if value.blank?

      "#{HLS_PLAYBACK_SESSION_KEY_PREFIX}#{Digest::SHA256.hexdigest(value)}"
    rescue
      nil
    end

    def legacy_raw_token_tracking_key?(value)
      text = value.to_s
      return false if text.blank?
      return false if text.include?(":sha256:")

      text.start_with?("media_gallery:token:", "media_gallery:session:")
    rescue
      false
    end

    def user_tokens_set(user_id)
      "media_gallery:tokens:u#{user_id}"
    end

    def ip_tokens_set(ip)
      "media_gallery:tokens:ip:#{ip}"
    end

    def user_sessions_set(user_id)
      "media_gallery:sessions:u#{user_id}"
    end

    def ip_sessions_set(ip)
      "media_gallery:sessions:ip:#{ip}"
    end

    # -----------------
    # Utility
    # -----------------

    def prune_set_members!(set_key)
      members = redis.smembers(set_key)
      return 0 if members.blank?

      # Remove members whose referenced key expired. Legacy pre-part-3 set members
      # contained raw bearer tokens inside Redis key names; drop them from the
      # aggregate sets instead of keeping them visible in active-count tracking.
      members.each do |member_key|
        if legacy_raw_token_tracking_key?(member_key)
          redis.srem(set_key, member_key)
          next
        end

        next if member_key.present? && redis.exists?(member_key)
        redis.srem(set_key, member_key)
      end

      redis.scard(set_key).to_i
    end

    def set_best_effort_expiry!(key, seconds)
      seconds = seconds.to_i
      return if seconds <= 0
      # Some installs may have long-running redis instances; keep ancillary sets bounded.
      redis.expire(key, seconds)
    rescue
      # ignore
    end

    # -----------------
    # Token tracking
    # -----------------

    def track_token!(token:, exp:, user_id:, ip:)
      return if token.blank?

      ttl = exp.to_i - Time.now.to_i
      ttl = 1 if ttl <= 0

      tk = token_key(token)
      return if tk.blank?

      redis.setex(tk, ttl, exp.to_i)

      if user_id.present?
        ut = user_tokens_set(user_id)
        redis.sadd(ut, tk)
        set_best_effort_expiry!(ut, ttl + 600)
      end

      if ip.present?
        it = ip_tokens_set(ip)
        redis.sadd(it, tk)
        set_best_effort_expiry!(it, ttl + 600)
      end
    end

    def active_tokens_count(user_id:, ip:)
      u = user_id.present? ? prune_set_members!(user_tokens_set(user_id)) : 0
      i = ip.present? ? prune_set_members!(ip_tokens_set(ip)) : 0
      [u, i]
    end

    # -----------------
    # Session tracking (heartbeat)
    # -----------------

    def open_or_touch_session!(token:, user_id:, ip:)
      return if token.blank?

      sk = session_key(token)
      return if sk.blank?

      ttl = heartbeat_ttl_seconds

      # Store a small payload for debugging.
      begin
        redis.setex(sk, ttl, "u=#{user_id}|ip=#{ip}")
      rescue
        redis.setex(sk, ttl, "1")
      end

      if user_id.present?
        us = user_sessions_set(user_id)
        redis.sadd(us, sk)
        set_best_effort_expiry!(us, ttl + 600)
      end

      if ip.present?
        is = ip_sessions_set(ip)
        redis.sadd(is, sk)
        set_best_effort_expiry!(is, ttl + 600)
      end
    end

    def active_sessions_count(user_id:, ip:)
      u = user_id.present? ? prune_set_members!(user_sessions_set(user_id)) : 0
      i = ip.present? ? prune_set_members!(ip_sessions_set(ip)) : 0
      [u, i]
    end

    # -----------------
    # HLS server-side playback sessions
    # -----------------

    def open_hls_playback_session!(session_id:, token:, exp:, user_id:, media_item_id:, ip:, user_agent: nil, fingerprint_id: nil)
      return true unless hls_playback_sessions_enabled?
      return false if session_id.blank? || token.blank? || media_item_id.blank?

      ttl = exp.to_i - Time.now.to_i
      ttl = 1 if ttl <= 0

      key = hls_playback_session_key(session_id)
      return false if key.blank?

      now = Time.now.utc.iso8601
      payload = {
        "version" => 1,
        "playback_session_id" => session_id.to_s,
        "token_sha256" => token_sha256(token),
        "user_id" => user_id.to_i,
        "media_item_id" => media_item_id.to_i,
        "kind" => "hls",
        "ip" => ip.to_s.presence,
        "user_agent" => user_agent.to_s.presence,
        "fingerprint_id" => fingerprint_id.to_s.presence,
        "created_at" => now,
        "last_seen_at" => now,
      }.compact

      redis.setex(key, ttl, JSON.generate(payload))
      true
    rescue => e
      Rails.logger.warn("[media_gallery] hls playback session open failed session_id=#{session_id} error=#{e.class}: #{e.message}") rescue nil
      false
    end

    def hls_playback_session_payload(session_id)
      key = hls_playback_session_key(session_id)
      return nil if key.blank?

      raw = redis.get(key)
      return nil if raw.blank?

      data = JSON.parse(raw) rescue nil
      data.is_a?(Hash) ? data : nil
    rescue
      nil
    end

    def validate_hls_playback_session(session_id:, token:, payload:, user_id:, media_item_id:)
      return [true, nil] unless hls_playback_sessions_enabled?

      session_id = session_id.to_s.presence || (payload.is_a?(Hash) ? payload["playback_session_id"].to_s.presence : nil)
      return [false, "hls_playback_session_missing"] if session_id.blank?

      data = hls_playback_session_payload(session_id)
      return [false, "hls_playback_session_not_active"] unless data.present?

      expected_token_sha = data["token_sha256"].to_s
      actual_token_sha = token_sha256(token).to_s
      return [false, "hls_playback_session_token_mismatch"] if expected_token_sha.blank? || actual_token_sha.blank? || expected_token_sha != actual_token_sha

      stored_user_id = data["user_id"].to_i
      return [false, "hls_playback_session_user_mismatch"] if stored_user_id.positive? && user_id.to_i != stored_user_id

      stored_media_item_id = data["media_item_id"].to_i
      return [false, "hls_playback_session_media_mismatch"] if stored_media_item_id.positive? && media_item_id.to_i != stored_media_item_id

      return [false, "hls_playback_session_kind_mismatch"] if data["kind"].to_s.present? && data["kind"].to_s != "hls"

      [true, nil]
    rescue => e
      Rails.logger.warn("[media_gallery] hls playback session validate failed session_id=#{session_id} error=#{e.class}: #{e.message}") rescue nil
      [false, "hls_playback_session_validate_error"]
    end

    def touch_hls_playback_session!(session_id:, token:, attrs: {})
      return false unless hls_playback_sessions_enabled?
      data = hls_playback_session_payload(session_id)
      return false unless data.present?
      return false if data["token_sha256"].to_s != token_sha256(token).to_s

      now = Time.now.utc.iso8601
      merged = data.merge(stringify_values(attrs).compact).merge("last_seen_at" => now)
      write_hls_playback_session_payload!(session_id, merged)
      true
    rescue => e
      Rails.logger.debug("[media_gallery] hls playback session touch failed session_id=#{session_id} error=#{e.class}: #{e.message}") if Rails.logger.respond_to?(:debug)
      false
    end

    def close_hls_playback_session!(session_id:, token: nil)
      return false if session_id.blank?
      data = hls_playback_session_payload(session_id)
      if token.present? && data.present? && data["token_sha256"].to_s != token_sha256(token).to_s
        return false
      end

      key = hls_playback_session_key(session_id)
      return false if key.blank?

      redis.del(key)
      true
    rescue
      false
    end

    def hls_playback_session_manifest_received?(session_id)
      data = hls_playback_session_payload(session_id)
      return false unless data.present?

      data["hls_master_playlist_received_at"].present? || data["hls_variant_playlist_received_at"].present?
    rescue
      false
    end

    def hls_playback_session_recent_heartbeat_status(session_id, grace_seconds: nil)
      data = hls_playback_session_payload(session_id)
      return [false, "hls_playback_session_not_active", nil] unless data.present?

      grace = grace_seconds.to_i
      grace = hls_recent_heartbeat_grace_seconds if grace <= 0
      now = Time.now.utc

      heartbeat_at = parse_iso8601_utc(data["hls_last_heartbeat_at"])
      return [true, nil, data] if heartbeat_at.present? && heartbeat_at >= now - grace

      created_at = parse_iso8601_utc(data["created_at"])
      if heartbeat_at.blank? && created_at.present? && created_at >= now - grace
        return [true, nil, data]
      end

      reason = heartbeat_at.present? ? "hls_recent_heartbeat_stale" : "hls_recent_heartbeat_missing"
      [false, reason, data]
    rescue => e
      Rails.logger.debug("[media_gallery] hls heartbeat status check failed session_id=#{session_id} error=#{e.class}: #{e.message}") if Rails.logger.respond_to?(:debug)
      [false, "hls_recent_heartbeat_check_error", nil]
    end

    def parse_iso8601_utc(value)
      return nil if value.blank?
      Time.iso8601(value.to_s).utc
    rescue
      nil
    end
    private_class_method :parse_iso8601_utc

    def write_hls_playback_session_payload!(session_id, payload)
      key = hls_playback_session_key(session_id)
      return false if key.blank?

      ttl = redis.ttl(key).to_i
      ttl = 1 if ttl <= 0
      redis.setex(key, ttl, JSON.generate(payload))
      true
    end
    private_class_method :write_hls_playback_session_payload!

    def stringify_values(hash)
      Hash[Array(hash).map { |k, v| [k.to_s, v] }]
    rescue
      {}
    end
    private_class_method :stringify_values

    # -----------------
    # Revocation
    # -----------------

    def revoked?(token)
      return false if token.blank?
      key = revoked_key(token)
      return false if key.blank?

      redis.exists?(key)
    rescue
      false
    end

    def revoke!(token:, exp: nil, user_id: nil, ip: nil, playback_session_id: nil)
      return unless revoke_enabled?
      return if token.blank?

      ttl = nil
      ttl = exp.to_i - Time.now.to_i if exp.present?
      ttl ||= SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
      ttl = 1 if ttl <= 0

      rk = revoked_key(token)
      return if rk.blank?

      redis.setex(rk, ttl, "1")

      # Best effort cleanup of tracking keys.
      begin
        tk = token_key(token)
        sk = session_key(token)

        redis.del(tk)
        redis.del(sk)
        close_hls_playback_session!(session_id: playback_session_id, token: token) if playback_session_id.present?

        if user_id.present?
          redis.srem(user_tokens_set(user_id), tk)
          redis.srem(user_sessions_set(user_id), sk)
        end

        if ip.present?
          redis.srem(ip_tokens_set(ip), tk)
          redis.srem(ip_sessions_set(ip), sk)
        end
      rescue
        # ignore
      end

      true
    end

    # -----------------
    # Enforcement helpers
    # -----------------

    def enforce_active_token_limits!(user_id:, ip:)
      mu = max_active_tokens_per_user
      mi = max_active_tokens_per_ip

      u_count, i_count = active_tokens_count(user_id: user_id, ip: ip)

      if mu.positive? && user_id.present? && u_count >= mu
        return [false, "too_many_active_tokens_user"]
      end

      if mi.positive? && ip.present? && i_count >= mi
        return [false, "too_many_active_tokens_ip"]
      end

      [true, nil]
    end

    def enforce_session_limits!(user_id:, ip:)
      mu = max_concurrent_sessions_per_user
      mi = max_concurrent_sessions_per_ip

      u_count, i_count = active_sessions_count(user_id: user_id, ip: ip)

      if mu.positive? && user_id.present? && u_count > mu
        return [false, "too_many_concurrent_sessions_user"]
      end

      if mi.positive? && ip.present? && i_count > mi
        return [false, "too_many_concurrent_sessions_ip"]
      end

      [true, nil]
    end

    # Used at token issuance time (before the new session is added).
    def enforce_new_session_limits!(user_id:, ip:)
      mu = max_concurrent_sessions_per_user
      mi = max_concurrent_sessions_per_ip

      u_count, i_count = active_sessions_count(user_id: user_id, ip: ip)

      if mu.positive? && user_id.present? && u_count >= mu
        return [false, "too_many_concurrent_sessions_user"]
      end

      if mi.positive? && ip.present? && i_count >= mi
        return [false, "too_many_concurrent_sessions_ip"]
      end

      [true, nil]
    end
  end
end
