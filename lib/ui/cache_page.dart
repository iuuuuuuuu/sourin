// ═══════════════════════════════════════════════════════════════════════
//  「已缓存」页 —— 底部第 5 个 tab（task-3 ⑲）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：
// > 对于已下载的,底部是不是应该加个已缓存的页面?然后有封面,
// > 并且显示出来缓存了多少
//
// # ★★★ 这份数据为什么是**扫盘**而不是查库
//
// 勘察结论（写这份文件时逐行核过）：lib/core/sourin_api.dart 全表 130+ 个
// static Future<...> 里**没有任何**「已下载 / 下载清单」接口 —— 下载是**纯文件
// 系统行为**（见下面「落盘布局」）。所以唯一**真实**的数据源就是扫描下载根目录。
// ⚠️ 硬要求（lead）：**不许 mock**。这份页面拿到的每一个字节都来自真的文件系统。
//
// # 落盘布局（扫盘规则就是从这三条反推出来的）
//
// ```text
// <下载根>/<剧名>/<第01集 剧集名>.mp4      ← DownloadDir.forWork(:171) + episodeFileName(:190)
// ```
// · <下载根>  = DownloadDir.root()（可由用户在 设置→播放 改；见 ⑳）
// · 子目录名 = ClipDownloader.safeName(剧名)
// · 文件名   = 多集时 `第NN集 <剧集名>`，单集时就是 <剧集名>（:198-200）
//
// ⚠️ **safeName 是不可逆的**（它把 \ / : * ? " < > | 之类的字符换掉）。
//    所以扫盘**不能**从目录名反推剧名 —— 反过来：显示用的剧名就是**目录名本身**。
//    这是刻意的：显示用户磁盘上真实的那个名字，不会骗人。
//
// # ★★ 封面的来源：旁文件 _sourin-cache.json
//
// 这条是本页最容易被做错的地方，先说清楚**错在哪**：
// ```text
// ① 下载只落一个 .mp4 —— 没有任何元数据（封面 / provider / id / 集号）
// ② 入队那行 lib/ui/detail_page.dart:1417-1431 构造 DownloadTask 时
//    **根本没有 cover 字段**（DownloadTask 也确实是领域无关的）
// ③ 纯从文件名反推 → 拿不到网络封面 URL，卡片只能是一片灰占位
// ```
// ⇒ 修法：下载**成功**时，在剧集目录里写一个很小的旁文件
//    _sourin-cache.json（CacheSidecar），记 provider/id/title/cover。
//    本页读到它就用真封面；读不到（老下载、用户手拷进来的文件）就退化成
//    **目录名 + 灰底** —— **不编造**封面。
//
// ⚠️ 旁文件以 _ 开头：_scanWork 必须跳过它，否则它会被当成一集「视频」。
//
// # 一个坑：看「缓存大小」不能只认扩展名
//
// 下载是**先写 .part 再改名**（lib/core/hls_download.dart:252-253）。所以：
//   · *.part = 正在下载的半成品 ⇒ 体积要算进「占用」，但**不算一集**（点了也播不了）；
//   · 非视频后缀（.json / .log）⇒ 不算集。
// 漏掉 .part 会让「正在下 8 个 G」时页面显示 0，用户以为没在下载。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-12（Owner 第三批）—— 这个页面补了三件事 + 一条勘察
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（附截图：1 部 · 0 集 / 0 B / 灰底「无」封面）：
// > 我点了下载本集,在这里缓存看不到封面,看不到下载进度,
// > 而且就算是下载到本地的 弹幕 历史等等功能也还是要有的
// > （追加）而且就算在外面也应该可以进行整部剧的删除操作
//
// ```text
// ① 封面看不到 —— 旁文件根本没人写
//    cache_page.dart 的 writeCacheSidecar 原来**全仓只有定义、零调用**
//    ⇒ 扫盘读不到 _sourin-cache.json ⇒ 走降级路径 ⇒ 灰底「无」。
//    ★ task-11（player-dev）已在 download_queue.dart:596 接上这个函数，
//      本文件**只**负责读取侧（扫盘 + 画封面）—— 见 §① 。
//
// ② 看不到下载进度 —— 本页原来**一次都没引用 DownloadQueue**
//    （task-12 之前 grep 0 处）⇒ 用户点「下载本集」后本页毫无反应。
//    ⇒ 顶部加「下载中」区块，订阅 DownloadQueue.tasks（见 _downloading）。
//    ★ 纪律：空队列**整块不画**（与 _LiveStrip 同一条）；
//      **不轮询扫盘** —— 见某任务变 done ⇒ 触发**一次** load()。
//
// ③ 整剧删除 —— 卡片上加入口，**必须二次确认**且写清「将删 N 集 / 共 X MB」
//    （真删文件、不可逆）⇒ 用 DownloadQueue.previewRemoveWork / removeWork。
//
// ④ 本地文件的弹幕 / 历史 —— 勘察结论（行号证据）
//    这条**本轮没做完**，如实标注在 §④ ，不许「按钮在但点了没用」。
// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/app_log.dart';
import '../core/download_dir.dart';
// ★ task-12 ②③：下载中区块（DownloadQueue.tasks）+ 整剧删除（removeWork）
import '../core/download_queue.dart';
// ★ task-17 ①：旁文件缺失时按目录名去库里找回元数据（provider/cover）
import '../core/sourin_api.dart';
// ★ task-17 ①：标题匹配复用**唯一那份**判据（lib/core/title_match.dart）——
//   绝不在这里写第二份归一化/相似度（两份必然漂移，见那个文件头的说明）。
import '../core/title_match.dart';
import 'tokens.dart';
// ★ 已缓存页卡片要能画**盘上的**封面（Owner 第 1009 批）——
//   解码尺寸沿用全站同一对函数，免得两页的解码算法漂移。
import 'widgets/app_loading.dart';
import 'widgets/cover_image.dart';
import 'widgets/motion_prefs.dart';
import 'widgets/overlay_motion.dart' show showAppDialog;
import 'widgets/poster_card.dart';

/// 旁文件名（ _ 开头 ⇒ 扫盘时会跳过它，不会被当成一集）
///
/// ★★ task-12：**取值来源改成 core 那份常量**（不再是本文件各写一份字面量）。
///
/// # 为什么要改（lead 裁决）
/// ```text
/// 旁文件现在由 lib/core/download_queue.dart 写（:642-655 _writeSidecarFor），
/// 而**读**在本文件（_scanWork）。两边若各写一份 "_sourin-cache.json" 字面量，
/// 将来改名必然只改一处 ⇒ 读侧永远读不到 ⇒ 症状「封面时有时无」。
/// ⇒ 让写侧与读侧引用**同一个**常量：本文件只是取个别名。
///
/// ⚠️ 与「删掉重复实现」是同一件事的两半（见下面被删的 writeCacheSidecar）。
///   实现重复会静默写错格式；常量重复则会在改名时立刻暴露 —— 但能免则免。
/// ```
const String kCacheSidecarName = DownloadQueue.kSidecarName;

/// 认得出是视频的后缀（小写比较）
const Set<String> kVideoExts = {
  '.mp4',
  '.mkv',
  '.webm',
  '.mov',
  '.m4v',
  '.ts',
  '.flv',
  '.avi',
};

/// 一集（落在磁盘上的一个视频文件）
@immutable
class CachedEpisode {
  const CachedEpisode({
    required this.fileName,
    required this.bytes,
    required this.isComplete,
  });

  final String fileName;
  final int bytes;

  /// false = 还是 .part（正在下载 / 上次中断）
  final bool isComplete;

