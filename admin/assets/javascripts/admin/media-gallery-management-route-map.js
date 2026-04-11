export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryManagement", {
      path: "/media-gallery-management",
    });
  },
};
