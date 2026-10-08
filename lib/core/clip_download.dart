// ======================================================================
//  片段下载（真实并发池 + 缓存目录上限淘汰）
// ======================================================================
//
// 用户 2026-10-04 要求（逐字，m13330 截图第 ③④ 项）：
// > 这些功能也可以抄一下
//
// 本文件对应两项：
//   ③ 片段下载并发：滑杆 0-8，缺省 4
//   ④ 缓存上限：64 / 128 / 256 / 512 MB
//
// # 键名（task-18 新增；落地前已 grep 全仓，dsh.download / dsh.cache 零命中）
// ----------------------------------------------------------------------
// dsh.download.concurrency   "0".."8"，缺省 "4"；"0" = 不限制并发
// dsh.cache.limitMb          "64" / "128" / "256" / "512"，缺省 "256"
// ----------------------------------------------------------------------
//
// # ★ 滑杆上的 0 是什么意思（这是一个**语义选择**，不是随手定的）
//
// 两种解释都成立，且实现成本相同：
//   (A) 0 = 不限制并发（把滑杆读成「上限」）
//   (B) 0 = 禁止下载（把滑杆读成「开关 + 数量」）
// 这里选 (A)，理由：
//   1. 滑杆的语义就是「并发上限」；上限为 0 在工程上就是「不设上限」，
//      与 aria2 的 --max-concurrent-downloads 一类参数同构。
//   2. 选 (B) 的话，用户把滑杆拉到最左边会得到一个**整体不可用**的
//      下载器，而界面上没有任何「已禁用」的视觉反馈，看起来像是坏了。
//   3. 真要清空磁盘，④ 旁边已经有「清空缓存」，语义比「并发 0」清楚。
// ⇒ 为避免歧义，UI 副标题**逐字写着**「0 = 不限制」，
//   见 lib/ui/settings/playback_page.dart。
//
// # ★ 为什么这个文件是新建的（产品里原本**没有任何下载层**）
//
// 落地前 grep 过：
//   rust/sourin_core/src/ 里 download 只命中 backup.rs:396 dirs_download()
//     （那是系统「下载」目录，不是下载器）；cache 只命中 proxy.rs:522/532
//     的测试函数名与 cctv.rs:987 的注释。
//   lib/ 里「片段」2 处、「下载」5 处，全是注释与文案。
//   lib/core/sourin_api.dart:1853 的 ProxyCache 是**进程内配置缓存**，
//     与媒体磁盘缓存无关。
// ⇒ ③「并发要真的限制同时在跑的下载任务数」、④「缓存上限要真的传给
//   下载器」这两条要求在既有代码里**没有落点**，只能新增。
//
// # 数据目录为什么自己解析（不复用 lib/shell.dart:792 的 _resolveDataDir）
//
// 那个函数是**私有**的，而且 lib/shell.dart 是 app 入口 —— 设置页 import
// 它会把整个 app 拖进依赖图。这里镜像它的三步次序（见 dataDir）：
//   DATA_DIR_OVERRIDE -> 桌面 %APPDATA%\app.sourin.player -> path_provider
// ★ 次序**必须与 shell.dart 一致**，否则设置页看到的缓存目录和 app 真正
//   用的那个不是同一个，④ 的「上限」就会作用在一个没人看的目录上。
//
// # 并发池为什么手写（不用 Future.wait / 不引依赖）
//
// Future.wait 会把**所有**任务一次性打出去，没有上限；要限制在跑数就必须
// 自己排队。既有先例：lib/ui/live_availability.dart:175 手写并发池
// （注释原话：「不引依赖；Future.wait 会一次性打完」）。
// 本文件同套路，但**多一层可观测性**：maxObservedActive 记录峰值，
// 供真进程探针断言「上限真的生效」。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'ui_prefs.dart';

/// ★ 本文件自己判桌面端，**不 import lib/shell.dart:135 的 kIsDesktop**
/// —— 那是 app 入口文件里的顶层变量，设置页 import 它会把整个 app
/// 拖进依赖图（见文件头「数据目录为什么自己解析」）。
/// 判据与 shell.dart:135 逐字一致：
///   final bool kIsDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
final bool _kIsDesktop =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 一次下载的结果。
class ClipDownloadResult {
  const ClipDownloadResult({
    required this.path,
    required this.bytes,
    required this.elapsed,
  });

  /// 落盘后的绝对路径
  final String path;

  /// 实际写入字节数
  final int bytes;

  final Duration elapsed;

  double get mb => bytes / (1024 * 1024);

  @override
  String toString() =>
      'ClipDownloadResult(path=$path, bytes=$bytes, '
      'mb=${mb.toStringAsFixed(2)}, ms=${elapsed.inMilliseconds})';
}

/// 缓存目录里的一个文件。
class ClipCacheEntry {
  const ClipCacheEntry({
    required this.path,
    required this.bytes,
    required this.modified,
    this.busy = false,
  });

  final String path;
  final int bytes;
  final DateTime modified;

  /// ★ 这个文件**此刻正在被下载**（`download()` 还没走完）。
  ///
  /// 为什么必须有这个标记：下载是"先写 `<name>.part`、完成后 rename 成
  /// `<name>`"两步。rename 一旦发生，这个文件就已经是**成品**了，但
  /// 发起它的那次 `download()` 还没返回、它的 `finally` 还没执行 ——
  /// 这个窗口里如果另一个并发任务跑 `enforceCacheLimit()`，它会把这个
  /// **刚下完的**文件当普通旧文件删掉。用户看到的是"下载成功"闪一下、
  /// 文件却不见了（探针 P10 复现：4 个并发下载全部下完，终态目录里 0 个文件）。
  ///
  /// 处理方式：`cacheEntries()` **照常列出**它（读数要诚实，磁盘上确实
  /// 占着这些字节），但 `enforceCacheLimit()` **跳过**它 —— 既不把它算进
  /// 总量、也不把它当删除候选。把「列出来」和「能不能删」拆成两件事。
  final bool busy;

