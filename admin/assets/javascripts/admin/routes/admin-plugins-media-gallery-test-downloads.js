import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryTestDownloadsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    controller.resetState();
  }
}
