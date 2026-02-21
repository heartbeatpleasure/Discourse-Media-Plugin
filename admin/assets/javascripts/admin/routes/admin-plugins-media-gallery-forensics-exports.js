import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

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
      exports: model?.exports || [],
      error: model?.error,
      downloadBase: "/admin/plugins/media-gallery/forensics-exports",
    });
  }
}
