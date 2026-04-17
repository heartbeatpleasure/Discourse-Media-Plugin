import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryForensicsIdentifyRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);

    if (controller._searchTimer) {
      clearTimeout(controller._searchTimer);
      controller._searchTimer = null;
    }

    if (controller._statusPollTimer) {
      clearTimeout(controller._statusPollTimer);
      controller._statusPollTimer = null;
    }

    controller.publicId = "";
    controller.file = null;
    controller.sourceUrl = "";
    controller.maxSamples = 60;
    controller.maxOffsetSegments = 30;
    controller.layout = "";
    controller.autoExtend = true;
    controller.isRunning = false;
    controller.result = null;
    controller.resultJson = "";
    controller.error = "";
    controller.statusMessage = "";
    controller.activeTaskId = null;

    controller.searchQuery = "";
    controller.searchResults = [];
    controller.isSearching = false;
    controller.searchError = "";
    controller.searchTypeFilter = "all";
    controller.searchStatusFilter = "all";
    controller.searchBackendFilter = "all";
    controller.searchHlsFilter = "all";
    controller.searchLimit = 20;
    controller.searchSort = "newest";

    controller.lookupCode = "";
    controller.lookupMatches = [];
    controller.lookupBusy = false;
    controller.lookupError = "";

    controller.search();
  }
}
