/* Runs before Bilibili's player. The local authentication token is never in this world. */
(() => {
  "use strict";
  const C = globalThis.BiliCaptionCore;
  if (!C || globalThis.__biliCaptionPageHookV1) return;
  Object.defineProperty(globalThis, "__biliCaptionPageHookV1", {value: true});
  const MARKER = "bili-caption-menu-v1";
  const originalFetch = window.fetch.bind(window);
  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  const xhrInfo = new WeakMap();
  const languageByURL = new Map();
  const captured = new Map();
  const provisional = new Map(), pendingMetadata = new Map();
  const readFallback = new Set();
  const tracks = new Map();
  let catalog = null, catalogLoading = "", metadataAttempt = "", metadataSeen = false;
  let subtitleStatus = "正在检查字幕", preference = "ai";
  let expectedCID = "", expectedAid = "";
  let nonce = "", cid = "", baseKey = C.basePageKey(location.href);
  function identity() {
    const next = C.basePageKey(location.href);
    if (next !== baseKey) { baseKey = next; cid = ""; expectedCID = ""; expectedAid = ""; captured.clear(); provisional.clear(); pendingMetadata.clear(); languageByURL.clear(); readFallback.clear(); tracks.clear(); catalog = null; catalogLoading = ""; metadataAttempt = ""; metadataSeen = false; subtitleStatus = "正在检查字幕"; }
    return C.pageKey(location.href, cid);
  }
  function send(type, payload) {
    if (!nonce) return;
    window.postMessage({marker: MARKER, direction: "page", nonce, type, ...payload}, location.origin);
  }
  function absoluteURL(value) {
    try { return new URL(typeof value === "string" ? value : value?.url || "", location.href).href; }
    catch { return ""; }
  }
  function expectedIdentity(data) {
    if (!data || !baseKey) return;
    const pageURL = new URL(baseKey), id = pageURL.pathname.split("/")[2];
    if (data.bvid !== id && `av${data.aid}` !== id) return;
    const part = Number(pageURL.searchParams.get("p") || 1);
    const page = data.pages?.find(item => Number(item.page) === part);
    const value = String(page?.cid || (part === 1 ? data.cid : "") || "");
    if (/^\d{1,20}$/.test(value)) expectedCID = value;
    if (/^\d{1,20}$/.test(String(data.aid || ""))) expectedAid = String(data.aid);
  }
  function sendCatalog() {
    send("catalog", {pageKey: identity(), catalog: {...(catalog || {title: "", items: []}), subtitles: [...tracks.values()].map(({id, label, language, isAI}) => ({id, label, language, isAI})), subtitleStatus}});
  }
  async function loadTrack(track) {
    if (!track || captured.has(track.url) || readFallback.has(track.url)) return;
    const key = identity(), requestedBaseKey = baseKey;
    readFallback.add(track.url);
    try { await readResponse(await originalFetch(track.url, {credentials: "omit", cache: "force-cache"}), track.url, requestedBaseKey, key); }
    catch { readFallback.delete(track.url); }
  }
  function preferredTracks() {
    return [...tracks.values()].sort((a, b) => {
      const rank = item => C.languageRank(item.language) + (item.isAI === (preference === "ai") ? 30 : 0);
      return rank(b) - rank(a);
    });
  }
  async function inspectCatalog() {
    const key = identity(), requestedBaseKey = baseKey;
    if (!key || catalogLoading === requestedBaseKey) return;
    catalogLoading = requestedBaseKey;
    try {
      const id = new URL(key).pathname.split("/")[2];
      let data = window.__INITIAL_STATE__?.videoData;
      if (!data || data.bvid !== id && `av${data.aid}` !== id) {
        const query = id.startsWith("BV") ? `bvid=${encodeURIComponent(id)}` : `aid=${id.slice(2)}`;
        const response = await originalFetch(`https://api.bilibili.com/x/web-interface/view?${query}`, {credentials: "include"});
        const value = await response.json();
        if (value.code !== 0) throw new Error("目录暂不可用");
        data = value.data;
      }
      if (C.basePageKey(identity()) !== requestedBaseKey) return;
      expectedIdentity(data);
      catalog = C.catalogFromVideo(data, key);
      const deferred = pendingMetadata.get(expectedCID);
      pendingMetadata.clear();
      if (deferred) consume(deferred.url, deferred.value, requestedBaseKey, identity());
      sendCatalog();
      // The player normally requests this metadata itself. This fallback also
      // discovers subtitles when CC is off; it uses only the current video's CID.
      const nextCID = expectedCID;
      if (!metadataSeen && /^\d{1,20}$/.test(nextCID) && metadataAttempt !== requestedBaseKey) {
        metadataAttempt = requestedBaseKey;
        const query = new URLSearchParams({cid: nextCID, ...(id.startsWith("BV") ? {bvid: id} : {aid: id.slice(2)})});
        const url = `https://api.bilibili.com/x/player/v2?${query}`;
        await readResponse(await originalFetch(url, {credentials: "include"}), url, requestedBaseKey, key);
      }
    } catch { if (!catalog) { subtitleStatus = "字幕或目录暂不可用，可重新同步"; sendCatalog(); } }
    finally { if (catalogLoading === requestedBaseKey) catalogLoading = ""; }
  }
  function consume(url, value, requestedBaseKey, requestedKey) {
    const currentKey = identity();
    if (!currentKey || requestedBaseKey !== baseKey) return;
    if (C.metadataURL(url)) {
      // Bilibili also requests metadata for hover previews and preloads. A BV
      // match alone is insufficient: each part has its own globally unique CID.
      expectedIdentity(window.__INITIAL_STATE__?.videoData);
      const parsedURL = new URL(url);
      const nextCID = String(value?.data?.cid || parsedURL.searchParams.get("cid") || "");
      const responseBV = value?.data?.bvid || parsedURL.searchParams.get("bvid");
      const responseAid = String(value?.data?.aid || parsedURL.searchParams.get("aid") || "");
      const pageVideo = new URL(baseKey).pathname.split("/")[2];
      if (responseBV && pageVideo.startsWith("BV") && responseBV !== pageVideo) return;
      if (responseAid && expectedAid && responseAid !== expectedAid) return;
      if (!/^\d{1,20}$/.test(nextCID)) return;
      if (!expectedCID) {
        pendingMetadata.set(nextCID, {url, value});
        if (pendingMetadata.size > 4) pendingMetadata.delete(pendingMetadata.keys().next().value);
        void inspectCatalog();
        return;
      }
      if (nextCID !== expectedCID) return;
      if (value?.code !== undefined && value.code !== 0) {
        if (!tracks.size) {
          subtitleStatus = value.code === -101 ? "请先登录 B 站以读取字幕" : "字幕读取暂不可用，请在网页开启字幕或重新同步";
          sendCatalog();
        }
        return;
      }
      metadataSeen = true;
      if (/^\d{1,20}$/.test(nextCID) && nextCID !== cid) {
        const hadCID = !!cid;
        cid = nextCID;
        if (hadCID) captured.clear();
        readFallback.clear();
        send("identity", {pageKey: identity()});
      }
      const subtitles = value?.data?.subtitle?.subtitles;
      if (Array.isArray(subtitles)) {
        tracks.clear();
        languageByURL.clear();
        for (const track of subtitles.slice(0, 100)) {
          const subtitleUrl = absoluteURL(track?.subtitle_url);
          if (C.subtitleURL(subtitleUrl)) {
            const language = C.cleanText(track.lan, 60);
            const id = C.cleanText(String(track.id_str || track.id || language), 300);
            tracks.set(id, {id, url: subtitleUrl, language, label: C.cleanText(track.lan_doc || language, 100), isAI: /^ai-/i.test(language) || track.type === 1});
            languageByURL.set(subtitleUrl, language);
            const existing = captured.get(subtitleUrl) || provisional.get(subtitleUrl);
            if (existing) {
              const updated = {...existing, id, pageKey: identity(), language};
              captured.set(subtitleUrl, updated);
              send("track", updated);
            }
          }
        }
        provisional.clear();
        for (const oldURL of captured.keys()) if (!languageByURL.has(oldURL)) captured.delete(oldURL);
        subtitleStatus = tracks.size ? "字幕轨道已就绪" : value?.data?.need_login_subtitle ? "请先登录 B 站以读取字幕" : "B 站未提供可用字幕";
        sendCatalog();
        // Fetch the preferred Chinese track proactively. Selecting another
        // available track loads only that known resource, never arbitrary URLs.
        void loadTrack(preferredTracks()[0]);
      }
      if (!catalog) void inspectCatalog();
      return;
    }
    if (!C.subtitleURL(url)) return;
    // Discard a response that belongs to an earlier part of a SPA video.
    if (new URL(requestedKey).searchParams.get("cid") && requestedKey !== currentKey) return;
    const cues = C.normalizeCues(value);
    if (!cues) return;
    const descriptor = [...tracks.values()].find(item => item.url === url);
    if (!descriptor) {
      // An early response is usable only if current-part metadata later names
      // this exact URL. Never publish arbitrary preview/history subtitle files.
      if (!metadataSeen) {
        provisional.set(url, {url, cues});
        if (provisional.size > 6) provisional.delete(provisional.keys().next().value);
      }
      return;
    }
    const track = {url, id: descriptor?.id || "", pageKey: currentKey, language: languageByURL.get(url) || C.cleanText(value?.lang, 60), cues};
    captured.set(url, track);
    if (captured.size > 6) captured.delete(captured.keys().next().value);
    send("track", track);
  }
  async function readResponse(response, url, requestedBaseKey, requestedKey) {
    try {
      if (!response.ok) return;
      const length = Number(response.headers.get("content-length") || 0);
      if (length > C.LIMITS.jsonBytes) return;
      const text = await response.text();
      if (text.length > C.LIMITS.jsonBytes) return;
      consume(url, JSON.parse(text), requestedBaseKey, requestedKey);
    } catch { /* An unavailable or non-JSON resource cannot affect the player. */ }
  }
  window.fetch = async function (...args) {
    const url = absoluteURL(args[0]);
    const key = identity(), requestedBaseKey = baseKey;
    const response = await originalFetch(...args);
    if (key && (C.subtitleURL(url) || C.metadataURL(url))) {
      try { void readResponse(response.clone(), url, requestedBaseKey, key); } catch { /* No player interruption. */ }
    }
    return response;
  };
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    const key = identity();
    xhrInfo.set(this, {url: absoluteURL(url), key, baseKey});
    return originalOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function (...args) {
    const info = xhrInfo.get(this);
    if (info?.key && (C.subtitleURL(info.url) || C.metadataURL(info.url))) {
      this.addEventListener("load", () => {
        try {
          if (this.status < 200 || this.status >= 300) return;
          let value;
          if (this.responseType === "json") value = this.response;
          else if (this.responseType === "" || this.responseType === "text") {
            if (this.responseText.length > C.LIMITS.jsonBytes) return;
            value = JSON.parse(this.responseText);
          } else return;
          consume(info.url, value, info.baseKey, info.key);
        } catch { /* Ignore unrelated/invalid JSON. */ }
      }, {once: true});
    }
    return originalSend.apply(this, args);
  };
  function resourceFallback(entry) {
    const url = entry.name;
    if (!C.subtitleURL(url) || !languageByURL.has(url) || captured.has(url) || readFallback.has(url)) return;
    const key = identity(), requestedBaseKey = baseKey;
    if (!key) return;
    readFallback.add(url);
    // A worker/cached player may bypass window.fetch/XHR. Re-read only an already
    // requested subtitle resource, anonymously; never request audio/video or cookies.
    setTimeout(() => {
      if (captured.has(url) || identity() !== key) return;
      void originalFetch(url, {credentials: "omit", cache: "force-cache"})
        .then(response => readResponse(response, url, requestedBaseKey, key)).catch(() => {});
    }, 1200);
  }
  try {
    const observer = new PerformanceObserver(list => list.getEntries().forEach(resourceFallback));
    observer.observe({type: "resource", buffered: true});
  } catch { /* fetch/XHR hooks still work without resource timing. */ }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin) return;
    const message = event.data;
    if (!message || message.marker !== MARKER || message.direction !== "content") return;
    if (message.type === "hello" && typeof message.nonce === "string" && /^[a-f\d]{32}$/.test(message.nonce)) {
      nonce = message.nonce;
      send("ready", {pageKey: identity()});
      for (const track of captured.values()) if (track.pageKey === identity()) send("track", track);
      if (catalog) sendCatalog();
      else void inspectCatalog();
    } else if (message.type === "resync" && message.nonce === nonce) {
      send("identity", {pageKey: identity()});
      for (const track of captured.values()) if (track.pageKey === identity()) send("track", track);
      performance.getEntriesByType("resource").forEach(resourceFallback);
      if (catalog) sendCatalog();
      else void inspectCatalog();
      if (!tracks.size) { metadataSeen = false; metadataAttempt = ""; void inspectCatalog(); }
      for (const track of tracks.values()) if (!captured.has(track.url)) readFallback.delete(track.url);
      for (const track of preferredTracks().slice(0, 1)) void loadTrack(track);
    } else if (message.nonce === nonce && message.type === "selectSubtitle") {
      const track = tracks.get(message.subtitleID);
      if (track) {
        if (captured.has(track.url)) send("track", {...captured.get(track.url), id: track.id});
        else void loadTrack(track);
      }
    } else if (message.nonce === nonce && message.type === "subtitlePreference" && ["ai", "human"].includes(message.preference)) {
      preference = message.preference;
      void loadTrack(preferredTracks()[0]);
    }
  });
})();
