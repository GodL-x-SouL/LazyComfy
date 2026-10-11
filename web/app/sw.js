/* LazyComfy app-shell cache. Hand-written: no deps, no precache manifest.
 *
 * - Hashed shell assets (/_next/static/*) are immutable: cache-first, so a
 *   warm WebView reheats the UI without touching the network.
 * - API (/lazycomfy/api/*), ComfyUI (/ws, /view, /upload, /prompt, /history,
 *   /queue, /system_stats) and non-GET requests: never intercepted.
 * - Documents: network-first with cache fallback, so a tunnel hiccup shows
 *   the last shell instead of a dead page.
 */
const CACHE = "lazycomfy-shell-v1";
const STATIC_RE = /\/lazycomfy\/app\/_next\/static\//;

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  let url;
  try {
    url = new URL(req.url);
  } catch {
    return;
  }
  const p = url.pathname;
  if (
    p.startsWith("/lazycomfy/api/") ||
    p === "/ws" ||
    p.startsWith("/view") ||
    p.startsWith("/upload") ||
    p.startsWith("/prompt") ||
    p.startsWith("/history") ||
    p.startsWith("/queue") ||
    p.startsWith("/system_stats")
  ) {
    return; // realtime data: always the network
  }
  if (STATIC_RE.test(p)) {
    event.respondWith(
      caches.open(CACHE).then(async (cache) => {
        const hit = await cache.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        // waitUntil: the worker may be killed the moment the response is
        // delivered, which would silently drop the fire-and-forget put.
        if (res.ok) event.waitUntil(cache.put(req, res.clone()).catch(() => {}));
        return res;
      }),
    );
    return;
  }
  if (req.mode === "navigate" || p.endsWith(".html")) {
    event.respondWith(
      fetch(req)
        .then(async (res) => {
          const cache = await caches.open(CACHE);
          if (res.ok) cache.put(req, res.clone());
          return res;
        })
        .catch(() => caches.match(req)),
    );
  }
});
