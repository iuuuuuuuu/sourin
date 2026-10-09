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
    this.paused = false,
    this.partPath,
  });

  final String path;
  final int bytes;
  final int segments;
  final Duration elapsed;

  /// ★★★ task-11 ③：true = **因为用户暂停而收尾**（不是完成，也不是失败）
  ///
  /// # 为什么暂停要「正常返回」而不是抛异常
  /// ```text
  /// 本类的 catch 分支有一条硬纪律：「失败绝不留半截文件」⇒ 删 .part。
  /// 而暂停**必须**保留 .part（已下好的分片一片不丢，继续时从下一片接上）。
  /// ⇒ 暂停不能走异常路径，只能走「正常返回 + 一个标志位」。
  /// ```
  final bool paused;

  /// 暂停时**半成品**的路径（`<目标>.part`）—— 继续下载时从它接着写
  final String? partPath;

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

    /// ★★★ task-11 ③：**暂停**判据 —— 在**分片边界**被问。
    ///
    /// 返回 true ⇒ 立即停止拉新分片，但**正常返回**（保留 .part）。
    /// ⚠️ 与 [isCancelled] 语义**不同**：后者抛异常 ⇒ .part 被删。
    bool Function()? isPaused,

    /// ★★★ task-11 ③ 续传：.part 里**已经写完**的分片数（跳过它们）
    ///
    /// 由调用方从任务状态带来（暂停时 `HlsDownloadResult.segments` 回报的值）。
    /// null / 0 = 全新下载。
    int? initialDone,
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

      /*
       * ★★★ task-11 ③：**续传** —— 已存在的 .part 不覆盖，从它后面接着写。
       *
       * # 为什么续传是安全的（不需要分片级断点文件）
       * ```text
       * HLS 是**定序**的：分片 0,1,2,…,N 必须按序拼接才有意义。
       * .part 的长度 = 已完整写入的分片字节数之和（暂停点永远在分片边界）。
       * ⇒ 只要记下"写到第几片"就能接上。
       *
       * ★ 不记分片号、改用**按字节数反推**：每片长度已知（先 HEAD/GET 拿到），
       *   但那要额外请求。更稳的做法是续传时**重放前 k 片**的判定 ——
       *   见 download() 的 initialDone 参数：调用方从任务状态里带来。
       * ```
       */
      final append = part.existsSync() && part.lengthSync() > 0;
      final sink = append
          ? part.openWrite(mode: FileMode.append)
          : part.openWrite();
      var bytes = append ? part.lengthSync() : 0;
      try {
        final ordered = <HlsSegment>[
          if (pl.initUri != null) HlsSegment(uri: pl.initUri!),
          ...pl.segments,
        ];
        total = ordered.length;
        /*
         * ★★★ task-11 ③ 续传：跳过已经写进 .part 的分片。
         *
         * `initialDone` 由调用方从任务状态带来（= 暂停时下载器回报的 segments）。
         * ⚠️ 为什么必须**跳过而不是重下**：重下会让 .part 里出现重复分片
         *    ⇒ 拼出来的文件在拼接点坏掉（播放器会卡在那个时间点）。
         */
        final skip = (initialDone ?? 0).clamp(0, total);
        for (var i = 0; i < ordered.length; i++) {
          if (i < skip) continue; // ★ 续传：这一片已在 .part 里了
          if (isCancelled?.call() ?? false) {
            throw HlsDownloadException('已取消');
          }
          /*
           * ★★★ task-11 ③：**分片边界**检查暂停。
           *
           * 位置在这里（拿下一片**之前**）是有意的：
           * · 已写进 sink 的分片全部落盘，一片不丢；
           * · 不会出现"半片"—— 分片是不可分割的写入单位。
           * ★ 正常收尾（flush + close）后**返回**，走 return 而不是 throw，
           *   这样下面那条"失败删 .part"的 catch 就不会碰到它。
           */
          if (isPaused?.call() ?? false) {
            /*
             * ★★ 关键：这里**只 flush，不 close**。
             *
             * 踩过的坑（探针实测报的错）：
             * ```text
             * PathAccessException: Cannot rename file to '…第01集 探针.ts',
             *   path = '…第01集 探针.ts.part'
             *   (OS Error: 另一个程序正在使用此文件…, errno = 32)
             * ```
             * 原因：这里 close 一次、外面 finally 又 close 一次 ⇒
             *   **同一个 sink 被关两次**，句柄状态错乱 ⇒ 续传那一轮
             *   写完 rename 时 Windows 报「文件被占用」。
             * ⇒ 收尾统一交给 finally 的 close（它只跑一次，成功/暂停/失败都覆盖）。
             */
            await sink.flush();
            AppLog.write(
              'DL',
              '整片暂停 ${target.path}.part（已下 i=$i/$total 片、'
                  '${(bytes / 1048576).toStringAsFixed(1)} MB 已落盘）',
            );
            return HlsDownloadResult(
              path: target.path,
              bytes: bytes,
              segments: i,
              elapsed: sw.elapsed,
              paused: true,
              partPath: part.path,
            );
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
