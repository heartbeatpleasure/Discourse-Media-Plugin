import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryManagementRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
      if (typeof controller?.loadInitial === "function") {
        controller.loadInitial();
      }
    }
  }
}
