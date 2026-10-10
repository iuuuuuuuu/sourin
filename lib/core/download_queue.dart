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
// 「下载所有集」= 几十个整片下载 ⇒ 默认**串行**（并发拉几十条流会把
// 本地代理和上游一起打爆），而且要有一个**全局可观察**的进度，
// 因为用户点完就切走别的页面了 —— 下载不能跟着页面 State 一起没。
// ```
//
// # ★★★ 2026-10-09（Owner 第 20 条）并发数要**可配置**
//
// 用户原话（逐字）：
// > 并发数可配置
//
// ```text
// 改前：_pump() 里 while(true) { await _run(i); } —— 一次只跑一个，
//       刻在代码里，用户想「我网快，同时下 2 集」没有出口。
// 改后：同一个 _pump() 改成「同时最多 N 个 _run() 在飞」，N 来自 pref。
//       ★★ 默认仍是 1 ⇒ 不配置时行为与改动前**逐字相同**。
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
import 'dart:convert';
// ★ task-11 ③④：删除任务/整剧删除要碰文件系统（File/Directory/Platform）
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'clip_download.dart';
import 'download_dir.dart';
import 'hls_download.dart';
import 'sourin_api.dart';
import 'ui_prefs.dart';

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
    this.cover,
    this.description,
    this.year,
    this.area,
    this.kind,
    this.badges = const [],
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

  /// ★★★ task-11 ④：封面地址（可空）—— 与 title 同级，供「已缓存」页展示。
  ///
  /// 为什么加在这里：`DownloadTask` 是**唯一的**跨层进度载体
  /// （详情页入队 → 队列跑 → 面板/已缓存页读），封面挂它上面才不会
  /// 让每个消费方各自再去查一次详情接口。
  final String? cover;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ Owner 第 1009 批 13：随下载一起**缓存作品元数据**
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么这四个字段必须**下载那一刻**就记下来
  // ```text
  // 本地播放页要"跟在线播放页一模一样"：标题、简介、年份、地区、类型、角标。
  // 而这些**只有详情接口能给** —— 离线时核心也拿不到（本地没有 provider 可路由）。
  // ⇒ 唯一能离线显示的时机就是**下载那一刻还在线**。
  // ★ 全部可空：老任务 / 插件没给 → 本地页降级显示（不编造），不崩。
  // ```
  final String? description;
  final String? year;
  final String? area;
  final String? kind;

  /// 后端拼好的角标（「连载中」「9.2 分」…）—— 与在线页显示的是**同一份**
  final List<String> badges;

  double get progress => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);

  DownloadTask copyWith({
    int? done,
    int? total,
    DownloadState? state,
    String? error,
    String? path,
    String? cover,
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
        cover: cover ?? this.cover,
        // ★ 元数据不参与 copyWith：它们在入队时就定了，
        //   队列里的状态变更（进度/状态/错误）不应该把它们抹掉。
        description: description,
        year: year,
        area: area,
        kind: kind,
        badges: badges,
      );
}

/// 任务状态
///
/// ★★★ task-11 ③：新增 paused
///
/// # 为什么 paused 必须是**独立枚举值**而不是复用一个 bool
/// ```text
/// 用户要「暂停 / 继续」。若用 bool paused 叠在 running 上：
///   · UI 判「这一行画不画暂停按钮」要同时看两个字段（易错）
///   · _pump 的槽位计数只看 running ⇒ 暂停的任务会**白占一个并发槽**，
///     把后面排队的堵到天荒地老
/// ⇒ 独立枚举值，三处判据（UI / 槽位 / 泵）各看一眼就够。
/// ```
enum DownloadState { queued, running, paused, done, failed }

/// ★★★ task-11 ④：整剧删除的**预览**（真删前给用户看「将删什么」）
///
/// 为什么必须有它：整剧删除是**真删文件、不可逆**。用户点之前必须看到
/// 「几集 / 多少 MB」—— 这正是 Owner 说的「在外面也应该可以进行整部剧的删除操作」
/// 的安全前提。
@immutable
class WorkRemovalPreview {
  const WorkRemovalPreview({
    required this.title,
    required this.fileCount,
    required this.bytes,
    required this.fileNames,
    required this.episodeCount,
  });

  final String title;

  /// 目录里的文件个数（含 .part）
  final int fileCount;

  /// 目录里所有文件的字节总数
  final int bytes;

  /// 文件名清单（供确认弹窗列出前几个）
  final List<String> fileNames;

  /// 队列里这部剧的任务数
  final int episodeCount;

