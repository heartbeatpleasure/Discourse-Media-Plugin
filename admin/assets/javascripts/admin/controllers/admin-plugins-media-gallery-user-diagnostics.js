import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

function formatDateTime(value) {
  if (!value) return "-";
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function boolLabel(value) {
  return value ? "Yes" : "No";
}

function statusClass(value) {
  return value ? "is-success" : "is-danger";
}

function severityClass(value) {
  switch (String(value || "").toLowerCase()) {
    case "success":
    case "ok":
      return "is-success";
    case "warning":
    case "warn":
      return "is-warning";
    case "danger":
    case "error":
    case "critical":
    case "failed":
    case "failure":
      return "is-danger";
    case "info":
    case "notice":
    case "debug":
      return "is-info";
    default:
      return "";
  }
}

function encodeParam(value) {
  return encodeURIComponent(String(value || "").trim());
}

function titleize(value) {
  return String(value || "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

export default class AdminPluginsMediaGalleryUserDiagnosticsController extends Controller {
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked selectedUser = null;
  @tracked access = null;
  @tracked settingsRows = [];
  @tracked stats = null;
  @tracked recent = { uploads: [], logs: [], reports: [] };
  @tracked isSearching = false;
  @tracked isLoadingUser = false;
  @tracked searchError = "";
  @tracked loadError = "";
  @tracked noticeMessage = "";

  resetState() {
    this.searchQuery = "";
    this.searchResults = [];
    this.selectedUser = null;
    this.access = null;
    this.settingsRows = [];
    this.stats = null;
    this.recent = { uploads: [], logs: [], reports: [] };
    this.isSearching = false;
    this.isLoadingUser = false;
    this.searchError = "";
    this.loadError = "";
    this.noticeMessage = "";
  }

  async loadInitial() {
    const params = new URLSearchParams(window.location.search || "");
    const userId = params.get("user_id");
    const q = params.get("q");
    if (q) {
      this.searchQuery = q.slice(0, 120);
      await this.searchUsers();
    }
    if (userId && /^\d+$/.test(userId)) {
      await this.loadUser(userId);
    }
  }

  get hasSearchResults() {
    return Array.isArray(this.searchResults) && this.searchResults.length > 0;
  }

  get hasSelectedUser() {
    return !!this.selectedUser;
  }

  get userNameLabel() {
    const user = this.selectedUser;
    if (!user) return "No user selected";
    return user.name ? `${user.username} - ${user.name}` : user.username;
  }

  get accountRows() {
    const user = this.selectedUser || {};
    return [
      { label: "User ID", value: user.id || "-" },
      { label: "Trust level", value: user.trust_level == null ? "-" : `TL${user.trust_level}` },
      { label: "Username", value: user.username || "-" },
      { label: "Name", value: user.name || "-" },
      { label: "Created", value: formatDateTime(user.created_at) },
      { label: "Last seen", value: formatDateTime(user.last_seen_at) },
      { label: "Suspended", value: user.suspended ? `Yes${user.suspended_till ? ` until ${formatDateTime(user.suspended_till)}` : ""}` : "No" },
      { label: "Silenced", value: user.silenced ? `Yes${user.silenced_till ? ` until ${formatDateTime(user.silenced_till)}` : ""}` : "No" },
    ];
  }

  get roleBadges() {
    const user = this.selectedUser || {};
    const badges = [];
    if (user.admin) badges.push({ label: "Admin", className: "is-danger" });
    if (user.moderator) badges.push({ label: "Moderator", className: "is-warning" });
    if (user.staff) badges.push({ label: "Staff", className: "is-success" });
    if (user.staged) badges.push({ label: "Staged", className: "" });
    if (!user.active) badges.push({ label: "Inactive", className: "is-warning" });
    if (user.suspended) badges.push({ label: "Suspended", className: "is-danger" });
    if (user.silenced) badges.push({ label: "Silenced", className: "is-warning" });
    if (!badges.length) badges.push({ label: "Regular user", className: "" });
    return badges;
  }

  get mediaAccessCards() {
    const access = this.access || {};
    const threshold = access.report_score_threshold || "disabled";
    const weight = access.report_score_points ?? 0;
    return [
      { label: "Can view", value: boolLabel(access.can_view), className: statusClass(access.can_view), reason: access.view_reason },
      { label: "Can upload", value: boolLabel(access.can_upload), className: statusClass(access.can_upload), reason: access.upload_reason },
      { label: "Can report", value: boolLabel(access.can_report), className: statusClass(access.can_report), reason: access.report_reason },
      { label: "Instant auto-hide reporter", value: boolLabel(access.report_auto_hide_instant), className: access.report_auto_hide_instant ? "is-warning" : "", reason: access.report_auto_hide_instant_reason },
      { label: "Report point weight", value: `${weight} per report`, className: weight > 0 ? "is-info" : "", reason: `Per media item threshold: ${threshold}. Only open reports on the same media item count.` },
    ];
  }

  get statCards() {
    const stats = this.stats || {};
    const userId = this.selectedUser?.id;
    const username = this.selectedUser?.username || "";
    const managementUrl = userId ? `/admin/plugins/media-gallery-management?user_id=${encodeParam(userId)}` : "";
    const reportsByUserUrl = userId ? `/admin/plugins/media-gallery-reports?status=all&reporter_user_id=${encodeParam(userId)}` : "";
    const reportsOnUserMediaUrl = userId ? `/admin/plugins/media-gallery-reports?status=all&media_owner_user_id=${encodeParam(userId)}` : "";
    const logsUrl = username ? `/admin/plugins/media-gallery-logs?q=${encodeParam(username)}&hours=720` : "";

    return [
      { label: "Uploads", value: stats.uploads_total ?? 0, url: managementUrl },
      { label: "Ready", value: stats.uploads_ready ?? 0, url: managementUrl },
      { label: "Failed", value: stats.uploads_failed ?? 0, url: managementUrl },
      { label: "Queued / processing", value: stats.uploads_processing ?? 0, url: managementUrl },
      { label: "Hidden uploads", value: stats.uploads_hidden ?? 0, url: managementUrl },
      { label: "Reports submitted", value: stats.reports_submitted ?? 0, url: reportsByUserUrl },
      { label: "Reports on user's media", value: stats.reports_against_media ?? 0, url: reportsOnUserMediaUrl },
      { label: "Likes given", value: stats.likes_given ?? 0 },
      { label: "Playback sessions", value: stats.playback_sessions ?? 0 },
      { label: "Log events 30d", value: stats.log_events_30d ?? 0, url: logsUrl },
    ];
  }

  get groupNames() {
    return (this.selectedUser?.groups || []).map((group) => group.name).join(", ") || "No displayable groups found";
  }

  get recentUploads() {
    return (this.recent?.uploads || []).map((item) => ({
      ...item,
      createdAtLabel: formatDateTime(item.created_at),
      statusLabel: titleize(item.status),
      typeLabel: titleize(item.media_type),
      containsLabel: titleize(item.gender),
      tagsLabel: Array.isArray(item.tags) && item.tags.length ? item.tags.join(", ") : "No tags",
      visibilityLabel: item.hidden ? "Hidden" : "Visible",
      visibilityClass: item.hidden ? "is-danger" : "is-success",
    }));
  }

  get recentLogs() {
    return (this.recent?.logs || []).map((event) => ({
      ...event,
      createdAtLabel: formatDateTime(event.created_at),
      eventLabel: titleize(event.event_type),
      severityLabel: titleize(event.severity || "info"),
      severityClass: severityClass(event.severity),
    }));
  }

  get recentReports() {
    return (this.recent?.reports || []).map((report) => ({
      ...report,
      createdAtLabel: formatDateTime(report.created_at),
      statusLabel: titleize(report.status),
      statusClass: report.status === "open" ? "is-warning" : report.status === "accepted" ? "is-danger" : report.status === "resolved" ? "is-success" : "",
    }));
  }

  async _extractError(response) {
    try {
      const json = await response.clone().json();
      if (Array.isArray(json?.errors) && json.errors.length) return json.errors.join(" ");
      if (json?.message) return String(json.message);
      if (json?.error) return String(json.error);
    } catch {
      // ignore
    }
    return `HTTP ${response.status}`;
  }

  async _fetchJson(url, options = {}) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "X-Requested-With": "XMLHttpRequest",
        ...options.headers,
      },
      ...options,
    });

    if (!response.ok) throw new Error(await this._extractError(response));
    return await response.json();
  }

  @action
  updateSearchQuery(event) {
    this.searchQuery = String(event?.target?.value || "").slice(0, 120);
  }

  @action
  async searchUsers(event) {
    event?.preventDefault?.();
    const q = String(this.searchQuery || "").trim();
    if (!q) {
      this.searchResults = [];
      this.searchError = "Enter a username, display name, or user ID.";
      return;
    }

    this.isSearching = true;
    this.searchError = "";
    this.noticeMessage = "";

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/user-diagnostics/search?q=${encodeURIComponent(q)}`);
      this.searchResults = Array.isArray(data?.users) ? data.users : [];
      if (!this.searchResults.length) this.searchError = "No users found.";
    } catch (error) {
      this.searchError = error?.message || "Search failed.";
    } finally {
      this.isSearching = false;
    }
  }

  @action
  async selectUser(user) {
    if (!user?.id) return;
    await this.loadUser(user.id);
  }

  async loadUser(userId) {
    this.isLoadingUser = true;
    this.loadError = "";
    this.noticeMessage = "";

    try {
      const data = await this._fetchJson(`/admin/plugins/media-gallery/user-diagnostics/${encodeURIComponent(userId)}`);
      this.selectedUser = data?.user || null;
      this.access = data?.access || null;
      this.settingsRows = Array.isArray(data?.settings) ? data.settings : [];
      this.stats = data?.stats || null;
      this.recent = data?.recent || { uploads: [], logs: [], reports: [] };
      if (this.selectedUser?.id) {
        const url = new URL(window.location.href);
        url.searchParams.set("user_id", this.selectedUser.id);
        window.history.replaceState({}, "", url.toString());
      }
    } catch (error) {
      this.loadError = error?.message || "Loading user diagnostics failed.";
    } finally {
      this.isLoadingUser = false;
    }
  }

  formatDate(value) {
    return formatDateTime(value);
  }

  titleize(value) {
    return titleize(value);
  }
}
