import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryLogsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
    if (typeof controller?.loadInitial === "function") {
      Promise.resolve(controller.loadInitial()).catch(() => {
        // controller handles its own error state; avoid unhandled promise noise
      });
    }
  }
}
