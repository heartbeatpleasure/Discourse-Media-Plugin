// NOTE: This file previously attempted to register an admin route inside the main (public) Discourse
// Ember app, which can break boot when Discourse runs the admin UI as a separate bundle.
//
// Admin routes for this plugin now live under:
//   admin/assets/javascripts/admin/*
//
// Keeping this file as a no-op prevents crashes for installs which already deployed it.
export default function mediaGalleryForensicsExportsNoop() {}
