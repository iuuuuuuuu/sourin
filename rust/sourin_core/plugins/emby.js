/**
 * @id emby
 * @name Emby
 * @version 1.0.0
 * @author sourin
 * @description 接入你自己的 Emby 媒体服务器：填地址 + 账号密码，就能浏览 / 搜索 / 播放。
 *
 * ══════════════════════════════════════════════════════════════════════
 *  怎么用
 * ══════════════════════════════════════════════════════════════════════
 *  设置 → 插件 → Emby → 配置：
 *      serverUrl   http://10.0.2.2:8096        ← 安卓模拟器里访问宿主机
 *                  http://192.168.1.10:8096    ← 局域网真机 / 电视盒子
 *      username    sourin
 *      password    ********
 *  保存后回到首页下拉刷新，会出现每个媒体库一个区块。
 *
 * ══════════════════════════════════════════════════════════════════════
 *  实测记录（2026-10-05，Emby 4.9.3.0，ServerName 公司电脑-M600）
 * ══════════════════════════════════════════════════════════════════════
 *  POST /Users/AuthenticateByName            200  取 AccessToken
 *      ★ 无 /emby 前缀；带前缀 → 401
 *      ★ 必须带 X-Emby-Authorization 头；不带 → 401
 *  GET  /Users/<uid>/Views                    200  媒体库列表
 *  GET  /Users/<uid>/Items?ParentId=<lib>     200  库内条目
 *  GET  /Users/<uid>/Items/<id>?Fields=...    200  详情
 *      ★ 非 Users 前缀的 /Items/<id> → 404「找不到文件 "/Items/5"」
 *  GET  /Items/<id>/PlaybackInfo?UserId=<uid> 200  MediaSources[0].Id
 *  GET  /Videos/<id>/stream?static=true       206  直连（Range 也支持）
 *  GET  /Videos/<id>/master.m3u8?...          200  转码 HLS（子清单是相对路径）
 *  GET  /Items/<id>/Images/Primary            ★ 没海报时 500 ⇒ 本文件只在
 *      ImageTags.Primary 存在时才给出 cover，避免整页刷一堆失败图
 *
 * ══════════════════════════════════════════════════════════════════════
 *  几个刻意的取舍
 * ══════════════════════════════════════════════════════════════════════
 *  ① 不走宿主登录面板：账号密码放 config 里，登录结果塞 host.store。
 *     原因 —— 声明 loginRequired 会让 Registry::ensure_session 把游客
 *     挡在门外，而 Emby 的「服务器地址」本身就是要用户填的，两套输入
 *     框会打架。所以 capabilities 里 loginSupported 保持 false。
 *  ② home() 只用 { type: 'category' }：Dart 的 home_page.dart:584
 *     _loadSection 只认 category / rank 两种，recent / custom 不会被
 *     预取（会渲染成空轨道）。所以每个媒体库声明成一个 category 区块。
 *  ③ 返回的 JSON 键一律写 camelCase —— 宿主 js_value_to_rust 会递归把
 *     键名转成 snake_case（plugins/mod.rs:167），写 pageCount 才对得上
 *     Rust 的 page_count。
 *  ④ 单次调用总预算 10 秒（plugins/mod.rs:44 SCRIPT_BUDGET_MS），HTTP
 *     超时却是 15 秒 ⇒ 媒体库列表与 MediaSourceId 都做了 host.store 缓存，
 *     避免每次调用都打网络。
 */
