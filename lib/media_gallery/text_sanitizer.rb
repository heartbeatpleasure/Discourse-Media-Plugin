# frozen_string_literal: true

module ::MediaGallery
  module TextSanitizer
    module_function

    def plain_text(value, max_length:, allow_newlines: false)
      text = value.to_s.dup
      text = text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      text = text.unicode_normalize(:nfkc) if text.respond_to?(:unicode_normalize)
      text = ActionController::Base.helpers.strip_tags(text)
      text = text.gsub("\r\n", "\n").gsub("\r", "\n")

      if allow_newlines
        text = text.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, "")
        text = text.gsub(/[\t ]+/, " ")
        text = text.gsub(/\n{3,}/, "\n\n")
      else
        text = text.gsub(/[\u0000-\u001F\u007F]/, " ")
        text = text.gsub(/\s+/, " ")
      end

      text = text.strip
      text = text.mb_chars.limit(max_length).to_s if max_length.to_i.positive?
      text
    rescue
      value.to_s[0, max_length.to_i]
    end

    def search_query(value, max_length: 200)
      plain_text(value, max_length: max_length, allow_newlines: false)
    end
  end
end
