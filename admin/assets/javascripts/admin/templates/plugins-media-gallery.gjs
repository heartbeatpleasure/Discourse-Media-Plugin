import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-landing {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-landing h1,
      .media-gallery-admin-landing h2,
      .media-gallery-admin-landing h3,
      .media-gallery-admin-landing p {
        margin: 0;
      }

      .mg-landing__hero,
      .mg-landing__card {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-landing__hero {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
        padding: 1.25rem 1.35rem;
      }

      .mg-landing__hero-copy {
        display: flex;
        flex-direction: column;
        gap: 0.45rem;
        max-width: 760px;
      }

      .mg-landing__hero-copy p,
      .mg-landing__card-description,
      .mg-landing__section-description {
        color: var(--mg-muted);
      }

      .mg-landing__section-header {
        display: flex;
        align-items: flex-end;
        justify-content: space-between;
        gap: 1rem;
        padding: 0 0.25rem;
      }

      .mg-landing__section-copy {
        display: flex;
        flex-direction: column;
        gap: 0.2rem;
      }

      .mg-landing__grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 1rem;
      }

      .mg-landing__card {
        display: flex;
        flex-direction: column;
        gap: 0.85rem;
        min-height: 170px;
        padding: 1rem 1.1rem;
        text-decoration: none;
        color: var(--primary);
        transition: border-color 0.12s ease, box-shadow 0.12s ease, transform 0.12s ease;
      }

      .mg-landing__card:hover,
      .mg-landing__card:focus {
        border-color: var(--tertiary-medium);
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.06);
        color: var(--primary);
        text-decoration: none;
        transform: translateY(-1px);
      }

      .mg-landing__card.is-primary {
        border-color: var(--tertiary-low);
        background: linear-gradient(180deg, var(--secondary) 0%, var(--tertiary-very-low) 100%);
      }

      .mg-landing__card-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.8rem;
      }

      .mg-landing__card-title {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 0;
      }

      .mg-landing__card-title h3 {
        font-size: var(--font-up-1);
        line-height: 1.15;
      }

      .mg-landing__card-description {
        line-height: 1.35;
      }

      .mg-landing__card-badge {
        display: inline-flex;
        width: max-content;
        max-width: 100%;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-medium);
        font-size: var(--font-down-1);
        line-height: 1;
        padding: 0.35rem 0.55rem;
        white-space: nowrap;
      }

      .mg-landing__card-badge.is-primary {
        border-color: var(--tertiary-low);
        background: var(--tertiary-low);
        color: var(--tertiary);
      }

      .mg-landing__card-action {
        margin-top: auto;
        display: inline-flex;
        align-items: center;
        gap: 0.35rem;
        color: var(--tertiary);
        font-weight: 600;
      }

      @media (max-width: 700px) {
        .mg-landing__hero {
          flex-direction: column;
        }

        .mg-landing__grid {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="media-gallery-admin-landing">
      <section class="mg-landing__hero">
        <div class="mg-landing__hero-copy">
          <h1>{{i18n "admin.media_gallery.title"}}</h1>
          <p>{{i18n "admin.media_gallery.description"}}</p>
        </div>

        <a
          class="btn btn-primary"
          href="/admin/site_settings/category/all_results?filter=media_gallery"
        >
          {{i18n "admin.media_gallery.open_settings"}}
        </a>
      </section>

      <div class="mg-landing__section-header">
        <div class="mg-landing__section-copy">
          <h2>{{i18n "admin.media_gallery.overview_title"}}</h2>
          <p class="mg-landing__section-description">
            {{i18n "admin.media_gallery.overview_description"}}
          </p>
        </div>
      </div>

      <section class="mg-landing__grid" aria-label={{i18n "admin.media_gallery.overview_title"}}>
        <a
          class="mg-landing__card is-primary"
          href="/admin/site_settings/category/all_results?filter=media_gallery"
        >
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge is-primary">
                {{i18n "admin.media_gallery.category_configuration"}}
              </span>
              <h3>{{i18n "admin.media_gallery.open_settings"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.settings_description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_settings"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-settings-guide">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_configuration"}}
              </span>
              <h3>Settings guide</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            Understand the most important Media Gallery settings, recommended values, and where to change them.
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-management">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_content"}}
              </span>
              <h3>{{i18n "admin.media_gallery.management.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.management.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-reports">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_moderation"}}
              </span>
              <h3>{{i18n "admin.media_gallery.reports.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.reports.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-health">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_monitoring"}}
              </span>
              <h3>{{i18n "admin.media_gallery.health.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.health.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>


        <a class="mg-landing__card" href="/admin/plugins/media-gallery-security">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_monitoring"}}
              </span>
              <h3>Security status</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            Review security, privacy, download-prevention and storage hardening controls in one read-only overview.
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>
        <a class="mg-landing__card" href="/admin/plugins/media-gallery-user-diagnostics">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_monitoring"}}
              </span>
              <h3>{{i18n "admin.media_gallery.user_diagnostics.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.user_diagnostics.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-logs">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_monitoring"}}
              </span>
              <h3>{{i18n "admin.media_gallery.logs.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.logs.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-forensics-identify">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_forensics"}}
              </span>
              <h3>{{i18n "admin.media_gallery.forensics_identify.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.forensics_identify.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-forensics-exports">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_forensics"}}
              </span>
              <h3>{{i18n "admin.media_gallery.forensics_exports.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.forensics_exports.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-test-downloads">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_forensics"}}
              </span>
              <h3>{{i18n "admin.media_gallery.test_downloads.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.test_downloads.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>

        <a class="mg-landing__card" href="/admin/plugins/media-gallery-migrations">
          <div class="mg-landing__card-header">
            <div class="mg-landing__card-title">
              <span class="mg-landing__card-badge">
                {{i18n "admin.media_gallery.category_operations"}}
              </span>
              <h3>{{i18n "admin.media_gallery.migrations.short_title"}}</h3>
            </div>
          </div>
          <p class="mg-landing__card-description">
            {{i18n "admin.media_gallery.migrations.description"}}
          </p>
          <span class="mg-landing__card-action">
            {{i18n "admin.media_gallery.open_tool"}}
          </span>
        </a>
      </section>
    </div>
  </template>
);
