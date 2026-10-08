// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 第 4 条）整片下载队列
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 支持一下下载整个视频,然后按照一组存放,下载视频那个功能挪出来,
// > 支持下载所有集和单个集
//
// # 它解决什么
// ```text
// 「下载所有集」= 几十个整片下载 ⇒ 必须**串行**（并发拉几十条流会把
// 本地代理和上游一起打爆），而且要有一个**全局可观察**的进度，
// 因为用户点完就切走别的页面了 —— 下载不能跟着页面 State 一起没。
// ```
//
// # ★ 为什么任务里存的是「怎么解析流」而不是「流地址」
// ```text
// 改前我想的是「入队时把 url 解析好」。那对「下载所有集」是错的：
//   · 24 集就要**一次性**向核心层要 24 条流 ⇒ 而核心层的流表是
//     **256 条 FIFO**（rust/sourin_core/src/streamproxy.rs）——
//     一口气占掉 24 条，正常播放的流会被挤掉；
//   · 而且用户可能点完立刻取消，那 24 次解析全是白做的。
// ⇒ 任务只存 (provider, id, episodeId, sourceCode)，
//   **轮到它跑的时候**才 `resolve_stream`（用一条、解析一条）。
// ```
//
// # ★ 为什么是进程级单例（而不是挂在某个页面的 State 里）
// ```text
// ① 用户从详情页点「下载所有集」之后会**切到别的 tab** ——
//    若队列活在 DetailPage 的 State 里，页面一 dispose 队列就断了；
// ② 关闭确认要知道「还有几个任务在跑」。
// ```
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'clip_download.dart';
import 'download_dir.dart';
import 'hls_download.dart';
import 'sourin_api.dart';

/// 一个整片下载任务的对外快照（**不可变** ⇒ 直接喂给 ValueListenableBuilder）
@immutable
class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.title,
    required this.episodeTitle,
    required this.provider,
    required this.mediaId,
    required this.episodeId,
    required this.sourceCode,
    required this.fileName,
    this.done = 0,
    this.total = 0,
    this.state = DownloadState.queued,
    this.error,
    this.path,
  });

  /// 稳定 id（`provider:mediaId:episodeId`）—— 用来去重
  final String id;

  /// 作品名（＝**文件夹名**，见 `DownloadDir.forWork`）
  final String title;
  final String episodeTitle;

  final String provider;
  final String mediaId;
  final String episodeId;
  final String? sourceCode;

  /// 落盘文件名（不含目录、不含扩展名）
  final String fileName;

  /// 已完成分片 / 总分片（0 表示还没拿到清单）
  final int done;
  final int total;

  final DownloadState state;
  final String? error;
  final String? path;

  double get progress => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);

  DownloadTask copyWith({
    int? done,
    int? total,
    DownloadState? state,
    String? error,
    String? path,
    bool clearError = false,
  }) =>
      DownloadTask(
        id: id,
        title: title,
        episodeTitle: episodeTitle,
        provider: provider,
        mediaId: mediaId,
        episodeId: episodeId,
        sourceCode: sourceCode,
        fileName: fileName,
        done: done ?? this.done,
        total: total ?? this.total,
        state: state ?? this.state,
        error: clearError ? null : (error ?? this.error),
        path: path ?? this.path,
      );
}

/// 任务状态
enum DownloadState { queued, running, done, failed }

/// 整片下载队列（**进程级单例**）
class DownloadQueue {
  DownloadQueue._();

  static final DownloadQueue instance = DownloadQueue._();

  /// 对外只读快照 —— UI 直接 `ValueListenableBuilder` 它
  static final ValueNotifier<List<DownloadTask>> tasks =
      ValueNotifier<List<DownloadTask>>(const []);

  /// 队列本体（含已完成的，供 UI 显示下载记录）
  static final List<DownloadTask> _list = <DownloadTask>[];

  static bool _pumping = false;

  /// 是否还有在排队/在跑的任务
  static bool get busy => activeCount > 0;

  /// 正在跑 / 排队的条数
  static int get activeCount => _list
      .where((t) =>
          t.state == DownloadState.queued || t.state == DownloadState.running)
      .length;

  /// 测试用：清空
  static void debugReset() {
    _list.clear();
    tasks.value = const [];
  }

  static void _publish() => tasks.value = List<DownloadTask>.unmodifiable(_list);

