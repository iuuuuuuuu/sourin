// =======================================================================
//  弹幕（dandanplay 弹弹play 开放弹幕网络）—— 客户端
// =======================================================================
//
// # 这个文件解决什么
//
// 用户 2026-10-04 要求（逐字）：
// > 接入一下 dandanplay 的弹幕功能
//
// 这里实现三件事：
// ```text
// (1) 配置      DanmakuConfig    —— 开关 / AppId / AppSecret（键名已锁定，见下）
// (2) 取弹幕    DandanplayClient —— 真实 HTTP：/api/v2/match + /api/v2/comment/{id}
// (3) 渲染      lib/ui/widgets/danmaku_overlay.dart（本文件只出数据，不碰 widget）
// ```
//
// # 锁定的偏好键名（task-13 定；task-14 若做统一入口按这套接，不要改）
// ```text
// dsh.danmaku.enabled     "1" / "0"，缺省 "0"
// dsh.danmaku.appId       AppId，缺省 ""
// dsh.danmaku.appSecret   AppSecret，缺省 ""
// ```
// 本文件另外新增四个**显示参数**键（与上面三个不冲突）：
// ```text
// dsh.danmaku.fontScale   字号比例，缺省 "1.0"
// dsh.danmaku.opacity     不透明度，缺省 "1.0"
// dsh.danmaku.speed       一条弹幕穿过画面的秒数，缺省 "8.0"
// dsh.danmaku.area        显示区域占画面高度的比例，缺省 "1.0"
// ```
//
// # 为什么自己写 SHA-256、用 dart:io 而不是 package:crypto / package:http
//
// `pubspec.yaml` 的 `dependencies:` 里只有 `http`，**没有** `crypto` ——
// 而签名模式要 `base64(sha256(AppId + Timestamp + Path + AppSecret))`。
// 直接 `import 'package:crypto/crypto.dart'` 属于**未声明依赖**
// （现在能编译只是因为它恰好是传递依赖，换一次 lock 就会炸）。
// `pubspec.yaml` 不在本次写范围内 ⇒ 用 `dart:io` 的 `HttpClient`
// 加本文件自己实现的 SHA-256，**零新依赖**。
//
// # 鉴权：签名模式（不把 AppSecret 直接当请求头发出去）
//
// 逐字来自官方文档（`.probe/danmaku/open.txt`「签名验证模式指南」）：
// > base64(sha256(AppId + Timestamp + Path + AppSecret))
// > Timestamp：当前时间戳（UTC Unix 秒）
// > Path：API 地址后的路径部分，以斜杠开头，不含协议/域名/问号后的查询参数
// 请求头：`X-AppId` / `X-Signature` / `X-Timestamp`。
//
// # 错误必须**原文**透出（不要换成"网络错误"这种糊话）
//
// 实测（2026-10-04，无凭证）：
// ```text
// GET https://api.dandanplay.net/api/v2/comment/123450001?withRelated=true
// => HTTP 403 Forbidden
//    X-Error-Message: Missing Authentication Headers
//    Server: nginx
//    Content-Length: 0
// ```
// 403 的**原因**只在响应头 `X-Error-Message` 里（正文是空的），
// 取值有 `Missing Authentication Headers` / `Invalid Timestamp` /
// `Invalid AppId` / `Invalid Signature` / `Invalid AppSecret`。
// ⇒ 本文件把这些值**原样**带进 `DanmakuException.xErrorMessage`，
//   UI 直接显示 —— 用户和我们才能一眼看出是"没配凭证"还是"签名算错"。
//
// # 拿不到 fileHash 的现实（为什么走 fileNameOnly / search）
//
// 官方推荐流程是 `fileHash = 文件前 16MB 的 MD5`。
// 而本项目的播放地址是**流**（本地代理或远端 m3u8），
// `StreamCandidate` 里**没有本地路径、也没有 fileSize**
// ⇒ 物理上算不出 fileHash ⇒ 只能用 `matchMode = fileNameOnly`
//   或退路 `GET /api/v2/search/episodes?anime=&episode=`。
// 这一点在报告里必须如实标注为**能力限制**，不是 bug。
//
// TODO(security): AppSecret 目前明文存 ui-prefs.json，需迁移到系统凭据存储
// （Windows DPAPI / Android Keystore）。见 danmaku_settings_dialog.dart 头部。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ui_prefs.dart';

/// 一条弹幕的显示模式
///
/// 值来自 dandanplay 的 `p` 字段第 2 段（`出现时间,模式,颜色,用户ID`）：
/// ```text
/// 1 = 滚动（从右往左）
/// 4 = 底部固定
/// 5 = 顶部固定
/// ```
/// 其余值（2/3/6/7/8/9）是历史遗留或高级模式（逆向、精确时间定位等）。
/// 这里一律按**滚动**处理 —— 宁可按常见方式显示，也不要整条丢掉。
enum DanmakuMode {
  scroll,
  bottom,
  top;

  static DanmakuMode fromWire(int v) {
    switch (v) {
      case 4:
        return DanmakuMode.bottom;
      case 5:
        return DanmakuMode.top;
      default:
        return DanmakuMode.scroll;
    }
  }

  /// 是否固定在屏幕上（顶部/底部）—— 决定用哪一套轨道
  bool get isFixed => this != DanmakuMode.scroll;

  /// 给 UI / 日志看的中文名
  String get label {
    switch (this) {
      case DanmakuMode.scroll:
        return '滚动';
      case DanmakuMode.bottom:
        return '底部';
      case DanmakuMode.top:
        return '顶部';
    }
  }
}

/// 一条弹幕（已经解析、已经算好出现时间）
///
/// dandanplay 返回的原始形态是 `CommentData{ cid, p, m }`，
/// 其中 `p` 是一串**逗号分隔的字符串**：`出现时间,模式,颜色,用户ID`。
/// 本类把它拆开并做三件规范化：
/// ```text
/// 1. time  : String -> double（秒），并叠加 shift（见下）
/// 2. mode  : int    -> DanmakuMode（未知值归滚动）
/// 3. color : int    -> 只留 24 位 RGB（有些源会塞超过 0xFFFFFF 的值）
/// ```
///
/// ## 关于 shift（弹幕偏移）
///
/// `/api/v2/match` 的每条结果带一个 `shift` 字段，官方逐字：
/// > 弹幕偏移时间（弹幕应延迟多少秒出现）。此数字为负数时表示弹幕应提前多少秒出现。
///
/// 例：视频本体带了 90 秒的片头，弹幕库是按**无片头版**录的，
/// 那么 shift = 90，弹幕时间要整体 +90 才对得上。
/// ⇒ shift 由 [DanmakuMatch.shift] 提供，在 [DandanplayClient] 里一次性叠加，
///   叠加后 time < 0 的弹幕直接丢掉（提前到负数 = 这条本来就不该出现）。
class DanmakuComment {
  const DanmakuComment({
    required this.cid,
    required this.time,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFF,
    this.userId = '',
  });

  /// 弹幕库内的唯一编号（dandanplay 的 `cid`）
  final int cid;

  /// 出现时间，单位**秒**，已经叠加过 shift
  final double time;

  /// 弹幕正文
  final String text;

  final DanmakuMode mode;

  /// 24 位 RGB（`R * 65536 + G * 256 + B`）。
  /// UI 侧拼成 `Color(0xFF000000 | color)`。
  /// 注意：弹幕颜色**没有** alpha 通道，透明度由全局设置控制。
  final int color;

  final String userId;

