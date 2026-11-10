"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const directory = process.env.BILI_CAPTION_EXTENSION_DIR
  ? path.resolve(process.env.BILI_CAPTION_EXTENSION_DIR)
  : path.resolve(__dirname, "..");
const source = name => fs.readFileSync(path.join(directory, name), "utf8");
const PAGE = "https://www.bilibili.com/video/BV1jV4y1a7ao/?p=2&t=50&spm_id_from=foo";
const SUBTITLE = "https://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/abc.json?auth_key=example";
function core() {
  const context = vm.createContext({URL, URLSearchParams});
  vm.runInContext(source("core.js"), context);
  return context.BiliCaptionCore;
}
const plain = value => JSON.parse(JSON.stringify(value));
test("document_start scripts use unique, fresh bundles in each execution world", () => {
  const manifest = JSON.parse(source("manifest.json"));
  assert.deepEqual(manifest.content_scripts[0].js, ["page-bundle.js"]);
  assert.deepEqual(manifest.content_scripts[1].js, ["content-bundle.js"]);
  assert.equal(manifest.content_scripts[0].world, "MAIN");
  assert.equal(manifest.content_scripts[1].world, "ISOLATED");
  assert.equal(source("page-bundle.js"), [source("core.js"), source("page-hook.js")].join("\n"));
  assert.equal(source("content-bundle.js"), [source("core.js"), source("content.js")].join("\n"));
});
test("video identity retains part/CID and removes tracking/time", () => {
  const C = core();
  assert.equal(C.pageKey(PAGE, "123456"), "https://www.bilibili.com/video/BV1jV4y1a7ao/?p=2&cid=123456");
  assert.equal(C.basePageKey(PAGE), "https://www.bilibili.com/video/BV1jV4y1a7ao/?p=2");
  assert.equal(C.pageKey(PAGE.replace("p=2", "p=-1")), "https://www.bilibili.com/video/BV1jV4y1a7ao/?p=1");
  assert.equal(C.pageKey("https://evil.example/video/BV1jV4y1a7ao/"), "");
  assert.equal(C.videoPage("https://www.bilibili.com.evil.example/video/BV1jV4y1a7ao/"), false);
});
test("subtitle allow-list cannot be pointed at arbitrary URLs or media", () => {
  const C = core();
  assert.equal(C.subtitleURL(SUBTITLE), true);
  assert.equal(C.subtitleURL("https://i0.hdslb.com/bfs/subtitle/abc.json"), true);
  assert.equal(C.subtitleURL("https://evil.example/bfs/ai_subtitle/prod/abc.json"), false);
  assert.equal(C.subtitleURL("https://foo.hdslb.com.evil.example/bfs/subtitle/abc.json"), false);
  assert.equal(C.subtitleURL("https://foo.hdslb.com/upgcxcode/audio.m4s"), false);
  assert.equal(C.subtitleURL("http://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/abc.json"), false);
  assert.equal(C.metadataURL("https://api.bilibili.com/x/player/wbi/v2?cid=1"), true);
});
test("cue parsing sorts/deduplicates and removes invalid ranges/control characters", () => {
  const C = core();
  const cues = C.normalizeCues({body: [
    {from: 2, to: 4, content: " 第二句\u0000 "},
    {from: 0, to: 2, content: "第一句"},
    {from: 2, to: 4, content: "第二句"},
    {from: -1, to: 2, content: "invalid"},
    {from: 2, to: 2, content: "zero duration"},
    {from: "0", to: 1, content: "not numeric"},
    {from: 3, to: Infinity, content: "invalid"},
    {from: 0, to: 1, content: ""}
  ]});
  assert.deepEqual(plain(cues), [{from: 0, to: 2, content: "第一句"}, {from: 2, to: 4, content: "第二句"}]);
  assert.equal(C.cueAt(cues, 0), "第一句");
  assert.equal(C.cueAt(cues, 2), "第二句");
  assert.equal(C.cueAt(cues, 4), "");
});
test("cue parser bounds text and track size", () => {
  const C = core();
  assert.equal(C.normalizeCues([]), null);
  assert.equal(C.normalizeCues(Array(50001).fill({from: 0, to: 1, content: "x"})), null);
  assert.equal(C.normalizeCues([{from: 0, to: 1, content: "x".repeat(4000)}])[0].content.length, 2000);
  assert.equal(C.normalizeCues(Array.from({length: 1001}, (_, i) => ({from: i, to: i + 1, content: "x".repeat(2000)}))), null);
});
test("caption matching/language ranking supports Chinese vs secondary translation", () => {
  const C = core();
  assert.equal(C.captionMatches("今天，出发了！\nToday, we left.", "今天出发了"), true);
  assert.equal(C.captionMatches("", "今天"), false);
  assert.equal(C.captionMatches("a", "a"), false);
  assert.ok(C.languageRank("ai-zh") > C.languageRank("ai-en"));
  assert.ok(C.languageRank("zh-CN") > C.languageRank("en"));
});
test("Arc popup lookup ignores extension-window tabs and picks a Bilibili video", () => {
  const C = core();
  const tabs = [
    {id: 1, url: "chrome-extension://test/popup.html", active: true},
    {id: 2, url: PAGE, active: false, audible: false, lastAccessed: 20},
    {id: 3, url: PAGE.replace("p=2", "p=3"), active: false, audible: true, lastAccessed: 10},
    {id: 4, url: PAGE.replace("p=2", "p=4"), active: true, audible: false, lastAccessed: 30}
  ];
  assert.equal(C.pickVideoTab(tabs).id, 4);
  assert.equal(C.pickVideoTab(tabs, 2).id, 2);
  assert.equal(C.pickVideoTab(tabs.filter(tab => !tab.active)).id, 3);
  assert.equal(C.pickVideoTab([tabs[0]]), null);
});
test("playback protocol rejects non-finite/injected input and keeps bounded text", () => {
  const C = core();
  const valid = {kind: "playback", pageKey: C.pageKey(PAGE, "123"), title: "小说", currentTime: 3.5, paused: true, playbackRate: 2, hasVideo: true, caption: "第一句", captionVisible: true};
  assert.equal(C.validatePlayback(valid).pageKey, valid.pageKey);
  assert.equal(C.validatePlayback({...valid, currentTime: NaN}), null);
  assert.equal(C.validatePlayback({...valid, playbackRate: 0}), null);
  assert.equal(C.validatePlayback({...valid, pageKey: "file:///etc/passwd"}), null);
  assert.equal(C.validatePlayback({...valid, paused: "false"}), null);
  assert.equal(C.validatePlayback({...valid, title: "x".repeat(1000)}).title.length, 300);
});
function hookEnvironment(responseFor) {
  const posts = [], requests = [], messages = [], timers = [], resources = [];
  const window = {fetch: async (url, options) => {
    requests.push({url, options});
    const value = responseFor?.(url, options) || (url.includes("/x/player/") ? {data: {cid: 42, bvid: "BV1jV4y1a7ao", subtitle: {subtitles: [{lan: "ai-zh", subtitle_url: SUBTITLE}]}}} : {body: [{from: 0, to: 4, content: "测试字幕"}]});
    return new Response(JSON.stringify(value), {status: 200});
  }, postMessage: data => posts.push(data), addEventListener: (name, fn) => { if (name === "message") messages.push(fn); }};
  window.__INITIAL_STATE__ = {videoData: {bvid: "BV1jV4y1a7ao", aid: 123, title: "测试小说", pages: [{page: 1, cid: 41, part: "一"}, {page: 2, cid: 42, part: "二"}]}};
  class XHR {open() {} send() {} addEventListener() {}}
  class Observer {constructor(callback) {this.callback = callback;} observe() {}}
  const context = vm.createContext({URL, URLSearchParams, Response, window, location: new URL(PAGE), XMLHttpRequest: XHR, PerformanceObserver: Observer, performance: {getEntriesByType: () => resources}, setTimeout: fn => {timers.push(fn); return timers.length;}});
  vm.runInContext(source("page-bundle.js"), context);
  function emit(data, origin = "https://www.bilibili.com", eventSource = window) { for (const fn of messages) fn({data, origin, source: eventSource}); }
  return {context, window, posts, requests, emit, timers, resources};
}
const flush = () => new Promise(resolve => setTimeout(resolve, 10));
test("MAIN hook captures player-requested AI JSON with no token in page messages", async () => {
  const env = hookEnvironment();
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "a".repeat(32)});
  await env.window.fetch("https://api.bilibili.com/x/player/wbi/v2?cid=42&bvid=BV1jV4y1a7ao");
  await flush();
  await env.window.fetch(SUBTITLE);
  await flush();
  const track = env.posts.find(message => message.type === "track");
  assert.ok(track);
  assert.equal(track.language, "ai-zh");
  assert.match(track.pageKey, /cid=42/);
  assert.equal(track.cues[0].content, "测试字幕");
  assert.ok(env.requests.some(request => request.url === SUBTITLE && request.options?.credentials === "omit"), "preferred subtitle is proactively loaded anonymously");
  assert.ok(env.requests.every(request => /\/x\/(?:player\/|web-interface\/view)|\/bfs\/ai_subtitle\//.test(request.url)), "never requests audio/video media");
  assert.equal(JSON.stringify(env.posts).includes("74625a77"), false);
});
test("MAIN bridge ignores cross-origin/window messages", async () => {
  const env = hookEnvironment();
  const hello = {marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "a".repeat(32)};
  env.emit(hello, "https://evil.example");
  env.emit(hello, "https://www.bilibili.com", {});
  await env.window.fetch(SUBTITLE);
  await flush();
  assert.equal(env.posts.length, 0);
  env.emit(hello);
  await flush();
  assert.equal(env.posts.some(message => message.type === "track"), true);
});
function contentEnvironment() {
  const relays = [], posts = [], eventHandlers = {}, intervals = [], workerHandlers = [], workerMessages = [], documentHandlers = {};
  const video = {paused: false, ended: false, seeking: false, readyState: 4, currentTime: 0, playbackRate: 1, duration: 300, pause() {this.paused = true;}, async play() {this.paused = false;}, addEventListener: (name, fn) => {eventHandlers[name] = fn;}, removeEventListener() {}};
  const element = {textContent: "测试字幕", getClientRects: () => [{}], parentElement: null};
  const document = {title: "测试小说_哔哩哔哩_bilibili", hidden: false, querySelector: () => video, querySelectorAll: selector => selector === "video" ? [video] : [element], addEventListener: (name, fn) => {documentHandlers[name] = fn; if (name !== "ended") eventHandlers[name] = fn;}};
  const messageHandlers = [];
  const window = {postMessage: data => posts.push(data), addEventListener: (name, fn) => {if (name === "message") messageHandlers.push(fn); else eventHandlers[name] = fn;}};
  let workerReply = {ok: true};
  const chrome = {runtime: {sendMessage: async message => {workerMessages.push(message); if (message.type === "relay") relays.push(message.payload); return workerReply;}, onMessage: {addListener(fn) {workerHandlers.push(fn);}}}};
  const context = vm.createContext({URL, URLSearchParams, crypto: require("node:crypto").webcrypto, window, document, location: new URL(PAGE), chrome, getComputedStyle: () => ({display: "block", visibility: "visible", opacity: "1"}), setInterval: fn => {intervals.push(fn); return 1;}, clearInterval() {}});
  vm.runInContext(source("content-bundle.js"), context);
  const nonce = posts[0].nonce;
  function emit(message) {for (const fn of messageHandlers) fn({source: window, origin: "https://www.bilibili.com", data: {marker: "bili-caption-menu-v1", direction: "page", nonce, pageKey: context.BiliCaptionCore.pageKey(PAGE), ...message}});}
  function control(message) {return new Promise(resolve => {for (const fn of workerHandlers) fn(message, {}, resolve);});}
  return {context, relays, posts, video, document, eventHandlers, documentHandlers, workerMessages, intervals, emit, control, element, setWorkerReply: reply => {workerReply = reply;}};
}
test("playback stalls/seeks pause extrapolation; hidden DOM captions do not override timeline", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"});
  await flush();
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).paused, false);
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).captionVisible, true);
  env.video.readyState = 2;
  env.eventHandlers.waiting();
  await flush();
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).paused, true);
  env.video.readyState = 4;
  env.video.seeking = true;
  env.eventHandlers.seeking();
  await flush();
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).paused, true);
  env.video.seeking = false;
  env.document.hidden = true;
  env.eventHandlers.visibilitychange();
  await flush();
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).captionVisible, false);
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).paused, false);
});
test("current rendered caption selects correct track over later translated request", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"});
  env.emit({type: "track", url: SUBTITLE, language: "ai-zh", cues: [{from: 0, to: 4, content: "测试字幕"}]});
  await flush();
  env.emit({type: "track", url: SUBTITLE.replace("abc", "english"), language: "ai-en", cues: [{from: 0, to: 4, content: "English subtitle"}]});
  await flush();
  const tracks = env.relays.filter(payload => payload.kind === "track");
  assert.ok(tracks.length);
  assert.equal(tracks.at(-1).cues[0].content, "测试字幕");
});
test("metadata part swap clears previous track in content", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"});
  env.emit({type: "track", url: SUBTITLE, language: "ai-zh", cues: [{from: 0, to: 4, content: "测试字幕"}]});
  await flush();
  env.emit({type: "identity", pageKey: env.context.BiliCaptionCore.pageKey(PAGE, "987")});
  await flush();
  assert.match(env.relays.filter(item => item.kind === "playback").at(-1).pageKey, /cid=987/);
  assert.equal(env.relays.filter(item => item.kind === "playback").at(-1).kind, "playback");
});
test("native needsTrack flag repairs a quick restart without a failed heartbeat", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"});
  env.emit({type: "track", url: SUBTITLE, language: "ai-zh", cues: [{from: 0, to: 4, content: "测试字幕"}]});
  await flush();
  const before = env.relays.filter(payload => payload.kind === "track").length;
  env.setWorkerReply({ok: true, needsTrack: true});
  env.eventHandlers.timeupdate();
  await flush();
  assert.ok(env.relays.filter(payload => payload.kind === "track").length > before);
});
test("playback control pauses/resumes the video once and ignores duplicate delivery", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"});
  await flush();
  const control = {type: "control", action: "togglePlayback", controlId: "12345678-1234-1234-1234-123456789abc"};
  let result = await env.control(control);
  assert.equal(result.ok, true);
  assert.equal(env.video.paused, true);
  result = await env.control(control);
  assert.equal(result.ok, true);
  assert.equal(result.duplicate, true);
  assert.equal(env.video.paused, true);
  result = await env.control(control);
  assert.equal(env.video.paused, true);
  const next = {...control, controlId: "87654321-4321-4321-4321-cba987654321"};
  result = await env.control(next);
  assert.equal(result.ok, true);
  assert.equal(env.video.paused, false);
  const rateControl = {...control, controlId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", action: "setPlaybackRate", rate: 1.5};
  result = await env.control(rateControl);
  assert.equal(result.ok, true);
  assert.equal(env.video.playbackRate, 1.5);
  result = await env.control(rateControl);
  assert.equal(result.duplicate, true);
  assert.equal(env.video.playbackRate, 1.5);
});
test("late initial metadata keeps captured track and annotates its AI Chinese language", async () => {
  const env = hookEnvironment();
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "a".repeat(32)});
  await env.window.fetch(SUBTITLE);
  await flush();
  await env.window.fetch("https://api.bilibili.com/x/player/wbi/v2?cid=42&bvid=BV1jV4y1a7ao");
  await flush();
  const track = env.posts.filter(message => message.type === "track").at(-1);
  assert.match(track.pageKey, /cid=42/);
  assert.equal(track.language, "ai-zh");
});
function workerEnvironment() {
  const requests = [], stored = [], tabMessages = [], updates = [], executions = [], sessionData = {};
  let handler;
  let fetchReply = {ok: true, needsTrack: true};
  let sendResult = async () => ({ok: true, paused: false}), executionResult = {ok: true};
  const chrome = {runtime: {onMessage: {addListener: fn => {handler = fn;}}, getURL: name => `chrome-extension://test/${name}`}, storage: {local: {get: async () => ({}), set: async value => {stored.push(plain(value));}}, session: {get: async key => ({[key]: sessionData[key]}), set: async value => Object.assign(sessionData, plain(value)), remove: async key => {delete sessionData[key];}}}, tabs: {onRemoved: {addListener() {}}, update: async (tabId, options) => {updates.push({tabId, options});}, sendMessage: async (tabId, message) => {tabMessages.push({tabId, message}); return sendResult(message);}}, scripting: {executeScript: async details => {executions.push(details); return [{result: typeof executionResult === "function" ? await executionResult(details) : executionResult}];}}};
  const context = vm.createContext({URL, URLSearchParams, crypto: require("node:crypto").webcrypto, AbortController, setTimeout, clearTimeout, chrome, fetch: async (url, options) => {
    requests.push({url, options});
    return new Response(JSON.stringify(fetchReply), {status: 200});
  }});
  context.importScripts = (...files) => files.forEach(file => vm.runInContext(source(file), context));
  vm.runInContext(source("background.js"), context);
  const dispatch = (message, sender) => new Promise(resolve => {
    const asynchronous = handler(message, sender, resolve);
    if (!asynchronous) resolve(undefined);
  });
  return {requests, stored, tabMessages, updates, executions, sessionData, dispatch, setSendResult: value => {sendResult = value;}, setExecutionResult: value => {executionResult = value;}, setFetchReply: reply => {fetchReply = reply;}};
}
test("worker authenticates loopback, attaches sourceId and propagates needsTrack", async () => {
  const env = workerEnvironment();
  const payload = {kind: "playback", pageKey: core().pageKey(PAGE), title: "测试", currentTime: 1, paused: false, playbackRate: 1, hasVideo: true, caption: "字幕", captionVisible: true};
  const response = await env.dispatch({type: "relay", payload}, {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 91, url: PAGE}});
  assert.equal(response.ok, true);
  assert.equal(response.needsTrack, true);
  assert.equal(env.requests[0].url, "http://127.0.0.1:17373/update");
  assert.equal(env.requests[0].options.headers["X-Bili-Token"].length, 64);
  assert.equal(JSON.parse(env.requests[0].options.body).sourceId, "91");
  assert.equal(env.requests[0].options.credentials, "omit");
  assert.equal(JSON.stringify(env.stored).includes('"caption":'), false);
});
test("worker rejects hostile source URLs and invalid payloads before network access", async () => {
  const env = workerEnvironment();
  const payload = {kind: "playback", pageKey: PAGE, title: "x", currentTime: 0, paused: false, playbackRate: 1, hasVideo: true};
  const badSource = await env.dispatch({type: "relay", payload}, {url: "https://evil.example/", origin: "https://evil.example", tab: {id: 1, url: "https://evil.example/"}});
  assert.equal(badSource.ok, false);
  const badPayload = await env.dispatch({type: "relay", payload: {...payload, currentTime: -1}}, {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 1, url: PAGE}});
  assert.equal(badPayload.ok, false);
  assert.equal(env.requests.length, 0);
});
test("worker routes a native playback command only to its matching Bilibili tab", async () => {
  const env = workerEnvironment();
  const payload = {kind: "playback", pageKey: core().pageKey(PAGE), title: "测试", currentTime: 1, paused: false, playbackRate: 1, hasVideo: true, caption: "字幕", captionVisible: true};
  const control = {id: "12345678-1234-1234-1234-123456789abc", action: "togglePlayback", sourceId: "91"};
  env.setFetchReply({ok: true, needsTrack: false, control});
  const response = await env.dispatch({type: "relay", payload}, {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 91, url: PAGE}});
  assert.equal(response.ok, true);
  assert.equal(env.tabMessages.length, 1);
  assert.equal(env.tabMessages[0].tabId, 91);
  assert.equal(env.tabMessages[0].message.action, "togglePlayback");
  await flush();
  assert.equal(env.requests.at(-1).url, "http://127.0.0.1:17373/control/result");
  assert.deepEqual(JSON.parse(env.requests.at(-1).options.body), {id: control.id, ok: true});
});
test("worker validates and routes playback rate commands", async () => {
  const env = workerEnvironment();
  const payload = {kind: "playback", pageKey: core().pageKey(PAGE), title: "测试", currentTime: 1, paused: false, playbackRate: 1, hasVideo: true};
  const control = {id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", action: "setPlaybackRate", sourceId: "91", rate: 1.5};
  env.setFetchReply({ok: true, needsTrack: false, control});
  const response = await env.dispatch({type: "relay", payload}, {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 91, url: PAGE}});
  assert.equal(response.ok, true);
  assert.equal(env.tabMessages[0].tabId, 91);
  assert.equal(env.tabMessages[0].message.action, "setPlaybackRate");
  assert.equal(env.tabMessages[0].message.rate, 1.5);

  const hostile = workerEnvironment();
  hostile.setFetchReply({ok: true, needsTrack: false, control: {...control, rate: 16}});
  const rejected = await hostile.dispatch({type: "relay", payload}, {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 91, url: PAGE}});
  assert.equal(rejected.ok, true);
  assert.equal(hostile.tabMessages.length, 0);
});

