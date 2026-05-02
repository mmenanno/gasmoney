// Service worker for the Gas Money PWA.
//
// Scope: keep this file at the site root so it controls the entire app.
// Strategy: cache the static "app shell" (CSS + JS + favicon + icons +
// fonts) and never touch HTML or POSTs. The trip-cost numbers and
// cost-per-km tiles are derived from the SQLite database server-side,
// so a fully offline experience would be misleading — better to fail
// honestly with the browser's offline page than to serve stale tiles.
//
// Bump CACHE_VERSION whenever the static asset list changes; the old
// cache is purged on the next activate event.

const CACHE_VERSION = "gasmoney-shell-v3";
const PRECACHE_URLS = [
  "/style.css",
  "/select.js",
  "/nav.js",
  "/confirm.js",
  "/pwa-refresh.js",
  "/sync.js",
  "/favicon.svg",
  "/favicon-32.png",
  "/icons/icon-192.png",
  "/icons/icon-256.png",
  "/icons/icon-512.png",
  "/manifest.webmanifest",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(PRECACHE_URLS)),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key.startsWith("gasmoney-shell-") && key !== CACHE_VERSION)
          .map((key) => caches.delete(key)),
      ),
    ),
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Only intercept paths that the precache list owns. Everything else
  // (HTML, /health, /calculate redirects, etc.) goes straight to the
  // network — no stale dashboards.
  if (!PRECACHE_URLS.includes(url.pathname)) return;

  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;
      return fetch(request).then((response) => {
        // Opportunistically cache fresh static-asset responses so
        // post-install asset rotations land in the cache without
        // requiring a SW upgrade.
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
        }
        return response;
      });
    }),
  );
});
