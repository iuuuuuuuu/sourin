// ═══════════════════════════════════════════════════════════════════════
//  本地 Referer 注入代理（投屏防盗链） —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有它（不是"优化"，是"没有就投不了"）
//
// 原版 D:\WishProject\cctv_to_client\src-tauri\src\streamproxy.rs 的文件头
// 记录了一组实测结论（第 10-22 行）：
//
// ```text
//   央视直播源    无防盗链，直连可播
//   B 站 CDN      只认 Referer：
//                   只带 UA      → HTTP 403
//                   只带 Referer → HTTP 206（正常）
//                   两个都不带   → HTTP 403
// ```
//
// 投屏时电视是自己去拉那个 URL 的 —— 它**不可能**带我们 App 才知道的
// Referer。所以把原始 URL 直接投过去，B 站源 100% 黑屏。
//
// 解法：App 内起一个 HTTP 代理，把原始 URL 注册进去并绑定附加头；
// 投给电视的是 `http://<手机在局域网里的地址>:PORT/m/<token>`。
// 电视来拉 → 代理补上 Referer/UA 转发给上游 → 边收边转发给电视。
//
// ⚠️ 主机名必须是**电视能访问到的那个地址**：手机自己的 127.0.0.1 对电视来说
//    是它自己的回环口，投 `http://127.0.0.1:PORT/...` 过去电视必然 716 黑屏。
//    原版 streamproxy.rs 之所以能用回环，是因为拉流的是同一台机器上的播放器；
//    投屏的客户端是**另一台设备**，两者不是一回事。
//    ⇒ 绑定用 anyIPv4，投出去的主机名用局域网 IPv4（见 pickLanAddress）。
//
// # 从 streamproxy.rs 抄来的 4 条设计（都有理由，别改）
//
// ```text
// 1. 代理只认「登记过的 token」，路径里没有原始 URL ⇒ 同网段的人即使连上这个
//    端口，也只能拿到我们主动登记的那几条流，不能拿它当任意 URL 的跳板。
//    （原版用「只监听回环」来防这件事；投屏场景必须让电视可达，所以改成
//      token + 随机 16 字节来防。）
// 2. 路径里是 token 而不是原始 URL —— 原始 URL 会被电视写进日志/上报；
//    而且暴露"能代理任意 URL"这件事本身就危险。token 是随机 16 字节。
// 3. 必须透传 Range 与 206/416 —— 否则电视拖进度条只能从头开始
//    （电视拖进度时会重发带 Range 的 GET，代理丢掉 Range 就等于回了个完整文件）。
// 4. 响应头挑着转发 —— 不能整体 copy。上游的 Set-Cookie / ACAO /
//    Transfer-Encoding 透给电视会出各种怪问题（尤其 TE: chunked 会让
//    HttpClient 二次分块）。
// ```
//
// # ★ 点播（R1 修复，2026-10-05）：播放列表必须改写
//
// 点播的流地址**本身就已经是核心层的回环代理地址**
// （`http://127.0.0.1:<corePort>/s/<token>/`，见 rust/sourin_core/src/streamproxy.rs:398），
// 而核心层返回 m3u8 时会把里面的子地址**也改写成它自己的回环地址**
// （streamproxy.rs:1880 `rewrite_playlist(&text, upstream_url, &local_base)`，
//  `local_base = http://127.0.0.1:<corePort>/p/<hdrToken>/`）。
//
// 外层代理（本文件）原先**逐字节透传**响应体 ⇒ 电视拿到的那份 m3u8 里全是
// `http://127.0.0.1:<corePort>/...` ⇒ 那是**电视自己的回环口** ⇒ 必然拉不到。
// 表现是「SetAVTransportURI 成功、Play 成功，然后卡住黑屏」，**不是** 716 ——
// 因为第一跳（`/m/<token>`）是通的，死在 m3u8 内部的分片地址上。
//
// ⇒ 响应是播放列表时改写（`_relay` → `rewritePlaylist`）：
// ```text
//   http://127.0.0.1:<p>/<rest>   →  http://<lan-ip>:<本代理端口>/x/<p>/<rest>
//   /a/b.ts（根相对）              →  先按 RFC 3986 相对播放列表 URL 解析，再按上一条改写
//   a/b.ts（相对路径）             →  同上
//   https://cdn.com/a.ts（完整 URL）→  **不动**（跨主机分片，电视直连；这类分片不要 Referer）
// ```
//   新增路由 `/x/<port>/<rest>` ⇒ 原样转发到 `http://127.0.0.1:<port>/<rest>`，
//   **不注入任何附加头**（这一跳的目标是核心层代理，Referer/UA 由它自己带）。
//   目标主机写死 127.0.0.1 + 端口限 1..65535 + 只允许 GET/HEAD ⇒ 不是"任意 URL 跳板"。
//
// ⚠️ 二进制流（mp4/ts/图片）**继续逐字节边收边发**，一个字节都不许读进内存；
//    只有候选播放列表（content-type 含 mpegurl，或缺 content-type / `text/*`）才整读，
//    且整读有 `kPlaylistMaxBytes` 上限，超限立刻转回流式转发。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'dlna_http.dart';

