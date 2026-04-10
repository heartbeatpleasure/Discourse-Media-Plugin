import { apiInitializer } from "discourse/lib/api";
import { schedule } from "@ember/runloop";

const LABELS = {
  local: "Local storage",
  s3_1: "S3 profile 1",
  s3_2: "S3 profile 2",
  s3_3: "S3 profile 3",
};

function inMediaGallerySettings() {
  return window.location.pathname.startsWith("/admin/site_settings") &&
    window.location.search.includes("filter=media_gallery");
}

function replaceTextIfObjectObject(node, value) {
  if (!node || !value) return;
  const text = (node.textContent || "").trim();
  if (!text || text === "[object Object]" || LABELS[text] || text === value) {
    node.textContent = LABELS[value] || value;
  }
}

function patchNativeSelect(select) {
  if (!select || select.dataset.mediaGalleryDefaultStoragePatched === "1") return;
  for (const option of select.options || []) {
    const value = option.value;
    if (LABELS[value]) option.textContent = LABELS[value];
  }
  select.dataset.mediaGalleryDefaultStoragePatched = "1";
}

function patchSelectKitRow(row) {
  if (!row) return;
  const header = row.querySelector(".select-kit-header .selected-name, .select-kit-header-wrapper .selected-name");
  const collection = row.querySelectorAll("[data-value]");
  collection.forEach((item) => {
    const value = item.getAttribute("data-value");
    if (LABELS[value]) replaceTextIfObjectObject(item, value);
  });

  const selected = row.querySelector(".select-kit .is-selected[data-value], .select-kit-collection .is-selected[data-value]");
  const headerValue = selected?.getAttribute("data-value") || row.querySelector("input[type=hidden]")?.value || "";
  if (header && LABELS[headerValue]) {
    replaceTextIfObjectObject(header, headerValue);
  }
}

function patchDefaultStorageSetting() {
  if (!inMediaGallerySettings()) return;

  schedule("afterRender", () => {
    document.querySelectorAll('select').forEach((select) => {
      const row = select.closest('.setting, .control-group, .site-setting');
      if (!row) return;
      const text = row.textContent || "";
      if (!text.includes("default storage profile")) return;
      patchNativeSelect(select);
    });

    document.querySelectorAll('.setting, .control-group, .site-setting').forEach((row) => {
      const text = row.textContent || "";
      if (!text.includes("default storage profile")) return;
      patchSelectKitRow(row);
    });
  });
}

export default apiInitializer("0.11.1", (api) => {
  let observer = null;

  const start = () => {
    patchDefaultStorageSetting();
    if (observer) observer.disconnect();
    observer = new MutationObserver(() => patchDefaultStorageSetting());
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