  String get displayName {
    final name = fileName.endsWith('.part')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// 一部作品（= 下载根下的一个子目录）
@immutable
class CachedWork {
  const CachedWork({
    required this.dirName,
    required this.path,
    required this.episodes,
    this.provider,
    this.mediaId,
    this.cover,
    this.title,
    this.description,
    this.year,
    this.area,
    this.kind,
    this.badges = const <String>[],
    this.localCoverPath,
  });

  /// 真实目录名（safeName(剧名)，不可逆 ⇒ 就显示它）
  final String dirName;
  final String path;
  final List<CachedEpisode> episodes;

  /// 以下四项来自旁文件；缺旁文件时为 null（老下载 / 手拷进来的）
  final String? provider;
  final String? mediaId;
  final String? cover;
  final String? title;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ Owner 第 1009 批 13：随下载缓存下来的**作品元数据**
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么本地播放页需要它们
  // ```text
  // Owner：「封面介绍啥的 在线播放器有的,本地播放器也要有」
  // 而简介/年份/类型/角标**只有详情接口能给**，离线时核心也路由不到
  //   （本地会话的 provider 是 'local'）⇒ 只能靠下载那一刻缓存下来的。
  // ⚠️ 全部可空：老下载 / 手拷进来的目录**没有**旁文件 ⇒ 本地页降级显示
  //    （有旁文件的老目录也可能是旧格式，只写了前四个字段）。
  // ```
  final String? description;
  final String? year;
  final String? area;
  final String? kind;

  /// 后端拼好的角标（「连载中」「9.2 分」…）
  final List<String> badges;

  /// **本地封面文件**的绝对路径（旁文件记了文件名 + 文件真在盘上时才有）
  ///
  /// ★ 与 [cover] 的分工：
  /// ```text
  /// cover         = 网络 URL（联网上才画得出来）
  /// localCoverPath= 磁盘上的图片文件（**离线也在、跨机器也在**）
  /// ```
  /// ⇒ **显示时一律优先 [localCoverPath]**（本地页、已缓存页卡片、
  ///   播放请求的 cover 都是），[cover] 退成兜底。
  ///
  /// ★★★ 2026-10-10（Owner 第 1009 批）改了这条规矩：
  /// 原注释写「已缓存页卡片仍是网络图」，理由是「列表里没法为一堆卡片
  /// 各读一次文件」—— 但那张灰方块正是 Owner 报的 bug
  /// 「已缓存的也要显示原来的封面」。实测 Image.file 由 Flutter 的
  /// FileImage 走 ImageCache，**同一张图多张卡片只解一次码**，
  /// 「读一次文件」这个代价并不存在 ⇒ 以 Owner 的观感为准。
  final String? localCoverPath;

  /// 有没有任何可显示的元信息（本地页据此决定要不要画"简介"那一段）
  bool get hasMeta =>
      (description ?? '').trim().isNotEmpty ||
      (year ?? '').trim().isNotEmpty ||
      (area ?? '').trim().isNotEmpty ||
      (kind ?? '').trim().isNotEmpty ||
      badges.isNotEmpty;

  /// 卡片标题：旁文件里的剧名优先，否则用目录名
  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return dirName;
  }

  /// 已完成的集数（不含 .part）
  int get completedCount => episodes.where((e) => e.isComplete).length;

  /// 正在下载的集数
  int get partialCount => episodes.length - completedCount;

  /// 占用字节（含 .part —— 它真的占了盘）
  int get bytes {
    var n = 0;
    for (final e in episodes) {
      n += e.bytes;
    }
    return n;
  }

  /// 能直接播放的那一集（没有完成集 ⇒ null）
  CachedEpisode? get firstPlayable {
    for (final e in episodes) {
      if (e.isComplete) return e;
    }
    return null;
  }
}

/// 把字节数写成人看的大小
///
/// ★ 用 1024 进制（KiB/MiB/GiB）而不是 1000 进制：Windows 资源管理器、
///   du -h、以及用户自己在文件属性里看到的都是 1024 进制 ⇒ 页面上的
///   数字与用户**对照得上**才是关键。
String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[i]}';
}

/// ★★★ task-12 缺陷 A：**解析扫描根并扫盘** —— 扫盘这件事的**唯一**公共入口
///
/// # 为什么单独抽出来（而不是各处自己 `DownloadDir.root() + scanCacheWorks`）
/// ```text
/// 有两个调用方需要扫盘：
///   · 本文件的 CachePage（「已缓存」页）
///   · lib/ui/media_page.dart（右侧下载面板要在**重启后**仍列出磁盘上已下好的集）
/// 两处各写一遍 `DownloadDir.root()` + 探针注入点 = 两份实现 ⇒
///   探针只改得动其中一处，另一处测不到（或更糟：两处行为不一致）。
/// ⇒ 收成一个函数，两边都调它。
/// ```
///
/// ★ 探针注入点留在这里（[CachePage.debugScanRootOverride]），
///   于是 media_page 不必去碰那个 `@visibleForTesting` 字段 ——
///   既避免了 `invalid_use_of_visible_for_testing_member`，
///   也保证两个调用方**共用同一个**注入点。
Future<List<CachedWork>> scanCacheWorksAtRoot() async {
  final rootPath = CachePage.debugScanRootOverride ?? await DownloadDir.root();
  return scanCacheWorks(rootPath);
}

/// ★ 扫盘的**纯函数**部分（给测试直接喂目录，不必起整棵树）
///
/// ⚠️ 返回前按**目录名**排序：Directory.list 的顺序是文件系统给的，
///    不保证稳定 ⇒ 每次刷新卡片乱跳对用户是「看着像 bug」。
// ═══════════════════════════════════════════════════════════════════════
//  task-17 ① —— 旁文件缺失时，按**目录名**去 history / favorites 找回元数据
// ═══════════════════════════════════════════════════════════════════════
//
// # 问题（Owner 截图：缓存卡是灰底「无」首字占位）
// ```text
// 旁文件 _sourin-cache.json 是**后加**的功能。在它上线**之前**下载的那些目录里
// 没有它 ⇒ 扫盘拿不到 cover ⇒ 退化成首字占位。
// 但那些作品的数据**还在库里**（provider / native_id / cover 都有），
// 只是从没跟"磁盘上这个目录"关联过。
// ```
//
// # 匹配方式：目录名 ⇄ 库里的标题（归一化后**相等**）
// ```text
// 目录名 = ClipDownloader.safeName(剧名) —— safeName 只换掉非法字符，
//   所以它通常就是剧名本身（见本文件头"safeName 是不可逆的"那段）。
// ⇒ 用 lib/core/title_match.dart 的 titleSimilarity（**复用，不写第二份**）：
//     == 1.0 才算命中 —— 相等，不是"相似"。
// ```
// ⚠️ **为什么用 1.0 而不是某个阈值**（这条很重要，想清楚再改）
// ```text
// Owner 的硬要求是"不要为了好看乱配封面"：配错了用户会以为看的是别的剧。
//   而 titleSimilarity 对"子串"并不给 1.0（《无职转生》vs《无职转生 第三季》≈0.4），
//   所以 1.0 这条线**天然只在"归一化后逐字相同"时才成立** ⇒ 最保守、最不会乱配。
// ```
//
// # 命中多条怎么办（Owner 要求"显示出来"，不是"绝不猜"）
// ```text
// 同一部剧在多个站点都有记录（cycani:3862、hongniuzy2:150722）——
//   上一轮 detail_page 的策略是"不唯一就放弃" ⇒ 显示「本地」⇒ Owner 不满意。
// ⇒ 这里改成**排序后选第一条**，排序规则写死并留日志：
//     ① 有 cover 的优先（没封面就没解决 Owner 的问题）
//     ② 有 native_id 的优先（详情页来源要用）
//     ③ 历史更近的优先（watchedAt 大的在前）
//     ④ provider 名字典序（**保证确定性** —— 否则每次扫盘可能选到不同的）
// ```
//
// ⚠️ 进程级 memo（按目录名）：缓存页是**滚动列表**，`_scanWork` 每部作品都调一次，
//    每次都查 DB 的话，50 部作品 = 100 次 IPC（列表会明显卡）。
//    负结果也要 memo（否则"库里没有"的目录每次都白查一遍）。
//
// ⚠️ 失败必须静默降级：查库抛异常（无核心 / DB 锁）时返回 null，
//    绝不让缓存页整页失败 —— 封面是"锦上添花"，不是页面存在的前提。
final Map<String, CachedMeta?> _metaMemo = <String, CachedMeta?>{};

/// 从库里找回的元数据（只含 Owner 需要的"来源 + 封面"）
class CachedMeta {
  const CachedMeta({
    required this.provider,
    required this.nativeId,
    required this.title,
    this.cover,
    this.watchedAt = 0,
    this.source = '',
  });

  final String provider;
  final String nativeId;
  final String title;
  final String? cover;

  /// 历史里最后一次观看的时间戳（0 = 来自收藏）—— 排序用
  final int watchedAt;

  /// 命中来源：'history' / 'favorites'（日志与排查用）
  final String source;
}

/// 按目录名解析元数据（命中缓存则零 IPC）
@visibleForTesting
Future<CachedMeta?> resolveCacheMetaByDirName(String dirName) async {
  if (dirName.trim().isEmpty) return null;
  if (_metaMemo.containsKey(dirName)) return _metaMemo[dirName];
  final hit = await _lookupMeta(dirName);
  _metaMemo[dirName] = hit;
  return hit;
}

/// 清空 memo（测试用；也是"库变了要重查"的显式入口）
@visibleForTesting
void debugClearCacheMetaMemo() => _metaMemo.clear();

/// ★★ 探针注入点：库查询的**数据来源**（默认 null ⇒ 生产路径逐字不变）
///
/// # 为什么留这个口子（而不是让测试去连真核心）
/// ```text
/// `flutter_test` 里**加载不了 sourin_core.dll**（error 126，本项目实测过）
///   ⇒ `SourinApi.listHistory()` 必然抛 ⇒ 走 catch ⇒ 永远返回 null
///   ⇒ "命中"与"没命中"在测试里读数完全一样（都是 null）⇒ 测不出任何东西。
/// ```
/// ⇒ 让测试注入两份**假的历史/收藏**，验证的是**本文件的匹配与排序逻辑**：
///   归一化比较、多条命中的排序、memo、负面对照。
/// ⚠️ 生产路径（默认 null）**一行都不走这里** —— 见下面 `_lookupMeta` 的分支。
/// ★ 端到端那条（真库 → 真封面）由真机探针证，不靠这个口子。
@visibleForTesting
({Future<List<HistoryEntry>> Function() history,
        Future<List<Favorite>> Function() favorites})?
    debugMetaFetchers;

