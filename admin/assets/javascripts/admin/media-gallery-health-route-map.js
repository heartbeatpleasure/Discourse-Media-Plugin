export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryHealth", {
      path: "/media-gallery-health",
    });
  },
};
