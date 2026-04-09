export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("media-gallery", { path: "/media-gallery" });
  },
};