  String get sizeText {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

/// ★★★ task-11 ④：整剧删除的**结果**（真删之后回报实际删了多少）
@immutable
class WorkRemovalResult {
  const WorkRemovalResult({
    required this.preview,
    required this.deleted,
    this.deletedFiles = 0,
    this.deletedBytes = 0,
  });

  final WorkRemovalPreview preview;

  /// false = 只是演练（force 没传 true）
  final bool deleted;
  final int deletedFiles;
  final int deletedBytes;
}

/// 整片下载队列（**进程级单例**）
class DownloadQueue {
  DownloadQueue._();

  static final DownloadQueue instance = DownloadQueue._();

  /// ★★★ 2026-10-09（Owner 第 20 条）：整片下载的**并发数**（同时跑几集）
  ///
  /// 键名沿用「下载」前缀（`dsh.download.*`），与
  /// `clip_download.dart:279`（片段并发）、`download_dir.dart`（目录）一组。
  static const String kConcurrencyKey = 'dsh.download.queue.concurrency';

  /// 缺省 1 = **串行**，即改动前的行为（见文件头/下面 _pump 的长注释）
  static const int defaultConcurrency = 1;

  /// 上界 3：再多就会把本地代理 256 条 FIFO 流表挤到影响**正在播的那条**
  /// （每集内部还要顺序拉几百个分片，见 `_run`），所以这里刻意收紧到 3。
  static const int maxConcurrency = 3;

  /// 滑杆档位
  static const List<int> concurrencyOptions = [1, 2, 3];

  /// 当前并发数（永远落在 1..maxConcurrency）
  ///
  /// ⚠️ 越界值**夹**而不是抛：pref 文件是用户可手改的（`ui-prefs.json`），
  ///   手滑写 99 不该让下载崩，夹到上界继续跑才是对的。
  static int get concurrency {
    final raw = UiPrefs.get(kConcurrencyKey);
    final v = raw == null ? defaultConcurrency : int.tryParse(raw);
    if (v == null) return defaultConcurrency;
    return v.clamp(1, maxConcurrency);
  }

  /// 文案：给 UI 用
  static String concurrencyLabel(int v) => v <= 1 ? '串行（1 集）' : '$v 集同时';

  static void setConcurrency(int value) {
    final v = value.clamp(1, maxConcurrency);
    UiPrefs.set(kConcurrencyKey, v.toString());
    AppLog.write('DL', '整片下载并发 -> $v');
    /*
     * ★ 改**大**要立刻放行排队者。
     *
     * 不然会这样：用户在「下载所有集」跑到第 2 集时把并发从 1 拉到 3，
     * 结果**没反应** —— 因为 _pump 的循环已经卡在 `await _run()` 里了。
     * 与 `clip_download.dart:298-305` 同一个理由（那里是 _wakeWaiters）。
     */
    unawaited(_pump());
  }

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

  /// 测试/探针用：清空
  static void debugReset() {
    _list.clear();
    tasks.value = const [];
    _maxObservedRunning = 0;
  }

  /*
   * ★★★ 并发实测的**唯一可信读数**（照抄 `clip_download.dart:343` 的
   * `_maxObservedActive` 范式）。
   *
   * 为什么必须有它：光看"我配了 3"证明不了什么 —— 要证明的是**真的有 3 个
   * 同时在跑**。这个计数在每次置 running 时取历史最大，测试读它就能判定
   * "并发上限是不是真的生效"（而不是只相信配置项被读到了）。
   */
  static int _maxObservedRunning = 0;

  /// 探针读数：本次运行中**同时处于 running 的最大个数**
  static int debugMaxObservedRunning() => _maxObservedRunning;

  /// 探针读数：当前 running 个数（瞬时）
  static int debugRunningCount() =>
      _list.where((t) => t.state == DownloadState.running).length;

  static void _publish() => tasks.value = List<DownloadTask>.unmodifiable(_list);

  /// ★★★ task-11 ③：正在**收尾**（已判定暂停、但下载器的文件句柄还没关完）的任务 id
  ///
  /// # 为什么需要它（探针实测踩到的坑，必须记住）
  /// ```text
  /// 报错：PathAccessException: Cannot rename file to '…第01集 探针.ts',
  ///       path = '…第01集 探针.ts.part'
  ///       (OS Error: 另一个程序正在使用此文件, errno = 32)
  ///
  /// 时序：
  ///   ① 用户点暂停 ⇒ pause() **同步**把状态置成 paused
  ///   ② 下载器要到**下一个分片边界**才看到 paused ⇒ 正常收尾（flush + close）后 return
  ///   ③ 但 _run 此时还没跑到它的 finally —— 在这段窗口里，
  ///      用户若立刻点「继续」，新的 _run 会对**同一个 .part** 再开一个
  ///      append 句柄 ⇒ 与正在关闭中的旧句柄冲突 ⇒ rename 报 errno 32。
  ///
  /// ⇒ 用这个集合把「已暂停但还没收尾完」的 id 圈起来：
  ///   resume() 遇到它就**只改状态、不立刻放开**（不叫 _pump），
  ///   等 _run 收尾时把它移出并叫 _pump —— 那时句柄一定已经关干净了。
  /// ```
  static final Set<String> _settling = <String>{};

  /// 探针读数：正在收尾的任务数
  static int debugSettlingCount() => _settling.length;

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

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-11 ③：暂停 / 继续 / 删除
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话（逐字）：
  // > 一集占一行,然后如果正在下载就可以暂停啊 删除啊,操作
  //
  // # ★ 暂停为什么「在分片边界停」就够（不需要真挂起 socket）
  // ```text
  // HLS 是**顺序**拉分片：_run → HlsDownloader.download 的 for 循环一次只处理一片。
  // 我们只要在第 i 片**开始之前**问一句「用户暂停了吗」。
  //
  // ★★ 关键：已经写进 .part 的分片**一个都不许丢**。
  //   而 HlsDownloader 的 catch 分支会把 .part **删掉**（失败绝不留半截）。
  //   ⇒ 所以「暂停」**不能**用异常表达，必须让下载器**正常返回**。
  //   ⇒ 这就是 hls_download.dart 要加 isPaused 回调、并在暂停时正常收尾的原因。
  // ```

  /// 暂停一个任务（queued/running → paused）
  ///
  /// 返回 true = 状态确实变了；false = 任务不存在或已结束（done/failed）。
  ///
  /// ★ 对 queued 也允许：用户点了「下载所有集」后想先放一放某一集，
  ///   那一集可能还没轮到跑 —— 只允许 running 的话，用户的操作会被静默吞掉。
  static bool pause(String id) {
    final i = _list.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final s = _list[i].state;
    if (s != DownloadState.running && s != DownloadState.queued) return false;
    _list[i] = _list[i].copyWith(state: DownloadState.paused);
    /*
     * ★ 若它正在跑（要等下载器走到分片边界才真的收尾）⇒ 先把 id 圈进 _settling。
     *   queued 的任务没有句柄要关，不用圈。
     */
    if (s == DownloadState.running) _settling.add(id);
    AppLog.write('DL', '暂停 ${_list[i].fileName}');
    _publish();
    /*
     * ★ 暂停 running 的那个：_run 会在分片边界发现并归还槽位（它自己叫 _pump）。
     *   这里不用手动叫 —— 叫了也只是多做一次空转。
     */
    return true;
  }

  /// 继续一个暂停的任务（paused → queued）
  ///
  /// ★ 为什么回 queued 而不是 running：槽位是 _pump 派的，直接置 running
  ///   会**绕过并发上限**（用户连点 5 次继续就跑 5 个）。
  static bool resume(String id) {
    final i = _list.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    if (_list[i].state != DownloadState.paused) return false;
    _list[i] = _list[i].copyWith(state: DownloadState.queued, clearError: true);
    AppLog.write('DL', '继续 ${_list[i].fileName}');
    _publish();
    /*
     * ★ 收尾还没结束（旧 .part 句柄没关）⇒ **现在不能放开**。
     *   否则新的 _run 会对同一个 .part 开 append 句柄 ⇒ rename 报 errno 32。
     *   等 _run 的 finally 把它移出 _settling 时会自己叫 _pump（见 _run 结尾）。
     */
    if (!_settling.contains(id)) unawaited(_pump());
    return true;
  }

  /// 重试一个**失败/取消**的任务（failed → queued）
  ///
  /// ★ 为什么不复用 resume：resume 只认 paused。失败的任务要重试，
  ///   语义是「忘掉上次的错，重新排队」——顺便清掉 error 文案。
  ///
  /// ⚠️ 不重置 `done`：若上次是**暂停后失败**，.part 还在盘上，
  ///   保留 done 让 HlsDownloader 从下一片接上（见 `initialDone`）。
  ///   真失败的场景 .part 已被删，HlsDownloader 会 `part.existsSync()` 为 false
  ///   ⇒ 走全新下载 ⇒ done 留着也无害（skip 会被 clamp 到 total 内）。
  static bool retry(String id) {
    final i = _list.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final s = _list[i].state;
    if (s == DownloadState.done || s == DownloadState.running) return false;
    _list[i] = _list[i].copyWith(
      state: DownloadState.queued,
      clearError: true,
    );
    AppLog.write('DL', '重试 ${_list[i].fileName}');
    _publish();
    unawaited(_pump());
    return true;
  }

  /// 删除**单个**任务：先停、再删盘上文件、最后从队列移除
  ///
  /// ⚠️ 真删文件、不可逆 ⇒ 调用方必须先二次确认（UI 层做）。
  ///
  /// ★ 顺序为什么是「先改状态 → 再等 → 再删文件 → 最后移除」：
  /// ```text
  /// ① 把状态改成 failed ⇒ 正在跑的那一轮会在**下一个分片边界**发现
  ///    「我该停了」（cancelled() 读的就是 failed，见 _run 里那行）
  /// ② 删盘上产物
  /// ③ 最后才从 _list 移除 —— 若先移除，_run 里的 _list[i] 会越界
  /// ```
  static Future<void> remove(String id) async {
    final i = _list.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final t = _list[i];
    if (t.state == DownloadState.running) {
      _list[i] = t.copyWith(state: DownloadState.failed, error: '已删除');
      _publish();
      // ★ 给在跑的那轮一点时间跑到分片边界并完成 .part 清理
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await deleteTaskFiles(t);
    final j = _list.indexWhere((x) => x.id == id);
    if (j >= 0) _list.removeAt(j);
    AppLog.write('DL', '删除任务 ${t.fileName}');
    _publish();
    unawaited(_pump());
  }

  /// 删掉一个任务对应的**盘上产物**（.part 与已落定文件）
  ///
  /// 抽成 public static 让「单集删除」与「整剧删除」共用同一套路径规则
  /// —— 两处各写一遍迟早不一致（一个删 .mp4、一个删 .ts）。
  static Future<void> deleteTaskFiles(DownloadTask t) async {
    try {
      final dir = await DownloadDir.forWork(t.title);
      final sep = Platform.pathSeparator;
      final candidates = <String>[
        '$dir$sep${t.fileName}',
        '$dir$sep${t.fileName}.ts',
        '$dir$sep${t.fileName}.mp4',
        '$dir$sep${t.fileName}.part',
        '$dir$sep${t.fileName}.ts.part',
        '$dir$sep${t.fileName}.mp4.part',
      ];
      for (final p in candidates) {
        final f = File(p);
        if (await f.exists()) {
          await f.delete();
          AppLog.write('DL', '已删文件 $p');
        }
      }
    } catch (e) {
      AppLog.write('DL', '删任务文件失败：$e');
    }
  }

  /// ★★★ task-11 ④：**整剧删除**（Owner 追加要求）
  ///
  /// 用户原话（逐字）：
  /// > 而且就算在外面也应该可以进行整部剧的删除操作
  ///
  /// # 两类东西都要删
  /// ```text
  /// ① 队列里这部剧的**全部任务**（含正在跑的 —— 先停）
  /// ② DownloadDir.forWork(title) 这个**目录整个删掉**
  ///    （目录里可能有队列不知道的残留：半截 .part、旁文件等）
  /// ```
  ///
  /// ⚠️ 真删、不可逆 ⇒ 调用方必须先 `List<...> previewRemoveWork` 拿到清单再确认。
  ///
  /// [force] 传 true 才真删（默认 false = 只演练，防误调用）。
  static Future<WorkRemovalResult> removeWork(
    String title, {
    bool force = false,
  }) async {
    final preview = await previewRemoveWork(title);
    if (!force) {
      AppLog.write(
        'DL',
        '[演练] 整剧删除 "$title"：${preview.episodeCount} 集 / '
            '${(preview.bytes / 1048576).toStringAsFixed(1)} MB（未真删）',
      );
      return WorkRemovalResult(preview: preview, deleted: false);
    }

    // ① 先让这部剧的所有在跑任务停下
    for (var i = 0; i < _list.length; i++) {
      final t = _list[i];
      if (t.title != title) continue;
      if (t.state != DownloadState.done && t.state != DownloadState.failed) {
        _list[i] = t.copyWith(state: DownloadState.failed, error: '整剧删除');
      }
    }
    _publish();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // ② 删整个目录
    var deletedFiles = 0;
    var deletedBytes = 0;
    try {
      final dir = Directory(await DownloadDir.forWork(title));
      if (await dir.exists()) {
        await for (final ent in dir.list(followLinks: false)) {
          if (ent is File) {
            try {
              deletedBytes += (await ent.length()).toInt();
            } catch (_) {}
            deletedFiles++;
          }
        }
        await dir.delete(recursive: true);
        AppLog.write(
          'DL',
          '整剧删除 "$title"：删 $deletedFiles 个文件 / '
              '${(deletedBytes / 1048576).toStringAsFixed(1)} MB',
        );
      }
    } catch (e) {
      AppLog.write('DL', '整剧删除目录失败：$e');
    }

    // ③ 从队列移除这部剧的**全部**任务
    _list.removeWhere((t) => t.title == title);
    _publish();
    unawaited(_pump());

    return WorkRemovalResult(
      preview: preview,
      deleted: true,
      deletedFiles: deletedFiles,
      deletedBytes: deletedBytes,
    );
  }

  /// 整剧删除的**预览**（真删前必须给用户看这个）
  static Future<WorkRemovalPreview> previewRemoveWork(String title) async {
    var files = 0;
    var bytes = 0;
    final names = <String>[];
    try {
      final dir = Directory(await DownloadDir.forWork(title));
      if (await dir.exists()) {
        await for (final ent in dir.list(followLinks: false)) {
          if (ent is File) {
            files++;
            names.add(ent.uri.pathSegments.last);
            try {
              bytes += (await ent.length()).toInt();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    final queued = _list.where((t) => t.title == title).length;
    return WorkRemovalPreview(
      title: title,
      fileCount: files,
      bytes: bytes,
      fileNames: names,
      episodeCount: queued,
    );
  }

  /// 某部剧在队列里的任务数（UI 用来决定「整剧删除」按钮显不显示）
  static int taskCountOf(String title) =>
      _list.where((t) => t.title == title).length;

  /// ★★★ task-11 ④：下载成功后把**旁文件**写进剧集目录
  ///
  /// # 为什么是「写进剧集目录」而不是「另存一份元数据」
  /// ```text
  /// 「已缓存」页（cache_page.dart）扫盘时读的就是**剧集目录里的**
  /// _sourin-cache.json（kCacheSidecarName），拿 provider/id/title/cover。
  /// 下载目录与缓存目录**各有一个按剧名命名的文件夹** —— 只要两边都写
  /// 同一个旁文件，「已缓存」页对下载来的剧也能显示封面。
  ///
  /// ⚠️ 目录层级必须与 cache_page._scanWork 的规则一致：
  ///   扫描的是 <root>/<剧名>/ 一层，文件直接放在里面（不嵌套）。
  /// ```
  /// ★★ 注意：这里是 **core 层**，不许 import `ui/cache_page.dart`。
  ///
  /// # 为什么自己写这 15 行，而不是复用 cache_page 的 writeCacheSidecar
  /// ```text
  /// ① 分层：lib/core/** 依赖 lib/ui/** 是反向依赖（core 不该认识页面）。
  ///    仓内本来只有 app_tray.dart 一处越界（它确实要读主题 token），不该再加一处。
  /// ② 构建耦合：cache_page.dart 归 release-dev（task-12）在做，
  ///    我的 core 文件 import 它 ⇒ 他写坏一半时**我的测试也编不过**。
  /// ③ 契约仍是**同一个**：文件名 `_sourin-cache.json`（kCacheSidecarName）、
  ///    字段 provider/id/title/cover —— 与 cache_page._scanWork 的读法逐字对齐。
  ///    ★ 两边是"同一个契约的两份实现"，不是两份不同格式；
  ///      改契约时**两处必须一起改**（在 cache_page 顶部与这里各留一句提醒）。
  /// ```
  static const String kSidecarName = '_sourin-cache.json';

  /// 旁文件里「本地封面文件名」那个键（读侧 cache_page 必须引用同一个常量）
  static const String kSidecarCoverFileKey = 'coverFile';

  /// ★★★ 旁文件**原子写**（先写 .tmp 再 rename）
  ///
  /// 改前是直接 `writeAsString`：写到一半崩了/断电 ⇒ 盘上留下**半个 JSON**。
  /// 而读侧（`cache_page._readSidecar`）解析失败会静默降级成"没封面"
  /// ⇒ 用户看到的是"我明明下过，怎么封面没了"，而文件明明就在那儿。
  /// rename 在同一卷上是原子的 ⇒ 要么完整的新文件，要么完整的老文件。
  ///
  /// ★★★ OPS-16 ①：rename **会撞锁**（目标已存在且被别的句柄开着）⇒
  ///   改前那一行 `await tmp.rename(f.path)` + 一个只记日志的 catch，
  ///   在 Windows 上会把**整份新旁文件**静默丢掉。现在统一走
  ///   [_atomicReplaceWith]（重试 + 兜底 + 失败如实记），见那里的长注释。
  ///
  /// ★★★ OPS-16 ②：本函数必须在**发布 done 之前** await 完 ——
  ///   理由见 `_run` 里调用点上方那段（cache_page 的 _onQueueChanged
  ///   按 id 集合去重，第二次 publish **不会**再触发重扫 ⇒ 只能靠顺序保证）。
  static Future<void> _writeSidecarFor(DownloadTask t, String dir) async {
    try {
      /*
       * ★ 封面图先抓：抓成功了才知道本地文件名，好一起写进旁文件。
       * ⚠️ 抓图是网络 IO ⇒ 绝不能让它挡住后面的字段写入（顺序即此）。
       */
      final coverFile = await cacheCoverImage(t.cover, dir);
      final f = File('$dir${Platform.pathSeparator}$kSidecarName');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(<String, Object?>{
        'provider': t.provider,
        'id': t.mediaId,
        'title': t.title,
        'cover': t.cover,
        kSidecarCoverFileKey: coverFile,
        // ★ 以下给「本地播放页」补（Owner：封面介绍啥的在线播放器有的，
        //   本地播放器也要有）。全部可空 —— 缺就缺，读侧降级，绝不编造。
        'description': t.description,
        'year': t.year,
        'area': t.area,
        'kind': t.kind,
        'badges': t.badges,
      }), flush: true);
      await _atomicReplaceWith(tmp, f, what: '旁文件');
    } catch (e) {
      /*
       * 旁文件丢了是小事，把下载本身搞失败是大事 —— 但**不许再静默**
       * （改前这里写的是「旁文件写入被忽略」，连目标路径都没有）。
       */
      AppLog.write(
        'DL',
        '旁文件写入失败（不阻断下载）：'
        '目标=$dir${Platform.pathSeparator}$kSidecarName  $e',
      );
    }
  }

  /// 原子替换的退避序列（毫秒）：立即试一次 + 退避 4 次，合计 ≈ 440 ms
  ///
  /// 依据：真实占用者都是**短命**的 —— 读一个小 JSON 是微秒级、杀软扫几 KB
  /// 是几十毫秒级、并发收尾的另一集只是一次 rename 的瞬间。
  /// 440 ms 足够覆盖这些，又不会让收尾肉眼可感地卡顿。
  static const List<int> _replaceBackoffMs = <int>[20, 50, 120, 250];

  /// ★★★ OPS-16 ①：把 [tmp] 换成 [target] —— 撞锁时**重试 + 兜底 + 如实记**
  ///
  /// # 缺陷（改前）
  /// ```text
  /// await tmp.rename(f.path);          // 一行：没有重试、没有兜底
  /// catch (e) { AppLog.write('DL', '旁文件写入被忽略：$e'); }   // 静默吞掉
  /// ```
  /// Windows 上 rename 到**已存在且被别的句柄打开**的目标会抛（实测）：
  /// ```text
  /// PathAccessException: Cannot rename file to '…\_sourin-cache.json',
  ///   path = '…\_sourin-cache.json.tmp' (OS Error: 拒绝访问。, errno = 5)
  /// ```
  /// 占用者全是**我们自己的代码或系统**，而且都是常态：
  /// · `cache_page._readSidecar` 正在读同一个文件（扫盘 / 详情页）；
  /// · 杀软实时扫描刚写出的文件；
  /// · **同一部剧并发下载多集**（并发 2/3 是正式功能）⇒ 两集同时收尾。
  /// ⇒ 概率性丢封面/来源，且被 catch 吞成一行日志 ⇒ 用户永远不知道。
  ///
  /// # 三级处理
  /// ```text
  /// ① rename（同卷原子 ⇒ 读侧要么完整旧文件、要么完整新文件）：
  ///    立即试一次，失败后退避重试（见 _replaceBackoffMs）。
  /// ② 兜底「原地覆盖写」：把 tmp 的字节写进目标、截断、flush、删 tmp。
  ///    ⚠️ 为什么不是 copy：实测 File.copy 到**已存在**的目标会抛
  ///       PathExistsException (OS Error: 当文件已存在时…, errno = 183)；
  ///       「先 delete 再 rename」也不行 —— 删被占文件抛 errno = 32。
  ///       只有"打开目标自己写"能成功（探针实测：目标被 FileMode.append
  ///       句柄持住时 open(FileMode.write) + write + flush 成功，
  ///       且**长度被正确截断**，不留旧尾巴）。
  ///    ⚠️ 代价：这一步放弃了 ① 的原子性（读侧可能撞见半截 JSON）——
  ///       但读侧解析失败本来就降级成"没封面"，而**丢掉整份新旁文件**
  ///       （改前的行为）是永久且不可自愈的。两害相权取轻。
  /// ③ 两级都失败 ⇒ 如实记日志（目标路径 + 两次异常原文），绝不再静默；
  ///    并尽力清掉 tmp，不在用户目录里留垃圾。
  /// ```
  static Future<bool> _atomicReplaceWith(
    File tmp,
    File target, {
    required String what,
  }) async {
    Object? renameErr;
    for (var attempt = 0; attempt <= _replaceBackoffMs.length; attempt++) {
      try {
        await tmp.rename(target.path);
        if (attempt > 0) {
          AppLog.write('DL',
              '$what原子替换成功（rename 第 ${attempt + 1} 次）：${target.path}');
        }
        return true;
      } catch (e) {
        renameErr = e;
        if (attempt < _replaceBackoffMs.length) {
          await Future<void>.delayed(
              Duration(milliseconds: _replaceBackoffMs[attempt]));
        }
      }
    }

    Object? fallbackErr;
    try {
      final bytes = await tmp.readAsBytes();
      final raf = await target.open(mode: FileMode.write);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await _tryDelete(tmp);
      AppLog.write(
        'DL',
        '$what原子替换退化为原地写（rename 重试 '
        '${_replaceBackoffMs.length + 1} 次仍被占用）：${target.path}'
        '  原因：$renameErr',
      );
      return true;
    } catch (e) {
      fallbackErr = e;
    }

    await _tryDelete(tmp);
    AppLog.write(
      'DL',
      '★ $what原子替换彻底失败（重试 + 兜底都没成）：目标=${target.path}'
      '  rename=$renameErr  兜底=$fallbackErr',
    );
    return false;
  }

  /// 尽力删掉一个临时文件：失败只记日志，绝不抛（收尾路径上不许有异常）
  static Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.write('DL', '清理临时文件失败：${f.path}  $e');
    }
  }

  /// 把封面图抓到剧集目录里（返回落地的文件名；没封面 / 失败 ⇒ null）
  ///
  /// ★ 为什么**必须**缓存图片本体而不只是记 URL：离线时那张图照样拉不下来
  ///   ⇒ 本地页仍是灰底占位 —— 而"离线也能看到封面"正是这一轮的要求。
  ///
  /// ⚠️ 失败绝不阻断下载（有些源防盗链、或根本没有封面），只记日志。
  @visibleForTesting
  static Future<String?> cacheCoverImage(String? url, String dir) async {
    final raw = url?.trim() ?? '';
    if (raw.isEmpty) return null;
    // 只认 http(s)：data: 与本地路径没有"抓取"的必要，也免得拼出怪文件名
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) return null;

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(raw));
      // ★ 不带 Referer 是**对的**（见 poster_card 顶部的说明：CDN 拒绝陌生来源）
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final bytes = await consolidateHttpClientResponseBytes(res);
      // 0 字节 / 超过 8 MiB 都不写：前者是没抓到，后者多半不是封面而是整集视频
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;

      /*
       * ★ 扩展名只从 **URL 的 path** 上取，且要白名单 ——
       *   query 里常带一串伪扩展名（`?format=webp&x=jpg`），
       *   直接截整个 URL 会写出怪文件名，还会漏掉没有扩展名的 CDN 地址。
       */
      var ext = '.jpg';
      final m =
          RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false)
              .firstMatch(Uri.parse(raw).path);
      if (m != null) {
        final g = m.group(1)!.toLowerCase();
        // jpeg/jpg 都写成 .jpg，免得同一张图有两个文件名
        ext = g == 'jpeg' ? '.jpg' : '.$g';
      }

      final name = '_sourin-cover$ext';
      final f = File('$dir${Platform.pathSeparator}$name');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      /*
       * ★★★ OPS-16 ①：封面与旁文件是**同一个撞锁窗口**（同一部剧并发收尾、
       *   cache_page 扫盘、杀软），改前同样是「一行 rename + 静默 catch」
       *   ⇒ 概率性丢原封面（Owner：「已缓存的也要显示原封面」）。
       *   ⇒ 走与旁文件同一套重试 + 兜底（见 _atomicReplaceWith）。
       */
      final ok = await _atomicReplaceWith(tmp, f, what: '封面');
      if (!ok) return null;
      return name;
    } catch (e) {
      AppLog.write('DL', '封面缓存失败（不阻断下载）：$e');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 有界并发泵：同时最多 [concurrency] 个任务在跑（默认 1 = 串行）
  ///
  /// # 为什么默认是 1（不是复用 ClipDownloader 的 4 并发池）
  /// ```text
  /// 那 4 个槽位是给**片段**下载用的（几 MB）。整片下载一集几百 MB、
  /// 内部还要顺序拉几百个分片 —— 四条这样的流并行，本地代理的
  /// 256 条 FIFO 流表会被瞬间打满，结果是**所有**流（含正在播的那条）
  /// 一起卡。⇒ 整片下载**默认串行**，把带宽让给播放。
  /// ```
  ///
  /// # ★★★ 2026-10-09（Owner 第 20 条）：这个「1」现在是**缺省值，不是天花板**
  /// ```text
  /// 改前：while(true){ await _run(i); } —— 「一次只跑一个」刻在循环里，
  ///       上限写死，用户没有任何出口。
  /// 改后：同一个 while，但每次迭代**现算**还有没有空槽：
  ///       空槽够 ⇒ 不 await，直接开下一个（_run 内部自己 await）。
  ///       N = concurrency（pref，1..3，缺省 1）。
  /// ```
  ///
  /// ★ 不变量：`_pumping` 保证**同一时刻只有一个 while 在跑**；
  ///   槽位数 = `running` 计数，而 running 由 `_run` 开头置位、
  ///   `_run` 结尾（成功/失败都）归还 ⇒ 与 ui-prefs 的内容无关，
  ///   不会因为用户手改文件而泄漏槽位。
  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        /*
         * ★ 每次迭代都**重读** concurrency：用户在下载途中把 1 拉到 3，
         *   下一个槽位一空出来就按新值放行（与 clip_download.dart:340
         *   的 _withSlot 同一个理由 —— 上限不能只在启动时算一次）。
         */
        final limit = concurrency;
        final running = _list
            .where((t) => t.state == DownloadState.running)
            .length;
        if (running >= limit) {
          /*
           * 没空槽：等**任意一个**在跑的任务结束（_pump 会被 _run 的
           * finally 回调唤醒 —— 见 _run 结尾的 unawaited(_pump())）。
           * 这里 break 出 while，由那次回调重新进 _pump，避免忙等。
           */
          break;
        }
        final i = _list.indexWhere((t) => t.state == DownloadState.queued);
        if (i < 0) break;
        /*
         * ★ 这里**故意不 await 整个 _run**：await 会让 while 停在这一行，
         *   并发度永远是 1（那正是改动前的行为）。改成先把它标成 running
         *   占住槽位、再 unawaited 放它跑，然后继续循环找下一个空槽。
         *   ⚠️ 标记动作必须在**同一个** _pump 迭代里**同步**完成，
         *      否则两次迭代会挑到同一个 queued（并发重复下载同一集）。
         */
        _markRunning(i);
        unawaited(_run(i));
      }
    } finally {
      _pumping = false;
    }
  }

