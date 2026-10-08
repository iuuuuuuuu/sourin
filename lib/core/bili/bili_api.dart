
// ═══════════════════════════════════════════════════════════════════════
//  哔哩哔哩弹幕 API 客户端（免登录）—— task-28
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决什么
//
// 用户原话：「支持一下 哔哩哔哩填入链接导入弹幕，并且自动绑定剧集和
// 自动更新弹幕」。
//
// 三条端点（全部免登录、全部已实测）：
//   1. /x/web-interface/view?bvid=BV...
//      → title / aid / videos / pages[]（pages 里已经有 cid，多 P 全在这）
//   2. /x/player/pagelist?bvid=BV...
//      → 只要分 P；view 的 pages 为空时用它兜底
//   3. https://comment.bilibili.com/<cid>.xml
//      → 弹幕 XML，<d p="...">正文</d>
//
// 请求头：现在一条都不需要（实测裸请求就 200）。仍然带着 Referer + 移动端 UA
// （对前两条 JSON 端点有用，且成本为零）。
//
// # ★★ 2026-10-05 端点变更（Lead 实测）
//
// 原来的 /x/v1/dm/list.so?oid=<cid> 现在对**所有**请求头组合回 HTTP 412
// （3400 字节的 text/html 风控页）。试过七种，全部 412：
//   Referer+移动端 UA（原样）/ 全套浏览器头（Accept/Origin/Sec-Fetch-*）
//   / 自造 buvid3 cookie / 先去 www.bilibili.com 收真 Set-Cookie 再带
//   / 加 type=1 参数 / http:// 明文
// 证据：.probe/bili412/run1.txt 与 run2.txt。
//
// 替代端点 https://comment.bilibili.com/<cid>.xml 回 **200**，而且：
//   · 正文是**同样的裸 deflate**（47634 -> 126107，1200 条）
//   · XML 形状与 list.so 完全一致（同一个 <i>…<d p="…">…</d> 结构）
//   · 不带任何请求头也 200
//   · 多 P 照样按 cid 路由（42317974118 -> 221 条）
// 证据：.probe/bili412/run3.txt（六条对照，含 412 复测）。
//
// # ★★ 为什么不能直接用 lib/core/danmaku.dart 的 IoDanmakuTransport
//
// 实测（.probe/bili/recon_deflate.dart，四路对照）：
//
//   --- A) plain (autoUncompress 默认) ---
//     status=200 bytes=46770 ce=deflate ae_sent=gzip
//     head_bytes=b4 bd 79 73 1c 47 96 27      <-- 乱码
//   --- B) 显式 Accept-Encoding: identity ---
//     status=200 bytes=46770 ce=deflate ae_sent=identity   <-- 拦不住
//   --- C) zlib.decode ---
//     zlib.decode FAILED: FormatException: Filter error, bad data
//   --- D) raw-inflate ---
//     raw-inflate bytes=122675
//     head=<?xml version="1.0" encoding="UTF-8"?><i><chatserver>...
//
// 结论：dm/list.so 回的是**裸 deflate**（没有 zlib 头），而 Dart 的
// HttpClient.autoUncompress 只认 gzip（它自己发的是 Accept-Encoding: gzip），
// zlib.decode 会抛 FormatException。必须自己用
// RawZLibFilter.inflateFilter(raw: true) 解。
//
// IoDanmakuTransport 的正文是直接 Utf8Decoder 的（danmaku.dart:574-577），
// 没有 deflate 分支 ⇒ 这里另起一个 HttpClient，不复用它。
//
// # 零新依赖
//
// pubspec.yaml 里没有 http / crypto / xml（已核对）。所以：
//   · HTTP  → dart:io 的 HttpClient
//   · XML   → 本文件自带的扫描器（B 站这个 XML 的形状极固定，见下）
//
// # B 站弹幕 XML 的形状（实测 1200 条的样本）
//
//   整个文件**一行到底**（换行数 = 0），开头是
//   <?xml version="1.0" encoding="UTF-8"?><i><chatserver>...<d p="...">正文</d>
//
//   所以**不能**按行切，必须整串扫描。正文里可能出现任何字符，
//   包括引号、尖括号（已实体转义）。
//
// # p 属性是 9 段，与 dandanplay 的 4 段**不同**
//
//   时间秒,模式,字号,十进制颜色,时间戳,池,hash,弹幕ID,权重
//   0.60100,4,25,15138834,1604742895,0,9e5adeaa,40685126698926083,10
//
//   ⚠️ 颜色在第 4 段（下标 3）。danmaku.dart:178 的 DanmakuComment.parse
//   读的是 parts[2]（那是 dandanplay 的布局）⇒ **绝不能**把 B 站的 p 丢给它。
//   本文件自己解析，然后直接构造 DanmakuComment(...)。
//
//   模式直方图（该 1200 条样本）：{"1":815,"4":68,"5":309,"7":8}
//   模式 7（高级弹幕）真实存在，DanmakuMode.fromWire 会把它归 scroll。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../danmaku.dart';

