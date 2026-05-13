export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryStatistics", {
      path: "/media-gallery-statistics",
    });
  },
};
