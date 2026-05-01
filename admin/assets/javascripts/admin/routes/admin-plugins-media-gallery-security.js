import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

export default class AdminPluginsMediaGallerySecurityRoute extends DiscourseRoute {
  async model() {
    try {
      return await ajax("/admin/plugins/media-gallery/security.json");
    } catch (e) {
      return {
        error_message: e?.jqXHR?.responseJSON?.message || e?.message || "Security status could not be loaded.",
      };
    }
  }

  setupController(controller, model) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
    if (typeof controller?.applySecurityStatus === "function") {
      controller.applySecurityStatus(model);
    } else if (typeof controller?.loadSecurityStatus === "function") {
      controller.loadSecurityStatus();
    }
  }
}
