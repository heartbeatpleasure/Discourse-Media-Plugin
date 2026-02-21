import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(

<h1>{{i18n "admin.media_gallery.forensics_exports.title"}}</h1>

<p>{{i18n "admin.media_gallery.forensics_exports.description"}}</p>

{{#if @controller.error}}
  <div class="alert alert-error">{{@controller.error}}</div>
{{/if}}

{{#if @controller.exports.length}}
  <ul>
    {{#each @controller.exports as |exp|}}
      <li>
        <a
          href={{concat @controller.downloadBase "/" exp.id ".csv"}}
          rel="noopener noreferrer"
        >
          {{exp.filename}}
        </a>

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
          <a
            href={{concat @controller.downloadBase "/" exp.id ".csv?gz=1"}}
            rel="noopener noreferrer"
          >
            {{i18n "admin.media_gallery.forensics_exports.download_gz"}}
          </a>
          ]
        </span>
      </li>
    {{/each}}
  </ul>
{{else}}
  <p>{{i18n "admin.media_gallery.forensics_exports.none"}}</p>
{{/if}}

);
