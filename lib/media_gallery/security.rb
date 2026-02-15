# frozen_string_literal: true

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

    # -----------------
    # Redis keys
    # -----------------

    def token_key(token)
      "media_gallery:token:#{token}"
    end

    def revoked_key(token)
      "media_gallery:revoked:#{token}"
    end

    def session_key(token)
      "media_gallery:session:#{token}"
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

      # Remove members whose referenced key expired.
      members.each do |member_key|
        next if redis.exists?(member_key)
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
    # Revocation
    # -----------------

    def revoked?(token)
      return false if token.blank?
      redis.exists?(revoked_key(token))
    rescue
      false
    end

    def revoke!(token:, exp: nil, user_id: nil, ip: nil)
      return unless revoke_enabled?
      return if token.blank?

      ttl = nil
      ttl = exp.to_i - Time.now.to_i if exp.present?
      ttl ||= SiteSetting.media_gallery_stream_token_ttl_minutes.to_i * 60
      ttl = 1 if ttl <= 0

      redis.setex(revoked_key(token), ttl, "1")

      # Best effort cleanup of tracking keys.
      begin
        tk = token_key(token)
        sk = session_key(token)

        redis.del(tk)
        redis.del(sk)

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
