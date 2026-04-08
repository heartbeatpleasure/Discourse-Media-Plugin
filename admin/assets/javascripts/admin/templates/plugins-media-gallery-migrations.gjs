import RouteTemplate from "ember-route-template";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <div class="media-gallery-admin-migrations">
      <h1>{{i18n "admin.media_gallery.migrations.title"}}</h1>
      <p>{{i18n "admin.media_gallery.migrations.description"}}</p>

      {{#if @controller.storageError}}
        <div class="alert alert-error" style="margin-bottom:1rem;">{{@controller.storageError}}</div>
      {{/if}}

      <div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap:1rem; align-items:start; margin-bottom:1rem;">
        <div class="admin-detail-panel" style="padding:1rem; border:1px solid var(--primary-low); border-radius:8px;">
          <h2 style="margin-top:0;">{{i18n "admin.media_gallery.migrations.active_storage"}}</h2>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap; margin-bottom:0.75rem;">
            <button class="btn" type="button" {{on "click" (fn @controller.loadStorageHealth "active")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.refresh_health"}}
            </button>
            <button class="btn" type="button" {{on "click" (fn @controller.runStorageProbe "active")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.run_probe"}}
            </button>
          </div>
          {{#if @controller.activeHealth}}
            <div><strong>backend:</strong> {{@controller.activeHealth.backend}}</div>
            <div><strong>profile:</strong> {{@controller.activeHealth.profile_key}}</div>
            <div><strong>available:</strong> {{if @controller.activeHealth.available "yes" "no"}}</div>
            <div><strong>validation errors:</strong> {{@controller.activeHealth.validation_errors.length}}</div>
          {{/if}}
          {{#if @controller.activeProbe}}
            <div style="margin-top:0.75rem;"><strong>probe:</strong> {{if @controller.activeProbe.ok "ok" "failed"}}</div>
          {{/if}}
        </div>

        <div class="admin-detail-panel" style="padding:1rem; border:1px solid var(--primary-low); border-radius:8px;">
          <h2 style="margin-top:0;">{{i18n "admin.media_gallery.migrations.target_storage"}}</h2>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap; margin-bottom:0.75rem;">
            <button class="btn" type="button" {{on "click" (fn @controller.loadStorageHealth "target")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.refresh_health"}}
            </button>
            <button class="btn" type="button" {{on "click" (fn @controller.runStorageProbe "target")}} disabled={{@controller.storageBusy}}>
              {{i18n "admin.media_gallery.migrations.run_probe"}}
            </button>
          </div>
          {{#if @controller.targetHealth}}
            <div><strong>backend:</strong> {{@controller.targetHealth.backend}}</div>
            <div><strong>profile:</strong> {{@controller.targetHealth.profile_key}}</div>
            <div><strong>available:</strong> {{if @controller.targetHealth.available "yes" "no"}}</div>
            <div><strong>validation errors:</strong> {{@controller.targetHealth.validation_errors.length}}</div>
          {{/if}}
          {{#if @controller.targetProbe}}
            <div style="margin-top:0.75rem;"><strong>probe:</strong> {{if @controller.targetProbe.ok "ok" "failed"}}</div>
          {{/if}}
        </div>
      </div>

      <div class="admin-detail-panel" style="padding:1rem; border:1px solid var(--primary-low); border-radius:8px; margin-bottom:1rem;">
        <h2 style="margin-top:0;">{{i18n "admin.media_gallery.migrations.find_media"}}</h2>
        <div style="display:flex; gap:0.75rem; flex-wrap:wrap; align-items:end;">
          <div>
            <label>{{i18n "admin.media_gallery.migrations.search_label"}}</label>
            <input type="text" value={{@controller.searchQuery}} placeholder={{i18n "admin.media_gallery.migrations.search_placeholder"}} {{on "input" @controller.onSearchInput}} {{on "keydown" @controller.onSearchKeydown}} style="min-width:320px;" />
          </div>
          <div>
            <label>{{i18n "admin.media_gallery.migrations.backend_filter"}}</label>
            <select value={{@controller.backendFilter}} {{on "change" @controller.onBackendFilterChange}}>
              <option value="all">all</option>
              <option value="local">local</option>
              <option value="s3">s3</option>
            </select>
          </div>
          <div>
            <label>{{i18n "admin.media_gallery.migrations.status_filter"}}</label>
            <select value={{@controller.statusFilter}} {{on "change" @controller.onStatusFilterChange}}>
              <option value="all">all</option>
              <option value="queued">queued</option>
              <option value="processing">processing</option>
              <option value="ready">ready</option>
              <option value="failed">failed</option>
            </select>
          </div>
          <div>
            <label>{{i18n "admin.media_gallery.migrations.hls_filter"}}</label>
            <select value={{@controller.hlsFilter}} {{on "change" @controller.onHlsFilterChange}}>
              <option value="all">all</option>
              <option value="yes">yes</option>
              <option value="no">no</option>
            </select>
          </div>
          <div>
            <label>{{i18n "admin.media_gallery.migrations.limit_label"}}</label>
            <input type="number" min="1" max="100" value={{@controller.limit}} {{on "input" @controller.onLimitInput}} style="width:90px;" />
          </div>
          <div>
            <label>{{i18n "admin.media_gallery.migrations.sort_label"}}</label>
            <select value={{@controller.sortBy}} {{on "change" @controller.onSortByChange}}>
              <option value="created_at_desc">newest</option>
              <option value="created_at_asc">oldest</option>
              <option value="title_asc">title A-Z</option>
              <option value="title_desc">title Z-A</option>
              <option value="backend_asc">backend A-Z</option>
              <option value="backend_desc">backend Z-A</option>
            </select>
          </div>
          <div>
            <button class="btn btn-primary" type="button" {{on "click" @controller.search}} disabled={{@controller.isSearching}}>
              {{if @controller.isSearching "Searching…" (i18n "admin.media_gallery.migrations.search_button")}}
            </button>
          </div>
        </div>
        <div class="desc" style="margin-top:0.5rem;">{{@controller.searchInfo}}</div>
        {{#if @controller.searchError}}
          <div class="alert alert-error" style="margin-top:0.75rem;">{{@controller.searchError}}</div>
        {{/if}}
      </div>

      <div style="display:grid; grid-template-columns: minmax(420px, 1.1fr) minmax(420px, 1fr); gap:1rem; align-items:start;">
        <div class="admin-detail-panel" style="padding:1rem; border:1px solid var(--primary-low); border-radius:8px;">
          <h2 style="margin-top:0;">{{i18n "admin.media_gallery.migrations.results"}}</h2>
          <table class="table">
            <thead>
              <tr>
                <th>public_id</th>
                <th>title</th>
                <th>status</th>
                <th>backend</th>
                <th>HLS</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each @controller.sortedResults as |item|}}
                <tr>
                  <td><code>{{item.public_id}}</code></td>
                  <td>{{item.title}}</td>
                  <td>{{item.status}}</td>
                  <td>{{item.managed_storage_backend}}<br /><small>{{item.managed_storage_profile}}</small></td>
                  <td>{{if item.has_hls "yes" "no"}}</td>
                  <td><button class="btn btn-small" type="button" {{on "click" (fn @controller.selectItem item)}}>{{i18n "admin.media_gallery.migrations.select_button"}}</button></td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>

        <div class="admin-detail-panel" style="padding:1rem; border:1px solid var(--primary-low); border-radius:8px;">
          <h2 style="margin-top:0;">{{i18n "admin.media_gallery.migrations.selected_item"}}</h2>
          {{#if @controller.hasSelectedItem}}
            <div><strong>public_id:</strong> <code>{{@controller.selectedPublicId}}</code></div>
            <div style="margin-top:0.5rem; display:flex; gap:0.75rem; flex-wrap:wrap;">
              <label><input type="checkbox" checked={{@controller.autoSwitch}} {{on "change" @controller.onAutoSwitchChange}} /> auto switch after copy</label>
              <label><input type="checkbox" checked={{@controller.autoCleanup}} {{on "change" @controller.onAutoCleanupChange}} /> auto cleanup</label>
              <label><input type="checkbox" checked={{@controller.forceAction}} {{on "change" @controller.onForceActionChange}} /> force</label>
            </div>
            <div style="margin-top:0.75rem; display:flex; gap:0.75rem; flex-wrap:wrap;">
              <button class="btn" type="button" {{on "click" @controller.refreshSelected}} disabled={{@controller.isLoadingSelection}}>{{i18n "admin.media_gallery.migrations.refresh_selected"}}</button>
              <button class="btn" type="button" {{on "click" @controller.copyToTarget}} disabled={{@controller.copyDisabled}}>{{i18n "admin.media_gallery.migrations.copy_button"}}</button>
              <button class="btn" type="button" {{on "click" @controller.switchToTarget}} disabled={{@controller.switchDisabled}}>{{i18n "admin.media_gallery.migrations.switch_button"}}</button>
              <button class="btn" type="button" {{on "click" @controller.cleanupSource}} disabled={{@controller.cleanupDisabled}}>{{i18n "admin.media_gallery.migrations.cleanup_button"}}</button>
            </div>

            {{#if @controller.lastActionMessage}}
              <div class="alert alert-info" style="margin-top:0.75rem;">{{@controller.lastActionMessage}}</div>
            {{/if}}
            {{#if @controller.actionError}}
              <div class="alert alert-error" style="margin-top:0.75rem;">{{@controller.actionError}}</div>
            {{/if}}
            {{#if @controller.selectedError}}
              <div class="alert alert-error" style="margin-top:0.75rem;">{{@controller.selectedError}}</div>
            {{/if}}

            {{#if @controller.selectedDiagnostics}}
              <div style="margin-top:1rem;"><strong>Current backend/profile:</strong> {{@controller.selectedDiagnostics.managed_storage_backend}} / {{@controller.selectedDiagnostics.managed_storage_profile}}</div>
              <div><strong>Delivery:</strong> {{@controller.selectedDiagnostics.delivery_mode}}</div>
            {{/if}}

            {{#if @controller.selectedPlan}}
              <h3 style="margin-top:1rem;">{{i18n "admin.media_gallery.migrations.plan"}}</h3>
              <pre style="max-height:260px; overflow:auto; white-space:pre-wrap;">{{@controller.planJson}}</pre>
            {{/if}}

            {{#if @controller.selectedDiagnostics}}
              <h3 style="margin-top:1rem;">{{i18n "admin.media_gallery.migrations.diagnostics"}}</h3>
              <pre style="max-height:320px; overflow:auto; white-space:pre-wrap;">{{@controller.diagnosticsJson}}</pre>
            {{/if}}
          {{else}}
            <p>{{i18n "admin.media_gallery.migrations.no_selection"}}</p>
          {{/if}}
        </div>
      </div>
    </div>
  </template>
);
