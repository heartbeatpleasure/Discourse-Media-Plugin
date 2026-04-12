import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-forensics-exports">
      <h1>{{i18n "admin.media_gallery.forensics_exports.title"}}</h1>

      <p>{{i18n "admin.media_gallery.forensics_exports.description"}}</p>

      {{#if @controller.error}}
        <div class="alert alert-error">{{@controller.error}}</div>
      {{/if}}

      {{#if @controller.exports.length}}
        <ul>
          {{#each @controller.exports as |exp|}}
            <li>
              <button type="button" class="btn btn-link" {{on "click" (fn @controller.downloadExport exp false)}}>
                {{exp.filename}}
              </button>

              <span>
                &nbsp;—
                {{#if exp.rows_count}}
                  {{exp.rows_count}} {{i18n "admin.media_gallery.forensics_exports.rows"}}
                {{/if}}
                {{#if exp.created_at}}
                  &nbsp;({{exp.created_at}})
                {{/if}}
              </span>

              <span>
                &nbsp;[
                <button type="button" class="btn btn-link" {{on "click" (fn @controller.downloadExport exp true)}}>
                  {{i18n "admin.media_gallery.forensics_exports.download_gz"}}
                </button>
                ]
              </span>
            </li>
          {{/each}}
        </ul>
      {{else}}
        <p>{{i18n "admin.media_gallery.forensics_exports.none"}}</p>
      {{/if}}
    </div>
  </template>
);