  String get name => path.split(RegExp(r'[\\/]')).last;

  @override
  String toString() =>
      'ClipCacheEntry($name, $bytes bytes, ${modified.toIso8601String()}'
      '${busy ? ', busy' : ''})';
}

/// 下载失败（非 2xx / 长度不符 / 无法建目录）。
class ClipDownloadException implements Exception {
  ClipDownloadException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ClipDownloadException: $message';
}

/// `sweepAllLimits()` 的结果：三个目录各删了几个 + 清完的合计占用。
///
/// 为什么不是只返回一个总数：用户点「按上限清理」之后要能知道**删了什么**
/// —— 尤其 `shotsDeleted > 0` 这一项（删掉的是他按快门留下的截图，不可再生），
/// 必须能如实报出来，不能混在一个「已清理」里。
class CacheSweepResult {
  const CacheSweepResult({
    required this.limitBytes,
    required this.clipDeleted,
    required this.mpvDeleted,
    required this.shotsDeleted,
    required this.bytesAfter,
  });

  /// 当时的上限（字节），即 `cacheLimitBytes`。
  final int limitBytes;
  final int clipDeleted;
  final int mpvDeleted;
  final int shotsDeleted;

  /// 清理**之后**三目录合计占用（字节）。
  final int bytesAfter;

  int get deletedTotal => clipDeleted + mpvDeleted + shotsDeleted;
  bool get nothingDeleted => deletedTotal == 0;
  bool get touchedShots => shotsDeleted > 0;

  @override
  String toString() =>
      'CacheSweepResult(limit=$limitBytes, clip=$clipDeleted, mpv=$mpvDeleted, '
      'shots=$shotsDeleted, after=$bytesAfter)';
}

/// 片段下载器：**真实**并发池 + **真实**缓存上限淘汰。
///
/// 全部状态是静态的（单例语义）—— 并发上限是**进程级**约束，
/// 每个调用点各持一个池就等于没有上限。
class ClipDownloader {
  ClipDownloader._();

  /// ★★ 淘汰互斥闸（**必须**是闸，不能只是共享集合）
  ///
  /// 洞①：并发下载时，每个 `download()` 完成后各跑一次
  /// `enforceCacheLimit()`，四个调用**各自**先算一遍 `total`、再各自按
  /// 自己那份快照删 —— 互相不感知。探针 P10 实测：6 个旧种子 60MB + 4 个
  /// 并发 10MB 新下载，理论上只需删到 64MB（该留 6 个 10MB），
  /// **实测终态 0 个文件、磁盘 0 字节**，刚下完的 4 个全被同伴删了。
  ///
  /// 修法：把"读快照 → 算 total → 删"整段串行化。后到的调用排队进来时
  /// 会**重新读一遍**目录（不是复用排队前的旧快照），所以每个调用看到的
  /// 都是"前一个删完之后的真实状态"，不会重复计数、不会删过头。
  ///
  /// 为什么用 Completer 链而不是一个 `Future` 字段：链尾永远是
  /// "最后一个排进来的调用"，后来者接在链尾即可；`Future` 字段会随
  /// 每个调用不断被替换，接上时可能接到一个已经跑完的（丢失互斥）。
  /// 这个范式与 :233-240 的 `_wakeWaiters`（排队唤醒）同一套。
  static Future<void> _gcChain = Future<void>.value();

  /// 此刻**正在下载**的成品文件的绝对路径。
  ///
  /// 语义 = 「这个路径的下载还没收尾（`download()` 还没走到淘汰那一步）」。
  /// 它同时被两个地方用：
  ///   - `cacheEntries()`：列出它们并打上 `busy` 标记（读数**不瞒报**）；
  ///   - `enforceCacheLimit()`：跳过它们 ⇒ 既不进 `total`、也**绝不删**。
  ///
  /// # 为什么「不计入」而不是「计入了但不删」
  /// 探针 P10 的 4 个并发下载：如果把它们算进 total，每个调用都会认为
  /// 「严重超限」，于是把**别人**的成品删掉来补自己的数 —— 这正是删空
  /// （终态 0 个文件）的原因。
  ///
  /// # ★ 豁免是**瞬态**的，不是永久的
  /// `download()` 在**跑淘汰之前**就把自己从登记里摘掉（见那里的注释）：
  /// 一摘掉，它立刻参与这一次统计 —— 上限守的是「磁盘上所有成品」，
  /// 刚下完的那个也在磁盘上。只有「正在写、或刚 rename 完但还没走到
  /// 淘汰那一步」的那几十毫秒里才豁免。
  ///
  /// 若不这样做（先淘汰、后摘），终态会稳定地**超出上限一个文件的大小**：
  /// 探针 P9 逐字读数（修之前）`limit=67108864 终态文件数=7
  /// 终态磁盘=73400320` —— 7 个 10MB 文件躺在 64MB 上限下。
  ///
  /// # ★ 用**引用计数**（路径 → 还在跑的同名下载数）而不是裸 Set（路径 → 还在跑的同名下载数）而不是裸 Set：
  ///   两个并发 `download()` 撞同一个 `fileName` 时，先收尾的那个若直接
  ///   `remove`，正在写盘的那个就会**失去豁免**，被同伴的淘汰当成孤儿
  ///   删掉。计数到 0 才真正注销。
  static final Map<String, int> _busyPaths = <String, int>{};

  /// 正在下载的成品路径数（只读，探针/测试用）。
  static int get debugBusyCount => _busyPaths.length;

  /// 正在下载的成品路径快照（只读，测试断言「下载中不被删」用）。
  static Set<String> get debugBusyPaths =>
      Set<String>.unmodifiable(_busyPaths.keys);

