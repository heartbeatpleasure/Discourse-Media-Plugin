import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";
import { ajaxEvidenceErrorMessage } from "../../lib/media-gallery-evidence-ui";

export default class AdminPluginsMediaGalleryEvidenceCasesRoute extends DiscourseRoute {
  async model() {
    const requestedCaseRef =
      new URLSearchParams(window.location.search || "").get("case_ref") || "";

    let base;
    try {
      base = await ajax(
        "/admin/plugins/media-gallery/evidence-cases.json?limit=50"
      );
    } catch (error) {
      return {
        ok: false,
        cases: [],
        selected: null,
        config: null,
        requestedCaseRef,
        error: ajaxEvidenceErrorMessage(
          error,
          "The evidence configuration and case list could not be loaded."
        ),
      };
    }

    if (!requestedCaseRef) {
      return { ...base, requestedCaseRef, selectedError: "" };
    }

    try {
      const selectedResponse = await ajax(
        `/admin/plugins/media-gallery/evidence-cases/${encodeURIComponent(
          requestedCaseRef
        )}.json`
      );
      return {
        ...base,
        selected: selectedResponse?.case || null,
        config: selectedResponse?.config || base?.config || null,
        requestedCaseRef,
        selectedError: "",
      };
    } catch (error) {
      return {
        ...base,
        selected: null,
        requestedCaseRef,
        selectedError: ajaxEvidenceErrorMessage(
          error,
          `Evidence case ${requestedCaseRef} was created, but its details could not be loaded.`
        ),
      };
    }
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.initializeFromModel(model);
  }
}