  /// 解析一条原始弹幕；无法解析时返回 null（调用方直接跳过）
  ///
  /// `p` 的容错策略：只要求第 1 段（时间）能解析出数字，
  /// 后面的段缺失就用默认值 —— 弹幕库里历史数据格式很杂，
  /// 为了一个坏字段丢掉整条弹幕不划算。
  static DanmakuComment? parse({
    required int cid,
    required String p,
    required String m,
    double shift = 0,
  }) {
    if (m.trim().isEmpty) return null;
    final parts = p.split(',');
    if (parts.isEmpty) return null;
    final rawTime = double.tryParse(parts[0].trim());
    if (rawTime == null) return null;
    final t = rawTime + shift;
    if (t < 0) return null;
    var mode = DanmakuMode.scroll;
    if (parts.length > 1) {
      final mv = int.tryParse(parts[1].trim());
      if (mv != null) mode = DanmakuMode.fromWire(mv);
    }
    var color = 0xFFFFFF;
    if (parts.length > 2) {
      final cv = int.tryParse(parts[2].trim());
      if (cv != null && cv > 0) color = cv & 0xFFFFFF;
    }
    final uid = parts.length > 3 ? parts[3].trim() : '';
    return DanmakuComment(
      cid: cid,
      time: t,
      text: m,
      mode: mode,
      color: color,
      userId: uid,
    );
  }

  /// 从 dandanplay 的 JSON 对象解析（`{cid, p, m}`）
  static DanmakuComment? fromJson(Map<String, dynamic> j, {double shift = 0}) {
    final cid = _asInt(j['cid']);
    final p = j['p']?.toString() ?? '';
    final m = j['m']?.toString() ?? '';
    if (cid == null) return null;
    return DanmakuComment.parse(cid: cid, p: p, m: m, shift: shift);
  }

  @override
  String toString() => 'DanmakuComment(#$cid ${time.toStringAsFixed(2)}s '
      '${mode.label} #${color.toRadixString(16).padLeft(6, "0")} "$text")';
}

/// dandanplay 的整数可能以 int 或 String 出现（int64 走 JSON 时常见），
/// 这里统一成 int。
int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

/// `/api/v2/match` 的一条匹配结果（只要本项目用得上的字段）
///
/// 官方 `MatchResultV2` 还有 animeId / type / typeDescription / imageUrl，
/// 这里只留渲染和排错需要的：
/// ```text
/// episodeId   弹幕库 ID —— 拿弹幕的唯一钥匙
/// animeTitle  作品名   —— 给用户看，让用户确认"匹配对不对"
/// episodeTitle 剧集名  —— 同上
/// shift       弹幕偏移秒数（负数=提前）—— 必须叠加，见 DanmakuComment
/// ```
class DanmakuMatch {
  const DanmakuMatch({
    required this.episodeId,
    this.animeTitle = '',
    this.episodeTitle = '',
    this.shift = 0,
  });

  final int episodeId;
  final String animeTitle;
  final String episodeTitle;
  final double shift;

  static DanmakuMatch? fromJson(Map<String, dynamic> j) {
    final id = _asInt(j['episodeId']);
    if (id == null || id <= 0) return null;
    return DanmakuMatch(
      episodeId: id,
      animeTitle: j['animeTitle']?.toString() ?? '',
      episodeTitle: j['episodeTitle']?.toString() ?? '',
      shift: _asDouble(j['shift']),
    );
  }

  /// 一行给人看的描述，例：`某番 第 3 集（偏移 +90.0s）`
  String get label {
    final b = StringBuffer();
    if (animeTitle.isNotEmpty) b.write(animeTitle);
    if (episodeTitle.isNotEmpty) {
      if (b.isNotEmpty) b.write(' ');
      b.write(episodeTitle);
    }
    if (b.isEmpty) b.write('弹幕库 #$episodeId');
    if (shift != 0) {
      b.write('（偏移 ');
      if (shift > 0) b.write('+');
      b.write(shift.toStringAsFixed(1));
      b.write('s）');
    }
    return b.toString();
  }

  @override
  String toString() => 'DanmakuMatch(#$episodeId "$label")';
}

