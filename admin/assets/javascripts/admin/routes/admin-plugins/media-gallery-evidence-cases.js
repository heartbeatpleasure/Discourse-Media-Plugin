import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryEvidenceCasesRoute extends DiscourseRoute {
  model() {
    const caseRef = new URLSearchParams(window.location.search || "").get("case_ref") || "";
    const query = caseRef ? `&case_ref=${encodeURIComponent(caseRef)}` : "";
    return ajax(`/admin/plugins/media-gallery/evidence-cases.json?limit=50${query}`).catch((error) => ({
      ok: false,
      cases: [],
      error: error?.jqXHR?.responseJSON?.error || error?.message || String(error),
    }));
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.initializeFromModel(model);
  }
}
