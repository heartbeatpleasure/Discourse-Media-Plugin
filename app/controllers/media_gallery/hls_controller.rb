# frozen_string_literal: true

require "digest/sha1"
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

      role = hls_role_for(item)
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

      variant = params[:variant].to_s
      deny!(:variant_not_allowed, token: token) unless MediaGallery::Hls.variant_allowed?(variant)

      role = hls_role_for(item)
      data = read_variant_playlist!(item, variant: variant, role: role)
      data = rewrite_variant_playlist(data, item: item, variant: variant, token: token, fingerprint_id: payload["fingerprint_id"], media_item_id: item.id)

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

    def enforce_asset_binding!(item, payload:, kind:, token:)
      return if ::MediaGallery::Token.asset_binding_valid?(media_item: item, kind: kind, payload: payload)

      deny!(:asset_binding_mismatch, token: token)
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

      payload
    end

    def enforce_hls_rate_limit!(kind:, token:)
      per_min =
        case kind.to_s
        when "playlist"
          SiteSetting.respond_to?(:media_gallery_hls_playlist_requests_per_token_per_minute) ?
            SiteSetting.media_gallery_hls_playlist_requests_per_token_per_minute.to_i :
            0
        else
          SiteSetting.respond_to?(:media_gallery_hls_segment_requests_per_token_per_minute) ?
            SiteSetting.media_gallery_hls_segment_requests_per_token_per_minute.to_i :
            0
        end

      return true if per_min <= 0

      ip = request.remote_ip.to_s
      digest = Digest::SHA1.hexdigest("#{token}|#{ip}")
      key = "media_gallery:hls:#{kind}:#{digest}"

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

    def denial_logging_enabled?
      SiteSetting.respond_to?(:media_gallery_log_hls_denials) && SiteSetting.media_gallery_log_hls_denials
    end

    def token_fingerprint(token)
      return "-" if token.blank?
      Digest::SHA1.hexdigest(token.to_s)[0, 12]
    end

    def log_denial!(reason, token: nil)
      return unless denial_logging_enabled?
      Rails.logger.warn(
        "[media_gallery] HLS denied reason=#{reason} token=#{token_fingerprint(token)} ip=#{request.remote_ip} user_id=#{current_user&.id} request_id=#{request.request_id}"
      )
    rescue
    end

    def hls_role_for(item)
      role = ::MediaGallery::Hls.managed_role_for(item)
      return nil unless role.present?
      return nil unless ::MediaGallery::Hls.managed_role_ready?(item, role)
      role.deep_stringify_keys
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
        begin
          return store.read(::MediaGallery::Hls.master_key_for(item, role: role))
        rescue
          raise Discourse::NotFound
        end
      end

      path = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      raise Discourse::NotFound unless path.present? && File.exist?(path)
      File.read(path)
    end

    def read_variant_playlist!(item, variant:, role: nil)
      if role.present?
        store = hls_store_for(item, role)
        raise Discourse::NotFound if store.blank?
        begin
          return store.read(::MediaGallery::Hls.variant_playlist_key_for(item, variant, role: role))
        rescue
          raise Discourse::NotFound
        end
      end

      path = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
      raise Discourse::NotFound unless path.present? && File.exist?(path)
      File.read(path)
    end

    def resolve_segment_delivery(item, variant:, segment:, ab:, role: nil)
      if role.present?
        store = hls_store_for(item, role)
        raise Discourse::NotFound if store.blank?

        key = ::MediaGallery::Hls.segment_key_for(item, variant, segment, ab: ab, role: role)
        raise Discourse::NotFound if key.blank?

        if role["backend"].to_s == "s3"
          if s3_redirect_delivery_enabled?
            ttl = ::MediaGallery::StorageSettingsResolver.presign_ttl_for_profile_key(item.managed_storage_profile)
            ttl = 300 if ttl <= 0

            return {
              mode: :redirect,
              redirect_url: store.presigned_get_url(
                key,
                expires_in: ttl,
                response_content_type: segment_content_type(segment),
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
        if bytes <= 0
          info = store.object_info(key)
          bytes = info[:bytes].to_i if info.is_a?(Hash)
        end
        response.headers["Content-Length"] = bytes.to_s if bytes.positive?
        return head :ok
      end

      data = store.read(key)
      response.headers["Content-Length"] = data.to_s.b.bytesize.to_s
      send_data(data, type: delivery[:content_type].presence || segment_content_type(segment), disposition: "inline")
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
      if role.present?
        key = ::MediaGallery::Hls.fingerprint_meta_key_for(item, role: role)
        store = hls_store_for(item, role)
        if key.present? && store.present? && store.exists?(key)
          meta = JSON.parse(store.read(key)) rescue nil
          if meta.is_a?(Hash)
            return meta["codebook_scheme"].to_s.presence ||
              ::MediaGallery::Fingerprinting.codebook_scheme_for(layout: meta["layout"].to_s)
          end
        end
      end

      root = MediaGallery::PrivateStorage.hls_root_abs_dir(item.public_id)
      meta_path = File.join(root, "fingerprint_meta.json")
      return nil unless File.exist?(meta_path)

      meta = JSON.parse(File.read(meta_path)) rescue nil
      return nil unless meta.is_a?(Hash)

      meta["codebook_scheme"].to_s.presence ||
        ::MediaGallery::Fingerprinting.codebook_scheme_for(layout: meta["layout"].to_s)
    rescue
      nil
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

    def rewrite_variant_playlist(raw, item:, variant:, token:, fingerprint_id: nil, media_item_id: nil)
      out = []
      seg_counter = 0
      public_id = item.public_id.to_s
      codebook_scheme = packaged_codebook_scheme_for(item)

      raw.to_s.each_line do |line|
        l = line.rstrip
        if l.blank? || l.start_with?("#")
          if l.include?("URI=\"")
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
  end
end