  /// 入队一集（返回 false = 已在队列里，调用方据此提示）
  static bool enqueue(DownloadTask t) {
    final dup = _list.any((x) =>
        x.id == t.id &&
        (x.state == DownloadState.queued ||
            x.state == DownloadState.running));
    if (dup) return false;
    _list.add(t);
    _publish();
    unawaited(_pump());
    return true;
  }

  /// 取消一个还在排队/在跑的任务
  static void cancel(String id) {
    final i = _list.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final t = _list[i];
    if (t.state == DownloadState.done || t.state == DownloadState.failed) {
      return;
    }
    _list[i] = t.copyWith(state: DownloadState.failed, error: '已取消');
    _publish();
  }

  /// 清掉已完成/已失败（UI 的「清空记录」）
  static void clearFinished() {
    _list.removeWhere((t) =>
        t.state == DownloadState.done || t.state == DownloadState.failed);
    _publish();
  }

  /// 串行泵：一次只跑一个
  ///
  /// # 为什么是串行（不是复用 ClipDownloader 的 4 并发池）
  /// ```text
  /// 那 4 个槽位是给**片段**下载用的（几 MB）。整片下载一集几百 MB、
  /// 内部还要顺序拉几百个分片 —— 四条这样的流并行，本地代理的
  /// 256 条 FIFO 流表会被瞬间打满，结果是**所有**流（含正在播的那条）
  /// 一起卡。⇒ 整片下载**串行**，把带宽让给播放。
  /// ```
  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final i = _list.indexWhere((t) => t.state == DownloadState.queued);
        if (i < 0) break;
        await _run(i);
      }
    } finally {
      _pumping = false;
    }
  }

  static Future<void> _run(int i) async {
    final t = _list[i].copyWith(state: DownloadState.running, clearError: true);
    _list[i] = t;
    _publish();
    try {
      /*
       * ① 轮到它了才解析流（见文件头的说明）——
       *    一次只占核心层流表里的一条。
       */
      final st = await SourinApi.firstPlayable(
        t.provider,
        t.mediaId,
        req: PlayRequest(
          episodeId: t.episodeId,
          sourceCode: t.sourceCode,
        ),
      );
      if (st == null) {
        throw HlsDownloadException('这条线路没有可用的流');
      }
      final dir = await DownloadDir.forWork(t.title);

      void onProg(int done, int total) {
        /*
         * ⚠️ 每片都 publish 会疯狂重建（一集几百片）—— 每 8 片报一次。
         *   最后一片必报（done == total）⇒ 进度条一定走到 100%。
         */
        if (done != total && done % 8 != 0) return;
        final cur = _list[i];
        if (cur.state != DownloadState.running) return;
        _list[i] = cur.copyWith(done: done, total: total);
        _publish();
      }

      bool cancelled() => _list[i].state == DownloadState.failed;

      /*
       * ② 先按 HLS 试。
       *
       * ★ 为什么敢直接试：`HlsDownloader` 拿到正文先判 `#EXTM3U`，
       *   不是清单会抛 `HlsNotPlaylistException` —— 那是**预期**分支，
       *   不是错误（mp4 直链就是这种情况），所以这里静默回退。
       */
      String path;
      int bytes;
      try {
        final r = await HlsDownloader.download(
          url: st.url,
          intoDir: dir,
          fileName: t.fileName,
          headers: st.headers,
          onProgress: onProg,
          isCancelled: cancelled,
        );
        path = r.path;
        bytes = r.bytes;
      } on HlsNotPlaylistException {
        final r = await ClipDownloader.download(
          url: st.url,
          fileName: '${t.fileName}.mp4',
          headers: st.headers,
          intoDir: dir,
          enforceLimitAfter: false,
        );
        path = r.path;
        bytes = r.bytes;
      }

      _list[i] = _list[i].copyWith(
        state: DownloadState.done,
        done: _list[i].total,
        path: path,
      );
      AppLog.write(
        'DL',
        '队列完成 ${t.fileName}  ${(bytes / 1048576).toStringAsFixed(1)} MB',
      );
    } catch (e) {
      _list[i] = _list[i].copyWith(state: DownloadState.failed, error: '$e');
      AppLog.write('DL', '队列失败 ${t.fileName}  $e');
    }
    _publish();
  }
}