// ═══════════════════════════════════════════════════════════════════════
//  ★ 播放列表改写的常量（R1 修复）
// ═══════════════════════════════════════════════════════════════════════

/// 回环分片改写后的路由前缀：`/x/<port>/<rest>`
///
/// 用 `x` 而不是 `loop`：这个前缀会出现在**电视收到的 m3u8** 里（一行几百字符），
/// 短前缀少占带宽、也少一次误判的机会。`m` 已被 token 路由占用，`p` 是核心层的写法。
const String kLoopPrefix = 'x';

/// 只有**候选**播放列表才允许先缓冲进内存的上限
///
/// 候选判定 = content-type 含 `mpegurl` / `text/*`，
/// 或（没有 content-type 或 `application/octet-stream`）且路径以 `.m3u8`/`.m3u` 结尾。
/// 真 m3u8 通常几 KB ~ 几百 KB（VOD 清单可能到 1 MB 量级），16 MB 足够。
/// 超过就**立刻切回「边收边发」**（已缓冲的部分先写出去，剩下的边收边发）——
/// 绝不为了改写把一个 2 GB 的 mp4 读进内存，也绝不丢字节。
const int kPlaylistMaxBytes = 16 * 1024 * 1024;

/// content-type 里出现这些词就是播放列表（大小写不敏感）
const List<String> kPlaylistTypeMarkers = <String>['mpegurl'];

// ═══════════════════════════════════════════════════════════════════════
//  注册项
// ═══════════════════════════════════════════════════════════════════════

/// 一个被代理的媒体源
/// 取一个**电视能访问到的**本机 IPv4 地址。
///
/// 为什么不能直接用 127.0.0.1：那是手机自己的回环口。电视拿着这个地址去拉流，
/// 等于让电视拉它自己，必然失败（实测表现就是 UPnP 716）。
///
/// 拿不到就抛 —— 绝不退回 127.0.0.1 假装成功：投过去必然黑屏，
/// 不如在投之前就说清楚「这台手机现在没有可用的局域网地址」。
Future<String> pickLanAddress() async {
  try {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    // 按接口名排优先级：投屏的目标（电视）几乎总在同一 Wi-Fi 上，
    // 而 Android 上还可能有 rmnet（蜂窝）、tun（VPN）、各种虚拟网卡，
    // 随便挑一个的结果是「地址看起来对，但电视根本连不上」。
    int rank(String name) {
      final n = name.toLowerCase();
      if (n.startsWith('wlan')) return 0;
      if (n.startsWith('eth')) return 1;
      if (n.startsWith('en')) return 2;
      return 3;
    }

    final candidates = <({int r, String addr})>[];
    for (final i in ifaces) {
      for (final a in i.addresses) {
        if (a.type != InternetAddressType.IPv4) continue;
        if (a.isLoopback || a.isLinkLocal) continue;
        candidates.add((r: rank(i.name), addr: a.address));
      }
    }
    if (candidates.isEmpty) {
      throw DlnaException(
        '这台手机现在没有局域网地址（Wi-Fi 或热点没连上？），没法把流投给电视。',
      );
    }
    candidates.sort((a, b) => a.r.compareTo(b.r));
    return candidates.first.addr;
  } on DlnaException {
    rethrow; // 自己抛的（没地址）原样上去，别包成「网络故障」
  } on Object catch (e) {
    throw DlnaException('读取本机网络地址失败：$e');
  }
}