  /// 探针/测试用：把某个成品路径**标记**为「正在下载」。
  ///
  /// 为什么需要这个钩子：「rename 完成 → download() 收尾前」这个窗口在真实
  /// 代码里只有几十微秒，测试没法稳定地卡在里面 —— 而这正是探针 P4/P10
  /// 复现出「下载成功、文件消失」的那个窗口。有了它，`t101` 能把
  /// 「busy 的成品绝不被淘汰」测成**确定性**断言，而不是靠抢时序的 flaky 断言。
  /// 每调一次就**多一个**持有者（与真实 `download()` 的登记同语义）。
  @visibleForTesting
  static void debugMarkBusy(String path) => _markBusy(path);

  /// 探针/测试用：释放一个持有者（计数归 0 才真正注销）。
  @visibleForTesting
  static void debugUnmarkBusy(String path) => _unmarkBusy(path);

  /// 探针/测试用：某个路径当前的持有者计数（不在登记里 = 0）。
  @visibleForTesting
  static int debugBusyRefCount(String path) => _busyPaths[path] ?? 0;

  /// 探针/测试用：清空 busy 登记（不碰磁盘）。
  @visibleForTesting
  static void debugClearBusy() => _busyPaths.clear();

  static void _markBusy(String path) =>
      _busyPaths[path] = (_busyPaths[path] ?? 0) + 1;

  static void _unmarkBusy(String path) {
    final n = _busyPaths[path];
    if (n == null) return;
    if (n <= 1) {
      _busyPaths.remove(path);
    } else {
      _busyPaths[path] = n - 1;
    }
  }

  // ======================================================================
  //  ③ 并发上限
  // ======================================================================

  static const String kConcurrencyKey = 'dsh.download.concurrency';

  /// 滑杆的 9 档（0 = 不限制，见文件头）
  static const List<int> concurrencyOptions = [0, 1, 2, 3, 4, 5, 6, 7, 8];

  static const int defaultConcurrency = 4;

  /// 当前并发上限；0 = 不限制。
  static int get concurrency {
    final raw = UiPrefs.get(kConcurrencyKey);
    final v = raw == null ? defaultConcurrency : int.tryParse(raw);
    if (v == null) return defaultConcurrency;
    return v.clamp(0, 8);
  }

  static void setConcurrency(int value) {
    final v = value.clamp(0, 8);
    UiPrefs.set(kConcurrencyKey, v.toString());
    AppLog.write('DL', '并发上限 -> $v${v == 0 ? '（不限制）' : ''}');
    /*
     * ★ 改**大**上限要立刻放行排队者。
     *
     * 不然会这样：用户把滑杆从 1 拉到 8，看着「没反应」—— 因为排队中的
     * 任务原本只在**有槽位释放**时才被唤醒，而当前那个下载可能还要跑
     * 几十秒。改小不需要唤醒（下一次迭代自己会读到新的小上限）。
     */
    _wakeWaiters();
  }

  /// 文案：给 UI 用，保证「0」在任何地方读起来都是同一个意思
  static String concurrencyLabel(int v) => v == 0 ? '不限制' : '$v 个';

  /// 当前正在跑的下载任务数
  static int get activeCount => _active;

  /// **峰值**在跑任务数（探针断言用；只会涨，debugResetProbeCounters 清零）
  static int get maxObservedActive => _maxObservedActive;

  /// 已完成的任务数（探针用）
  static int get completedCount => _completed;

  static int _active = 0;
  static int _maxObservedActive = 0;
  static int _completed = 0;

  /// 等空位的排队者（FIFO）
  static final List<Completer<void>> _waiters = [];

  /// 探针/测试用：清零计数器
  static void debugResetProbeCounters() {
    _maxObservedActive = 0;
    _completed = 0;
  }

  /// ★ 并发池本体：拿到槽位才执行 body，拿不到就排队等。
  ///
  /// ★★ 上限在**每次循环**重新读一次 concurrency —— 用户在下载途中把
  ///    滑杆从 4 拉到 1，正在排队的任务会立刻按新上限收敛，不需要重启。
  ///    反方向（拉大）由 [setConcurrency] 里的 [_wakeWaiters] 立即放行。
  static Future<T> _withSlot<T>(Future<T> Function() body) async {
    while (true) {
      final limit = concurrency;
      if (limit == 0 || _active < limit) {
        _active++;
        if (_active > _maxObservedActive) _maxObservedActive = _active;
        break;
      }
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    try {
      final r = await body();
      _completed++;
      return r;
    } finally {
      _active--;
      _wakeWaiters();
    }
  }

  /// 唤醒所有排队者，让它们各自重判一次上限（拿不到槽位的会自己再排回去）
  ///
  /// # 为什么是「全唤醒」而不是「放行 N 个」
  ///
  /// 上限在 [_withSlot] 的 while 循环里**每次迭代都重读**，所以唤醒是
  /// **幂等**的：多唤醒不会超限（拿不到槽位的重新排队等下一次），
  /// 少唤醒才是 bug（任务会卡在队列里不动）。
  ///
  /// 顺序：被唤醒的 Completer 按 FIFO 顺序进微任务队列，
  /// 所以先排队的仍然先拿槽位。
  static void _wakeWaiters() {
    if (_waiters.isEmpty) return;
    final all = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final c in all) {
      if (!c.isCompleted) c.complete();
    }
  }

  // ======================================================================
  //  ④ 缓存上限
  // ======================================================================

  static const String kCacheLimitKey = 'dsh.cache.limitMb';

  static const List<int> cacheLimitOptions = [64, 128, 256, 512];

  static const int defaultCacheLimitMb = 256;