/// 移动端 UA —— 实测能过 B 站的 UA 校验。
const String kBiliUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// 必须带的 Referer。缺了会被风控挡。
const String kBiliReferer = 'https://www.bilibili.com';

/// 搜索接口专用的 Referer
///
/// ★ 实测（2026-10-08，只读、无凭证）：同一个搜索端点，
///   ```text
///   Referer: https://www.bilibili.com     -> 200 + text/html（aba 风控页）★ 状态码是 200
///   Referer: https://search.bilibili.com/ -> 200 + application/json
///   不带 Referer                           -> 200 + application/json（不稳，别用）
///   ```
/// ⇒ 搜索**不能**复用 [kBiliReferer]，否则拿到的是一张网页。
///   状态码仍是 200，所以"非 2xx 才报错"的判断骗得过去 ——
///   解析层必须同时判 content-type / 首字符。
const String kBiliSearchReferer = 'https://search.bilibili.com/';

/// 一次最多吃多少条弹幕。
///
/// 为什么要有上限：热门视频的弹幕能到几十万条，全量塞进内存再交给
/// 排版器会卡住主 isolate。12000 条已经覆盖绝大多数正片。
const int kBiliMaxComments = 12000;

// ══════════════════════════════════════════════════════════════════════
//  一、输入解析：BV 号 / av 号 / 完整链接 / b23.tv 短链
// ══════════════════════════════════════════════════════════════════════

/// 用户输入里解析出来的视频定位信息。
class BiliRef {
  const BiliRef({
    this.bvid = '',
    this.aid = 0,
    this.page = 0,
    this.shortUrl = '',
    this.raw = '',
  });

  /// 形如 BV1GJ411x7h7；空串 = 未知。
  final String bvid;

  /// av 号；0 = 未知。
  final int aid;

  /// 分 P 号；0 = 未指定（取第 1 P）。
  final int page;

  /// b23.tv 短链（此时 bvid/aid 都为空，需要先解析跳转）。
  final String shortUrl;

  /// 用户原始输入（回显 / 排错用）。
  final String raw;

  /// 是否已经能直接打 API。
  bool get isResolved => bvid.isNotEmpty || aid > 0;

  /// 是否是短链、还需要一次跳转才能拿到 BV 号。
  bool get isShortLink => !isResolved && shortUrl.isNotEmpty;

  /// 拼给 view / pagelist 的查询串。
  String get query => bvid.isNotEmpty ? 'bvid=$bvid' : 'aid=$aid';

  /// 稳定的字符串标识，用于偏好键与去重。
  String get id => bvid.isNotEmpty ? bvid : 'av$aid';

  @override
  String toString() => 'BiliRef($bvid, av$aid, p$page)';
}

/// 从一段任意用户输入里抠出 BV 号 / av 号 / 分 P。
///
/// 支持这些形态（都实测过）：
///   · BV1GJ411x7h7
///   · av80433022 / AV80433022
///   · https://www.bilibili.com/video/BV1GJ411x7h7/?p=2
///   · https://www.bilibili.com/video/av80433022
///   · https://b23.tv/xxxxxxx            （返回 isShortLink = true）
///   · 夹在中文里的一整段话，例如「看看这个 https://... 挺好」
///
/// 解析不出来返回 null（调用方据此提示用户）。
BiliRef? parseBiliInput(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  // 1) BV 号。B 站的 BV 号是 BV + 10 位 base58 字符。
  final bv = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(s);
  if (bv != null) {
    return BiliRef(bvid: bv.group(0)!, page: _pageOf(s), raw: s);
  }

  // 2) av 号。加词边界，免得把 save123456789012 这种误判。
  final av = RegExp(r'(?:^|[^0-9A-Za-z])av(\d{1,12})', caseSensitive: false)
      .firstMatch(s);
  if (av != null) {
    final n = int.tryParse(av.group(1)!);
    if (n != null && n > 0) {
      return BiliRef(aid: n, page: _pageOf(s), raw: s);
    }
  }

  // 3) b23.tv 短链：只取 URL 部分，真正的 BV 号要发一次请求才知道。
  final short = RegExp(r'https?://b23\.tv/[0-9A-Za-z]+').firstMatch(s);
  if (short != null) {
    return BiliRef(shortUrl: short.group(0)!, page: _pageOf(s), raw: s);
  }

  return null;
}

