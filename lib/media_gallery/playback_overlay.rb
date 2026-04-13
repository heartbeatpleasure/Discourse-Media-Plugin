# frozen_string_literal: true

require "securerandom"
require "digest"

module ::MediaGallery
  module PlaybackOverlay
    module_function

    CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ".freeze
    DEFAULT_POSITIONS = %w[top_left top_center top_right center_left center+40 center_right bottom_left bottom_center bottom_right].freeze
    VALID_POSITIONS = %w[
      top_left
      top_right
      top_center
      center_left
      center
      center_right
      bottom_left
      bottom_center
      bottom_right
    ].freeze

    def enabled_for_media_type?(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_video_enabled) && SiteSetting.media_gallery_playback_overlay_video_enabled
      when "image"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_image_enabled) && SiteSetting.media_gallery_playback_overlay_image_enabled
      else
        false
      end
    rescue
      false
    end

    def build_or_reuse_payload(media_item:, user:, request:, token:, fingerprint_id: nil, reuse_code: nil)
      return nil if media_item.blank? || user.blank?
      media_type = media_item.media_type.to_s
      return nil unless enabled_for_media_type?(media_type)

      rendered = rendered_text_for(media_type: media_type, user: user, code: nil)
      return nil if rendered.blank? && !show_session_code_for?(media_type)

      record = nil
      if reuse_code.present?
        record = find_reusable_record(code: reuse_code, media_item: media_item, user: user)
      end

      if record.present?
        rendered = record.rendered_text.to_s.presence || rendered_text_for(media_type: media_type, user: user, code: record.overlay_code)
        update_existing_record!(record, token: token, request: request, fingerprint_id: fingerprint_id, rendered_text: rendered)
      else
        code = unique_overlay_code
        rendered = rendered_text_for(media_type: media_type, user: user, code: code)
        record = create_record!(media_item: media_item, user: user, request: request, token: token, media_type: media_type, fingerprint_id: fingerprint_id, overlay_code: code, rendered_text: rendered)
      end

      payload_for_record(record, user: user)
    rescue => e
      Rails.logger.warn("[media_gallery] playback overlay build failed media_item_id=#{media_item&.id} user_id=#{user&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def lookup_by_code(code:, public_id: nil, limit: 25)
      return [] if code.to_s.strip.blank?
      scope = ::MediaGallery::MediaOverlaySession.includes(:user, :media_item).where(overlay_code: normalize_code(code))
      if public_id.present?
        scope = scope.joins(:media_item).where(media_gallery_media_items: { public_id: public_id.to_s.strip })
      end
      scope.order(updated_at: :desc, created_at: :desc).limit([[limit.to_i, 1].max, 100].min).map do |row|
        item = row.media_item
        usr = row.user
        {
          id: row.id,
          overlay_code: row.overlay_code,
          media_item_id: row.media_item_id,
          media_public_id: item&.public_id,
          media_title: item&.title,
          media_type: row.media_type,
          user_id: row.user_id,
          username: usr&.username,
          name: usr&.name,
          fingerprint_id: row.fingerprint_id,
          rendered_text: row.rendered_text,
          ip: row.ip,
          user_agent: row.user_agent,
          created_at: row.created_at,
          updated_at: row.updated_at
        }
      end
    rescue => e
      Rails.logger.warn("[media_gallery] playback overlay lookup failed code=#{code} public_id=#{public_id} error=#{e.class}: #{e.message}")
      []
    end

    def retention_cutoff_days
      days = SiteSetting.respond_to?(:media_gallery_forensics_playback_session_retention_days) ? SiteSetting.media_gallery_forensics_playback_session_retention_days.to_i : 0
      days > 0 ? days : 0
    rescue
      0
    end

    def purge_older_than!(cutoff)
      return unless overlay_table_present?
      ::MediaGallery::MediaOverlaySession.where("updated_at < ?", cutoff).in_batches(of: 1_000).delete_all
    rescue => e
      Rails.logger.warn("[media_gallery] playback overlay purge failed cutoff=#{cutoff} error=#{e.class}: #{e.message}")
    end

    def overlay_table_present?
      ::ActiveRecord::Base.connection.data_source_exists?("media_gallery_overlay_sessions")
    rescue
      false
    end

    def client_enabled_config
      {
        video: {
          enabled: enabled_for_media_type?("video"),
          show_username: show_username_for?("video"),
          show_timestamp: show_timestamp_for?("video"),
          show_session_code: show_session_code_for?("video")
        },
        image: {
          enabled: enabled_for_media_type?("image"),
          show_username: show_username_for?("image"),
          show_timestamp: show_timestamp_for?("image"),
          show_session_code: show_session_code_for?("image")
        },
        opacity_percent: opacity_percent,
        font_size_px: font_size_px,
        move_interval_seconds: move_interval_seconds_for("video"),
        image_move_interval_seconds: move_interval_seconds_for("image"),
        background_enabled: background_enabled?,
        background_opacity_percent: background_opacity_percent,
        positions: configured_positions
      }
    end

    def payload_for_record(record, user:)
      media_type = record.media_type.to_s
      {
        enabled: true,
        media_type: media_type,
        overlay_code: record.overlay_code,
        text: record.rendered_text,
        username: overlay_display_name(user),
        fingerprint_id_present: record.fingerprint_id.present?,
        opacity_percent: opacity_percent,
        font_size_px: font_size_px,
        move_interval_seconds: move_interval_seconds_for(media_type),
        background_enabled: background_enabled?,
        background_opacity_percent: background_opacity_percent,
        positions: effective_positions_for_record(record)
      }
    end

    def effective_positions_for_record(record)
      item = record.media_item
      positions = configured_positions.deep_dup
      if item.present? && item.respond_to?(:watermark_enabled) && item.watermark_enabled
        burned_position = SiteSetting.respond_to?(:media_gallery_watermark_position) ? SiteSetting.media_gallery_watermark_position.to_s : nil
        positions.reject! do |entry|
          entry[:key].to_s == burned_position.to_s && entry[:offset_y_px].to_i.abs < 24
        end
      end
      positions = parsed_default_positions if positions.blank?
      positions
    end

    def configured_positions
      raw = SiteSetting.respond_to?(:media_gallery_playback_overlay_positions) ? SiteSetting.media_gallery_playback_overlay_positions : nil
      parsed = normalize_list(raw).map { |entry| parse_position_entry(entry) }.compact
      parsed = parsed_default_positions if parsed.blank?
      dedupe_position_entries(parsed)
    rescue
      parsed_default_positions
    end


    def background_enabled?
      return true unless SiteSetting.respond_to?(:media_gallery_playback_overlay_background_enabled)
      SiteSetting.media_gallery_playback_overlay_background_enabled
    rescue
      true
    end

    def background_opacity_percent
      n = SiteSetting.respond_to?(:media_gallery_playback_overlay_background_opacity_percent) ? SiteSetting.media_gallery_playback_overlay_background_opacity_percent.to_i : 45
      [[n, 0].max, 100].min
    rescue
      45
    end

    def opacity_percent
      n = SiteSetting.respond_to?(:media_gallery_playback_overlay_opacity_percent) ? SiteSetting.media_gallery_playback_overlay_opacity_percent.to_i : 28
      n = 28 if n <= 0
      [[n, 10].max, 100].min
    rescue
      28
    end

    def font_size_px
      n = SiteSetting.respond_to?(:media_gallery_playback_overlay_font_size_px) ? SiteSetting.media_gallery_playback_overlay_font_size_px.to_i : 14
      n = 14 if n <= 0
      [[n, 10].max, 28].min
    rescue
      14
    end

    def move_interval_seconds_for(media_type)
      key = media_type.to_s == "image" ? :media_gallery_playback_overlay_image_move_interval_seconds : :media_gallery_playback_overlay_move_interval_seconds
      default_value = media_type.to_s == "image" ? 0 : 18
      n = SiteSetting.respond_to?(key) ? SiteSetting.public_send(key).to_i : default_value
      return 0 if n <= 0
      [[n, 5].max, 300].min
    rescue
      default_value
    end

    def show_username_for?(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_video_show_username) && SiteSetting.media_gallery_playback_overlay_video_show_username
      when "image"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_image_show_username) && SiteSetting.media_gallery_playback_overlay_image_show_username
      else
        false
      end
    rescue
      false
    end

    def show_timestamp_for?(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_video_show_timestamp) && SiteSetting.media_gallery_playback_overlay_video_show_timestamp
      when "image"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_image_show_timestamp) && SiteSetting.media_gallery_playback_overlay_image_show_timestamp
      else
        false
      end
    rescue
      false
    end

    def show_session_code_for?(media_type)
      case media_type.to_s
      when "video"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_video_show_session_code) && SiteSetting.media_gallery_playback_overlay_video_show_session_code
      when "image"
        SiteSetting.respond_to?(:media_gallery_playback_overlay_image_show_session_code) && SiteSetting.media_gallery_playback_overlay_image_show_session_code
      else
        false
      end
    rescue
      false
    end

    def rendered_text_for(media_type:, user:, code: nil)
      parts = []
      parts << overlay_display_name(user) if show_username_for?(media_type)
      parts << Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC") if show_timestamp_for?(media_type)
      parts << code.to_s if show_session_code_for?(media_type) && code.present?
      parts.reject(&:blank?).join(" · ")
    end

    def overlay_display_name(user)
      user&.name.to_s.strip.presence || user&.username.to_s.strip
    end

    def create_record!(media_item:, user:, request:, token:, media_type:, fingerprint_id:, overlay_code:, rendered_text:)
      ::MediaGallery::MediaOverlaySession.create!(
        media_item_id: media_item.id,
        user_id: user.id,
        overlay_code: overlay_code,
        media_type: media_type,
        fingerprint_id: fingerprint_id.to_s.presence,
        token_sha256: token_sha256(token),
        rendered_text: rendered_text,
        ip: request&.remote_ip.to_s.presence,
        user_agent: request&.user_agent.to_s.presence
      )
    end

    def update_existing_record!(record, token:, request:, fingerprint_id:, rendered_text:)
      attrs = {
        token_sha256: token_sha256(token),
        rendered_text: rendered_text,
        ip: request&.remote_ip.to_s.presence,
        user_agent: request&.user_agent.to_s.presence,
        updated_at: Time.now
      }
      attrs[:fingerprint_id] = fingerprint_id.to_s.presence if fingerprint_id.present?
      record.update_columns(attrs)
      record
    rescue => e
      Rails.logger.warn("[media_gallery] playback overlay reuse update failed id=#{record&.id} error=#{e.class}: #{e.message}")
      record
    end

    def find_reusable_record(code:, media_item:, user:)
      return nil unless overlay_table_present?
      ::MediaGallery::MediaOverlaySession.where(
        overlay_code: normalize_code(code),
        media_item_id: media_item.id,
        user_id: user.id
      ).order(updated_at: :desc, created_at: :desc).first
    rescue
      nil
    end

    def unique_overlay_code(length: 6)
      raise "overlay_session_table_missing" unless overlay_table_present?

      10.times do
        code = Array.new(length) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
        next if ::MediaGallery::MediaOverlaySession.exists?(overlay_code: code)
        return code
      end

      SecureRandom.hex(4).upcase
    end

    def normalize_code(code)
      code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end

    def token_sha256(token)
      return nil if token.to_s.blank?
      Digest::SHA256.hexdigest(token.to_s)
    end

    def parse_position_entry(entry)
      raw = entry.to_s.strip
      return nil if raw.blank?

      pattern = /\A(?<key>#{VALID_POSITIONS.join("|")})(?:\s*(?<offset>[+-]\s*\d+)\s*(?:px)?)?\z/i
      match = raw.match(pattern)
      return nil unless match

      key = match[:key].to_s.downcase
      offset = match[:offset].to_s.gsub(/\s+/, "")
      {
        key: key,
        offset_y_px: offset.present? ? offset.to_i : 0,
        raw: raw
      }
    end

    def parsed_default_positions
      DEFAULT_POSITIONS.map { |entry| parse_position_entry(entry) }.compact
    end

    def dedupe_position_entries(entries)
      seen = {}
      entries.each_with_object([]) do |entry, ary|
        fingerprint = [entry[:key].to_s, entry[:offset_y_px].to_i]
        next if seen[fingerprint]
        seen[fingerprint] = true
        ary << entry
      end
    end

    def normalize_list(raw)
      case raw
      when Array
        raw
      else
        raw.to_s.split("|")
      end
    end
  end
end
