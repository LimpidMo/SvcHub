// PWA Service Worker：仅作安装资格占位，不做任何缓存与拦截。
// 页面数据全走实时请求（CGI 带 no-store），外壳也不缓存——断网打不开页面是预期行为。
// 版本号仅用于模块升级时触发 SW 字节变化让浏览器重新安装。
const CACHE = 'svchub-shell-v1';

self.addEventListener('install', (e) => {
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