/// 从链接里读 ?p=N（也认 _P2 / P2 这类写法）。
int _pageOf(String s) {
  final q = RegExp(r'[?&]p=(\d{1,5})').firstMatch(s);
  if (q != null) {
    final n = int.tryParse(q.group(1)!);
    if (n != null && n > 0) return n;
  }
  final p = RegExp(r'[_/]P(\d{1,5})(?:\D|$)').firstMatch(s);
  if (p != null) {
    final n = int.tryParse(p.group(1)!);
    if (n != null && n > 0) return n;
  }
  return 0;
}

// ══════════════════════════════════════════════════════════════════════
//  二、数据模型
// ══════════════════════════════════════════════════════════════════════

/// 一个分 P。
class BiliPage {
  const BiliPage({
    required this.cid,
    required this.page,
    this.part = '',
    this.duration = 0,
  });

  /// 弹幕接口要的就是它（oid = cid）。
  final int cid;

  /// 第几 P，从 1 开始。
  final int page;

  /// 分 P 标题。
  final String part;

  /// 时长（秒）。
  final int duration;

  /// 给用户看的短标签。
  String get label {
    if (page <= 1 && part.isEmpty) return 'P1';
    if (page <= 1) return part;
    return part.isEmpty ? 'P$page' : 'P$page $part';
  }

  static BiliPage? fromJson(Map<String, dynamic> j) {
    final cid = _int(j['cid']);
    if (cid <= 0) return null;
    return BiliPage(
      cid: cid,
      page: _int(j['page'], fallback: 1),
      part: _str(j['part']),
      duration: _int(j['duration']),
    );
  }

  @override
  String toString() => 'BiliPage(p$page, cid=$cid, $part)';
}

/// view 端点回来的视频信息。
class BiliVideoInfo {
  const BiliVideoInfo({
    required this.bvid,
    required this.aid,
    required this.title,
    this.cover = '',
    this.duration = 0,
    this.pages = const <BiliPage>[],
  });

  final String bvid;
  final int aid;
  final String title;
  final String cover;

  /// 总时长（秒）。多 P 时是各 P 之和。
  final int duration;

  final List<BiliPage> pages;

  bool get isMultiPart => pages.length > 1;

  /// 取第 [page] P（从 1 开始）；越界时退回第 1 P；一 P 都没有时返回 null。
  BiliPage? pageAt(int page) {
    if (pages.isEmpty) return null;
    for (final p in pages) {
      if (p.page == page) return p;
    }
    return pages.first;
  }

  @override
  String toString() =>
      'BiliVideoInfo($bvid, av$aid, $title, ${pages.length} P)';
}

// ══════════════════════════════════════════════════════════════════════
//  三、HTTP 层（含裸 deflate 解码）
// ══════════════════════════════════════════════════════════════════════

/// 一次原始响应的快照 —— 留给「真实请求证据」用。
class BiliHttpTrace {
  const BiliHttpTrace({
    required this.method,
    required this.uri,
    required this.status,
    required this.bytes,
    this.contentEncoding = '',
    this.contentType = '',
    this.elapsedMs = 0,
    this.note = '',
  });

  final String method;
  final String uri;
  final int status;

  /// **解码后**的字节数。
  final int bytes;
  final String contentEncoding;
  final String contentType;
  final int elapsedMs;

  /// 额外说明（例如 raw-deflate 46770->122675）。
  final String note;

  /// 一行给人看的记录。
  String get line {
    final b = StringBuffer('$method $uri -> $status bytes=$bytes');
    if (contentEncoding.isNotEmpty) b.write(' ce=$contentEncoding');
    if (contentType.isNotEmpty) b.write(' ct=$contentType');
    if (elapsedMs > 0) b.write(' $elapsedMs ms');
    if (note.isNotEmpty) b.write(' ($note)');
    return b.toString();
  }

  @override
  String toString() => line;
}