  /// 缓存目录的字节上限。
  static int get cacheLimitMb {
    final raw = UiPrefs.get(kCacheLimitKey);
    final v = raw == null ? defaultCacheLimitMb : int.tryParse(raw);
    if (v == null) return defaultCacheLimitMb;
    return v.clamp(64, 512);
  }

  static void setCacheLimitMb(int mb) {
    final v = mb.clamp(64, 512);
    UiPrefs.set(kCacheLimitKey, v.toString());
    AppLog.write('DL', '缓存上限 -> $v MB');
  }

  static int get cacheLimitBytes => cacheLimitMb * 1024 * 1024;

  // ======================================================================
  //  ④b 播放器（mpv）的解复用缓存
  // ======================================================================
  /*
   * ★ 为什么 ④ 要分**两个**目录、两组读数
   *
   * ```text
   * ① 片段缓存   <dataDir>/clip-cache   用户**看得见**的成品（下载下来的 mp4）
   *               由 enforceCacheLimit() 按 mtime 淘汰 —— 删了要重新下
   * ② 播放器缓存 <dataDir>/mpv-cache    mpv 自己写的**临时**解复用数据
   *               由 mpv 按 demuxer-max-bytes 自行滚动 —— 删了只是重缓冲
   * ③ 截图       <dataDir>/shots       用户**主动**留下的成品（截图 jpg）
   *               只在点「截图」时写入 —— 不参与任何自动淘汰
   * ```
   *
   * ⚠️ 三者**绝不能**共用目录：`clearCache()` 会把整个目录删空 ——
   *    若 mpv 的临时文件混在里面，用户点一次「清空缓存」就会把
   *    已经下好的片段一起删掉（反之亦然，播放中的 mpv 缓存文件
   *    被 enforceCacheLimit 当成「最旧的片段」淘汰）。
   *
   * ★ `cache-on-disk=yes` **不是我们设的** —— media_kit 硬编码在
   *   `real.dart:2401`（ALL 选项表里）。也就是说**在本次改动之前**，
   *   mpv 就已经在往磁盘写解复用缓存了，只是写在 mpv 自己的默认
   *   `cache-dir`（不在应用数据目录里，用户找不到、我们清不掉）。
   *   现在把 `cache-dir` 指到 <dataDir>/mpv-cache，它才进入我们的地盘。
   *
   * ★ 为什么用 `demuxer-max-bytes` 而不是 `bufferSize`：
   *   media_kit 的 `PlayerConfiguration.bufferSize` 在 `real.dart:2425-2426`
   *   **正好**映射到 `demuxer-max-bytes` + `demuxer-max-back-bytes` 两个属性。
   *   构造期传值只管到「开播前」；用户在设置页拖滑杆时播放器**已经活着**，
   *   所以必须再 `setProperty` 一次 —— 这就是下面这两个 API 的用处。
   */

  static const String kMpvMaxBytesKey = 'demuxer-max-bytes';

  static const String kMpvMaxBackBytesKey = 'demuxer-max-back-bytes';

  static const String kMpvCacheDirKey = 'cache-dir';

  /// 要回读取证的属性（顺序 = 报告里的显示顺序）
  static const List<String> kMpvCacheKeys = [
    kMpvMaxBytesKey,
    kMpvMaxBackBytesKey,
    kMpvCacheDirKey,
  ];

