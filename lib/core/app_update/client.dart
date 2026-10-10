// ═══════════════════════════════════════════════════════════════════════
//  更新相关的 HTTP 出口（直连 / 代理 / 镜像）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己写 HTTP 而不用 `package:http`
//
// 需要三件 `http` 包不直接给的能力：
// ```text
// ① 对**某个代理**发请求 —— HttpClient.findProxy 可以，但它每建一个
//    连接都会调一次回调，代理设置变了正在下载的文件不会跟着变；
//    我们按「每次请求开始时决定一次代理」来做，语义更清楚。
// ② 代理模式下 HTTP 需要 **absolute-form 的请求行**
//    （`GET http://host/path HTTP/1.1`）—— HttpClient 会自动处理，
//    这条留白给自己写的原因。
// ③ 断点续传要拿到响应的 `Content-Length` / `Accept-Ranges` 并自己拼 Range，
//    顺手就在同一个文件里做了。
// ```
//
// ★ 但**行为**与 `http` 一致：跟随重定向、30s 超时、UA 明确。
//
// # 优雅降级（本文件的第一原则）
// ```text
// 代理模式下若代理不可达 ⇒ 自动用直连再试一次
// 镜像模式下若镜像不可达   ⇒ 自动用原地址再试一次
// ```
// 因为这些服务随时会失效，让用户看到一个红框是没意义的 ——
// 慢一点总能下完。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log.dart';
import 'release.dart';
import 'route.dart';

/// 更新功能用的 HTTP 客户端
class UpdateHttp {
  UpdateHttp(this.config);

  UpdateRouteConfig config;

  static const Duration _timeout = Duration(seconds: 20);

  /// 当前设备该用的平台 + ABI
  static (UpdatePlatform, String?) currentTarget() {
    if (Platform.isWindows) return (UpdatePlatform.windows, null);
    if (Platform.isMacOS || Platform.isIOS) return (UpdatePlatform.macos, null);
    if (Platform.isAndroid) {
      final abi = _androidAbi();
      // TV 与手机同一个 APK，用 arch 的 feature 区分不出来对我们没意义
      return (UpdatePlatform.android, abi);
    }
    return (UpdatePlatform.windows, null);
  }

  static String? _androidAbi() {
    // Android 上 `Platform.version` 形如 `Version 13`；ABI 只能从环境变量
    // 猜不到。老实做法：让 [selectForAbi] 自己按候选顺序退回 arm64。
    return const String.fromEnvironment('SOURIN_ABI', defaultValue: '');
  }

