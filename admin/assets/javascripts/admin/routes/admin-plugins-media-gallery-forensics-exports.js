import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

function decorateExport(exp) {
  const rowsCount = Number(exp?.rows_count || 0);
  const isDatabaseStorage = exp?.storage === "db";
  const isReady = isDatabaseStorage || Boolean(exp?.file_exists);

  return {
    ...exp,
    rowsLabel: `${rowsCount} rows`,
    storageLabel: isDatabaseStorage ? "Database" : "File storage",
    availabilityLabel: isReady ? "Ready" : "Missing file",
    availabilityClass: isReady ? "is-success" : "is-warning",
    storageClass: isDatabaseStorage ? "is-info" : "",
  };
}

export default class AdminPluginsMediaGalleryForensicsExportsRoute extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/media-gallery/forensics-exports.json").catch((e) => {
      // Keep the route usable even if the API call fails.
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
