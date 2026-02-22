# frozen_string_literal: true

module ::MediaGallery
  # Admin helper endpoint used by the forensics identify UI.
  # Provides a simple search to find the correct public_id.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    def search
      q = params[:q].to_s.strip
      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 50 if limit > 50

      scope = MediaGallery::MediaItem.all

      if q.present?
        if q.match?(/\A\d+\z/)
          scope = scope.where(id: q.to_i)
        else
          like = "%#{::ActiveRecord::Base.sanitize_sql_like(q)}%"
          scope = scope.where("public_id ILIKE ? OR title ILIKE ?", like, like)
        end
      end

      items = scope.order(created_at: :desc).limit(limit)

      user_ids = items.pluck(:user_id).uniq
      users_by_id = ::User.where(id: user_ids).pluck(:id, :username).to_h

      render_json_dump({
        results: items.map { |item|
          {
            id: item.id,
            public_id: item.public_id,
            title: item.title,
            status: item.status,
            media_type: item.media_type,
            duration_seconds: item.duration_seconds,
            created_at: item.created_at,
            uploader_username: users_by_id[item.user_id]
          }
        }
      })
    end
  end
end
