import "./api-initializers/media-gallery-settings-button-fix";

export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("mediaGalleryEvidenceCases", { path: "/media-gallery-evidence-cases" });
  },
};