const SENDER = {url: PAGE, origin: "https://www.bilibili.com", tab: {id: 91, url: PAGE}};
const PLAYBACK = {kind: "playback", pageKey: PAGE, title: "测试", currentTime: 2, paused: false, playbackRate: 1.5, hasVideo: true, duration: 300};
const COMMAND_ID = "12345678-1234-1234-1234-123456789abc";

test("multipart and collection catalog normalize playable URLs and preserve ordering", () => {
  const C = core();
  const multipart = C.catalogFromVideo({bvid: "BV1jV4y1a7ao", title: "小说", pages: [{page: 1, part: "上", duration: 20}, {page: 2, part: "下", duration: 30}]}, PAGE);
  assert.equal(multipart.items.length, 2);
  assert.equal(multipart.items[1].title, "下");
  assert.equal(multipart.items[1].url, C.pageKey(PAGE));
  const collection = C.catalogFromVideo({bvid: "BV1jV4y1a7ao", title: "第一集", pages: [{page: 1}], ugc_season: {title: "全集", sections: [{episodes: [{bvid: "BV1jV4y1a7ao", title: "一"}, {bvid: "BV18h411N7q5", title: "二"}]}]}}, PAGE);
  assert.equal(collection.title, "全集");
  assert.equal(collection.items.length, 2);
  assert.equal(C.adjacentItem(collection.items, collection.items[0].url, 1).title, "二");
  assert.equal(C.adjacentItem(collection.items, collection.items[0].url, -1), null);
  assert.equal(C.adjacentItem(collection.items, PAGE, 1), null, "unlisted part cannot jump to an unrelated item");
});
test("catalog/account validation bounds metadata and prevents arbitrary navigation", () => {
  const C = core();
  const input = {kind: "catalog", pageKey: PAGE, title: "小说", catalog: {items: [{url: PAGE, title: "第一集"}, {url: "javascript:alert(1)"}, {url: PAGE}], subtitles: [{id: "123", label: "中文", language: "ai-zh", isAI: true}], selectedSubtitleID: "not-present"}};
  const catalog = C.validateCatalog(input).catalog;
  assert.equal(catalog.items.length, 1);
  assert.equal(Object.hasOwn(catalog, "selectedSubtitleID"), false);
  assert.equal(catalog.subtitles[0].isAI, true);
  const account = C.validateAccount({kind: "account", pageKey: PAGE, account: {loggedIn: true, folders: [{id: 123, title: "小说", count: 20}, {id: "bad"}], items: input.catalog.items, folderID: "123"}}).account;
  assert.equal(account.folders.length, 1);
  assert.equal(account.folders[0].id, "123");
  assert.equal(account.items.length, 1);
});
test("control schema rejects hostile URLs, bad rates, account writes without explicit URLs", () => {
  const C = core(), command = {id: COMMAND_ID, sourceId: "91"};
  assert.equal(C.validateControl({...command, action: "playItem", url: "file:///tmp/a"}, "91"), null);
  assert.equal(C.validateControl({...command, action: "playItem", url: PAGE, time: Infinity}, "91"), null);
  assert.equal(C.validateControl({...command, action: "saveFavorites", folderID: "123", urls: []}, "91"), null);
  assert.equal(C.validateControl({...command, action: "addWatchLater", urls: ["https://evil.example/"]}, "91"), null);
  assert.equal(C.validateControl({...command, action: "setPlaybackRate", rate: 3}, "91").rate, 3);
  assert.equal(C.validateControl({...command, action: "seek", time: -2}, "91"), null);
  assert.equal(C.validateControl({...command, action: "loadAccount"}, "92"), null);
});
test("worker reports command failures once and deduplicates concurrent deliveries", async () => {
  const env = workerEnvironment();
  let release;
  env.setSendResult(() => new Promise(resolve => {release = resolve;}));
  const control = {id: COMMAND_ID, action: "togglePlayback", sourceId: "91"};
  env.setFetchReply({ok: true, control});
  const a = env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  const b = env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  let heartbeatDelivered = false;
  void a.then(() => { heartbeatDelivered = true; });
  await flush();
  assert.equal(heartbeatDelivered, true, "slow commands must not block the playback heartbeat");
  assert.equal(env.tabMessages.length, 1);
  release({ok: false, error: "播放器拒绝播放"});
  await Promise.all([a, b]);
  await flush();
  assert.equal(env.requests.filter(request => request.url.endsWith("/control/result")).length, 1, "in-flight duplicate deliveries must not produce a result burst");
  await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  await flush();
  assert.equal(env.tabMessages.length, 1, "failed commands must not toggle again");
  const result = JSON.parse(env.requests.filter(request => request.url.endsWith("/control/result")).at(-1).options.body);
  assert.deepEqual(result, {id: COMMAND_ID, ok: false, error: "播放器拒绝播放"});
  assert.equal(env.sessionData.completedControls[COMMAND_ID].ok, false);
});
test("native playItem navigates the same tab, restores time/rate only on the target page", async () => {
  const env = workerEnvironment(), target = PAGE.replace("p=2", "p=3");
  env.setFetchReply({ok: true, control: {id: COMMAND_ID, sourceId: "91", action: "playItem", url: target, time: 42, rate: 2.5}});
  await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  await flush();
  assert.equal(env.updates.length, 1);
  assert.equal(env.updates[0].tabId, 91);
  assert.equal(env.updates[0].options.url, core().pageKey(target));
  assert.equal(env.sessionData['resume:91'].time, 42);
  assert.equal(env.sessionData['resume:91'].rate, 2.5);
  assert.equal((await env.dispatch({type: "resume", pageKey: PAGE}, SENDER)).resume, undefined);
  const response = await env.dispatch({type: "resume", pageKey: target}, {...SENDER, url: target});
  assert.equal(response.resume.time, 42);
  await env.dispatch({type: "resumed", resumeID: response.resume.id, pageKey: target}, {...SENDER, url: target});
  assert.equal(env.sessionData['resume:91'], undefined);
});
test("end-of-item policies use saved queue, repeat current, or stop without wrapping", async () => {
  const current = core().pageKey(PAGE), next = current.replace("p=2", "p=3");
  for (const mode of ["sequence", "repeatOne", "stopAfter"]) {
    const env = workerEnvironment();
    env.setFetchReply({ok: true, preferences: {controlledSourceId: "91", playbackMode: mode, autoSubtitle: true, subtitlePreference: "human", queue: [{url: current, title: "二"}, {url: next, title: "三"}]}});
    const reply = await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
    assert.equal(reply.preferences.subtitlePreference, "human");
    await env.dispatch({type: "ended", pageKey: current}, SENDER);
    if (mode === "sequence") assert.equal(env.updates[0].options.url, next);
    if (mode === "repeatOne") { assert.equal(env.tabMessages[0].message.type, "resume"); assert.equal(env.tabMessages[0].message.resume.time, 0); }
    if (mode === "stopAfter") { assert.equal(env.updates.length, 0); assert.equal(env.tabMessages.length, 0); }
  }
});
test("only authenticated native account commands execute MAIN actions; account result has sourceId", async () => {
  const env = workerEnvironment();
  const forged = await env.dispatch({type: "control", action: "addWatchLater", urls: [PAGE]}, SENDER);
  assert.equal(forged, undefined);
  await env.dispatch({type: "relay", payload: {...PLAYBACK, action: "saveFavorites", urls: [PAGE]}}, SENDER);
  assert.equal(env.executions.length, 0);
  env.setFetchReply({ok: true, control: {id: COMMAND_ID, sourceId: "91", action: "loadAccount", folderID: "watchlater"}});
  env.setExecutionResult({ok: true, account: {loggedIn: true, folders: [], items: [{url: PAGE, title: "小说"}], folderID: "watchlater"}});
  await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  assert.equal(env.executions.length, 1);
  assert.equal(env.executions[0].world, "MAIN");
  assert.equal(env.executions[0].target.tabId, 91);
  await flush();
  const account = env.requests.map(request => request.options.body && JSON.parse(request.options.body)).find(payload => payload?.kind === "account");
  assert.equal(account.sourceId, "91");
  assert.equal(account.account.items.length, 1);
  assert.equal(JSON.stringify(env.stored).includes("小说"), false, "account list is never stored in persistent connection status");
});
test("subtitle preference selects a known Chinese track and clicks only the main CC item", async () => {
  const env = contentEnvironment();
  let clicked = 0;
  const ai = {id: "100", label: "AI 中文", language: "ai-zh", isAI: true};
  const human = {id: "200", label: "中文", language: "zh-CN", isAI: false};
  const option = {getAttribute: () => "zh-CN", click: () => {clicked++;}};
  const originalQuery = env.document.querySelectorAll;
  env.document.querySelectorAll = selector => selector.includes("major-inner") ? [option] : originalQuery(selector);
  env.setWorkerReply({ok: true, preferences: {autoSubtitle: true, subtitlePreference: "human", playbackMode: "sequence"}});
  env.emit({type: "ready"});
  await flush();
  env.emit({type: "catalog", catalog: {title: "小说", items: [{url: PAGE, title: "第二集"}], subtitles: [ai, human]}});
  env.emit({type: "track", id: "100", url: SUBTITLE, language: "ai-zh", cues: [{from: 0, to: 4, content: "测试字幕"}]});
  env.emit({type: "track", id: "200", url: SUBTITLE.replace("abc", "human"), language: "zh-CN", cues: [{from: 0, to: 4, content: "人工字幕"}]});
  await flush();
  assert.equal(clicked, 1);
  assert.equal(env.relays.filter(item => item.kind === "track").at(-1).cues[0].content, "人工字幕");
  assert.ok(env.posts.some(message => message.type === "selectSubtitle" && message.subtitleID === "200"));
  const result = await env.control({type: "control", controlId: COMMAND_ID, action: "selectSubtitle", subtitleID: "absent"});
  assert.equal(result.ok, false);
});
test("content captures ended only after native preferences and supports seek/resume", async () => {
  const env = contentEnvironment();
  let stopped = 0;
  env.emit({type: "ready"});
  await flush();
  env.documentHandlers.ended({target: env.video, stopImmediatePropagation() {stopped++;}});
  assert.equal(stopped, 0);
  env.setWorkerReply({ok: true, sourceId: "91", preferences: {controlledSourceId: "91", playbackMode: "stopAfter"}});
  env.eventHandlers.timeupdate(); await flush();
  env.documentHandlers.ended({target: env.video, stopImmediatePropagation() {stopped++;}});
  await flush();
  assert.equal(stopped, 1);
  assert.ok(env.workerMessages.some(message => message.type === "ended"));
  const result = await env.control({type: "control", controlId: COMMAND_ID, action: "seek", time: 20});
  assert.equal(result.ok, true); assert.equal(env.video.currentTime, 20);
  await env.control({type: "resume", resume: {url: PAGE, time: 80, rate: 3}});
  assert.equal(env.video.currentTime, 80); assert.equal(env.video.playbackRate, 3); assert.equal(env.video.paused, false);
});
function accountEnvironment(replies) {
  const requests = [];
  const csrf = "a".repeat(32);
  const context = vm.createContext({URL, URLSearchParams, AbortController, setTimeout, clearTimeout, document: {cookie: `bili_jct=${csrf}; unrelated=private`}, fetch: async (url, options) => {
    const parsed = new URL(url); requests.push({path: parsed.pathname, query: parsed.searchParams, options});
    const value = typeof replies[parsed.pathname] === "function" ? replies[parsed.pathname](requests.at(-1)) : replies[parsed.pathname];
    if (!value) throw new Error(`Unexpected endpoint ${parsed.pathname}`);
    return new Response(JSON.stringify(value), {status: 200});
  }});
  vm.runInContext(source("page-actions.js"), context);
  return {requests, csrf, task: command => context.biliCaptionAccountTask(command)};
}
const LOGGED_IN = {code: 0, data: {isLogin: true, mid: 123}};
const FOLDERS = {code: 0, data: {list: [{id: 456, title: "小说", media_count: 2}]}};
test("account reads watch-later and paginated favorites without writes or credential return", async () => {
  const env = accountEnvironment({"/x/web-interface/nav": LOGGED_IN, "/x/v3/fav/folder/created/list-all": FOLDERS, "/x/v2/history/toview": {code: 0, data: {list: [{bvid: "BV1jV4y1a7ao", title: "稍后听"}]}}, "/x/v3/fav/resource/list": request => ({code: 0, data: {has_more: request.query.get("pn") === "1", medias: [{bvid: request.query.get("pn") === "1" ? "BV1jV4y1a7ao" : "BV18h411N7q5", title: "分集"}]}})});
  const watch = await env.task({action: "loadAccount", folderID: "watchlater"});
  assert.equal(watch.ok, true); assert.equal(watch.account.items[0].title, "稍后听");
  const favorites = await env.task({action: "loadAccount", folderID: "456"});
  assert.equal(favorites.account.items.length, 2);
  assert.equal(env.requests.every(request => request.options.method === "GET"), true);
  assert.equal(JSON.stringify([watch, favorites]).includes(env.csrf), false);
  assert.equal(JSON.stringify([watch, favorites]).includes("private"), false);
});
test("account save deduplicates multipart videos, requires owned folder and reports partial failure", async () => {
  const env = accountEnvironment({"/x/web-interface/nav": LOGGED_IN, "/x/v3/fav/folder/created/list-all": FOLDERS, "/x/web-interface/view": {code: 0, data: {aid: 999}}, "/x/v3/fav/resource/deal": {code: 0}, "/x/v2/history/toview/add": request => ({code: new URLSearchParams(request.options.body).get("bvid") === "BV18h411N7q5" ? 90001 : 0})});
  const save = await env.task({action: "saveFavorites", folderID: "456", urls: [PAGE, PAGE.replace("p=2", "p=3")]});
  assert.equal(save.ok, true); assert.equal(save.saved, 1);
  const posts = env.requests.filter(request => request.options.method === "POST");
  assert.equal(posts.length, 1);
  assert.equal(new URLSearchParams(posts[0].options.body).get("rid"), "999");
  assert.equal(new URLSearchParams(posts[0].options.body).get("add_media_ids"), "456");
  const invalid = await env.task({action: "saveFavorites", folderID: "789", urls: [PAGE]});
  assert.equal(invalid.ok, false);
  assert.equal(env.requests.filter(request => request.options.method === "POST").length, 1);
  const partial = await env.task({action: "addWatchLater", urls: [PAGE, "https://www.bilibili.com/video/BV18h411N7q5/"]});
  assert.equal(partial.ok, false); assert.equal(partial.saved, 1); assert.match(partial.error, /1\/2/);
  assert.equal(JSON.stringify([save, invalid, partial]).includes(env.csrf), false);
});

