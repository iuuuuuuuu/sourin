// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 第 4 条）整片下载 + 按组存放
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 支持一下下载整个视频,然后按照一组存放,下载视频那个功能挪出来,
// > 支持下载所有集和单个集
//
// # 三个诉求，逐条落点
// ```text
// ① 下载整个视频      ⇒ 本文件：把 HLS 播放列表里的**全部分片**拼成一个文件
// ② 按照一组存放      ⇒ `download_dir.dart`：一部剧一个文件夹
// ③ 下载所有集/单个集 ⇒ `detail_page.dart` 的下载菜单（两个动作）
// ```
//
// # 为什么必须自己拼分片（不能用现成的「另存为」）
// ```text
// 播放地址是 HLS（`#EXTM3U`）——**不是一个文件**，而是几百上千个 .ts 分片
// 的清单。`ClipDownloader.download()` 只会把「清单本身」存下来（几 KB），
// 那不是视频。
// ```
//
// # ★ 为什么分片**不需要**传 headers（这是能实现的关键）
// ```text
// `StreamCandidate.url` 是核心层的**本地代理**地址
//   `http://127.0.0.1:<port>/s/<token>/…`，
// 而核心层的代理会把播放列表里的**每一个子地址**（含 `#EXT-X-KEY`）
// 都改写成它自己的回环地址（见 `lib/core/dlna/referer_proxy.dart:51-58`
// 对同一机制的说明）⇒ 分片请求打到本地代理，防盗链由 Rust 侧处理。
// ⇒ 我们只要按顺序 GET 那些回环地址即可，不需要 Referer/UA。
// ```
//
// # ⚠️ 诚实边界（做不到的如实说，不假装）
// ```text
// · `#EXT-X-KEY:METHOD=AES-128` ⇒ 本仓库没有 AES 依赖，**明确报错**
//   （不下载、不留半截文件、不谎报成功）
// · `#EXT-X-BYTERANGE` 分片 ⇒ 需要 Range 请求，本版本**明确报错**
// · 直播（缺 `#EXT-X-ENDLIST`）⇒ **明确报错**（直播没有「整个视频」）
// ```
library;

import 'dart:async';
import 'dart:io';

import 'app_log.dart';

/// HLS 下载失败（带**可读原因**，UI 直接显示）
class HlsDownloadException implements Exception {
  HlsDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 拿到的正文**不是** HLS 清单（是 mp4 之类的直链）
///
/// ★ 单独一个类型（不是复用 [HlsDownloadException]）：调用方要据此
///   **回退到普通下载**，而真正的失败要往上报 —— 两者必须能分辨。
class HlsNotPlaylistException extends HlsDownloadException {
  HlsNotPlaylistException() : super('这不是 HLS 播放列表');
}

/// 一个媒体分片
class HlsSegment {
  const HlsSegment({required this.uri, this.byteRange});

  final String uri;

  /// `#EXT-X-BYTERANGE` 的原始参数（`长度[@偏移]`）；null = 没有
  final String? byteRange;
}

/// 解析结果
class HlsPlaylist {
  const HlsPlaylist({
    required this.segments,
    required this.isMaster,
    required this.variants,
    required this.encrypted,
    required this.hasEndList,
    required this.initUri,
    required this.isFmp4,
  });

  final List<HlsSegment> segments;

  /// 是不是**主**播放列表（里面是子清单，不是分片）
  final bool isMaster;

  /// 主列表里的子清单地址（出现顺序）
  final List<String> variants;

  /// 有 `#EXT-X-KEY` 且 METHOD 不是 NONE
  final bool encrypted;

  /// 有 `#EXT-X-ENDLIST` ⇒ 是**点播**（直播没有）
  final bool hasEndList;

  /// `#EXT-X-MAP:URI=` —— fMP4 的初始化段，必须拼在最前面
  final String? initUri;

