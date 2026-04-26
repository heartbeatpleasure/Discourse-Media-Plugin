import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-admin-landing">
      <h1>{{i18n "admin.media_gallery.title"}}</h1>
      <p>{{i18n "admin.media_gallery.description"}}</p>

      <div class="buttons" style="display:flex; gap:0.75rem; flex-wrap:wrap; margin-top: 1rem;">
        <a
          class="btn btn-primary"
          href="/admin/site_settings/category/all_results?filter=media_gallery"
        >
          {{i18n "admin.media_gallery.open_settings"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-forensics-identify">
          {{i18n "admin.media_gallery.forensics_identify.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-forensics-exports">
          {{i18n "admin.media_gallery.forensics_exports.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-test-downloads">
          {{i18n "admin.media_gallery.test_downloads.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-migrations">
          {{i18n "admin.media_gallery.migrations.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-management">
          {{i18n "admin.media_gallery.management.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-reports">
          {{i18n "admin.media_gallery.reports.short_title"}}
        </a>

        <a class="btn" href="/admin/plugins/media-gallery-logs">
          {{i18n "admin.media_gallery.logs.short_title"}}
        </a>
      </div>
    </div>
  </template>
);
