export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGallerySettingsGuide", {
      path: "/media-gallery-settings-guide",
    });
  },
};
