import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

function pad(value) {
  return String(value).padStart(2, "0");
}

function formatAdminDateTime(value) {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }

  return `${pad(date.getUTCDate())}-${pad(date.getUTCMonth() + 1)}-${date.getUTCFullYear()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())} UTC`;
}

function trimCsvExtension(filename) {
  return String(filename || "").replace(/\.csv$/i, "") || "—";
}

function titleizeStorageLocation(value) {
  switch (String(value || "").toLowerCase()) {
    case "local":
      return "Local";
    case "database":
    case "db":
      return "Database";
    default:
      return value ? String(value) : "—";
  }
}

function decorateExport(exp) {
  const rowsCount = Number(exp?.rows_count || 0);
  const isReady = Boolean(exp?.download_ready);
  const gzipBytes = exp?.gzip_bytes;

  return {
    ...exp,
    displayName: trimCsvExtension(exp?.filename),
    rowsLabel: `${rowsCount} rows`,
    availabilityLabel: isReady ? "Ready" : "Missing file",
    availabilityClass: isReady ? "is-success" : "is-warning",
    createdLabel: formatAdminDateTime(exp?.created_at),
    cutoffLabel: formatAdminDateTime(exp?.cutoff_at),
    storageLocationLabel: titleizeStorageLocation(exp?.storage_location),
    gzipSizeLabel: gzipBytes === null || gzipBytes === undefined || gzipBytes === "" ? "—" : String(gzipBytes),
    csvShaLabel: exp?.csv_sha256 || "—",
  };
}

export default class AdminPluginsMediaGalleryForensicsExportsRoute extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/media-gallery/forensics-exports.json").catch((e) => {
      let message = "";
      try {
        message =
          e?.jqXHR?.responseJSON?.errors?.join(" ") ||
          e?.jqXHR?.responseText ||
          e?.message ||
          "";
      } catch {
        // ignore
      }

      return {
        exports: [],
        error: message,
      };
    });
  }

  setupController(controller, model) {
    super.setupController(controller, model);

    controller.setProperties({
      model,
      exports: (model?.exports || []).map(decorateExport),
      error: model?.error,
      downloadBase: "/admin/plugins/media-gallery/forensics-exports",
    });
  }
}
