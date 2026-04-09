import "./api-initializers/media-gallery-settings-button-fix";

export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryMigrations", {
      path: "/media-gallery-migrations",
    });
  },
};
