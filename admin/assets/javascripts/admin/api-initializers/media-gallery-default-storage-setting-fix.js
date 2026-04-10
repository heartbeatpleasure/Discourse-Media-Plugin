import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

const LABELS = {
  local: "Local storage",
  s3_1: "S3 profile 1",
  s3_2: "S3 profile 2",
  s3_3: "S3 profile 3",
};

const SETTINGS_PATH = "/admin/site_settings";
const FILTER_TOKEN = "filter=media_gallery";

function inMediaGallerySettings() {
  return (
    window.location.pathname.startsWith(SETTINGS_PATH) &&
    window.location.search.includes(FILTER_TOKEN)
  );
}

function desiredLabel(value) {
  return LABELS[value] || value;
}

function setTextIfNeeded(node, text) {
  if (!node || !text) {
    return false;
  }

  const current = (node.textContent || "").trim();
  if (current === text) {
    return false;
  }

  node.textContent = text;
  return true;
}

function rowLooksRelevant(row) {
  const text = (row?.textContent || "").toLowerCase();
  return text.includes("default storage profile");
}

function patchNativeSelect(row) {
  const select = row?.querySelector("select");
  if (!select) {
    return false;
  }

  let changed = false;
  for (const option of Array.from(select.options || [])) {
    const label = desiredLabel(option.value);
    if (option.textContent !== label) {
      option.textContent = label;
      changed = true;
    }
  }

  return changed;
}

function patchSelectKit(row) {
  if (!row) {
    return false;
  }

  let changed = false;

  row.querySelectorAll("[data-value]").forEach((item) => {
    const value = item.getAttribute("data-value");
    const label = desiredLabel(value);

    // Only touch the visible text holder, not the whole element tree.
    const labelNode =
      item.querySelector(".name, .select-kit-row-label, .text, .desc") || item;

    changed = setTextIfNeeded(labelNode, label) || changed;
  });

  const selectedValue =
    row.querySelector(".select-kit .is-selected[data-value], .select-kit-collection .is-selected[data-value]")?.getAttribute("data-value") ||
    row.querySelector("input[type='hidden']")?.value ||
    row.querySelector(".select-kit-header [data-value]")?.getAttribute("data-value");

  const header = row.querySelector(
    ".select-kit-header .selected-name, .select-kit-header-wrapper .selected-name"
  );

  if (header && selectedValue) {
    changed = setTextIfNeeded(header, desiredLabel(selectedValue)) || changed;
  }

  return changed;
}

function patchDefaultStorageSetting() {
  if (!inMediaGallerySettings()) {
    return false;
  }

  let touched = false;

  document
    .querySelectorAll(".setting, .control-group, .site-setting")
    .forEach((row) => {
      if (!rowLooksRelevant(row)) {
        return;
      }

      touched = patchNativeSelect(row) || touched;
      touched = patchSelectKit(row) || touched;
    });

  return touched;
}

function schedulePatch() {
  schedule("afterRender", () => patchDefaultStorageSetting());
}

export default apiInitializer("0.11.1", (api) => {
  let observer = null;
  let attempts = 0;
  let stopTimer = null;

  const stop = () => {
    if (observer) {
      observer.disconnect();
      observer = null;
    }

    if (stopTimer) {
      clearTimeout(stopTimer);
      stopTimer = null;
    }

    attempts = 0;
  };

  const start = () => {
    stop();
    schedulePatch();

    // Observe only for a short time while the settings page renders. The previous
    // permanent body observer could keep retriggering itself and stall the rest of
    // the settings list.
    observer = new MutationObserver(() => {
      attempts += 1;
      schedulePatch();

      if (attempts >= 25) {
        stop();
      }
    });

    observer.observe(document.body, { childList: true, subtree: true });
    stopTimer = setTimeout(stop, 4000);
  };

  api.onPageChange((url) => {
    if (url?.startsWith(SETTINGS_PATH) && window.location.search.includes(FILTER_TOKEN)) {
      start();
    } else {
      stop();
    }
  });

  if (inMediaGallerySettings()) {
    start();
  }
});
