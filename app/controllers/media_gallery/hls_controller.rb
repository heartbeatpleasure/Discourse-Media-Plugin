# frozen_string_literal: true

require "digest"
require "json"

module ::MediaGallery
  class HlsController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_plugin_enabled
    before_action :ensure_logged_in
    before_action :ensure_can_view
    before_action :ensure_hls_enabled

    def master
      token = params[:token].to_s
      payload = verify_hls_token!(token)
      return unless enforce_hls_rate_limit!(kind: :playlist, token: token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      deny!(:item_not_ready, token: token) if item.blank?
      deny!(:item_hidden, token: token) if item.respond_to?(:admin_hidden?) && item.admin_hidden?
      deny!(:item_not_ready, token: token) unless item.ready?
      deny!(:token_item_mismatch, token: token) if payload["media_item_id"].to_i != item.id
      enforce_asset_binding!(item, payload: payload, kind: "hls", token: token)
      deny!(:hls_not_ready, token: token) unless MediaGallery::Hls.ready?(item)
      deny_direct_media_navigation!(:master, token: token, item: item)

      role = hls_role_for(item)
      enforce_aes128_required!(item, role: role, token: token)
      data = read_master_playlist!(item, role: role)
      data = rewrite_master_playlist(data, public_id: item.public_id, token: token)

      set_playlist_headers!
      send_data(data, type: m3u8_content_type, disposition: "inline")
    end

    def variant
      token = params[:token].to_s
      payload = verify_hls_token!(token)
      return unless enforce_hls_rate_limit!(kind: :playlist, token: token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      deny!(:item_not_ready, token: token) if item.blank?
      deny!(:item_hidden, token: token) if item.respond_to?(:admin_hidden?) && item.admin_hidden?
      deny!(:item_not_ready, token: token) unless item.ready?
      deny!(:token_item_mismatch, token: token) if payload["media_item_id"].to_i != item.id
      enforce_asset_binding!(item, payload: payload, kind: "hls", token: token)
      deny!(:hls_not_ready, token: token) unless MediaGallery::Hls.ready?(item)
      deny_direct_media_navigation!(:variant, token: token, item: item)

      variant = params[:variant].to_s
      deny!(:variant_not_allowed, token: token) unless MediaGallery::Hls.variant_allowed?(variant)

      role = hls_role_for(item)
      enforce_aes128_required!(item, role: role, token: token)
      data = read_variant_playlist!(item, variant: variant, role: role)
      data = rewrite_variant_playlist(data, item: item, variant: variant, token: token, fingerprint_id: payload["fingerprint_id"], media_item_id: item.id, role: role)

      set_playlist_headers!
      send_data(data, type: m3u8_content_type, disposition: "inline")
    end

    def segment
      token = params[:token].to_s
      payload = verify_hls_token!(token)
      return unless enforce_hls_rate_limit!(kind: :segment, token: token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      deny!(:item_not_ready, token: token) if item.blank?
      deny!(:item_hidden, token: token) if item.respond_to?(:admin_hidden?) && item.admin_hidden?
      deny!(:item_not_ready, token: token) unless item.ready?
      deny!(:token_item_mismatch, token: token) if payload["media_item_id"].to_i != item.id
      enforce_asset_binding!(item, payload: payload, kind: "hls", token: token)
      deny!(:hls_not_ready, token: token) unless MediaGallery::Hls.ready?(item)
      deny_direct_media_navigation!(:segment, token: token, item: item)

      variant = params[:variant].to_s
      deny!(:variant_not_allowed, token: token) unless MediaGallery::Hls.variant_allowed?(variant)

      ab = params[:ab].to_s.downcase.presence
      if ab.present? && !%w[a b].include?(ab)
        deny!(:ab_not_allowed, token: token)
      end

      if MediaGallery::Fingerprinting.enabled? && payload["fingerprint_id"].present? && ab.blank?
        deny!(:missing_ab_variant, token: token)
      end

      segment = params[:segment].to_s
      segment = File.basename(segment)
      deny!(:invalid_segment_name, token: token) unless segment =~ /\A[\w\-.]+\.(ts|m4s)\z/i

      if MediaGallery::Fingerprinting.enabled? && payload["fingerprint_id"].present? && ab.present?
        seg_idx = MediaGallery::Fingerprinting.segment_index_from_filename(segment)
        if seg_idx.present?
          codebook_scheme = packaged_codebook_scheme_for(item)
          expected = MediaGallery::Fingerprinting.expected_variant_for_segment(
            fingerprint_id: payload["fingerprint_id"],
            media_item_id: item.id,
            segment_index: seg_idx,
            codebook: codebook_scheme
          )
          deny!(:ab_mismatch, token: token) if expected.to_s != ab.to_s
        end
      end

      role = hls_role_for(item)
      enforce_aes128_required!(item, role: role, token: token)
      delivery = resolve_segment_delivery(item, variant: variant, segment: segment, ab: ab, role: role)
      raise Discourse::NotFound if delivery.blank?

      set_segment_headers!(segment)

      if delivery[:mode] == :redirect
        response.headers["Cache-Control"] = "no-store"
        return redirect_to(delivery[:redirect_url], allow_other_host: true, status: 307)
      end

      if delivery[:mode] == :proxy
        return send_remote_segment(delivery, segment)
      end

      abs = delivery[:local_path]
      raise Discourse::NotFound unless abs.present? && File.exist?(abs)

      if SiteSetting.respond_to?(:media_gallery_hls_x_accel_enabled) && SiteSetting.media_gallery_hls_x_accel_enabled
        internal = SiteSetting.media_gallery_hls_x_accel_internal_location.to_s.strip
        internal = "/internal/media-hls/" if internal.blank?
        internal = "/#{internal}" unless internal.start_with?("/")
        internal = "#{internal}/" unless internal.end_with?("/")

        rel = segment_rel_from_abs(abs)
        response.headers["X-Accel-Redirect"] = internal + rel
        return head :ok
      end

      send_file(abs, type: segment_content_type(segment), disposition: "inline")
    end

    def key
      token = params[:token].to_s
      payload = verify_hls_token!(token)
      return unless enforce_hls_rate_limit!(kind: :key, token: token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      deny!(:item_not_ready, token: token) if item.blank?
      deny!(:item_hidden, token: token) if item.respond_to?(:admin_hidden?) && item.admin_hidden?
      deny!(:item_not_ready, token: token) unless item.ready?
      deny!(:token_item_mismatch, token: token) if payload["media_item_id"].to_i != item.id
      enforce_asset_binding!(item, payload: payload, kind: "hls", token: token)
      deny!(:hls_not_ready, token: token) unless MediaGallery::Hls.ready?(item)
      deny_direct_media_navigation!(:key, token: token, item: item)

      role = hls_role_for(item)
      deny!(:hls_aes128_role_missing, token: token) unless role.present?
      encryption = MediaGallery::Hls.aes128_encryption_meta_for(item, role: role)
      deny!(:hls_aes128_not_ready, token: token) unless MediaGallery::Hls.aes128_ready?(item, role: role) && encryption.present?

      key_id = normalized_hls_aes128_key_id!(params[:key_id].to_s, token: token)
      expected_key_id = encryption["key_id"].to_s
      deny!(:hls_aes128_key_mismatch, token: token) if expected_key_id.blank? || expected_key_id != key_id

      key_bytes = MediaGallery::HlsAes128.fetch_key_bytes(item: item, key_id: key_id)
      deny!(:hls_aes128_key_missing, token: token) unless MediaGallery::HlsAes128.valid_key_bytes?(key_bytes)

      set_key_headers!
      response.headers["Content-Length"] = key_bytes.b.bytesize.to_s
      send_data(key_bytes.b, type: "application/octet-stream", disposition: "inline")
    end

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.media_gallery_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless MediaGallery::Permissions.can_view?(guardian)
    end

    def ensure_hls_enabled
      raise Discourse::NotFound unless SiteSetting.respond_to?(:media_gallery_hls_enabled) && SiteSetting.media_gallery_hls_enabled
    end


    def enforce_aes128_required!(item, role:, token:)
      return unless MediaGallery::Hls.aes128_required?

      deny!(:hls_aes128_not_ready, token: token) unless MediaGallery::Hls.aes128_ready?(item, role: role)
    end

    def enforce_asset_binding!(item, payload:, kind:, token:)
      return if ::MediaGallery::Token.asset_binding_valid?(media_item: item, kind: kind, payload: payload)

      deny!(:asset_binding_mismatch, token: token)
    end

    def normalized_hls_aes128_key_id!(raw_key_id, token:)
      ::MediaGallery::HlsAes128.normalize_key_id(raw_key_id)
    rescue
      deny!(:hls_aes128_invalid_key_id, token: token)
    end

    def verify_hls_token!(token)
      deny!(:missing_token, token: token) if token.blank?
      deny!(:token_revoked, token: token) if MediaGallery::Security.revoked?(token)

      payload = MediaGallery::Token.verify(token, purpose: "hls")
      deny!(:invalid_or_expired_token, token: token) if payload.blank?
      deny!(:invalid_token_kind, token: token) if payload["kind"].to_s != "hls"

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        deny!(:user_mismatch, token: token)
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        deny!(:ip_mismatch, token: token)
      end

      unless MediaGallery::Token.request_session_binding_valid?(payload: payload, request: request, cookies: cookies)
        deny!(:session_binding_mismatch, token: token)
      end

      payload
    end

    def enforce_hls_rate_limit!(kind:, token:)
      per_min =
        case kind.to_s
        when "playlist"
          SiteSetting.respond_to?(:media_gallery_hls_playlist_requests_per_token_per_minute) ?
            SiteSetting.media_gallery_hls_playlist_requests_per_token_per_minute.to_i :
            0
        when "key"
          if SiteSetting.respond_to?(:media_gallery_hls_key_requests_per_token_per_minute)
            SiteSetting.media_gallery_hls_key_requests_per_token_per_minute.to_i
          elsif SiteSetting.respond_to?(:media_gallery_hls_segment_requests_per_token_per_minute)
            SiteSetting.media_gallery_hls_segment_requests_per_token_per_minute.to_i
          else
            0
          end
        else
          SiteSetting.respond_to?(:media_gallery_hls_segment_requests_per_token_per_minute) ?
            SiteSetting.media_gallery_hls_segment_requests_per_token_per_minute.to_i :
            0
        end

      return true if per_min <= 0

      ip = request.remote_ip.to_s
      digest = Digest::SHA256.hexdigest("#{token}|#{ip}")
      key = "media_gallery:hls:#{kind}:sha256:#{digest}"

      RateLimiter.new(nil, key, per_min, 1.minute).performed!
      true
    rescue RateLimiter::LimitExceeded
      log_denial!("rate_limited_#{kind}", token: token)
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Retry-After"] = "60"
      render plain: "rate_limited", status: 429
      false
    end

    def deny!(reason, token: nil)
      log_denial!(reason, token: token)
      raise Discourse::NotFound
    end

    def deny_direct_media_navigation!(endpoint, token:, item: nil)
      return unless ::MediaGallery::RequestSecurity.direct_media_navigation_blocked?(request)

      details = {
        reason: "direct_media_navigation_blocked",
        endpoint: endpoint.to_s,
        public_id: params[:public_id].to_s.presence,
        variant: params[:variant].to_s.presence,
        segment: params[:segment].to_s.presence,
        token_present: token.present?,
        token_sha256: token_sha256_label(token),
      }.merge(::MediaGallery::RequestSecurity.fetch_metadata_details(request))

      ::MediaGallery::LogEvents.record(
        event_type: "direct_media_navigation_blocked",
        severity: "warning",
        category: "playback",
        request: request,
        user: current_user,
        media_item: item,
        message: "hls_#{endpoint}",
        details: details,
      )

      log_denial!("direct_media_navigation_blocked", token: token)
      raise Discourse::NotFound
    rescue Discourse::NotFound
      raise
    rescue
      raise Discourse::NotFound
    end

    def denial_logging_enabled?(reason = nil)
      if params[:action].to_s == "key" || reason.to_s.start_with?("hls_aes128")
        return true if MediaGallery::Hls.respond_to?(:aes128_key_denial_logging_enabled?) && MediaGallery::Hls.aes128_key_denial_logging_enabled?
      end

      SiteSetting.respond_to?(:media_gallery_log_hls_denials) && SiteSetting.media_gallery_log_hls_denials
    end

    def token_sha256_label(token)
      return "-" if token.blank?
      "sha256:#{Digest::SHA256.hexdigest(token.to_s)}"
    rescue
      "-"
    end

    def log_denial!(reason, token: nil)
      return unless denial_logging_enabled?(reason)
      Rails.logger.warn(
        "[media_gallery] HLS denied reason=#{reason} token_sha256=#{token_sha256_label(token)} ip=#{request.remote_ip} user_id=#{current_user&.id} request_id=#{request.request_id}"
      )
      ::MediaGallery::LogEvents.record(
        event_type: "hls_denied",
        severity: "warning",
        category: "playback",
        request: request,
        user: current_user,
        message: reason.to_s,
        details: {
          reason: reason.to_s,
          public_id: params[:public_id].to_s.presence,
          variant: params[:variant].to_s.presence,
          endpoint: params[:action].to_s.presence,
          segment: params[:segment].to_s.presence,
          key_id: params[:key_id].to_s.presence,
          token_present: token.present?,
          token_sha256: token_sha256_label(token),
        },
      )
    rescue
    end

    def hls_role_for(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      return nil unless role.present?

      role = role.deep_stringify_keys
      return nil unless managed_hls_role_ready_cached?(item, role)

      role
    rescue
      nil
    end

    def hls_store_for(item, role)
      ::MediaGallery::Hls.store_for_managed_role(item, role)
    rescue
      nil
    end

    def read_master_playlist!(item, role: nil)
      if role.present?
        store = hls_store_for(item, role)
        raise Discourse::NotFound if store.blank?

        key = ::MediaGallery::Hls.master_key_for(item, role: role)
        return read_hls_store_object!(store, key, item: item, role: role, cache_kind: "master")
      end

      path = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      raise Discourse::NotFound unless path.present? && File.exist?(path)
      read_local_playlist!(path, cache_kind: "master")
    end

    def read_variant_playlist!(item, variant:, role: nil)
      if role.present?
        store = hls_store_for(item, role)
        raise Discourse::NotFound if store.blank?

        key = ::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: role)
        return read_hls_store_object!(store, key, item: item, role: role, cache_kind: "variant:#{variant}")
      end

      path = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
      raise Discourse::NotFound unless path.present? && File.exist?(path)
      read_local_playlist!(path, cache_kind: "variant:#{variant}")
    end

    def resolve_segment_delivery(item, variant:, segment:, ab:, role: nil)
      if role.present?
        store = hls_store_for(item, role)
        raise Discourse::NotFound if store.blank?

        key = ::MediaGallery::Hls.segment_key_for(item, variant, segment, ab: ab, role: role)
        raise Discourse::NotFound if key.blank?

        if role["backend"].to_s == "s3"
          if s3_redirect_delivery_enabled?
            ttl = hls_s3_presign_ttl_for_item(item)
            content_type = segment_content_type(segment)

            return {
              mode: :redirect,
              redirect_url: presigned_hls_segment_url(
                store,
                key,
                item: item,
                role: role,
                expires_in: ttl,
                response_content_type: content_type,
                response_content_disposition: "inline"
              )
            }
          end

          return {
            mode: :proxy,
            store: store,
            key: key,
            content_type: segment_content_type(segment)
          }
        end

        abs = store.absolute_path_for(key)
        raise Discourse::NotFound unless abs.present? && File.exist?(abs)
        return { mode: :local, local_path: abs }
      end

      abs = resolve_segment_abs_path(item.public_id, variant, segment, ab: ab)
      raise Discourse::NotFound unless abs.present? && File.exist?(abs)
      { mode: :local, local_path: abs }
    end

    def send_remote_segment(delivery, segment)
      store = delivery[:store]
      key = delivery[:key].to_s
      raise Discourse::NotFound if store.blank? || key.blank?

      if request.head?
        bytes = delivery[:bytes].to_i
        if bytes <= 0 && store.respond_to?(:object_info)
          info = store.object_info(key)
          bytes = info[:bytes].to_i if info.is_a?(Hash)
        end
        response.headers["Content-Length"] = bytes.to_s if bytes.positive?
        return head :ok
      end

      content_type = delivery[:content_type].presence || segment_content_type(segment)
      if hls_proxy_stream_remote_segments? && store.respond_to?(:stream)
        response.headers["Content-Type"] = content_type
        self.response_body = Enumerator.new do |yielder|
          store.stream(key) do |chunk|
            yielder << chunk
          end
        end
        return
      end

      data = store.read(key)
      response.headers["Content-Length"] = data.to_s.b.bytesize.to_s
      send_data(data, type: content_type, disposition: "inline")
    end

    def s3_redirect_delivery_enabled?
      ::MediaGallery::StorageSettingsResolver.default_delivery_mode.to_s == "redirect"
    rescue
      true
    end

    def segment_rel_from_abs(abs_path)
      root = MediaGallery::PrivateStorage.private_root.to_s
      root = root.chomp("/")
      p = abs_path.to_s
      return p if root.blank?
      p = p.sub(/\A#{Regexp.escape(root)}\/?/, "")
      p
    end

    def resolve_segment_rel_path(public_id, variant, segment, ab: nil)
      seg = segment.to_s
      if ab.present?
        File.join(public_id.to_s, "hls", ab.to_s, variant.to_s, seg)
      else
        MediaGallery::PrivateStorage.hls_segment_rel_path(public_id, variant, seg)
      end
    end

    def resolve_segment_abs_path(public_id, variant, segment, ab: nil)
      if ab.present?
        ab_abs = File.join(MediaGallery::PrivateStorage.private_root, resolve_segment_rel_path(public_id, variant, segment, ab: ab))
        return ab_abs if File.exist?(ab_abs)
      end

      MediaGallery::PrivateStorage.hls_segment_abs_path(public_id, variant, segment)
    end

    def packaged_codebook_scheme_for(item)
      role = hls_role_for(item)
      store = role.present? ? hls_store_for(item, role) : nil
      meta = ::MediaGallery::Hls.fingerprint_meta_for(item, role: role, store: store)
      return nil unless meta.is_a?(Hash)

      meta["codebook_scheme"].to_s.presence ||
        ::MediaGallery::Fingerprinting.codebook_scheme_for(layout: meta["layout"].to_s)
    rescue
      nil
    end

    def managed_hls_role_ready_cached?(item, role)
      ttl = hls_managed_readiness_cache_seconds
      return ::MediaGallery::Hls.managed_role_ready?(item, role) if ttl <= 0

      key = hls_cache_key("ready", item: item, role: role)
      return true if Rails.cache.read(key) == true

      ready = ::MediaGallery::Hls.managed_role_ready?(item, role)
      Rails.cache.write(key, true, expires_in: ttl.seconds) if ready
      ready
    rescue
      ::MediaGallery::Hls.managed_role_ready?(item, role)
    end

    def read_hls_store_object!(store, key, item:, role:, cache_kind:)
      raise Discourse::NotFound if key.blank?

      ttl = hls_playlist_cache_seconds
      return store.read(key) if ttl <= 0

      Rails.cache.fetch(hls_cache_key("playlist", item: item, role: role, parts: [cache_kind, key]), expires_in: ttl.seconds) do
        store.read(key)
      end
    rescue
      raise Discourse::NotFound
    end

    def read_local_playlist!(path, cache_kind:)
      ttl = hls_playlist_cache_seconds
      return File.read(path) if ttl <= 0

      stat = File.stat(path)
      key = "media_gallery:hls:playlist:local:#{Digest::SHA256.hexdigest([path.to_s, stat.mtime.to_i, stat.size.to_i, cache_kind].join('|'))}"
      Rails.cache.fetch(key, expires_in: ttl.seconds) { File.read(path) }
    rescue
      raise Discourse::NotFound
    end

    def presigned_hls_segment_url(store, key, item:, role:, expires_in:, response_content_type:, response_content_disposition:)
      ttl = hls_s3_presign_cache_seconds(expires_in: expires_in)
      if ttl <= 0
        return store.presigned_get_url(
          key,
          expires_in: expires_in,
          response_content_type: response_content_type,
          response_content_disposition: response_content_disposition
        )
      end

      Rails.cache.fetch(
        hls_cache_key("presigned", item: item, role: role, parts: [key, response_content_type, response_content_disposition, expires_in]),
        expires_in: ttl.seconds
      ) do
        store.presigned_get_url(
          key,
          expires_in: expires_in,
          response_content_type: response_content_type,
          response_content_disposition: response_content_disposition
        )
      end
    rescue
      store.presigned_get_url(
        key,
        expires_in: expires_in,
        response_content_type: response_content_type,
        response_content_disposition: response_content_disposition
      )
    end

    def hls_cache_key(kind, item:, role: nil, parts: [])
      role ||= {}
      profile_key = item.respond_to?(:managed_storage_profile) ? item.managed_storage_profile.to_s : ""
      location = ::MediaGallery::StorageSettingsResolver.profile_location_fingerprint_key(profile_key) rescue nil
      payload = [
        kind,
        item&.id,
        item&.public_id,
        item&.updated_at&.to_i,
        profile_key,
        location,
        role.is_a?(Hash) ? role["backend"] : nil,
        role.is_a?(Hash) ? role["generated_at"] : nil,
        role.is_a?(Hash) ? role["master_key"] : nil,
        role.is_a?(Hash) ? role["complete_key"] : nil,
        Array(parts).join("|")
      ].join("|")

      "media_gallery:hls:#{kind}:#{Digest::SHA256.hexdigest(payload)}"
    end

    def hls_managed_readiness_cache_seconds
      site_setting_integer(:media_gallery_hls_managed_readiness_cache_seconds, default: 30, min: 0, max: 300)
    end

    def hls_playlist_cache_seconds
      site_setting_integer(:media_gallery_hls_playlist_cache_seconds, default: 15, min: 0, max: 300)
    end

    def hls_s3_presign_ttl_for_item(item)
      profile_ttl = ::MediaGallery::StorageSettingsResolver.presign_ttl_for_profile_key(item.respond_to?(:managed_storage_profile) ? item.managed_storage_profile : nil).to_i
      profile_ttl = 300 if profile_ttl <= 0
      hls_ttl = site_setting_integer(:media_gallery_hls_s3_presign_ttl_seconds, default: 60, min: 0, max: 3600)
      ttl = hls_ttl.positive? ? hls_ttl : profile_ttl
      ttl = 15 if ttl < 15
      [ttl, profile_ttl].min
    rescue
      60
    end

    def hls_s3_presign_cache_seconds(expires_in:)
      configured = site_setting_integer(:media_gallery_hls_s3_presign_cache_seconds, default: 15, min: 0, max: 300)
      return 0 if configured <= 0

      ttl_cap = expires_in.to_i - 5
      return 0 if ttl_cap <= 0

      [configured, ttl_cap].min
    end

    def hls_proxy_stream_remote_segments?
      return true unless SiteSetting.respond_to?(:media_gallery_hls_proxy_stream_remote_segments)

      !!SiteSetting.media_gallery_hls_proxy_stream_remote_segments
    rescue
      true
    end

    def site_setting_integer(name, default:, min:, max:)
      value = SiteSetting.respond_to?(name) ? SiteSetting.public_send(name).to_i : default.to_i
      value = default.to_i if value.nil?
      value = min.to_i if value < min.to_i
      value = max.to_i if value > max.to_i
      value
    rescue
      default.to_i
    end

    def set_playlist_headers!
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    def set_segment_headers!(segment)
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = segment_content_type(segment)
    end

    def set_key_headers!
      response.headers["Cache-Control"] = "no-store, no-cache, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = "application/octet-stream"
    end

    def m3u8_content_type
      "application/vnd.apple.mpegurl"
    end

    def segment_content_type(segment = nil)
      ext = File.extname(segment.to_s).downcase
      return "video/iso.segment" if ext == ".m4s"
      "video/MP2T"
    end

    def rewrite_master_playlist(raw, public_id:, token:)
      out = []
      raw.to_s.each_line do |line|
        l = line.rstrip
        if l.blank? || l.start_with?("#")
          out << l
          next
        end

        variant = l.split("/").first.to_s
        if MediaGallery::Hls.variant_allowed?(variant)
          out << "/media/hls/#{public_id}/v/#{variant}/index.m3u8?token=#{token}"
        else
          out << l
        end
      end
      out.join("\n") + "\n"
    end

    def rewrite_variant_playlist(raw, item:, variant:, token:, fingerprint_id: nil, media_item_id: nil, role: nil)
      out = []
      seg_counter = 0
      public_id = item.public_id.to_s
      codebook_scheme = packaged_codebook_scheme_for(item)

      raw.to_s.each_line do |line|
        l = line.rstrip
        if l.blank? || l.start_with?("#")
          if l.start_with?("#EXT-X-KEY") && l.match?(/METHOD=AES-128/i)
            out << rewrite_aes128_key_tag(l, item: item, variant: variant, token: token, role: role)
          elsif l.include?("URI=\"")
            out << l.gsub(/URI=\"([^\"]+)\"/) do
              uri = Regexp.last_match(1).to_s
              file = File.basename(uri)
              if file =~ /\A[\w\-.]+\.(mp4|m4s)\z/i
                "URI=\"/media/hls/#{public_id}/seg/#{variant}/#{file}?token=#{token}\""
              else
                "URI=\"#{uri}\""
              end
            end
          else
            out << l
          end
          next
        end

        seg = File.basename(l)
        if seg =~ /\A[\w\-.]+\.(ts|m4s)\z/i
          ab = nil
          if MediaGallery::Fingerprinting.enabled? && fingerprint_id.present? && media_item_id.present?
            idx = MediaGallery::Fingerprinting.segment_index_from_filename(seg)
            idx ||= seg_counter
            ab = MediaGallery::Fingerprinting.expected_variant_for_segment(
              fingerprint_id: fingerprint_id,
              media_item_id: media_item_id,
              segment_index: idx,
              codebook: codebook_scheme
            )
          end

          seg_counter += 1

          if ab.present?
            out << "/media/hls/#{public_id}/seg/#{variant}/#{ab}/#{seg}?token=#{token}"
          else
            out << "/media/hls/#{public_id}/seg/#{variant}/#{seg}?token=#{token}"
          end
        else
          out << l
        end
      end
      out.join("\n") + "\n"
    end

    def rewrite_aes128_key_tag(line, item:, variant:, token:, role: nil)
      return line unless line.to_s.include?("URI=\"")

      encryption = MediaGallery::Hls.aes128_encryption_meta_for(item, role: role)
      return line unless encryption.present?

      line.gsub(/URI=\"([^\"]+)\"/) do
        uri = Regexp.last_match(1).to_s
        key_id = MediaGallery::HlsAes128.key_id_from_placeholder_uri(uri)
        if key_id.present? && key_id == encryption["key_id"].to_s
          "URI=\"/media/hls/#{item.public_id}/key/#{key_id}.key?token=#{token}\""
        else
          "URI=\"#{uri}\""
        end
      end
    rescue
      line
    end
  end
end
