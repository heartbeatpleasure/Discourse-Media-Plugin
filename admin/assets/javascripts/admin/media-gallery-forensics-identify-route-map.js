export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryForensicsIdentify", {
      path: "/media-gallery-forensics-identify",
    });
  },
};
