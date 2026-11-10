/* Serialized by chrome.scripting only after an authenticated native command.
 * This function is never registered as a window/message API. Credentials stay
 * in Bilibili's MAIN world; its return value contains only bounded list data. */
async function biliCaptionAccountTask(command) {
  const text = (value, max = 300) => typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, max) : "";
  const errorMessage = error => text(error?.message) || "B 站请求失败，请稍后重试";
  async function api(path, query = {}, body) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(`https://api.bilibili.com${path}${Object.keys(query).length ? `?${new URLSearchParams(query)}` : ""}`, {
        method: body ? "POST" : "GET", credentials: "include", cache: "no-store", signal: controller.signal,
        ...(body ? {headers: {"Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"}, body: new URLSearchParams(body).toString()} : {})
      });
      if (!response.ok) throw new Error(`B 站请求失败（${response.status}）`);
      const value = await response.json();
      if (value.code !== 0) {
        const labels = {"-101": "请先在网页登录 B 站", "-111": "登录已失效，请刷新 B 站页面", "-352": "B 站需要验证，请在网页完成验证后重试", "-412": "B 站暂时限制请求，请稍后重试", "90001": "稍后再看列表已满"};
        throw new Error(labels[String(value.code)] || `B 站返回错误 ${value.code}：${text(value.message, 120)}`);
      }
      return value.data;
    } finally { clearTimeout(timer); }
  }
  function media(items) {
    return (Array.isArray(items) ? items : []).slice(0, 1000).flatMap((item, index) => {
      const bvid = item.bvid || item.bv_id;
      if (!/^BV[a-z\d]+$/i.test(bvid || "")) return [];
      const page = Number.isInteger(item.page) && item.page > 0 ? item.page : 1;
      const url = `https://www.bilibili.com/video/${bvid}/?p=${page}`;
      return [{id: url, url, title: text(item.title) || "B 站视频", index: index + 1, duration: Number.isFinite(item.duration) ? item.duration : 0}];
    });
  }
  let loggedIn = false, folders = [], folderID = command.folderID || "watchlater";
  try {
    const user = await api("/x/web-interface/nav");
    if (!user?.isLogin || !Number.isSafeInteger(user.mid)) throw new Error("请先在网页登录 B 站");
    loggedIn = true;
    if (command.action === "loadAccount" || command.action === "saveFavorites") {
      const value = await api("/x/v3/fav/folder/created/list-all", {up_mid: String(user.mid), type: "2"});
      folders = (value?.list || []).slice(0, 200).map(folder => ({id: String(folder.id), title: text(folder.title), count: Number(folder.media_count) || 0}));
    }
    if (command.action === "loadAccount") {
      let items = [], truncated = false;
      if (folderID === "watchlater") {
        const value = await api("/x/v2/history/toview");
        items = media(value?.list);
      } else {
        if (!folders.some(folder => folder.id === folderID)) throw new Error("收藏夹不存在或不属于当前登录账号");
        for (let pn = 1; pn <= 50; pn++) {
          const value = await api("/x/v3/fav/resource/list", {media_id: folderID, pn: String(pn), ps: "20", order: "mtime", type: "0", platform: "web"});
          items.push(...media(value?.medias));
          if (!value?.has_more || !value?.medias?.length) break;
          if (pn === 50) truncated = true;
        }
      }
      return {ok: true, account: {loggedIn, folders, items: items.slice(0, 1000), folderID, ...(truncated ? {error: "已读取前 1000 条视频，超出部分请在 B 站查看"} : {})}};
    }
    if (!["saveFavorites", "addWatchLater"].includes(command.action)) throw new Error("不支持的账号操作");
    if (command.action === "saveFavorites" && !folders.some(folder => folder.id === folderID)) throw new Error("收藏夹不存在或不属于当前登录账号");
    const csrf = document.cookie.split(";").map(value => value.trim()).find(value => value.startsWith("bili_jct="))?.slice(9);
    if (!csrf || !/^[a-f\d]{32}$/i.test(csrf)) throw new Error("登录已失效，请刷新 B 站页面");
    // A multi-part video is one Bilibili favorite; dedupe by BV/AV, not by part.
    const identifiers = [...new Set(command.urls.map(url => new URL(url).pathname.split("/")[2]))];
    let saved = 0;
    for (const identifier of identifiers) {
      try {
        if (command.action === "addWatchLater") {
          await api("/x/v2/history/toview/add", {}, {...(identifier.startsWith("BV") ? {bvid: identifier} : {aid: identifier.slice(2)}), csrf});
        } else {
          let aid = identifier.startsWith("av") ? identifier.slice(2) : "";
          if (!aid) aid = String((await api("/x/web-interface/view", {bvid: identifier}))?.aid || "");
          if (!/^\d{1,20}$/.test(aid)) throw new Error("无法读取视频编号");
          await api("/x/v3/fav/resource/deal", {}, {rid: aid, type: "2", add_media_ids: folderID, csrf});
        }
        saved++;
      } catch (error) {
        return {ok: false, error: `${errorMessage(error)}（已保存 ${saved}/${identifiers.length} 个视频）`, saved};
      }
    }
    return {ok: true, saved};
  } catch (error) {
    const message = errorMessage(error);
    return {ok: false, error: message, ...(command.action === "loadAccount" ? {account: {loggedIn, folders, items: [], folderID, error: message}} : {})};
  }
}
