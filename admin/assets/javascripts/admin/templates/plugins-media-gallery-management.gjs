import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-admin-management">
      <h1>{{i18n "admin.media_gallery.management.title"}}</h1>
      <p>{{i18n "admin.media_gallery.management.description"}}</p>

      <div class="mg-management__layout" style="display:grid; grid-template-columns: minmax(360px, 520px) minmax(420px, 1fr); gap: 1rem; align-items:start;">
        <section class="mg-management__panel" style="border:1px solid var(--primary-low); border-radius:1rem; padding:1rem; background: var(--secondary);">
          <div style="display:grid; gap:0.75rem;">
            <div>
              <label class="control-label">Search</label>
              <input class="admin-input" type="text" value={{@controller.searchQuery}} placeholder="Search by public_id, title or id" {{on "input" @controller.onSearchInput}} />
            </div>
            <div style="display:grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap:0.75rem;">
              <div>
                <label class="control-label">Status</label>
                <select class="combobox" value={{@controller.statusFilter}} {{on "change" @controller.onStatusFilterChange}}>
                  <option value="all">All</option>
                  <option value="ready">Ready</option>
                  <option value="queued">Queued</option>
                  <option value="processing">Processing</option>
                  <option value="failed">Failed</option>
                </select>
              </div>
              <div>
                <label class="control-label">Type</label>
                <select class="combobox" value={{@controller.mediaTypeFilter}} {{on "change" @controller.onMediaTypeFilterChange}}>
                  <option value="all">All</option>
                  <option value="image">Image</option>
                  <option value="audio">Audio</option>
                  <option value="video">Video</option>
                </select>
              </div>
              <div>
                <label class="control-label">Visibility</label>
                <select class="combobox" value={{@controller.hiddenFilter}} {{on "change" @controller.onHiddenFilterChange}}>
                  <option value="all">All</option>
                  <option value="visible">Visible</option>
                  <option value="hidden">Hidden</option>
                </select>
              </div>
            </div>
            <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
              <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isSearching}}>
                {{if @controller.isSearching "Searching…" "Search"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.loadInitial}} disabled={{@controller.isSearching}}>Reset</button>
            </div>
          </div>

          {{#if @controller.searchInfo}}
            <div class="alert alert-info" style="margin-top:1rem;">{{@controller.searchInfo}}</div>
          {{/if}}
          {{#if @controller.searchError}}
            <div class="alert alert-error" style="margin-top:1rem;">{{@controller.searchError}}</div>
          {{/if}}

          <div style="margin-top:1rem; max-height:70vh; overflow:auto;">
            <table class="table">
              <thead>
                <tr>
                  <th>Title</th>
                  <th>Type</th>
                  <th>Status</th>
                  <th>Visibility</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {{#each @controller.searchResults as |item|}}
                  <tr>
                    <td>
                      <div><strong>{{item.title}}</strong></div>
                      <div><code>{{item.public_id}}</code></div>
                      <div class="mg-management__muted">{{item.username}}</div>
                    </td>
                    <td>{{item.media_type}}</td>
                    <td>{{item.status}}</td>
                    <td>{{if item.hidden "Hidden" "Visible"}}</td>
                    <td>
                      <button class="btn btn-small" type="button" {{on "click" (fn @controller.selectItem item)}}>Open</button>
                    </td>
                  </tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        </section>

        <section class="mg-management__panel" style="border:1px solid var(--primary-low); border-radius:1rem; padding:1rem; background: var(--secondary);">
          {{#if @controller.noticeMessage}}
            <div class="alert alert-info">{{@controller.noticeMessage}}</div>
          {{/if}}
          {{#if @controller.selectionError}}
            <div class="alert alert-error">{{@controller.selectionError}}</div>
          {{/if}}

          {{#if @controller.hasSelectedItem}}
            <div style="display:flex; gap:1rem; align-items:flex-start; flex-wrap:wrap;">
              <img src={{@controller.selectedItem.thumbnail_url}} alt="thumbnail" style="width: 180px; max-width:100%; border-radius:0.75rem; border:1px solid var(--primary-low);" />
              <div style="flex:1; min-width:260px;">
                <h2 style="margin-top:0;">{{@controller.selectedItem.title}}</h2>
                <div class="mg-management__muted"><code>{{@controller.selectedItem.public_id}}</code></div>
                <table class="table">
                  <tbody>
                    {{#each @controller.selectedMetaRows as |row|}}
                      <tr>
                        <th>{{row.label}}</th>
                        <td>{{row.value}}</td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </div>
            </div>

            <div style="margin-top:1rem; display:grid; gap:0.75rem;">
              <div>
                <label class="control-label">Title</label>
                <input class="admin-input" type="text" value={{@controller.editTitle}} {{on "input" @controller.onEditTitle}} />
              </div>
              <div>
                <label class="control-label">Description</label>
                <textarea class="admin-input" rows="5" value={{@controller.editDescription}} {{on "input" @controller.onEditDescription}}></textarea>
              </div>
              <div style="display:grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap:0.75rem;">
                <div>
                  <label class="control-label">Gender</label>
                  <select class="combobox" value={{@controller.editGender}} {{on "change" @controller.onEditGender}}>
                    <option value="male">Male</option>
                    <option value="female">Female</option>
                    <option value="both">Both</option>
                    <option value="non_binary">Non-binary</option>
                    <option value="objects">Objects</option>
                    <option value="other">Other</option>
                  </select>
                </div>
                <div>
                  <label class="control-label">Tags</label>
                  <input class="admin-input" type="text" value={{@controller.editTags}} placeholder="comma,separated,tags" {{on "input" @controller.onEditTags}} />
                </div>
              </div>
              <div>
                <label class="control-label">Admin note / reason</label>
                <textarea class="admin-input" rows="3" value={{@controller.adminNote}} placeholder="Optional note for hide/unhide/edit/delete" {{on "input" @controller.onAdminNote}}></textarea>
              </div>
            </div>

            <div style="margin-top:1rem; display:flex; gap:0.75rem; flex-wrap:wrap;">
              <button class="btn btn-primary" type="button" {{on "click" @controller.saveChanges}} disabled={{@controller.saveDisabled}}>
                {{if @controller.isSaving "Saving…" "Save changes"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.toggleHidden}} disabled={{@controller.toggleHiddenDisabled}}>
                {{if @controller.isTogglingHidden "Updating…" @controller.hiddenButtonLabel}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.retryProcessing}} disabled={{@controller.retryDisabled}}>
                {{if @controller.isRetrying "Queuing…" "Retry processing"}}
              </button>
              <button class="btn btn-danger" type="button" {{on "click" @controller.deleteItem}} disabled={{@controller.deleteDisabled}}>
                {{if @controller.isDeleting "Deleting…" "Delete item"}}
              </button>
              <button class="btn" type="button" {{on "click" @controller.refreshSelected}} disabled={{@controller.isLoadingSelection}}>
                {{if @controller.isLoadingSelection "Refreshing…" "Refresh"}}
              </button>
            </div>

            <div style="margin-top:1.5rem;">
              <h3>Admin history</h3>
              {{#if @controller.historyEntries.length}}
                <table class="table">
                  <thead>
                    <tr>
                      <th>When</th>
                      <th>Admin</th>
                      <th>Action</th>
                      <th>Note</th>
                    </tr>
                  </thead>
                  <tbody>
                    {{#each @controller.historyEntries as |entry|}}
                      <tr>
                        <td>{{entry.at}}</td>
                        <td>{{entry.admin_username}}</td>
                        <td>{{entry.action}}</td>
                        <td>
                          {{#if entry.note}}
                            {{entry.note}}
                          {{else}}
                            —
                          {{/if}}
                          {{#if entry.changes}}
                            <div class="mg-management__muted"><code>{{entry.changesSummary}}</code></div>
                          {{/if}}
                        </td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              {{else}}
                <p>No admin changes recorded yet for this item.</p>
              {{/if}}
            </div>
          {{else}}
            <p>Select an item from the search results to manage it.</p>
          {{/if}}
        </section>
      </div>
    </div>
  </template>
);
