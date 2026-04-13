export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryLogs", { path: "/media-gallery-logs" });
  },
};
