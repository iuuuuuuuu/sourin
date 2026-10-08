// ═══════════════════════════════════════════════════════════════════════
//  DLNA 公共设施：错误类型 / URL 解析 / 共享 HTTP 客户端（task-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// ```text
// 错误类型   —— 5 个模块都要抛/接，各自定义会导致 UI 层 import 5 个文件才能 catch
// URL 解析   —— description / soap / proxy 三处都要把"设备给的相对地址"变绝对
// HTTP 客户端 —— 三处都要带超时的 HttpClient（默认 HttpClient 的连接超时是
//               无限 —— 设备不在线时整个页面**永远转圈**，这是真机最难受的 bug）
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ═══════════════════════════════════════════════════════════════════════
//  错误
// ═══════════════════════════════════════════════════════════════════════

/// DLNA 链路上的错误 —— **一定带一句人话**
///
/// # 为什么不用 `Exception('...')`
///
/// UI 要把这句话**原样显示**给用户（本项目禁止"操作失败"这种无信息文案）。
/// 而 `SocketException` / `TimeoutException` 的 `toString()` 是英文 + 一堆
/// 内部字段，直接显示等于没显示。所以这里强制两层：
/// ```text
///   message  面向用户的一句中文（"设备 192.168.1.7 没有响应（超时 3 秒）"）
///   detail   原始错误（`SocketException: Connection refused`），给日志
/// ```
class DlnaException implements Exception {
  DlnaException(this.message, {this.detail});

  /// 面向用户的中文说明（UI 直接显示这句）
  final String message;

