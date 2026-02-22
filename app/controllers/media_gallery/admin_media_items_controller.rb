# frozen_string_literal: true

module ::MediaGallery
  # Admin-only helper endpoints.
  class AdminMediaItemsController < ::Admin::AdminController
    requires_plugin "Discourse-Media-Plugin"

    # GET /admin/plugins/media-gallery/media-items/search.json?q=...
    # Returns a small list for quickly selecting a public_id in the admin UI.
    def search
      q = params[:q].to_s.strip
      limit = 20

      scope = ::MediaGallery::MediaItem.includes(:user).order(created_at: :desc)

      if q.present?
        if q =~ /\A\d+\z/
          # Numeric input: treat as media_item id.
          scope = scope.where(id: q.to_i)
        else
          like = "%#{q}%"
          scope = scope.where(
            "public_id ILIKE :q OR title ILIKE :q",
            q: like
          )
        end
      end

      items = scope.limit(limit).map do |item|
        {
          id: item.id,
          public_id: item.public_id,
          title: item.title,
          status: item.status,
          created_at: item.created_at,
          user_id: item.user_id,
          username: item.user&.username,
        }
      end

      render_json_dump(items: items)
    end
  end
end
