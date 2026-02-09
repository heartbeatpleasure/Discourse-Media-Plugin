// assets/javascripts/discourse/media-gallery-route-map.js
//
// Route map for the Media Gallery plugin.
//
// Dit registreert de pagina /media-library in de Ember router.
// De daadwerkelijke route-logica en template leveren we vanuit
// de theme component (routes/media-library.js + templates/media-library.hbs).
export default function mediaGallery() {
  this.route("media-library", { path: "/media-library" });
}
