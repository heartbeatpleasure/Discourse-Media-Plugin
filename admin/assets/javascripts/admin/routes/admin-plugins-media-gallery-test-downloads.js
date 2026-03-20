import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryTestDownloadsRoute extends DiscourseRoute {
  setupController(controller, model) {
    super.setupController(controller, model);

    if (controller && typeof controller.resetState === "function") {
      controller.resetState();
    }
  }
}
