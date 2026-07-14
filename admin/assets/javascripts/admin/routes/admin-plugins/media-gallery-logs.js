import DiscourseRoute from "discourse/routes/discourse";
import { next } from "@ember/runloop";

export default class AdminPluginsMediaGalleryLogsRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);

    if (typeof controller?.resetState === "function") {
      controller.resetState();
    }

    const params = new URLSearchParams(window.location?.search || "");
    const query = String(params.get("q") || "").trim();
    const hours = String(params.get("hours") || "").trim();
    const severity = String(params.get("severity") || "").trim();
    const category = String(params.get("category") || "").trim();
    const eventType = String(params.get("event_type") || "").trim();
    if (query) {
      controller.query = query.slice(0, 200);
    }
    if (["24", "72", "168", "720", "2160"].includes(hours)) {
      controller.hoursFilter = hours;
    }
    if (severity) {
      controller.severityFilter = severity.slice(0, 40);
    }
    if (category) {
      controller.categoryFilter = category.slice(0, 80);
    }
    if (eventType) {
      controller.eventTypeFilter = eventType.slice(0, 100);
    }

    if (typeof controller?.loadLogs === "function") {
      next(() => controller.loadLogs());
    }
  }
}
