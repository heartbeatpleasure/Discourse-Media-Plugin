export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryUserDiagnostics", {
      path: "/media-gallery-user-diagnostics",
    });
  },
};
