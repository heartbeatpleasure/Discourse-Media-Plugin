# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module ::MediaGallery
  module PrivateStorage
    module_function

    # When enabled, processed media + thumbnails are stored outside /uploads (not publicly guessable)
    # and streamed via /media/stream/:token only.
    def enabled?
      SiteSetting.respond_to?(:media_gallery_private_storage_enabled) && SiteSetting.media_gallery_private_storage_enabled
    end

    def private_root
      p = SiteSetting.media_gallery_private_root_path.to_s.strip
      p = "/shared/media_gallery/private" if p.blank?
      p
    end

    def originals_root
      p = SiteSetting.media_gallery_original_export_root_path.to_s.strip
      p = "/shared/media_gallery/original_export" if p.blank?
      p
    end

    # 0 => delete immediately (no export)
    def original_retention_hours
      (SiteSetting.media_gallery_original_retention_hours.to_i rescue 0)
    end

    def item_private_dir(public_id)
      File.join(private_root, public_id.to_s)
    end

    def item_original_dir(public_id)
      File.join(originals_root, public_id.to_s)
    end

    def ensure_dir!(path)
      FileUtils.mkdir_p(path)
    end

    def processed_ext_for_type(media_type)
      case media_type.to_s
      when "video" then "mp4"
      when "audio" then "mp3"
      when "image" then "jpg"
      else "bin"
      end
    end

    def processed_rel_path(item)
      ext = processed_ext_for_type(item.media_type)
      File.join(item.public_id.to_s, "main.#{ext}")
    end

    def thumbnail_rel_path(item)
      File.join(item.public_id.to_s, "thumb.jpg")
    end

    def processed_abs_path(item)
      File.join(private_root, processed_rel_path(item))
    end

    def thumbnail_abs_path(item)
      File.join(private_root, thumbnail_rel_path(item))
    end

    def export_original!(item:, source_path:, original_filename:, extension:)
      hours = original_retention_hours
      return nil if hours <= 0

      dir = item_original_dir(item.public_id)
      ensure_dir!(dir)

      ext = extension.to_s.downcase
      ext = "bin" if ext.blank?
      export_path = File.join(dir, "original.#{ext}")
      meta_path = File.join(dir, "meta.json")
      complete_path = File.join(dir, ".complete")

      FileUtils.cp(source_path, export_path)

      meta = {
        "public_id" => item.public_id,
        "media_item_id" => item.id,
        "original_filename" => original_filename.to_s,
        "original_extension" => ext,
        "exported_at" => Time.now.utc.iso8601
      }
      File.write(meta_path, JSON.pretty_generate(meta))
      File.write(complete_path, Time.now.utc.iso8601)

      export_path
    end

    def cleanup_exported_originals!
      hours = original_retention_hours
      return if hours <= 0

      root = originals_root
      return if root.blank? || !Dir.exist?(root)

      cutoff = Time.now - hours.hours

      Dir.glob(File.join(root, "*")).each do |dir|
        next unless File.directory?(dir)
        complete = File.join(dir, ".complete")
        next unless File.exist?(complete)

        begin
          age = File.mtime(complete)
        rescue
          age = File.mtime(dir)
        end

        next if age > cutoff
        FileUtils.rm_rf(dir)
      end
    end
  end
end
