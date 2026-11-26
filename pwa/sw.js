/*
  geog215.org service worker: makes the site installable and lets pages a
  student has already opened load offline. Copied to the site root by
  scripts/cloudflare-build.sh (geog215.org only, never daveparr.com).

  Rules:
  - Only GET requests are touched, and only from geog215.org itself, the
    pinned supabase-js script, and Google Fonts.
  - Supabase (sign-in, quiz answers, polls, questions, progress) is never
    intercepted or cached: those requests go straight to the network.
  - /admin/ is never cached.
  - Pages, CSS, scripts, and quiz banks are network first: online, students
    always get the latest version; the saved copy is only used offline.
  - Bump VERSION to drop every saved copy (for example after a big change).
*/
const VERSION = "v1";
const CACHE = "geog215-" + VERSION;
const OFFLINE_URL = "/offline.html";
const PRECACHE = [OFFLINE_URL, "/icon-192.png"];

// Cross-origin files that never change at a given URL (pinned or font files).
const CDN_ALLOW = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@",
  "https://fonts.googleapis.com/",
  "https://fonts.gstatic.com/",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k.startsWith("geog215-") && k !== CACHE).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

function shouldHandle(request) {
  if (request.method !== "GET") return false;
  if (request.headers.has("authorization")) return false;
  const url = new URL(request.url);
  if (url.origin === self.location.origin) {
    return !url.pathname.startsWith("/admin");
  }
  return CDN_ALLOW.some((prefix) => request.url.startsWith(prefix));
}

// Save a copy only of complete, successful responses.
function save(request, response) {
  const okSameOrigin = response.ok && response.type === "basic";
  const okCdn = response.type === "opaque" || (response.ok && response.type === "cors");
  if (!(okSameOrigin || okCdn)) return;
  const copy = response.clone();
  caches.open(CACHE).then((cache) => cache.put(request, copy)).catch(() => {});
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (!shouldHandle(request)) return; // the browser handles it as usual

  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      save(request, response);
      return response;
    } catch (err) {
      // Offline (or the network failed): use the saved copy if there is one.
      const cached = await caches.match(request, { ignoreSearch: request.mode === "navigate" });
      if (cached) return cached;
      if (request.mode === "navigate") {
        const offline = await caches.match(OFFLINE_URL);
        if (offline) return offline;
      }
      throw err;
    }
  })());
});
