import { next } from "@ember/runloop";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryHealthRoute extends DiscourseRoute {
  setupController(controller) {
    super.setupController(...arguments);

    const loadToken = (this._mediaGalleryHealthLoadToken || 0) + 1;
    this._mediaGalleryHealthLoadToken = loadToken;
    this._mediaGalleryHealthController = controller;

    if (typeof controller?.invalidatePendingHealthLoads === "function") {
      controller.invalidatePendingHealthLoads();
    }

    // Do not block the admin route model on the Health request and do not mutate
    // tracked controller state while the route/outlet is still being installed.
    // Starting in the next run loop mirrors other Media Gallery admin routes and
    // avoids leaving Glimmer with stale render subscriptions on a hard refresh.
    next(() => {
      if (
        this._mediaGalleryHealthLoadToken !== loadToken ||
        controller?.isDestroying ||
        controller?.isDestroyed
      ) {
        return;
      }

      if (typeof controller?.resetState === "function") {
        controller.resetState();
      }

      if (typeof controller?.loadHealth === "function") {
        controller.loadHealth({ fullStorage: false });
      }
    });
  }

  deactivate() {
    this._mediaGalleryHealthLoadToken =
      (this._mediaGalleryHealthLoadToken || 0) + 1;

    if (
      typeof this._mediaGalleryHealthController?.invalidatePendingHealthLoads ===
      "function"
    ) {
      this._mediaGalleryHealthController.invalidatePendingHealthLoads();
    }

    this._mediaGalleryHealthController = null;
    super.deactivate?.(...arguments);
  }
}
