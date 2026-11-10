"use strict";
const $ = id => document.getElementById(id);
let tab = null;
async function inspect() {
  const currentTabs = await chrome.tabs.query({active: true, currentWindow: true});
  tab = BiliCaptionCore.pickVideoTab(currentTabs);
  if (!tab) {
    // Arc can give the browser-action popup its own window. Limit fallback
    // discovery to our permitted Bilibili video pages, including background audio.
    const videoTabs = await chrome.tabs.query({url: "https://www.bilibili.com/video/*"});
    tab = BiliCaptionCore.pickVideoTab(videoTabs);
  }
  const isVideo = BiliCaptionCore.videoPage(tab?.url || "");
  $("resync").disabled = !isVideo;
  $("reload").disabled = !isVideo;
  $("video-title").textContent = isVideo ? (tab.title || "B 站视频").replace(/[_\-\s]*哔哩哔哩.*$/, "") : "请打开 B 站视频页面";
  const status = await chrome.runtime.sendMessage({type: "status", tabId: tab?.id});
  $("dot").className = `dot ${status?.connected ? "connected" : "offline"}`;
  $("connection").textContent = status?.connected ? "菜单栏程序已连接" : (status?.error || "请先打开 BiliCaption");
  const video = status?.tab;
  if (!isVideo) $("detail").textContent = "打开普通 B 站视频页后，会自动检查 AI／人工字幕和分集目录。";
  else if (!video || Date.now() - video.lastUpdate > 15000) $("detail").textContent = "首次安装扩展，请刷新一次视频页。";
  else if (video.hasTrack) $("detail").textContent = `${video.paused ? "已暂停" : "正在播放"} · 已同步 ${video.cueCount.toLocaleString()} 条字幕${video.episodeCount ? ` · ${video.episodeCount} 集` : ""}`;
  else if (video.hasCaption) $("detail").textContent = "已读取画面字幕，正在等待完整字幕时间轴。";
  else $("detail").textContent = video.subtitleStatus || "正在检查可用字幕；可在菜单栏选择 AI 中文或人工中文。";
}
$("resync").addEventListener("click", async () => {
  if (!tab?.id) return;
  $("resync").disabled = true;
  try {
    const response = await chrome.tabs.sendMessage(tab.id, {type: "resync"});
    $("message").textContent = response?.hasTrack ? "已重新同步字幕、目录和进度。" : "正在重新检查可用字幕；尚无轨道时不会自行生成字幕。";
  } catch { $("message").textContent = "扩展还未加载到此页面，请点击刷新 B 站页面。"; }
  $("resync").disabled = false;
  void inspect();
});
$("reload").addEventListener("click", async () => {
  if (!tab?.id) return;
  await chrome.tabs.reload(tab.id);
  $("message").textContent = "页面正在刷新，播放后会自动同步。";
});
void inspect().catch(() => { $("connection").textContent = "检查失败，请重新打开扩展弹窗"; });
