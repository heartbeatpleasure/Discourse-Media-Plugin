import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryForensicsIdentifyRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);

    // Reset state when visiting the page.
    controller.publicId = "";
    controller.file = null;
    controller.maxSamples = 60;
    controller.maxOffsetSegments = 30;
    controller.layout = "";
    controller.isRunning = false;
    controller.resultJson = "";
    controller.error = "";
  }
}