test("non-selected tabs and absent native control selection never take over auto-next", async () => {
  for (const controlledSourceId of ["92", ""]) {
    const env = workerEnvironment();
    env.setFetchReply({ok: true, preferences: {controlledSourceId, playbackMode: "sequence", queue: [{url: PAGE, title: "二"}, {url: PAGE.replace("p=2", "p=3"), title: "三"}]}});
    await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
    assert.equal((await env.dispatch({type: "ended", pageKey: PAGE}, SENDER)).ok, false);
    assert.equal(env.updates.length, 0);
  }
  const env = contentEnvironment();
  env.setWorkerReply({ok: true, sourceId: "91", preferences: {controlledSourceId: "92", playbackMode: "sequence"}});
  env.emit({type: "ready"}); await flush();
  let intercepted = false;
  env.documentHandlers.ended({target: env.video, stopImmediatePropagation() {intercepted = true;}});
  assert.equal(intercepted, false);
});
test("page bridge cannot request account writes or load arbitrary subtitle URLs", async () => {
  const env = hookEnvironment();
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "b".repeat(32)});
  await flush();
  const before = env.requests.length;
  for (const type of ["saveFavorites", "addWatchLater", "loadAccount", "selectSubtitle"]) {
    env.emit({marker: "bili-caption-menu-v1", direction: "content", nonce: "b".repeat(32), type, subtitleID: "https://evil.example/a", urls: [PAGE], folderID: "123"});
  }
  await flush();
  assert.equal(env.requests.length, before);
});

