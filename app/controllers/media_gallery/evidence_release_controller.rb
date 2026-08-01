# frozen_string_literal: true

require "digest"
require "securerandom"

module ::MediaGallery
  class EvidenceReleaseController < ::ApplicationController
    requires_plugin "Discourse-Media-Plugin"

    skip_before_action :verify_authenticity_token
    skip_before_action :check_xhr, raise: false

    before_action :ensure_evidence_enabled
    before_action :secure_release_headers
    before_action :rate_limit_redemption!, only: :redeem

    def landing
      nonce = SecureRandom.base64(18)
      response.headers["Content-Security-Policy"] = [
        "default-src 'none'",
        "script-src 'nonce-#{nonce}'",
        "style-src 'unsafe-inline'",
        "form-action 'self'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
      ].join("; ")

      render html: landing_html(nonce).html_safe, layout: false, content_type: "text/html"
    end

    def redeem
      redemption = ::MediaGallery::EvidenceRelease.redeem!(
        disclosure_ref: params[:disclosure_ref],
        token: params[:token],
      )
      package = redemption[:package]
      send_file(
        redemption[:path],
        filename: "#{package.package_ref}.tar.gz",
        type: "application/gzip",
        disposition: "attachment",
      )
    rescue ::MediaGallery::EvidenceRelease::Unavailable
      render_unavailable
    end

    private

    def ensure_evidence_enabled
      raise Discourse::NotFound unless ::MediaGallery::EvidencePolicy.enabled?
    end

    def secure_release_headers
      response.headers["Cache-Control"] = "no-store, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["X-Frame-Options"] = "DENY"
      response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    end

    def rate_limit_redemption!
      remote_digest = Digest::SHA256.hexdigest(request.remote_ip.to_s)
      RateLimiter.new(nil, "media_gallery:evidence_release:#{remote_digest}", 30, 1.minute).performed!
    rescue RateLimiter::LimitExceeded
      render plain: "Too many evidence release attempts. Try again later.", status: 429
    end

    def render_unavailable
      render plain: "This evidence release link is invalid, expired, revoked, or has already reached its download limit.", status: 410
    end

    def landing_html(nonce)
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Secure evidence package release</title>
            <style>
              :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
              body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: Canvas; color: CanvasText; }
              main { width: min(42rem, calc(100vw - 2rem)); box-sizing: border-box; padding: 2rem; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 1rem; }
              h1 { margin-top: 0; font-size: 1.5rem; }
              p { line-height: 1.55; }
            </style>
          </head>
          <body>
            <main>
              <h1>Secure evidence package release</h1>
              <p id="status">Preparing the authorised package download…</p>
              <noscript>JavaScript is required so the secret part of this release link can be submitted without exposing it in server access logs.</noscript>
            </main>
            <script nonce="#{nonce}">
              (() => {
                const status = document.getElementById("status");
                const token = window.location.hash.slice(1);
                window.history.replaceState(null, document.title, window.location.pathname);
                if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
                  status.textContent = "This evidence release link is incomplete or invalid.";
                  return;
                }
                const form = document.createElement("form");
                form.method = "post";
                form.action = window.location.pathname.replace(/\/$/, "") + "/redeem";
                const input = document.createElement("input");
                input.type = "hidden";
                input.name = "token";
                input.value = token;
                form.appendChild(input);
                document.body.appendChild(form);
                status.textContent = "The authorised download response is being prepared…";
                form.submit();
                window.setTimeout(() => {
                  input.value = "";
                  form.remove();
                }, 0);
              })();
            </script>
          </body>
        </html>
      HTML
    end
  end
end