  /// 占槽位：把第 i 个任务标成 running 并广播（同步，不可 await）
  static void _markRunning(int i) {
    _list[i] = _list[i].copyWith(state: DownloadState.running, clearError: true);
    // ★ 实测读数：占槽的同时记历史最大同时在跑数
    final n = debugRunningCount();
    if (n > _maxObservedRunning) _maxObservedRunning = n;
    _publish();
  }

  /// ★ 解析「这一集该从哪条流下」——默认走核心层，探针可临时替换
  ///
  /// # 为什么单独抽一层（而不是直接调 SourinApi.firstPlayable）
  /// ```text
  /// 并发**上限**这件事只能靠"真的让 N 个 _run 同时在飞"来证明；
  /// 而 _run 的第一步就是向 Rust 核心要流。flutter_tester 里没有核心，
  /// 于是整条 _run 会在第一步就抛异常 ⇒ 探针测到的永远是"失败得很快"，
  /// 根本走不到并发那一段（那是**空转**，不是实测）。
  ///
  /// 抽出这一层后，探针把它指向一个**真的本地 HTTP 服务器**：
  /// HlsDownloader / ClipDownloader 照常发真实请求、照常写真实文件，
  /// 服务器侧能数出"同时活跃请求数的峰值" —— 那才是并发的硬读数。
  /// ```
  static Future<StreamCandidate?> Function(DownloadTask t) _resolveStreamFor =
      (t) => SourinApi.firstPlayable(
            t.provider,
            t.mediaId,
            req: PlayRequest(
              episodeId: t.episodeId,
              sourceCode: t.sourceCode,
            ),
          );

