# frozen_string_literal: true

require "json"

module MediaGallery
  class Watermark
    DEFAULT_OPACITY = 0.35
    DEFAULT_MARGIN = 24
    DEFAULT_POSITION = "bottom_right"
    DEFAULT_SIZE_FRAC = 0.045

    PLACEHOLDERS = {
      "@username" => ->(item) { item&.user&.username.to_s },
      "@user_id" => ->(item) { item&.user_id.to_s },
    }.freeze

    def self.presets
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

    def self.text_for_item(item)
      preset = nil
      if item.respond_to?(:watermark_preset_id) && item.watermark_preset_id.present?
        preset = find_preset(item.watermark_preset_id)
      end

      if preset.blank?
        default_id = SiteSetting.media_gallery_watermark_default_preset_id.to_s.strip
        preset = find_preset(default_id) if default_id.present?
      end

      template = preset&.dig(:template).presence || SiteSetting.media_gallery_watermark_default_text.to_s
      s = template.to_s

      PLACEHOLDERS.each { |ph, fn| s = s.gsub(ph, fn.call(item)) }
      s = s.gsub(/\s+/, " ").strip
      s[0, 500]
    end

    # Returns ffmpeg -vf fragment: "drawtext=..."
    def self.vf_for(item:, tmpdir:)
      return nil unless SiteSetting.media_gallery_watermark_enabled
      return nil if item.blank?
      return nil unless item.media_type.to_s == "video"

      enabled = item.respond_to?(:watermark_enabled) ? !!item.watermark_enabled : false
      return nil unless enabled

      text = text_for_item(item)
      return nil if text.blank?

      preset = nil
      if item.respond_to?(:watermark_preset_id) && item.watermark_preset_id.present?
        preset = find_preset(item.watermark_preset_id)
      end
      if preset.blank?
        default_id = SiteSetting.media_gallery_watermark_default_preset_id.to_s.strip
        preset = find_preset(default_id) if default_id.present?
      end

      pos = (preset&.dig(:position) || DEFAULT_POSITION).to_s
      margin = (preset&.dig(:margin) || DEFAULT_MARGIN).to_i
      opacity = preset&.dig(:opacity).to_f
      opacity = DEFAULT_OPACITY if opacity <= 0 || opacity > 1

      fontsize = fontsize_expr(preset&.dig(:size))
      x_expr, y_expr = position_expr(pos, margin)

      text_file = File.join(tmpdir, "watermark-#{item.public_id}.txt")
      File.write(text_file, text + "\n")

      parts = ["drawtext"]
      fontfile = pick_font_file
      parts << "fontfile=#{escape_filter_path(fontfile)}" if fontfile.present?
      parts << "textfile=#{escape_filter_path(text_file)}"
      parts << "reload=1"
      parts << "fontcolor=white@#{format("%.2f", opacity)}"
      parts << "fontsize=#{fontsize}"
      parts << "x=#{x_expr}"
      parts << "y=#{y_expr}"
      parts << "shadowcolor=black@0.4"
      parts << "shadowx=2"
      parts << "shadowy=2"
      parts.join(":")
    rescue => e
      Rails.logger.warn("[media_gallery] watermark build failed item_id=#{item&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def self.escape_filter_path(path)
      s = path.to_s
      s = s.gsub("\\", "\\\\")
      s = s.gsub(":", "\\:")
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

    def self.fontsize_expr(size)
      return "h*#{DEFAULT_SIZE_FRAC}" if size.nil?
      n = size.to_f
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
      m = DEFAULT_MARGIN if m <= 0

      case pos
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
  end
end
