import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryManagementRoute extends DiscourseRoute {
  beforeModel(transition) {
    super.beforeModel?.(...arguments);
    this._mediaGalleryQueryParams = transition?.to?.queryParams || {};
  }

  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
      if (typeof controller?.loadInitial === "function") {
        controller.loadInitial(this._mediaGalleryQueryParams || {});
      }
    }
  }
}
