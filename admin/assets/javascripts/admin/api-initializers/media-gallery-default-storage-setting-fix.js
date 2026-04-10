import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

const FALLBACK_LABELS = {
  local: "Local storage",
  s3_1: "S3 profile 1",
  s3_2: "S3 profile 2",
  s3_3: "S3 profile 3",
};

const SETTINGS_PATH = "/admin/site_settings";
const FILTER_TOKEN = "filter=media_gallery";

const HUMANIZED_LABEL_REPLACEMENTS = {
  "Media gallery S3 profile name": "Media gallery S3 profile 1 name",
  "Media gallery S3 endpoint": "Media gallery S3 profile 1 endpoint",
  "Media gallery S3 region": "Media gallery S3 profile 1 region",
  "Media gallery S3 bucket": "Media gallery S3 profile 1 bucket",
  "Media gallery S3 prefix": "Media gallery S3 profile 1 prefix",
  "Media gallery S3 access key ID": "Media gallery S3 profile 1 access key ID",
  "Media gallery S3 secret access key": "Media gallery S3 profile 1 secret access key",
  "Media gallery S3 force path style": "Media gallery S3 profile 1 force path style",
  "Media gallery S3 presign ttl seconds": "Media gallery S3 profile 1 presign ttl seconds",

  "Media gallery target S3 profile name": "Media gallery S3 profile 2 name",
  "Media gallery target S3 endpoint": "Media gallery S3 profile 2 endpoint",
  "Media gallery target S3 region": "Media gallery S3 profile 2 region",
  "Media gallery target S3 bucket": "Media gallery S3 profile 2 bucket",
  "Media gallery target S3 prefix": "Media gallery S3 profile 2 prefix",
  "Media gallery target S3 access key ID": "Media gallery S3 profile 2 access key ID",
  "Media gallery target S3 secret access key": "Media gallery S3 profile 2 secret access key",
  "Media gallery target S3 force path style": "Media gallery S3 profile 2 force path style",
  "Media gallery target S3 presign ttl seconds": "Media gallery S3 profile 2 presign ttl seconds",

  "Media gallery target S3 2 profile name": "Media gallery S3 profile 3 name",
  "Media gallery target S3 2 endpoint": "Media gallery S3 profile 3 endpoint",
  "Media gallery target S3 2 region": "Media gallery S3 profile 3 region",
  "Media gallery target S3 2 bucket": "Media gallery S3 profile 3 bucket",
  "Media gallery target S3 2 prefix": "Media gallery S3 profile 3 prefix",
  "Media gallery target S3 2 access key ID": "Media gallery S3 profile 3 access key ID",
  "Media gallery target S3 2 secret access key": "Media gallery S3 profile 3 secret access key",
  "Media gallery target S3 2 force path style": "Media gallery S3 profile 3 force path style",
  "Media gallery target S3 2 presign ttl seconds": "Media gallery S3 profile 3 presign ttl seconds",

  "Media gallery target S3 3 profile name": "Media gallery legacy S3 fallback profile name",
  "Media gallery target S3 3 endpoint": "Media gallery legacy S3 fallback endpoint",
  "Media gallery target S3 3 region": "Media gallery legacy S3 fallback region",
  "Media gallery target S3 3 bucket": "Media gallery legacy S3 fallback bucket",
  "Media gallery target S3 3 prefix": "Media gallery legacy S3 fallback prefix",
  "Media gallery target S3 3 access key ID": "Media gallery legacy S3 fallback access key ID",
  "Media gallery target S3 3 secret access key": "Media gallery legacy S3 fallback secret access key",
  "Media gallery target S3 3 force path style": "Media gallery legacy S3 fallback force path style",
  "Media gallery target S3 3 presign ttl seconds": "Media gallery legacy S3 fallback presign ttl seconds",

  "Media gallery target local profile name": "Media gallery legacy local profile name",
  "Media gallery target local asset root path": "Media gallery local storage override root path (legacy)",
  "Media gallery target asset storage backend": "Media gallery legacy destination backend",
  "Media gallery asset storage backend": "Media gallery legacy managed storage backend",
};

function inMediaGallerySettings() {
  return (
    window.location.pathname.startsWith(SETTINGS_PATH) &&
    window.location.search.includes(FILTER_TOKEN)
  );
}