test("CC-off startup reads multipart catalog and fetches available AI track automatically", async () => {
  const env = hookEnvironment();
  env.window.__INITIAL_STATE__ = {videoData: {bvid: "BV1jV4y1a7ao", title: "合成小说", pages: [{page: 1, cid: 41, part: "第一集", duration: 20}, {page: 2, cid: 42, part: "第二集", duration: 30}]}};
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "c".repeat(32)});
  await flush(); await flush();
  const catalog = env.posts.filter(message => message.type === "catalog").at(-1).catalog;
  assert.equal(catalog.items.length, 2);
  assert.equal(catalog.items[1].title, "第二集");
  assert.equal(catalog.subtitles[0].language, "ai-zh");
  assert.ok(env.posts.some(message => message.type === "track" && message.language === "ai-zh"));
  assert.ok(env.requests.some(request => request.url.includes("/x/player/v2?cid=42")));
  assert.equal(env.requests.filter(request => request.url === SUBTITLE).length, 1);
});

test("rapid next/previous commands advance from the pending destination and retain rate", async () => {
  const env = workerEnvironment(), C = core();
  const queue = [1, 2, 3, 4].map(part => ({url: PAGE.replace("p=2", `p=${part}`), title: String(part)}));
  env.setFetchReply({ok: true, preferences: {queue}});
  await env.dispatch({type: "relay", payload: {...PLAYBACK, playbackRate: 2.5}}, SENDER);
  let sequence = 1;
  async function command(action) {
    env.setFetchReply({ok: true, preferences: {queue}, control: {id: `00000000-0000-0000-0000-${String(sequence++).padStart(12, '0')}`, sourceId: "91", action}});
    await env.dispatch({type: "relay", payload: {...PLAYBACK, playbackRate: 2.5}}, SENDER);
    await flush();
    return {...env.sessionData['resume:91']};
  }
  const first = await command("nextItem");
  assert.equal(first.url, C.pageKey(PAGE.replace("p=2", "p=3")));
  const second = await command("nextItem");
  assert.equal(second.url, C.pageKey(PAGE.replace("p=2", "p=4")), "must not repeat p=3 from the stale p=2 snapshot");
  assert.equal(second.rate, 2.5);
  assert.notEqual(first.id, second.id);
  await env.dispatch({type: "resumed", resumeID: first.id, pageKey: first.url}, SENDER);
  assert.equal(env.sessionData['resume:91'].id, second.id, "late acknowledgement cannot erase a newer navigation");
  const third = await command("previousItem");
  assert.equal(third.url, first.url);
  assert.equal(third.rate, 2.5);
  await env.dispatch({type: "resumed", resumeID: third.id, pageKey: PAGE}, SENDER);
  assert.equal(env.sessionData['resume:91'].id, third.id, "right ID with wrong destination cannot erase resume");
  await env.dispatch({type: "resumed", resumeID: third.id, pageKey: third.url}, SENDER);
  assert.equal(env.sessionData['resume:91'], undefined);
});
test("a newer same-page resume survives an older pending play promise", async () => {
  const env = contentEnvironment();
  env.emit({type: "ready"}); await flush();
  let release, attempts = 0;
  env.video.play = () => { attempts++; return attempts === 1 ? new Promise(resolve => {release = resolve;}) : Promise.resolve(); };
  const first = env.control({type: "resume", resume: {id: "old", url: PAGE, time: 20, rate: 1.5}});
  await flush();
  const second = env.control({type: "resume", resume: {id: "new", url: PAGE, time: 80, rate: 3}});
  release();
  assert.equal((await first).ok, true);
  assert.equal((await second).ok, true);
  assert.equal(env.video.currentTime, 80);
  assert.equal(env.video.playbackRate, 3);
  assert.deepEqual(env.workerMessages.filter(message => message.type === "resumed").map(message => message.resumeID), ["old", "new"]);
});

