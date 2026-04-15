import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryTestDownloadsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
    if (typeof controller?.loadInitialResults === "function") {
      controller.loadInitialResults();
    }
  }
}
