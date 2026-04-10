import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

const PROFILE_OPTION_LABELS = {
  local: "Local storage",
  s3_1: "S3 profile 1",
  s3_2: "S3 profile 2",
  s3_3: "S3 profile 3",
};

const SETTING_LABELS = [
  ["default storage profile", "Media gallery default storage profile"],
  ["processing root path", "Media gallery processing root path"],
  ["delivery mode default", "Media gallery delivery mode default"],

  ["local storage profile name", "Media gallery local storage profile name"],
  ["local storage root path", "Media gallery local storage root path"],
  ["legacy local storage override root path", "Media gallery legacy local storage override root path"],

  ["s3 profile 1 name", "Media gallery S3 profile 1 name"],
  ["s3 profile 1 endpoint", "Media gallery S3 profile 1 endpoint"],
  ["s3 profile 1 region", "Media gallery S3 profile 1 region"],
  ["s3 profile 1 bucket", "Media gallery S3 profile 1 bucket"],
  ["s3 profile 1 prefix", "Media gallery S3 profile 1 prefix"],
  ["s3 profile 1 access key id", "Media gallery S3 profile 1 access key ID"],
  ["s3 profile 1 secret access key", "Media gallery S3 profile 1 secret access key"],
  ["s3 profile 1 force path style", "Media gallery S3 profile 1 force path style"],
  ["s3 profile 1 presign ttl seconds", "Media gallery S3 profile 1 presign TTL seconds"],

  ["s3 profile 2 name", "Media gallery S3 profile 2 name"],
  ["s3 profile 2 endpoint", "Media gallery S3 profile 2 endpoint"],
  ["s3 profile 2 region", "Media gallery S3 profile 2 region"],
  ["s3 profile 2 bucket", "Media gallery S3 profile 2 bucket"],
  ["s3 profile 2 prefix", "Media gallery S3 profile 2 prefix"],
  ["s3 profile 2 access key id", "Media gallery S3 profile 2 access key ID"],
  ["s3 profile 2 secret access key", "Media gallery S3 profile 2 secret access key"],
  ["s3 profile 2 force path style", "Media gallery S3 profile 2 force path style"],
  ["s3 profile 2 presign ttl seconds", "Media gallery S3 profile 2 presign TTL seconds"],

  ["s3 profile 3 name", "Media gallery S3 profile 3 name"],
  ["s3 profile 3 endpoint", "Media gallery S3 profile 3 endpoint"],
  ["s3 profile 3 region", "Media gallery S3 profile 3 region"],
  ["s3 profile 3 bucket", "Media gallery S3 profile 3 bucket"],
  ["s3 profile 3 prefix", "Media gallery S3 profile 3 prefix"],
  ["s3 profile 3 access key id", "Media gallery S3 profile 3 access key ID"],
  ["s3 profile 3 secret access key", "Media gallery S3 profile 3 secret access key"],
  ["s3 profile 3 force path style", "Media gallery S3 profile 3 force path style"],
  ["s3 profile 3 presign ttl seconds", "Media gallery S3 profile 3 presign TTL seconds"],

  ["legacy managed storage backend", "Media gallery legacy managed storage backend"],
  ["legacy destination backend", "Media gallery legacy destination backend"],
  ["legacy local profile name", "Media gallery legacy local profile name"],
  ["legacy s3 fallback profile name", "Media gallery legacy S3 fallback profile name"],
  ["legacy s3 fallback endpoint", "Media gallery legacy S3 fallback endpoint"],
  ["legacy s3 fallback region", "Media gallery legacy S3 fallback region"],
  ["legacy s3 fallback bucket", "Media gallery legacy S3 fallback bucket"],
  ["legacy s3 fallback prefix", "Media gallery legacy S3 fallback prefix"],
  ["legacy s3 fallback access key id", "Media gallery legacy S3 fallback access key ID"],
  ["legacy s3 fallback secret access key", "Media gallery legacy S3 fallback secret access key"],
  ["legacy s3 fallback force path style", "Media gallery legacy S3 fallback force path style"],
  ["legacy s3 fallback presign ttl seconds", "Media gallery legacy S3 fallback presign TTL seconds"],
];

