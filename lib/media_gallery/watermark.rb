# frozen_string_literal: true

require "json"
require "open3"

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

      text_file = File.join(tmpdir, "watermark-#{item.public_id}.txt")
      File.write(text_file, text + "\n")

      fontfile = pick_font_file
      fontsize = effective_fontsize(
        item: item,
        text: text,
        size_setting: size_setting,
        margin: margin,
        text_file: text_file,
        fontfile: fontfile
      )

      x_expr, y_expr = position_expr(pos, margin)

      # NOTE: ffmpeg filter syntax is "drawtext=<options>", not "drawtext:<options>".
      # Using a colon directly after the filter name makes ffmpeg interpret it as part of the
      # filter name, resulting in: "No such filter: 'drawtext:textfile'".
      opts = []
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

    def self.effective_fontsize(item:, text:, size_setting:, margin:, text_file: nil, fontfile: nil)
      # The configured size is treated as the *desired* size, but we will scale down
      # if the watermark would not fit inside the frame.
      #
      # Key goals:
      #  - If it already fits, keep the configured size EXACTLY (no accidental shrinking).
      #  - Only shrink when it truly overflows.
      #
      # We do a cheap heuristic first. Only when that heuristic indicates we would shrink,
      # we optionally do a tiny 1-frame ffmpeg "preflight" on a blank canvas to measure the
      # actual rendered text bounds. This avoids false positives caused by conservative
      # text-width estimates.

      w = item.respond_to?(:width) ? item.width.to_i : 0
      h = item.respond_to?(:height) ? item.height.to_i : 0

      # Clamp against expected OUTPUT dimensions (the pipeline scales before drawtext).
      out_w, out_h = expected_output_dims(media_type: item&.media_type.to_s, in_w: w, in_h: h)

      # If we can't determine dimensions reliably, fall back to legacy behavior.
      if out_w <= 0 || out_h <= 0
        n = size_setting.to_f if !size_setting.nil?
        return size_setting.nil? ? "h*#{global_size_frac}" : fontsize_expr(n)
      end

      # Reference dimension for "size percent": use the LONG SIDE so portrait and landscape
      # can share the same visual scale (both have a 1920-long side in our Full HD policy).
      ref = [out_w, out_h].max.to_f

      desired_px = desired_font_px(ref: ref, size_setting: size_setting)
      desired_px = (ref * global_size_frac).to_f if desired_px <= 0

      desired_i = desired_px.floor
      desired_i = 4 if desired_i < 4
      desired_i = 300 if desired_i > 300

      m = margin.to_i
      m = 0 if m.negative?

      max_w = (out_w - (2 * m)).to_f
      max_h = (out_h - (2 * m)).to_f
      max_w = 50.0 if max_w < 50.0
      max_h = 50.0 if max_h < 50.0

      lines = text_lines(text)
      line_count = [lines.length, 1].max
      longest_units = lines.map { |ln| text_units(ln) }.max
      longest_units = 1.0 if longest_units.to_f <= 0

      # Heuristic estimates. Keep these slightly optimistic; the preflight (below) is our
      # correctness check when we would otherwise shrink.
      avg_glyph_em = 0.62
      line_height = 1.20

      max_by_w = max_w / (avg_glyph_em * longest_units)
      max_by_h = max_h / (line_height * line_count)

      heuristic_px = [desired_i.to_f, max_by_w, max_by_h].min.floor
      heuristic_px = 4 if heuristic_px < 4
      heuristic_px = 300 if heuristic_px > 300

      # If heuristic says it fits, keep the desired size exactly.
      return desired_i.to_s if heuristic_px >= desired_i

      # Only when we would shrink: try an ffmpeg preflight to confirm whether it truly overflows.
      if text_file.present?
        bbox = measure_text_bbox(out_w: out_w, out_h: out_h, text_file: text_file, fontfile: fontfile, fontsize_px: desired_i)
        if bbox.present?
          tw, th = bbox
          if tw.to_i <= max_w && th.to_i <= max_h
            return desired_i.to_s
          end

          scale = [max_w / tw.to_f, max_h / th.to_f].min
          px = (desired_i.to_f * scale * 0.98).floor
          px = 4 if px < 4
          px = 300 if px > 300
          return px.to_s
        end
      end

      # If preflight fails, fall back to heuristic clamp.
      heuristic_px.to_s
    end

    def self.measure_text_bbox(out_w:, out_h:, text_file:, fontfile:, fontsize_px:)
      return nil if out_w.to_i <= 0 || out_h.to_i <= 0
      return nil if fontsize_px.to_i <= 0
      return nil if text_file.blank?

      opts = []
      opts << "fontfile=#{escape_filter_path(fontfile)}" if fontfile.present?
      opts << "textfile=#{escape_filter_path(text_file)}"
      opts << "reload=1"
      opts << "fontcolor=white@1.0"
      opts << "fontsize=#{fontsize_px.to_i}"
      opts << "x=0"
      opts << "y=0"
      opts << "shadowcolor=black@0.4"
      opts << "shadowx=2"
      opts << "shadowy=2"

      vf = "drawtext=#{opts.join(':')},cropdetect=24:16:0"

      cmd = [
        MediaGallery::Ffmpeg.ffmpeg_path,
        "-hide_banner",
        "-nostats",
        "-loglevel",
        "info",
        "-f",
        "lavfi",
        "-i",
        "color=c=black:s=#{out_w}x#{out_h}:r=1:d=0.1",
        "-vf",
        vf,
        "-frames:v",
        "1",
        "-f",
        "null",
        "-",
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      return nil unless status.success?

      crops = stderr.to_s.scan(/crop=(\d+):(\d+):(\d+):(\d+)/)
      return nil if crops.blank?

      w = crops.last[0].to_i
      h = crops.last[1].to_i
      return nil if w <= 0 || h <= 0

      [w, h]
    rescue
      nil
    end


    # Predict the output dimensions of our ffmpeg filterchain so sizing clamps are stable.
    # This mirrors MediaGallery::Ffmpeg.transcode_video/transcode_image_to_jpg.
    def self.expected_output_dims(media_type:, in_w:, in_h:)
      w = in_w.to_i
      h = in_h.to_i
      return [0, 0] if w <= 0 || h <= 0

      # Mirror MediaGallery::Ffmpeg scaling policy:
      #  - landscape/square: fit within 1920x1080
      #  - portrait:         fit within 1080x1920
      if h > w
        max_w = 1080.0
        max_h = 1920.0
      else
        max_w = 1920.0
        max_h = 1080.0
      end

      scale = [max_w / w.to_f, max_h / h.to_f, 1.0].min

      out_w = (w.to_f * scale).floor
      out_h = (h.to_f * scale).floor

      # Video pipeline forces even dimensions (yuv420p/x264 requirement).
      if media_type.to_s == "video"
        out_w = (out_w / 2) * 2
        out_h = (out_h / 2) * 2
      end

      out_w = 2 if out_w < 2
      out_h = 2 if out_h < 2
      [out_w, out_h]
    end

    def self.desired_font_px(ref:, size_setting:)
      if size_setting.nil?
        return (ref * global_size_frac).to_f
      end

      n = size_setting.to_f
      return 0.0 if n <= 0

      # Legacy: fraction of height (<= 2) or fixed px (> 2)
      if n <= 2
        n = [[n, 0.01].max, 0.2].min
        (ref * n).to_f
      else
        n
      end
    end

    # Split watermark text into lines (supports explicit newlines).
    def self.text_lines(text)
      text.to_s
        .split(/\r?\n/)
        .map { |s| s.to_s.strip }
        .reject(&:blank?)
        .presence || ["x"]
    end

    # Estimate "text length" in units where 1.0 roughly corresponds to one average glyph.
    # Spaces are counted as partial width, because they render narrower than letters.
    def self.text_units(line)
      s = line.to_s
      spaces = s.count(" \t")
      non_space = s.gsub(/[\s]/, "").length
      # Count spaces as ~0.35 glyphs and add a small padding for punctuation/kerning.
      (non_space + (spaces * 0.35) + 0.5).to_f
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
