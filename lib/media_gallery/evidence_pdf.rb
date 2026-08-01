# frozen_string_literal: true

module ::MediaGallery
  class EvidencePdf
    PAGE_WIDTH = 595
    PAGE_HEIGHT = 842
    MARGIN_X = 48
    TOP_Y = 794
    BOTTOM_Y = 48
    BODY_SIZE = 9.5
    LEADING = 13
    MAX_LINE_CHARS = 92

    def initialize(title:, subtitle:, status:, generated_at:, sections:, footer: nil)
      @title = clean(title)
      @subtitle = clean(subtitle)
      @status = clean(status)
      @generated_at = generated_at.utc
      @sections = Array(sections)
      @footer = clean(footer.presence || "Technical evidence report - generated in UTC")
    end

    def render
      pages = layout_pages
      build_pdf(pages)
    end

    private

    def layout_pages
      pages = []
      current = []
      y = TOP_Y

      add_header(current, y)
      y -= 82

      @sections.each do |section|
        heading = clean(section[:heading] || section["heading"])
        lines = normalize_lines(section[:lines] || section["lines"])
        estimated = 24 + ([lines.length, 1].max * LEADING)
        if y - estimated < BOTTOM_Y
          pages << current
          current = []
          y = TOP_Y
          add_continuation_header(current, y)
          y -= 42
        end

        current << text_command(MARGIN_X, y, heading, size: 12, bold: true)
        y -= 19
        lines.each do |line|
          wrapped_lines(line).each do |wrapped|
            if y < BOTTOM_Y + 18
              pages << current
              current = []
              y = TOP_Y
              add_continuation_header(current, y)
              y -= 42
            end
            current << text_command(MARGIN_X, y, wrapped, size: BODY_SIZE)
            y -= LEADING
          end
        end
        y -= 9
      end

      pages << current
      pages.each_with_index do |commands, index|
        commands << text_command(MARGIN_X, 27, @footer, size: 7.5)
        commands << text_command(PAGE_WIDTH - 108, 27, "Page #{index + 1} of #{pages.length}", size: 7.5)
        commands.unshift(draft_watermark) if @status.upcase.include?("DRAFT")
      end
      pages
    end

    def add_header(commands, y)
      commands << text_command(MARGIN_X, y, @title, size: 18, bold: true)
      commands << text_command(MARGIN_X, y - 25, @subtitle, size: 10)
      commands << text_command(MARGIN_X, y - 47, "Status: #{@status}", size: 9, bold: true)
      commands << text_command(MARGIN_X + 220, y - 47, "Generated: #{@generated_at.iso8601(6)}", size: 9)
      commands << line_command(MARGIN_X, y - 59, PAGE_WIDTH - MARGIN_X, y - 59)
    end

    def add_continuation_header(commands, y)
      commands << text_command(MARGIN_X, y, @title, size: 11, bold: true)
      commands << text_command(PAGE_WIDTH - 185, y, "#{@status} - continued", size: 8)
      commands << line_command(MARGIN_X, y - 12, PAGE_WIDTH - MARGIN_X, y - 12)
    end

    def normalize_lines(lines)
      Array(lines).flat_map do |line|
        case line
        when Hash
          line.map { |key, value| "#{clean(key)}: #{clean(format_value(value))}" }
        else
          clean(format_value(line)).split("\n", -1)
        end
      end
    end

    def format_value(value)
      case value
      when nil then "Not available"
      when TrueClass then "Yes"
      when FalseClass then "No"
      when Array then value.map { |item| format_value(item) }.join(", ")
      when Hash then ::MediaGallery::EvidenceReference.canonical_json(value)
      else value.to_s
      end
    end

    def wrapped_lines(text)
      value = clean(text)
      return [""] if value.blank?

      value.split(/\s+/).each_with_object([""]) do |word, rows|
        if rows.last.empty?
          rows[-1] = word
        elsif rows.last.length + word.length + 1 <= MAX_LINE_CHARS
          rows[-1] = "#{rows.last} #{word}"
        elsif word.length > MAX_LINE_CHARS
          chunks = word.scan(/.{1,#{MAX_LINE_CHARS}}/)
          rows << chunks.shift
          rows.concat(chunks)
        else
          rows << word
        end
      end
    end

    def clean(value)
      ::MediaGallery::EvidenceReference.ascii_text(value.to_s).gsub(/[\r\t]+/, " ").gsub(/ +/, " ").strip
    end

    def escape_pdf_text(value)
      clean(value).gsub("\\", "\\\\").gsub("(", "\\(").gsub(")", "\\)")
    end

    def text_command(x, y, text, size:, bold: false)
      font = bold ? "F2" : "F1"
      "BT /#{font} #{format_number(size)} Tf 1 0 0 1 #{x} #{y} Tm (#{escape_pdf_text(text)}) Tj ET\n"
    end

    def line_command(x1, y1, x2, y2)
      "0.6 w #{x1} #{y1} m #{x2} #{y2} l S\n"
    end

    def draft_watermark
      "q 0.88 g BT /F2 58 Tf 0.707 0.707 -0.707 0.707 130 330 Tm (DRAFT - NOT FINAL) Tj ET Q\n"
    end

    def format_number(value)
      value.to_f == value.to_i ? value.to_i.to_s : format("%.2f", value)
    end

    def build_pdf(page_commands)
      objects = []
      font_regular_id = add_object(objects, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
      font_bold_id = add_object(objects, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")
      pages_id = objects.length + 1
      add_object(objects, "PAGES_PLACEHOLDER")

      page_ids = page_commands.map do |commands|
        stream = commands.join
        content_id = add_object(objects, "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream")
        add_object(
          objects,
          "<< /Type /Page /Parent #{pages_id} 0 R /MediaBox [0 0 #{PAGE_WIDTH} #{PAGE_HEIGHT}] " \
          "/Resources << /Font << /F1 #{font_regular_id} 0 R /F2 #{font_bold_id} 0 R >> >> " \
          "/Contents #{content_id} 0 R >>",
        )
      end

      objects[pages_id - 1] = "<< /Type /Pages /Kids [#{page_ids.map { |id| "#{id} 0 R" }.join(" ")}] /Count #{page_ids.length} >>"
      catalog_id = add_object(objects, "<< /Type /Catalog /Pages #{pages_id} 0 R >>")
      info_id = add_object(
        objects,
        "<< /Title (#{escape_pdf_text(@title)}) /Subject (Forensic technical evidence report) " \
        "/Creator (Discourse Media Library Evidence Reporter 1.1.0) /Producer (Built-in deterministic PDF writer) " \
        "/CreationDate (D:#{@generated_at.strftime("%Y%m%d%H%M%SZ")}) >>",
      )

      output = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
      offsets = [0]
      objects.each_with_index do |object, index|
        offsets << output.bytesize
        output << "#{index + 1} 0 obj\n#{object}\nendobj\n".b
      end
      xref_offset = output.bytesize
      output << "xref\n0 #{objects.length + 1}\n".b
      output << "0000000000 65535 f \n".b
      offsets.drop(1).each { |offset| output << format("%010d 00000 n \n", offset).b }
      output << "trailer\n<< /Size #{objects.length + 1} /Root #{catalog_id} 0 R /Info #{info_id} 0 R >>\n".b
      output << "startxref\n#{xref_offset}\n%%EOF\n".b
      output
    end

    def add_object(objects, body)
      objects << body.to_s.b
      objects.length
    end
  end
end
