import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryHealthRoute extends DiscourseRoute {
  async model() {
    try {
      return {
        healthData: await ajax("/admin/plugins/media-gallery/health.json"),
        loadError: null,
      };
    } catch (error) {
      return { healthData: null, loadError: error };
    }
  }

  setupController(controller, model) {
    super.setupController(...arguments);
    if (typeof controller?.resetState !== "function") {
      return;
    }

    controller.resetState();

    if (model?.loadError) {
      controller.error = typeof controller?.errorMessage === "function"
        ? controller.errorMessage(model.loadError)
        : "Unable to load Media Gallery health.";
      return;
    }

    if (typeof controller?.applyResponse === "function") {
      const data = model?.healthData || {};
      controller.isFullStorage = Boolean(data?.full_storage);
      controller.applyResponse(data);
    }
  }
}
