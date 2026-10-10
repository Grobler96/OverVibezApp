// OverVibez service worker: lets the app install and open offline, without ever caching anything private.
// - Pages: network first (so a new release shows up straight away), cached copy if offline.
// - Our own static files (icons, manifest): cached, refreshed in the background.
// - Supabase, Stripe and LiveKit calls are never touched. Library scripts from jsDelivr are cached so the app shell can start offline.
const VERSION = 'ov-v2';
const SHELL = ['./', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/favicon.svg'];

self.addEventListener('install', (e) => { e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET') return;
  const sameOrigin = url.origin === self.location.origin;
  const isCdnLib = url.hostname === 'cdn.jsdelivr.net';
  if (!sameOrigin && !isCdnLib) return;                                    // everything else goes straight to the network

  if (req.mode === 'navigate') {
    const isShell = url.pathname === new URL('./', self.location).pathname;      // only the app itself is kept as the offline page (not terms, creator pages, ...)
    e.respondWith(fetch(req).then((res) => { if (isShell) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put('./', copy)); } return res; })
      .catch(() => caches.match('./').then((r) => r || new Response('You are offline. Reconnect to use OverVibez.', { status: 503, headers: { 'Content-Type': 'text/plain' } }))));
    return;
  }
  e.respondWith(caches.match(req).then((hit) => {
    const net = fetch(req).then((res) => { if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); } return res; }).catch(() => hit);
    return hit || net;
  }));
});