/// B 站 API 客户端。**用完记得 close()**。
class BiliApi {
  BiliApi({
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
    this.traceLimit = 40,
  }) : _client = client ?? _newClient();

  final HttpClient _client;
  final Duration timeout;

  /// 最多留多少条 trace（环形）。
  final int traceLimit;

  final List<BiliHttpTrace> _trace = <BiliHttpTrace>[];

  /// 最近若干次请求的记录（新的在后）。UI 的「真实请求证据」区读它。
  List<BiliHttpTrace> get trace => List<BiliHttpTrace>.unmodifiable(_trace);

  void clearTrace() => _trace.clear();

  static HttpClient _newClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15)
      // ★ 默认 true。它只解 gzip；deflate 由我们自己解。
      ..autoUncompress = true;
  }

  void close() => _client.close(force: true);

  void _remember(BiliHttpTrace t) {
    _trace.add(t);
    while (_trace.length > traceLimit) {
      _trace.removeAt(0);
    }
  }

  // ── 低层：一次 GET ─────────────────────────────────────────────────

  Future<_Raw> _get(Uri uri, {String referer = kBiliReferer}) async {
    final sw = Stopwatch()..start();
    final req = await _client.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.refererHeader, referer);
    req.headers.set(HttpHeaders.userAgentHeader, kBiliUserAgent);
    req.headers.set(HttpHeaders.acceptHeader, '*/*');

    final resp = await req.close().timeout(timeout);
    final raw = <int>[];
    await for (final chunk in resp.timeout(timeout)) {
      raw.addAll(chunk);
    }
    sw.stop();

    final ce =
        (resp.headers.value(HttpHeaders.contentEncodingHeader) ?? '')
            .toLowerCase();
    final ct = resp.headers.value(HttpHeaders.contentTypeHeader) ?? '';

    List<int> body;
    var note = '';
    if (ce.contains('deflate')) {
      // ★ 裸 deflate：zlib.decode 会抛 FormatException，必须 raw inflate。
      body = rawInflate(raw);
      note = 'raw-deflate ${raw.length} -> ${body.length}';
    } else {
      // gzip 已被 autoUncompress 解掉；identity 原样。
      body = raw;
    }

    _remember(BiliHttpTrace(
      method: 'GET',
      uri: uri.toString(),
      status: resp.statusCode,
      bytes: body.length,
      contentEncoding: ce,
      contentType: ct,
      elapsedMs: sw.elapsedMilliseconds,
      note: note,
    ));

    return _Raw(status: resp.statusCode, body: body, contentType: ct);
  }

  Future<Map<String, dynamic>> _getJson(Uri uri, {String referer = kBiliReferer}) async {
    final r = await _get(uri, referer: referer);
    if (r.status < 200 || r.status >= 300) {
      throw DanmakuException(
        'B 站接口返回 HTTP ${r.status}',
        statusCode: r.status,
        uri: uri.toString(),
      );
    }
    final text = utf8.decode(r.body, allowMalformed: true);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw DanmakuException(
        'B 站接口返回的不是 JSON',
        statusCode: r.status,
        body: text.length > 2000 ? text.substring(0, 2000) : text,
        uri: uri.toString(),
      );
    }
    if (decoded is! Map) {
      throw DanmakuException(
        'B 站接口返回的 JSON 不是对象',
        statusCode: r.status,
        uri: uri.toString(),
      );
    }
    final m = decoded.cast<String, dynamic>();
    final code = _int(m['code']);
    if (code != 0) {
      throw DanmakuException(
        'B 站接口报错：${_str(m['message'], fallback: '未知错误')}',
        statusCode: r.status,
        errorCode: code,
        errorMessage: _str(m['message']),
        body: text.length > 2000 ? text.substring(0, 2000) : text,
        uri: uri.toString(),
      );
    }
    return m;
  }

  // ── 搜索 ───────────────────────────────────────────────────────────

  /// 按关键词搜 B 站视频 —— 给"知道要看什么、但不想自己去翻链接"的用户。
  ///
  /// 端点 `/x/web-interface/search/type?search_type=video`，
  /// **不传 `page_size`**（实测加了会 412），每页固定 20 条。
  ///
  /// ⚠️ Referer 必须用 [kBiliSearchReferer]（理由见那里的注释）。
  /// 返回的条目**已经清洗过**（见 [parseBiliSearchItems]）。
  Future<List<BiliSearchItem>> searchVideos(
    String keyword, {
    int page = 1,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const <BiliSearchItem>[];
    final p = page < 1 ? 1 : page;
    final uri = Uri.https(
      'api.bilibili.com',
      '/x/web-interface/search/type',
      <String, String>{
        'search_type': 'video',
        'keyword': kw,
        'page': '$p',
      },
    );
    final m = await _getJson(uri, referer: kBiliSearchReferer);
    return parseBiliSearchItems(m);
  }

  // ── 短链解析 ───────────────────────────────────────────────────────

  /// 把 b23.tv 短链跟到最终地址，再从中抠出 BV 号。
  Future<BiliRef> resolveShortLink(BiliRef ref) async {
    if (!ref.isShortLink) return ref;
    final uri = Uri.parse(ref.shortUrl);
    final sw = Stopwatch()..start();
    final req = await _client.getUrl(uri).timeout(timeout);
    req.followRedirects = false; // 自己读 Location，方便记 trace
    req.headers.set(HttpHeaders.userAgentHeader, kBiliUserAgent);
    final resp = await req.close().timeout(timeout);
    await resp.drain<void>();
    sw.stop();

    final loc = resp.headers.value(HttpHeaders.locationHeader) ?? '';
    _remember(BiliHttpTrace(
      method: 'GET',
      uri: uri.toString(),
      status: resp.statusCode,
      bytes: 0,
      elapsedMs: sw.elapsedMilliseconds,
      note: 'short-link -> $loc',
    ));

    final parsed = parseBiliInput(loc);
    if (parsed == null || !parsed.isResolved) {
      throw DanmakuException(
        '短链没跟到 BV 号（Location: $loc）',
        statusCode: resp.statusCode,
        uri: uri.toString(),
      );
    }
    // 用户自己带的 ?p= 优先；短链里的 p 次之。
    return BiliRef(
      bvid: parsed.bvid,
      aid: parsed.aid,
      page: ref.page > 0 ? ref.page : parsed.page,
      raw: ref.raw,
    );
  }

  // ── 视频信息 ───────────────────────────────────────────────────────

  Map<String, String> _idQuery(BiliRef ref) => <String, String>{
        if (ref.bvid.isNotEmpty) 'bvid': ref.bvid else 'aid': '${ref.aid}',
      };

  /// 拉视频信息（标题 / aid / pages）。
  Future<BiliVideoInfo> videoInfo(BiliRef ref) async {
    if (!ref.isResolved) {
      throw DanmakuException('还没解析出 BV 号或 av 号');
    }
    final uri =
        Uri.https('api.bilibili.com', '/x/web-interface/view', _idQuery(ref));
    final m = await _getJson(uri);
    final data = m['data'];
    if (data is! Map) {
      throw DanmakuException('view 接口没有 data 字段', uri: uri.toString());
    }
    final d = data.cast<String, dynamic>();

    var pages = <BiliPage>[];
    final rawPages = d['pages'];
    if (rawPages is List) {
      for (final it in rawPages) {
        if (it is Map) {
          final p = BiliPage.fromJson(it.cast<String, dynamic>());
          if (p != null) pages.add(p);
        }
      }
    }
    // view 的 pages 为空时用 pagelist 兜底（老视频偶发）。
    if (pages.isEmpty) {
      pages = await pageList(ref);
    }

    return BiliVideoInfo(
      bvid: _str(d['bvid'], fallback: ref.bvid),
      aid: _int(d['aid'], fallback: ref.aid),
      title: _str(d['title']),
      cover: _str(d['pic']),
      duration: _int(d['duration']),
      pages: pages,
    );
  }

  /// 只要分 P 列表（view 的兜底，也单独可用）。
  Future<List<BiliPage>> pageList(BiliRef ref) async {
    if (!ref.isResolved) {
      throw DanmakuException('还没解析出 BV 号或 av 号');
    }
    final uri =
        Uri.https('api.bilibili.com', '/x/player/pagelist', _idQuery(ref));
    final m = await _getJson(uri);
    final data = m['data'];
    final out = <BiliPage>[];
    if (data is List) {
      for (final it in data) {
        if (it is Map) {
          final p = BiliPage.fromJson(it.cast<String, dynamic>());
          if (p != null) out.add(p);
        }
      }
    }
    return out;
  }

  // ── 弹幕 ───────────────────────────────────────────────────────────

  /// 拉某个 cid 的弹幕 XML 原文。
  Future<String> danmakuXml(int cid) async {
    if (cid <= 0) throw DanmakuException('cid 非法：$cid');
    // ★ 2026-10-05：list.so 全量 412，改用 comment.bilibili.com/<cid>.xml
    //   （同样的裸 deflate，同样的 XML 形状，见文件头注释与 .probe/bili412/run3.txt）
    final uri = Uri.https('comment.bilibili.com', '/$cid.xml');
    final r = await _get(uri);
    if (r.status < 200 || r.status >= 300) {
      throw DanmakuException(
        '弹幕接口返回 HTTP ${r.status}',
        statusCode: r.status,
        uri: uri.toString(),
      );
    }
    return utf8.decode(r.body, allowMalformed: true);
  }

  /// 一步到位：拉 XML 并解析成 DanmakuComment。
  Future<List<DanmakuComment>> danmaku(int cid) async =>
      parseBiliDanmakuXml(await danmakuXml(cid));

  /// 便捷组合：输入 → 解析 → 视频信息 + 该 P 的弹幕。
  Future<BiliFetchResult> fetch(String rawInput) async {
    final parsed = parseBiliInput(rawInput);
    if (parsed == null) {
      throw DanmakuException('没认出 BV 号 / av 号 / 链接');
    }
    final ref = await resolveShortLink(parsed);
    final info = await videoInfo(ref);
    final page = info.pageAt(ref.page > 0 ? ref.page : 1);
    if (page == null) {
      throw DanmakuException('这个视频没有可用的分 P');
    }
    final comments = await danmaku(page.cid);
    return BiliFetchResult(
      ref: ref,
      info: info,
      page: page,
      comments: comments,
      trace: trace,
    );
  }
}

