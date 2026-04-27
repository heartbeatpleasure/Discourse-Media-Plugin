import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

export default apiInitializer("1.34.0", (api) => {
  api.registerNotificationTypeRenderer("custom", (NotificationTypeBase) => {
    return class MediaGalleryProcessingNotification extends NotificationTypeBase {
      get isMediaGalleryProcessingNotification() {
        return this.notification?.data?.media_gallery_processing === true;
      }

      get linkHref() {
        if (this.isMediaGalleryProcessingNotification) {
          return this.notification.data.url || "/media-library?tab=mine";
        }

        return super.linkHref;
      }

      get linkTitle() {
        if (this.isMediaGalleryProcessingNotification) {
          return i18n(this.notification.data.title);
        }

        if (this.notification?.data?.title) {
          return i18n(this.notification.data.title);
        }

        return super.linkTitle;
      }

      get icon() {
        if (this.isMediaGalleryProcessingNotification) {
          return this.notification.data.status === "ready"
            ? "circle-check"
            : "triangle-exclamation";
        }

        if (this.notification?.data?.message) {
          return `notification.${this.notification.data.message}`;
        }

        return super.icon;
      }

      get label() {
        if (this.isMediaGalleryProcessingNotification) {
          return null;
        }

        return super.label;
      }

      get description() {
        if (this.isMediaGalleryProcessingNotification) {
          return i18n(this.notification.data.message, {
            title: this.notification.data.media_title || "Untitled media item",
          });
        }

        return super.description;
      }
    };
  });
});
