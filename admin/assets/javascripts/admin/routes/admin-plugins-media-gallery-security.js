import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGallerySecurityRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
    if (typeof controller?.loadSecurityStatus === "function") {
      controller.loadSecurityStatus();
    }
  }
}
