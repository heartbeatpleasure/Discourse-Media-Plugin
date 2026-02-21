import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class AdminPluginsMediaGalleryForensicsExportsRoute extends Route {
  async model() {
    try {
      // Keep data endpoint separate from the Ember route slug.
      return await ajax(
        "/admin/plugins/media-gallery/forensics-exports.json?limit=200"
      );
    } catch {
      return { exports: [], load_error: true };
    }
  }
}