Future<CachedMeta?> _lookupMeta(String dirName) async {
  final cands = <CachedMeta>[];
  final injected = debugMetaFetchers;
  try {
    final hist = injected != null
        ? await injected.history()
        : await SourinApi.listHistory();
    for (final h in hist) {
      if (titleSimilarity(dirName, h.title) == 1.0) {
        cands.add(CachedMeta(
          provider: h.provider,
          nativeId: h.nativeId,
          title: h.title,
          cover: h.cover,
          watchedAt: h.watchedAt,
          source: 'history',
        ));
      }
    }
  } catch (e) {
    // ⚠️ 无核心 / DB 忙 ⇒ 降级，不影响页面
    AppLog.write('CACHE', '历史查询失败（目录=$dirName）：$e');
  }
  try {
    final favs = injected != null
        ? await injected.favorites()
        : await SourinApi.listFavorites();
    for (final f in favs) {
      if (titleSimilarity(dirName, f.title) == 1.0) {
        cands.add(CachedMeta(
          provider: f.provider,
          nativeId: f.nativeId,
          title: f.title,
          cover: f.cover,
          source: 'favorites',
        ));
      }
    }
  } catch (e) {
    AppLog.write('CACHE', '收藏查询失败（目录=$dirName）：$e');
  }

  if (cands.isEmpty) {
    /*
     * ★ 负面对照的读数（Owner 要求"造一个库里没有的目录 ⇒ 仍是首字占位"）：
     *   这条日志就是那件事的证据 —— 命中 0 条 ⇒ 返回 null ⇒ 调用方不设 cover。
     */
    AppLog.write('CACHE', '封面找回：目录「$dirName」在历史/收藏里命中 0 条 ⇒ 用首字占位');
    return null;
  }

  // ★ 排序：有封面 > 有 id > 历史更近 > provider 名字典序（确定性）
  cands.sort((a, b) {
    final ca = (a.cover ?? '').trim().isNotEmpty;
    final cb = (b.cover ?? '').trim().isNotEmpty;
    if (ca != cb) return cb ? 1 : -1;
    final ia = a.nativeId.isNotEmpty, ib = b.nativeId.isNotEmpty;
    if (ia != ib) return ib ? 1 : -1;
    if (a.watchedAt != b.watchedAt) return b.watchedAt.compareTo(a.watchedAt);
    return a.provider.compareTo(b.provider);
  });
  final pick = cands.first;
  AppLog.write('CACHE', '封面找回：目录「$dirName」命中 ${cands.length} 条 ⇒ '
      '选 ${pick.provider}:${pick.nativeId}（来源=${pick.source}，'
      '有封面=${(pick.cover ?? '').trim().isNotEmpty}）；'
      '其余：${cands.skip(1).map((c) => "${c.provider}:${c.nativeId}").join(", ")}');
  return pick;
}
Future<List<CachedWork>> scanCacheWorks(String rootPath) async {
  final root = Directory(rootPath);
  if (!await root.exists()) return const <CachedWork>[];

  final works = <CachedWork>[];
  await for (final ent in root.list(followLinks: false)) {
    if (ent is! Directory) continue;
    works.add(await _scanWork(ent));
  }
  works.sort((a, b) => a.dirName.compareTo(b.dirName));
  return works;
}

