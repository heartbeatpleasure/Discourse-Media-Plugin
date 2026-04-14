import DiscourseRoute from "discourse/routes/discourse";
import { next } from "@ember/runloop";

export default class AdminPluginsMediaGalleryLogsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);

    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }

    if (typeof controller?.loadLogs === "function") {
      next(() => controller.loadLogs());
    }
  }
}
