/* MirrorLink — landing page scripts
   - Fetches the latest release from the Pages Function /api/release
   - Wires the download buttons and release notes
   - Registers the service worker for offline PWA use
   - Injects a minimal "Not Found" handler for SPAs (not used, kept for future) */

(function () {
  "use strict";

  var GITHUB_REPO = "rkobroo/screenmirror";

  function qs(sel) { return document.querySelector(sel); }

  async function loadLatestRelease() {
    var versionTag = qs("#version-tag");
    var dlAndroid = qs("#dl-android");
    var dlWindows = qs("#dl-windows");
    var releaseTitle = qs("#release-title");
    var releaseBody = qs("#release-body");

    try {
      var res = await fetch("/api/release", { cache: "no-store" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      var data = await res.json();

      var tag = data.tag_name || "latest";
      if (versionTag) versionTag.textContent = tag;
      document.title = document.title.replace(/^MirrorLink/, "MirrorLink " + tag);

      if (data.android_url && dlAndroid) {
        dlAndroid.href = data.android_url;
      } else if (dlAndroid) {
        dlAndroid.href = "https://github.com/" + GITHUB_REPO + "/releases/latest";
      }

      if (data.windows_url && dlWindows) {
        dlWindows.href = data.windows_url;
      } else if (dlWindows) {
        dlWindows.href = "https://github.com/" + GITHUB_REPO + "/releases/latest";
      }

      if (data.name && releaseTitle) releaseTitle.textContent = data.name;
      if (data.body && releaseBody) releaseBody.textContent = data.body.trim();
      else if (releaseBody) releaseBody.textContent = "No release notes for this version.";
    } catch (err) {
      if (versionTag) versionTag.textContent = "check GitHub";
      var fallback = "https://github.com/" + GITHUB_REPO + "/releases/latest";
      if (dlAndroid) dlAndroid.href = fallback;
      if (dlWindows) dlWindows.href = fallback;
      if (releaseBody) releaseBody.textContent = "Could not reach the release API — see GitHub Releases.";
    }
  }

  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () { /* offline PWA is best-effort */ });
    });
  }

  loadLatestRelease();
})();