class ProxyEntry {
  ProxyEntry({
    required this.token,
    required this.url,
    required this.headers,
    required this.createdAt,
    required this.label,
  });

  final String token;

  /// 上游真实地址（**绝不回给客户端**）
  final String url;

  /// 注入给上游的附加头（Referer / User-Agent / Cookie…）
  final Map<String, String> headers;

  final DateTime createdAt;

  /// 日志用的可读名（如"第 3 集"）
  final String label;

  /// 给电视的地址路径
  String get path => '/m/$token';
}

// ═══════════════════════════════════════════════════════════════════════
//  代理
// ═══════════════════════════════════════════════════════════════════════

/// 只监听回环的媒体代理
///
/// 生命周期：`start()` 一次（端口 0 让系统分配），`register()` 任意次，
/// App 退出/停止投屏时 `stop()`。
class MediaProxy {
  MediaProxy({this.onLog});

  final void Function(String line)? onLog;

  HttpServer? _server;
  final Map<String, ProxyEntry> _entries = {};
  final Random _rng = Random.secure();

  /// 上游请求客户端 —— **共享一个**（streamproxy.rs 也是这么做的：
  /// 每集都新建 HttpClient 会攒下一堆 TIME_WAIT 连接，电视那边表现为"卡住"）
  HttpClient? _upstream;

  /// 投给电视时用的主机名（局域网 IPv4）。绑 anyIPv4 之后这里才可能是非回环。
  String? _lanAddress;

  int _hits = 0;
  int _rewritten = 0;

  /// 已接的请求数（诊断/测试用）
  int get hits => _hits;

  /// 已改写过的播放列表数（诊断/测试用）
  int get rewrittenCount => _rewritten;

  /// 本代理的**局域网基址**（如 `http://192.168.1.5:45678`），未启动时为 null
  String? get lanBase {
    final s = _server;
    final lan = _lanAddress;
    if (s == null || lan == null) return null;
    return 'http://$lan:${s.port}';
  }

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  int get entryCount => _entries.length;

  List<ProxyEntry> get entries => List.unmodifiable(_entries.values);

  void _log(String line) => onLog?.call(line);

  // ── 启动 ──

  /// 起代理（幂等：已启动则直接返回现有端口）
  ///
  /// ★ 绑 `anyIPv4` 而不是 `loopbackIPv4`：拉流的是**另一台设备**（电视），
  ///   它连不上手机的 127.0.0.1。对外暴露的风险由 token 承担（路径里没有原始 URL，
  ///   只有随机 token ⇒ 同网段的人也只能拿到我们主动登记的那几条流）。
  Future<int> start() async {
    final s = _server;
    if (s != null) return s.port;
    // 先算地址：拿不到就抛，此时对象仍是「没启动」的干净状态
    final lan = await pickLanAddress();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _lanAddress = lan;
    _server = server;
    _upstream = HttpClient();
    // ⚠️ 这里**故意不设 connectionTimeout / 不设整体 timeout**：
    //    投屏是长时间的大文件流，设了整体超时会在播到一半时把连接掐了。
    //    只管空闲连接的回收。
    _upstream!.idleTimeout = const Duration(seconds: 30);
    _upstream!.autoUncompress = false;
    _upstream!.maxConnectionsPerHost = 8;
    server.listen(_handle, onError: (Object e) => _log('[代理] 监听错误：$e'));
    _log('[代理] 已启动 http://$_lanAddress:${server.port}（监听全部网卡，只认登记过的 token）');
    return server.port;
  }