Future<CachedWork> _scanWork(Directory dir) async {
  final eps = <CachedEpisode>[];
  await for (final ent in dir.list(followLinks: false)) {
    if (ent is! File) continue;
    final name = ent.uri.pathSegments.last;
    // ★ 旁文件 / 非视频 ⇒ 不进「集」列表
    if (name == kCacheSidecarName) continue;
    final isPart = name.toLowerCase().endsWith('.part');
    final bare = isPart ? name.substring(0, name.length - 5) : name;
    if (!kVideoExts.contains(_extOf(bare))) continue;
    int bytes = 0;
    try {
      bytes = await ent.length();
    } catch (_) {
      // ★ 文件在扫码期间被删/被占用 ⇒ 当 0，绝不让整页失败
    }
    eps.add(CachedEpisode(
      fileName: name,
      bytes: bytes,
      isComplete: !isPart,
    ));
  }
  eps.sort((a, b) => a.fileName.compareTo(b.fileName));

  final dirName = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final meta = await _readSidecar(dir);
  /*
   * ★★★ task-17 ①：旁文件缺失时，去库里**找回**这部作品的元数据
   *
   * # 为什么需要（Owner 截图：缓存卡是灰底「无」首字占位）
   * ```text
   * 那条下载发生在"写旁文件的功能"上线**之前** ⇒ 目录里没有 _sourin-cache.json
   *   ⇒ 这里只能拿到目录名 ⇒ 卡片退化成灰底「无」。
   * 但数据**其实还在**：应用的库里有 provider/id/cover（只是没跟磁盘文件关联）。
   * ```
   * ⇒ 三级优先级（先便宜后贵）：
   * ```text
   * ① 旁文件有 cover          ⇒ 直接用（最快，现状）
   * ② 没有 ⇒ 按**目录名**去 history / favorites 里找（标题归一化后相等才算命中）
   * ③ 都没有 ⇒ 首字占位（现状；**不编造**封面）
   * ```
   * ⚠️ ② 的结果**只补空缺**：旁文件已经给了 provider/cover 时绝不被覆盖
   *    （旁文件是"下载那一刻"的事实，比事后按标题猜的更可信）。
   */
  var provider = meta?['provider'] as String?;
  var mediaId = meta?['id'] as String?;
  var cover = meta?['cover'] as String?;
  var title = meta?['title'] as String?;
  /*
   * ★★★ Owner 第 1009 批 13：读出随下载缓存下来的元数据与**本地封面文件**
   * ```text
   * ⚠️ 全部容错：一个字段类型不对（老文件 / 被人手改过）都只丢那一个字段，
   *    绝不让整部作品退化成"没信息" —— 尤其 jsonDecode 已经在 _readSidecar
   *    里 try/catch 过了，这里再抛一次就等于把整个缓存页搞崩。
   * ```
   */
  String? pickStr(String key) {
    final v = meta?[key];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  final description = pickStr('description');
  final year = pickStr('year');
  final area = pickStr('area');
  final kind = pickStr('kind');
  final badges = <String>[
    if (meta?['badges'] is List)
      for (final b in meta!['badges'] as List)
        if (b is String && b.trim().isNotEmpty) b.trim(),
  ];

  /*
   * ★ 本地封面文件：旁文件里记的是**文件名**（不是路径）——
   *   绝对路径不写进文件，换个盘符/把目录挪走之后旧值就会指向别处。
   * ⇒ 这里现拼，并用 `File(...).parent.path` 再确认它确实在**本目录**里。
   */
  String? localCoverPath;
  final coverFile = pickStr(DownloadQueue.kSidecarCoverFileKey);
  if (coverFile != null) {
    final f = File(
        '${dir.path}${Platform.pathSeparator}$coverFile');
    if (await f.exists() && f.parent.absolute.path == dir.absolute.path) {
      localCoverPath = f.path;
    }
  }

  /*
   * ★★★ Owner 第 1009 批：旁文件缺失时，**来源**也必须能找回
   * ```text
   * 原判据只有「封面空不空」——
   *   ⇒ 旁文件里有封面但没有 provider 的目录，去库里问也白问（白跑一次查询）
   *   ⇒ provider/mediaId 一直是 null ⇒ 详情页「来源」只能退成「本地」。
   * 现在：**三样里缺任意一样**都去问一次库（问一次的结果三条都补上）。
   * ```
   *
   * ⚠️ 赋值一律用 `??=`（**旁文件优先**）：
   *   库里那条是"按目录名猜"的，猜错了会**覆盖**旁文件里的真值。
   *   （原代码的 `cover = hit.cover` 在 hit.cover 为 null 时还会把
   *    旁文件里的好封面**抹掉**。）
   */
  if (_blank(cover) || _blank(provider) || _blank(mediaId)) {
    final hit = await resolveCacheMetaByDirName(dirName);
    if (hit != null) {
      provider ??= hit.provider;
      mediaId ??= hit.nativeId;
      cover ??= hit.cover;
      title ??= hit.title;
    }
  }
  return CachedWork(
    dirName: dirName,
    path: dir.path,
    episodes: eps,
    provider: provider,
    mediaId: mediaId,
    cover: cover,
    title: title,
    description: description,
    year: year,
    area: area,
    kind: kind,
    badges: badges,
    localCoverPath: localCoverPath,
  );
}

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

/// 「这个字段没有值」（null 或全是空白）—— 判据只有一处，别写第二份
bool _blank(String? s) => s == null || s.trim().isEmpty;

// ═══════════════════════════════════════════════════════════════════════
//  盘上封面（Owner 第 1009 批）的几何与绘制
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这里的尺寸要**逐字抄** PosterCard
// ```text
// PosterCard 算自己那一格：w = min(AppMetrics.posterWidth, 可用宽)，
// 高 = w / AppMetrics.posterAspect。
// 我们叠上去的那层必须**占同一块**，否则封面会偏出去半格。
// ⇒ 但它又不能重算一遍「万一 PosterCard 改了默认值」的公式，
//   所以这里把它的**当前**公式原样写下来，并在旁边钉死同步义务。
// ```
double _posterBoxWidth(BuildContext context) {
  final avail = MediaQuery.sizeOf(context).width;
  const want = AppMetrics.posterWidth;
  return want > avail ? avail : want;
}

double _posterBoxHeight(BuildContext context) =>
    _posterBoxWidth(context) / AppMetrics.posterAspect;

/// 画**盘上**的封面文件
///
/// # 为什么是 Image.file 而不是把路径塞给 [PosterCard]
/// coverImage 里写死了 Image.network（lib/ui/widgets/cover_image.dart:195），
/// 而 [PosterCard] 的 cover 语义就是网络 URL。改那两个共用文件会把
/// 「本地文件路径」这个新语义摊到 5 个在线页面上 ⇒ 不值得，本地这张卡自己画。
///
/// # 失败时**让位**而不是画裂图标
/// 占位块在下面（PosterCard 自己的底色）⇒ 这里返回 SizedBox.shrink()
/// 就等于「让位给它」，不画任何东西，避免两层错误提示叠在一起。
Widget _localCoverImage(BuildContext context, {required String path}) {
  final w = _posterBoxWidth(context);
  return Image.file(
    File(path),
    fit: BoxFit.cover,
    // ★ 与 coverImage 逐字同一条规则：2:3 卡片 + 16:9 源图时
    //   **按高度解码**才不糊（见 cover_image.dart 的 A1–A5 说明）。
    cacheHeight: coverDecodeHeightFor(
      context,
      layoutWidth: w,
      layoutHeight: w / AppMetrics.posterAspect,
    ),
    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
  );
}

Future<Map<String, dynamic>?> _readSidecar(Directory dir) async {
  final f = File('${dir.path}${Platform.pathSeparator}$kCacheSidecarName');
  try {
    if (!await f.exists()) return null;
    final txt = await f.readAsString();
    final j = jsonDecode(txt);
    return j is Map<String, dynamic> ? j : null;
  } catch (e) {
    // ★ 坏 JSON 不能让整页崩 —— 退回「无封面」形态
    AppLog.write('DL', '忽略坏的缓存旁文件 ${f.path}：$e');
    return null;
  }
}

/*
 * ★★★ task-12 去重：原来这里有一份 writeCacheSidecar 的**实现**，已删除。
 *
 * # 为什么删（lead 裁决，我认同）
 * ```text
 * task-11（player-dev）把旁文件写入**移进了 core**：
 *   lib/core/download_queue.dart:640  static const String kSidecarName = '_sourin-cache.json';
 *   lib/core/download_queue.dart:642-655  _writeSidecarFor(DownloadTask t, String dir)
 * 它的两条理由都成立：
 *   ① core 层 import ui 层是**反向依赖**（core 不该认识页面）；
 *   ② 构建耦合 —— core 的测试会因为 ui 页面写坏一半而编不过。
 * ```
 *
 * # 为什么必须删（不是「重复一份更保险」）
 * ```text
 * 同一个契约两份实现是**维护陷阱**：将来改契约（加字段/改名）必然只改一处，
 * 另一处**静默写错格式** ⇒ 症状正是「封面时有时无」——
 * ★ 那恰好就是 task-12 要修的那个原始缺陷的形态，绝不能自己再造一个。
 * 且它当时**全仓零调用**（本文件旧注释里就写着这句）⇒ 删掉零风险。
 * ```
 *
 * ⚠️ kCacheSidecarName 这个**常量**保住了（_scanWork 在用）—— 见文件头的定义。
 *   常量重复比实现重复安全得多（值如果不同，读侧会立刻暴露）。
 */

/// ★★★ task-12 ④：本地播放会话 —— **本文件负责组织**，shell 只转发
///
/// # 为什么要在这一层组织（lead 的硬约束）
/// ```text
/// lead 裁决：**不要改 shell.dart 里 MediaPage(...) 那个构造点的参数表** ——
///   因为 MediaPage 的构造（media_page.dart:76-101）**没有** file/path/local 参数，
///   给它加参数就必须同时改 media_page.dart，而那是「我的 / 详情页 / 已缓存页」
///   三个入口共用的合并页，改它的构造签名会波及 task-8（返回卡顿）。
/// ⇒ 约定：**本页把会话组织好**（一个 CachedWork + 选中的 CachedEpisode，
///   里面已经有绝对路径），shell 拿到的就是这个现成对象，只做转发。
/// ```
///
/// # ★★ provider 命名空间必须是 `local`（不能沿用站点 provider）
/// ```text
/// 勘察（player_page.dart）：
///   :5266 _saveProgress()  **照常写库**（:5279 SourinApi.saveProgress）
///   :5280-5281 键是 (_provider, _contentId)，:5314-5315 还带 episodeId。
/// ⇒ 若本地播放沿用「站点 provider + 站点 id」，就会**把在线那条记录的
///   进度改成本地文件的进度**（同一部剧在线看了一半、本地又看了一点，互相覆盖）。
/// ⇒ 用独立命名空间 `local` 把两笔账彻底分开。
///
/// ⚠️ 但**也不许静默不写**（lead 的硬约束）：本地文件的观看进度必须
///   **能存能读**（下次打开同一集要能续播），只是落在 `local` 这个空间里。
///   ⇒ id 用**文件的规范化绝对路径**：同一集永远算出同一个 id ⇒ 续播成立。
/// ```
@immutable
class CachedPlayRequest {
  const CachedPlayRequest({
    required this.work,
    required this.episode,
    required this.provider,
    required this.mediaId,
    required this.title,
    this.cover,
    this.originProvider,
    this.originMediaId,
  });

  final CachedWork work;
  final CachedEpisode episode;

  /// ★ 恒为 [kLocalProvider]（见上面「为什么必须独立命名空间」）
  final String provider;

  /// ★★ **原下载源**（B站 / 弹弹play / cycani …），拿不到时为 null
  ///
  /// # 为什么单独拎一个字段（Owner 第 1009 批：「要显示原来源，而不是 local」）
  /// ```text
  /// [provider] 恒为 'local' —— 它是**续播的命名空间**，不能改（改了旧进度全丢）。
  /// 但「原来源」是**给人看的**：详情页/播放页那个「来源」标签要的是
  /// 「B站」而不是「local」。
  /// ⇒ 两者**必须分开存**：一个当主键用，一个当文案用。
  ///
  /// 来源是 [CachedWork.provider]（扫盘时从旁文件或库里找回，见 _scanWork）。
  /// ```
  final String? originProvider;

  /// 原站的条目 id（与 [originProvider] 配对；拿不到为 null）
  final String? originMediaId;

  /// ★ 视频文件的规范化绝对路径（同一集 ⇒ 同一 id ⇒ 续播成立）
  final String mediaId;

  final String title;
  final String? cover;

  /// 交给 mpv 的地址（media_kit / mpv 原生吃 file://）
  String get fileUrl => Uri.file(episodeAbsolutePath).toString();

  /// 视频文件的**绝对路径**
  String get episodeAbsolutePath {
    final sep = Platform.pathSeparator;
    return '${work.path}$sep${episode.fileName}';
  }
}

/// ★ 本地会话的 provider 命名空间（与任何在线站点都不冲突）
const String kLocalProvider = 'local';

/// ★★★ task-12 ④：把磁盘上的路径**规范化成续播用的 key**
///
/// # 为什么必须规范化（lead 点名的硬要求）
/// ```text
/// provider=local、contentId=<文件绝对路径> 这一对是**历史/进度的主键**
/// （player_page.dart:5279-5281 SourinApi.saveProgress(_provider, _contentId)）。
/// 同一个文件若能算出**两个不同的 key**，续播就认不出来 —— 而同一个文件
/// 真的会有多种写法：
///   · 大小写：D:\Videos\A.mp4  vs  d:\videos\a.mp4   （Windows 不区分大小写）
///   · 分隔符：D:/Videos/A.mp4  vs  D:\Videos\A.mp4
///   · 重复分隔符：D:\\Videos\\\A.mp4
///   · 相对/绝对：.\A.mp4  vs  <cwd>\A.mp4
///   · Win32 长路径前缀：\\?\D:\Videos\A.mp4（>260 字符时系统会加）
/// ```
///
/// # 为什么不直接用 `File(...).absolute.path`
/// ```text
/// 它只解决「相对 → 绝对」，**不**折叠 `..`、**不**处理 `\\?\` 前缀、
/// 在 Windows 上也**不**统一盘符大小写 ⇒ 上面 5 种写法里它只挡住 1 种。
/// ```
///
/// ⚠️ 我**先找过**仓里现成的实现（lead 要求「复用别新造」）：
///   `download_dir.dart` / `clip_download.dart` 里都没有规范化函数
///   （只有 `safeName` 的字符清洗、以及拼路径）。它们拼路径时用的都是
///   `File(...).absolute.path`（见本函数末尾的兜底那行）⇒ 没有可复用件。
///   所以这里实现一个**最小**版本，只做「让同一个文件永远算出同一个串」
///   必需的那几件事，**不碰文件系统**（不做 realpath —— 那会要求文件存在，
///   而这里可能在扫盘结果被删之后才调用）。
String canonicalLocalPath(String raw) =>
    canonicalLocalPathAs(raw, windows: Platform.isWindows);

/// ★★★ 平台判断**参数化**的规范化实现（[canonicalLocalPath] 只是它的一行委托）
///
/// # 为什么必须把 `Platform.isWindows` 变成**入参**（本改动的全部理由）
/// ```text
/// 跑测试的机器是 Windows ⇒ `Platform.isWindows` 是**编译期常量 true**。
/// ⇒ 任何被 `if (Platform.isWindows)` 守卫包住的 POSIX 断言，在这台机器上
///   **永远不执行**：绿了也只证明「Windows 分支没坏」，对 macOS CI **零保证**
///   —— 那正是本仓铁律「假门禁比红更糟」要防的事。
/// ⇒ 把平台判断从编译期常量变成**入参**，POSIX 语义就能在 Windows 主机上
///   被**真跑一遍**（见 test/zz_cr_dl_c25_canon_path_test.dart 的用例 ③）。
/// ```
///
/// # CR-25 的两条说法，实测核对（结论钉在这里，别照抄 CR）
/// ```text
/// ① 「反斜杠转正斜杠只对 Windows 生效」⇒ **不成立**。
///    下面 ① 那行 replaceAll 在**任何平台**都跑，与 windows 参数无关
///    （测试用例 ② 在任何平台都通过 —— 那就是证据）。
/// ② 「非 Windows 也要折小写」⇒ **是错的**。
///    POSIX 大小写敏感：折小写会把 /movies/E1.mp4 与 /movies/e1.mp4
///    （**两个不同文件**）算成同一个进度键 ⇒ 续播串集。
///    ⇒ 折小写只在 windows:true 时做（见 ⑥）。
/// ```
///
/// # ⚠️ 与「逐字搬运」的两处**必要偏离**（探针实测出的既有缺陷）
/// ```text
/// 判据（测试，不许改）钉死了两条 UNC 期望，原实现**算不出来**。
/// 下面都是先把原函数跑一遍得到的**实测值**，不是读代码猜的：
///
///   · ② 的**判序**缺陷：原代码先判 startsWith('//?/') 并 substring(4)，
///     之后才判 startsWith('//?/UNC/') —— 后者**永远不可达**。
///     实测 \\?\UNC\nas\share\E1.mp4
///       ⇒ d:/<cwd>/unc/nas/share/e1.mp4
///     （UNC 被当成**相对路径**，还叠上了当前工作目录）
///     期望（用例 ①第 3 条）：//nas/share/e1.mp4。
///   · ④ 的**破坏**缺陷：③ 特意保留了开头那对斜杠（注释自己写着
///     「UNC 靠它」），但 11 行后的 ④ 用 (isAbs ? '/' : '') 重建时
///     只补**一个**斜杠 ⇒ 开头那对**在这里被吃掉**。
///     实测 //nas/share//E1.mp4 ⇒ /nas/share/e1.mp4（只剩单个前导斜杠）
///     期望（用例 ③第 4 条）：//nas/share/E1.mp4。
///
/// ⇒ 只动这两处（② 换成「长的先判」、④ 把开头那对原样接回去），
///   其余**逐字不变**。这不是「改测试迁就实现」，而是测试先钉死了
///   正确语义、实现来满足它。
/// ```
///
/// ⚠️ 语义契约：[canonicalLocalPath] 的结果必须与
///    canonicalLocalPathAs(raw, windows: Platform.isWindows) **完全相等**
///    （用例 ②第 2 条钉死了这条 ⇒ 上面的委托写法天然满足）。
String canonicalLocalPathAs(String raw, {required bool windows}) {
  var p = raw.trim();
  if (p.isEmpty) return p;

  // ① 正反斜杠统一成正斜杠（两种写法指向同一文件）
  //    ★ 全平台无条件执行 —— CR-25 说「只对 Windows 生效」，实测不成立
  p = p.replaceAll(r'\', '/');

  // ② Win32 长路径前缀：\\?\D:/x  →  D:/x
  //    （系统加它只是为了绕开 MAX_PATH，不改变文件身份）
  //
  //    ★★ 判序：**UNC 那条必须在前**（两条前缀互斥，长的先判）。
  //    原代码把 //?/ 放在前面 ⇒ //?/UNC/... 被 substring(4) 削成
  //    UNC/nas/...，UNC 判据**永远不可达** ⇒ 整条被当成相对路径。
  if (p.startsWith('//?/UNC/')) {
    // UNC 前缀 \\?\UNC\server\share → //server/share
    p = '//${p.substring(8)}';
  } else if (p.startsWith('//?/')) {
    p = p.substring(4);
  }

  // ③ 折叠重复斜杠（D://a///b → D:/a/b），但**保留**开头那对（UNC 靠它）
  final lead = p.startsWith('//') ? '//' : '';
  final body = lead.isEmpty ? p : p.substring(2);
  p = lead + body.replaceAll(RegExp('/+'), '/');

  // ④ 折叠 `.` / `..` 段（纯词法折叠，不碰盘）
  //
  //    ★★ 重建时必须把 ③ 保住的开头那对**原样接回去**：原来只写
  //    (isAbs ? '/' : '') ⇒ 单个斜杠，UNC 身份在这一步被吃掉。
  //
  //    ⚠️ 但只对**真 UNC 形状**（恰好两个前导斜杠、第 3 个字符不是斜杠）
  //    接回那对：`///x` 按 POSIX 应折成单个 `/`（3 个以上前导斜杠与 1 个
  //    等价），空的 `//` 也退回 `/`。这样除真 UNC 外，行为与改动前逐字一致
  //    —— 由 zz_tmp_canon_diff_test.dart 对 34 组输入做的差分探针实测过。
  final isAbs = p.startsWith('/');
  final head = (p.startsWith('//') && p.length > 2 && p[2] != '/')
      ? '//'
      : (isAbs ? '/' : '');
  final parts = p.split('/');
  final out = <String>[];
  for (final s in parts) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..' && out.isNotEmpty && out.last != '..') {
      out.removeLast();
      continue;
    }
    out.add(s);
  }
  p = head + out.join('/');

  // ⑤ Windows 盘符统一成大写（d:/x → D:/x）
  if (windows && p.length >= 2 && p[1] == ':') {
    p = p[0].toUpperCase() + p.substring(1);
  }

  // ⑥ Windows 上整体折成小写
  //    ★ 为什么必须：NTFS 大小写不敏感 ⇒ `A.mp4` 与 `a.mp4` 是**同一个**
  //      文件，但字符串不同 ⇒ 会算出两个 key ⇒ 续播失效。（POSIX 上
  //      大小写敏感，**不能**折，否则会把两个不同文件混成一个 key。）
  if (windows) p = p.toLowerCase();

  // ⑦ 兜底：相对路径（没被 ④ 变成绝对）交给 File.absolute 补当前目录。
  //    放在最后 —— 它不碰盘，但会读 cwd。
  if (!p.startsWith('/') && !(windows && p.length >= 2 && p[1] == ':')) {
    p = File(p).absolute.path.replaceAll(r'\', '/');
    if (windows) p = p.toLowerCase();
  }

  return p;
}

/// 从一部作品挑出一集，组织成**本地播放会话**（挑不出返回 null）
///
/// 只挑**已完成**的集（`.part` 点了必然失败，见 [CachedEpisode.isComplete]）。
/// [prefer] 用来指定具体某一集（例如用户在卡片上点了第 3 集）。
CachedPlayRequest? buildLocalPlayRequest(
  CachedWork work, {
  CachedEpisode? prefer,
}) {
  final ep = (prefer != null && prefer.isComplete)
      ? prefer
      : work.firstPlayable;
  if (ep == null) return null;

  final sep = Platform.pathSeparator;
  final abs = '${work.path}$sep${ep.fileName}';

  return CachedPlayRequest(
    work: work,
    episode: ep,
    provider: kLocalProvider,
    mediaId: canonicalLocalPath(abs),
    title: work.displayTitle,
    // ★ 原来源**不是** local：它是这部作品当初从哪个站下的
    //   （旁文件里有；旁文件没有时 _scanWork 已去库里按目录名找回）。
    //   null ⇒ 真不知道，不猜（详情页会退成「本地」）。
    originProvider: _blank(work.provider) ? null : work.provider,
    originMediaId: _blank(work.mediaId) ? null : work.mediaId,
    // ★★★ Owner 第 1009 批「已缓存的也要显示原来的封面」
    //   本地封面文件**离线也在**、也不依赖站点代理端口，换机器/换网络都还在
    //   ⇒ 优先用它，网络 URL 退成兜底（它只在联网上才画得出来）。
    cover: work.localCoverPath ?? work.cover,
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ Owner 第 1009 批 13：本地缓存的**删文件** —— 唯一的公共实现
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有**路径穿越**防护（lead 明令）
// ```text
// 删缓存是**不可逆**的破坏性操作，而文件名来自扫盘、进而可能来自
// 旁文件/用户手拷/恶意构造的目录名。
// 而"文件名字段"是完全不受控的输入：文件名里可以有 `..`，
// 例如一个叫 `第01集 ....mp4` 的文件，`dirname(dirname(path))` 就跑出去了。
// ⇒ 规则（一行判据，任何实现都照它）：
//     **只允许删 <作品目录>/ 里的文件**，且文件名不得含路径分隔符或 '..'。
// ```
//
// # 为什么写在 cache_page 而不是 detail_page
// ```text
// 「已缓存」页与「本地播放页」都要删 —— 两处各写一遍必然漂移（本仓反复踩过）。
// 而扫盘数据（CachedWork / CachedEpisode）本来就出自本文件 ⇒ 它是天然的家。
// ```
class CachedDelete {
  CachedDelete._();

  /// 该文件名**能不能**在 [workDir] 下被删除（纯判据，可单测）
  ///
  /// ★ 返回 `File`（已 join 好）而不是 bool：调用方直接删，省一次自己拼路径
  ///   —— 拼路径的地方越多，越容易在某处忘了判穿越。
  @visibleForTesting
  static File? resolveDeletable(String workDir, String fileName) {
    // ① 文件名里不许出现任何分隔符（`..` 的前提是分隔符，这条直接掐死）
    if (fileName.isEmpty) return null;
    if (fileName.contains('/') || fileName.contains('\\')) return null;
    if (fileName == '.' || fileName == '..') return null;
    // ② Windows 上 `C:foo.mp4`（带盘符）也是穿越的一种
    if (fileName.contains(':')) return null;

    final dir = Directory(workDir).absolute.path;
    final f = File('$dir${Platform.pathSeparator}$fileName').absolute;
    // ③ 结构性的最后一道：解析后的父目录必须**逐字**等于作品目录
    //    （absolute 已经消掉了 `..`，所以这一步能挡住任何拼出来的绕路）
    if (f.parent.path != dir) return null;
    return f;
  }

  /// 删一个文件（含同名的 `.part` / `.ts` 半成品），返回"是否真删掉了什么"
  ///
  /// ⚠️ 后缀清单与 `DownloadQueue.deleteTaskFiles` **保持一致** ——
  ///   两处各写一份迟早漂移（一个删 .mp4、一个删 .ts）。
  static Future<bool> deleteEpisodeFile(String workDir, String fileName) async {
    final f = resolveDeletable(workDir, fileName);
    if (f == null) {
      AppLog.write('CACHE', '拒绝删除越界文件名：$fileName');
      return false;
    }
    final base = fileName.endsWith('.part')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    var any = false;
    for (final name in <String>[base, '$base.part', '$base.ts', '$base.ts.part']) {
      final target = resolveDeletable(workDir, name);
      if (target == null) continue;
      try {
        if (await target.exists()) {
          await target.delete();
          any = true;
          AppLog.write('CACHE', '已删 $target');
        }
      } catch (e) {
        // ★ 一个删不掉（被别的程序占着）不能连带放弃后面的
        AppLog.write('CACHE', '删文件失败 $target：$e');
      }
    }
    return any;
  }

  /// 批量删（先逐个判越界，再删）⇒ 返回（删掉几个文件, 放掉多少字节）
  static Future<(int files, int bytes)> deleteEpisodes(
    String workDir,
    List<CachedEpisode> eps,
  ) async {
    var files = 0;
    var bytes = 0;
    for (final e in eps) {
      if (await deleteEpisodeFile(workDir, e.fileName)) {
        files++;
        bytes += e.bytes;
      }
    }
    return (files, bytes);
  }
}

/// 点卡片进播放（复用现成入口）
///   会话在**本文件**组织好（含 provider=local 与文件的绝对路径），
///   shell 只负责转发（见 buildLocalPlayRequest 的注释）。
typedef OnOpenCached = void Function(CachedPlayRequest request);

class CachePage extends StatefulWidget {
  const CachePage({
    super.key,
    this.isTv = false,
    this.onOpen,
  });

  final bool isTv;

  /// 宿主（shell）接到后去 push MediaPage —— 与「我的」版块同一个入口
  final OnOpenCached? onOpen;

  /// ★ 探针口：临时指定扫描根（**不改 pref、不落盘**）
  ///
  /// 为什么要有它：真站点上扫描根来自 `DownloadDir.root()`（异步碰盘），
  /// 而 flutter_test 的 `t.pump` 走**受控（fake）时钟** —— 真实 IO 的 future
  /// 在那个区里永不完成，页面会永远停在 loading 态（上一轮就是这么红的：
  /// loadCount=1 但 loading 永远 true）。**那是探针假阴性，不是页面缺陷。**
  /// ⇒ 给探针一个注入点：测试直接喂一个真目录，走的仍是同一条
  ///    `scanCacheWorks` + `setState` 路径，渲染出来的是真的。
  @visibleForTesting
  static String? debugScanRootOverride;

  @override
  State<CachePage> createState() => CachePageState();
}

class CachePageState extends State<CachePage> {
  bool _loading = true;
  String _root = '';
  List<CachedWork> _works = const <CachedWork>[];
  Object? _error;

  /// ★ 对外暴露：保活验收测试要数「切回来有没有重建」
  ///   （State 被销毁重建 ⇒ 这个计数器归零）
  int debugLoadCount = 0;

  /// 只读诊断（探针用）—— 页面卡在哪一态一眼可见
  bool get debugLoading => _loading;
  Object? get debugError => _error;
  String get debugRoot => _root;
  int get debugWorkCount => _works.length;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ task-12 ②：下载中区块（订阅队列，**不轮询扫盘**）
  // ══════════════════════════════════════════════════════════════════

  /// 上一次看到的「已完成任务 id 集合」
  ///
  /// ★ 为什么用**集合**而不是一个 bool：
  ///   队列里可能同时有多个任务，只用 bool 的话「A 刚 done、B 变 queued」
  ///   会把「已处理过 A」这件事丢掉 ⇒ A 再 done 时会重复触发（或永远不触发）。
  Set<String> _seenDoneIds = <String>{};

  /// 本页曾经见过「下载中」区块非空（探针用：证明空队列整块不画的**反面**）
  bool debugSawDownloading = false;

  /// 最近一次由「队列完成」触发的重扫次数（探针用）
  int debugQueueTriggeredReloads = 0;

  /// 当前队列快照（探针/渲染共用，避免两处读同一个 notifier 走样）
  List<DownloadTask> get _queueTasks => DownloadQueue.tasks.value;

  /// ★ 订阅队列：只在**有人变 done** 时触发一次 [load]
  ///
  /// # 为什么不是每 300ms 轮询扫盘（lead 明令）
  /// ```text
  /// 扫盘是**真碰盘 IO**（每个剧目录一次 list + 每个文件一次 length）。
  /// 轮询会让「已缓存」页在后台一直转磁盘；而真正需要重扫的时刻只有一个：
  ///   **某个任务从「下载中」变成「完成」** —— 那一刻它才刚从
  ///   「下载中区块」消失、应当出现在下面的扫盘结果里。
  /// ```
  /// ⚠️ 只在 `done` 上触发，**不在** failed 上触发：失败不会产生新文件。
  void _onQueueChanged() {
    final list = _queueTasks;
    final doneIds = <String>{
      for (final t in list)
        if (t.state == DownloadState.done) t.id,
    };
    final fresh = doneIds.difference(_seenDoneIds);
    _seenDoneIds = doneIds;
    if (fresh.isEmpty) return;
    // ★ 这一行是「下载完自动出现」的唯一触发点（不是定时器）
    debugQueueTriggeredReloads++;
    AppLog.write('DL', '队列有 ${fresh.length} 个任务完成 ⇒ 重扫已缓存页');
    unawaited(load());
  }

  @override
  void initState() {
    super.initState();
    DownloadQueue.tasks.addListener(_onQueueChanged);
    unawaited(load());
  }

  @override
  void dispose() {
    DownloadQueue.tasks.removeListener(_onQueueChanged);
    super.dispose();
  }

  /// 重新扫一遍（切回本 tab 时由 shell 调）
  Future<void> load() async {
    debugLoadCount++;
    try {
      // ★ 与 media_page 共用**同一个**扫描入口（探针注入点只有一处）
      final rootPath = CachePage.debugScanRootOverride ?? await DownloadDir.root();
      final works = await scanCacheWorks(rootPath);
      if (!mounted) return;
      setState(() {
        _root = rootPath;
        _works = works;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  int get _totalBytes {
    var n = 0;
    for (final w in _works) {
      n += w.bytes;
    }
    return n;
  }

  int get _totalEpisodes {
    var n = 0;
    for (final w in _works) {
      n += w.completedCount;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★★★ task-12 ②：订阅队列 —— 只重建「下载中」那一块，不重建整页
    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: DownloadQueue.tasks,
      builder: (context, tasks, _) {
        // 只显示「还没结束」的任务（done 的会出现在下面的扫盘结果里；
        // failed 的**要显示**，否则用户看不到失败原因）
        final active = tasks
            .where((t) => t.state != DownloadState.done)
            .toList(growable: false);
        final strip = _downloading(colors, active);
        if (strip != null) debugSawDownloading = true;

        /*
         * ★ 空态与「下载中」的取舍
         * ```text
         * 用户刚点「下载本集」时**盘上还没有任何文件** ⇒ 若沿用原来那条
         * 「_works.isEmpty ⇒ 整页空态」，他会看到「还没有下载过东西」——
         * 而队列里明明正在下。那正是 Owner 说的「看不到下载进度」。
         * ⇒ 只要有活跃任务，就**不显示空态**，先把进度画出来。
         * ```
         */
        if (_loading && active.isEmpty) {
          // ★ OPS-14：换成共享组件（原来没给尺寸 ⇒ Material 默认 40×40，
          //   描边 4px 落在浅灰 `c.secondary` 轨道上，远看只是一圈发丝）。
          return const Center(child: AppLoading());
        }
        if (_error != null && active.isEmpty) {
          return _empty(
            colors,
            icon: Icons.error_outline_rounded,
            title: '读不了下载目录',
            body: '$_error',
          );
        }
        if (_works.isEmpty && active.isEmpty) {
          return _empty(
            colors,
            icon: Icons.download_done_rounded,
            title: '还没有下载过东西',
            body: '在详情页点「下载」把整集存到本地，这里就会列出来。',
          );
        }
        return RefreshIndicator(
          onRefresh: load,
          child: CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(child: _header(colors)),
              if (strip != null) SliverToBoxAdapter(child: strip),
              SliverPadding(
                padding: Layout.contentInsetOf(context),
                sliver: SliverLayoutBuilder(
                  builder: (context, c) {
                    final band = c.crossAxisExtent +
                        Layout.contentPaddingOf(context) * 2;
                    final cols = Layout.columnsForBand(band);
                    final gap = Layout.gapFor(band);
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: Sp.x6,
                        childAspectRatio: _posterAspect(),
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (_, i) => _card(colors, _works[i]),
                        childCount: _works.length,
                      ),
                    );
                  },
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: Sp.x10)),
            ],
          ),
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ task-12 ②：「下载中」区块
  // ══════════════════════════════════════════════════════════════════

  /// 画「下载中」区块；**空队列返回 null**（调用方据此整块不画）
  ///
  /// # 为什么空队列必须整块不画（与本仓 _LiveStrip 同一条纪律）
  /// ```text
  /// 一条永远存在的「下载中：暂无」标题条会白占一屏顶部空间，
  /// 而且让用户以为**有空数据**。没有任务 = 这块不存在。
  /// ```
  Widget? _downloading(ColorScheme colors, List<DownloadTask> active) {
    if (active.isEmpty) return null;
    return Padding(
      padding: EdgeInsets.only(
        left: Layout.contentPaddingOf(context),
        right: Layout.contentPaddingOf(context),
        bottom: Sp.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '下载中 · ${active.length}',
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: FontWeights.semibold,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: Sp.x2),
          for (final t in active) _downloadRow(colors, t),
        ],
      ),
    );
  }

  Widget _downloadRow(ColorScheme colors, DownloadTask t) {
    final pct = (t.progress * 100).round();
    final isFailed = t.state == DownloadState.failed;
    // ★ 三种状态都要能一眼分清（Owner 要「看到下载进度」）
    final statusText = switch (t.state) {
      DownloadState.queued => '排队中',
      DownloadState.running => t.total > 0 ? '$pct%' : '下载中',
      DownloadState.paused => '已暂停',
      DownloadState.failed => '失败',
      DownloadState.done => '已完成',
    };
    final epTitle = t.episodeTitle.isNotEmpty ? t.episodeTitle : t.fileName;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${t.title} · $epTitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                statusText,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  fontWeight: FontWeights.semibold,
                  color: isFailed ? colors.error : colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x1),
          ClipRRect(
            borderRadius: Radii.rSm,
            child: LinearProgressIndicator(
              // ★ total<=0（还没拿到分片清单）时给一个不确定进度条，
              //   不要画成 0% —— 那看起来像「卡住了」
              value: t.total > 0 ? t.progress : null,
              minHeight: 4,
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
          // ★ 失败必须能看到**原因原文**（lead 明令）—— 否则用户只
          //   知道「失败了」，不知道怎么处理
          if (isFailed && (t.error ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: Sp.x1),
            Text(
              t.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 网格格子的宽高比 —— **与首页海报卡完全同源**（本页不再有额外那一行）
  ///
  /// ★ 2026-10-10（Owner：「孤卐卐一个删除按钮真不好看」）：
  ///   卡片结构变成了 `PosterCard` 本身（删除入口收进封面右上角的「更多」浮层）
  ///   ⇒ 格子不再需要多留 `_deleteRowH` 那 48px ⇒ 这个算式与
  ///   `follow_page.followGridAspect()` **逐值相同**了。
  double _posterAspect() =>
      AppMetrics.posterWidth /
      (AppMetrics.posterWidth / AppMetrics.posterAspect +
          AppMetrics.posterMetaHeight(titleLines: 2));

  Widget _header(ColorScheme colors) {
    final n = _works.length;
    final eps = _totalEpisodes;
    /*
     * ★ Owner ⑨：「已缓存」页 UI 优化 —— 顶部统计改成三枚**小统计块**
     * ```text
     * 改前：一个「已缓存」标题 + 右边一个大号总占用 + 下面一行
     *       「N 部 · M 集 | <完整磁盘路径>」。
     * 观感问题：
     *   ① 三样信息挤在一行里，字号/权重各不相同 ⇒ 读不出主次；
     *   ② **把完整的下载目录路径放在页面上**——那是调试信息，不是给用户看的
     *      （而且路径很长，会把那一行顶得右对齐后溢出感很强）。
     * ⇒ 现在：标题一行，下面三枚统计块（作品 / 集数 / 占用），
     *   磁盘路径收进 Tooltip（要查时悬停/长按才看得到）。
     * ```
     */
    return Padding(
      padding: EdgeInsets.only(
        left: Layout.contentPaddingOf(context),
        right: Layout.contentPaddingOf(context),
        top: Sp.x5,
        bottom: Sp.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '已缓存',
            style: TextStyle(
              fontSize: FontSizes.xl,
              fontWeight: FontWeights.semibold,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x3),
          Row(
            children: <Widget>[
              _stat(colors, '作品', '$n'),
              const SizedBox(width: Sp.x8),
              _stat(colors, '已下好', '$eps'),
              const SizedBox(width: Sp.x8),
              // 路径挂在 Tooltip 上：仍然查得到，但不再占版面
              Tooltip(
                message: _root.isEmpty ? '' : '存放位置：$_root',
                child: _stat(colors, '占用', humanBytes(_totalBytes)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一枚统计块（大数字 + 小标签）
  ///
  /// ★ 为什么数字在上、标签在下：扫视时先抓到的是**量**，再确认它是什么；
  ///   反过来（标签在上）会让人先读一串字才知道该期待多大的数字。
  Widget _stat(ColorScheme colors, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: TextStyle(
            fontSize: FontSizes.lg,
            fontWeight: FontWeights.semibold,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _card(ColorScheme colors, CachedWork w) {
    final sub = StringBuffer(humanBytes(w.bytes));
    sub.write(' \u00b7 ');
    if (w.partialCount > 0) {
      sub.write('${w.completedCount} \u96c6\uff08${w.partialCount} \u4e2a\u5728\u4e0b\uff09');
    } else {
      sub.write('${w.completedCount} \u96c6');
    }
    // \u2605 \u5361\u7247\u672c\u8eab\u5c31\u662f PosterCard\uff08\u4e0e\u9996\u9875\u6d77\u62a5\u5361\u9010\u5b57\u8282\u540c\u6e90\uff09
    return _CacheWorkCard(
      work: w,
      onOpen: w.firstPlayable == null || widget.onOpen == null
          ? null
          : () => _openWork(w),
      onDelete: () => unawaited(_confirmDelete(w)),
      onOpenFolder: () => unawaited(_openFolder(w)),
    );
  }

  /// \u5728\u6587\u4ef6\u7ba1\u7406\u5668\u91cc\u6253\u5f00\u90a3\u4e2a\u76ee\u5f55\uff08\u5931\u8d25\u53ea\u8bf4\u4e00\u53e5\u8bdd\uff0c\u4e0d\u5f39\u7a97\uff09
  Future<void> _openFolder(CachedWork w) async {
    final ok = await DownloadDir.open(w.path);
    if (!ok) _say('\u6253\u5f00\u76ee\u5f55\u5931\u8d25\uff08\u5f53\u524d\u7cfb\u7edf\u4e0d\u652f\u6301\uff09');
  }

  /// 组织本地会话 → 交宿主转发（★ 会话在**本页**组织好，见 buildLocalPlayRequest）
  void _openWork(CachedWork w) {
    final req = buildLocalPlayRequest(w);
    if (req == null) {
      // 一张能点却没东西可播的卡片是最难查的表现 —— 如实说出来
      _say('这部的文件还没下完，暂时播不了');
      return;
    }
    widget.onOpen?.call(req);
  }

  /// ★★★ task-12 ③：整剧删除（**真删文件、不可逆** ⇒ 必须二次确认）
  ///
  /// # 确认正文为什么必须写「几集 / 多少 MB」
  /// ```text
  /// Owner 的原话是「在外面也应该可以进行整部剧的删除操作」——
  /// 那是**能力**要求；而这句正文是**安全**要求（lead 明令）：
  /// 整剧删除没有回收站、不能撤销，用户点之前必须看到**代价**。
  /// 数字来自 DownloadQueue.previewRemoveWork()（真读盘，不是估算）。
  /// ```
  Future<void> _confirmDelete(CachedWork w) async {
    // ① 先问队列要一份**真读数**（文件数 / 字节 / 队列里几集）
    final preview = await DownloadQueue.previewRemoveWork(w.dirName);
    if (!mounted) return;

    // ② 若队列里一集都没有（纯扫盘发现的、老下载或手拷进来的），
    //    仍要能删 —— 用扫盘读数当正文（两条数据源取并集，不重复计数）。
    final dirEps = w.episodes.length;
    final dirBytes = w.bytes;
    final eps = preview.episodeCount > 0 ? preview.episodeCount : dirEps;
    final bytes = preview.bytes > 0 ? preview.bytes : dirBytes;

    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除整部？'),
        content: Text(
          '「${w.displayTitle}」\n'
          '将删除 $eps 集 / 共 ${humanBytes(bytes)}。\n'
          '文件会从磁盘上真正删除，此操作不可恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // ③ 真删（force: true 才是真删，否则只是演练）
    final res = await DownloadQueue.removeWork(w.dirName, force: true);
    if (!mounted) return;

    // ④ 真刷新（重新扫盘）—— 不刷新的话卡片会一直挂在屏幕上骗人
    await load();
    if (!mounted) return;

    // ⑤ 可判定反馈：删了几集 / 多少 MB（用**实际**删掉的数，不是预览数）
    final n = res.deletedFiles;
    final b = humanBytes(res.deletedBytes);
    _say(res.deleted ? '已删除 ${w.displayTitle}：$n 个文件 / $b' : '没有删除任何文件');
  }

  /// 一句话反馈（底部 SnackBar —— 与页面自带 Scaffold 配对）
  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Widget _empty(
    ColorScheme colors, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: colors.onSurfaceVariant),
            const SizedBox(height: Sp.x4),
            Text(
              title,
              style: TextStyle(
                fontSize: FontSizes.xl,
                fontWeight: FontWeights.semibold,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.base,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ★ Owner 1009（1）：「已缓存」页的一张卡片
///
/// # 改了什么（Owner 原话）
/// ```text
/// > 这个已缓存,这里孤零零一个删除按钮真不好看,优化优化,样式不好看
/// ```
///
/// 改前：卡片正下方右侧单独挂一枚垃圾桶 ⇒ 整页像「一排删除按钮」。
/// 改后：删除收进**封面右上角**一枚半透明圆形「更多」按钮，默认**隐藏**，
///        鼠标悬停 / 右键 / 触摸长按 / TV 菜单键才显形。
///
/// # 为什么自己写一张卡而不改 PosterCard
/// ```text
/// PosterCard 是 5 个页面共用的底座组件（归 polish agent），而「更多」菜单
/// 只有「已缓存」页需要 ⇒ 改它会把一个无关能力摊到全部 5 页。
/// 而本卡的**形状与 PosterCard 逐字节相同**（同一个组件、同一组参数），
/// 只是外面包了一层浮层。
/// ```
class _CacheWorkCard extends StatefulWidget {
  const _CacheWorkCard({
    required this.work,
    required this.onOpen,
    required this.onDelete,
    required this.onOpenFolder,
  });

  final CachedWork work;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;

  @override
  State<_CacheWorkCard> createState() => _CacheWorkCardState();
}

class _CacheWorkCardState extends State<_CacheWorkCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final sub = StringBuffer(humanBytes(widget.work.bytes));
    sub.write(' · ');
    if (widget.work.partialCount > 0) {
      sub.write('${widget.work.completedCount} 集'
          '（${widget.work.partialCount} 个在下）');
    } else {
      sub.write('${widget.work.completedCount} 集');
    }

    /*
     * ★ 卡片本体就是 PosterCard（与首页海报卡同一组件、同一组参数）
     *   ⇒ 两页的排版（标题两行 + 「大小 · N 集」）天然一致。
     */
    final poster = PosterCard(
      title: widget.work.displayTitle,
      cover: widget.work.cover,
      subtitle: sub.toString(),
      titleLines: 2,
      onTap: widget.onOpen,
    );

    /*
     * ★★★ Owner 第 1009 批：「已缓存的也要显示原来的封面」
     * ```text
     * 症状：已缓存页的卡片是一块灰方块（只剩标题第一个字「无」）。
     * 根因：PosterCard 的 cover 只喂 coverImage(...) ⇒ **只认网络 URL**；
     *       而这部作品盘上明明有 _sourin-cover.jpg（DownloadQueue 写的那份），
     *       它从没被用过 —— 已缓存页等于「有封面也不显示」。
     * ```
     *
     * # 为什么是**叠在上面**而不是把 PosterCard 的 cover 换掉
     * ```text
     * PosterCard 是 5 个页面共用的底座，cover 参数的语义是**网络 URL**
     * （Image.network）。塞一条磁盘路径进去 ⇒ 每个调用点都要跟着分叉。
     * ⇒ 不动底座，只在这张卡的**海报格**上叠一层本地图。
     * ```
     *
     * # 三层的顺序（**谁先坏就退下一层**，不是二选一）
     * ```text
     * ① 本地封面文件（离线在、跨机器在、跨网络在）
     * ② 网络 URL（PosterCard 自己画的，在它下面）
     * ③ 占位块（PosterCard 的底色，永远在最底下）
     * ⇒ 本地图读不出来（文件被删/损坏）时 errorBuilder 缩回 0×0，
     *   ② 立刻透出来 —— 两层都在树里，不需要等谁失败再重建。
     * ```
     */
    final localCover = _blank(widget.work.localCoverPath)
        ? null
        : widget.work.localCoverPath;
    final Widget card = localCover == null
        ? poster
        : Stack(
            children: [
              poster,
              Positioned(
                left: 0,
                top: 0,
                width: _posterBoxWidth(context),
                height: _posterBoxHeight(context),
                // 图片只是装饰，永远不参与命中测试（否则会盖掉海报卡的点击）
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: Radii.rMd,
                    child: _localCoverImage(
                      context,
                      path: localCover,
                    ),
                  ),
                ),
              ),
            ],
          );

    /*
     * ★ 三种输入方式**共用**下面那一个菜单（右键 / 长按 / 点「更多」）
     * ```text
     * 桌面拖鼠标、手机长按、TV 菜单键——三个入口若各写一份实现，
     * 迟早漂移成「右键能弹、长按不能」这类难以定位的不一致。
     * ```
     */
    return MouseRegion(
      cursor: widget.onOpen != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        // 桌面：右键
        onSecondaryTapDown: (d) => unawaited(_openMenu(d.globalPosition)),
        // 触摸 / TV：长按
        onLongPress: () => unawaited(_openMenu(_moreButtonCenter())),
        child: Stack(
          children: <Widget>[
            // ★ card = poster（没本地封面时）或 poster + 盘上封面那层
            card,
            // ── 「更多」：默认透明，悬停显形（危险操作按需浮现）──
            Positioned(
              top: Sp.x2,
              right: Sp.x2,
              child: IgnorePointer(
                ignoring: !_hover,
                child: AnimatedOpacity(
                  // ★ 给这枚按钮一个**稳定 key**（测试按它定位）
                  //   —— 几何位置会随布局变，按坐标定位的测试会断起来无故红。
                  key: ValueKey<String>('cache-card-more:${widget.work.dirName}'),
                  // ★ 用 AnimatedOpacity（FadeTransition，零 Transform）
                  //   —— 与 PosterCard 内部那层悬停辉光同一手法，不引入新结构
                  opacity: _hover ? 1 : 0,
                  duration: MotionPrefs.duration(context, Motion.fast),
                  curve: MotionPrefs.curve(context, Motion.easeOut),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => unawaited(_openMenu(_moreButtonCenter())),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Icon(Icons.more_horiz,
                            size: 18, color: colors.onSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「更多」按钮中心的全局坐标（菜单与长按都以它为锚点）
  Offset _moreButtonCenter() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    // 按钮尺寸 28 + 边距 Sp.x2（与 Stack 里 Positioned 的 top/right 同源）
    return box.localToGlobal(Offset(box.size.width - Sp.x2 - 14, Sp.x2 + 14));
  }

  /// 三个入口共用的那一个菜单
  ///
  /// ★ 用 `PopupMenuItem.onTap` 而不是 `await showMenu()` 的返回值：
  ///   后者只在「点了某一项」时给值，而**按 Esc / 点外面关闭**时给 null，
  ///   无法区分"点了取消"与"点了第一项"—— 那会让键盘用户永远弹不出菜单。
  Future<void> _openMenu(Offset anchor) async {
    if (!mounted) return;
    final mq = MediaQuery.sizeOf(context);
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & mq,
      ),
      items: <PopupMenuEntry<void>>[
        PopupMenuItem<void>(
          onTap: widget.onDelete,
          child: const Text('删除整部'),
        ),
        PopupMenuItem<void>(
          onTap: widget.onOpenFolder,
          child: const Text('打开所在文件夹'),
        ),
      ],
    );
  }
}
