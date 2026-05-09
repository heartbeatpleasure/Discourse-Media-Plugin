import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

function errorMessage(error) {
  return (
    error?.jqXHR?.responseJSON?.errors?.join(" ") ||
    error?.jqXHR?.responseJSON?.error ||
    error?.message ||
    "Unable to load background jobs."
  );
}

export default class AdminPluginsMediaGalleryJobsRoute extends DiscourseRoute {
  queryParams = {
    status: { refreshModel: true },
    type: { refreshModel: true },
    limit: { refreshModel: true },
  };

  async model(params) {
    try {
      return await ajax("/admin/plugins/media-gallery/jobs.json", {
        data: {
          status: params?.status || "all",
          type: params?.type || "all",
          limit: params?.limit || "50",
        },
      });
    } catch (error) {
      return {
        summary: {
          active_count: 0,
          failed_count: 0,
          completed_count: 0,
          visible_count: 0,
          total_count: 0,
          by_type: [],
        },
        rows: [],
        total_count: 0,
        error: errorMessage(error),
      };
    }
  }

  setupController(controller, model) {
    super.setupController(...arguments);
    if (typeof controller?.loadModel === "function") {
      controller.loadModel(model || {});
    }
  }
}
