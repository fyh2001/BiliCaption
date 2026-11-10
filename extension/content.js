(() => {
  "use strict";
  const C = globalThis.BiliCaptionCore;
  if (!C || globalThis.__biliCaptionContentV1) return;
  globalThis.__biliCaptionContentV1 = true;
  const MARKER = "bili-caption-menu-v1";
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, "0")).join("");
  let baseKey = C.basePageKey(location.href), currentKey = baseKey, video = null;
  let selectedURL = "", selectedTrack = null, trackPending = false;
  let playbackBusy = false, playbackAgain = false, trackBusy = false, connected = false;
  let lastBaseTitle = "", lastHeartbeat = 0, ready = false;
  const handledControls = new Map(), inFlightControls = new Map();
  let catalog = {title: "", items: [], subtitles: [], subtitleStatus: "正在检查字幕"};
  let prefs = {autoSubtitle: false, subtitlePreference: "ai", playbackMode: "sequence"};
  let nativePreferences = false, controlsPlayback = false, manualSubtitleID = "", catalogPending = false, catalogBusy = false, lastCatalog = 0;
  let pendingResume = null, resumeBusy = false, resumePromise = null, resumeQueried = "", autoEnabledKey = "";
  const candidates = new Map();
  const mediaEvents = ["play", "playing", "pause", "ended", "timeupdate", "ratechange", "seeking", "seeked", "waiting", "stalled", "loadedmetadata", "durationchange", "emptied"];
  function title() { return C.cleanText(document.title.replace(/[_\-\s]*哔哩哔哩.*$/, ""), 300) || "B 站视频"; }
  function post(type, payload = {}) { window.postMessage({marker: MARKER, direction: "content", nonce, type, ...payload}, location.origin); }
  function reset(key) {
    currentKey = key;
    selectedURL = "";
    selectedTrack = null;
    trackPending = false;
    candidates.clear();
    catalog = {title: "", items: [], subtitles: [], subtitleStatus: "正在检查字幕"};
    manualSubtitleID = ""; catalogPending = false; autoEnabledKey = "";
    connected = false;
  }
  function refreshIdentity() {
    const next = C.basePageKey(location.href);
    if (next !== baseKey) { baseKey = next; reset(next); post("resync"); }
    return currentKey;
  }
  function findVideo() {
    const preferred = document.querySelector(".bpx-player-video-wrap video, .bilibili-player-video-wrap video");
    if (preferred) return preferred;
    const videos = [...document.querySelectorAll("video")];
    return videos.find(item => !item.paused && !item.ended) || videos[0] || null;
  }
  function attachVideo() {
    const next = findVideo();
    if (next === video) return;
    if (video) mediaEvents.forEach(event => video.removeEventListener(event, mediaChanged));
    video = next;
    if (video) mediaEvents.forEach(event => video.addEventListener(event, mediaChanged));
  }
  function mediaChanged() { void applyResume(); void sendPlayback(true); }
  function desiredSubtitle() {
    if (manualSubtitleID) return catalog.subtitles.find(track => track.id === manualSubtitleID);
    if (!prefs.autoSubtitle) return null;
    const rank = track => C.languageRank(track.language) + (track.isAI === (prefs.subtitlePreference === "ai") ? 30 : 0);
    return [...catalog.subtitles].sort((a, b) => rank(b) - rank(a))[0];
  }
  function enableSubtitleUI(force = false) {
    const target = desiredSubtitle();
    if (!target) return false;
    const key = `${currentKey}:${target.id}`;
    if (!force && autoEnabledKey === key) return true;
    // Only the main subtitle language list; never select the translation track
    // or click the CC close switch. The player's language names vary by build.
    const elements = document.querySelectorAll(".bpx-player-ctrl-subtitle-major-inner .bpx-player-ctrl-subtitle-language-item[data-lan], .bilibili-player-video-subtitle-menu [data-lan]");
    const option = [...elements].find(element => element.getAttribute?.("data-lan") === target.language);
    if (!option || typeof option.click !== "function") return false;
    option.click();
    autoEnabledKey = key;
    return true;
  }
  function applyPreferences(value, sourceId) {
    const next = C.preferences(value);
    if (!next) return;
    nativePreferences = true;
    controlsPlayback = !!sourceId && next.controlledSourceId === sourceId;
    const changed = next.subtitlePreference && next.subtitlePreference !== prefs.subtitlePreference;
    const enabled = next.autoSubtitle === true && !prefs.autoSubtitle;
    prefs = {...prefs, ...next};
    if (changed) { manualSubtitleID = ""; autoEnabledKey = ""; post("subtitlePreference", {preference: prefs.subtitlePreference}); }
    if (changed || enabled) { selectTrack(captionDOM()); catalogPending = true; }
    if (prefs.autoSubtitle) enableSubtitleUI();
  }
  async function sendCatalog(force = false) {
    if (catalogBusy || !currentKey || !force && !catalogPending && Date.now() - lastCatalog < 15000) return;
    const selected = [...catalog.subtitles].find(item => item.id === selectedTrack?.id || item.language === selectedTrack?.language);
    const payload = C.validateCatalog({kind: "catalog", pageKey: currentKey, title: title(), catalog: {...catalog, ...(selected ? {selectedSubtitleID: selected.id} : {})}});
    if (!payload) return;
    catalogBusy = true;
    const result = await messageWorker(payload);
    catalogBusy = false; lastCatalog = Date.now(); catalogPending = !result?.ok;
    if (result?.ok) applyPreferences(result.preferences, result.sourceId);
  }
  async function requestResume() {
    if (resumeQueried === baseKey || !baseKey) return;
    resumeQueried = baseKey;
    try {
      const result = await chrome.runtime.sendMessage({type: "resume", pageKey: currentKey});
      if (result?.resume) { pendingResume = result.resume; void applyResume(); }
    } catch { /* A normal visit has no resume request. */ }
  }
  async function applyResume() {
    if (resumeBusy) { if (resumePromise) await resumePromise; return; }
    if (!pendingResume || !video || video.readyState < 1) return;
    resumeBusy = true;
    resumePromise = (async () => {
      while (pendingResume && video && video.readyState >= 1) {
        const resume = pendingResume;
        if (C.basePageKey(resume.url) !== baseKey || !Number.isFinite(resume.time) || resume.time < 0 || !C.RATES.includes(resume.rate)) { pendingResume = null; break; }
        try {
          video.playbackRate = resume.rate;
          video.currentTime = Number.isFinite(video.duration) ? Math.min(resume.time, Math.max(0, video.duration - 0.25)) : resume.time;
          await video.play();
          // A newer request may have arrived while play() was pending.
          if (pendingResume === resume) pendingResume = null;
          await chrome.runtime.sendMessage({type: "resumed", resumeID: resume.id, pageKey: resume.url});
        } catch { break; /* Metadata/autoplay may not yet permit playback. */ }
      }
    })();
    try { await resumePromise; }
    finally { resumeBusy = false; resumePromise = null; }
  }
  function captionDOM() {
    const nodes = document.querySelectorAll('.bili-subtitle-x-subtitle-panel-text[data-type="0"], .bpx-player-subtitle-panel-text, .bilibili-player-video-subtitle .subtitle-item-text');
    const lines = [];
    for (const element of nodes) {
      if (element.getAttribute?.("data-type") === "1") continue;
      if (!element.getClientRects().length) continue;
      let visible = true, ancestor = element;
      for (let depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.parentElement) {
        const style = getComputedStyle(ancestor);
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) { visible = false; break; }
      }
      if (!visible) continue;
      const text = C.cleanText(element.textContent, 4000);
      if (text && !lines.includes(text)) lines.push(text);
    }
    return C.cleanText(lines.join("\n"), 4000);
  }
  function selectTrack(caption) {
    if (!candidates.size || !currentKey) return;
    const time = Number.isFinite(video?.currentTime) ? video.currentTime : 0;
    let winner = null, bestScore = -1;
    const desired = desiredSubtitle();
    for (const candidate of candidates.values()) {
      if (candidate.pageKey !== currentKey) continue;
      const match = !document.hidden && C.captionMatches(caption, C.cueAt(candidate.cues, time));
      const requested = desired && (candidate.id === desired.id || candidate.language === desired.language);
      const preferred = /^ai-/i.test(candidate.language) === (prefs.subtitlePreference === "ai");
      const score = (requested ? 2000 : 0) + (match ? 1000 : 0) + C.languageRank(candidate.language) + (preferred ? 30 : 0) + (candidate.url === selectedURL ? 10 : 0);
      if (score > bestScore) { winner = candidate; bestScore = score; }
    }
    if (winner && (winner.url !== selectedURL || winner !== selectedTrack)) {
      selectedURL = winner.url;
      selectedTrack = winner;
      trackPending = true;
      catalogPending = true;
      void sendTrack();
    }
  }
  async function messageWorker(payload) {
    try { return await chrome.runtime.sendMessage({type: "relay", payload}); }
    catch { return {ok: false, error: "扩展已更新，请刷新 B 站页面"}; }
  }
  async function sendTrack() {
    if (trackBusy || !selectedTrack || selectedTrack.pageKey !== currentKey) return;
    const track = selectedTrack;
    trackBusy = true;
    const result = await messageWorker({kind: "track", pageKey: currentKey, title: title(), cues: track.cues});
    trackBusy = false;
    if (selectedTrack === track && track.pageKey === currentKey) trackPending = !result?.ok;
    if (selectedTrack !== track && selectedTrack) void sendTrack();
  }
  async function sendPlayback(urgent = false) {
    refreshIdentity();
    if (!currentKey) return;
    attachVideo();
    void requestResume();
    void applyResume();
    if (prefs.autoSubtitle) enableSubtitleUI();
    const now = Date.now();
    if (!urgent && now - lastHeartbeat < 900) return;
    if (playbackBusy) { if (urgent) playbackAgain = true; return; }
    const caption = captionDOM();
    selectTrack(caption);
    const hasVideo = !!video;
    const payload = {
      kind: "playback", pageKey: currentKey, title: title(),
      currentTime: Number.isFinite(video?.currentTime) ? video.currentTime : 0,
      paused: !video || video.paused || video.ended || video.seeking || video.readyState < 3,
      playbackRate: Number.isFinite(video?.playbackRate) && video.playbackRate > 0 ? video.playbackRate : 1,
      duration: Number.isFinite(video?.duration) ? video.duration : 0, ended: video?.ended === true,
      caption, captionVisible: !!caption && !document.hidden, hasVideo, sentAt: now
    };
    lastHeartbeat = now;
    lastBaseTitle = payload.title;
    playbackBusy = true;
    const response = await messageWorker(payload);
    playbackBusy = false;
    if (payload.pageKey === currentKey) {
      const wasConnected = connected;
      connected = response?.ok === true;
      if (connected) applyPreferences(response.preferences, response.sourceId);
      if (connected && (!wasConnected || trackPending || response.needsTrack === true)) void sendTrack();
      if (connected) void sendCatalog(!wasConnected);
    }
    if (playbackAgain) { playbackAgain = false; void sendPlayback(true); }
  }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin) return;
    const message = event.data;
    if (!message || message.marker !== MARKER || message.direction !== "page" || message.nonce !== nonce) return;
    refreshIdentity();
    if (!C.videoPage(message.pageKey) || C.basePageKey(message.pageKey) !== baseKey) return;
    const cid = new URL(message.pageKey).searchParams.get("cid") || "";
    const key = C.pageKey(message.pageKey, cid);
    if (message.type === "ready" || message.type === "identity") {
      ready = true;
      if (key !== currentKey) reset(key);
      void sendPlayback(true);
    } else if (message.type === "track") {
      if (!C.subtitleURL(message.url)) return;
      const cues = C.normalizeCues(message.cues);
      if (!cues) return;
      if (key !== currentKey) reset(key);
      const track = {url: message.url, id: C.cleanText(message.id, 256), pageKey: key, language: C.cleanText(message.language, 60), cues};
      candidates.set(track.url, track);
      if (candidates.size > 6) candidates.delete(candidates.keys().next().value);
      attachVideo();
      selectTrack(captionDOM());
      void sendPlayback(true);
    } else if (message.type === "catalog") {
      const validated = C.validateCatalog({kind: "catalog", pageKey: key, title: title(), catalog: message.catalog});
      if (!validated) return;
      if (key !== currentKey) reset(key);
      catalog = validated.catalog;
      catalogPending = true;
      const desired = desiredSubtitle();
      if (desired) post("selectSubtitle", {subtitleID: desired.id});
      if (prefs.autoSubtitle) enableSubtitleUI();
      selectTrack(captionDOM());
      void sendCatalog(true);
    }
  });
  async function performControl(message) {
    const command = C.validateControl({...message, id: message.controlId, sourceId: "content"}, "content");
    if (!command) return {ok: false, error: "无效的播放命令"};
    attachVideo();
    if (["selectSubtitle", "enableSubtitles", "resyncSubtitles"].includes(command.action)) {
      if (command.action === "resyncSubtitles") {
        post("resync"); trackPending = !!selectedTrack; catalogPending = true;
        void sendTrack(); void sendCatalog(true);
        return {ok: true};
      }
      if (command.action === "selectSubtitle") {
        if (!catalog.subtitles.some(track => track.id === command.subtitleID)) return {ok: false, error: "该字幕轨道已失效，请重新同步"};
        manualSubtitleID = command.subtitleID;
      } else {
        prefs.autoSubtitle = true;
        if (!catalog.subtitles.length) { post("resync"); return {ok: false, error: catalog.subtitleStatus || "B 站尚未提供字幕"}; }
      }
      const target = desiredSubtitle();
      if (!target) return {ok: false, error: "B 站尚未提供字幕"};
      post("selectSubtitle", {subtitleID: target.id});
      enableSubtitleUI(true); selectTrack(captionDOM()); catalogPending = true;
      void sendCatalog(true);
      return {ok: true};
    }
    if (!video) return {ok: false, error: "没有可控制的视频"};
    if (command.action === "togglePlayback") {
      if (video.paused) await video.play(); else video.pause();
    } else if (command.action === "setPlaybackRate") video.playbackRate = command.rate;
    else if (command.action === "seek") video.currentTime = Number.isFinite(video.duration) ? Math.min(command.time, Math.max(0, video.duration - 0.25)) : command.time;
    else return {ok: false, error: "不支持的播放器命令"};
    void sendPlayback(true);
    return {ok: true, paused: video.paused, playbackRate: video.playbackRate};
  }
  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "resync") {
      post("resync"); trackPending = !!selectedTrack; catalogPending = true;
      void sendTrack(); void sendCatalog(true); void sendPlayback(true);
      respond({ok: true, hasVideo: !!video, hasTrack: !!selectedTrack});
    } else if (message?.type === "resume") {
      pendingResume = message.resume; attachVideo();
      void applyResume().then(() => respond({ok: !pendingResume, ...(pendingResume ? {error: "视频尚未就绪，请稍后重试"} : {})}));
      return true;
    } else if (message?.type === "control") {
      const id = C.cleanText(message.controlId, 64);
      if (handledControls.has(id)) { respond({...handledControls.get(id), duplicate: true}); return; }
      if (!inFlightControls.has(id)) {
        const task = performControl(message).catch(error => ({ok: false, error: C.cleanText(error?.message, 200) || "无法控制播放"})).then(result => {
          handledControls.set(id, result);
          if (handledControls.size > 100) handledControls.delete(handledControls.keys().next().value);
          inFlightControls.delete(id);
          return result;
        });
        inFlightControls.set(id, task);
      }
      void inFlightControls.get(id).then(respond);
      return true;
    }
  });
  // Capture the native ended event before Bilibili's own auto-next listener.
  // Only take over after the native app has supplied an explicit playback mode.
  document.addEventListener("ended", event => {
    attachVideo();
    if (!nativePreferences || !controlsPlayback || !connected || event.target !== video) return;
    event.stopImmediatePropagation();
    video.pause();
    void sendPlayback(true);
    void chrome.runtime.sendMessage({type: "ended", pageKey: currentKey}).catch(() => {});
  }, true);
  document.addEventListener("visibilitychange", () => { post("resync"); void sendPlayback(true); });
  window.addEventListener("pageshow", () => { post("hello"); void sendPlayback(true); });
  window.addEventListener("popstate", () => { refreshIdentity(); void sendPlayback(true); });
  post("hello");
  const timer = setInterval(() => {
    if (!ready) post("hello");
    void sendPlayback(lastBaseTitle !== title());
  }, 1000);
  window.addEventListener("pagehide", event => {
    // Keep the BFCache document's timer; its pageshow heartbeat restores sync.
    if (!event.persisted) clearInterval(timer);
  });
})();
