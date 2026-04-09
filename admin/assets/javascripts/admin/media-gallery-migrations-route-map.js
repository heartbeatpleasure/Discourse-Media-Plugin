import "./api-initializers/media-gallery-settings-button-fix";

export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("media-gallery-migrations", {
      path: "/media-gallery-migrations",
    });
  },
};