double _asDouble(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

// -----------------------------------------------------------------------
// SHA-256（自己实现，理由见文件头）
// -----------------------------------------------------------------------

/// SHA-256 的 64 个轮常量（FIPS 180-4 5.4.2）
const List<int> _k256 = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// 计算 SHA-256，返回 32 字节摘要
///
/// 纯 Dart、零依赖。正确性靠**公开测试向量**验证（见 `test/task13_danmaku_test.dart`）：
/// ```text
/// sha256("")          = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
/// sha256("abc")       = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
/// sha256("abcdbcde...")（56 字节长串，跨 2 个分组）= 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
/// ```
Uint8List sha256Bytes(List<int> input) {
  final msgLen = input.length;
  // 补位：0x80 + 若干 0x00，使总长 = 56 (mod 64)，再接 8 字节大端位长
  final total = ((msgLen + 9 + 63) ~/ 64) * 64;
  final data = Uint8List(total);
  data.setRange(0, msgLen, input);
  data[msgLen] = 0x80;
  final bitLen = msgLen * 8;
  for (var i = 0; i < 8; i++) {
    data[total - 1 - i] = (bitLen >> (8 * i)) & 0xFF;
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final w = Uint32List(64);
  for (var off = 0; off < total; off += 64) {
    for (var i = 0; i < 16; i++) {
      final b = off + i * 4;
      w[i] = (data[b] << 24) | (data[b + 1] << 16) | (data[b + 2] << 8) | data[b + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  final hs = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (hs[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (hs[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (hs[i] >> 8) & 0xFF;
    out[i * 4 + 3] = hs[i] & 0xFF;
  }
  return out;
}

/// `base64(sha256(text))` —— 就是 dandanplay 要求的 `X-Signature`
String sha256Base64(String text) =>
    base64.encode(sha256Bytes(utf8.encode(text)));

/// 十六进制摘要，只给日志和测试用
String sha256Hex(String text) {
  final d = sha256Bytes(utf8.encode(text));
  final sb = StringBuffer();
  for (final b in d) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

// -----------------------------------------------------------------------
// 错误
// -----------------------------------------------------------------------

/// 弹幕功能里所有"能给人看"的失败都走这个异常
///
/// 设计要点：**保留服务端原文**。
/// 弹幕拿不到的原因分三类，用户看到的提示必须能区分：
/// ```text
/// 1. 没配凭证   HTTP 403 + 头 X-Error-Message: Missing Authentication Headers
/// 2. 凭证不对   HTTP 403 + 头 X-Error-Message: Invalid Signature / Invalid AppId ...
/// 3. 匹配不到   业务错误（HTTP 200 + success:false）或 matches 为空
/// ```
/// 所以 [xErrorMessage] / [errorCode] / [errorMessage] / [body] 全部原样保留，
/// [message] 只是给人看的一句话总结，**不替换**原文。
class DanmakuException implements Exception {
  DanmakuException(
    this.message, {
    this.statusCode = 0,
    this.xErrorMessage = '',
    this.errorCode = 0,
    this.errorMessage = '',
    this.body = '',
    this.uri = '',
    this.hint,
  });

  /// 中文一句话总结（UI 主文案）
  final String message;

  /// HTTP 状态码，0 表示还没发出去就失败了（DNS / 连接超时等）
  final int statusCode;

  /// 响应头 `X-Error-Message` 原文，可能为空
  final String xErrorMessage;

  /// 业务错误码（`ResponseBase.errorCode`）
  final int errorCode;

  /// 业务错误原文（`ResponseBase.errorMessage`）
  final String errorMessage;

  /// 响应正文原文（截断到 2000 字，够排错又不至于把 UI 撑爆）
  final String body;

  /// 出错的请求地址（不含签名，可以安全展示）
  final String uri;

  /// 「为什么失败 + 怎么办」的中文动作，null = 没有比 [message] 更具体的话可说
  ///
  /// 判据全部来自真实读数（HTTP 状态码 + `X-Error-Message` 原文），
  /// 见 [DanmakuHint.of]。它**不替换** [message] / [xErrorMessage] ——
  /// 服务端原文照旧透出，这里只是补一句"下一步做什么"。
  final DanmakuHint? hint;

  /// 是否属于"没配 / 配错凭证"这一类 —— UI 据此提示"去设置里填 AppId"
  bool get isAuthProblem => statusCode == 403 || statusCode == 401;

  /// 多行详细描述，给对话框的"详情"区域用
  String get detail {
    final b = StringBuffer();
    if (statusCode != 0) b.writeln('HTTP $statusCode');
    if (xErrorMessage.isNotEmpty) b.writeln('X-Error-Message: $xErrorMessage');
    if (errorCode != 0) b.writeln('errorCode: $errorCode');
    if (errorMessage.isNotEmpty) b.writeln('errorMessage: $errorMessage');
    if (uri.isNotEmpty) b.writeln('请求: $uri');
    if (body.isNotEmpty) b.writeln('响应正文: $body');
    return b.toString().trimRight();
  }

  @override
  String toString() {
    final d = detail;
    return d.isEmpty ? 'DanmakuException($message)' : 'DanmakuException($message)\n$d';
  }
}

// -----------------------------------------------------------------------
// 传输层（抽出来是为了**可测**：真实实现走 dart:io，测试注入假实现）
// -----------------------------------------------------------------------

/// 一次 HTTP 响应的最小快照
class DanmakuHttpResponse {
  const DanmakuHttpResponse({
    required this.statusCode,
    this.body = '',
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;

  /// 响应头，**键统一小写**（HTTP 头大小写不敏感，统一后才好查）
  final Map<String, String> headers;

  /// 403 时的失败原因就在这里（正文是空的）
  String get xErrorMessage => headers['x-error-message'] ?? '';

  String get contentType => headers['content-type'] ?? '';

  bool get isOk => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'DanmakuHttpResponse($statusCode, ${body.length} chars)';
}

/// 弹幕 HTTP 传输接口
///
/// 存在的理由：单测 / 探针里要能**确定性地**造出 403 + `X-Error-Message`，
/// 而不是"跑到网上碰运气"。生产环境用 [IoDanmakuTransport]。
abstract class DanmakuTransport {
  /// 发一次请求；**不允许**在非 2xx 时抛异常 —— 状态码和响应头要带回来，
  /// 由上层决定怎么解释（403 的 X-Error-Message 就是这么拿到的）。
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  });

  /// 释放底层连接池
  void close();
}

/// 生产实现：`dart:io` 的 [HttpClient]
///
/// 两个关键设置：
/// ```text
/// followRedirects = true   —— /api/v2/comment/{id} 官方响应码就是 302，
///                            不跟随重定向的话永远拿不到弹幕
/// connectionTimeout        —— 移动网络下别无限等
/// ```
class IoDanmakuTransport implements DanmakuTransport {
  IoDanmakuTransport({HttpClient? client, this.timeout = const Duration(seconds: 15)})
      : _client = client ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 10)
              ..userAgent = 'sourin-flutter-spike/danmaku');

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final req = await _client.openUrl(method, uri).timeout(timeout);
    headers.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final resp = await req.close().timeout(timeout);
    // dandanplay 全站 UTF-8；allowMalformed 保证偶发坏字节不会把整次请求炸掉
    final text = await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(timeout);
    final h = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) h[name.toLowerCase()] = values.join(', ');
    });
    return DanmakuHttpResponse(
      statusCode: resp.statusCode,
      body: text,
      headers: h,
    );
  }

  @override
  void close() => _client.close(force: true);
}

// -----------------------------------------------------------------------
// 配置（键名已锁定，见文件头）
// -----------------------------------------------------------------------

/// 弹幕配置 —— 三个锁定键 + 四个显示参数
///
/// 全部走 [UiPrefs]，也就是 `<数据目录>/ui-prefs.json`。
/// 空串一律 **remove** 而不是写空值，避免配置文件里攒一堆没用的键。
///
/// ## 为什么不用 `UiPrefs.load` 之外的东西
/// 播放页可能在任何时候读配置（底栏按钮要显示开/关状态），
/// [UiPrefs] 的内存缓存读是同步的、零 IO，正合适。
/// 写是异步合并落盘的（300ms 合并），不需要调用方 await。
///
/// ## 安全
/// AppSecret 目前是**明文**存在 ui-prefs.json 里。
/// 这是当前唯一可选项：项目没有 keyring / secure-storage 依赖，
/// 而 `pubspec.yaml` 不在本次改动范围内。
/// 已在设置对话框里**明确告知用户**，并留了 TODO 见文件头。
class DanmakuConfig {
  DanmakuConfig._();

  // ---- 锁定键（不要改名字，task-14 要按这套接） ----

  /// `"1"` 开 / `"0"` 关；缺省 `"0"`
  static const String keyEnabled = 'dsh.danmaku.enabled';

  /// dandanplay 开放平台申请到的 AppId；缺省 `""`
  static const String keyAppId = 'dsh.danmaku.appId';

  /// dandanplay 开放平台申请到的 AppSecret；缺省 `""`
  static const String keyAppSecret = 'dsh.danmaku.appSecret';

  // ---- 显示参数（本文件新增，非锁定） ----

  static const String keyFontScale = 'dsh.danmaku.fontScale';
  static const String keyOpacity = 'dsh.danmaku.opacity';
  static const String keySpeed = 'dsh.danmaku.speed';
  static const String keyArea = 'dsh.danmaku.area';

  // ---- ★★★ 2026-10-09 新增：屏蔽与分类开关（对齐 B 站弹幕设置） ----
  //
  // Owner 原话：「弹幕管理 还要支持指定区域的屏幕不显示 大小 屏蔽 速度 等等,
  //            这些都参考b站的弹幕设置就行了」
  //
  // 键名沿用 `dsh.danmaku.` 前缀，且**全部有向后兼容的缺省值** ——
  // 老用户的 ui-prefs.json 里没有这些键，读出来就是默认（全显示、不屏蔽）。

  /// 滚动弹幕开关（缺省开）
  static const String keyScroll = 'dsh.danmaku.showScroll';

  /// 顶部固定弹幕开关（缺省开）
  static const String keyTop = 'dsh.danmaku.showTop';

  /// 底部固定弹幕开关（缺省开）
  static const String keyBottom = 'dsh.danmaku.showBottom';

  /// 屏蔽词（**每行一个**，存成一个多行字符串）
  ///
  /// 为什么用多行字符串而不是 JSON 数组：用户是在一个多行输入框里敲的，
  /// 存成 JSON 的话每次读写都要序列化，而 UiPrefs 存的就是字符串 ——
  /// 多行文本**就是**最自然的形态，且用户手改 ui-prefs.json 时也看得懂。
  static const String keyBlockWords = 'dsh.danmaku.blockWords';

  /// 屏蔽词是否按**正则**解释（缺省否 ⇒ 按子串包含匹配）
  static const String keyBlockRegex = 'dsh.danmaku.blockRegex';

  /// 屏蔽「按类型」—— 上面三个开关是"显示/不显示"，
  /// 这一组是"这类弹幕直接不进渲染队列"（与 B 站的"屏蔽类型"对应）。
  static const String keyBlockScroll = 'dsh.danmaku.blockScroll';
  static const String keyBlockTop = 'dsh.danmaku.blockTop';
  static const String keyBlockBottom = 'dsh.danmaku.blockBottom';

  // ---- 显示参数的取值范围（UI 滑块与这里共用，别在两处写死） ----

  static const double fontScaleMin = 0.6;
  static const double fontScaleMax = 2.0;
  static const double opacityMin = 0.2;
  static const double opacityMax = 1.0;
  static const double speedMin = 3.0;
  static const double speedMax = 16.0;
  static const double areaMin = 0.3;
  static const double areaMax = 1.0;

  static const double defaultFontScale = 1.0;
  static const double defaultOpacity = 1.0;
  static const double defaultSpeed = 8.0;
  static const double defaultArea = 1.0;

  // ---- 读 ----

  static bool get enabled => UiPrefs.get(keyEnabled) == '1';

  static String get appId => UiPrefs.get(keyAppId) ?? '';

  static String get appSecret => UiPrefs.get(keyAppSecret) ?? '';

  /// 是否"有资格"发请求。
  ///
  /// 注意：这**不代表**凭证一定有效 —— 有效性只有服务端说了算，
  /// 所以 UI 上这个值只用来决定"是否提示用户去填"，
  /// 不能用来跳过真实请求（真实请求失败要如实显示服务端原文）。
  static bool get isConfigured => appId.isNotEmpty && appSecret.isNotEmpty;

  static double get fontScale =>
      _readDouble(keyFontScale, defaultFontScale, fontScaleMin, fontScaleMax);

  static double get opacity =>
      _readDouble(keyOpacity, defaultOpacity, opacityMin, opacityMax);

  /// 一条弹幕从右边缘走到左边缘的秒数（越大越慢）
  static double get speed =>
      _readDouble(keySpeed, defaultSpeed, speedMin, speedMax);

  /// 弹幕纵向可占用区域占画面高度的比例（1.0 = 整个画面）
  static double get area =>
      _readDouble(keyArea, defaultArea, areaMin, areaMax);

  // ---- ★ 新增项的读（缺省值 = 向后兼容：老用户读出来就是"全显示、不屏蔽"） ----

  static bool get showScroll => UiPrefs.get(keyScroll) != '0';

  static bool get showTop => UiPrefs.get(keyTop) != '0';

  static bool get showBottom => UiPrefs.get(keyBottom) != '0';

  /// 屏蔽词列表（已 trim、去空行、去重）
  static List<String> get blockWords {
    final raw = UiPrefs.get(keyBlockWords) ?? '';
    if (raw.trim().isEmpty) return const <String>[];
    final out = <String>[];
    for (final line in raw.split('\n')) {
      final w = line.trim();
      if (w.isNotEmpty && !out.contains(w)) out.add(w);
    }
    return out;
  }

  static bool get blockRegex => UiPrefs.get(keyBlockRegex) == '1';

  static bool get blockScroll => UiPrefs.get(keyBlockScroll) == '1';

  static bool get blockTop => UiPrefs.get(keyBlockTop) == '1';

  static bool get blockBottom => UiPrefs.get(keyBlockBottom) == '1';

  /// 一条弹幕该不该显示 —— **纯函数**，可单测。
  ///
  /// 判据（全部来自 B 站那套，逐条对应）：
  /// ```text
  /// ① 该类型的"显示"开关关着 ⇒ 不显示
  /// ② 该类型被"屏蔽类型"勾上 ⇒ 不显示
  /// ③ 文本命中屏蔽词 ⇒ 不显示（正则模式按正则，否则按子串包含）
  /// ```
  ///
  /// ⚠️ 正则**编译失败**时按"不匹配"处理（不是"全都屏蔽"）——
  ///    用户敲错一个正则不该让所有弹幕消失。
  static bool shouldShow({
    required DanmakuMode mode,
    required String text,
  }) {
    switch (mode) {
      case DanmakuMode.scroll:
        if (!showScroll || blockScroll) return false;
      case DanmakuMode.top:
        if (!showTop || blockTop) return false;
      case DanmakuMode.bottom:
        if (!showBottom || blockBottom) return false;
    }
    final words = blockWords;
    if (words.isEmpty) return true;
    if (blockRegex) {
      for (final w in words) {
        try {
          if (RegExp(w).hasMatch(text)) return false;
        } catch (_) {
          // 用户的正则写错了 ⇒ 跳过这一条（见上面的说明）
        }
      }
      return true;
    }
    for (final w in words) {
      if (text.contains(w)) return false;
    }
    return true;
  }

  // ---- 写 ----

  static void setEnabled(bool v) => UiPrefs.set(keyEnabled, v ? '1' : '0');

  static void setAppId(String v) => _writeTrimmed(keyAppId, v);

  static void setAppSecret(String v) => _writeTrimmed(keyAppSecret, v);

  static void setFontScale(double v) =>
      UiPrefs.set(keyFontScale, _fmt(_clamp(v, fontScaleMin, fontScaleMax)));

  static void setOpacity(double v) =>
      UiPrefs.set(keyOpacity, _fmt(_clamp(v, opacityMin, opacityMax)));

  static void setSpeed(double v) =>
      UiPrefs.set(keySpeed, _fmt(_clamp(v, speedMin, speedMax)));

  static void setArea(double v) =>
      UiPrefs.set(keyArea, _fmt(_clamp(v, areaMin, areaMax)));

  // ---- ★ 2026-10-09 新增项的写 ----

  static void setShowScroll(bool v) => UiPrefs.set(keyScroll, v ? '1' : '0');

  static void setShowTop(bool v) => UiPrefs.set(keyTop, v ? '1' : '0');

  static void setShowBottom(bool v) => UiPrefs.set(keyBottom, v ? '1' : '0');

  /// 写入屏蔽词原文（多行，每行一个）
  static void setBlockWords(String raw) {
    if (raw.trim().isEmpty) {
      UiPrefs.remove(keyBlockWords);
    } else {
      UiPrefs.set(keyBlockWords, raw);
    }
  }

  static void setBlockRegex(bool v) => UiPrefs.set(keyBlockRegex, v ? '1' : '0');

  static void setBlockScroll(bool v) => UiPrefs.set(keyBlockScroll, v ? '1' : '0');

  static void setBlockTop(bool v) => UiPrefs.set(keyBlockTop, v ? '1' : '0');

  static void setBlockBottom(bool v) => UiPrefs.set(keyBlockBottom, v ? '1' : '0');

  /// 清空凭证（用户点"清除"时用）
  static void clearCredentials() {
    UiPrefs.remove(keyAppId);
    UiPrefs.remove(keyAppSecret);
  }

  // ---- 展示用 ----

  /// 打码后的 AppId，例 `abcd****`；空则返回空串。
  ///
  /// 只用于"已经配过"的只读回显，**不要**拿它当输入框初值。
  static String get maskedAppId {
    final id = appId;
    if (id.isEmpty) return '';
    if (id.length <= 4) return '****';
    return '${id.substring(0, 4)}****';
  }

  /// 当前配置的一句话状态，给底栏提示 / 对话框标题用
  static String get statusText {
    if (!enabled) return '弹幕已关闭';
    if (!isConfigured) return '弹幕已开启，但还没填 AppId / AppSecret';
    return '弹幕已开启（AppId $maskedAppId）';
  }
}

double _readDouble(String key, double def, double lo, double hi) {
  final raw = UiPrefs.get(key);
  if (raw == null || raw.isEmpty) return def;
  final v = double.tryParse(raw);
  if (v == null) return def;
  return _clamp(v, lo, hi);
}

double _clamp(double v, double lo, double hi) {
  if (v.isNaN) return lo;
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/// 定点输出（最多 3 位小数，去掉多余的 0），保证落盘字符串稳定可比
String _fmt(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

void _writeTrimmed(String key, String v) {
  final t = v.trim();
  if (t.isEmpty) {
    UiPrefs.remove(key);
  } else {
    UiPrefs.set(key, t);
  }
}

// -----------------------------------------------------------------------
// 客户端
// -----------------------------------------------------------------------

/// 一次取弹幕的完整结果
class DanmakuFetchResult {
  const DanmakuFetchResult({
    required this.comments,
    this.match,
    this.matchedBy = '',
    this.matchMode = '',
  });

  final List<DanmakuComment> comments;

  /// 命中的弹幕库；走 search 退路时也可能是 null
  final DanmakuMatch? match;

  /// `match` 或 `search` —— 报告里要如实说明"这条弹幕是怎么找到的"
  final String matchedBy;

  final String matchMode;

  bool get isEmpty => comments.isEmpty;

  /// 给人看的一句话：`某番 第 3 集 · 842 条弹幕`
  String get summary {
    final m = match;
    final head = m == null ? '弹幕库' : m.label;
    return '$head · ${comments.length} 条弹幕';
  }
}

// -----------------------------------------------------------------------
// 失败之后：告诉用户**下一步做什么**（而不只是"失败了"）
// -----------------------------------------------------------------------
//
// Owner 反馈（2026-10-08，逐字）：「弹幕报错，如图1」，截图里那句话是
// `弹幕失败：Missing Authentication Headers`。
//
// 这句英文是 dandanplay 的原话，**必须原样保留**（它是排错的唯一线索，
// 见文件头"错误必须原文透出"），但光有它用户不知道该干什么 ——
// 实测 Owner 机器上 `dsh.danmaku.appId` / `dsh.danmaku.appSecret` 两个键
// 根本不存在，所以这句话会出现在每一台"还没填凭证"的机器上。
//
// ⇒ 在本文件里把「哪一类失败」判出来，并给出对应的中文动作：
//   · 判据**只认真实读数** —— HTTP 状态码 + `X-Error-Message` 原文；
//   · 不做"消息里含某几个字"这种乱匹配（那是脆的，服务端改一个词就失效）；
//   · UI 只负责显示 [DanmakuHint.text]、把 [DanmakuHint.action] 变成按钮，
//     **不替换** [DanmakuException.message] / [DanmakuException.xErrorMessage]。

/// 提示里附带的一个「按钮」
///
/// 刻意用两个 bool 而不是回调：本文件是 core 层，不许依赖任何 UI 包
/// （理由见 lib/core/ui_prefs.dart 头部），导航由宿主（播放页）负责。
class DanmakuHintAction {
  const DanmakuHintAction({
    required this.label,
    this.openDanmakuSettings = false,
    this.openBiliSheet = false,
  });

  /// 按钮文案
  final String label;

  /// 点了之后打开「弹幕设置」面板
  final bool openDanmakuSettings;

  /// 点了之后打开「哔哩哔哩弹幕」面板
  final bool openBiliSheet;
}

/// 「为什么失败 + 怎么办」——一句话解释 + 可选的动作按钮
class DanmakuHint {
  const DanmakuHint({
    required this.title,
    required this.text,
    this.action,
    this.url = '',
  });

  /// 短标题（一句话说清是哪一类问题）
  final String title;

  /// 说人话的解释 + 下一步怎么做
  final String text;

  /// 可选的按钮（null = 不需要按钮）
  final DanmakuHintAction? action;

  /// 可选的官方地址（只有需要用户去申请凭证时才给）
  final String url;

  /// 从一次失败里判出「该告诉用户什么」；判不出来返回 null
  ///
  /// 判据（**全部是真实读数**）：
  /// ```text
  /// HTTP 403/401 + X-Error-Message 含 "Missing Authentication Headers"（或该头为空）
  ///   ⇒ 没填凭证。实测无凭证访问 api.dandanplay.net 就是这个组合。
  /// HTTP 403/401 + 其它 X-Error-Message（Invalid AppId / Signature / Timestamp / AppSecret）
  ///   ⇒ 凭证填了但没通过。
  /// 其余 ⇒ 返回 null，让 UI 只说服务端原文（不猜）。
  /// ```
  static DanmakuHint? of(DanmakuException e) {
    final rejected = e.statusCode == 401 || e.statusCode == 403;
    if (!rejected) return null;

    final xe = e.xErrorMessage.trim();
    final lower = xe.toLowerCase();
    final missing = xe.isEmpty || lower.contains('missing authentication');

    if (missing) {
      return const DanmakuHint(
        title: '弹幕服务没收到凭证',
        text: 'dandanplay 的弹幕要填一对 AppId / AppSecret 才能取，'
            '在弹幕设置里填上就能用了（去官网免费申请，填完点「重新获取弹幕」）。'
            '另外：B 站视频可以改用「哔哩哔哩弹幕」直接绑定，不需要这对凭证。',
        action: DanmakuHintAction(
          label: '去弹幕设置',
          openDanmakuSettings: true,
          openBiliSheet: true,
        ),
        url: 'https://dev.dandanplay.com',
      );
    }

    return DanmakuHint(
      title: '凭证没通过',
      text: '弹幕服务说这次请求的凭证不对（$xe）。'
          '常见原因是 AppId / AppSecret 复制时带了空格，或者两者不是同一对，'
          '在弹幕设置里重新填一次试试。',
      action: const DanmakuHintAction(label: '去弹幕设置', openDanmakuSettings: true),
      url: 'https://dev.dandanplay.com',
    );
  }

  /// 「拿到的是网页，不是数据」这一类（CDN / 人机校验页）
  ///
  /// 实测：B 站搜索接口在 Referer 不对时**返回 HTTP 200 + text/html**，
  /// 正文是一张 aba.bilibili.com 的风控页 —— 状态码是 200，最容易骗过
  /// "非 2xx 才报错"的判断，所以这里给一句人话。
  static DanmakuHint htmlPage({required String what}) => DanmakuHint(
        title: '拿到的是网页，不是数据',
        text: '$what这次返回的是一张网页（多半是被人机校验拦了），不是数据。'
            '等几分钟再试一次；一直这样的话，先换成别的片源。',
      );

  @override
  String toString() => 'DanmakuHint($title)';
}

/// dandanplay 开放弹幕网络客户端
///
/// ## 三步流程（对应官方文档）
/// ```text
/// 1. POST /api/v2/match                   文件名 -> episodeId
/// 2. GET  /api/v2/comment/{episodeId}      episodeId -> 弹幕列表（302 重定向）
/// 3. GET  /api/v2/search/episodes          匹配不到时的退路（按番剧名 + 集数搜）
/// ```
///
/// ## ★ 没配凭证时**照样发请求**
///
/// 这是一个刻意的设计决定：
/// 与其在本地"猜"一个错误提示，不如把请求真发出去、
/// 把服务端返回的 `X-Error-Message` **原文**显示给用户 ——
/// 用户和我们才能区分"没填"（`Missing Authentication Headers`）、
/// "时间戳不对"（`Invalid Timestamp`）、"签名算错"（`Invalid Signature`）
/// 这几种完全不同的情况。本地短路会把这条信息永久埋掉。
///
/// 因此 [isConfigured] 只用来在 UI 上**追加**一句提示，
/// **不**用来阻止请求。
class DandanplayClient {
  DandanplayClient({
    DanmakuTransport? transport,
    String? appId,
    String? appSecret,
    DateTime Function()? clock,
  })  : _transport = transport ?? IoDanmakuTransport(),
        _appId = appId ?? DanmakuConfig.appId,
        _appSecret = appSecret ?? DanmakuConfig.appSecret,
        _clock = clock ?? DateTime.now;

  /// 官方唯一入口（swagger 的 `servers` 只有这一个）
  static const String host = 'api.dandanplay.net';

  /// `fileHash` 拿不到时的匹配模式（见文件头"拿不到 fileHash 的现实"）
  static const String defaultMatchMode = 'fileNameOnly';

  final DanmakuTransport _transport;
  final String _appId;
  final String _appSecret;
  final DateTime Function() _clock;

  bool get isConfigured => _appId.isNotEmpty && _appSecret.isNotEmpty;

  /// 当前 UTC 秒 —— 签名里的 `Timestamp` 要求是 UTC Unix 秒
  int get _nowSeconds => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

  Uri _uri(String path, [Map<String, String>? query]) => Uri.https(
        host,
        path,
        (query == null || query.isEmpty) ? null : query,
      );

  /// 构造鉴权头
  ///
  /// 签名 = `base64(sha256(AppId + Timestamp + Path + AppSecret))`，
  /// 其中 Path **以斜杠开头、不含协议/域名/查询参数**。
  /// 文档建议 Path 全小写、不做 URL 编码 —— 这里按文档来。
  Map<String, String> _authHeaders(String path) {
    final ts = _nowSeconds;
    final p = path.toLowerCase();
    final sig = sha256Base64('$_appId$ts$p$_appSecret');
    return <String, String>{
      'X-AppId': _appId,
      'X-Timestamp': '$ts',
      'X-Signature': sig,
      'Accept': 'application/json',
    };
  }

  /// 把一次响应翻译成"要么是数据、要么是带原文的异常"
  Map<String, dynamic> _decode(DanmakuHttpResponse r, String what, Uri uri) {
    if (r.statusCode == 403 || r.statusCode == 401) {
      final xe = r.xErrorMessage;
      final e = DanmakuException(
        xe.isEmpty ? '弹幕服务拒绝了这次请求（HTTP ${r.statusCode}）' : '弹幕服务拒绝了这次请求：$xe',
        statusCode: r.statusCode,
        xErrorMessage: xe,
        body: _clip(r.body),
        uri: uri.toString(),
      );
      // ★ 原文照旧（上面那个 message），额外挂一句"下一步做什么"
      throw DanmakuException(
        e.message,
        statusCode: e.statusCode,
        xErrorMessage: e.xErrorMessage,
        body: e.body,
        uri: e.uri,
        hint: DanmakuHint.of(e),
      );
    }
    if (!r.isOk) {
      throw DanmakuException(
        '弹幕服务返回 HTTP ${r.statusCode}',
        statusCode: r.statusCode,
        xErrorMessage: r.xErrorMessage,
        body: _clip(r.body),
        uri: uri.toString(),
        // 412/429 是"被限流"，不是"坏了" —— 用户该做的是等一下
        hint: r.statusCode == 412 || r.statusCode == 429
            ? const DanmakuHint(
                title: '被弹幕服务限流了',
                text: '短时间内请求太多次了，等几分钟再点一次「重新获取弹幕」。',
              )
            : null,
      );
    }
    // ★ HTTP 200 但正文是网页 —— 实测 B 站搜索接口在 Referer 不对时就是这样
    //   （200 + text/html 的 aba.bilibili.com 风控页）。不判这个的话，
    //   用户会看到一句没头没脑的"返回的不是 JSON"。
    if (_looksLikeHtml(r.body)) {
      throw DanmakuException(
        '弹幕服务返回的是一张网页，不是数据（$what）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: uri.toString(),
        hint: DanmakuHint.htmlPage(what: what),
      );
    }
    Object? parsed;
    try {
      parsed = jsonDecode(r.body);
    } catch (e) {
      throw DanmakuException(
        '弹幕服务返回的不是 JSON（$what）',
        statusCode: r.statusCode,
        xErrorMessage: r.xErrorMessage,
        body: _clip(r.body),
        uri: uri.toString(),
      );
    }
    if (parsed is! Map<String, dynamic>) {
      throw DanmakuException(
        '弹幕服务返回的 JSON 结构不对（$what）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: uri.toString(),
      );
    }
    // 业务错误：HTTP 200 + success:false + errorCode/errorMessage
    if (parsed['success'] == false) {
      final code = _asInt(parsed['errorCode']) ?? 0;
      final msg = parsed['errorMessage']?.toString() ?? '';
      throw DanmakuException(
        msg.isEmpty ? '弹幕服务报错（errorCode $code）' : '弹幕服务报错：$msg',
        statusCode: r.statusCode,
        errorCode: code,
        errorMessage: msg,
        body: _clip(r.body),
        uri: uri.toString(),
      );
    }
    return parsed;
  }

  /// 1) 按文件名匹配弹幕库
  ///
  /// `fileName` 按官方要求**不含文件夹和扩展名**，由调用方负责裁剪。
  /// `fileHash` / `fileSize` 本项目拿不到（播放地址是流），留空即可，
  /// 同时把 `matchMode` 设成 `fileNameOnly` 免得服务端白算一遍 hash。
  Future<List<DanmakuMatch>> match({
    required String fileName,
    String fileHash = '',
    int fileSize = 0,
    int videoDuration = 0,
    String matchMode = defaultMatchMode,
  }) async {
    const path = '/api/v2/match';
    final uri = _uri(path);
    final payload = <String, dynamic>{
      'fileName': fileName,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'videoDuration': videoDuration,
      'matchMode': matchMode,
    };
    final headers = _authHeaders(path);
    headers['Content-Type'] = 'application/json; charset=utf-8';
    final resp = await _transport.send(
      method: 'POST',
      uri: uri,
      headers: headers,
      body: jsonEncode(payload),
    );
    final j = _decode(resp, '匹配弹幕库', uri);
    final raw = j['matches'];
    final out = <DanmakuMatch>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final m = DanmakuMatch.fromJson(e);
          if (m != null) out.add(m);
        }
      }
    }
    return out;
  }

  /// 2) 取某个弹幕库的全部弹幕
  ///
  /// ★ 官方 swagger 里这个接口**唯一**的响应码是 **302**，
  /// 所以传输层必须跟随重定向（[IoDanmakuTransport] 默认跟随）。
  /// 用 `dart:io` 直接发而不跟随的话，永远只能拿到一个空的重定向响应。
  Future<List<DanmakuComment>> fetchComments(
    int episodeId, {
    bool withRelated = true,
    int chConvert = 0,
    double shift = 0,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final uri = _uri(path, <String, String>{
      'withRelated': withRelated ? 'true' : 'false',
      if (chConvert != 0) 'chConvert': '$chConvert',
    });
    final resp = await _transport.send(
      method: 'GET',
      uri: uri,
      headers: _authHeaders(path),
    );
    final j = _decode(resp, '获取弹幕', uri);
    return _parseComments(j, shift: shift);
  }

  /// 3) 退路：按番剧名 / 集数搜索剧集
  ///
  /// 用在"文件名匹配不到"的时候（本地文件名常常是 `第03集` 这种），
  /// 用户也可以手动输入番剧名来搜。
  Future<List<DanmakuMatch>> searchEpisodes({
    String anime = '',
    String episode = '',
  }) async {
    const path = '/api/v2/search/episodes';
    final uri = _uri(path, <String, String>{
      if (anime.isNotEmpty) 'anime': anime,
      if (episode.isNotEmpty) 'episode': episode,
    });
    final resp = await _transport.send(
      method: 'GET',
      uri: uri,
      headers: _authHeaders(path),
    );
    final j = _decode(resp, '搜索剧集', uri);
    final animes = j['animes'];
    final out = <DanmakuMatch>[];
    if (animes is List) {
      for (final a in animes) {
        if (a is! Map<String, dynamic>) continue;
        final title = a['animeTitle']?.toString() ?? '';
        final eps = a['episodes'];
        if (eps is! List) continue;
        for (final e in eps) {
          if (e is! Map<String, dynamic>) continue;
          final id = _asInt(e['episodeId']);
          if (id == null || id <= 0) continue;
          out.add(DanmakuMatch(
            episodeId: id,
            animeTitle: title,
            episodeTitle: e['episodeTitle']?.toString() ?? '',
          ));
        }
      }
    }
    return out;
  }

  /// 一条龙：文件名 -> 弹幕列表（匹配不到就自动走 search 退路）
  ///
  /// [anime] / [episode] 是给退路用的关键词，通常传当前剧集标题。
  /// 命中多条匹配结果时**不自动选**（返回 [DanmakuMatch] 列表让 UI 问用户），
  /// 只有唯一一条才自动取 —— 对应官方 `isMatched` 的语义。
  Future<DanmakuFetchResult> loadFor({
    required String fileName,
    int videoDuration = 0,
    String anime = '',
    String episode = '',
    bool allowSearchFallback = true,
  }) async {
    final matches = await match(
      fileName: fileName,
      videoDuration: videoDuration,
    );
    if (matches.isNotEmpty) {
      final m = matches.first;
      final cs = await fetchComments(m.episodeId, shift: m.shift);
      return DanmakuFetchResult(
        comments: cs,
        match: m,
        matchedBy: 'match',
        matchMode: defaultMatchMode,
      );
    }
    if (!allowSearchFallback) {
      throw DanmakuException('没有匹配到弹幕库（fileName=$fileName）');
    }
    final found = await searchEpisodes(anime: anime, episode: episode);
    if (found.isEmpty) {
      throw DanmakuException('没有匹配到弹幕库（fileName=$fileName）');
    }
    final m = found.first;
    final cs = await fetchComments(m.episodeId);
    return DanmakuFetchResult(
      comments: cs,
      match: m,
      matchedBy: 'search',
      matchMode: 'searchEpisodes',
    );
  }

  /// 把一个 `CommentResponseV2` 的 JSON 拆成弹幕列表
  ///
  /// 单独抽出来是因为测试要能直接喂 JSON，不经过网络。
  static List<DanmakuComment> _parseComments(
    Map<String, dynamic> j, {
    double shift = 0,
  }) {
    final raw = j['comments'];
    final out = <DanmakuComment>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map<String, dynamic>) continue;
        final c = DanmakuComment.fromJson(e, shift: shift);
        if (c != null) out.add(c);
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  void close() => _transport.close();
}

/// 正文看起来像网页吗（CDN 错误页 / 人机校验页）
///
/// 只认**开头**的特征，不做全文搜索 —— 正常 JSON 正文里出现 "html"
/// 这个词的概率不低，全文匹配会误判。
/// 实测来源：B 站搜索接口在 Referer 不对时回 HTTP 200 + text/html
/// 的风控页（见 lib/core/bili/bili_api.dart 的 searchVideos）。
bool _looksLikeHtml(String body) {
  final s = body.trimLeft().toLowerCase();
  return s.startsWith('<!doctype html') || s.startsWith('<html');
}

/// 正文太长时截断，避免把整个响应塞进异常对象和 UI
String _clip(String s, [int max = 2000]) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…（已截断，共 ${s.length} 字）';
}

// -----------------------------------------------------------------------
// 排版：轨道分配（纯函数，可单测、可离线证明"不重叠"）
// -----------------------------------------------------------------------
//
// 这一层刻意**不碰任何 widget / dart:ui 类型**，只做数学：
// 输入一串弹幕 + 画面尺寸 + 字号，输出每条弹幕"在第几轨道、什么时候、
// 从哪儿到哪儿"。渲染层（danmaku_overlay.dart）只负责照着画。
//
// 好处："不重叠"这个验收点可以用纯计算证明（test/task13_danmaku_test.dart
// 会把所有弹幕在时间轴上密集采样，逐帧做矩形相交检测），
// 不依赖截图肉眼看。

/// 一个矩形（左、上、宽、高）—— 不引 dart:ui，保持本文件纯 Dart
class DanmakuBox {
  const DanmakuBox(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// 两个矩形是否**有面积**相交（只是贴边不算）
  bool overlaps(DanmakuBox o, {double epsilon = 0.5}) {
    if (right <= o.left + epsilon) return false;
    if (o.right <= left + epsilon) return false;
    if (bottom <= o.top + epsilon) return false;
    if (o.bottom <= top + epsilon) return false;
    return true;
  }

  @override
  String toString() => 'DanmakuBox(${left.toStringAsFixed(1)}, '
      '${top.toStringAsFixed(1)}, ${width.toStringAsFixed(1)}, '
      '${height.toStringAsFixed(1)})';
}

/// 一条弹幕被分配到轨道之后的结果
class DanmakuPlacement {
  const DanmakuPlacement({
    required this.comment,
    required this.lane,
    required this.laneTop,
    required this.width,
    required this.enterAt,
    required this.exitAt,
    required this.speed,
    required this.fixed,
    required this.fontSize,
  });

  final DanmakuComment comment;

  /// 轨道序号（0 在最上面）
  final int lane;

  /// 轨道顶部 y（相对弹幕区域顶部，未加任何偏移）
  final double laneTop;

  /// 估算的文本宽度
  final double width;

  /// 开始出现的时间（秒）—— 等于弹幕自己的时间戳
  final double enterAt;

  /// 完全离开的时间（秒）；固定弹幕 = 出现时间 + 停留时长
  final double exitAt;

  /// 水平速度（px/s）；固定弹幕为 0
  final double speed;

  /// 是否固定弹幕（顶部 / 底部）
  final bool fixed;

  final double fontSize;

  /// 某个时刻的矩形
  ///
  /// [canvasWidth] 是弹幕区域宽度。
  /// 滚动弹幕：从右边 `canvasWidth` 处进入，向左走到 `-width` 离开；
  /// 固定弹幕：水平居中，位置不动。
  DanmakuBox boxAt(double t, double canvasWidth, double lineHeight) {
    final top = laneTop;
    if (fixed) {
      final left = (canvasWidth - width) / 2;
      return DanmakuBox(left, top, width, lineHeight);
    }
    final left = canvasWidth - speed * (t - enterAt);
    return DanmakuBox(left, top, width, lineHeight);
  }

  /// 这个时刻是否**应该**被画出来（还没进画 / 已经出画就跳过）
  ///
  /// ★ 区间是**半开**的 `[enterAt, exitAt)`：
  ///   分配器回收轨道用的判据是 `exitAt < t`（也就是 `t == exitAt` 时轨道已可复用），
  ///   如果这里写成闭区间，就会在 `t == exitAt` 这一瞬间出现"
  ///   上一条还在画、下一条已经进来"的同轨重叠 ——
  ///   单测 `task13_danmaku_test.dart` 的 900 帧逐帧相交检测正是这么抓到它的。
  bool visibleAt(double t) => t >= enterAt && t < exitAt;

  @override
  String toString() => 'DanmakuPlacement(lane $lane, '
      '${enterAt.toStringAsFixed(2)}~${exitAt.toStringAsFixed(2)}s, '
      'w=${width.toStringAsFixed(1)}, ${fixed ? "固定" : "滚动"}, '
      '"${comment.text}")';
}

/// 粗略估算一段文本的像素宽度
///
/// 用于**没有 TextPainter 时**的退路（纯 Dart 单测、离线排版分析）。
/// 渲染层会传入真实的 `TextPainter` 测量结果，两者不要混用。
///
/// 系数：CJK（含全角标点、假名、韩文）按 1.0 em，其余按 0.55 em ——
/// 不追求精确，只保证"长文本占更宽"这个单调关系成立。
double estimateTextWidth(String text, double fontSize) {
  var units = 0.0;
  for (final r in text.runes) {
    units += r < 0x2E80 ? 0.55 : 1.0;
  }
  return units * fontSize;
}

/// 轨道分配器
///
/// ## 规则（决定了"不重叠"是怎么成立的）
///
/// 所有弹幕按时间顺序处理，每条尝试从**上往下**找第一条能放下的轨道。
/// 轨道里已经有的弹幕记为一次"占用"，占用分两种：
/// ```text
/// 滚动弹幕：占用区间 [enterAt, exitAt]，但**只要上一条已经完整进入画面**
///           且留出 gap 的空隙，下一条就能进 —— 因为速度相同，
///           空隙会一直保持，不会追尾。
/// 固定弹幕：整段时间停在原地，必须等它彻底消失才能进。
/// ```
/// 也就是：`下一条的进入时间 >= 上一条要求的时刻`。
/// 两种占用合并成同一个判据后，滚动 / 顶部 / 底部**共用同一批轨道**，
/// 于是任意两条弹幕在任何时刻的矩形都不会相交。
///
/// ## 和常见播放器的差异（刻意为之）
///
/// 多数播放器允许顶部/底部弹幕和滚动弹幕**压在同一个位置**
/// （因为它们看起来"本来就该叠"）。这里不这么做 —— 本项目的验收点
/// 明确要求"不重叠"，所以固定弹幕也占用轨道。
/// 代价是固定弹幕多的时候滚动弹幕可用轨道变少，
/// 放不下的弹幕会被丢弃并计入 [DanmakuLayout.dropped]。
class DanmakuTrackAllocator {
  const DanmakuTrackAllocator._();

  /// 分配轨道
  ///
  /// * [comments] 已按时间排好序（[DandanplayClient] 保证）
  /// * [canvasWidth] / [canvasHeight] 弹幕区域的逻辑像素尺寸
  /// * [fontSize] 字号（px）
  /// * [lineHeight] 单行占用的高度（px），通常 = fontSize * 1.35
  /// * [speed] 滚动弹幕速度（px/s）
  /// * [area] 可用高度比例（0.3 ~ 1.0）
  /// * [fixedSeconds] 固定弹幕停留时长
  /// * [gap] 同轨道两条滚动弹幕之间的最小空隙（px）
  /// * [measure] 文本宽度测量；缺省用 [estimateTextWidth]
  static DanmakuLayout layout({
    required List<DanmakuComment> comments,
    required double canvasWidth,
    required double canvasHeight,
    required double fontSize,
    double? lineHeight,
    double speed = 120,
    double area = 1.0,
    double fixedSeconds = 4.0,
    double gap = 24,
    double Function(String text, double fontSize)? measure,
  }) {
    final lh = lineHeight ?? fontSize * 1.35;
    final measurer = measure ?? estimateTextWidth;
    final v = speed <= 0 ? 1.0 : speed;
    final usable = math.max(canvasHeight * area.clamp(0.05, 1.0), lh);
    final laneCount = math.max(1, (usable / lh).floor());
    final lanes = List<List<_Occ>>.generate(laneCount, (_) => <_Occ>[]);
    final out = <DanmakuPlacement>[];
    var dropped = 0;

    for (final c in comments) {
      final w = math.max(measurer(c.text, fontSize), fontSize);
      final fixed = c.mode.isFixed;
      final t = c.time;
      // 先清掉"以后都不可能再挡路"的占用（时间只增不减，所以安全）
      for (final occ in lanes) {
        occ.removeWhere((o) => o.exitAt < t);
      }
      var placed = false;
      // 顶部固定从上往下找；底部固定从下往上找；滚动从上往下找
      final order = _laneOrder(c.mode, laneCount);
      for (final li in order) {
        final occ = lanes[li];
        var ok = true;
        for (final o in occ) {
          if (t < o.requiredStartFor(fixed, v, gap)) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        final exitAt = fixed ? t + fixedSeconds : t + (canvasWidth + w) / v;
        out.add(DanmakuPlacement(
          comment: c,
          lane: li,
          laneTop: li * lh,
          width: w,
          enterAt: t,
          exitAt: exitAt,
          speed: fixed ? 0 : v,
          fixed: fixed,
          fontSize: fontSize,
        ));
        occ.add(_Occ(
          enterAt: t,
          exitAt: exitAt,
          width: w,
          fixed: fixed,
        ));
        placed = true;
        break;
      }
      if (!placed) dropped++;
    }

    return DanmakuLayout(
      placements: out,
      laneCount: laneCount,
      lineHeight: lh,
      dropped: dropped,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      speed: v,
    );
  }

  /// 轨道搜索顺序：顶部固定从上往下，底部固定从下往上，滚动从上往下。
  /// 底部固定从下往上找，是为了让它优先待在画面下缘（符合直觉）。
  static List<int> _laneOrder(DanmakuMode mode, int laneCount) {
    if (mode == DanmakuMode.bottom) {
      return List<int>.generate(laneCount, (i) => laneCount - 1 - i);
    }
    return List<int>.generate(laneCount, (i) => i);
  }
}

/// 一次排版的完整结果
class DanmakuLayout {
  const DanmakuLayout({
    required this.placements,
    required this.laneCount,
    required this.lineHeight,
    required this.dropped,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.speed,
  });

  final List<DanmakuPlacement> placements;
  final int laneCount;
  final double lineHeight;

  /// 因为所有轨道都被占满而丢掉的条数（如实统计，不要藏）
  final int dropped;

  final double canvasWidth;
  final double canvasHeight;
  final double speed;

  bool get isEmpty => placements.isEmpty;

  int get length => placements.length;

  /// 某个时刻应该画出来的弹幕
  List<DanmakuPlacement> at(double t) {
    final out = <DanmakuPlacement>[];
    for (final p in placements) {
      if (p.visibleAt(t)) out.add(p);
    }
    return out;
  }

  /// 某个时刻所有可见弹幕的矩形（给"不重叠"证明用）
  List<DanmakuBox> boxesAt(double t) {
    final out = <DanmakuBox>[];
    for (final p in at(t)) {
      out.add(p.boxAt(t, canvasWidth, lineHeight));
    }
    return out;
  }

  /// 一行统计，探针日志里打这个
  String get summary => '轨道 $laneCount 条 · 排版 $length 条'
      '${dropped > 0 ? " · 丢弃 $dropped 条" : ""}';
}

/// 轨道里的一次占用（内部用）
class _Occ {
  _Occ({
    required this.enterAt,
    required this.exitAt,
    required this.width,
    required this.fixed,
  });

  final double enterAt;
  final double exitAt;
  final double width;
  final bool fixed;

  /// 下一条弹幕最早能在什么时刻进入这条轨道
  ///
  /// * 上一条是固定弹幕 -> 必须等它整段消失
  /// * 上一条是滚动弹幕，本条也是滚动 -> 只要上一条完整进入画面 + 留出空隙
  /// * 上一条是滚动弹幕，本条是固定 -> 固定弹幕停在原地，必须等滚动弹幕走完
  double requiredStartFor(bool newIsFixed, double speed, double gap) {
    if (fixed || newIsFixed) return exitAt;
    return enterAt + (width + gap) / speed;
  }

  @override
  String toString() => '_Occ(${enterAt.toStringAsFixed(2)}~'
      '${exitAt.toStringAsFixed(2)}s, w=${width.toStringAsFixed(1)}, '
      '${fixed ? "固定" : "滚动"})';
}

