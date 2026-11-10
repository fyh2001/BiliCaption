"use strict";
importScripts("core.js", "page-actions.js");
const C = globalThis.BiliCaptionCore;
const ENDPOINT = "http://127.0.0.1:17373";
const TOKEN = "__BILI_CAPTION_BRIDGE_TOKEN__";
let status = {connected: false, error: "请先打开 BiliCaption 菜单栏程序", lastUpdate: 0, tabs: {}};
let lastPersist = 0;
const catalogs = new Map(), preferencesByTab = new Map(), playbackByTab = new Map();
const inFlight = new Map(), completed = new Map(), ending = new Map();
const navigationTasks = new Map();
const restored = (async () => {
  const value = await chrome.storage.local.get("bridgeStatus").catch(() => ({}));
  if (value.bridgeStatus && typeof value.bridgeStatus === "object") status = {...status, ...value.bridgeStatus, connected: false};
  const session = await chrome.storage.session?.get("completedControls").catch(() => ({}));
  for (const [id, result] of Object.entries(session?.completedControls || {}).slice(-100)) completed.set(id, result);
})();
async function request(path, payload) {
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch(`${ENDPOINT}${path}`, {
      method: payload ? "POST" : "GET",
      headers: {"X-Bili-Token": TOKEN, ...(payload ? {"Content-Type": "application/json"} : {})},
      body: payload ? JSON.stringify(payload) : undefined,
      credentials: "omit", cache: "no-store", signal: controller.signal
    });
    if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ? "配对密钥不匹配，请使用同一套安装包" : `本机程序返回 ${response.status}`);
    const reply = await response.json();
    if (reply.ok !== true) throw new Error("本机程序未确认同步，请重启 BiliCaption");
    return reply;
  } finally { clearTimeout(timeout); }
}
function humanError(error) {
  return /^配对|^本机/.test(error?.message || "") ? error.message : "未连接菜单栏程序，请先打开 BiliCaption";
}
function persist(force = false) {
  if (!force && Date.now() - lastPersist < 3000) return;
  lastPersist = Date.now();
  void chrome.storage.local.set({bridgeStatus: status});
}
function trustedVideoSender(sender) {
  return !!sender.tab && Number.isInteger(sender.tab.id) && C.videoPage(sender.url || sender.tab.url || "") && (!sender.origin || sender.origin === "https://www.bilibili.com");
}
function itemsFor(sourceId, currentURL) {
  const queue = preferencesByTab.get(sourceId)?.queue || [];
  if (queue.some(item => item.url === C.basePageKey(currentURL))) return queue;
  return catalogs.get(sourceId)?.items || [];
}
async function navigate(tabId, command) {
  const plan = await withNavigationLock(tabId, async () => {
    const key = `resume:${tabId}`, saved = (await chrome.storage.session.get(key))[key];
    const pending = saved && Date.now() - saved.createdAt <= 120000 ? saved : null;
    const current = playbackByTab.get(String(tabId)), currentURL = pending?.url || current?.pageKey || "";
    let url = C.pageKey(command.url);
    if (["previousItem", "nextItem"].includes(command.action)) {
      const item = C.adjacentItem(itemsFor(String(tabId), currentURL), currentURL, command.action === "nextItem" ? 1 : -1);
      if (!item) throw new Error(command.action === "nextItem" ? "已经是最后一集" : "已经是第一集");
      url = item.url;
    }
    if (!url) throw new Error("只能打开 B 站视频页");
    const resume = {id: crypto.randomUUID(), url, time: command.time || 0, rate: command.rate || pending?.rate || current?.playbackRate || 1, createdAt: Date.now()};
    // An in-flight document replacement must be superseded by tabs.update,
    // even if the destination happens to equal the old playback snapshot.
    if (!pending && current && C.basePageKey(current.pageKey) === url) return {localResume: resume};
    await chrome.storage.session.set({[key]: resume});
    try { await chrome.tabs.update(tabId, {url}); }
    catch (error) { await chrome.storage.session.remove(key); throw error; }
    return {ok: true};
  });
  // Do not hold the navigation lock while the content script acknowledges its
  // resume: that acknowledgement itself needs the same lock.
  if (plan.localResume) return chrome.tabs.sendMessage(tabId, {type: "resume", resume: plan.localResume});
  return plan;
}
async function withNavigationLock(tabId, operation) {
  const prior = navigationTasks.get(tabId) || Promise.resolve();
  const task = prior.catch(() => {}).then(operation);
  navigationTasks.set(tabId, task);
  try { return await task; }
  finally { if (navigationTasks.get(tabId) === task) navigationTasks.delete(tabId); }
}
async function executeControl(command, tabId) {
  const sourceId = String(tabId), playback = playbackByTab.get(sourceId);
  if (command.action === "playItem") return navigate(tabId, command);
  if (["previousItem", "nextItem"].includes(command.action)) {
    return navigate(tabId, command);
  }
  if (["loadAccount", "saveFavorites", "addWatchLater"].includes(command.action)) {
    const result = (await chrome.scripting.executeScript({target: {tabId}, world: "MAIN", func: biliCaptionAccountTask, args: [command]}))?.[0]?.result;
    if (!result || typeof result.ok !== "boolean") throw new Error("无法连接 B 站账号，请刷新视频页");
    const destination = playbackByTab.get(sourceId) || playback;
    if (result.account && destination) {
      // Account lists are independent of the video. An SPA episode change can
      // finish while pagination runs, so attach the result to the current page.
      const payload = C.validateAccount({kind: "account", pageKey: destination.pageKey, title: destination.title, account: result.account});
      if (payload) await request("/update", {...payload, sourceId});
    }
    return {ok: result.ok, ...(result.error ? {error: C.cleanText(result.error, 300)} : {})};
  }
  return chrome.tabs.sendMessage(tabId, {type: "control", ...command, controlId: command.id});
}
async function dispatchControl(input, sourceId, tabId) {
  if (!input || input.sourceId !== sourceId || !/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(input.id || "")) return null;
  const command = C.validateControl(input, sourceId);
  let result = completed.get(input.id);
  if (!result) {
    if (inFlight.has(input.id)) return {ok: true, pending: true};
    if (!inFlight.has(input.id)) {
      const task = (async () => {
        let outcome;
        try {
          if (!command) throw new Error("无效或不支持的播放命令");
          outcome = await executeControl(command, tabId);
          if (outcome?.ok !== true) throw new Error(outcome?.error || "播放器没有完成操作");
          outcome = {ok: true};
        } catch (error) { outcome = {ok: false, error: C.cleanText(error?.message, 300) || "操作失败"}; }
        completed.set(input.id, outcome);
        if (completed.size > 100) completed.delete(completed.keys().next().value);
        await chrome.storage.session?.set({completedControls: Object.fromEntries(completed)}).catch(() => {});
        return outcome;
      })();
      inFlight.set(input.id, task);
      void task.finally(() => inFlight.delete(input.id));
    }
    result = await inFlight.get(input.id);
  }
  // Both success and failure consume the command. A failed POST is retried on
  // the next delivery using the cached result, never by repeating the action.
  try { await request("/control/result", {id: input.id, ...result}); } catch { /* Native retry will deliver the cached result. */ }
  return result;
}
async function relay(payload, sender) {
  await restored;
  if (!trustedVideoSender(sender)) return {ok: false, error: "仅允许 B 站视频页面同步"};
  const validators = {track: C.validateTrack, playback: C.validatePlayback, catalog: C.validateCatalog};
  const validated = Object.hasOwn(validators, payload?.kind || "") ? validators[payload.kind](payload) : null;
  if (!validated) return {ok: false, error: "字幕或播放数据无效"};
  const sourceId = String(sender.tab.id), previous = status.tabs[sourceId];
  const prior = previous?.pageKey === validated.pageKey ? previous : {};
  const detail = validated.kind === "playback" ? {paused: validated.paused, hasVideo: validated.hasVideo, hasCaption: !!validated.caption} : validated.kind === "track" ? {cueCount: validated.cues.length, hasTrack: true} : {episodeCount: validated.catalog.items.length, subtitleCount: validated.catalog.subtitles.length, subtitleStatus: validated.catalog.subtitleStatus};
  status.tabs[sourceId] = {...prior, title: validated.title, pageKey: validated.pageKey, lastUpdate: Date.now(), ...detail};
  if (validated.kind === "playback") playbackByTab.set(sourceId, validated);
  if (validated.kind === "catalog") catalogs.set(sourceId, validated.catalog);
  if (Object.keys(status.tabs).length > 30) {
    const oldest = Object.keys(status.tabs).sort((a, b) => status.tabs[a].lastUpdate - status.tabs[b].lastUpdate)[0];
    delete status.tabs[oldest];
  }
  try {
    const reply = await request("/update", {...validated, sourceId});
    const prefs = C.preferences(reply.preferences || reply);
    if (prefs) preferencesByTab.set(sourceId, {...preferencesByTab.get(sourceId), ...prefs});
    // Account pagination/batch writes can take seconds. Keep heartbeats flowing
    // while the command runs; later deliveries reuse its in-flight promise.
    void dispatchControl(reply.control, sourceId, sender.tab.id).catch(() => {});
    status.connected = true; status.error = ""; status.lastUpdate = Date.now(); persist();
    return {ok: true, needsTrack: reply.needsTrack === true, sourceId, preferences: preferencesByTab.get(sourceId) || null};
  } catch (error) {
    status.connected = false; status.error = humanError(error); persist();
    return {ok: false, error: status.error};
  }
}
async function handleEnded(sender, pageKey) {
  if (!trustedVideoSender(sender)) return {ok: false};
  const sourceId = String(sender.tab.id), playback = playbackByTab.get(sourceId), prefs = preferencesByTab.get(sourceId);
  if (!prefs || prefs.controlledSourceId !== sourceId || !playback || C.basePageKey(pageKey) !== C.basePageKey(playback.pageKey)) return {ok: false};
  const key = `${sourceId}:${C.basePageKey(pageKey)}`;
  if (ending.has(key)) return ending.get(key);
  const task = (async () => {
    if (prefs.playbackMode === "repeatOne") return navigate(sender.tab.id, {url: pageKey, time: 0, rate: playback.playbackRate});
    if (prefs.playbackMode === "sequence") {
      const item = C.adjacentItem(itemsFor(sourceId, pageKey), pageKey, 1);
      if (item) return navigate(sender.tab.id, item);
    }
    return {ok: true, stopped: true};
  })();
  ending.set(key, task);
  void task.finally(() => { setTimeout(() => ending.delete(key), 1500); });
  return task;
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type === "relay") {
    void relay(message.payload, sender).then(respond).catch(() => respond({ok: false, error: "同步失败"})); return true;
  }
  if (message?.type === "ended" && trustedVideoSender(sender)) {
    void handleEnded(sender, message.pageKey).then(respond).catch(() => respond({ok: false, error: "无法切换下一集"})); return true;
  }
  if (message?.type === "resume" && trustedVideoSender(sender)) {
    void (async () => {
      const key = `resume:${sender.tab.id}`, value = await chrome.storage.session.get(key), resume = value[key];
      if (!resume) return {ok: true};
      if (Date.now() - resume.createdAt > 120000) { await chrome.storage.session.remove(key); return {ok: true}; }
      if (C.basePageKey(resume.url) !== C.basePageKey(message.pageKey)) return {ok: true};
      return {ok: true, resume};
    })().then(respond).catch(() => respond({ok: false})); return true;
  }
  if (message?.type === "resumed" && trustedVideoSender(sender)) {
    void withNavigationLock(sender.tab.id, async () => {
      const key = `resume:${sender.tab.id}`, resume = (await chrome.storage.session.get(key))[key];
      if (resume && resume.id === message.resumeID && C.basePageKey(resume.url) === C.basePageKey(message.pageKey)) await chrome.storage.session.remove(key);
      return {ok: true};
    }).then(respond).catch(() => respond({ok: false})); return true;
  }
  if (sender.url !== chrome.runtime.getURL("popup.html")) return;
  if (message?.type === "status") {
    void (async () => {
      await restored;
      try { await request("/health"); status.connected = true; status.error = ""; }
      catch (error) { status.connected = false; status.error = humanError(error); }
      persist(true);
      return {ok: true, connected: status.connected, error: status.error, tab: status.tabs[String(message.tabId)] || null};
    })().then(respond).catch(() => respond({ok: false})); return true;
  }
});
chrome.tabs.onRemoved.addListener(tabId => {
  const id = String(tabId);
  delete status.tabs[id]; catalogs.delete(id); preferencesByTab.delete(id); playbackByTab.delete(id);
  void chrome.storage.session?.remove(`resume:${tabId}`); persist(true);
});
