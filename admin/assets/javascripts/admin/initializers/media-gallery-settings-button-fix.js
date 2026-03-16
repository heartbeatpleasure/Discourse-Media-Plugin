import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

/**
 * Fix: clicking the "Settings" button for this plugin on /admin/plugins should show the Media Gallery
 * settings. In some Discourse versions, the plugin filter token can fail to match (e.g. due to
 * normalization/parsing differences), resulting in an empty list.
 *
 * We rewrite the settings link for this plugin to use a stable prefix search ("media_gallery"),
 * which always finds the plugin's settings keys.
 *
 * This does NOT change the plugin name/repo name and does not affect any other plugins.
 */
export default apiInitializer("0.11.1", (api) => {
  const FIXED_SETTINGS_URL = "/admin/site_settings/category/all_results?filter=media_gallery";

  // This token is what the core UI typically uses when building per-plugin settings links.
  // We match both encoded and unencoded forms to be safe.
  const LEGACY_TOKENS = [
    "plugin%3ADiscourse-Media-Plugin",
    "plugin:Discourse-Media-Plugin",
    "plugin%3Adiscourse-media-plugin",
    "plugin:discourse-media-plugin",
  ];

  let observer = null;

  function rewriteSettingsLinks() {
    schedule("afterRender", () => {
      const anchors = document.querySelectorAll('a[href*="/admin/site_settings/"]');
      anchors.forEach((a) => {
        const href = a.getAttribute("href") || "";
        if (!href) return;
        if (a.dataset.mediaGallerySettingsFixed === "1") return;

        for (const token of LEGACY_TOKENS) {
          if (href.includes(token)) {
            a.setAttribute("href", FIXED_SETTINGS_URL);
            a.dataset.mediaGallerySettingsFixed = "1";
            break;
          }
        }
      });
    });
  }

  function startObserving() {
    rewriteSettingsLinks();

    if (observer) observer.disconnect();
    observer = new MutationObserver(() => rewriteSettingsLinks());
    observer.observe(document.body, { childList: true, subtree: true });
  }

  function stopObserving() {
    if (observer) observer.disconnect();
    observer = null;
  }

  api.onPageChange((url) => {
    // Run only on the plugin list page.
    if (url?.startsWith("/admin/plugins")) {
      startObserving();
    } else {
      stopObserving();
    }
  });

  // In case /admin/plugins is the initial page load.
  if (window.location?.pathname?.startsWith("/admin/plugins")) {
    startObserving();
  }
});
