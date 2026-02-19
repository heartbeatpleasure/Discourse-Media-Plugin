# frozen_string_literal: true

module ::MediaGallery
  class AdminFingerprintsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    def show
      public_id = params[:public_id].to_s
      item = MediaGallery::MediaItem.find_by(public_id: public_id)
      raise Discourse::NotFound if item.blank?

      conn = ::ActiveRecord::Base.connection

      fingerprints_missing = !conn.data_source_exists?("media_gallery_media_fingerprints")
      sessions_missing = !conn.data_source_exists?("media_gallery_playback_sessions")

      fingerprints =
        if fingerprints_missing
          []
        else
          MediaGallery::MediaFingerprint
            .where(media_item_id: item.id)
            .order(last_seen_at: :desc)
            .limit(200)
        end

      sessions =
        if sessions_missing
          []
        else
          MediaGallery::MediaPlaybackSession
            .where(media_item_id: item.id)
            .order(played_at: :desc, created_at: :desc)
            .limit(500)
        end

      user_ids =
        (
          (fingerprints_missing ? [] : fingerprints.pluck(:user_id)) +
          (sessions_missing ? [] : sessions.pluck(:user_id))
        ).uniq

      users_by_id = ::User.where(id: user_ids).pluck(:id, :username).to_h

      filename =
        item.original_upload&.original_filename.presence ||
        item.processed_upload&.original_filename.presence ||
        item.title

      render_json_dump({
        meta: {
          fingerprints_table_present: !fingerprints_missing,
          playback_sessions_table_present: !sessions_missing,
          migration_hint: (fingerprints_missing || sessions_missing) ? "Run ./launcher rebuild app (or bundle exec rake db:migrate) to create missing tables." : nil
        },
        media_item: {
          id: item.id,
          public_id: item.public_id,
          title: item.title,
          filename: filename
        },
        fingerprints: fingerprints.map { |f|
          {
            user_id: f.user_id,
            username: users_by_id[f.user_id],
            fingerprint_id: f.fingerprint_id,
            ip: f.ip,
            last_seen_at: f.last_seen_at,
            created_at: f.created_at
          }
        },
        playback_sessions: sessions.map { |s|
          {
            user_id: s.user_id,
            username: users_by_id[s.user_id],
            fingerprint_id: s.fingerprint_id,
            token_sha256: s.token_sha256,
            ip: s.ip,
            user_agent: s.user_agent,
            played_at: s.played_at,
            created_at: s.created_at
          }
        }
      })
    end
  end
end