  /// 停掉代理并清空注册表
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _lanAddress = null;
    _entries.clear();
    _upstream?.close(force: true);
    _upstream = null;
    if (s != null) {
      await s.close(force: true);
      _log('[代理] 已停止');
    }
  }

  // ── 注册 ──

  /// 登记一个媒体源，返回**给电视用的完整地址**
  ///
  /// [headers] 里的头会覆盖同名默认头。典型用法：
  /// ```dart
  /// final u = proxy.register(url, {'Referer': 'https://www.bilibili.com/'});
  /// ```
  Future<String> register(
    String url, {
    Map<String, String> headers = const {},
    String label = '',
  }) async {
    // ★ 只接受 http/https：本地文件路径、magnet、rtsp 这些
    //   "看起来像 URL" 的东西转给电视只会得到一个 716，
    //   不如在这里就说清楚（而且能挡住 file:// 这类本地读取）。
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      throw DlnaException('这个地址不能投屏（只支持 http/https）：$url');
    }
    final port = await start();
    final token = _newToken();
    final e = ProxyEntry(
      token: token,
      url: url,
      headers: Map<String, String>.from(headers),
      createdAt: DateTime.now(),
      label: label.isEmpty ? url : label,
    );
    _entries[token] = e;
    _log('[代理] 登记 ${e.label}（token ${token.substring(0, 8)}…）'
        '附加头 ${e.headers.isEmpty ? '无' : e.headers.keys.join(',')}');
    return 'http://$_lanAddress:$port${e.path}';
  }

  /// 撤销一个 token（换集/停止投屏时用）
  void unregister(String token) {
    if (_entries.remove(token) != null) {
      _log('[代理] 撤销 token ${token.substring(0, 8)}…');
    }
  }

  /// 从给电视的地址反查注册项（测试/诊断用）
  ProxyEntry? entryFor(String proxyUrl) {
    try {
      final segs = Uri.parse(proxyUrl).pathSegments;
      if (segs.length < 2) return null;
      return _entries[segs[1]];
    } catch (_) {
      return null;
    }
  }

  String _newToken() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  // ── 处理请求 ──

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;

    // 健康检查：让 App/测试能确认代理活着（也便于 adb forward 探测）
    if (path == '/ping') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text;
      req.response.write('sourin-cast-proxy ok entries=${_entries.length}');
      await req.response.close();
      return;
    }

    // ── ★ 回环中转（R1 修复）：/x/<port>/<rest> → http://127.0.0.1:<port>/<rest> ──
    //
    // 电视拿到我们改写过的 m3u8 后，会来拉这个路径。这里**不注入任何附加头**：
    // 上游是**手机自己的核心层代理**，Referer/UA 由它按登记表自己带；
    // 我们从电视那边继承来的头（尤其是电视自己的 User-Agent）反而会干扰它。
    final segs = req.uri.pathSegments;
    if (segs.isNotEmpty && segs[0] == kLoopPrefix) {
      await _relayLoopback(req, segs);
      return;
    }

    if (segs.length < 2 || segs[0] != 'm') {
      await _plain(req, HttpStatus.notFound, '未知路径：$path');
      return;
    }
    final e = _entries[segs[1]];
    if (e == null) {
      // ★ 如实说"token 失效"，不要说 404 空响应 —— 否则电视那边只显示"播放失败"，
      //   用户和我们都不知道是 token 过期还是源挂了。
      await _plain(req, HttpStatus.gone, '这个投屏地址已失效（token 未登记或已撤销）');
      return;
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      await _plain(req, HttpStatus.methodNotAllowed, '只支持 GET/HEAD');
      return;
    }
    _hits++;
    // `/m/<token>/<rest>` 的 `<rest>` 按**相对登记地址**拼回去（见 _subTarget）
    await _forward(req, e, target: _subTarget(req, e));
  }

  /// 把 `/x/<port>/<rest>` 原样转发到 `http://127.0.0.1:<port>/<rest>`
  ///
  /// 用途只有一个：让**电视**能拿到核心层代理（跑在手机回环口上）产出的分片/子清单。
  ///
  /// 安全性：目标主机**写死 127.0.0.1**、端口限 1..65535、只允许 GET/HEAD ⇒
  /// 拿不到"任意 URL 跳板"的能力（这也是不把整条 URL 塞进路径的原因）。
  Future<void> _relayLoopback(HttpRequest req, List<String> segs) async {
    if (req.method != 'GET' && req.method != 'HEAD') {
      await _plain(req, HttpStatus.methodNotAllowed, '只支持 GET/HEAD');
      return;
    }
    if (segs.length < 3) {
      await _plain(req, HttpStatus.badRequest, '回环中转路径要写成 /$kLoopPrefix/<端口>/<路径>');
      return;
    }
    final port = int.tryParse(segs[1]);
    if (port == null || port < 1 || port > 65535) {
      await _plain(req, HttpStatus.badRequest, '回环中转的端口不合法：${segs[1]}');
      return;
    }
    // ★ 用 `req.uri.path` 而不是 `pathSegments.join('/')` ——
    //   `pathSegments` 是**解码后**的（`%2F` 会变回 `/`、`%20` 变空格），
    //   重新拼出来就不是原来的路径了。`path` 保持百分号编码。
    final path = req.uri.path;
    final prefix = '/$kLoopPrefix/${segs[1]}';
    var rest = path.startsWith(prefix) ? path.substring(prefix.length) : path;
    if (rest.isEmpty) rest = '/';
    if (!rest.startsWith('/')) rest = '/$rest';
    final query = req.uri.query;
    final target = Uri.parse('http://127.0.0.1:$port$rest${query.isEmpty ? '' : '?$query'}');
    _hits++;
    _log('[代理] ↻ 回环中转 → $target');
    await _pump(req, target, const <String, String>{}, label: '回环中转');
  }

  Future<void> _plain(HttpRequest req, int code, String msg) async {
    req.response
      ..statusCode = code
      ..headers.contentType = ContentType.text;
    req.response.write(msg);
    await req.response.close();
  }

  /// `/m/<token>/<rest>` 的 `<rest>` 要拼回登记地址（**相对**语义，不是 RFC 根相对）
  ///
  /// 为什么需要它：播放列表里如果有**相对路径**的子地址（`seg1.ts`），电视会把它
  /// 解析成 `http://<lan>:<port>/m/<token>/seg1.ts` —— 走到这里。而 `/m/<token>/`
  /// 就是登记地址的"目录"，所以要把 `rest` 相对**登记地址**拼回去
  /// （与核心层 `/s/<token>/<rest>` 的 `join_subpath` 是同一套语义）。
  ///
  /// ⚠️ 拼出来的目标仍以登记地址为 base（`resolveUrl`）⇒ **换不了主机**，
  ///    不是"任意 URL 跳板"。没有子路径时返回 null（用登记地址本身）。
  Uri? _subTarget(HttpRequest req, ProxyEntry e) {
    final prefix = '/m/${e.token}';
    if (!req.uri.path.startsWith(prefix)) return null;
    var rest = req.uri.path.substring(prefix.length);
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    if (rest.isEmpty) return null;
    // 保留百分号编码（`req.uri.path` 不解码；`pathSegments` 会解码）
    final query = req.uri.query;
    final joined = resolveUrl(rest + (query.isEmpty ? '' : '?$query'), e.url);
    return joined == null ? null : Uri.tryParse(joined);
  }

  /// 转发一次登记过的流（含 Range 透传、播放列表改写）
  Future<void> _forward(HttpRequest req, ProxyEntry e, {Uri? target}) async {
    final up = target ?? Uri.tryParse(e.url);
    if (up == null) {
      await _plain(req, HttpStatus.badGateway, '登记的上游地址解析失败：${e.url}');
      return;
    }
    await _pump(req, up, e.headers, label: e.label);
  }

  /// 真正的一次转发（`_forward` 与 `_relayLoopback` 共用）
  ///
  /// [headers] 是要注入上游的附加头（空 Map = 一个都不加）；
  /// 响应是播放列表时整读改写（见 `rewritePlaylist`），其余**一律边收边发**。
  Future<void> _pump(
    HttpRequest req,
    Uri target,
    Map<String, String> headers, {
    String label = '',
  }) async {
    final client = _upstream;
    if (client == null) {
      await _plain(req, HttpStatus.serviceUnavailable, '代理未启动');
      return;
    }
    final tag = label.isEmpty ? target.toString() : label;
    HttpClientRequest? up;
    try {
      up = await client.getUrl(target);
      // ── 注入附加头（这是整个代理存在的理由；回环中转传空 Map = 一个都不加）──
      headers.forEach(up.headers.set);
      // ── Range 透传 ──
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
      // ── 其余按需透传（能影响上游取流行为的那几个）──
      for (final h in const ['if-range', 'accept', 'accept-language']) {
        final v = req.headers.value(h);
        if (v != null) up.headers.set(h, v);
      }
      // ⚠️ **绝不转发 Host**：Host 必须是上游的主机名，转发成
      //    127.0.0.1:port 会让上游 CDN 直接 403/回错站。HttpClient 自己
      //    按 URL 设 Host，所以这里什么都不用做 —— 但别"顺手 copy 全部头"。
      up.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      up.followRedirects = true;
      up.maxRedirects = 5;

      final res = await up.close();
      _log('[代理] ← 上游 HTTP ${res.statusCode}（Range: ${range ?? '无'}）$tag');

      final out = req.response;
      out.statusCode = res.statusCode;
      _copyHeaders(res, out);
      if (req.method == 'HEAD') {
        await out.close();
        await res.drain<void>();
        return;
      }
      // ★ 播放列表（点播 R1）：整读改写。
      //   ⚠️ 必须在**任何字节写给电视之前**决定，且 `_copyHeaders` 只透传了
      //      content-type（content-length 本来就被跳过），所以这里改长度是安全的。
      if (_isPlaylistCandidate(res, target)) {
        final r = await _drain(res, out);
        final text = r.text;
        if (text != null) {
          // lanBase 为 null 只可能是「上游自己就是本代理」（回环中转）——
          // 那种情况下把回环地址换成回环地址，改写仍是等价的。
          final base = lanBase ?? 'http://127.0.0.1:$port';
          final rewritten = rewritePlaylist(text, target.toString(), base);
          _rewritten++;
          _log('[代理] ✎ 播放列表已改写：${text.length} → ${rewritten.length} 字符');
          final bytes = utf8.encode(rewritten);
          // ⚠️ 必须在写正文**之前**改长度：content-length 随首字节发出后就改不动了。
          out.headers.contentLength = bytes.length;
          out.add(bytes);
          await out.close();
          return;
        }
        // 超上限：`_drain` 已经转成"边收边发"（缓冲的字节原样写出，一个字节没丢）。
        // 不完整改写，但至少不是空响应 —— 电视侧可能出现 127.0.0.1 子地址。
        _log('[代理] ✗ 播放列表超过 $kPlaylistMaxBytes 字节（已读 ${r.read}），'
            '转为原样流式转发：改写不完整，点播可能失败');
        await out.close();
        return;
      }
      // 边收边发：不要 await res.fold 把整个文件读进内存 ——
      // 一部电影 2GB，读进来手机直接 OOM。
      await res.forEach(out.add);
      await out.close();
    } on Object catch (err) {
      _log('[代理] ✗ 转发失败：$err（$target）');
      try {
        // 头可能已经发出去了（流已经开始），此时改状态码会抛异常 —— 忽略
        if (req.response.headers.contentLength == -1) {
          req.response.statusCode = HttpStatus.badGateway;
        }
        req.response.write('代理转发失败：$err');
        await req.response.close();
      } catch (_) {
        // 已经关了就什么都不做
      }
    }
  }

  /// 这个响应**可能是** HLS 播放列表吗？（只有"可能"才会整读）
  ///
  /// ★ 为什么用**保守**的判定：误判的代价是不对称的 ——
  ///   · 把 mp4 误判成播放列表 ⇒ 整个文件进内存 ⇒ 手机 OOM
  ///   · 把 m3u8 漏判 ⇒ 回到今天这个 bug（电视黑屏）
  ///   所以「有 content-type 且不是 mpegurl/text」⇒ **直接不是**（octet-stream 例外，
  ///   那种情况 CDN 常用来发 m3u8，只能退回看路径后缀）。
  ///   （核心层代理改写后会返回 `application/vnd.apple.mpegurl`，命中第一条。）
  bool _isPlaylistCandidate(HttpClientResponse res, Uri target) {
    if (res.statusCode != HttpStatus.ok) return false; // 206/416 都是媒体分片
    final ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
    for (final m in kPlaylistTypeMarkers) {
      if (ct.contains(m)) return true;
    }
    if (ct.isNotEmpty) {
      if (ct.startsWith('text/')) return true;
      // ★ `application/octet-stream` 是**唯一**允许「退回看后缀」的非 text 类型 ——
      //   CDN 常拿它发 m3u8（核心层那份 playlist 判定也把后缀算进去）。
      //   其余类型（video/*、audio/*、image/*）**直接判否**：那才是「误判就 OOM」的一侧。
      if (ct != 'application/octet-stream') return false;
    }
    // content-type 缺失、或是 octet-stream 时：**只认路径后缀**，
    // 不再看首行（看首行要先读字节，而"要不要读"必须在读之前决定）。
    //    `application/vnd.apple.mpegurl`（核心层改写后的类型）走上面第一条。
    final p = target.path.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.m3u');
  }

  /// 先把播放列表候选体缓冲起来；**一旦超过上限就立刻切回边收边发**。
  ///
  /// 返回的 `text == null` 表示「超上限、已转流式」—— 此时**已经**把缓冲的字节
  /// 写进 [out] 了，调用方只许补日志，**不许再写正文**（否则字节重复）。
  ///
  /// ⚠️ 这里不做 `bytes.clear()` 之后复用同一个 List：`HttpResponse.add` 把 List
  ///    原样交给底层（不复制），后续清空会把还没写出去的字节抹掉。
  Future<({String? text, int read, bool over})> _drain(
    HttpClientResponse res,
    HttpResponse out,
  ) async {
    final bytes = <int>[];
    var read = 0;
    await for (final chunk in res) {
      read += chunk.length;
      if (bytes.length + chunk.length <= kPlaylistMaxBytes) {
        bytes.addAll(chunk);
        continue;
      }
      // ★ 超上限：已缓冲的部分原样写出，其余边收边发 —— 绝不丢字节。
      //   （旧实现直接 return null 放弃转发 ⇒ 电视收到空响应，日志还把"被截断"
      //     误报成"超大播放列表"。）
      out.add(bytes);
      out.add(chunk);
      await res.forEach(out.add);
      return (text: null, read: read, over: true);
    }
    // allowMalformed：真机上见过带 BOM / 混编码的清单，不能因为一个坏字节整条投屏失败
    return (text: utf8.decode(bytes, allowMalformed: true), read: read, over: false);
  }

  /// 响应头挑选转发
  ///
  /// ★ 只转这些 —— 白名单而不是黑名单，因为"新出现的头"永远猜不到。
  ///   特别是不转 `Transfer-Encoding`（Dart 的 HttpResponse 自己决定分块）
  ///   与 `Set-Cookie`（电视不需要、也不该拿到上游 cookie）。
  ///
  /// ⚠️ `Content-Length` 也**故意不转**（下面那个 continue）—— 这不是疏忽：
  ///   改写播放列表会改长度，透传上游的 CL 会把响应截断成半份。
  void _copyHeaders(HttpClientResponse from, HttpResponse to) {
    const keep = [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.cacheControlHeader,
      'content-disposition',
      'connection',
    ];
    for (final h in keep) {
      final v = from.headers.value(h);
      if (v == null) continue;
      // contentLength 由 Dart 自己按实际写入量设置；这里透传会与"边收边发"冲突
      if (h == HttpHeaders.contentLengthHeader) continue;
      if (h == 'connection') continue;
      to.headers.set(h, v);
    }
    // 206 时 Content-Range 是必须的（电视靠它确认拿到的是哪一段）
    if (from.statusCode == HttpStatus.partialContent) {
      final cr = from.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null) to.headers.set(HttpHeaders.contentRangeHeader, cr);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 播放列表改写（R1 修复，2026-10-05）
// ═══════════════════════════════════════════════════════════════════════

/// 把 m3u8 里的子地址改写成「电视能访问到」的地址
///
/// 只有**回环**的子地址需要改写。原因见文件头「点播 R1 修复」那一段：
/// 核心层代理把分片地址写成了 `http://127.0.0.1:<corePort>/...`，
/// 那是**电视自己的回环口**。
///
/// 改写规则（只改**有风险的**那几种，其余一个字都不动）：
/// ```text
///   http://127.0.0.1:<p>/<rest>    → http://<lan>:<port>/x/<p>/<rest>
///   http://localhost:<p>/<rest>    → 同上
///   /a/b.ts（根相对）               → 按 RFC 3986 相对 [base] 解析后，再按上面两条判
///   a/b.ts（相对路径）              → 同上
///   https://cdn.com/a.ts            → 不动（跨主机分片，电视直连，这类分片不要 Referer）
///   //cdn.com/a.ts（协议相对）       → 不动（同上）
/// ```
///
/// ★ 相对路径**必须**处理：核心层的 `rewrite_playlist` 会把每条 URI 绝对化
///   （见 rust/sourin_core/src/streamproxy.rs:2121 `to_local`），所以正常情况下
///   我们收到的都是完整 URL；但万一有漏网的相对路径，电视会把它解析到
///   `http://<lan>:<port>/<相对路径>` —— 那会 404。改写掉就等于替电视解析。
///
/// ★ 为什么相对路径的目标写回**本代理的路径**而不是直接写核心层地址：
///   因为电视是从**本代理**的 m3u8 里读到的这一行，相对路径的 base 就是本代理；
///   写回本代理（`/x/<port>/...`）语义完全一致，且不依赖电视能不能直连手机回环口。
String rewritePlaylist(String text, String base, String lanBase) {
  final origin = originOf(base);
  final lines = text.split('\n');
  final buf = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isNotEmpty) {
      if (line.startsWith('#')) {
        // 带 URI 属性的标签（`#EXT-X-KEY:...,URI="key.bin"`、`#EXT-X-MAP:URI="init.mp4"`）
        // 也要改写，否则加密流拿不到密钥、fMP4 拿不到 init 段。
        // ⚠️ 下标在**原行**上算，别在剥掉 `#` 的串上算（差 1 位会吃掉引号）。
        final pos = line.indexOf('URI="');
        if (pos < 0) {
          buf.write(line);
        } else {
          final valueStart = pos + 5;
          final after = line.substring(valueStart);
          final end = after.indexOf('"');
          if (end < 0) {
            buf.write(line);
          } else {
            buf.write(line.substring(0, valueStart));
            buf.write(_toLocalUri(after.substring(0, end), base, origin, lanBase));
            buf.write(after.substring(end));
          }
        }
      } else {
        buf.write(_toLocalUri(line, base, origin, lanBase));
      }
    }
    // ★ 换行按**原样**补：最后一行后面没有换行就不补。
    //   （旧写法对每个元素都补一个 `\n`，而 `split` 在结尾有换行时会多出一个空元素
    //     ⇒ 每份清单都被多吐一个空行。播放器不在意，但字节对不上不好查。）
    if (i < lines.length - 1) buf.write('\n');
  }
  return buf.toString();
}