  /// 分片是不是 fMP4（`.m4s` / 有 `#EXT-X-MAP`）
  final bool isFmp4;
}

/// 把 m3u8 文本解析成结构化清单
///
/// ⚠️ 抽成**纯函数**（不碰网络）⇒ 可以单测：真机上不可能复现
///    「加密流 / 直播流 / fMP4」这三种边界。
HlsPlaylist parseHlsPlaylist(String text, {String? baseUrl}) {
  final lines = text.split(RegExp(r'\r?\n'));
  final segments = <HlsSegment>[];
  final variants = <String>[];
  var encrypted = false;
  var hasEndList = false;
  var isMaster = false;
  String? initUri;
  String? pendingRange;
  var sawStreamInf = false;
  var pendingInf = false;

  String abs(String u) {
    final t = u.trim();
    if (t.isEmpty) return t;
    if (baseUrl == null || baseUrl.isEmpty) return t;
    final b = Uri.tryParse(baseUrl);
    if (b == null) return t;
    return b.resolve(t).toString();
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      isMaster = true;
      sawStreamInf = true;
      continue;
    }
    if (line.startsWith('#EXT-X-MEDIA:') && line.contains('URI=')) {
      /*
       * 备选音轨/字幕轨。**不下载** —— 我们下的是主视频；
       * 把外挂音轨也拼进 TS 只会得到一个坏文件。
       */
      continue;
    }
    if (line.startsWith('#EXT-X-KEY')) {
      if (!line.contains('METHOD=NONE')) encrypted = true;
      continue;
    }
    if (line.startsWith('#EXT-X-MAP')) {
      final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (m != null) initUri = abs(m.group(1)!);
      continue;
    }
    if (line.startsWith('#EXT-X-BYTERANGE')) {
      pendingRange = line.substring('#EXT-X-BYTERANGE:'.length).trim();
      continue;
    }
    if (line.startsWith('#EXT-X-ENDLIST')) {
      hasEndList = true;
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      pendingInf = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    // 非注释行 = 地址
    if (sawStreamInf) {
      variants.add(abs(line));
      sawStreamInf = false;
      continue;
    }
    if (pendingInf) {
      segments.add(HlsSegment(uri: abs(line), byteRange: pendingRange));
      pendingRange = null;
      pendingInf = false;
      continue;
    }
    /*
     * ⚠️ 没有 `#EXTINF` 铺垫的裸地址：**不**当分片。
     *   某些源会在媒体列表里混入 `#EXT-X-I-FRAME-STREAM-INF` 的地址，
     *   它们指向的是关键帧清单，拼进去会得到一个坏文件。
     */
  }

  final fmp4 = initUri != null ||
      (segments.isNotEmpty && segments.first.uri.contains('.m4s'));
  return HlsPlaylist(
    segments: segments,
    isMaster: isMaster,
    variants: variants,
    encrypted: encrypted,
    hasEndList: hasEndList,
    initUri: initUri,
    isFmp4: fmp4,
  );
}

/// 整片下载结果
class HlsDownloadResult {
  const HlsDownloadResult({
    required this.path,
    required this.bytes,
    required this.segments,
    required this.elapsed,
  });

  final String path;
  final int bytes;
  final int segments;
  final Duration elapsed;

  double get mb => bytes / 1048576;
}

/// 把一条 HLS 流**整片**下载成一个文件
///
/// # 为什么是「拼成一个文件」而不是「存一个文件夹的分片」
/// ```text
/// 用户要的是「下载整个视频」—— 拿到一个能双击播放的 ts/mp4。
/// 分片目录对他没有意义（播放器也不认）。
/// ```
class HlsDownloader {
  HlsDownloader._();

  static const Duration _timeout = Duration(seconds: 30);

  /// 单次请求的 UA —— 与 `clip_download.dart` 保持一致（同一个程序的身份）
  static const String _userAgent = 'SourinSpike/1.0';

