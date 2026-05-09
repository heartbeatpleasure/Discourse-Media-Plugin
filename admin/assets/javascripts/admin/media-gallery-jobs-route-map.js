export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryJobs", {
      path: "/media-gallery-jobs",
    });
  },
};
