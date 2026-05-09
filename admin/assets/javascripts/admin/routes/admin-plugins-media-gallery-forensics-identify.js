import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryForensicsIdentifyRoute extends DiscourseRoute {
  beforeModel(transition) {
    super.beforeModel?.(...arguments);
    this._mediaGalleryQueryParams = transition?.to?.queryParams || {};
  }

  setupController(controller) {
    super.setupController(...arguments);

    if (controller._searchTimer) {
      clearTimeout(controller._searchTimer);
      controller._searchTimer = null;
    }

    if (typeof controller._cancelStatusPoll === "function") {
      controller._cancelStatusPoll();
    } else if (controller._statusPollTimer) {
      clearTimeout(controller._statusPollTimer);
      controller._statusPollTimer = null;
    }

    const pendingParams = this._mediaGalleryQueryParams || {};
    const browserParams = new URLSearchParams(window.location.search || "");
    const initialPublicId = String(pendingParams.public_id || browserParams.get("public_id") || "").trim();
    const initialQuery = String(pendingParams.q || browserParams.get("q") || initialPublicId || "").trim();

    controller.publicId = initialPublicId || initialQuery;
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

    controller.searchQuery = initialQuery;
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
    controller.showPerformanceTimings = false;
    controller.lastSearchTimingMs = null;
    controller.lastSearchTimingBreakdown = null;

    controller.search();
  }
}