  /// 探针用：替换 / 还原上面的解析器（只在测试里调）
  @visibleForTesting
  static void debugSetResolver(
    Future<StreamCandidate?> Function(DownloadTask t)? r,
  ) {
    _resolveStreamFor = r ??
        (t) => SourinApi.firstPlayable(
              t.provider,
              t.mediaId,
              req: PlayRequest(
                episodeId: t.episodeId,
                sourceCode: t.sourceCode,
              ),
            );
  }

  /// ★★★ CR-14：跑**第 i 个任务**（**调用方必须已经把它标成 running**，见 _markRunning）
  ///
  /// ⚠️ 这里**不再**自己置 running：置位是并发槽位的**占用动作**，
  ///   必须与 _pump 里选任务**同步**发生，否则两次 _pump 迭代会挑到同一个
  ///   queued 任务（并发重复下载同一集）。所以置位统一收在 _markRunning。
  ///
  /// ★★★ CR-14：i 只是**入口**下标，函数内**全程按任务 id 定位**。
  ///
  /// # 为什么不能用 i 定位（缺陷链，探针实测见 test/zz_cr_dl_c14_index_identity_test.dart）
  /// ```text
  /// 并发 >= 2 时，只要 _list 在本轮 await 期间被摘掉**前面**任何一个任务，
  /// 后面所有任务的下标就左移 —— 而 _run 还拿着旧 i：
  ///   · 自己的收尾（state=done / path / 失败原因）写到**邻居**身上 ⇒
  ///     自己永远停在 running，邻居被冒名顶替（实测 ep1 卡 running、ep2 被写成 done）；
  ///   · 任务被 remove() 摘掉之后，catch 里 _list[i] 直接 RangeError。
  /// ⇒ 下面所有读写都现查 indexOfId()：找不到 = 这条任务已经没了，
  ///   它的收尾结论没有落点，直接跳过，绝不能写邻居。
  /// ```
  static Future<void> _run(int i) async {
    // ★★★ CR-14：i 只在**入口**用一次（_pump 刚把它标成 running，这一刻它是对的）。
    final t = _list[i];
    /// ★★★ CR-14：这条任务**当下**所在的下标（-1 = 已被移除）。
    ///   _list 是可变的静态列表，下标随时会因 remove/clearFinished 左移，
    ///   所以每次读写都必须现查，绝不能缓存。
    int indexOfId() => _list.indexWhere((x) => x.id == t.id);
    /// ★★★ CR-15：本轮是不是**因为暂停**而收尾的。
    var pausedOut = false;
    /// ★★★ CR-15：暂停时**下载器回报的真实分片数**（= .part 里落盘的片数）。
    ///
    /// ★ 为什么必须单独存：onProg 有两道门 ——
    ///   ① 节流（每 8 片才写一次 done）；
    ///   ② `if (cur.state != DownloadState.running) return;`（暂停后状态已是 paused）。
    /// ⇒ 暂停那一刻，任务上的 done 停在**最后一个节流点**（实测 16），
    ///   而 .part 里其实已经写进了更多片（实测 20/21）。
    /// ⇒ 继续时 `initialDone: t.done` 偏小 ⇒ 下载器把已落盘的片**又拉一遍并追加**
    ///   ⇒ 成品重复拼接（实测 184320 字节 vs 应有 163840，服务器被拉 45 次 vs 40）。
    ///
    /// ⇒ 暂停收尾时必须用**下载器的回报值**覆盖 done（见下面的 pausedOut 分支）。
    var pausedSegments = 0;
    try {
      /*
       * ① 轮到它了才解析流（见文件头的说明）——
       *    一次只占核心层流表里的一条。
       */
      final st = await _resolveStreamFor(t);
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
        // ★★★ CR-14：按 id 现查，而不是拿入口下标 i（它会因并发下标左移而指错人）。
        final at = indexOfId();
        if (at < 0) return;
        final cur = _list[at];
        if (cur.state != DownloadState.running) return;
        _list[at] = cur.copyWith(done: done, total: total);
        _publish();
      }

      // ★★★ CR-14：按 id 现查；任务已被 remove() 摘掉时 indexOfId() == -1
      //   ⇒ 它的下载已经没有落点了，当成「已取消」处理（下载器会清掉 .part）。
      bool cancelled() {
        final at = indexOfId();
        return at < 0 || _list[at].state == DownloadState.failed;
      }

      /*
       * ★★★ task-11 ③：暂停判据 —— 由 HlsDownloader 在每个**分片边界**问。
       *
       * ⚠️ 与 cancelled 的区别（本任务最关键的一处设计）：
       * ```text
       * cancelled=failed ⇒ 抛异常 ⇒ HlsDownloader 的 catch **删掉 .part**
       * paused           ⇒ **正常收尾** ⇒ .part 原样留着 ⇒ 继续时从下一片接上
       * ```
       * ⇒ 两个回调必须分开传，**不能**用一个「该不该停」的 bool 混过去。
       */
      // ★★★ CR-14：同上，按 id 现查（任务没了就没有暂停可言）。
      bool paused() {
        final at = indexOfId();
        return at >= 0 && _list[at].state == DownloadState.paused;
      }

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
          isPaused: paused,
          /*
           * ★ task-11 ③ 续传：上次暂停时已写进 .part 的分片数。
           *   `t.done` 里存的正是它（暂停时下载器回报的 r.segments）。
           *   ⚠️ 只有状态是 paused 的任务才可能有非零 done ——
           *     首次运行时 done==0，与传 null 等价。
           */
          initialDone: t.done,
        );
        /*
         * ★★★ task-11 ③：暂停 ⇒ 下载器**正常返回**且 r.paused == true。
         *   此刻：.part 留在盘上（已下好的分片一片不丢）；本任务**不标 done**、
         *   也不抛；槽位由下面的 finally 归还。
         */
        if (r.paused) {
          AppLog.write(
            'DL',
            '暂停收尾 ${t.fileName}  已下 ${r.segments} 片 / '
                '${(r.bytes / 1048576).toStringAsFixed(1)} MB（.part 保留）',
          );
          pausedOut = true;
          // ★★★ CR-15：把下载器回报的真实分片数留下来（见 pausedSegments 的注释）
          pausedSegments = r.segments;
          path = r.path;
          bytes = r.bytes;
        } else {
          path = r.path;
          bytes = r.bytes;
        }
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

