import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-admin-test-downloads">
      <h1>{{i18n "admin.media_gallery.test_downloads.title"}}</h1>
      <p>{{i18n "admin.media_gallery.test_downloads.description"}}</p>

      <div class="alert alert-info">
        This page is admin-only. The backend still enforces the test-download setting.
      </div>

      <div class="control-group" style="margin-top: 1rem; max-width: 1000px;">
        <label class="control-label">Find media</label>
        <div style="display:flex; gap:0.75rem; align-items:flex-start; flex-wrap:wrap;">
          <input
            class="admin-input"
            type="text"
            value={{this.searchQuery}}
            placeholder="Paste full public_id or part of title"
            {{on "input" this.onSearchInput}}
            {{on "keydown" this.onSearchKeydown}}
            style="min-width: 320px;"
          />
          <button class="btn" type="button" {{on "click" this.search}} disabled={{this.searchButtonDisabled}}>
            Search
          </button>
          <button class="btn btn-primary" type="button" {{on "click" this.useTypedPublicId}} disabled={{this.useTypedPublicIdDisabled}}>
            Use entered public_id
          </button>
        </div>
        <div class="desc">Best: paste the full public_id. Search is optional; you can also continue directly with the entered public_id.</div>
      </div>

      {{#if this.selectionMessage}}
        <div class="alert alert-info" style="margin-top:1rem; max-width: 1000px;">
          {{this.selectionMessage}}
        </div>
      {{/if}}

      {{#if this.searchInfo}}
        <div class="alert alert-info" style="margin-top:1rem; max-width: 1000px;">
          {{this.searchInfo}}
        </div>
      {{/if}}

      {{#if this.isSearching}}
        <p>Searching…</p>
      {{/if}}

      {{#if this.searchError}}
        <div class="alert alert-error">{{this.searchError}}</div>
      {{/if}}

      {{#if this.showNoResults}}
        <div class="alert alert-warning" style="margin-top:1rem; max-width: 1000px;">
          No media items found for this search. If you entered an exact public_id, click <strong>Use entered public_id</strong>.
        </div>
      {{/if}}

      {{#if this.searchResults.length}}
        <div style="margin-top:1rem; max-width: 1000px;">
          <p><strong>{{this.searchResults.length}}</strong> result(s)</p>
          <table class="table">
            <thead>
              <tr>
                <th>public_id</th>
                <th>title</th>
                <th>owner</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each this.searchResults as |item|}}
                <tr>
                  <td><code>{{item.public_id}}</code></td>
                  <td>{{item.title}}</td>
                  <td>{{item.username}}</td>
                  <td>
                    <button class="btn btn-small" type="button" {{on "click" (fn this.pickItem item)}}>
                      Use
                    </button>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      {{/if}}

      {{#if this.hasSelectedItem}}
        <div class="alert alert-info" style="margin-top:1rem; max-width: 900px;">
          <strong>Selected media:</strong>
          <code>{{this.publicId}}</code>
          {{#if this.selectedItem.title}} — {{this.selectedItem.title}}{{/if}}
        </div>

        <div class="control-group" style="margin-top: 1rem; max-width: 900px;">
          <label class="control-label">Users</label>
          <div style="display:flex; gap:0.75rem; align-items:center; flex-wrap:wrap;">
            <select class="combobox" value={{this.selectedUserId}} {{on "change" this.onUserSelect}}>
              <option value="">-- select user --</option>
              {{#each this.users as |user|}}
                <option value={{user.id}}>
                  {{user.username}} (#{{user.id}})
                </option>
              {{/each}}
            </select>
            <button class="btn" type="button" {{on "click" this.loadUsers}} disabled={{this.isLoadingUsers}}>
              {{if this.isLoadingUsers "Loading users…" "Reload users"}}
            </button>
          </div>
          <div class="desc">Users are auto-loaded after selecting a public_id. You can reload them here or fill a user ID manually below.</div>
        </div>

        {{#if this.usersError}}
          <div class="alert alert-error">{{this.usersError}}</div>
        {{/if}}

        {{#if this.showNoUsersWarning}}
          <div class="alert alert-warning" style="max-width: 900px;">
            No users found from fingerprints/playback sessions for this public_id yet. You can still enter a user ID manually.
          </div>
        {{/if}}

        <div class="control-group" style="margin-top: 1rem; max-width: 900px;">
          <label class="control-label">Manual user ID</label>
          <input
            class="admin-input"
            type="number"
            min="1"
            value={{this.manualUserId}}
            placeholder="Enter user ID"
            {{on "input" this.onManualUserIdInput}}
          />
          <div class="desc">Use this if no users are listed automatically.</div>
        </div>

        <div style="margin-top:1rem; display:flex; gap:0.75rem; flex-wrap:wrap;">
          <button class="btn btn-primary" type="button" {{on "click" this.generateFull}} disabled={{this.generateDisabled}}>
            Generate full download
          </button>
          <button class="btn" type="button" {{on "click" this.generateRandomPartial}} disabled={{this.generateDisabled}}>
            Generate random partial (~40–50%)
          </button>
        </div>

        {{#if this.generateError}}
          <div class="alert alert-error" style="margin-top:1rem; max-width: 1000px;">{{this.generateError}}</div>
        {{/if}}
      {{/if}}

      <div style="margin-top:2rem; max-width: 1000px;">
        <h2>{{i18n "admin.media_gallery.test_downloads.generated"}}</h2>

        {{#if this.hasArtifacts}}
          <table class="table">
            <thead>
              <tr>
                <th>created</th>
                <th>public_id</th>
                <th>user</th>
                <th>mode</th>
                <th>segments</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each this.artifacts as |artifact|}}
                <tr>
                  <td>{{artifact.created_at}}</td>
                  <td><code>{{artifact.public_id}}</code></td>
                  <td>{{artifact.username}} (#{{artifact.user_id}})</td>
                  <td>
                    {{artifact.mode}}
                    {{#if artifact.random_clip_region}}
                      — {{artifact.random_clip_region}} ({{artifact.clip_percent_of_video}}%)
                    {{/if}}
                  </td>
                  <td>
                    start {{artifact.start_segment}}, count {{artifact.segment_count}} / {{artifact.total_segments}}
                  </td>
                  <td>
                    <a class="btn btn-small" href={{artifact.download_url}} target="_blank" rel="noopener noreferrer">
                      Download
                    </a>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{else}}
          <p>{{i18n "admin.media_gallery.test_downloads.none_generated"}}</p>
        {{/if}}
      </div>
    </div>
  </template>
);
