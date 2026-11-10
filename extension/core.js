/* Pure validation shared by the page hook, isolated content script and worker. */
(() => {
  "use strict";
  const LIMITS = Object.freeze({cues: 50000, cueChars: 2000, textChars: 2000000, jsonBytes: 4 * 1024 * 1024});
  function cleanText(value, maximum = LIMITS.cueChars) {
    return typeof value === "string" ? value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "").trim().slice(0, maximum) : "";
  }
  function videoPage(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" && parsed.hostname === "www.bilibili.com" && /^\/video\/(BV[a-z\d]+|av\d+)\/?$/i.test(parsed.pathname);
    } catch { return false; }
  }
  function pageKey(url, cid = "") {
    if (!videoPage(url)) return "";
    const parsed = new URL(url);
    const part = Number(parsed.searchParams.get("p") || "1");
    const normalizedPart = Number.isInteger(part) && part > 0 && part <= 100000 ? part : 1;
    const query = new URLSearchParams({p: String(normalizedPart)});
    if (/^\d{1,20}$/.test(String(cid))) query.set("cid", String(cid));
    return `${parsed.origin}${parsed.pathname.replace(/\/$/, "")}/?${query}`;
  }
  function basePageKey(url) { return pageKey(url); }
  function mediaItems(input) {
    if (!Array.isArray(input) || input.length > 1000) return [];
    const seen = new Set();
    return input.flatMap((entry, index) => {
      const url = pageKey(entry?.url || entry?.id || "");
      if (!url || seen.has(url)) return [];
      seen.add(url);
      return [{id: url, url, title: cleanText(entry.title, 300) || `第 ${index + 1} 集`, index: index + 1,
        ...(Number.isFinite(entry.duration) && entry.duration >= 0 && entry.duration <= 604800 ? {duration: entry.duration} : {})}];
    });
  }
  function catalogFromVideo(data, currentURL) {
    if (!data || !videoPage(currentURL)) return null;
    const current = new URL(currentURL), videoID = /^BV[a-z\d]+$/i.test(data.bvid || "") ? data.bvid : current.pathname.split("/")[2];
    const pages = Array.isArray(data.pages) ? data.pages : [];
    let items;
    if (pages.length > 1) {
      items = pages.slice(0, 1000).map((part, index) => ({url: `https://www.bilibili.com/video/${videoID}/?p=${Number.isInteger(part.page) && part.page > 0 ? part.page : index + 1}`, title: part.part, duration: part.duration}));
    } else {
      const episodes = data.ugc_season?.sections?.flatMap(section => Array.isArray(section.episodes) ? section.episodes : []) || [];
      items = episodes.length ? episodes.slice(0, 1000).map(item => ({url: `https://www.bilibili.com/video/${item.bvid || item.arc?.bvid}/?p=1`, title: item.title || item.arc?.title, duration: item.arc?.duration || item.page?.duration})) : [{url: currentURL, title: data.title || pages[0]?.part, duration: data.duration}];
    }
    return {title: cleanText(data.ugc_season?.title || data.title, 300), items: mediaItems(items)};
  }
  function safeMediaURL(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" && (parsed.hostname.endsWith(".hdslb.com") || parsed.hostname.endsWith(".bilibili.com") || parsed.hostname === "bilibili.com");
    } catch { return false; }
  }
  function subtitleURL(url) {
    if (!safeMediaURL(url)) return false;
    return /\/bfs\/(?:ai_)?subtitle\//i.test(new URL(url).pathname);
  }
  function metadataURL(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" && parsed.hostname === "api.bilibili.com" && /^\/x\/player\/(?:wbi\/)?v2\/?$/.test(parsed.pathname);
    } catch { return false; }
  }
  function normalizeCues(value) {
    const list = Array.isArray(value) ? value : value?.body;
    if (!Array.isArray(list) || list.length === 0 || list.length > LIMITS.cues) return null;
    const cues = [];
    let textLength = 0;
    for (const entry of list) {
      if (!entry || typeof entry !== "object") continue;
      const from = entry.from, to = entry.to;
      if (typeof from !== "number" || typeof to !== "number" || !Number.isFinite(from) || !Number.isFinite(to) || from < 0 || to <= from || to > 604800) continue;
      const content = cleanText(entry.content);
      if (!content) continue;
      textLength += content.length;
      if (textLength > LIMITS.textChars) return null;
      cues.push({from, to, content});
    }
    if (cues.length === 0) return null;
    cues.sort((a, b) => a.from - b.from || a.to - b.to);
    return cues.filter((cue, index) => !index || cue.from !== cues[index - 1].from || cue.to !== cues[index - 1].to || cue.content !== cues[index - 1].content);
  }
  function cueAt(cues, currentTime) {
    if (!Array.isArray(cues) || !cues.length || !Number.isFinite(currentTime)) return "";
    let low = 0, high = cues.length - 1, match = -1;
    while (low <= high) {
      const middle = (low + high) >>> 1;
      if (cues[middle].from <= currentTime) { match = middle; low = middle + 1; }
      else high = middle - 1;
    }
    // Several subtitles can overlap; checking nearby cues avoids a full scan per heartbeat.
    const active = [];
    for (let index = match; index >= 0 && index >= match - 20; index--) {
      const cue = cues[index];
      if (cue.from <= currentTime && cue.to > currentTime) active.unshift(cue.content);
    }
    return active.join("\n");
  }
  function comparable(text) { return cleanText(text, 6000).replace(/[\s\p{P}\p{S}]/gu, "").toLowerCase(); }
  function captionMatches(caption, cue) {
    const a = comparable(caption), b = comparable(cue);
    return a.length > 1 && b.length > 1 && (a.includes(b) || b.includes(a));
  }
  function languageRank(language = "") {
    if (/^ai-zh(?:-|$)/i.test(language)) return 40;
    if (/^zh(?:-|$)|^zhcn$/i.test(language)) return 30;
    if (/chinese|中文|汉语/i.test(language)) return 20;
    return 0;
  }
  function pickVideoTab(tabs, preferredId) {
    const videos = Array.isArray(tabs) ? tabs.filter(tab => videoPage(tab?.url || "")) : [];
    return videos.find(tab => tab.id === preferredId) || videos.sort((a, b) => Number(!!b.active) - Number(!!a.active) || Number(!!b.audible) - Number(!!a.audible) || (b.lastAccessed || 0) - (a.lastAccessed || 0))[0] || null;
  }
  function validatePlayback(input) {
    if (!input || input.kind !== "playback" || !videoPage(input.pageKey)) return null;
    if (typeof input.currentTime !== "number" || !Number.isFinite(input.currentTime) || input.currentTime < 0 || input.currentTime > 604800) return null;
    if (typeof input.playbackRate !== "number" || !Number.isFinite(input.playbackRate) || input.playbackRate < 0.0625 || input.playbackRate > 16) return null;
    if (typeof input.paused !== "boolean" || typeof input.hasVideo !== "boolean") return null;
    return {kind: "playback", pageKey: pageKey(input.pageKey, new URL(input.pageKey).searchParams.get("cid") || ""), title: cleanText(input.title, 300), currentTime: input.currentTime, playbackRate: input.playbackRate, paused: input.paused, caption: cleanText(input.caption, 4000), captionVisible: input.captionVisible === true, hasVideo: input.hasVideo, duration: Number.isFinite(input.duration) && input.duration >= 0 && input.duration <= 604800 ? input.duration : 0, ended: input.ended === true, sentAt: Date.now()};
  }
  function validateTrack(input) {
    if (!input || input.kind !== "track" || !videoPage(input.pageKey)) return null;
    const cues = normalizeCues(input.cues);
    if (!cues) return null;
    return {kind: "track", pageKey: pageKey(input.pageKey, new URL(input.pageKey).searchParams.get("cid") || ""), title: cleanText(input.title, 300), cues};
  }
  function validateCatalog(input) {
    if (input?.kind !== "catalog" || !videoPage(input.pageKey) || !input.catalog || typeof input.catalog !== "object") return null;
    const catalog = input.catalog;
    const subtitles = (Array.isArray(catalog.subtitles) ? catalog.subtitles : []).slice(0, 64).flatMap(item => {
      if (typeof item?.id !== "string" || !item.id || item.id.length > 256) return [];
      return [{id: cleanText(item.id, 256), label: cleanText(item.label, 100), language: cleanText(item.language, 60), isAI: item.isAI === true}];
    });
    return {kind: "catalog", pageKey: pageKey(input.pageKey, new URL(input.pageKey).searchParams.get("cid") || ""), title: cleanText(input.title, 300), catalog: {title: cleanText(catalog.title, 300), items: mediaItems(catalog.items), subtitles, ...(subtitles.some(item => item.id === catalog.selectedSubtitleID) ? {selectedSubtitleID: catalog.selectedSubtitleID} : {}), subtitleStatus: cleanText(catalog.subtitleStatus, 300)}};
  }
  function validateAccount(input) {
    if (input?.kind !== "account" || !videoPage(input.pageKey) || typeof input.account?.loggedIn !== "boolean") return null;
    const account = input.account;
    const folders = (Array.isArray(account.folders) ? account.folders : []).slice(0, 200).filter(folder => /^\d{1,20}$/.test(String(folder?.id))).map(folder => ({id: String(folder.id), title: cleanText(folder.title, 300), count: Number.isSafeInteger(folder.count) && folder.count >= 0 ? folder.count : 0}));
    return {kind: "account", pageKey: pageKey(input.pageKey), title: cleanText(input.title, 300), account: {loggedIn: account.loggedIn, folders, items: mediaItems(account.items), folderID: cleanText(account.folderID, 30), error: cleanText(account.error, 300)}};
  }
  function preferences(input) {
    if (!input || typeof input !== "object") return null;
    const result = {};
    if (typeof input.autoSubtitle === "boolean") result.autoSubtitle = input.autoSubtitle;
    if (["ai", "human"].includes(input.subtitlePreference)) result.subtitlePreference = input.subtitlePreference;
    if (["sequence", "repeatOne", "stopAfter"].includes(input.playbackMode)) result.playbackMode = input.playbackMode;
    if (typeof input.controlledSourceId === "string" && /^(?:\d{1,20})?$/.test(input.controlledSourceId)) result.controlledSourceId = input.controlledSourceId;
    if (Array.isArray(input.queue)) result.queue = mediaItems(input.queue);
    return Object.keys(result).length ? result : null;
  }
  const RATES = Object.freeze([0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]);
  function validateControl(input, sourceId) {
    if (!input || input.sourceId !== String(sourceId) || !/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(input.id || "")) return null;
    const result = {id: input.id, sourceId: String(sourceId), action: input.action};
    if (["togglePlayback", "previousItem", "nextItem", "enableSubtitles", "resyncSubtitles"].includes(input.action)) return result;
    if (input.action === "setPlaybackRate" && RATES.includes(input.rate)) return {...result, rate: input.rate};
    if (input.action === "seek" && Number.isFinite(input.time) && input.time >= 0 && input.time <= 604800) return {...result, time: input.time};
    if (input.action === "playItem" && videoPage(input.url) && (input.time === undefined || Number.isFinite(input.time) && input.time >= 0 && input.time <= 604800) && (input.rate === undefined || RATES.includes(input.rate))) return {...result, url: pageKey(input.url), ...(input.time === undefined ? {} : {time: input.time}), ...(input.rate === undefined ? {} : {rate: input.rate})};
    if (input.action === "selectSubtitle" && typeof input.subtitleID === "string" && input.subtitleID.length > 0 && input.subtitleID.length <= 300) return {...result, subtitleID: cleanText(input.subtitleID, 300)};
    if (input.action === "loadAccount" && (input.folderID === undefined || ["", "watchlater"].includes(input.folderID) || /^\d{1,20}$/.test(input.folderID))) return {...result, folderID: input.folderID || "watchlater"};
    if (["saveFavorites", "addWatchLater"].includes(input.action) && Array.isArray(input.urls) && input.urls.length > 0 && input.urls.length <= 1000 && input.urls.every(videoPage)) {
      if (input.action === "saveFavorites" && !/^\d{1,20}$/.test(String(input.folderID))) return null;
      return {...result, urls: [...new Set(input.urls.map(url => pageKey(url)))], ...(input.action === "saveFavorites" ? {folderID: String(input.folderID)} : {})};
    }
    return null;
  }
  function adjacentItem(items, currentURL, offset) {
    const list = mediaItems(items), index = list.findIndex(item => item.url === basePageKey(currentURL));
    return index < 0 ? null : list[index + offset] || null;
  }
  globalThis.BiliCaptionCore = Object.freeze({LIMITS, RATES, cleanText, videoPage, pageKey, basePageKey, mediaItems, catalogFromVideo, subtitleURL, metadataURL, normalizeCues, cueAt, captionMatches, languageRank, pickVideoTab, validatePlayback, validateTrack, validateCatalog, validateAccount, preferences, validateControl, adjacentItem});
})();