  /// 播放器缓存目录：<dataDir>/mpv-cache
  static Future<String> mpvCacheDir() async {
    final d =
        Directory('${await dataDir()}${Platform.pathSeparator}mpv-cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  /// 把「缓存上限」翻译成 mpv 属性表（键值对，顺序稳定便于断言）
  static List<(String, String)> mpvCacheProperties(String cacheDir) {
    final bytes = cacheLimitBytes.toString();
    return [
      (kMpvMaxBytesKey, bytes),
      (kMpvMaxBackBytesKey, bytes),
      (kMpvCacheDirKey, cacheDir),
    ];
  }

  /// 解析 mpv 回读的字节数
  ///
  /// ★ 实测：`getProperty('demuxer-max-bytes')` 回来的是
  ///   **带单位的可读串**（不是纯整数），所以必须解析单位；
  ///   解析不了返回 null（**不猜**，调用方按「回读失败」处理）。
  static int? parseMpvByteSize(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^([0-9]*\.?[0-9]+)\s*([A-Za-z]*)')
        .firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null) return null;
    final unit = m.group(2)!.toLowerCase();
    final mul = switch (unit) {
      '' || 'b' => 1,
      'k' || 'kb' || 'kib' => 1024,
      'm' || 'mb' || 'mib' => 1024 * 1024,
      'g' || 'gb' || 'gib' => 1024 * 1024 * 1024,
      _ => -1,
    };
    if (mul < 0) return null;
    return (v * mul).round();
  }
  /// mpv 缓存目录当前占用（字节）
  ///
  /// ★ 这里统计的是 **mpv 自己写的解复用文件**，与 `cacheBytes()`
  ///   （用户看得见的片段）是**两笔账** —— 报告里必须分开写，
  ///   不能相加成一个「总缓存」。
  ///
  /// 目录不存在返回 0（**不是错误**：还没播放过就没有缓存）。
  /// 单个文件读长度失败就跳过（mpv 可能正写着或刚好删掉），
  /// 不让一个临时文件把整个读数变成异常。
  static Future<int> mpvCacheBytes() async {
    try {
      final d = Directory(
        '${await dataDir()}${Platform.pathSeparator}mpv-cache',
      );
      if (!await d.exists()) return 0;
      var total = 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {
            // 读不到长度就跳过，不把读数变成异常
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  // ======================================================================
  //  数据目录 / 缓存目录
  // ======================================================================

  static String? _dataDirCache;

  /// 解析数据目录 —— 镜像 lib/shell.dart:792 的三步次序（见文件头注释）。
  static Future<String> dataDir() async {
    final cached = _dataDirCache;
    if (cached != null) return cached;

    const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
    if (override.isNotEmpty) {
      final d = Directory(override);
      if (!await d.exists()) await d.create(recursive: true);
      return _dataDirCache = d.path;
    }

    if (_kIsDesktop) {
      final appdata = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          '.';
      final dir =
          Directory('$appdata${Platform.pathSeparator}app.sourin.player');
      if (!await dir.exists()) await dir.create(recursive: true);
      return _dataDirCache = dir.path;
    }

    final d = await getApplicationSupportDirectory();
    return _dataDirCache = d.path;
  }

  /// 测试用：注入一个固定数据目录（null = 恢复自动解析）
  @visibleForTesting
  static void debugSetDataDir(String? dir) {
    _dataDirCache = dir;
  }

  /// 片段缓存目录：<dataDir>/clip-cache
  static Future<String> cacheDir() async {
    final d =
        Directory('${await dataDir()}${Platform.pathSeparator}clip-cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  /// 截图文件名：`shot-<yyyyMMdd>-<HHmmss>-<SSS>.jpg`；
  /// `suffix > 0` 时是 `…-<suffix>.jpg`（撞名兜底，见下）。
  ///
  /// # 为什么**必须**带毫秒
  /// 秒级时间戳在"连点两下"时会撞名 ⇒ 第二张**覆盖**第一张。
  /// 毫秒之后仍有理论上的撞名（系统时钟回拨 / 同一毫秒两次调用），
  /// 所以调用方还要配一层 `-1` / `-2` 兜底 —— 两层的分工是：
  /// 本函数负责"看起来是什么样"，调用方负责"绝不覆盖已有文件"。
  ///
  /// # 为什么用**本地**时间
  /// 文件名是给人看的（用户在资源管理器里找图），UTC 会让他对不上时间。
  ///
  /// ★ 抽成纯函数是为了**可测**：撞名兜底那条路径（`-1` / `-2`）
  ///   在真机上不可能复现（要同一毫秒连按两次），只能在这里验。
  static String shotFileName(DateTime n, {int suffix = 0}) {
    String p2(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    final stamp = '${p2(n.year, 4)}${p2(n.month)}${p2(n.day)}'
        '-${p2(n.hour)}${p2(n.minute)}${p2(n.second)}'
        '-${p2(n.millisecond, 3)}';
    return suffix <= 0 ? 'shot-$stamp.jpg' : 'shot-$stamp-$suffix.jpg';
  }

  /// 在 [dir] 里挑一个**还没被占用**的截图文件（返回**尚未创建**的 [File]）。
  ///
  /// 名字由 [shotFileName] 决定（格式的唯一真相），本函数只负责另一半：
  /// **绝不覆盖用户已有的图**。
  ///
  /// # 为什么兜底上限是 99
  /// `while (await f.exists())` 在"目录里塞满了同毫秒候选"时会一直转 ——
  /// 虽然要 100 张同一毫秒的图才可能发生，但**不可证明不会发生**的循环
  /// 不许留在交付代码里。到 99 就退回该候选（写进去也只是覆盖一个同毫秒
  /// 的旧候选，不伤别的图）。
  ///
  /// ★ 抽成静态函数是为了**可测**：`-1` 兜底那条路径在真机上不可能复现
  ///   （要同一毫秒连点两次），只能在这里验。
  static Future<File> uniqueShotFile(Directory dir, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    String pathOf(int suffix) => '${dir.path}${Platform.pathSeparator}'
        '${shotFileName(n, suffix: suffix)}';
    var f = File(pathOf(0));
    var i = 1;
    while (await f.exists()) {
      f = File(pathOf(i));
      i++;
      if (i > 99) break; // 兜底：绝不无限循环
    }
    return f;
  }
  /// 截图目录：<dataDir>/shots（★★ task-21 P1-30）
  ///
  /// # 为什么必须是**第三个**目录（与上面 ④b 的铁律同源）
  /// ```text
  /// ① clip-cache  用户看得见的成品（下载的 mp4）—— clearCache() 会删空
  /// ② mpv-cache   mpv 的临时解复用数据          —— mpv 自己滚动
  /// ③ shots       用户**主动**留下的截图        —— 谁都不该删
  /// ```
  /// ★ 把截图写进 `clip-cache` 的后果：用户点一次「清空缓存」，
  ///   他自己截的图就**一起没了** —— 而那不是缓存，是他的东西。
  static Future<String> shotsDir() async {
    final d = Directory('${await dataDir()}${Platform.pathSeparator}shots');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  // ======================================================================
  //  下载
  // ======================================================================

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) sourin/1.0';

  /// 文件名清洗：路径分隔符与 Windows 保留字符一律换掉。
  static String safeName(String raw) {
    var s = raw.split(RegExp(r'[\\/]')).last;
    s = s.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    if (s.isEmpty) s = 'clip.bin';
    if (s.length > 120) s = s.substring(0, 120);
    return s;
  }

  /// 下载一个 URL 到缓存目录（受并发上限约束）。
  ///
  /// ★ 走的是**真实 HTTP**：dart:io 的 HttpClient，逐块流式落盘，
  ///   先写 .part 再改名 —— 中途失败不会留下一个看起来完整的半截文件。
  static Future<ClipDownloadResult> download({
    required String url,
    required String fileName,
    List<(String, String)> headers = const [],
    String? intoDir,
    bool enforceLimitAfter = true,
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = intoDir ?? await cacheDir();
    final name = safeName(fileName);
    final target = File('$dir${Platform.pathSeparator}$name');
    final sw = Stopwatch()..start();

    return _withSlot(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..userAgent = _userAgent;
      final part = File('${target.path}.part');
      // ★ 从这一刻起，`target.path` 就是「正在下载」的路径：写盘期间它叫
      //   `<name>.part`（cacheEntries 本来就跳过），rename 之后叫 `<name>`，
      //   而 `_busyPaths` 保证后者也被 `cacheEntries()` 跳过、不被淘汰。
      //   登记必须在 try **之外**（try 之前），否则 openWrite 抛异常时
      //   收尾处的注销会把别人的登记误删。
      _markBusy(target.path);
      try {
        final req = await client.getUrl(Uri.parse(url));
        for (final h in headers) {
          req.headers.set(h.$1, h.$2);
        }
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw ClipDownloadException(
            'HTTP ${resp.statusCode} ${resp.reasonPhrase}  $url',
            statusCode: resp.statusCode,
          );
        }
        final declared = resp.contentLength >= 0 ? resp.contentLength : null;
        final sink = part.openWrite();
        var received = 0;
        try {
          await for (final chunk in resp) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, declared);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (declared != null && received != declared) {
          throw ClipDownloadException(
            '长度不符：收到 $received 字节，服务端声明 $declared 字节',
          );
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        /*
         * ★ 把成品的 mtime 钉成"下载完成时刻"。
         *
         * rename 只换名字，**保留 .part 的 mtime**。.part 是流式写出来的，
         * 它的 mtime 是"最后一次写入"的时刻 —— 探针 P8 实测一个 19.5 秒的
         * 下载，mtime 与完成时刻只差 24ms（写入过程一直在刷新），看着没事；
         * 但 P4 那种"大文件写了很久、其间没有别的文件活动"的场景里，
         * mtime 就是**下载开始**时刻，比同目录的小文件还旧。
         *
         * 后果是致命的：`enforceCacheLimit()` 按 mtime 从最旧开始删，
         * 于是**刚刚下完的那个大文件被当成最旧的第一个删掉** ——
         * 用户点"下载本集到缓存"，进度条走完、文件消失。P4 逐字读数：
         * `long.mp4 mtime=19:08:02` vs `small-5 mtime=19:43:02`，
         * `deleted=1`、`long.mp4 被删=true`。
         *
         * 钉成 now() 之后，"最近下载的 = 最新的 = 最后才被淘汰"这条
         * 用户直觉才成立（t101 的"保留最新"断言就是钉这条）。
         */
        try {
          await target.setLastModified(DateTime.now());
        } catch (_) {}

        AppLog.write(
            'DL',
            '完成 $name  ${(received / 1048576).toStringAsFixed(2)} MB'
            '  ${sw.elapsedMilliseconds} ms');
        /*
         * ★ 注销顺序：**先**从 `_busyPaths` 摘掉，**再**让淘汰跑。
         *
         * 为什么必须先摘：摘掉之后这个文件才正式进入「可被淘汰」的候选
         * 集，于是**它自己也参与这一次统计** —— 上限守的是「磁盘上所有
         * 成品」，刚下完的这个当然也在磁盘上。
         *
         * 反过来的话（先淘汰、后摘），这一次 enforce 会把刚下完的文件
         * 当成豁免项，终态就会稳定地**超出上限一个文件的大小**。
         * 探针 P9 逐字读数（修之前）：`limit=67108864 终态文件数=7
         * 终态磁盘=73400320` —— 7 个 10MB 文件躺在 64MB 上限下。
         * 修之后同一读数变成 6 个 / 62914560（<= 上限）。
         *
         * 它会不会因此被自己删掉？不会：上面刚把 mtime 钉成 now()，
         * 按「最旧先删」它排在最后一位。
         */
        _unmarkBusy(target.path);
        // ★ 每次下载完成后压一次上限。`enforceCacheLimit()` 内部走
        //   `_gcChain` 串行闸 —— 并发下载时这里是 4 个排队调用，不是
        //   4 个各删各的（洞①，见 _gcChain 的注释）。
        if (enforceLimitAfter) await enforceCacheLimit();
        return ClipDownloadResult(
          path: target.path,
          bytes: received,
          elapsed: sw.elapsed,
        );
      } catch (e) {
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
        AppLog.write('DL', '失败 $name  $e');
        rethrow;
      } finally {
        client.close(force: true);
        // ★ 兜底注销：正常路径已在上面（淘汰**之前**）摘过一次，这里是
        //   为了**失败路径** —— HTTP 非 200 / 长度不符 / 写盘异常时，
        //   `target.path` 可能压根没被 rename 出来，但登记必须清干净，
        //   否则它会永久占着一个「豁免名额」，让后来同名的下载绕过淘汰。
        //   计数为 0 时才真正注销（同名并发下载各自持有一次计数）。
        _unmarkBusy(target.path);
      }
    });
  }

  // ======================================================================
  //  缓存统计 / 淘汰
  // ======================================================================

  /// 片段缓存目录里的成品清单（**新的在前**）。
  ///
  /// 跳过的只有一类：`.part` —— 还在写的半截文件，本来就不算成品。
  /// `_busyPaths` 里的路径**会**出现在清单里（带 `busy: true`）——
  /// 它们是「已经下完、但发起它的那次 download() 还没收尾」的文件：
  ///   - 对**读数**（`cacheBytes`）它们必须算，否则磁盘占用会少报；
  ///   - 对**淘汰**它们必须排除（`enforceCacheLimit` 自己过滤 `busy`），
  ///     否则并发下每个刚下完的都会被同伴删掉（探针 P10 实测：4 个并发
  ///     下载全部完成，终态目录里 0 个文件）。
  /// 把「列出来」和「能不能删」拆成两件事，是为了让读数诚实、淘汰保守。
  static Future<List<ClipCacheEntry>> cacheEntries() async {
    final d = Directory(await cacheDir());
    if (!await d.exists()) return const [];
    final list = <ClipCacheEntry>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      if (e.path.endsWith('.part')) continue;
      final busy = _busyPaths.containsKey(e.path);
      try {
        final st = await e.stat();
        list.add(ClipCacheEntry(
          path: e.path,
          bytes: st.size,
          modified: st.modified,
          busy: busy,
        ));
      } catch (_) {}
    }
    list.sort((a, b) => b.modified.compareTo(a.modified)); // 新的在前
    return list;
  }

  /// 片段缓存占用（字节）。**含**正在下载的成品（磁盘上确实占着）。
  static Future<int> cacheBytes() async {
    final es = await cacheEntries();
    var n = 0;
    for (final e in es) {
      n += e.bytes;
    }
    return n;
  }

  /// ★ ④ 的**真实生效路径**：把**片段缓存**压回上限以内。
  ///
  /// 策略：按 mtime 从**最旧**开始删，直到总量 <= cacheLimitBytes。
  /// 返回删除的文件数。每次下载完成后自动调一次（见 download）。
  ///
  /// # 两处修复（都是探针复现出来的真 bug，不是重构）
  ///
  /// **① 串行化**（`_gcChain`）。并发下载时这个方法会被同时调用多次，
  ///    每个调用各自读一遍目录、各自算 `total`、各自按自己那份快照删 ——
  ///    互相不感知。探针 P10：6 个旧种子 60MB + 4 个并发 10MB 新下载，
  ///    理论上只需删到 64MB（该留 6 个 10MB），**实测终态 0 个文件**：
  ///    每个调用都把「别人刚下完的」也算进 total，于是每个都删过头，
  ///    合起来把目录清空了。现在整段「读快照 → 算 total → 删」在闸里跑，
  ///    后到的调用重新读目录，看到的是前一个删完的真实状态。
  ///
  /// **② 排除正在下载的成品**（`busy`）。rename 之后、`download()` 的
  ///    finally 之前，这个文件已经是成品了；这个窗口里如果被同伴的
  ///    enforce 当成普通旧文件删掉，用户看到的就是「下载成功、文件消失」
  ///    （P10 实测 4/4 全灭）。现在 `busy` 的条目既不进 `total`、也不进
  ///    候选集。
  static Future<int> enforceCacheLimit() async {
    // 排队：接在链尾，跑完再把链尾交出去（范式同 :233-240 的 _wakeWaiters）
    final prev = _gcChain;
    final done = Completer<void>();
    _gcChain = done.future;
    try {
      await prev;
      return await _enforceCacheLimitLocked();
    } finally {
      // ★ 必须在 finally 里 complete：否则一次异常会让后续调用永久挂死
      done.complete();
    }
  }

  /// `enforceCacheLimit()` 的**无锁**实现 —— 只允许从闸内调用。
  static Future<int> _enforceCacheLimitLocked() async {
    final limit = cacheLimitBytes;
    final es = await cacheEntries();
    var total = 0;
    for (final e in es) {
      if (e.busy) continue; // 正在下载的成品不计入，也不删
      total += e.bytes;
    }
    if (total <= limit) return 0;
    var deleted = 0;
    for (final e in es.reversed) {
      // es 新的在前 -> reversed 就是最旧的在前
      if (total <= limit) break;
      if (e.busy) continue;
      try {
        await File(e.path).delete();
        total -= e.bytes;
        deleted++;
        AppLog.write('DL', '淘汰 ${e.name}（${e.bytes} 字节）');
      } catch (_) {}
    }
    return deleted;
  }

  /// 清空**片段缓存**（含 .part 残留）—— 语义与范围**一个字都没改**。
  ///
  /// ⚠️ 只动 `clip-cache`：**不许**顺手删 `shots`（用户的截图）或
  ///    `mpv-cache`（播放器正用着）。`test/t63_shot_save_test.dart:155-174`
  ///    逐字钉住了这条（「清空缓存不许动截图（第三个目录存在的全部理由）」）。
  static Future<int> clearCache() async {
    final d = Directory(await cacheDir());
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    AppLog.write('DL', '清空缓存：删除 $n 个文件');
    return n;
  }

  /// 清空**播放器（mpv）解复用缓存** —— 不动片段与截图。
  ///
  /// 为什么可以单独清它：mpv-cache 里全是 mpv 自己写的临时解复用数据，
  /// 删了最坏的后果是「重新缓冲」；片段要重新下、截图不可再生，所以那两
  /// 个目录不给一键清空。
  static Future<int> clearMpvCache() async {
    try {
      final d = Directory(await mpvCacheDir());
      if (!await d.exists()) return 0;
      var n = 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is! File) continue;
        try {
          await e.delete();
          n++;
        } catch (_) {}
      }
      AppLog.write('DL', '清空播放器缓存：删除 $n 个文件');
      return n;
    } catch (_) {
      return 0;
    }
  }

  // ======================================================================
  //  缓存统计 / 淘汰 —— 三目录合计（Owner 第 6 条）
  // ======================================================================

  /// 单层目录里所有普通文件的字节和（不存在 / 异常一律返回 0）。
  static Future<int> _dirBytes(String path) async {
    try {
      final d = Directory(path);
      if (!await d.exists()) return 0;
      var n = 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is! File) continue;
        try {
          n += await e.length();
        } catch (_) {}
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 截图目录（`<dataDir>/shots`）当前占用（字节）。
  ///
  /// ★ 以前这个目录**没有任何读数** —— 设置页看不见它，上限也不管它。
  ///   探针 P2 实测：shots 里躺着 209715200 字节，而 `enforceCacheLimit()`
  ///   对它一个字节都不管。Owner 第 6 条「缓存目录也应该有大小限制，并且
  ///   要可以进行管理」里最没着落的就是这一块：目录长到多大用户无从知道。
  static Future<int> shotsBytes() async {
    try {
      return await _dirBytes(await shotsDir());
    } catch (_) {
      return 0;
    }
  }

  /// 三个目录的**合计**占用：片段 + 播放器 + 截图。
  ///
  /// ★ 三个数分开报是铁律（见上面 ④b 的注释），这个合计只用于「和上限
  ///   比一比」，**不能**用它替代分项读数 —— 用户要判断「我该清哪个」
  ///   必须看到分项。
  static Future<int> totalBytes() async {
    final clip = await cacheBytes();
    final mpv = await mpvCacheBytes();
    final shots = await shotsBytes();
    return clip + mpv + shots;
  }

  /// 从一个目录里**至少**腾出 `need` 字节（最旧的先删）。
  ///
  /// 返回 `(删除文件数, 实际腾出的字节数)`。删不动（文件被占用、权限不足）
  /// 就跳过继续试下一个 —— 只 catch 不重试，与 `enforceCacheLimit` 同范式。
  static Future<(int, int)> _evictFrom(String path, int need) async {
    if (need <= 0) return (0, 0);
    try {
      final d = Directory(path);
      if (!await d.exists()) return (0, 0);
      final infos = <(File, int, DateTime)>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          infos.add((e, st.size, st.modified));
        } catch (_) {}
      }
      infos.sort((a, b) => a.$3.compareTo(b.$3)); // 最旧的在前
      var deleted = 0;
      var freed = 0;
      for (final t in infos) {
        if (freed >= need) break;
        try {
          await t.$1.delete();
          freed += t.$2;
          deleted++;
        } catch (_) {}
      }
      return (deleted, freed);
    } catch (_) {
      return (0, 0);
    }
  }

  /// ★★ Owner 第 6 条的总闸：把**三个目录合计**压回 `cacheLimitBytes` 以内。
  ///
  /// # 淘汰顺序（先扔最不值钱的）
  /// ```text
  /// ① mpv-cache   播放器的临时解复用数据 —— 删了只是重新缓冲（最便宜）
  /// ② clip-cache  下载下来的片段       —— 删了要重新下（贵，但可再生）
  /// ③ shots       用户**主动**按快门留下的截图 —— 删了**不可再生**
  ///               ⇒ 只在①②都腾不出足够空间时才动它
  /// ```
  ///
  /// # 为什么只有它管三个目录，而每次下载后跑的还是 `enforceCacheLimit()`
  /// 自动路径（每次下载完成）**只**管片段目录：下载是高频、无人值守的动作，
  /// 让它顺手删掉用户正在看的 mpv 缓存或昨天截的图，太「突然」。
  /// 本函数只在用户**显式**点「按上限清理」时跑（以及测试调用）——
  /// 用户按了按钮就代表他接受「三个目录一起清到上限以内」。
  ///
  /// 每个目录**只腾出超限的那部分**（不是各自裁到上限）：合计超 10MB 就
  /// 从 mpv-cache 里腾 10MB，不会为了 10MB 把 200MB 的播放器缓存清光。
  static Future<CacheSweepResult> sweepAllLimits() async {
    final limit = cacheLimitBytes;
    var total = await totalBytes();
    if (total <= limit) {
      return CacheSweepResult(
        limitBytes: limit,
        clipDeleted: 0,
        mpvDeleted: 0,
        shotsDeleted: 0,
        bytesAfter: total,
      );
    }

    // ① mpv-cache（最便宜的一档）
    var mpvDeleted = 0;
    try {
      final mpvPath = await mpvCacheDir();
      final r = await _evictFrom(mpvPath, total - limit);
      mpvDeleted = r.$1;
      if (r.$1 > 0) AppLog.write('DL', '播放器缓存腾出 ${r.$2} 字节');
    } catch (_) {}
    total = await totalBytes();

    // ② clip-cache（专用逻辑：跳 .part、跳正在下载的成品）
    var clipDeleted = 0;
    if (total > limit) {
      clipDeleted = await enforceCacheLimit();
      total = await totalBytes();
    }

    // ③ shots（最后一档：用户截图不可再生）
    var shotsDeleted = 0;
    if (total > limit) {
      try {
        final shotsPath = await shotsDir();
        final r = await _evictFrom(shotsPath, total - limit);
        shotsDeleted = r.$1;
        if (r.$1 > 0) {
          AppLog.write('DL', '截图腾出 ${r.$2} 字节（已到最后一档，合计仍超限）');
        }
      } catch (_) {}
      total = await totalBytes();
    }

    AppLog.write(
        'DL',
        '按上限清理：片段删 $clipDeleted 个 / 播放器删 $mpvDeleted 个 / '
        '截图删 $shotsDeleted 个，合计 $total / $limit 字节');
    return CacheSweepResult(
      limitBytes: limit,
      clipDeleted: clipDeleted,
      mpvDeleted: mpvDeleted,
      shotsDeleted: shotsDeleted,
      bytesAfter: total,
    );
  }

  /// `sweepAllLimits()` 的结果（UI 用它给用户一句可判定的交代）。
  static String describeSweep(CacheSweepResult r) {
    if (r.nothingDeleted) {
      return '合计 ${humanBytes(r.bytesAfter)}，未超上限 ${humanBytes(r.limitBytes)}，无需清理';
    }
    final parts = <String>[];
    if (r.mpvDeleted > 0) parts.add('播放器缓存 ${r.mpvDeleted} 个');
    if (r.clipDeleted > 0) parts.add('片段缓存 ${r.clipDeleted} 个');
    if (r.shotsDeleted > 0) parts.add('截图 ${r.shotsDeleted} 个');
    return '已删除 ${parts.join(' / ')}，合计 ${humanBytes(r.bytesAfter)}'
        '（上限 ${humanBytes(r.limitBytes)}）';
  }

  /// 人类可读的缓存占用（UI 用）
  static String humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}