function inMediaGallerySettings() {
  return (
    window.location.pathname.startsWith("/admin/site_settings") &&
    window.location.search.includes("filter=media_gallery")
  );
}

function replaceText(node, text) {
  if (!node || !text) return;
  node.textContent = text;
}

function replaceTextIfObjectObject(node, value) {
  if (!node || !value) return;
  const text = (node.textContent || "").trim();
  if (!text || text === "[object Object]" || PROFILE_OPTION_LABELS[text] || text === value) {
    node.textContent = PROFILE_OPTION_LABELS[value] || value;
  }
}

function patchNativeSelect(select) {
  if (!select || select.dataset.mediaGalleryDefaultStoragePatched === "1") return;
  for (const option of select.options || []) {
    const value = option.value;
    if (PROFILE_OPTION_LABELS[value]) option.textContent = PROFILE_OPTION_LABELS[value];
  }
  select.dataset.mediaGalleryDefaultStoragePatched = "1";
}

function patchSelectKitRow(row) {
  if (!row) return;
  const header = row.querySelector(
    ".select-kit-header .selected-name, .select-kit-header-wrapper .selected-name"
  );
  const collection = row.querySelectorAll("[data-value]");
  collection.forEach((item) => {
    const value = item.getAttribute("data-value");
    if (PROFILE_OPTION_LABELS[value]) replaceTextIfObjectObject(item, value);
  });

  const selected = row.querySelector(
    ".select-kit .is-selected[data-value], .select-kit-collection .is-selected[data-value]"
  );
  const headerValue =
    selected?.getAttribute("data-value") || row.querySelector("input[type=hidden]")?.value || "";
  if (header && PROFILE_OPTION_LABELS[headerValue]) {
    replaceTextIfObjectObject(header, headerValue);
  }
}

function patchSettingTitle(row) {
  const text = (row.textContent || "").toLowerCase();
  const match = SETTING_LABELS.find(([needle]) => text.includes(needle));
  if (!match) return;

  const desiredLabel = match[1];
  const titleNode =
    row.querySelector(
      ".setting-label, .setting-title, .setting-name, .name, label.control-label, .controls label:first-child"
    ) || row.querySelector("label");

  if (titleNode) {
    replaceText(titleNode, desiredLabel);
  }

  const checkboxLabel = row.querySelector(".checkbox-label, .ember-checkbox + span, label[for]");
  if (checkboxLabel && checkboxLabel.textContent?.toLowerCase().includes("media gallery")) {
    replaceText(checkboxLabel, desiredLabel);
  }
}

function patchMediaGallerySettings() {
  if (!inMediaGallerySettings()) return;

  schedule("afterRender", () => {
    document.querySelectorAll("select").forEach((select) => {
      const row = select.closest(".setting, .control-group, .site-setting");
      if (!row) return;
      const text = row.textContent || "";
      if (!text.toLowerCase().includes("default storage profile")) return;
      patchNativeSelect(select);
    });

    document
      .querySelectorAll(".setting, .control-group, .site-setting")
      .forEach((row) => {
        const text = row.textContent || "";
        if (!text.toLowerCase().includes("media gallery")) return;
        patchSettingTitle(row);
        if (text.toLowerCase().includes("default storage profile")) {
          patchSelectKitRow(row);
        }
      });
  });
}

export default apiInitializer("0.11.1", (api) => {
  let observer = null;

  const start = () => {
    patchMediaGallerySettings();
    if (observer) observer.disconnect();
    observer = new MutationObserver(() => patchMediaGallerySettings());
    observer.observe(document.body, { childList: true, subtree: true });
  };

  const stop = () => {
    if (observer) observer.disconnect();
    observer = null;
  };

  api.onPageChange((url) => {
    if (url?.startsWith("/admin/site_settings")) {
      start();
    } else {
      stop();
    }
  });

  if (inMediaGallerySettings()) start();
});
