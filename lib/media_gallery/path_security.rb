# frozen_string_literal: true

require "fileutils"

module ::MediaGallery
  # Small, central path helper used by filesystem-backed media features.
  #
  # The plugin stores most paths as relative keys under an operator-configured
  # root. All callers should resolve paths through this helper before reading or
  # deleting files, especially when a path or key originated from params, JSON
  # metadata, or database rows.
  module PathSecurity
    module_function

    COMPONENT_DENYLIST = [".", ".."].freeze

    def normalize_relative_key!(key, allow_blank: false)
      raw = key.to_s.delete("\u0000").tr("\\", "/").sub(%r{\A/+}, "")
      parts = raw.split("/").reject { |part| part.empty? }

      if parts.empty?
        raise ArgumentError, "blank_relative_path" unless allow_blank
        return ""
      end

      if parts.any? { |part| COMPONENT_DENYLIST.include?(part) }
        raise ArgumentError, "unsafe_relative_path"
      end

      parts.join("/")
    end

    def normalize_path_component!(value, name: "path_component")
      component = value.to_s.delete("\u0000")
      if component.empty? || component.include?("/") || component.include?("\\") || COMPONENT_DENYLIST.include?(component)
        raise ArgumentError, "unsafe_#{name}"
      end

      component
    end

    def safe_join!(root, *parts, allow_root: false)
      root_abs = File.expand_path(root.to_s)
      raise ArgumentError, "blank_root" if root_abs.empty?
      raise ArgumentError, "unsafe_root" if root_abs == File::SEPARATOR

      joined = File.expand_path(File.join(root_abs, *parts.map(&:to_s)))
      root_prefix = root_abs.end_with?(File::SEPARATOR) ? root_abs : "#{root_abs}#{File::SEPARATOR}"

      allowed = allow_root ? (joined == root_abs || joined.start_with?(root_prefix)) : joined.start_with?(root_prefix)
      raise ArgumentError, "path_outside_root" unless allowed

      joined
    end

    def realpath_under?(path, root, allow_root: false)
      rp = File.realpath(path.to_s) rescue nil
      rr = File.realpath(root.to_s) rescue nil
      return false if rp.to_s.empty? || rr.to_s.empty?

      prefix = rr.end_with?(File::SEPARATOR) ? rr : "#{rr}#{File::SEPARATOR}"
      allow_root ? (rp == rr || rp.start_with?(prefix)) : rp.start_with?(prefix)
    end

    def assert_realpath_under!(path, root, allow_root: false)
      raise ArgumentError, "path_outside_root" unless realpath_under?(path, root, allow_root: allow_root)

      path.to_s
    end

    def remove_tree_under!(path, root, allow_root: false)
      return false if path.to_s.empty? || root.to_s.empty?
      return false unless File.exist?(path.to_s) || File.symlink?(path.to_s)

      root_abs = File.expand_path(root.to_s)
      path_abs = File.expand_path(path.to_s)
      prefix = root_abs.end_with?(File::SEPARATOR) ? root_abs : "#{root_abs}#{File::SEPARATOR}"
      lexical_ok = allow_root ? (path_abs == root_abs || path_abs.start_with?(prefix)) : path_abs.start_with?(prefix)
      raise ArgumentError, "path_outside_root" unless lexical_ok

      # Catch symlinks or replaced directories that point outside the configured root.
      assert_realpath_under!(path, root, allow_root: allow_root)

      FileUtils.rm_rf(path.to_s)
      true
    end
  end
end