/// 改写一条 URI（内部用；三种形态的判定与核心层 `to_local` 对齐）
String _toLocalUri(String uri, String base, String origin, String lanBase) {
  final u = uri.trim();
  if (u.isEmpty) return u;

  // ① 绝对化（RFC 3986 的 base 用**播放列表自己的 URL**）
  String abs;
  if (u.startsWith('http://') || u.startsWith('https://')) {
    abs = u;
  } else if (u.startsWith('//')) {
    final i = base.indexOf('://');
    abs = i < 0 ? u : '${base.substring(0, i)}://${u.substring(2)}';
  } else if (u.startsWith('/')) {
    abs = origin.isEmpty ? u : '$origin$u';
  } else {
    final resolved = resolveUrl(u, base);
    if (resolved == null) return u;
    abs = resolved;
  }

  // ② 只有回环地址才改写（跨主机分片保持原样：电视直连更快，且这类分片不要 Referer）
  final p = Uri.tryParse(abs);
  if (p == null) return u;
  final host = p.host.toLowerCase();
  if (host != '127.0.0.1' && host != 'localhost' && host != '::1') return u;

  // ③ 拼成 `/x/<port>/<path?query>`。
  //    ⚠️ 这里拼的是 **Uri 的 path**（`p.path` 不解码）——
  //    分片地址里常见 `?sign=abc%3D`、`%2F`，解码再编码会改掉字节。
  final q = p.query;
  return '$lanBase/$kLoopPrefix/${p.port}${p.path}${q.isEmpty ? '' : '?$q'}';
}

