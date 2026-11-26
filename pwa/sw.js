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
  - Push notifications (announcements from the admin page, sent by the
    Supabase `push` Edge Function) are shown by the "push" handler at the
    bottom. Students turn them on with "Notifications" (assets/notifications.html).
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

// ---- Announcements (push notifications) --------------------------------------
// The message is JSON: { title, body, url, tag }. iPhone and iPad require
// every push to show a notification, so this always shows one.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) {
    data = { body: event.data ? event.data.text() : "" };
  }
  const title = data.title || "GEOG 215";
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || "",
    icon: "/icon-192.png",
    tag: data.tag || undefined,
    data: { url: data.url || "/" },
  }));
});

// Tapping the notification opens its page (on this site only), reusing an
// open window when there is one.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  let target = new URL("/", self.location.origin);
  try {
    const u = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin);
    if (u.origin === self.location.origin) target = u;
  } catch (_) { /* use the home page */ }
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (new URL(w.url).origin !== self.location.origin) continue;
      await w.focus();
      if (w.url !== target.href && "navigate" in w) {
        try { await w.navigate(target.href); } catch (_) { /* stays where it is */ }
      }
      return;
    }
    await self.clients.openWindow(target.href);
  })());
});
