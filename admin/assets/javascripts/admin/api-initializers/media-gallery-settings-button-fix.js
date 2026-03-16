import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

/**
 * Make the "Settings" button on /admin/plugins for this plugin open Media Gallery settings.
 *
 * Why:
 * - In some Discourse builds, the plugin-settings button fills the search box with
 *   `plugin:Discourse-Media-Plugin` (client-side token parsing), but the list can render empty.
 * - Searching `media_gallery` works reliably because it's a plain text filter for the setting keys.
 *
 * We do NOT rename the plugin, repo, or settings. We only redirect that one button.
 */
export default apiInitializer("0.11.1", (api) => {
  const PLUGIN_DISPLAY_NAME = "Discourse-Media-Plugin";
  const FIXED_SETTINGS_URL = "/admin/site_settings/category/all_results?filter=media_gallery";

  let observer = null;
  let clickHandlerInstalled = false;

  function findPluginCards() {
    // The admin/plugins UI has changed over time; we use a few selectors and fall back to scanning.
    return (
      Array.from(document.querySelectorAll("[data-plugin-name]")) ||
      []
    ).concat(Array.from(document.querySelectorAll(".admin-plugins-list .admin-plugin, .admin-plugin")));
  }

  function cardLooksLikeOurPlugin(card) {
    if (!card) return false;

    const dataName = card.getAttribute?.("data-plugin-name");
    if (dataName && dataName.toLowerCase() === PLUGIN_DISPLAY_NAME.toLowerCase()) {
      return true;
    }

    const text = (card.textContent || "").toLowerCase();
    if (text.includes(PLUGIN_DISPLAY_NAME.toLowerCase())) return true;

    // Also match the repo URL if present
    const repo = card.querySelector?.('a[href*="github.com/heartbeatpleasure/Discourse-Media-Plugin"]');
    return !!repo;
  }

  function rewriteSettingsLinkInCard(card) {
    if (!cardLooksLikeOurPlugin(card)) return;

    // Most builds use an <a> with a site_settings href; some use a button action.
    const anchors = Array.from(card.querySelectorAll('a[href*="/admin/site_settings"]'));
    for (const a of anchors) {
      if (a.dataset.mediaGallerySettingsFixed === "1") continue;
      a.setAttribute("href", FIXED_SETTINGS_URL);
      a.dataset.mediaGallerySettingsFixed = "1";
    }
  }

  function rewriteAll() {
    schedule("afterRender", () => {
      const cards = findPluginCards();
      if (!cards?.length) return;

      cards.forEach((card) => rewriteSettingsLinkInCard(card));
    });
  }

  function installClickInterceptOnce() {
    if (clickHandlerInstalled) return;
    clickHandlerInstalled = true;

    // Capture phase so we can override even if core uses JS actions instead of hrefs.
    document.addEventListener(
      "click",
      (e) => {
        if (!window.location?.pathname?.startsWith("/admin/plugins")) return;

        const target = e.target;
        if (!target) return;

        // Look for a "settings" control
        const maybeControl =
          target.closest?.('a[href*="/admin/site_settings"], button, .btn, .d-button') || target;

        // Heuristic: settings controls usually have aria-label/title containing "Settings"
        const label =
          (maybeControl.getAttribute?.("aria-label") || "") +
          " " +
          (maybeControl.getAttribute?.("title") || "");
        const isSettingsish = label.toLowerCase().includes("settings");

        // Or it's the known settings URL already
        const href = maybeControl.getAttribute?.("href") || "";
        const isSiteSettingsLink = href.includes("/admin/site_settings");

        if (!isSettingsish && !isSiteSettingsLink) return;

        const card = maybeControl.closest?.("[data-plugin-name], .admin-plugin");
        if (!cardLooksLikeOurPlugin(card)) return;

        // Redirect to stable filter page
        e.preventDefault();
        e.stopPropagation();
        window.location.assign(FIXED_SETTINGS_URL);
      },
      true
    );
  }

  function start() {
    rewriteAll();
    installClickInterceptOnce();

    if (observer) observer.disconnect();
    observer = new MutationObserver(() => rewriteAll());
    observer.observe(document.body, { childList: true, subtree: true });
  }

  function stop() {
    if (observer) observer.disconnect();
    observer = null;
  }

  api.onPageChange((url) => {
    if (url?.startsWith("/admin/plugins")) {
      start();
    } else {
      stop();
    }
  });

  if (window.location?.pathname?.startsWith("/admin/plugins")) {
    start();
  }
});
