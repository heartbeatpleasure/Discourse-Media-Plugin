import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-forensics-identify">
      <h1>{{i18n "admin.media_gallery.forensics_identify.title"}}</h1>

      <p>{{i18n "admin.media_gallery.forensics_identify.description"}}</p>

      {{#if @controller.error}}
        <div class="alert alert-error">{{@controller.error}}</div>
      {{/if}}

      <div class="form">
        <p>
          <label>
            {{i18n "admin.media_gallery.forensics_identify.public_id_label"}}
            <input
              type="text"
              value={{@controller.publicId}}
              placeholder={{i18n "admin.media_gallery.forensics_identify.public_id_placeholder"}}
              {{on "input" @controller.onPublicIdInput}}
            />
          </label>
        </p>

        <p>
          <label>
            {{i18n "admin.media_gallery.forensics_identify.file_label"}}
            <input type="file" {{on "change" @controller.onFileChange}} />
          </label>
        </p>

        <p>
          <label>
            {{i18n "admin.media_gallery.forensics_identify.max_samples_label"}}
            <input
              type="number"
              min="5"
              max="200"
              value={{@controller.maxSamples}}
              {{on "input" @controller.onMaxSamplesInput}}
            />
          </label>
        </p>

        <p>
          <label>
            {{i18n "admin.media_gallery.forensics_identify.max_offset_label"}}
            <input
              type="number"
              min="0"
              max="300"
              value={{@controller.maxOffsetSegments}}
              {{on "input" @controller.onMaxOffsetInput}}
            />
          </label>
        </p>

        <p>
          <label>
            {{i18n "admin.media_gallery.forensics_identify.layout_label"}}
            <select value={{@controller.layout}} {{on "change" @controller.onLayoutChange}}>
              <option value="">{{i18n "admin.media_gallery.forensics_identify.layout_auto"}}</option>
              <option value="v1_tiles">{{i18n "admin.media_gallery.forensics_identify.layout_v1_tiles"}}</option>
              <option value="v2_pairs">{{i18n "admin.media_gallery.forensics_identify.layout_v2_pairs"}}</option>
            </select>
          </label>
        </p>

        <p>
          <button
            type="button"
            class="btn btn-primary"
            disabled={{@controller.isRunning}}
            {{on "click" @controller.identify}}
          >
            {{#if @controller.isRunning}}
              {{i18n "admin.media_gallery.forensics_identify.running"}}
            {{else}}
              {{i18n "admin.media_gallery.forensics_identify.identify_button"}}
            {{/if}}
          </button>
        </p>
      </div>

      {{#if @controller.resultJson}}
        <h2>{{i18n "admin.media_gallery.forensics_identify.result"}}</h2>
        <pre><code>{{@controller.resultJson}}</code></pre>
      {{/if}}
    </div>
  </template>
);
