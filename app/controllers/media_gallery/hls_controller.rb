# frozen_string_literal: true

require "digest/sha1"

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

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank? || !item.ready?
      raise Discourse::NotFound if payload["media_item_id"].to_i != item.id
      raise Discourse::NotFound unless MediaGallery::Hls.ready?(item)

      path = MediaGallery::PrivateStorage.hls_master_abs_path(item)
      raise Discourse::NotFound unless path.present? && File.exist?(path)

      data = File.read(path)
      data = rewrite_master_playlist(data, public_id: item.public_id, token: token)

      set_playlist_headers!
      send_data(data, type: m3u8_content_type, disposition: "inline")
    end

    def variant
      token = params[:token].to_s
      payload = verify_hls_token!(token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank? || !item.ready?
      raise Discourse::NotFound if payload["media_item_id"].to_i != item.id
      raise Discourse::NotFound unless MediaGallery::Hls.ready?(item)

      variant = params[:variant].to_s
      raise Discourse::NotFound unless MediaGallery::Hls.variant_allowed?(variant)

      path = MediaGallery::PrivateStorage.hls_variant_playlist_abs_path(item.public_id, variant)
      raise Discourse::NotFound unless path.present? && File.exist?(path)

      data = File.read(path)
      data = rewrite_variant_playlist(data, public_id: item.public_id, variant: variant, token: token)

      set_playlist_headers!
      send_data(data, type: m3u8_content_type, disposition: "inline")
    end

    def segment
      token = params[:token].to_s
      payload = verify_hls_token!(token)

      item = MediaGallery::MediaItem.find_by(public_id: params[:public_id].to_s)
      raise Discourse::NotFound if item.blank? || !item.ready?
      raise Discourse::NotFound if payload["media_item_id"].to_i != item.id
      raise Discourse::NotFound unless MediaGallery::Hls.ready?(item)

      variant = params[:variant].to_s
      raise Discourse::NotFound unless MediaGallery::Hls.variant_allowed?(variant)

      segment = params[:segment].to_s
      segment = File.basename(segment)
      raise Discourse::NotFound unless segment =~ /\A[\w\-.]+\.(ts|m4s)\z/i

      abs = MediaGallery::PrivateStorage.hls_segment_abs_path(item.public_id, variant, segment)
      raise Discourse::NotFound unless abs.present? && File.exist?(abs)

      set_segment_headers!

      if SiteSetting.respond_to?(:media_gallery_hls_x_accel_enabled) && SiteSetting.media_gallery_hls_x_accel_enabled
        internal = SiteSetting.media_gallery_hls_x_accel_internal_location.to_s.strip
        internal = "/internal/media-hls/" if internal.blank?
        internal = "/#{internal}" unless internal.start_with?("/")
        internal = "#{internal}/" unless internal.end_with?("/")

        rel = MediaGallery::PrivateStorage.hls_segment_rel_path(item.public_id, variant, segment)
        response.headers["X-Accel-Redirect"] = internal + rel
        return head :ok
      end

      send_file(abs, type: segment_content_type, disposition: "inline")
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

    def verify_hls_token!(token)
      raise Discourse::NotFound if token.blank?
      raise Discourse::NotFound if MediaGallery::Security.revoked?(token)

      payload = MediaGallery::Token.verify(token, purpose: "hls")
      raise Discourse::NotFound if payload.blank?

      if payload["user_id"].present? && current_user.id != payload["user_id"].to_i
        raise Discourse::NotFound
      end

      if payload["ip"].present? && request.remote_ip.to_s != payload["ip"].to_s
        raise Discourse::NotFound
      end

      payload
    end

    def set_playlist_headers!
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    def set_segment_headers!
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = segment_content_type
    end

    def m3u8_content_type
      "application/vnd.apple.mpegurl"
    end

    def segment_content_type
      "video/MP2T"
    end

    # Master playlists produced by our packager reference the variant playlists as relative paths.
    # We rewrite those lines to point at our authenticated variant endpoint.
    def rewrite_master_playlist(raw, public_id:, token:)
      out = []
      raw.to_s.each_line do |line|
        l = line.rstrip
        if l.blank? || l.start_with?("#")
          out << l
          next
        end

        # Expect something like: v0/index.m3u8
        variant = l.split("/").first.to_s
        if MediaGallery::Hls.variant_allowed?(variant)
          out << "/media/hls/#{public_id}/v/#{variant}/index.m3u8?token=#{token}"
        else
          out << l
        end
      end
      out.join("\n") + "\n"
    end

    # Variant playlists reference segments as relative paths.
    # We rewrite those lines to point at our authenticated segment endpoint.
    def rewrite_variant_playlist(raw, public_id:, variant:, token:)
      out = []
      raw.to_s.each_line do |line|
        l = line.rstrip
        if l.blank? || l.start_with?("#")
          # Also handle EXT-X-MAP URI for fMP4 (future-proof)
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
          out << "/media/hls/#{public_id}/seg/#{variant}/#{seg}?token=#{token}"
        else
          out << l
        end
      end
      out.join("\n") + "\n"
    end
  end
end
