export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryTestDownloads", {
      path: "/media-gallery-test-downloads",
    });
  },
};