/// 一次完整抓取的结果。
class BiliFetchResult {
  const BiliFetchResult({
    required this.ref,
    required this.info,
    required this.page,
    required this.comments,
    this.trace = const <BiliHttpTrace>[],
  });

  final BiliRef ref;
  final BiliVideoInfo info;
  final BiliPage page;
  final List<DanmakuComment> comments;
  final List<BiliHttpTrace> trace;

  int get count => comments.length;

  @override
  String toString() =>
      'BiliFetchResult(${info.bvid} P${page.page} ${info.title}, '
      '${comments.length} 条)';
}

/// 搜索结果里的一条视频（**字段已清洗**，可以直接上 UI / 喂给导入流程）
///
/// 清洗的三件事（都是线上响应里真实存在的坑，见 [parseBiliSearchItems]）：
/// ```text
/// title    B 站把命中的关键词包成 <em class="keyword">…</em> ⇒ 必须剥掉，
///          否则界面上会出现一串 HTML 标签
/// pic      线上是 "//i0.hdslb.com/..." ⇒ 补 https:，否则 Image 加载不出来
/// duration 线上是 "m:ss" / "mm:ss" 字符串（个位数秒会写成 "1:2"）⇒ 原样保留，
///          不要解析成秒再格式化（会变成 "01:02"，与 B 站自己显示的不一致）
/// ```
class BiliSearchItem {
  const BiliSearchItem({
    required this.bvid,
    required this.title,
    this.aid = 0,
    this.author = '',
    this.cover = '',
    this.duration = '',
    this.play = 0,
    this.typename = '',
    this.pubdate = 0,
  });