  /// 下载整片
  ///
  /// [url] 可以是主列表也可以是媒体列表（内部会自己下钻一层）。
  /// [intoDir] 与 [fileName] 决定落点（**目录必须已存在**，由调用方建）。
  /// [onProgress] 报 (已完成分片数, 总分片数)。
  static Future<HlsDownloadResult> download({
    required String url,
    required String intoDir,
    required String fileName,
    List<(String, String)> headers = const [],
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = _userAgent;
    final ext = fileName.contains('.') ? '' : '.ts';
    final target = File('$intoDir${Platform.pathSeparator}$fileName$ext');
    final part = File('${target.path}.part');
    var total = 0;
    try {
      // ① 拿清单（主列表先下钻到第一档）
      var mediaUrl = url;
      var text = await _getText(client, mediaUrl, headers);
      if (!text.trimLeft().startsWith('#EXTM3U')) {
        throw HlsNotPlaylistException();
      }
      var pl = parseHlsPlaylist(text, baseUrl: mediaUrl);
      if (pl.isMaster) {
        if (pl.variants.isEmpty) {
          throw HlsDownloadException('主播放列表里没有可用的清晰度');
        }
        mediaUrl = pl.variants.first;
        text = await _getText(client, mediaUrl, headers);
        pl = parseHlsPlaylist(text, baseUrl: mediaUrl);
      }
      if (pl.encrypted) {
        throw HlsDownloadException(
          '这条流是加密的（AES-128），当前版本不支持整片下载。',
        );
      }
      if (!pl.hasEndList) {
        throw HlsDownloadException('这是直播流，没有整片可以下载。');
      }
      if (pl.segments.any((s) => s.byteRange != null)) {
        throw HlsDownloadException('这条流用了分段字节范围，当前版本不支持。');
      }
      if (pl.segments.isEmpty) {
        throw HlsDownloadException('播放列表里没有分片地址。');
      }

      // ② 顺序拉分片，边拉边拼（顺序写 = 拼出来的文件天然可播）
      final sink = part.openWrite();
      var bytes = 0;
      try {
        final ordered = <HlsSegment>[
          if (pl.initUri != null) HlsSegment(uri: pl.initUri!),
          ...pl.segments,
        ];
        total = ordered.length;
        for (var i = 0; i < ordered.length; i++) {
          if (isCancelled?.call() ?? false) {
            throw HlsDownloadException('已取消');
          }
          final seg = await _getBytes(client, ordered[i].uri, headers);
          sink.add(seg);
          bytes += seg.length;
          onProgress?.call(i + 1, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // ③ 落定：先删旧、再改名（与 ClipDownloader 同一套纪律）
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      try {
        await target.setLastModified(DateTime.now());
      } catch (_) {}
      AppLog.write(
        'DL',
        '整片完成 ${target.path}  $total 片 / '
            '${(bytes / 1048576).toStringAsFixed(2)} MB  '
            '${sw.elapsedMilliseconds} ms',
      );
      return HlsDownloadResult(
        path: target.path,
        bytes: bytes,
        segments: total,
        elapsed: sw.elapsed,
      );
    } catch (e) {
      // ★ 失败**绝不留半截文件** —— 与 ClipDownloader 同一条纪律
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      AppLog.write('DL', '整片失败 $fileName  $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _getText(
    HttpClient client,
    String url,
    List<(String, String)> headers,
  ) async {
    final b = await _getBytes(client, url, headers);
    return String.fromCharCodes(b);
  }

  static Future<List<int>> _getBytes(
    HttpClient client,
    String url,
    List<(String, String)> headers,
  ) async {
    final req = await client.getUrl(Uri.parse(url));
    for (final h in headers) {
      req.headers.set(h.$1, h.$2);
    }
    final resp = await req.close().timeout(_timeout);
    if (resp.statusCode != 200) {
      throw HlsDownloadException('HTTP ${resp.statusCode}  $url');
    }
    final out = <int>[];
    await for (final chunk in resp) {
      out.addAll(chunk);
    }
    return out;
  }

  /// 判断一个响应是不是 HLS 清单（给 UI 决定走哪条下载路径）
  ///
  /// # 为什么看 Content-Type 而不是看 URL 后缀
  /// ```text
  /// 核心层返回的是 `http://127.0.0.1:<port>/s/<token>/` —— **没有 .m3u8 后缀**。
  /// 靠后缀判会把每一条流都判成非 HLS。
  /// ```
  static bool looksLikeHls({String? contentType, String? url}) {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.contains('mpegurl')) return true;
    final u = (url ?? '').toLowerCase();
    final p = Uri.tryParse(u)?.path ?? '';
    return p.endsWith('.m3u8') || p.endsWith('.m3u');
  }
}
