(function () {
  "use strict";

  // Footer "Refresh app" button. When the service worker has cached an
  // older app shell, the only way for installed PWAs to pick up new
  // CSS/JS is to evict the cache and reload — browsers don't expose a
  // user-friendly way to do this. The button is hidden in non-PWA
  // browser sessions (tab-based browsing already does Cmd+Shift+R).

  const btn = document.querySelector("[data-pwa-refresh]");
  if (!btn) return;

  // Show only when we're either running as a standalone PWA OR a
  // service worker is active (so the cache is what'd otherwise trap
  // the user).
  const standalone =
    window.matchMedia &&
    (matchMedia("(display-mode: standalone)").matches ||
      matchMedia("(display-mode: fullscreen)").matches ||
      navigator.standalone === true);

  if (!standalone && !("serviceWorker" in navigator)) return;

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.getRegistration().then(reg => {
      if (reg || standalone) btn.hidden = false;
    });
  } else if (standalone) {
    btn.hidden = false;
  }

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "Refreshing…";
    try {
      if ("serviceWorker" in navigator) {
        const regs = await navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map(r => r.unregister()));
      }
      if ("caches" in window) {
        const keys = await caches.keys();
        await Promise.all(keys.map(k => caches.delete(k)));
      }
    } finally {
      // Bypass the HTTP cache for this navigation; the SW is gone but
      // the browser may still hold an If-None-Match for style.css.
      const url = new URL(window.location.href);
      url.searchParams.set("pwa_refreshed", Date.now().toString());
      window.location.replace(url.toString());
    }
  });
})();