  /// BV 号 —— 点一条就是要把它喂给 [BiliApi.videoInfo] / bindFromInput
  final String bvid;

  /// 标题，已剥掉 `<em>` 高亮标签
  final String title;

  /// av 号（数字）。⚠️ 实测可达 1.17e14（> 2^53）⇒ 全程走 int，绝不经 double
  final int aid;

  /// UP 主
  final String author;

  /// 封面，已补上 `https:`；空串 = 这条没封面
  final String cover;

  /// 时长，**原样**保留线上给的 "mm:ss" 字符串
  final String duration;

  /// 播放量（B 站给的是原始数字）
  final int play;

  /// 分区名（"电子竞技" / "手机游戏" …）
  final String typename;

  /// 投稿时间（UTC 秒，0 = 没给）
  final int pubdate;

  /// 有 BV 号才绑得动
  bool get usable => bvid.isNotEmpty;

  @override
  String toString() => 'BiliSearchItem($bvid "$title" $author $duration)';
}

/// 把搜索接口的响应体解析成条目列表（**纯函数**，可单测、不发网络）
///
/// 形状（逐字，实测 2026-10-08）：
/// ```text
/// {"code":0,"message":"OK","ttl":1,
///  "data":{"seid":…,"page":1,"pagesize":20,"numResults":1000,"numPages":50,
///          "result":[ {bvid, aid, title, author, mid, duration, pic, play,
///                      video_review, typename, pubdate}, … ]}}
/// ```
///
/// ⚠️ 两种"看起来正常其实不是数据"的响应都要当**空结果**处理，不能抛：
/// ```text
/// ① 风控页：HTTP 200 + text/html（Referer 不对时就是这样）
///    —— 走到这里时已经由 DandanplayClient 的 JSON 解析拦下，抛的是
///       "弹幕服务返回的是一张网页"，不是本函数的责任；
/// ② data 缺失 / result 不是 List（例如 code!=0 的降级响应）⇒ 返回空列表。
/// ```
List<BiliSearchItem> parseBiliSearchItems(Object? body) {
  final Object? decoded = body is String ? _tryJson(body) : body;
  if (decoded is! Map) return const <BiliSearchItem>[];
  final data = decoded['data'];
  if (data is! Map) return const <BiliSearchItem>[];
  final raw = data['result'];
  if (raw is! List) return const <BiliSearchItem>[];
  final out = <BiliSearchItem>[];
  for (final it in raw) {
    if (it is! Map) continue;
    final item = biliSearchItemFromJson(it.cast<String, dynamic>());
    if (item != null) out.add(item);
  }
  return out;
}

