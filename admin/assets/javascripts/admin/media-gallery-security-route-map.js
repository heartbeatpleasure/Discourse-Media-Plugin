export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGallerySecurity", {
      path: "/media-gallery-security",
    });
  },
};
