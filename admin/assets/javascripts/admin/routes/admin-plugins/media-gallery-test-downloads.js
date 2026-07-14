import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryTestDownloadsRoute extends DiscourseRoute {
  beforeModel(transition) {
    super.beforeModel?.(...arguments);
    this._mediaGalleryQueryParams = transition?.to?.queryParams || {};
  }

  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }
    if (typeof controller?.loadInitialResults === "function") {
      controller.loadInitialResults(this._mediaGalleryQueryParams || {});
    }
  }
}
