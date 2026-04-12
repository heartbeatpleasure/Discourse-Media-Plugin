# frozen_string_literal: true

module ::MediaGallery
  module TextSanitizer
    module_function

    DEFAULT_TAG_MAX_LENGTH = 40

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

    def tag(value, max_length: DEFAULT_TAG_MAX_LENGTH)
      text = plain_text(value, max_length: max_length, allow_newlines: false)
      text = text.tr(",", " ")
      text = text.gsub(/\s+/, " ").strip.downcase
      text.presence
    rescue
      nil
    end

    def tag_list(values, max_count:, max_length: DEFAULT_TAG_MAX_LENGTH, allowed: nil)
      raw = values
      raw = raw.split(",") if raw.is_a?(String)

      out = []
      seen = {}
      allowed_map = nil

      if allowed.present?
        allowed_map = {}
        Array(allowed).each do |candidate|
          normalized = tag(candidate, max_length: max_length)
          next if normalized.blank?
          allowed_map[normalized] ||= normalized
        end
      end

      Array(raw).each do |value|
        normalized = tag(value, max_length: max_length)
        next if normalized.blank?
        next if allowed_map && !allowed_map.key?(normalized)

        canonical = allowed_map ? allowed_map[normalized] : normalized
        key = canonical.downcase
        next if seen[key]

        out << canonical
        seen[key] = true
        break if max_count.to_i.positive? && out.length >= max_count.to_i
      end

      out
    rescue
      []
    end
  end
end