  /// 原始错误文本（进日志，不进 UI）
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

// ═══════════════════════════════════════════════════════════════════════
//  URL 解析
// ═══════════════════════════════════════════════════════════════════════

/// 把设备给的地址变成绝对地址
///
/// # 为什么必须做（不是"防御性编程"）
///
/// UPnP 规范允许 `controlURL` 是**相对**的，而真机实现三种都出现过：
/// ```text
///   http://192.168.1.7:49152/upnp/control/AVTransport   ← 绝对
///   /upnp/control/AVTransport                            ← 根相对
///   upnp/control/AVTransport                             ← 文档相对（★ 最坑）
/// ```
/// 第三种要相对于 **description 文档所在的目录** 解析。
/// 不解析的后果：请求发到 `http://192.168.1.7:49152/upnp/control/AVTransport`
/// （碰巧对）或 `http://192.168.1.7:49152/AVTransport`（404，而且报错说"设备不支持"）。
///
/// ★ 用 `Uri.resolve`（RFC 3986 标准实现）而不是手写字符串拼接 ——
///   手写版本处理不了 `..`、`//host/`、只带 query 这些形式。
String? resolveUrl(String? ref, String base) {
  if (ref == null) return null;
  final r = ref.trim();
  if (r.isEmpty) return null;
  if (r.startsWith('http://') || r.startsWith('https://')) return r;
  try {
    return Uri.parse(base).resolve(r).toString();
  } catch (_) {
    // base 本身畸形时退化成朴素拼接，总比返回 null 好
    final i = base.lastIndexOf('/');
    final dir = i < 0 ? base : base.substring(0, i + 1);
    return r.startsWith('/') ? dir.replaceAll(RegExp(r'//[^/]*$'), '') + r : dir + r;
  }
}

/// 取 URL 的 `scheme://host[:port]`（没有路径）
String originOf(String url) {
  try {
    final u = Uri.parse(url);
    return u.hasPort ? '${u.scheme}://${u.host}:${u.port}' : '${u.scheme}://${u.host}';
  } catch (_) {
    return url;
  }
}

/// 取主机名（去掉端口），日志用
String hostOf(String url) {
  try {
    return Uri.parse(url).host;
  } catch (_) {
    return url;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  HTTP
// ═══════════════════════════════════════════════════════════════════════

/// 设备描述与 SOAP 共用的 HTTP 工具
abstract final class DlnaHttp {
  /// ★ 默认超时 —— 数字是**故意**这么小的
  ///
  /// 局域网里 UPnP 设备的正常响应是毫秒级。3 秒还不回 = 设备睡了/掉线了。
  /// 设成 30 秒的话，用户点了投屏要盯着转圈半分钟才被告知失败。
  static const Duration defaultTimeout = Duration(seconds: 3);

  /// 建一个带超时的客户端
  ///
  /// ⚠️ `HttpClient.connectionTimeout` **只管建连**，不管"连上了但不回数据"。
  ///    后者要靠每次请求的 `.timeout()`（见 [getText]）—— 两个都要有，
  ///    少一个就会在某些设备上永久挂住。
  static HttpClient newClient({
    Duration connectTimeout = defaultTimeout,
    bool keepAlive = true,
  }) {
    final c = HttpClient();
    c.connectionTimeout = connectTimeout;
    c.idleTimeout = const Duration(seconds: 15);
    if (!keepAlive) c.maxConnectionsPerHost = 1;
    // UPnP 设备多数只认 HTTP/1.1，且对 gzip 支持很差
    c.autoUncompress = false;
    return c;
  }

  /// GET 一段文本（带整体超时）
  ///
  /// 抛 [DlnaException]，消息里**带上 URL 与超时值** ——
  /// 用户看到"设备 192.168.1.7:49152 没有响应（超时 3 秒）"才知道下一步做什么。
  static Future<String> getText(
    String url, {
    Duration timeout = defaultTimeout,
    Map<String, String>? headers,
    HttpClient? client,
  }) async {
    final c = client ?? newClient(connectTimeout: timeout);
    final owned = client == null;
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(timeout);
      if (headers != null) {
        headers.forEach(req.headers.set);
      }
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(timeout);
      final body = await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw DlnaException(
          '设备返回 HTTP ${res.statusCode}（$url）',
          detail: body.length > 200 ? body.substring(0, 200) : body,
        );
      }
      return body;
    } on DlnaException {
      rethrow;
    } on TimeoutException {
      throw DlnaException(
        '设备 ${hostOf(url)} 没有响应（超时 ${timeout.inSeconds} 秒）',
        detail: 'TimeoutException after $timeout',
      );
    } on SocketException catch (e) {
      throw DlnaException(
        '连不上设备 ${hostOf(url)}（${e.osError?.message ?? e.message}）',
        detail: e.toString(),
      );
    } catch (e) {
      throw DlnaException('读取 $url 失败', detail: e.toString());
    } finally {
      if (owned) c.close(force: true);
    }
  }

  /// POST 一段 XML 并**把 body 原样带回来**（SOAP 的错也带 body）
  ///
  /// ⚠️ 与 [getText] 的关键区别：**HTTP 非 2xx 不抛异常**。
  ///    UPnP 的 SOAP 故障就是这样回来的 —— `HTTP/1.1 500` +
  ///    `<s:Fault><faultstring>...` 的 body。若这里按状态码抛，
  ///    调用方就永远读不到设备说的那句话，UI 只能显示"操作失败"。
  static Future<HttpText> postXml(
    String url,
    String body, {
    required Map<String, String> headers,
    Duration timeout = defaultTimeout,
    HttpClient? client,
  }) async {
    final c = client ?? newClient(connectTimeout: timeout);
    final owned = client == null;
    try {
      final req = await c.postUrl(Uri.parse(url)).timeout(timeout);
      headers.forEach(req.headers.set);
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final text = await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      final hs = <String, String>{};
      res.headers.forEach((k, v) => hs[k.toLowerCase()] = v.join(', '));
      return HttpText(statusCode: res.statusCode, body: text, headers: hs);
    } on TimeoutException {
      throw DlnaException(
        '设备 ${hostOf(url)} 没有响应（超时 ${timeout.inSeconds} 秒）',
        detail: 'TimeoutException after $timeout',
      );
    } on SocketException catch (e) {
      throw DlnaException(
        '连不上设备 ${hostOf(url)}（${e.osError?.message ?? e.message}）',
        detail: e.toString(),
      );
    } catch (e) {
      throw DlnaException('向 $url 发送请求失败', detail: e.toString());
    } finally {
      if (owned) c.close(force: true);
    }
  }
}

/// 一次 HTTP 文本响应（状态码 + body + 小写键的响应头）
class HttpText {
  HttpText({required this.statusCode, required this.body, required this.headers});

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

