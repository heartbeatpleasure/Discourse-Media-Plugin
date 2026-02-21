export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryForensicsExports", { path: "/media-gallery-forensics-exports" });
  },
};