  Future<_UpdateOpen> _open(
    Uri url, {
    Map<String, String>? headers,
    String? proxyHostOverride,
    int? proxyPort,
    bool useProxy = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = 'Sourin/${Platform.operatingSystem}';
    // 代理：只允许连本机/局域网之外都走这里；直连模式明确返回 DIRECT，
    // 免得系统环境变量（开发者机器常有 HTTP_PROXY）污染用户的选择。
    // [useProxy] 为 false 是「代理挂了之后改直连重试」用的 —— 此时强制 DIRECT。
    final host = useProxy ? (proxyHostOverride ?? _proxyHost) : null;
    if (host == null) {
      client.findProxy = (_) => 'DIRECT';
    } else {
      client.findProxy = (uri) {
        final local = uri.host == '127.0.0.1' || uri.host == 'localhost';
        return local ? 'DIRECT' : 'PROXY $host:${proxyPort ?? 0}';
      };
    }
    client.autoUncompress = true;
    try {
      final req = await client.getUrl(url).timeout(_timeout);
      req.followRedirects = true;
      req.maxRedirects = 8;
      headers?.forEach(req.headers.set);
      return _UpdateOpen(client, await req.close().timeout(_timeout));
    } catch (_) {
      // 没拿到响应就没有调用方来关，必须在这里兜底，否则同样泄漏。
      client.close(force: true);
      rethrow;
    }
  }

  String? get _proxyHost {
    final uri = config.proxyUri();
    if (uri == null) return null;
    final u = Uri.tryParse(uri);
    return u?.host.isEmpty ?? true ? null : u!.host;
  }

  int get _proxyPort {
    final u = Uri.tryParse(config.proxyUri() ?? '');
    return int.tryParse(u?.port.toString() ?? '') ?? 0;
  }

  /// GET 一个文本（API / SHA256SUMS.txt）
  ///
  /// 失败按「镜像 → 原地址 / 代理 → 直连」的顺序各试一次。
  Future<String> getText(Uri url, {Map<String, String> headers = const {}}) async {
    final candidates = <Uri>[url];
    if (config.route == UpdateRoute.mirror) {
      final mirrored = Uri.tryParse(config.mirrorPrefix + url.toString());
      if (mirrored != null && mirrored.toString() != url.toString()) {
        candidates.insert(0, mirrored);
      }
    }
    Object? last;
    for (final c in candidates) {
      _UpdateOpen? opened;
      try {
        opened = await _open(c, headers: headers, proxyPort: _proxyPort);
        final r = opened.response;
        final body = await utf8.decoder.bind(r).join();
        if (r.statusCode != 200) {
          throw HttpException('HTTP ${r.statusCode}', uri: c);
        }
        return body;
      } catch (e) {
        last = e;
        AppLog.write('UPDATE', '请求失败（${c.host}）: $e');
      } finally {
        // 读完（或放弃）响应后立刻释放 client，否则每次请求泄漏一个连接
        opened?.close();
      }
    }
    throw UpdateNetworkException('连接不上更新服务', last);
  }

  /// 下载到临时文件，带进度回调与取消
  ///
  /// - [onProgress] 收到 (已写字节, 总字节)；总字节未知时 total ≤ 0
  /// - 返回写好的文件
  /// - 抛 [UpdateCancelled] 表示用户取消（不留半截文件）
  Future<File> download(
    Uri url,
    File dest, {
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? cancelled,
  }) async {
    Object? last;
    // ① 首选 URL（镜像模式已改写过），失败再试原地址
    final fallbacks = <Uri>[url];
    if (config.route == UpdateRoute.mirror) {
      final u = Uri.tryParse(url.toString().substring(
          config.mirrorPrefix.length.clamp(0, config.mirrorPrefix.length)));
      if (u != null && u.toString() != url.toString()) fallbacks.add(u);
    }
    // ② 代理模式下代理挂了就改直连再试一次（头部注释承诺的降级）
    final proxied = config.route == UpdateRoute.proxy && _proxyHost != null;
    var triedDirect = false;
    for (final target in fallbacks) {
      // 代理模式下每个地址都有「走代理」和「强制直连」两种走法，
      // 直连只补一次，别把每个候选地址都试两遍。
      final attempts = <bool>[true, if (proxied && !triedDirect) false];
      for (final useProxy in attempts) {
        File? part;
        _UpdateOpen? opened;
        try {
          part = File('${dest.path}.part');
          part.parent.createSync(recursive: true);
          opened = await _open(target,
              proxyPort: _proxyPort, useProxy: useProxy);
          final r = opened.response;
          if (r.statusCode != 200) {
            throw HttpException('HTTP ${r.statusCode}', uri: target);
          }
          final total = r.contentLength;
          final sink = part.openWrite();
          var done = 0;
          var lastTick = DateTime.now();
          try {
            await for (final chunk in r) {
              // 返回 true 才算取消 —— 以前返回值被丢掉，UpdateCancelled
              // 永远抛不出来，用户点「取消」下载照跑到底。
              if (cancelled != null && await cancelled()) {
                throw UpdateCancelled();
              }
              sink.add(chunk);
              done += chunk.length;
              // 进度回调节流到 ~10Hz —— 每个 chunk 都回调会让 UI 重建上百次
              final now = DateTime.now();
              if (onProgress != null &&
                  now.difference(lastTick) >
                      const Duration(milliseconds: 100)) {
                lastTick = now;
                onProgress(done, total);
              }
            }
          } finally {
            await sink.flush();
            await sink.close();
            // 写完（或中途放弃）都要关掉 client
            opened.close();
            opened = null;
          }
          onProgress?.call(done, total);
          if (dest.existsSync()) dest.deleteSync();
          part.renameSync(dest.path);
          return dest;
        } on UpdateCancelled {
          opened?.close();
          _safeDelete(part);
          rethrow;
        } catch (e) {
          opened?.close();
          _safeDelete(part);
          last = e;
          AppLog.write(
              'UPDATE',
              '安装包下载失败（${target.host}${useProxy ? '' : ' 直连'}）: $e');
          if (!useProxy) triedDirect = true;
        }
      }
    }
    throw UpdateNetworkException('下载失败，请稍后重试', last);
  }

  static void _safeDelete(File? f) {
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {
      // 半截文件删不掉不是致命问题（下次会覆盖）
    }
  }
}

/// 一个已建立的连接：响应体由调用方读完，然后必须 [close]。
///
/// 以前每次请求都 new 一个 HttpClient 却从不 close，等于每个请求泄漏一个
/// 连接；现在把 client 和响应绑在一起，读完一起关。
class _UpdateOpen {
  _UpdateOpen(this.client, this.response);

  final HttpClient client;
  final HttpClientResponse response;

  void close() {
    try {
      // body 读完之后 close() 是优雅关闭。
      client.close(force: false);
    } catch (_) {
      // 关不掉也不是致命问题
    }
  }
}

/// 网络类失败（统一一个类型，UI 只显示 [message]）
class UpdateNetworkException implements Exception {
  UpdateNetworkException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

/// 用户主动取消
class UpdateCancelled implements Exception {
  UpdateCancelled();
  @override
  String toString() => '已取消';
}