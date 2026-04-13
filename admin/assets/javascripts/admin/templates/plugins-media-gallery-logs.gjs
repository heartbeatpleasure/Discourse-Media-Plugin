import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-logs-admin">
      <div class="media-gallery-logs-admin__header" style="margin-bottom: 1rem;">
        <h1>{{i18n "admin.media_gallery.logs.title"}}</h1>
        <p>{{i18n "admin.media_gallery.logs.description"}}</p>
      </div>

      <div
        class="media-gallery-logs-admin__card"
        style="border: 1px solid var(--primary-low); border-radius: 12px; padding: 1rem 1.1rem; background: var(--secondary); max-width: 980px;"
      >
        <div style="font-weight: 600; margin-bottom: 0.35rem;">Phase 1 route check</div>
        <div style="opacity: 0.85; line-height: 1.5;">
          This first step only adds the Logs tab and a minimal page, so the admin route can be verified safely before backend logging, search, counters, or charts are added.
        </div>
      </div>
    </div>
  </template>
);
