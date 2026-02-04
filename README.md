# Discourse Secure Media (Server Plugin)

This plugin provides a JSON API for a media gallery with:
- Upload registration (uses Discourse core upload endpoint)
- Background processing (ffprobe + ffmpeg)
- Tokenized streaming endpoint (no direct upload URLs exposed)
- Filters: gender, tags, media_type
- Likes

## Security approach (practical, not DRM)
- Never returns `Upload#url` for media items.
- Playback uses short-lived signed tokens: `/media/stream/:token`
- Optional token binding to current user and/or IP.
- Inline/no-store headers to discourage trivial saving/caching.
- Original (high-quality) source can be deleted after processing.

## Requirements
- ffmpeg + ffprobe available in the container/host PATH
  - configurable via SiteSettings: `media_gallery_ffmpeg_path`, `media_gallery_ffprobe_path`

## Notes on "prevent download"
You cannot fully prevent saving without DRM. This plugin makes it harder by removing stable direct file URLs.
Frontend/UI measures (disable right click, hide controls, etc.) will be implemented in the separate component.

## Optional: Nginx X-Accel-Redirect (performance)
By default the plugin uses Rails `send_file`. If you want nginx to serve files:
- Add an internal location mapping to your uploads storage
- Extend StreamController to set `X-Accel-Redirect` (not enabled by default in this version)

Example idea (adjust paths for your install):

location /__media_internal__/ {
  internal;
  alias /var/www/discourse/public/uploads/;
}

Then you could set:
X-Accel-Redirect: /__media_internal__/original/1X/<sha1>.<ext>

This requires careful mapping and is installation-specific.
