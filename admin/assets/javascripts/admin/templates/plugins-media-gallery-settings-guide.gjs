import RouteTemplate from "ember-route-template";

export default RouteTemplate(
  <template>
    <style>
      .media-gallery-settings-guide {
        --mg-guide-surface: var(--secondary);
        --mg-guide-surface-alt: var(--primary-very-low);
        --mg-guide-border: var(--primary-low);
        --mg-guide-muted: var(--primary-medium);
        --mg-guide-radius: 18px;
        --mg-guide-ok-bg: #ebf9ef;
        --mg-guide-ok-fg: #0b7a2a;
        --mg-guide-warn-bg: #fff4e5;
        --mg-guide-warn-fg: #b45309;
        --mg-guide-info-bg: #eef2ff;
        --mg-guide-info-fg: #4338ca;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .media-gallery-settings-guide h1,
      .media-gallery-settings-guide h2,
      .media-gallery-settings-guide h3,
      .media-gallery-settings-guide h4,
      .media-gallery-settings-guide p {
        margin: 0;
      }

      .mg-guide__panel,
      .mg-guide__hero,
      .mg-guide__card,
      .mg-guide__setting-row,
      .mg-guide__preset {
        background: var(--mg-guide-surface);
        border: 1px solid var(--mg-guide-border);
        border-radius: var(--mg-guide-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .mg-guide__hero,
      .mg-guide__panel {
        padding: 1.15rem 1.25rem;
      }

      .mg-guide__hero,
      .mg-guide__panel-header,
      .mg-guide__row-header,
      .mg-guide__card-header,
      .mg-guide__preset-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .mg-guide__copy,
      .mg-guide__panel-copy,
      .mg-guide__row-copy,
      .mg-guide__card-copy,
      .mg-guide__preset-copy {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .mg-guide__muted,
      .mg-guide__description,
      .mg-guide__note,
      .mg-guide__setting-help,
      .mg-guide__preset-body {
        color: var(--mg-guide-muted);
      }

      .mg-guide__actions,
      .mg-guide__button-row {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 0.65rem;
      }

      .mg-guide__summary-grid,
      .mg-guide__preset-grid,
      .mg-guide__section-grid,
      .mg-guide__settings-list {
        display: grid;
        gap: 1rem;
      }

      .mg-guide__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      }

      .mg-guide__preset-grid {
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      }

      .mg-guide__section-grid {
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      }

      .mg-guide__section-body {
        margin-top: 1rem;
      }

      .mg-guide__card,
      .mg-guide__preset {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        padding: 1rem 1.05rem;
        background: var(--mg-guide-surface-alt);
      }

      .mg-guide__card-title,
      .mg-guide__preset-title {
        font-size: var(--font-up-1);
        line-height: 1.2;
        font-weight: 700;
      }

      .mg-guide__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: max-content;
        max-width: 100%;
        white-space: nowrap;
        border-radius: 999px;
        border: 1px solid var(--mg-guide-border);
        background: var(--primary-very-low);
        color: var(--primary-medium);
        font-size: var(--font-down-1);
        line-height: 1;
        padding: 0.35rem 0.6rem;
        font-weight: 700;
      }

      .mg-guide__badge.is-ok {
        background: var(--mg-guide-ok-bg);
        color: var(--mg-guide-ok-fg);
        border-color: #92d2a2;
      }

      .mg-guide__badge.is-warning {
        background: var(--mg-guide-warn-bg);
        color: var(--mg-guide-warn-fg);
        border-color: #fdba74;
      }

      .mg-guide__badge.is-info {
        background: var(--mg-guide-info-bg);
        color: var(--mg-guide-info-fg);
        border-color: #c7d2fe;
      }

      .mg-guide__settings-list {
        grid-template-columns: 1fr;
      }

      .mg-guide__setting-row {
        display: grid;
        grid-template-columns: minmax(0, 1.1fr) minmax(210px, 0.65fr) auto;
        gap: 1rem;
        align-items: start;
        padding: 0.95rem 1rem;
        background: var(--mg-guide-surface-alt);
      }

      .mg-guide__setting-name {
        font-family: var(--d-font-family--monospace, monospace);
        font-size: var(--font-down-1);
        overflow-wrap: anywhere;
      }

      .mg-guide__setting-value {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
      }

      .mg-guide__value-label {
        color: var(--mg-guide-muted);
        font-size: var(--font-down-1);
      }

      .mg-guide__value-text {
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .mg-guide__list {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        margin: 0;
        padding-left: 1.1rem;
      }

      .mg-guide__list li {
        color: var(--mg-guide-muted);
      }

      .mg-guide__callout {
        border: 1px solid var(--tertiary-low);
        border-radius: 16px;
        background: var(--tertiary-very-low);
        padding: 0.95rem 1rem;
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
      }

      @media (max-width: 900px) {
        .mg-guide__setting-row {
          grid-template-columns: 1fr;
        }
      }

      @media (max-width: 700px) {
        .mg-guide__hero,
        .mg-guide__panel-header,
        .mg-guide__row-header,
        .mg-guide__card-header,
        .mg-guide__preset-header {
          flex-direction: column;
          align-items: stretch;
        }
      }
    </style>

    <div class="media-gallery-settings-guide">
      <section class="mg-guide__hero">
        <div class="mg-guide__copy">
          <h1>Media Gallery settings guide</h1>
          <p class="mg-guide__muted">
            A non-technical guide to the most important Media Gallery settings. Use this page to understand which settings matter, why they matter, and where to adjust them.
          </p>
        </div>
        <div class="mg-guide__actions">
          <a class="btn btn-primary" href="/admin/site_settings/category/all_results?filter=media_gallery">Open all settings</a>
          <a class="btn" href="/admin/plugins/media-gallery">Back to overview</a>
        </div>
      </section>

      <section class="mg-guide__summary-grid" aria-label="Guide summary">
        <article class="mg-guide__card">
          <div class="mg-guide__card-header">
            <div class="mg-guide__card-copy">
              <span class="mg-guide__badge is-info">Purpose</span>
              <h2 class="mg-guide__card-title">Settings stay in Discourse</h2>
            </div>
          </div>
          <p class="mg-guide__description">
            This guide does not change settings directly. It explains the settings and links you to the standard Discourse settings page where values can be changed safely.
          </p>
        </article>
        <article class="mg-guide__card">
          <div class="mg-guide__card-header">
            <div class="mg-guide__card-copy">
              <span class="mg-guide__badge is-ok">Recommended</span>
              <h2 class="mg-guide__card-title">Use security presets as a checklist</h2>
            </div>
          </div>
          <p class="mg-guide__description">
            Start with the production/protected-content checklist below, then review performance-sensitive options such as proxy delivery, thumbnail caching and request limits.
          </p>
        </article>
        <article class="mg-guide__card">
          <div class="mg-guide__card-header">
            <div class="mg-guide__card-copy">
              <span class="mg-guide__badge is-warning">Caution</span>
              <h2 class="mg-guide__card-title">Some values are environment specific</h2>
            </div>
          </div>
          <p class="mg-guide__description">
            Test servers, HTTP local storage, shared IP networks and large libraries may need different values than production. Change one area at a time and test playback after each change.
          </p>
        </article>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Recommended baseline checklists</h2>
            <p class="mg-guide__muted">Use these as practical starting points. They are guidance, not automatic changes.</p>
          </div>
        </div>
        <div class="mg-guide__preset-grid mg-guide__section-body">
          <article class="mg-guide__preset">
            <div class="mg-guide__preset-header">
              <div class="mg-guide__preset-copy">
                <span class="mg-guide__badge is-ok">Production</span>
                <h3 class="mg-guide__preset-title">Normal protected media</h3>
              </div>
            </div>
            <ul class="mg-guide__list">
              <li>Use private managed storage for processed media.</li>
              <li>Prefer HLS for video and block direct stream fallback for protected content.</li>
              <li>Keep stream tokens bound to user and browser session.</li>
              <li>Keep forensic retention to a defined non-zero policy value.</li>
            </ul>
          </article>
          <article class="mg-guide__preset">
            <div class="mg-guide__preset-header">
              <div class="mg-guide__preset-copy">
                <span class="mg-guide__badge is-warning">Strict</span>
                <h3 class="mg-guide__preset-title">Higher download deterrence</h3>
              </div>
            </div>
            <ul class="mg-guide__list">
              <li>Enable HLS-only video mode and HLS fingerprinting.</li>
              <li>Enable visible watermarking and prevent user opt-out.</li>
              <li>Use proxy delivery for sensitive S3/R2 media where performance allows.</li>
              <li>Review stream anomaly logs before enabling hard blocking thresholds.</li>
            </ul>
          </article>
          <article class="mg-guide__preset">
            <div class="mg-guide__preset-header">
              <div class="mg-guide__preset-copy">
                <span class="mg-guide__badge is-info">Staging</span>
                <h3 class="mg-guide__preset-title">HTTP test environments</h3>
              </div>
            </div>
            <ul class="mg-guide__list">
              <li>Use canonical_only for forensic HTTP source URLs when the test site itself runs on HTTP.</li>
              <li>Do not copy staging-only HTTP exceptions into production.</li>
              <li>Keep hard stream rate limits disabled until normal playback traffic is understood.</li>
            </ul>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Security and download prevention</h2>
            <p class="mg-guide__muted">These settings have the biggest effect on token reuse, stream fallback, watermarking and forensic attribution.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-security">Open Security status</a>
        </div>
        <div class="mg-guide__settings-list mg-guide__section-body">
          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Enable HLS packaging</h3>
              <code class="mg-guide__setting-name">media_gallery_hls_enabled</code>
              <p class="mg-guide__setting-help">Allows videos to be served as segmented HLS playlists. Needed for HLS-only delivery and HLS fingerprinting.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">true</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_hls_enabled">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Forensic HLS fingerprinting</h3>
              <code class="mg-guide__setting-name">media_gallery_fingerprint_enabled</code>
              <p class="mg-guide__setting-help">Enables per-user/per-session A/B HLS segment choices for newly packaged videos, making leaked streams easier to attribute.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">true for protected videos</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_fingerprint_enabled">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Visible watermarking</h3>
              <code class="mg-guide__setting-name">media_gallery_watermark_enabled</code>
              <p class="mg-guide__setting-help">Adds a visible deterrent and attribution signal. This is not DRM, but it discourages casual sharing and helps identify sources.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">true for protected media</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_watermark_enabled">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Watermark user opt-out</h3>
              <code class="mg-guide__setting-name">media_gallery_watermark_user_can_toggle</code>
              <p class="mg-guide__setting-help">If users can disable the visible watermark, download deterrence is weaker. Leave enabled only if user choice is more important than enforcement.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">false for protected media</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_watermark_user_can_toggle">Open setting</a>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Tokens, sessions and scraping detection</h2>
            <p class="mg-guide__muted">These settings reduce token sharing and help detect abnormal stream usage without immediately blocking normal users.</p>
          </div>
        </div>
        <div class="mg-guide__settings-list mg-guide__section-body">
          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Stream token lifetime</h3>
              <code class="mg-guide__setting-name">media_gallery_stream_token_ttl_minutes</code>
              <p class="mg-guide__setting-help">Shorter tokens reduce replay time if a URL leaks. Very short values can affect unstable networks or very long sessions.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">5–15 minutes</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_stream_token_ttl_minutes">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Token binding</h3>
              <code class="mg-guide__setting-name">media_gallery_bind_stream_to_user / session / ip</code>
              <p class="mg-guide__setting-help">User and session binding are usually safe and useful. IP binding is stronger but may break users on mobile, VPN or changing networks.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">user true, session true, IP optional</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_bind_stream_to">Open settings</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Stream anomaly logging</h3>
              <code class="mg-guide__setting-name">media_gallery_log_stream_anomalies</code>
              <p class="mg-guide__setting-help">Logs suspicious request patterns, such as many stream or range requests per token. Good first step before enabling hard blocking.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">true</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_log_stream_anomalies">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Hard stream limits</h3>
              <code class="mg-guide__setting-name">media_gallery_stream_requests_per_token_per_minute</code>
              <p class="mg-guide__setting-help">Blocks excessive /media/stream requests per token. Keep at 0 until you have reviewed logs, because media players can legitimately make many requests.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">0 first, tune later</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_stream_requests_per_token_per_minute">Open setting</a>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Storage and delivery</h2>
            <p class="mg-guide__muted">These settings determine where files live and whether browsers see Discourse tokenized URLs or short-lived object-storage URLs.</p>
          </div>
          <a class="btn" href="/admin/plugins/media-gallery-migrations">Open storage tools</a>
        </div>
        <div class="mg-guide__settings-list mg-guide__section-body">
          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Default storage profile</h3>
              <code class="mg-guide__setting-name">media_gallery_default_storage_profile_key</code>
              <p class="mg-guide__setting-help">Selects where newly managed media is stored: local, S3 profile 1, S3 profile 2 or S3 profile 3. Migrations can move existing media separately.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Options</span><span class="mg-guide__value-text">local / s3_1 / s3_2 / s3_3</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_default_storage_profile_key">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Delivery mode</h3>
              <code class="mg-guide__setting-name">media_gallery_delivery_mode_default</code>
              <p class="mg-guide__setting-help">stream keeps delivery behind Discourse. x_accel uses the reverse proxy for local files. redirect exposes short-lived S3/R2 signed URLs and is faster but weaker for strict download deterrence.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Options</span><span class="mg-guide__value-text">stream / x_accel / redirect</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_delivery_mode_default">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Private storage root</h3>
              <code class="mg-guide__setting-name">media_gallery_private_root_path</code>
              <p class="mg-guide__setting-help">Root path for private local managed media. Keep this outside public web paths and ensure it is covered by the backup policy you want.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">/shared/media_gallery/private or equivalent</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_private_root_path">Open setting</a>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Forensics, privacy and admin evidence</h2>
            <p class="mg-guide__muted">These settings control forensic identify behavior, export retention and privacy-sensitive evidence files.</p>
          </div>
          <div class="mg-guide__button-row">
            <a class="btn" href="/admin/plugins/media-gallery-forensics-identify">Open identify</a>
            <a class="btn" href="/admin/plugins/media-gallery-forensics-exports">Open exports</a>
          </div>
        </div>
        <div class="mg-guide__settings-list mg-guide__section-body">
          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Forensic HTTP source URL policy</h3>
              <code class="mg-guide__setting-name">media_gallery_forensics_http_source_url_policy</code>
              <p class="mg-guide__setting-help">Controls whether admin forensic identify accepts http:// source URLs. deny_all is strict production behavior. canonical_only is useful for HTTP test sites. allow_all is only for temporary troubleshooting.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Options</span><span class="mg-guide__value-text">deny_all / canonical_only / allow_all</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_forensics_http_source_url_policy">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Playback-session retention</h3>
              <code class="mg-guide__setting-name">media_gallery_forensics_playback_session_retention_days</code>
              <p class="mg-guide__setting-help">Controls how long forensic playback records are kept. These can include user, session, IP and user-agent signals, so use a real privacy policy value.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">90 days or policy</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_forensics_playback_session_retention_days">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Forensic export retention</h3>
              <code class="mg-guide__setting-name">media_gallery_forensics_export_retention_days</code>
              <p class="mg-guide__setting-help">Controls how long generated CSV/export files remain available. Exports are sensitive evidence files and should not be kept indefinitely without a reason.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">90 days or policy</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_forensics_export_retention_days">Open setting</a>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__panel-header">
          <div class="mg-guide__panel-copy">
            <h2>Upload processing and compatibility</h2>
            <p class="mg-guide__muted">These settings affect what users may upload and how much processing work the server performs.</p>
          </div>
        </div>
        <div class="mg-guide__settings-list mg-guide__section-body">
          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Fail closed on unrecognized media</h3>
              <code class="mg-guide__setting-name">media_gallery_fail_closed_on_unrecognized_media</code>
              <p class="mg-guide__setting-help">Rejects renamed PDFs, HTML, ZIPs or random bytes when ffprobe cannot recognize them as image, audio or video. This reduces exposure to unnecessary FFmpeg processing.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">true</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_fail_closed_on_unrecognized_media">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Thumbnail no-store headers</h3>
              <code class="mg-guide__setting-name">media_gallery_no_store_thumbnails</code>
              <p class="mg-guide__setting-help">Adds no-store/no-cache headers to thumbnail responses. Useful for privacy, but increases thumbnail requests and may make browsing less cache-friendly.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">false by default, true for strict privacy</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_no_store_thumbnails">Open setting</a>
          </article>

          <article class="mg-guide__setting-row">
            <div class="mg-guide__row-copy">
              <h3>Allowed upload extensions</h3>
              <code class="mg-guide__setting-name">media_gallery_allowed_image_extensions / video_extensions / audio_extensions</code>
              <p class="mg-guide__setting-help">Limits which file extensions Media Gallery accepts after Discourse upload validation. Keep the list as small as the business use-case allows.</p>
            </div>
            <div class="mg-guide__setting-value"><span class="mg-guide__value-label">Suggested value</span><span class="mg-guide__value-text">only needed formats</span></div>
            <a class="btn" href="/admin/site_settings/category/all_results?filter=media_gallery_allowed_">Open settings</a>
          </article>
        </div>
      </section>

      <section class="mg-guide__panel">
        <div class="mg-guide__callout">
          <h2>How to use this guide</h2>
          <p class="mg-guide__muted">
            Change settings in small groups, then test upload, playback, HLS, migration, forensic identify and exports where relevant. For live production changes, prefer staging verification first.
          </p>
          <div class="mg-guide__button-row">
            <a class="btn btn-primary" href="/admin/site_settings/category/all_results?filter=media_gallery">Open all Media Gallery settings</a>
            <a class="btn" href="/admin/plugins/media-gallery-security">Review Security status</a>
            <a class="btn" href="/admin/plugins/media-gallery-health">Review Health</a>
          </div>
        </div>
      </section>
    </div>
  </template>
);