function currentProfileLabels() {
  const labels = { ...FALLBACK_LABELS };

  document
    .querySelectorAll(".setting, .control-group, .site-setting")
    .forEach((row) => {
      const text = (row?.textContent || "").toLowerCase();
      const value = row.querySelector("input[type='text'], input:not([type]), textarea")?.value?.trim();
      if (!value) {
        return;
      }

      if (text.includes("local profile name") && !text.includes("legacy")) {
        labels.local = value;
      } else if (text.includes("s3 profile 1 name")) {
        labels.s3_1 = value;
      } else if (text.includes("s3 profile 2 name")) {
        labels.s3_2 = value;
      } else if (text.includes("s3 profile 3 name") && !text.includes("legacy")) {
        labels.s3_3 = value;
      }
    });

  return labels;
}

function desiredLabel(value) {
  const labels = currentProfileLabels();
  return labels[value] || FALLBACK_LABELS[value] || value;
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
  return text.includes("media gallery") || text.includes("default storage profile");
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

    const labelNode =
      item.querySelector(".name, .select-kit-row-label, .text, .desc") || item;

    changed = setTextIfNeeded(labelNode, label) || changed;
  });

  const selectedValue =
    row
      .querySelector(
        ".select-kit .is-selected[data-value], .select-kit-collection .is-selected[data-value]"
      )
      ?.getAttribute("data-value") ||
    row.querySelector("input[type='hidden']")?.value ||
    row
      .querySelector(".select-kit-header [data-value]")
      ?.getAttribute("data-value");

  const header = row.querySelector(
    ".select-kit-header .selected-name, .select-kit-header-wrapper .selected-name"
  );

  if (header && selectedValue) {
    changed = setTextIfNeeded(header, desiredLabel(selectedValue)) || changed;
  }

  return changed;
}

function patchHumanizedSettingLabels() {
  if (!inMediaGallerySettings()) {
    return false;
  }

  let changed = false;

  document
    .querySelectorAll("label, .setting-label, .setting-name, .name")
    .forEach((node) => {
      const current = (node.textContent || "").trim();
      const replacement = HUMANIZED_LABEL_REPLACEMENTS[current];

      if (replacement) {
        changed = setTextIfNeeded(node, replacement) || changed;
      }
    });

  return changed;
}

function patchSettingsPage() {
  if (!inMediaGallerySettings()) {
    return false;
  }

  let touched = patchHumanizedSettingLabels();

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
  schedule("afterRender", () => patchSettingsPage());
}

export default apiInitializer("0.11.1", (api) => {
  let observer = null;
  let attempts = 0;
  let stopTimer = null;
  let changeHandler = null;
  let clickHandler = null;
  let inputHandler = null;

  const stop = () => {
    if (observer) {
      observer.disconnect();
      observer = null;
    }

    if (stopTimer) {
      clearTimeout(stopTimer);
      stopTimer = null;
    }

    if (changeHandler) {
      document.removeEventListener("change", changeHandler, true);
      changeHandler = null;
    }

    if (clickHandler) {
      document.removeEventListener("click", clickHandler, true);
      clickHandler = null;
    }

    if (inputHandler) {
      document.removeEventListener("input", inputHandler, true);
      inputHandler = null;
    }

    attempts = 0;
  };

  const start = () => {
    stop();
    schedulePatch();

    observer = new MutationObserver(() => {
      attempts += 1;
      schedulePatch();

      if (attempts >= 25 && observer) {
        observer.disconnect();
        observer = null;
      }
    });

    observer.observe(document.body, { childList: true, subtree: true });

    changeHandler = () => schedulePatch();
    clickHandler = () => schedulePatch();
    inputHandler = () => schedulePatch();
    document.addEventListener("change", changeHandler, true);
    document.addEventListener("click", clickHandler, true);
    document.addEventListener("input", inputHandler, true);

    stopTimer = setTimeout(() => {
      if (observer) {
        observer.disconnect();
        observer = null;
      }
      if (stopTimer) {
        clearTimeout(stopTimer);
        stopTimer = null;
      }
      attempts = 0;
    }, 4000);
  };

  api.onPageChange((url) => {
    if (
      url?.startsWith(SETTINGS_PATH) &&
      window.location.search.includes(FILTER_TOKEN)
    ) {
      start();
    } else {
      stop();
    }
  });

  if (inMediaGallerySettings()) {
    start();
  }
});