(function () {
  'use strict';

  var UNCONFIGURED = '__emby_setup__';
  var PAGE_SIZE = 60;
  var LIST_TYPES = 'Movie,Series,Video';
  var SEARCH_TYPES = 'Movie,Series,Episode,Video';
  var ITEM_FIELDS = 'Path,Overview,ProductionYear,RunTimeTicks,Genres,ImageTags,CommunityRating';
  var DETAIL_FIELDS = 'Overview,Path,Genres,People,MediaSources,MediaStreams,ImageTags,ProductionYear,RunTimeTicks,CommunityRating,OfficialRating,Taglines';

  var AUTH_CLIENT = 'sourin-spike';
  var AUTH_DEVICE = 'sourin-app';
  var AUTH_DEVICE_ID = 'sourin-emby-client-0001';
  var AUTH_VERSION = '0.1.0';

  // ── 小工具 ──────────────────────────────────────────────────────────
  function enc(s) {
    return encodeURIComponent(String(s == null ? '' : s));
  }

  function cfgStr(key, def) {
    try {
      var v = host.config.getString(key, def);
      return (v == null) ? def : String(v);
    } catch (e) { return def; }
  }

  function cfgBool(key, def) {
    try {
      var v = host.config.getBool(key, def);
      return (v == null) ? def : !!v;
    } catch (e) { return def; }
  }

  function storeGet(k) {
    try { return host.store.get(k); } catch (e) { return null; }
  }

  function storeSet(k, v) {
    try { host.store.set(k, String(v)); } catch (e) { /* 存不下也不致命 */ }
  }

  function storeDel(k) {
    try { host.store.remove(k); } catch (e) { /* 同上 */ }
  }

  function baseUrl() {
    var u = cfgStr('serverUrl', '').trim();
    if (!u) return '';
    u = u.replace(/\/+$/, '');
    if (!/^https?:\/\//i.test(u)) u = 'http://' + u;
    return u;
  }

  function authHeader(token) {
    var s = 'MediaBrowser Client="' + AUTH_CLIENT + '", Device="' + AUTH_DEVICE +
            '", DeviceId="' + AUTH_DEVICE_ID + '", Version="' + AUTH_VERSION + '"';
    if (token) s = s + ', Token="' + token + '"';
    return s;
  }

  function transcodeOn() {
    return cfgBool('transcode', false);
  }

  // ── HTTP（★ host.http 不抛异常，失败返回 __ERR__ 开头的字符串）─────
  function errText(text) {
    return (typeof text === 'string' && text.indexOf('__ERR__') === 0);
  }

  async function getText(url, headers) {
    var text = await host.http.get(url, { headers: headers || {} });
    if (errText(text)) throw new Error('network: ' + String(text).slice(7));
    if (typeof text !== 'string') throw new Error('parse: 宿主返回了非文本响应');
    return text;
  }

  async function getJson(url, headers) {
    var text = await getText(url, headers);
    try {
      return JSON.parse(text);
    } catch (e) {
      throw new Error('parse: 返回不是合法 JSON — ' + String(text).slice(0, 120));
    }
  }

  // ── 登录 / 会话 ─────────────────────────────────────────────────────
  function savedSession() {
    var t = storeGet('token');
    var u = storeGet('userId');
    if (!t || !u) return null;
    return { token: String(t), userId: String(u), userName: String(storeGet('userName') || '') };
  }

  async function login() {
    var base = baseUrl();
    if (!base) {
      throw new Error('unsupported: 还没有填 Emby 服务器地址（设置 → 插件 → Emby → 配置）');
    }
    var user = cfgStr('username', '').trim();
    var pass = cfgStr('password', '');
    if (!user) throw new Error('unauthorized: 还没有填 Emby 用户名');

    var url = base + '/Users/AuthenticateByName';
    var body = JSON.stringify({ Username: user, Pw: pass });
    var text = await host.http.post(url, body, {
      headers: {
        'X-Emby-Authorization': authHeader(null),
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });
    if (errText(text)) {
      var rest = String(text).slice(7);
      if (rest.indexOf('401') >= 0 || rest.indexOf('400') >= 0) {
        throw new Error('unauthorized: Emby 用户名或密码不对（' + rest.slice(0, 120) + '）');
      }
      throw new Error('network: ' + rest);
    }

    var j;
    try { j = JSON.parse(text); }
    catch (e) { throw new Error('parse: 登录返回不是 JSON — ' + String(text).slice(0, 120)); }

    if (!j || !j.AccessToken) throw new Error('unauthorized: 登录没有返回 AccessToken');

    var uid = (j.User && j.User.Id) ? String(j.User.Id) : '';
    var uname = (j.User && j.User.Name) ? String(j.User.Name) : user;
    storeSet('token', j.AccessToken);
    storeSet('userId', uid);
    storeSet('userName', uname);
    if (j.ServerId) storeSet('serverId', String(j.ServerId));
    return { token: String(j.AccessToken), userId: uid, userName: uname };
  }

  async function session(force) {
    if (!force) {
      var s = savedSession();
      if (s) return s;
    }
    return await login();
  }

  // 带 api_key 的 GET；遇到 401 自动重登一次再试（token 可能被服务端踢掉）
  async function apiGet(pathAndQuery) {
    var s = await session(false);
    var sep = (pathAndQuery.indexOf('?') >= 0) ? '&' : '?';
    var url = baseUrl() + pathAndQuery + sep + 'api_key=' + enc(s.token);
    try {
      return await getJson(url);
    } catch (e) {
      var msg = String((e && e.message) ? e.message : e);
      var low = msg.toLowerCase();
      if (msg.indexOf('401') >= 0 || low.indexOf('unauthorized') >= 0) {
        var s2 = await session(true);
        var url2 = baseUrl() + pathAndQuery + sep + 'api_key=' + enc(s2.token);
        return await getJson(url2);
      }
      throw e;
    }
  }

  // ── 媒体库（带缓存）────────────────────────────────────────────────
  async function views() {
    var cached = storeGet('views');
    if (cached) {
      try {
        var arr0 = JSON.parse(String(cached));
        if (Object.prototype.toString.call(arr0) === '[object Array]' && arr0.length) return arr0;
      } catch (e) { /* 缓存坏了就当没有 */ }
    }
    var s = await session(false);
    var j = await apiGet('/Users/' + enc(s.userId) + '/Views');
    var raw = (j && j.Items) ? j.Items : [];
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      var v = raw[i];
      if (!v || !v.Id) continue;
      out.push({
        id: String(v.Id),
        name: String(v.Name || '未命名媒体库'),
        collectionType: String(v.CollectionType || '')
      });
    }
    storeSet('views', JSON.stringify(out));
    storeSet('viewsAt', String(Date.now()));
    return out;
  }

  // ── 条目 → 卡片 ────────────────────────────────────────────────────
  function ticksToMinutes(ticks) {
    var n = parseInt(ticks, 10);
    if (!n || n <= 0) return 0;
    return Math.max(1, Math.round(n / 600000000));
  }

  function coverUrl(it) {
    if (!it || !it.Id) return null;
    var tags = it.ImageTags;
    var tag = (tags && tags.Primary) ? String(tags.Primary) : '';
    if (!tag) return null;               // ★ 没海报就别给 URL：Emby 会 500
    var s = savedSession();
    if (!s) return null;
    return baseUrl() + '/Items/' + enc(it.Id) + '/Images/Primary?maxHeight=400&tag=' +
           enc(tag) + '&api_key=' + enc(s.token);
  }

  function subtitleOf(it) {
    var bits = [];
    if (it && it.ProductionYear) bits.push(String(it.ProductionYear));
    var mins = ticksToMinutes(it ? it.RunTimeTicks : 0);
    if (mins) bits.push(mins + ' 分钟');
    if (it && it.Type === 'Series' && it.RecursiveItemCount) {
      bits.push('共 ' + String(it.RecursiveItemCount) + ' 集');
    }
    return bits.length ? bits.join(' · ') : null;
  }

  function kindOf(it) {
    var t = String((it && it.Type) || '');
    if (t === 'Series') return 'series';
    if (t === 'BoxSet' || t === 'CollectionFolder') return 'collection';
    if (t === 'TvChannel' || t === 'LiveTvChannel' || t === 'Program') return 'live';
    return 'movie';
  }

  function toItem(it) {
    if (!it || !it.Id) return null;
    return {
      id: String(it.Id),
      title: String(it.Name || '未命名'),
      cover: coverUrl(it),
      subtitle: subtitleOf(it),
      kind: kindOf(it)
    };
  }

  function pageFrom(j, page, limit) {
    var raw = (j && j.Items) ? j.Items : [];
    var items = [];
    for (var i = 0; i < raw.length; i++) {
      var m = toItem(raw[i]);
      if (m) items.push(m);
    }
    var total = (j && typeof j.TotalRecordCount === 'number') ? j.TotalRecordCount : items.length;
    var pc = Math.max(1, Math.ceil(total / limit));
    return { items: items, page: page, pageCount: pc, total: total };
  }

  function emptyPage(page) {
    return { items: [], page: page, pageCount: 1, total: 0 };
  }

  // ── 播放地址 ───────────────────────────────────────────────────────
  async function mediaSourceId(itemId) {
    var ck = 'ms:' + itemId;
    var cached = storeGet(ck);
    if (cached) return String(cached);
    var s = await session(false);
    var ms = '';
    try {
      var j = await apiGet('/Items/' + enc(itemId) + '/PlaybackInfo?UserId=' + enc(s.userId));
      var arr = (j && j.MediaSources) ? j.MediaSources : [];
      if (arr.length && arr[0] && arr[0].Id) ms = String(arr[0].Id);
    } catch (e) {
      // PlaybackInfo 拿不到不算致命：HLS 那条 URL 少带一个参数而已
      host.log.warn('emby: PlaybackInfo 失败，MediaSourceId 留空 — ' + String(e && e.message ? e.message : e));
    }
    if (ms) storeSet(ck, ms);
    return ms;
  }

  // ── 对外方法 ───────────────────────────────────────────────────────
  async function home() {
    var vs;
    try {
      vs = await views();
    } catch (e) {
      var msg = String((e && e.message) ? e.message : e);
      return [{
        id: 'emby-setup',
        title: 'Emby：' + msg.replace(/^[a-z_]+:\s*/i, '').slice(0, 80),
        source: { type: 'category', categoryId: UNCONFIGURED },
        items: []
      }];
    }
    if (!vs.length) {
      return [{
        id: 'emby-empty',
        title: 'Emby 服务器上一个媒体库都没有',
        source: { type: 'category', categoryId: UNCONFIGURED },
        items: []
      }];
    }
    var out = [];
    for (var i = 0; i < vs.length; i++) {
      out.push({
        id: 'emby-lib-' + vs[i].id,
        title: vs[i].name,
        source: { type: 'category', categoryId: vs[i].id },
        items: []
      });
    }
    return out;
  }

  async function categories() {
    try {
      var vs = await views();
      var out = [];
      for (var i = 0; i < vs.length; i++) {
        out.push({ id: vs[i].id, name: vs[i].name, children: [] });
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  async function list(req) {
    var catId = (req && req.categoryId) ? String(req.categoryId) : '';
    var page = Math.max(1, parseInt((req && req.page) || 1, 10) || 1);
    if (!catId || catId === UNCONFIGURED) return emptyPage(page);
    var s = await session(false);
    var q = '/Users/' + enc(s.userId) + '/Items' +
            '?ParentId=' + enc(catId) +
            '&Recursive=true' +
            '&IncludeItemTypes=' + enc(LIST_TYPES) +
            '&Fields=' + enc(ITEM_FIELDS) +
            '&SortBy=SortName&SortOrder=Ascending' +
            '&Limit=' + PAGE_SIZE + '&StartIndex=' + ((page - 1) * PAGE_SIZE);
    return pageFrom(await apiGet(q), page, PAGE_SIZE);
  }

  async function search(keyword, page) {
    var kw = String(keyword == null ? '' : keyword).trim();
    var p = Math.max(1, parseInt(page || 1, 10) || 1);
    if (!kw) return emptyPage(p);
    var s = await session(false);
    var q = '/Users/' + enc(s.userId) + '/Items' +
            '?Recursive=true' +
            '&SearchTerm=' + enc(kw) +
            '&IncludeItemTypes=' + enc(SEARCH_TYPES) +
            '&Fields=' + enc(ITEM_FIELDS) +
            '&Limit=' + PAGE_SIZE + '&StartIndex=' + ((p - 1) * PAGE_SIZE);
    return pageFrom(await apiGet(q), p, PAGE_SIZE);
  }

  function episodeTitle(e) {
    var n = '';
    if (e && e.ParentIndexNumber != null && e.IndexNumber != null) {
      n = 'S' + String(e.ParentIndexNumber) + 'E' + String(e.IndexNumber) + ' · ';
    } else if (e && e.IndexNumber != null) {
      n = '第 ' + String(e.IndexNumber) + ' 集 · ';
    }
    return n + String((e && e.Name) || '正片');
  }

  async function detail(id) {
    var itemId = String(id == null ? '' : id).trim();
    if (!itemId) throw new Error('not_found: 空 id');
    var s = await session(false);
    var j;
    try {
      j = await apiGet('/Users/' + enc(s.userId) + '/Items/' + enc(itemId) + '?Fields=' + enc(DETAIL_FIELDS));
    } catch (e) {
      var msg = String((e && e.message) ? e.message : e);
      if (msg.indexOf('404') >= 0) {
        throw new Error('not_found: Emby 上没有这个条目（' + itemId + '）');
      }
      throw e;
    }
    if (!j || !j.Id) throw new Error('not_found: Emby 返回里没有条目（' + itemId + '）');

    var type = String(j.Type || '');
    var d = {
      id: itemId,
      title: String(j.Name || '未命名'),
      cover: coverUrl(j),
      description: String(j.Overview || ''),
      kind: kindOf(j),
      meta: {
        source: 'Emby',
        type: type || '未知',
        year: j.ProductionYear ? String(j.ProductionYear) : '',
        runtime: ticksToMinutes(j.RunTimeTicks) ? (String(ticksToMinutes(j.RunTimeTicks)) + ' 分钟') : '',
        rating: j.CommunityRating ? String(j.CommunityRating) : ''
      },
      sources: [{ code: 'emby', title: 'Emby 服务器', count: 1 }],
      episodes: []
    };

    if (type === 'Series') {
      try {
        var ej = await apiGet('/Shows/' + enc(itemId) + '/Episodes?UserId=' + enc(s.userId) +
                              '&Fields=' + enc('Overview,RunTimeTicks,ImageTags,ProductionYear,IndexNumber,ParentIndexNumber'));
        var raw = (ej && ej.Items) ? ej.Items : [];
        var order = 1;
        for (var i = 0; i < raw.length; i++) {
          var e2 = raw[i];
          if (!e2 || !e2.Id) continue;
          d.episodes.push({ id: String(e2.Id), title: episodeTitle(e2), order: order++ });
        }
      } catch (e3) {
        // 拿不到集列表也不该让详情整页失败 —— 给一个能播的入口
        host.log.warn('emby: 取集列表失败 — ' + String(e3 && e3.message ? e3.message : e3));
      }
      if (!d.episodes.length) {
        d.episodes.push({ id: itemId, title: '第 1 集', order: 1 });
      }
    } else {
      d.episodes.push({ id: itemId, title: '正片', order: 1 });
    }
    return d;
  }

  async function resolve(id, req) {
    var s = await session(false);
    var epId = (req && req.episodeId) ? String(req.episodeId) : '';
    var itemId = epId || String(id == null ? '' : id);
    if (!itemId) throw new Error('not_found: 空 id');

    var ms = await mediaSourceId(itemId);
    var base = baseUrl();
    var key = 'api_key=' + enc(s.token);

    var direct = {
      url: base + '/Videos/' + enc(itemId) + '/stream?static=true&' + key,
      kind: 'mp4',
      quality: '直连原画'
    };

    var hlsUrl = base + '/Videos/' + enc(itemId) + '/master.m3u8?' + key +
                 '&VideoCodec=h264&AudioCodec=aac&TranscodingProtocol=hls';
    if (ms) hlsUrl = hlsUrl + '&MediaSourceId=' + enc(ms);
    var hls = { url: hlsUrl, kind: 'hls', quality: '转码 HLS' };

    // 两条都给，播放失败时用户可以换线；开关只决定谁排第一
    return transcodeOn() ? [hls, direct] : [direct, hls];
  }

  async function loginCmd(username, password) {
    var base = baseUrl();
    if (!base) throw new Error('unsupported: 还没有填 Emby 服务器地址');
    var text = await host.http.post(base + '/Users/AuthenticateByName',
      JSON.stringify({ Username: String(username || ''), Pw: String(password || '') }), {
        headers: {
          'X-Emby-Authorization': authHeader(null),
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        }
      });
    if (errText(text)) {
      var rest = String(text).slice(7);
      if (rest.indexOf('401') >= 0 || rest.indexOf('400') >= 0) {
        throw new Error('unauthorized: Emby 用户名或密码不对（' + rest.slice(0, 120) + '）');
      }
      throw new Error('network: ' + rest);
    }
    var j = JSON.parse(text);
    if (!j || !j.AccessToken) throw new Error('unauthorized: 登录没有返回 AccessToken');
    storeSet('token', j.AccessToken);
    storeSet('userId', (j.User && j.User.Id) ? String(j.User.Id) : '');
    storeSet('userName', (j.User && j.User.Name) ? String(j.User.Name) : String(username || ''));
    return { token: String(j.AccessToken), displayName: (j.User && j.User.Name) ? String(j.User.Name) : '' };
  }

  async function logout() {
    storeDel('token');
    storeDel('userId');
    storeDel('userName');
    storeDel('views');
    storeDel('viewsAt');
  }

  async function sessionCmd() {
    var s = savedSession();
    if (!s) return null;
    return { token: s.token, displayName: s.userName };
  }

  async function refreshSession() {
    return await sessionCmd();
  }

  async function canAutoLogin() {
    return savedSession() !== null;
  }

  globalThis.plugin = {
    id: 'emby',
    capabilities: {
      vod: true,
      search: true,
      serverSideHistory: true,
      favorites: true,
      multiSource: false
    },
    config: [
      {
        key: 'serverUrl',
        label: '服务器地址',
        kind: 'text',
        default: '',
        placeholder: 'http://192.168.1.10:8096',
        hint: '安卓模拟器里访问本机请填 http://10.0.2.2:8096；局域网填真实 IP'
      },
      { key: 'username', label: '用户名', kind: 'text', default: '' },
      { key: 'password', label: '密码', kind: 'password', default: '' },
      {
        key: 'transcode',
        label: '优先转码',
        kind: 'switch',
        default: false,
        hint: '打开后优先用服务器转码（HLS）：兼容性更好，但吃服务器 CPU；关着走直连原画'
      },
      {
        key: 'note',
        label: '说明',
        kind: 'info',
        hint: 'Emby 只提供片源。弹幕 / 字幕 / 投屏都是本机功能，和 Emby 无关。'
      }
    ],
    home: home,
    categories: categories,
    list: list,
    search: search,
    detail: detail,
    resolve: resolve,
    login: loginCmd,
    logout: logout,
    session: sessionCmd,
    refreshSession: refreshSession,
    canAutoLogin: canAutoLogin
  };
})();
