import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-admin-forensics-exports {
        --mg-surface: var(--secondary);
        --mg-surface-alt: var(--primary-very-low);
        --mg-border: var(--primary-low);
        --mg-muted: var(--primary-medium);
        --mg-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-admin-forensics-exports h1,
      .media-gallery-admin-forensics-exports h2,
      .media-gallery-admin-forensics-exports h3,
      .media-gallery-admin-forensics-exports p {
        margin: 0;
      }

      .mg-exports__panel {
        background: var(--mg-surface);
        border: 1px solid var(--mg-border);
        border-radius: var(--mg-radius);
        padding: 1rem 1.125rem;
        min-width: 0;
        overflow: hidden;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-exports__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.75rem;
        margin-bottom: 0.9rem;
      }

      .mg-exports__panel-header:last-child {
        margin-bottom: 0;
      }

      .mg-exports__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        min-width: 0;
      }

      .mg-exports__muted {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
      }

      .mg-exports__flash {
        border-radius: 12px;
        padding: 0.85rem 1rem;
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-exports__badge-row,
      .mg-exports__actions {
        display: flex;
        align-items: center;
        gap: 0.65rem;
      }

      .mg-exports__badge-row {
        flex-wrap: wrap;
      }

      .mg-exports__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 0.28rem 0.68rem;
        font-size: var(--font-down-1);
        line-height: 1.2;
        white-space: nowrap;
        background: var(--primary-very-low);
        color: var(--primary-high);
        border: 1px solid var(--primary-low);
        font-weight: 600;
      }

      .mg-exports__badge.is-success {
        background: var(--success-low);
        color: var(--success);
        border-color: var(--success-low-mid);
      }

      .mg-exports__badge.is-warning {
        background: var(--tertiary-very-low);
        color: var(--tertiary);
        border-color: var(--tertiary-low);
      }

      .mg-exports__badge.is-info {
        background: var(--secondary);
      }

      .mg-exports__list,
      .mg-exports__meta-grid {
        display: grid;
        gap: 1rem;
      }

      .mg-exports__card {
        border: 1px solid var(--mg-border);
        border-radius: 18px;
        background: var(--mg-surface-alt);
        padding: 1rem;
        display: grid;
        gap: 1rem;
      }

      .mg-exports__card-header {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        align-items: start;
        gap: 1rem;
      }

      .mg-exports__card-copy {
        display: flex;
        flex-direction: column;
        gap: 0.7rem;
        min-width: 0;
      }

      .mg-exports__filename {
        font-size: 1.1rem;
        font-weight: 700;
        line-height: 1.25;
        overflow-wrap: anywhere;
      }

      .mg-exports__actions {
        flex-wrap: nowrap;
        justify-content: flex-end;
        white-space: nowrap;
        flex-shrink: 0;
      }

      .mg-exports__actions .btn {
        min-width: 148px;
        justify-content: center;
      }

      .mg-exports__meta-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .mg-exports__meta-card {
        border: 1px solid var(--mg-border);
        border-radius: 14px;
        background: var(--secondary);
        padding: 0.9rem 1rem;
        min-width: 0;
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
      }

      .mg-exports__meta-card.is-wide {
        grid-column: 1 / -1;
      }

      .mg-exports__meta-label {
        color: var(--mg-muted);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .mg-exports__meta-value {
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .mg-exports__meta-value.is-code {
        font-family: var(--font-family-monospace);
        font-size: var(--font-down-1);
      }

      .mg-exports__empty {
        border: 1px dashed var(--mg-border);
        border-radius: 18px;
        background: var(--mg-surface-alt);
        padding: 1.4rem;
        text-align: center;
        display: grid;
        gap: 0.35rem;
      }

      @media (max-width: 860px) {
        .mg-exports__card-header {
          grid-template-columns: 1fr;
        }

        .mg-exports__actions {
          justify-content: flex-start;
          flex-wrap: wrap;
          white-space: normal;
        }
      }

      @media (max-width: 700px) {
        .mg-exports__meta-grid {
          grid-template-columns: 1fr;
        }

        .mg-exports__meta-card.is-wide {
          grid-column: auto;
        }
      }
    </style>

    <div class="media-gallery-admin-forensics-exports">
      <section class="mg-exports__panel">
        <div class="mg-exports__panel-header">
          <div class="mg-exports__panel-copy">
            <h1>{{i18n "admin.media_gallery.forensics_exports.title"}}</h1>
            <p class="mg-exports__muted">{{i18n "admin.media_gallery.forensics_exports.description"}}</p>
          </div>

          <div class="mg-exports__badge-row">
            <span class="mg-exports__badge is-info">
              {{i18n "admin.media_gallery.forensics_exports.count" count=@controller.exports.length}}
            </span>
          </div>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-exports__flash">{{@controller.error}}</div>
      {{/if}}

      {{#if @controller.exports.length}}
        <section class="mg-exports__panel">
          <div class="mg-exports__panel-header">
            <div class="mg-exports__panel-copy">
              <h2>{{i18n "admin.media_gallery.forensics_exports.available"}}</h2>
              <p class="mg-exports__muted">{{i18n "admin.media_gallery.forensics_exports.available_description"}}</p>
            </div>
          </div>

          <div class="mg-exports__list">
            {{#each @controller.exports key="id" as |exp|}}
              <article class="mg-exports__card">
                <div class="mg-exports__card-header">
                  <div class="mg-exports__card-copy">
                    <h3 class="mg-exports__filename">{{exp.displayName}}</h3>

                    <div class="mg-exports__badge-row">
                      <span class="mg-exports__badge is-info">{{exp.rowsLabel}}</span>
                      <span class="mg-exports__badge {{exp.availabilityClass}}">{{exp.availabilityLabel}}</span>
                    </div>
                  </div>

                  <div class="mg-exports__actions">
                    <button
                      type="button"
                      class="btn btn-primary"
                      {{on "click" (fn @controller.downloadExport exp false)}}
                    >
                      {{i18n "admin.media_gallery.forensics_exports.download_csv"}}
                    </button>

                    <button
                      type="button"
                      class="btn"
                      {{on "click" (fn @controller.downloadExport exp true)}}
                    >
                      {{i18n "admin.media_gallery.forensics_exports.download_gzip"}}
                    </button>
                  </div>
                </div>

                <div class="mg-exports__meta-grid">
                  <div class="mg-exports__meta-card">
                    <div class="mg-exports__meta-label">{{i18n "admin.media_gallery.forensics_exports.created_at"}}</div>
                    <div class="mg-exports__meta-value">{{exp.createdLabel}}</div>
                  </div>

                  <div class="mg-exports__meta-card">
                    <div class="mg-exports__meta-label">{{i18n "admin.media_gallery.forensics_exports.cutoff_at"}}</div>
                    <div class="mg-exports__meta-value">{{exp.cutoffLabel}}</div>
                  </div>

                  <div class="mg-exports__meta-card">
                    <div class="mg-exports__meta-label">{{i18n "admin.media_gallery.forensics_exports.storage_location"}}</div>
                    <div class="mg-exports__meta-value">{{exp.storageLocationLabel}}</div>
                  </div>

                  <div class="mg-exports__meta-card">
                    <div class="mg-exports__meta-label">{{i18n "admin.media_gallery.forensics_exports.gzip_size"}}</div>
                    <div class="mg-exports__meta-value">{{exp.gzipSizeLabel}}</div>
                  </div>

                  <div class="mg-exports__meta-card is-wide">
                    <div class="mg-exports__meta-label">{{i18n "admin.media_gallery.forensics_exports.csv_checksum"}}</div>
                    <div class="mg-exports__meta-value is-code">{{exp.csvShaLabel}}</div>
                  </div>
                </div>
              </article>
            {{/each}}
          </div>
        </section>
      {{else}}
        <section class="mg-exports__panel">
          <div class="mg-exports__empty">
            <h2>{{i18n "admin.media_gallery.forensics_exports.empty_title"}}</h2>
            <p class="mg-exports__muted">{{i18n "admin.media_gallery.forensics_exports.empty_description"}}</p>
          </div>
        </section>
      {{/if}}
    </div>
  </template>
);
