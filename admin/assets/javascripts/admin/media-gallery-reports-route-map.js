export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryReports", {
      path: "/media-gallery-reports",
    });
  },
};