/// 单条解析（缺 bvid 的条目直接丢掉 —— 没有它绑不动）
BiliSearchItem? biliSearchItemFromJson(Map<String, dynamic> j) {
  final bvid = _str(j['bvid']).trim();
  if (bvid.isEmpty) return null;
  return BiliSearchItem(
    bvid: bvid,
    title: stripBiliSearchEm(_str(j['title'])).trim(),
    aid: _int(j['aid']),
    author: _str(j['author']).trim(),
    cover: biliSearchCoverUrl(_str(j['pic'])),
    duration: _str(j['duration']).trim(),
    play: _int(j['play']),
    typename: _str(j['typename']).trim(),
    pubdate: _int(j['pubdate']),
  );
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

final RegExp _reEmTag = RegExp(r'</?em[^>]*>', caseSensitive: false);

/// 剥掉标题里的 `<em class="keyword">` / `</em>`（B 站用来高亮命中词）
///
/// 只认 `<em …>` / `</em>` 这两种标签，**不做**通用 HTML 剥离 ——
/// 标题里合法的 `<` / `>`（例如「1<2>3」）不该被吃掉。
String stripBiliSearchEm(String s) => s.replaceAll(_reEmTag, '');

/// 封面地址补 `https:`
///
/// 线上是协议相对的 `//i0.hdslb.com/…`；Flutter 的 Image.network 遇到
/// 这种地址会直接抛"Invalid argument"，所以必须补齐。
/// 已经是 http/https 的原样返回。
String biliSearchCoverUrl(String s) {
  final u = s.trim();
  if (u.isEmpty) return '';
  if (u.startsWith('//')) return 'https:$u';
  return u;
}

class _Raw {
  const _Raw({required this.status, required this.body, this.contentType = ''});
  final int status;
  final List<int> body;
  final String contentType;
}

// ══════════════════════════════════════════════════════════════════════
//  四、裸 deflate
// ══════════════════════════════════════════════════════════════════════

/// 解**裸 deflate**（没有 zlib 头的那种）。
///
/// 为什么不用 zlib.decode：实测它抛
/// FormatException: Filter error, bad data
/// （.probe/bili/recon_deflate.dart 的 C 路），因为 B 站发的是 raw deflate。
///
/// RawZLibFilter 的签名（dart-sdk/lib/io/data_transformer.dart:450）：
///   List<int>? processed({bool flush = true, bool end = false});
/// 而 process 只收 3 个位置参数（多传一个编译期就报
/// "Too many positional arguments: 3 allowed, but 4 found."）。
List<int> rawInflate(List<int> data) {
  final filter = RawZLibFilter.inflateFilter(raw: true);
  filter.process(data, 0, data.length);
  final out = <int>[];
  while (true) {
    final chunk = filter.processed();
    if (chunk == null || chunk.isEmpty) break;
    out.addAll(chunk);
  }
  return out;
}

// ══════════════════════════════════════════════════════════════════════
//  五、弹幕 XML 解析
// ══════════════════════════════════════════════════════════════════════

/// <d p="...">正文</d> —— 整串扫描，不依赖换行。
final RegExp _reDanmakuTag = RegExp(r'<d p="([^"]*)">([\s\S]*?)</d>');

/// 把 B 站弹幕 XML 解析成 DanmakuComment。
///
/// · 结果按 time 升序（排版器 DanmakuTrackAllocator.layout 要求已排序）
/// · 时间非法 / 正文为空的条目直接跳过
/// · 超过 max 条就截断（默认 kBiliMaxComments）
List<DanmakuComment> parseBiliDanmakuXml(
  String xml, {
  int max = kBiliMaxComments,
  double shift = 0,
}) {
  final out = <DanmakuComment>[];
  if (xml.isEmpty) return out;

  for (final m in _reDanmakuTag.allMatches(xml)) {
    final c = parseBiliDanmakuEntry(
      p: m.group(1) ?? '',
      text: m.group(2) ?? '',
      shift: shift,
    );
    if (c == null) continue;
    out.add(c);
    if (out.length >= max) break;
  }

  out.sort((a, b) {
    final d = a.time.compareTo(b.time);
    return d != 0 ? d : a.cid.compareTo(b.cid);
  });
  return out;
}

/// 解析单条 <d>。
///
/// p 的 9 段（B 站）：
///   0 时间(秒)  1 模式  2 字号  3 颜色(十进制 RGB)  4 时间戳
///   5 池        6 hash  7 弹幕ID(dmid)             8 权重
///
/// ⚠️ 颜色在**下标 3**。danmaku.dart 的 DanmakuComment.parse 读下标 2
/// （那是 dandanplay 的 4 段布局），所以这里**不能**复用它 —— 自己解析后
/// 直接构造 DanmakuComment。
DanmakuComment? parseBiliDanmakuEntry({
  required String p,
  required String text,
  double shift = 0,
}) {
  final body = unescapeXml(text).trim();
  if (body.isEmpty) return null;

  final parts = p.split(',');
  if (parts.length < 4) return null;

  final rawTime = double.tryParse(parts[0].trim());
  if (rawTime == null) return null;
  final t = rawTime + shift;
  if (t < 0) return null;

  final mode = int.tryParse(parts[1].trim()) ?? 1;

  // 颜色：十进制 RGB。0 或非法值一律按白色（B 站自己也是这么兜的）。
  var color = int.tryParse(parts[3].trim()) ?? 0xFFFFFF;
  if (color <= 0) {
    color = 0xFFFFFF;
  } else {
    color &= 0xFFFFFF; // 去掉可能带上的 alpha 高位
  }

  // dmid 在下标 7。用不了就退回「时间 + 正文散列」的合成值，
  // 保证 cid 唯一（去重与增量合并都靠它）。
  var dmid = int.tryParse(parts.length > 7 ? parts[7].trim() : '') ?? 0;
  if (dmid <= 0) {
    dmid = (t * 1000).round() ^ (body.hashCode & 0xFFFF);
  }

  // 用户 id：B 站的 p 里只有 hash（下标 6），拿它当 uid。
  final uid = parts.length > 6 ? parts[6].trim() : '';

  return DanmakuComment(
    cid: dmid,
    time: t,
    text: body,
    mode: DanmakuMode.fromWire(mode),
    color: color,
    userId: uid,
  );
}

/// 反转义 XML 实体。B 站正文里常见 &amp; &lt; &gt; &quot; &#39;。
String unescapeXml(String s) {
  if (!s.contains('&')) return s;
  var out = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  // 数字实体 &#123; / &#x1F600;
  out = out.replaceAllMapped(
    RegExp(r'&#(x?)([0-9A-Fa-f]{1,7});'),
    (m) {
      final hex = m.group(1) == 'x';
      final v = int.tryParse(m.group(2)!, radix: hex ? 16 : 10);
      if (v == null || v <= 0 || v > 0x10FFFF) return m.group(0)!;
      try {
        return String.fromCharCode(v);
      } catch (_) {
        return m.group(0)!;
      }
    },
  );
  return out;
}

// ══════════════════════════════════════════════════════════════════════
//  六、小工具
// ══════════════════════════════════════════════════════════════════════

int _int(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _str(Object? v, {String fallback = ''}) {
  if (v is String) return v;
  if (v == null) return fallback;
  return '$v';
}
