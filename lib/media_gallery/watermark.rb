# frozen_string_literal: true

require "json"

module MediaGallery
  class Watermark
    # Defaults (kept close to the previous behavior)
    DEFAULT_OPACITY = 0.35
    DEFAULT_MARGIN = 24
    DEFAULT_POSITION = "bottom_right"
    DEFAULT_SIZE_FRAC = 0.045

    # --- Global settings (admin-friendly) ---

    def self.global_position
      if SiteSetting.respond_to?(:media_gallery_watermark_position)
        SiteSetting.media_gallery_watermark_position.to_s.presence || DEFAULT_POSITION
      else
        DEFAULT_POSITION
      end
    end

    def self.global_margin_px
      if SiteSetting.respond_to?(:media_gallery_watermark_margin_px)
        n = SiteSetting.media_gallery_watermark_margin_px.to_i
        n = 0 if n.negative?
        [n, 200].min
      else
        DEFAULT_MARGIN
      end
    end

    def self.global_opacity_percent
      if SiteSetting.respond_to?(:media_gallery_watermark_opacity_percent)
        n = SiteSetting.media_gallery_watermark_opacity_percent.to_f
        n = (DEFAULT_OPACITY * 100.0) if n <= 0
        n = 100.0 if n > 100.0
        n
      else
        (DEFAULT_OPACITY * 100.0)
      end
    end

    def self.global_size_percent
      if SiteSetting.respond_to?(:media_gallery_watermark_size_percent)
        n = SiteSetting.media_gallery_watermark_size_percent.to_f
        n = (DEFAULT_SIZE_FRAC * 100.0) if n <= 0
        n = 30.0 if n > 30.0
        n
      else
        (DEFAULT_SIZE_FRAC * 100.0)
      end
    end

    def self.global_size_frac
      (global_size_percent.to_f / 100.0)
    end

    # --- Choice list (tags-like) ---

    def self.choices
      return [] unless SiteSetting.respond_to?(:media_gallery_watermark_choices)

      raw = SiteSetting.media_gallery_watermark_choices
      arr = raw.is_a?(Array) ? raw : raw.to_s.split("|")

      arr
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .map { |s| s[0, 500] }
        .uniq
    end

    def self.choice_allowed?(candidate)
      c = candidate.to_s.strip
      return false if c.blank?

      list = choices
      return list.include?(c) if list.present?

      # Backwards compatibility: allow old preset IDs if presets are still configured.
      find_preset(c).present?
    end

    def self.safe_choices_for_client(user:)
      list = choices
      return safe_presets_for_client if list.blank?

      list.map do |tpl|
        {
          value: tpl,
          label: render_template(tpl, user: user, for_display: true),
        }
      end
    end

    def self.default_choice_for_client(user:)
      list = choices
      return nil if list.blank?

      tpl = list.first
      {
        value: tpl,
        label: render_template(tpl, user: user, for_display: true),
      }
    end

    # --- Template rendering (placeholders) ---

    # Supported placeholders:
    #  - {{username}}  => uploader username
    #  - {{user_id}}   => uploader id
    # Legacy (kept):
    #  - @username     => @<username>
    #  - @user_id      => @<id>
    def self.render_template(template, item: nil, user: nil, for_display: false)
      s = template.to_s

      u = user || item&.user
      username = u&.username.to_s
      user_id = (u&.id || item&.user_id).to_s

      # If we're rendering for display and we can't resolve a user, use friendly placeholders.
      display_username = username.presence || (for_display ? "username" : "")
      display_user_id = user_id.presence || (for_display ? "user_id" : "")

      replacements = {
        "{{username}}" => display_username,
        "{{user_id}}" => display_user_id,
        "@username" => (display_username.present? ? "@#{display_username}" : ""),
        "@user_id" => (display_user_id.present? ? "@#{display_user_id}" : ""),
      }

      replacements.each { |ph, val| s = s.gsub(ph, val) }
      s = s.gsub(/\s+/, " ").strip
      s[0, 500]
    end

    def self.text_for_item(item)
      # 1) Item-selected option
      tpl = nil
      chosen = item.respond_to?(:watermark_preset_id) ? item.watermark_preset_id.to_s.strip : ""

      if chosen.present?
        # a) Legacy preset id
        if (preset = find_preset(chosen)).present?
          tpl = preset[:template].presence
        end

        # b) New list mode stores the template directly
        tpl ||= chosen if choices.include?(chosen)
      end

      # 2) Default choice = first item in list
      tpl ||= choices.first

      # 3) Legacy default preset id
      if tpl.blank? && SiteSetting.respond_to?(:media_gallery_watermark_default_preset_id)
        default_id = SiteSetting.media_gallery_watermark_default_preset_id.to_s.strip
        tpl = find_preset(default_id)&.dig(:template) if default_id.present?
      end

      # 4) Fallback text
      if tpl.blank? && SiteSetting.respond_to?(:media_gallery_watermark_default_text)
        tpl = SiteSetting.media_gallery_watermark_default_text.to_s
      end

      render_template(tpl.to_s, item: item)
    end

    # --- ffmpeg drawtext filter ---

    # Returns ffmpeg -vf fragment: "drawtext=..."
    def self.vf_for(item:, tmpdir:)
      return nil unless SiteSetting.media_gallery_watermark_enabled
      return nil if item.blank?

      mt = item.media_type.to_s
      return nil unless mt == "video" || mt == "image"

      enabled = item.respond_to?(:watermark_enabled) ? !!item.watermark_enabled : false
      return nil unless enabled

      text = text_for_item(item)
      return nil if text.blank?

      # Determine whether we should honor legacy per-preset overrides.
      preset = nil
      chosen = item.respond_to?(:watermark_preset_id) ? item.watermark_preset_id.to_s.strip : ""
      preset = find_preset(chosen) if chosen.present?
      use_preset_overrides = preset.present? && choices.blank?

      pos = (use_preset_overrides && preset[:position].present?) ? preset[:position].to_s : global_position
      margin = (use_preset_overrides && preset[:margin].present?) ? preset[:margin].to_i : global_margin_px

      opacity =
        if use_preset_overrides && preset[:opacity].present?
          preset[:opacity].to_f
        else
          (global_opacity_percent.to_f / 100.0)
        end
      opacity = DEFAULT_OPACITY if opacity <= 0 || opacity > 1

      size_setting = use_preset_overrides ? preset[:size] : nil
      fontsize = effective_fontsize(item: item, text: text, size_setting: size_setting, margin: margin)

      x_expr, y_expr = position_expr(pos, margin)

      text_file = File.join(tmpdir, "watermark-#{item.public_id}.txt")
      File.write(text_file, text + "\n")

      # NOTE: ffmpeg filter syntax is "drawtext=<options>", not "drawtext:<options>".
      # Using a colon directly after the filter name makes ffmpeg interpret it as part of the
      # filter name, resulting in: "No such filter: 'drawtext:textfile'".
      opts = []
      fontfile = pick_font_file
      opts << "fontfile=#{escape_filter_path(fontfile)}" if fontfile.present?
      opts << "textfile=#{escape_filter_path(text_file)}"
      opts << "reload=1"
      opts << "fontcolor=white@#{format("%.2f", opacity)}"
      opts << "fontsize=#{fontsize}"
      opts << "x=#{x_expr}"
      opts << "y=#{y_expr}"
      opts << "shadowcolor=black@0.4"
      opts << "shadowx=2"
      opts << "shadowy=2"

      "drawtext=#{opts.join(":")}"
    rescue => e
      Rails.logger.warn("[media_gallery] watermark build failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def self.effective_fontsize(item:, text:, size_setting:, margin:)
      # Legacy path: size can be a fraction (<= 2) or a fixed px (> 2)
      if !size_setting.nil?
        n = size_setting.to_f
        return fontsize_expr(n)
      end

      # New path: use global % of height, but clamp so it cannot exceed the frame.
      w = item.respond_to?(:width) ? item.width.to_i : 0
      h = item.respond_to?(:height) ? item.height.to_i : 0

      frac = global_size_frac
      return "h*#{frac}" if w <= 0 || h <= 0

      desired = (h * frac).to_f

      # Rough width estimate: average glyph width ~0.6em for sans fonts.
      # We count non-space characters to avoid extreme shrink for multi-word texts.
      chars = text.to_s.gsub(/\s+/, "").length
      chars = 1 if chars <= 0

      m = margin.to_i
      m = 0 if m.negative?
      max_w = (w - (2 * m)).to_f
      max_h = (h - (2 * m)).to_f
      max_w = 50.0 if max_w < 50.0
      max_h = 50.0 if max_h < 50.0

      max_by_w = max_w / (0.60 * chars)
      max_by_h = max_h

      px = [desired, max_by_w, max_by_h].min
      px = px.floor
      # Allow small sizes so the watermark can always fit within the frame.
      px = 4 if px < 4
      px = 200 if px > 200
      px.to_s
    end

    def self.escape_filter_path(path)
      s = path.to_s
      s = s.gsub("\\", "\\\\")
      s = s.gsub(":", "\\:")
      # Comma separates filters in a filterchain; keep it safe.
      s = s.gsub(",", "\\,")
      s = s.gsub("'", "\\\\'")
      s
    end

    def self.pick_font_file
      candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
      ]
      candidates.find { |p| File.exist?(p) }
    end

    def self.fontsize_expr(n)
      return "h*#{DEFAULT_SIZE_FRAC}" if n <= 0

      if n <= 2
        n = [[n, 0.01].max, 0.2].min
        return "h*#{n}"
      end

      px = n.to_i
      px = 12 if px < 12
      px = 200 if px > 200
      px.to_s
    end

    def self.position_expr(pos, margin)
      m = margin.to_i
      m = 0 if m.negative?

      case pos.to_s
      when "bottom_left"
        ["#{m}", "h-th-#{m}"]
      when "top_left"
        ["#{m}", "#{m}"]
      when "top_right"
        ["w-tw-#{m}", "#{m}"]
      when "top_center"
        ["(w-tw)/2", "#{m}"]
      when "bottom_center"
        ["(w-tw)/2", "h-th-#{m}"]
      when "center"
        ["(w-tw)/2", "(h-th)/2"]
      else
        ["w-tw-#{m}", "h-th-#{m}"]
      end
    end

    # --- Legacy presets (JSON) ---

    def self.presets
      return {} unless SiteSetting.respond_to?(:media_gallery_watermark_presets)

      raw = SiteSetting.media_gallery_watermark_presets.to_s
      arr = JSON.parse(raw)
      arr = [] unless arr.is_a?(Array)
      out = {}

      arr.each do |p|
        next unless p.is_a?(Hash)
        id = p["id"].to_s.strip
        next if id.blank?
        next unless id.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)

        label = p["label"].to_s.strip
        label = id if label.blank?

        template = p["template"].to_s[0, 500]

        out[id] = {
          id: id,
          label: label[0, 120],
          template: template,
          position: p["position"].to_s.strip.presence,
          opacity: p["opacity"],
          size: p["size"],
          margin: p["margin"],
        }
      end

      out
    rescue => e
      Rails.logger.warn("[media_gallery] watermark presets parse failed: #{e.class}: #{e.message}")
      {}
    end

    def self.safe_presets_for_client
      presets.values.map { |p| { id: p[:id], label: p[:label] } }.sort_by { |p| p[:label].to_s.downcase }
    end

    def self.find_preset(id)
      return nil if id.blank?
      presets[id.to_s]
    end
  end
end
