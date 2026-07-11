import { scheduleOnce } from "@ember/runloop";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryHealthRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState !== "function") {
      return;
    }

    controller.resetState();

    // setupController runs before the route template has finished installing its
    // Glimmer render manager. Defer the first tracked-state update until that
    // render is complete, and avoid updating a controller that was destroyed by
    // a fast route transition.
    scheduleOnce("afterRender", this, () => {
      if (controller?.isDestroying || controller?.isDestroyed) {
        return;
      }

      if (typeof controller?.loadHealth === "function") {
        controller.loadHealth();
      }
    });
  }
}
