import RouteTemplate from "ember-route-template";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-jobs {
        --mg-jobs-surface: var(--secondary);
        --mg-jobs-surface-alt: var(--primary-very-low);
        --mg-jobs-border: var(--primary-low);
        --mg-jobs-muted: var(--primary-medium);
        --mg-jobs-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-jobs h1,
      .media-gallery-jobs h2,
      .media-gallery-jobs h3,
      .media-gallery-jobs p {
        margin: 0;
      }

      .mg-jobs__hero,
      .mg-jobs__panel,
      .mg-jobs__card,
      .mg-jobs__row {
        background: var(--mg-jobs-surface);
        border: 1px solid var(--mg-jobs-border);
        border-radius: var(--mg-jobs-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-jobs__hero,
      .mg-jobs__panel {
        padding: 1.1rem 1.25rem;
      }

      .mg-jobs__hero,
      .mg-jobs__panel-header,
      .mg-jobs__row-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-jobs__hero-actions {
        display: flex;
        align-items: center;
        justify-content: flex-end;
        flex-wrap: wrap;
        gap: 0.65rem;
      }

      .mg-jobs__copy,
      .mg-jobs__panel-copy,
      .mg-jobs__row-main {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 0;
      }

      .mg-jobs__muted,
      .mg-jobs__meta,
      .mg-jobs__field-label {
        color: var(--mg-jobs-muted);
        font-size: var(--font-down-1);
      }

      .mg-jobs__meta,
      .mg-jobs__field-label {
        font-size: var(--font-down-1);
      }

      .mg-jobs__summary-grid,
      .mg-jobs__type-grid,
      .mg-jobs__rows,
      .mg-jobs__details {
        display: grid;
        gap: 0.75rem;
      }

      .mg-jobs__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      }

      .mg-jobs__type-grid {
        grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
        margin-top: 0.95rem;
      }

      .mg-jobs__card {
        padding: 0.85rem 1rem;
        background: var(--mg-jobs-surface-alt);
      }

      .mg-jobs__card-value {
        font-size: var(--font-up-2);
        font-weight: 800;
        line-height: 1.15;
        margin-top: 0.25rem;
      }

      .mg-jobs__card .mg-jobs__meta {
        display: block;
        margin-top: 0.5rem;
      }

      a.mg-jobs__card,
      span.mg-jobs__card {
        color: var(--primary);
        display: block;
        text-decoration: none;
      }

      a.mg-jobs__card:hover,
      a.mg-jobs__card:focus,
      a.mg-jobs__card.is-active {
        border-color: var(--tertiary-medium);
      }

      a.mg-jobs__card.is-active,
      span.mg-jobs__card.is-active {
        box-shadow: inset 0 0 0 1px var(--tertiary-medium);
      }

      .mg-jobs__card.is-disabled,
      .mg-jobs__filter-pill.is-disabled {
        opacity: 0.48;
        cursor: not-allowed;
      }

      .mg-jobs__filter-groups {
        display: grid;
        gap: 0.85rem;
        margin-top: 1rem;
      }

      .mg-jobs__filter-group {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.45rem;
      }

      .mg-jobs__filter-label {
        color: var(--mg-jobs-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
        margin-right: 0.25rem;
      }

      .mg-jobs__filter-pill {
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-medium);
        display: inline-flex;
        align-items: center;
        font-size: var(--font-down-1);
        font-weight: 700;
        line-height: 1;
        padding: 0.42rem 0.65rem;
        text-decoration: none;
      }

      .mg-jobs__filter-pill.is-active {
        border-color: var(--tertiary-medium);
        background: var(--tertiary-low);
        color: var(--tertiary);
      }

      .mg-jobs__actions {
        flex-wrap: wrap;
        align-items: center;
      }

      .mg-jobs__rows {
        margin-top: 1rem;
      }

      .mg-jobs__row {
        padding: 0.95rem 1rem;
      }

      .mg-jobs__row-title {
        color: var(--tertiary);
        font-size: var(--font-up-1);
        font-weight: 800;
        overflow-wrap: anywhere;
      }

      .mg-jobs__badge {
        display: inline-flex;
        align-items: center;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-medium);
        font-size: var(--font-down-1);
        font-weight: 700;
        line-height: 1;
        padding: 0.36rem 0.65rem;
        white-space: nowrap;
      }

      .mg-jobs__badge.is-info {
        border-color: var(--tertiary-low);
        background: var(--tertiary-low);
        color: var(--tertiary);
      }

      .mg-jobs__badge.is-success {
        border-color: var(--success-low);
        background: var(--success-low);
        color: var(--success);
      }

      .mg-jobs__badge.is-danger {
        border-color: var(--danger-low);
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-jobs__details {
        grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
        margin-top: 0.85rem;
      }

      .mg-jobs__detail {
        border: 1px solid var(--mg-jobs-border);
        border-radius: 14px;
        background: var(--mg-jobs-surface-alt);
        padding: 0.7rem 0.8rem;
        min-width: 0;
      }

      .mg-jobs__detail-value {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-jobs__row-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
        margin-top: 0.85rem;
      }

      .mg-jobs__empty,
      .mg-jobs__error {
        border-radius: 14px;
        padding: 0.75rem 0.9rem;
      }

      .mg-jobs__error {
        background: var(--danger-low);
        color: var(--danger);
      }

      .mg-jobs__empty {
        background: var(--primary-very-low);
        color: var(--mg-jobs-muted);
        text-align: center;
      }

      @media (max-width: 700px) {
        .mg-jobs__hero,
        .mg-jobs__panel-header,
        .mg-jobs__row-header {
          flex-direction: column;
        }
      }
    </style>

    <div class="media-gallery-jobs">
      <section class="mg-jobs__hero">
        <div class="mg-jobs__copy">
          <h1>Background jobs</h1>
          <p class="mg-jobs__muted">
            Central read-only overview of Media Gallery processing, migration, AES/HLS, identify, and test-download activity.
          </p>
          {{#if @controller.generatedAtDisplay}}
            <p class="mg-jobs__meta">Last refreshed: {{@controller.generatedAtDisplay}}</p>
          {{/if}}
        </div>
        <div class="mg-jobs__hero-actions">
          <a class="btn btn-primary" href={{@controller.refreshUrl}}>Refresh</a>
          <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="mg-jobs__error">{{@controller.error}}</div>
      {{/if}}

      <section class="mg-jobs__panel">
        <div class="mg-jobs__panel-header">
          <div class="mg-jobs__panel-copy">
            <h2>Status</h2>
            <p class="mg-jobs__muted">Open a status to filter the list below. Counts follow the selected job type.</p>
          </div>
        </div>
        <div class="mg-jobs__summary-grid" aria-label="Job status summary">
          {{#each @controller.statusCards as |statusCard|}}
            {{#if statusCard.isDisabled}}
              <span class="mg-jobs__card is-disabled">
                <div class="mg-jobs__field-label">{{statusCard.label}}</div>
                <div class="mg-jobs__card-value">{{statusCard.countLabel}}</div>
                <p class="mg-jobs__meta">{{statusCard.description}}</p>
              </span>
            {{else}}
              <a class="mg-jobs__card {{if statusCard.isActive "is-active"}}" href={{statusCard.href}}>
                <div class="mg-jobs__field-label">{{statusCard.label}}</div>
                <div class="mg-jobs__card-value">{{statusCard.countLabel}}</div>
                <p class="mg-jobs__meta">{{statusCard.description}}</p>
              </a>
            {{/if}}
          {{/each}}
        </div>
      </section>

      <section class="mg-jobs__panel">
        <div class="mg-jobs__panel-header">
          <div class="mg-jobs__panel-copy">
            <h2>Job types</h2>
            <p class="mg-jobs__muted">Open a type to filter the list below. Counts follow the selected status filter.</p>
          </div>
        </div>
        <div class="mg-jobs__type-grid">
          {{#each @controller.typeCards as |typeCard|}}
            {{#if typeCard.isDisabled}}
              <span class="mg-jobs__card is-disabled">
                <div class="mg-jobs__field-label">{{typeCard.label}}</div>
                <div class="mg-jobs__card-value">{{typeCard.countLabel}}</div>
              </span>
            {{else}}
              <a class="mg-jobs__card {{if typeCard.isActive "is-active"}}" href={{typeCard.href}}>
                <div class="mg-jobs__field-label">{{typeCard.label}}</div>
                <div class="mg-jobs__card-value">{{typeCard.countLabel}}</div>
              </a>
            {{/if}}
          {{/each}}
        </div>
      </section>

      <section class="mg-jobs__panel">
        <div class="mg-jobs__panel-header">
          <div class="mg-jobs__panel-copy">
            <h2>Jobs and recent activity</h2>
            <p class="mg-jobs__muted">
              This page is read-only. Use Management, Migration manager, Identify, or Test downloads for the actual action controls.
            </p>
            <p class="mg-jobs__meta">{{@controller.showingSummaryLabel}}</p>
          </div>
        </div>

        <div class="mg-jobs__filter-groups">
          <div class="mg-jobs__filter-group">
            <span class="mg-jobs__filter-label">Limit</span>
            {{#each @controller.limitLinks as |option|}}
              <a class="mg-jobs__filter-pill {{if option.isActive "is-active"}}" href={{option.href}}>{{option.label}}</a>
            {{/each}}
          </div>
        </div>

        {{#if @controller.hasRows}}
          <div class="mg-jobs__rows">
            {{#each @controller.rows as |row|}}
              <article class="mg-jobs__row">
                <div class="mg-jobs__row-header">
                  <div class="mg-jobs__row-main">
                    <div class="mg-jobs__meta">{{row.group_label}} • {{row.label}}</div>
                    <h3 class="mg-jobs__row-title">{{row.titleLabel}}</h3>
                    {{#if row.itemMeta}}
                      <div class="mg-jobs__meta">{{row.itemMeta}}</div>
                    {{/if}}
                  </div>
                  <span class="mg-jobs__badge {{row.statusClass}}">{{row.statusLabel}}</span>
                </div>

                <div class="mg-jobs__details">
                  {{#if row.updatedAtDisplay}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Updated</div>
                      <div class="mg-jobs__detail-value">{{row.updatedAtDisplay}}</div>
                    </div>
                  {{/if}}
                  {{#if row.source_profile}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Source</div>
                      <div class="mg-jobs__detail-value">{{row.source_profile}}</div>
                    </div>
                  {{/if}}
                  {{#if row.target_profile}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Target</div>
                      <div class="mg-jobs__detail-value">{{row.target_profile}}</div>
                    </div>
                  {{/if}}
                  {{#if row.progressLabel}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Progress</div>
                      <div class="mg-jobs__detail-value">{{row.progressLabel}}</div>
                    </div>
                  {{/if}}
                  {{#if row.current_object}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Current object</div>
                      <div class="mg-jobs__detail-value">{{row.current_object}}</div>
                    </div>
                  {{/if}}
                  {{#if row.detail}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Details</div>
                      <div class="mg-jobs__detail-value">{{row.detail}}</div>
                    </div>
                  {{/if}}
                  {{#if row.error}}
                    <div class="mg-jobs__detail">
                      <div class="mg-jobs__field-label">Last error</div>
                      <div class="mg-jobs__detail-value">{{row.error}}</div>
                    </div>
                  {{/if}}
                </div>

                <div class="mg-jobs__row-actions">
                  {{#if row.primaryUrl}}
                    <a class="btn btn-small" href={{row.primaryUrl}}>{{row.primaryLabel}}</a>
                  {{/if}}
                  {{#if row.secondaryUrl}}
                    <a class="btn btn-small" href={{row.secondaryUrl}}>{{row.secondaryLabel}}</a>
                  {{/if}}
                  {{#if row.logs_url}}
                    <a class="btn btn-small" href={{row.logs_url}}>View logs</a>
                  {{/if}}
                </div>
              </article>
            {{/each}}
          </div>
        {{else}}
          <div class="mg-jobs__empty">
            No jobs or recent activity matched the current filters.
          </div>
        {{/if}}
      </section>
    </div>
  </template>
);
