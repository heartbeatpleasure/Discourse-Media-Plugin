import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryJobsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.loadInitial === "function") {
      controller.loadInitial();
    }
  }
}