test("slow account results follow the current SPA page while playback commands remain independent", async () => {
  const env = workerEnvironment(), next = PAGE.replace("p=2", "p=3");
  let release;
  env.setExecutionResult(() => new Promise(resolve => {release = resolve;}));
  env.setFetchReply({ok: true, control: {id: COMMAND_ID, sourceId: "91", action: "loadAccount", folderID: "watchlater"}});
  await env.dispatch({type: "relay", payload: PLAYBACK}, SENDER);
  await flush();
  assert.equal(env.executions.length, 1);
  env.setFetchReply({ok: true, control: {id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", sourceId: "91", action: "togglePlayback"}});
  await env.dispatch({type: "relay", payload: {...PLAYBACK, pageKey: next, title: "下一集"}}, {...SENDER, url: next});
  await flush();
  assert.equal(env.tabMessages[0].message.action, "togglePlayback", "native-prioritized playback command can execute while account read is in flight");
  release({ok: true, account: {loggedIn: true, folders: [], items: [{url: PAGE, title: "稍后听"}], folderID: "watchlater"}});
  await flush();
  const account = env.requests.map(request => request.options.body && JSON.parse(request.options.body)).find(payload => payload?.kind === "account");
  assert.equal(account.pageKey, core().pageKey(next));
  assert.equal(account.title, "下一集");
  assert.equal(env.requests.filter(request => request.url.endsWith("/control/result") && JSON.parse(request.options.body).id === COMMAND_ID).length, 1);
});

test("preview metadata without BV and preloaded different parts cannot replace the current CID", async () => {
  const previewURL = SUBTITLE.replace("abc", "preview");
  const env = hookEnvironment(url => {
    if (url.includes("cid=900")) return {code: 0, data: {subtitle: {subtitles: [{id: 900, lan: "ai-zh", subtitle_url: previewURL}]}}};
    if (url.includes("cid=41")) return {code: 0, data: {cid: 41, bvid: "BV1jV4y1a7ao", subtitle: {subtitles: [{id: 41, lan: "ai-zh", subtitle_url: previewURL}]}}};
    if (url === previewURL) return {lang: "ai-zh", body: [{from: 0.04, to: 88.5, content: "错误的预览短片字幕"}]};
  });
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "d".repeat(32)});
  await flush(); await flush();
  const before = env.posts.filter(message => message.type === "track").length;
  await env.window.fetch("https://api.bilibili.com/x/player/v2?aid=999&cid=900");
  await env.window.fetch(previewURL);
  await env.window.fetch("https://api.bilibili.com/x/player/v2?bvid=BV1jV4y1a7ao&cid=41");
  await flush();
  assert.equal(env.posts.filter(message => message.type === "track").length, before);
  assert.equal(env.posts.filter(message => message.type === "identity").every(message => message.pageKey.endsWith("cid=42")), true);
  assert.equal(env.posts.some(message => JSON.stringify(message).includes("错误的预览短片字幕")), false);
  assert.equal(env.posts.filter(message => message.type === "catalog").at(-1).catalog.subtitles[0].language, "ai-zh");
});
test("only metadata-associated subtitle URLs are published or read from resource history", async () => {
  const unrelated = SUBTITLE.replace("abc", "unknown");
  const env = hookEnvironment(url => url === unrelated || url.includes("/nav") ? {lang: "ai-zh", body: [{from: 0, to: 88.5, content: "无关字幕"}]} : null);
  await env.window.fetch(unrelated);
  await flush();
  assert.equal(env.posts.filter(message => message.type === "track").length, 0, "early unassociated subtitle must remain provisional");
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "hello", nonce: "e".repeat(32)});
  await flush(); await flush();
  env.resources.push({name: unrelated});
  const before = env.requests.filter(request => request.url === unrelated).length;
  env.emit({marker: "bili-caption-menu-v1", direction: "content", type: "resync", nonce: "e".repeat(32)});
  for (const timer of env.timers) timer();
  await env.window.fetch("https://api.bilibili.com/x/web-interface/nav");
  await flush();
  assert.equal(env.requests.filter(request => request.url === unrelated).length, before, "resync cannot re-read unrelated preview resources");
  assert.equal(env.posts.some(message => JSON.stringify(message).includes("无关字幕")), false);
  assert.equal(env.posts.filter(message => message.type === "track").at(-1).url, SUBTITLE);
});
test("current subtitle-x DOM supplies primary captions and excludes secondary duplicates", async () => {
  const env = contentEnvironment();
  const main = {textContent: "当前主字幕", getAttribute: () => "0", getClientRects: () => [{}], parentElement: null};
  const secondary = {textContent: "Secondary subtitle", getAttribute: () => "1", getClientRects: () => [{}], parentElement: null};
  const original = env.document.querySelectorAll;
  env.document.querySelectorAll = selector => selector.includes('.bili-subtitle-x-subtitle-panel-text[data-type="0"]') ? [main, {...main}, secondary] : original(selector);
  env.emit({type: "ready"}); await flush();
  const playback = env.relays.filter(item => item.kind === "playback").at(-1);
  assert.equal(playback.caption, "当前主字幕");
  assert.equal(playback.captionVisible, true);
});
