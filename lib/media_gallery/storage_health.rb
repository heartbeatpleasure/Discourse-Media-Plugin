# frozen_string_literal: true

require "securerandom"
require "tempfile"
require "time"

module ::MediaGallery
  module StorageHealth
    module_function

    PROFILES = %w[active target].freeze

    def health(profile: "active")
      profile = normalize_profile(profile)
      summary = ::MediaGallery::StorageSettingsResolver.profile_summary(profile)
      errors = ::MediaGallery::StorageSettingsResolver.validate_profile(profile)

      result = {
        ok: errors.empty?,
        profile: profile,
        backend: summary[:backend],
        profile_key: summary[:profile_key],
        config: summary[:config],
        validation_errors: errors,
      }

      if summary[:backend].blank?
        result[:available] = false
        result[:availability_error] = "backend_not_configured"
        return result
      end

      begin
        store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile(profile)
        raise "store_not_buildable" if store.blank?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        store.ensure_available!
        finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result[:available] = true
        result[:store_class] = store.class.name
        result[:availability_ms] = ((finished - started) * 1000.0).round(1)
      rescue => e
        result[:available] = false
        result[:availability_error] = "#{e.class}: #{e.message}"
      end

      result[:ok] = result[:ok] && result[:available]
      result
    end

    def probe!(profile: "active")
      profile = normalize_profile(profile)
      store = ::MediaGallery::StorageSettingsResolver.build_store_for_profile(profile)
      raise "store_not_buildable" if store.blank?

      backend = ::MediaGallery::StorageSettingsResolver.profile_backend(profile)
      profile_key = ::MediaGallery::StorageSettingsResolver.profile_key(profile)
      key = probe_key(profile_key)
      marker = "media-gallery-healthcheck:#{SecureRandom.hex(8)}"
      tmp_path = nil
      timings = {}

      begin
        ensure_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        store.ensure_available!
        timings[:ensure_available_ms] = elapsed_ms(ensure_started)

        Tempfile.create(["media-gallery-healthcheck", ".txt"]) do |tmp|
          tmp.binmode
          tmp.write(marker)
          tmp.flush
          tmp_path = tmp.path

          put_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          put_result = store.put_file!(
            tmp.path,
            key: key,
            content_type: "text/plain",
            metadata: {
              "media_gallery_healthcheck" => "1",
              "profile" => profile,
              "profile_key" => profile_key,
            }
          )
          timings[:put_ms] = elapsed_ms(put_started)

          exists_after_put_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          exists_after_put = store.exists?(key)
          timings[:exists_after_put_ms] = elapsed_ms(exists_after_put_started)

          read_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          body = store.read(key)
          timings[:read_ms] = elapsed_ms(read_started)

          delete_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          delete_ok = store.delete(key)
          timings[:delete_ms] = elapsed_ms(delete_started)

          exists_after_delete_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          exists_after_delete = store.exists?(key)
          timings[:exists_after_delete_ms] = elapsed_ms(exists_after_delete_started)

          {
            ok: exists_after_put && body.to_s == marker && delete_ok && !exists_after_delete,
            profile: profile,
            backend: backend,
            profile_key: profile_key,
            key: key,
            uploaded_bytes: put_result[:bytes],
            exists_after_put: exists_after_put,
            read_matches: body.to_s == marker,
            delete_ok: delete_ok,
            exists_after_delete: exists_after_delete,
            note: probe_note_for_backend(backend),
            timings_ms: timings,
          }
        end
      ensure
        begin
          File.delete(tmp_path) if tmp_path.present? && File.exist?(tmp_path)
        rescue
          nil
        end
      end
    rescue => e
      {
        ok: false,
        profile: profile,
        backend: backend,
        profile_key: profile_key,
        key: key,
        error: "#{e.class}: #{e.message}",
        timings_ms: timings,
      }
    end

    def normalize_profile(profile)
      value = profile.to_s.strip
      PROFILES.include?(value) ? value : "active"
    end

    def probe_key(profile_key)
      timestamp = Time.now.utc.strftime("%Y%m%d/%H%M%S")
      token = SecureRandom.hex(6)
      "__healthchecks__/#{profile_key}/#{timestamp}/probe_#{token}.txt"
    end
    private_class_method :probe_key

    def probe_note_for_backend(backend)
      return nil unless backend.to_s == "s3"

      "Current-object delete was verified. Versioned S3 backends may still retain hidden historical versions outside normal object listing."
    end
    private_class_method :probe_note_for_backend

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(1)
    end
    private_class_method :elapsed_ms
  end
end
