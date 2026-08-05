import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";

export default class MediaGalleryHealthSections extends Component {
  <template>
      <div class="mg-health__sections">
        {{#each @sections as |healthSection|}}
          <section class="mg-health__panel">
            <div class="mg-health__panel-header">
              <div class="mg-health__panel-copy">
                <h2>{{healthSection.title}}</h2>
                <p class="mg-health__muted">{{healthSection.description}}</p>
              </div>
              <div class="mg-health__actions">
                {{#if healthSection.hasHelp}}
                  <span class="mg-health__info" tabindex="0">i<span class="mg-health__info-text">{{healthSection.help}}</span></span>
                {{/if}}
                <span class="mg-health__badge {{healthSection.badgeClass}}">{{healthSection.severityLabel}}</span>
              </div>
            </div>

            <div class="mg-health__issue-list" style="margin-top: 1rem;">
              {{#each healthSection.issues as |issue|}}
                <article class="mg-health__issue">
                  <span class="mg-health__icon {{issue.iconClass}}">{{issue.icon}}</span>
                  <div>
                    <div class="mg-health__issue-title">
                      <span>{{issue.label}}</span>
                      {{#if issue.countLabel}}
                        <span class="mg-health__badge">{{issue.countLabel}}</span>
                      {{/if}}
                    </div>
                    <p class="mg-health__issue-message">{{issue.message}}</p>
                    {{#if issue.hasDetail}}
                      <p class="mg-health__item-detail">{{issue.detail}}</p>
                    {{/if}}
                    {{#if issue.hasExamples}}
                      <div class="mg-health__examples">
                        {{#each issue.examples as |example|}}
                          <div class="mg-health__example">
                            {{#if example.url}}
                              <a class="mg-health__example-title" href={{example.url}} target="_blank" rel="noopener noreferrer">{{example.title}}</a>
                            {{else}}
                              <div class="mg-health__example-title">{{example.title}}</div>
                            {{/if}}
                            {{#if example.subtitle}}
                              <div class="mg-health__example-subtitle">{{example.subtitle}}</div>
                            {{/if}}
                            {{#if example.hasMetaRows}}
                              <div class="mg-health__example-meta">
                                {{#each example.metaRows as |row|}}
                                  <div class="mg-health__example-meta-row {{row.className}} {{if row.emphasis "is-emphasis"}}">
                                    <div class="mg-health__example-meta-label">{{row.label}}</div>
                                    <div class="mg-health__example-meta-value">{{row.value}}</div>
                                  </div>
                                {{/each}}
                              </div>
                            {{/if}}
                            {{#if example.hasDetail}}
                              <div class="mg-health__example-subtitle">{{example.detail}}</div>
                            {{/if}}
                            {{#if example.hasSuggestion}}
                              <div class="mg-health__example-subtitle"><strong>Suggested action:</strong> {{example.suggestion}}</div>
                            {{/if}}
                            <div class="mg-health__example-actions">
                              {{#if example.url}}
                                <a class="btn" href={{example.url}} target="_blank" rel="noopener noreferrer">Open in management</a>
                              {{/if}}
                              {{#if example.canCleanup}}
                                <button class="btn btn-danger" type="button" disabled={{@controller.isLoading}} title={{example.cleanupHint}} {{on "click" (fn @controller.cleanupReconciliationFinding issue example)}}>{{example.cleanupLabel}}</button>
                              {{/if}}
                              {{#if example.canIgnore}}
                                <button class="btn" type="button" disabled={{@controller.isLoading}} {{on "click" (fn @controller.ignoreFinding issue example)}}>Ignore finding</button>
                              {{/if}}
                            </div>
                          </div>
                        {{/each}}
                      </div>
                    {{/if}}
                  </div>
                  <span class="mg-health__badge {{issue.badgeClass}}">{{issue.severityLabel}}</span>
                </article>
              {{/each}}
            </div>
          </section>
        {{/each}}
      </div>
  </template>
}