      /*
       * ★★★ task-11 ③ + CR-14 + CR-15：收尾**必须按 id 写回自己**，
       *   绝不能再用入口下标 i —— 并发时它会指向邻居（实测：ep1 卡 running、
       *   ep2 被冒名顶替成 done）；任务被 remove() 摘掉时 write() 返回 false，
       *   此时它的结论没有落点，直接放弃，绝不写邻居（catch 同理，见下）。
       *
       * 暂停分支另外还带着 CR-15 的修复：done 要用**下载器回报的分片数**，
       * 因为 onProg 有两道门（每 8 片节流 + 暂停后不再写），
       * 任务上的 done 会停在最后一个节流点（实测 16）而 .part 里已有 20/21 片。
       */
      if (pausedOut) {
        final at = indexOfId();
        if (at >= 0) {
          _list[at] = _list[at].copyWith(path: path, done: pausedSegments);
          _publish();
        }
      } else {
        /*
         * ★★★ OPS-16 ②：**这里的顺序是有意义的** —— 旁文件落地之后才发布 done。
         *
         * # 缺陷（改前）
         * ```text
         * _publish();                       // ① 先宣布「完成」
         * AppLog.write('DL', '队列完成 …');
         * …
         * await _writeSidecarFor(t, dir);   // ② 之后才写旁文件
         * ```
         * 「已缓存」页 _onQueueChanged（cache_page.dart:1143）收到 ① 就立刻
         * load() 扫盘；而 ② 里还夹着一次**网络 IO**（抓封面，几百毫秒到数秒）
         * ⇒ 扫到的是「有视频、没旁文件」⇒ 封面/来源缺失，用户看到的是
         * 「我明明下过，怎么封面没了」。
         *
         * # 为什么不是「写完再 publish 一次」（方案 b）
         * ```text
         * cache_page.dart:1145-1151
         *   final doneIds = {… state == done …};
         *   final fresh = doneIds.difference(_seenDoneIds);
         *   _seenDoneIds = doneIds;
         *   if (fresh.isEmpty) return;      // ★ 同一条任务第二次 done 被吃掉
         * ```
         * 它按 **id 集合**去重 ⇒ 第二次 publish **不会**再触发 load() ⇒ 不自愈。
         * （已读代码确认，不是假设。）
         *
         * # 代价（评估过）
         * 发布推迟到封面抓取完成之后：下载面板会多停在「下载中 6/6」几百毫秒。
         * 但 ① 那条 publish 从来就不是「文件已落盘」的信号（成品早在
         * HlsDownloader 里就 rename 好了），而 ② 的收益是**消灭不可自愈的
         * 缺封面状态** —— 业主反馈的「概率性丢封面」正是它。
         */
        /*
         * ★ CR-14 的同一条纪律：任务已被 remove() 摘掉（indexOfId() < 0）时
         *   它的成品已经被 deleteTaskFiles 删了 ⇒ 不要再给它写旁文件，
         *   免得在盘上留一个指向不存在的视频的孤儿 JSON。
         */
        if (indexOfId() >= 0) {
          /*
           * ★★★ task-11 ④：下载成功后写缓存旁文件（封面/标题/来源）。
           *   它的写出目录规则与「已缓存」页的扫盘规则 (`_scanWork`) 完全对齐
           *   ⇒ 写完这里，「已缓存」页立刻能显示封面。
           *   ⚠️ 只在**成功**时写（暂停/失败留下的是半截文件，不该进已缓存列表）。
           */
          await _writeSidecarFor(t, dir);
        }
        final at = indexOfId();
        if (at >= 0) {
          _list[at] = _list[at].copyWith(
            state: DownloadState.done,
            done: _list[at].total,
            path: path,
          );
          _publish();
        }
        AppLog.write(
          'DL',
          '队列完成 ${t.fileName}  ${(bytes / 1048576).toStringAsFixed(1)} MB',
        );
      }
    } catch (e) {
      // ★★★ CR-14：失败也只写回**自己**；任务已被 remove() 摘掉时 at<0，
      //   旧代码这里会 _list[i] 直接 RangeError（实测栈迹：download_queue.dart:1025）。
      final at = indexOfId();
      if (at >= 0) {
        _list[at] = _list[at].copyWith(state: DownloadState.failed, error: '$e');
      }
      AppLog.write('DL', '队列失败 ${t.fileName}  $e');
    }
    _publish();
    /*
     * ★ 归还槽位后**必须再叫一次 _pump**：
     *   并发的 while 在「没有空槽」时是 break 出去的（见 _pump 里那段），
     *   不会自己回来轮询 —— 靠的就是这一行把它重新拉起来。
     *   没有它，第 2 个任务会一直 queued 到天荒地老。
     *   ⚠️ unawaited：本函数自己可能就是 _pump 起的，await 会自等。
     */
    /*
     * ★★★ task-11 ③：收尾完成后才把 id 从 _settling 摘掉 —— 到这一刻
     *   HlsDownloader 的 sink 已经 close（它的 finally 早于本行），
     *   .part 的句柄一定干净了。此时才允许「继续」那一轮真正开跑。
     */
    final wasSettling = _settling.remove(t.id);
    unawaited(_pump());
    if (wasSettling) {
      AppLog.write('DL', '暂停收尾完成（句柄已释放）${t.fileName}');
    }
  }
}
