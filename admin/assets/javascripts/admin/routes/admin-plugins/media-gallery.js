import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsMediaGalleryRoute extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/media-gallery/access.json");
  }
}
