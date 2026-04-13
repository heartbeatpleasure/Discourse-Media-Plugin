import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryLogsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
  }
}
