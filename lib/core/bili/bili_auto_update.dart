
// ═══════════════════════════════════════════════════════════════════════
//  哔哩哔哩弹幕自动更新（增量拉取 + 缓存）—— task-28
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决什么
//
// 用户原话里最后半句：「自动更新弹幕」。
//
// 弹幕是**会长**的：视频发出来时 100 条，一周后 500 条。用户每次进
// 播放页都全量重拉一遍，既慢又费流量（实测一个 1200 条的样本解压后
// 122675 B）。所以这里做两层：
//
//   1. **内存缓存**：同一个 cid 在一次会话里只拉一次。
//   2. **增量合并**：拿到新的 XML 后，按 cid（dmid）与旧的合并去重，
//      只把**新增**的那些算作变化。
//
// # 为什么不做「只请求新增的那一段」
//
// B 站这个 /x/v1/dm/list.so 端点**没有**时间区间参数（只有 oid），
// 也就是说服务端每次都吐全量。所谓「增量」只能发生在**客户端**：
// 全量拿到 → 与本地已有的按 dmid 求差集 → 只把差集交给排版器重排。
//
// 这一点必须写清楚，否则后来人会以为我们漏做了服务端增量。
//
// # 缓存放在哪
//
// 内存（本文件顶部的 _cache）。**不落盘** —— 理由：
//   · 弹幕量大（1200 条 = 122675 B 原始 XML，序列化后更大），
//     落盘要自己管淘汰，得不偿失；
//   · 落盘就得处理「视频被删了 / cid 变了」的陈旧数据问题；
//   · 真正的持久化是**绑定关系**（bili_bind.dart），那才是下次能
//     「自动到位」的关键。弹幕本身每次重拉一遍是 1 个请求的事。
//
// # 自动更新的触发时机（由 UI 决定，这里只提供能力）
//
//   · 进入某一集时：先给缓存（瞬间有画面），后台再拉一次比对
//   · 距离上次同步超过 defaultIntervalMinutes 时：强制重拉
//   · 用户点「立即更新」：强制重拉

import 'dart:async';

import '../danmaku.dart';
import '../ui_prefs.dart';
import 'bili_api.dart';
import 'bili_bind.dart';

/// 默认自动更新间隔（分钟）。30 分钟是「一集看完再回来」的量级。
const int defaultIntervalMinutes = 30;

/// 一次更新的结果。
class BiliUpdateResult {
  const BiliUpdateResult({
    required this.cid,
    required this.total,
    required this.added,
    required this.removed,
    required this.fromCache,
    required this.changed,
    this.comments = const <DanmakuComment>[],
    this.error = '',
  });

  final int cid;

  /// 合并后的总条数。
  final int total;

  /// 这次新增了几条。
  final int added;

  /// 这次少了几条（视频弹幕被删/被清理）。
  final int removed;

  /// 是不是直接用缓存、根本没发请求。
  final bool fromCache;

  /// 内容是否真的变了（added > 0 || removed > 0）。
  final bool changed;

  /// 合并后的完整弹幕（已按时间排序）。
  final List<DanmakuComment> comments;

  /// 出错时的消息；空串 = 成功。
  final String error;

  bool get ok => error.isEmpty;

  String get summary {
    if (!ok) return '更新失败：$error';
    if (fromCache) return '缓存命中（$total 条）';
    if (!changed) return '没有新弹幕（$total 条）';
    return '新增 $added 条'
        '${removed > 0 ? '，减少 $removed 条' : ''}'
        '，共 $total 条';
  }

  @override
  String toString() => 'BiliUpdateResult(cid=$cid, $summary)';
}

/// 一个 cid 的缓存条目。
class _CacheEntry {
  _CacheEntry(this.comments, this.fetchedAt);

  List<DanmakuComment> comments;
  DateTime fetchedAt;
  final Map<int, DanmakuComment> byId = <int, DanmakuComment>{};
}

/// 弹幕缓存 + 增量合并。**全局单例**，因为弹幕是进程级共享的。
///
/// 单测里用 debugResetForTest 清空。
class BiliDanmakuStore {
  BiliDanmakuStore._();

  static final Map<int, _CacheEntry> _cache = <int, _CacheEntry>{};

  /// 最多缓存多少个 cid（FIFO 淘汰）。
  static const int maxEntries = 12;

  /// 测试专用：清空内存缓存。
  static void debugResetForTest() => _cache.clear();

  /// 缓存里有没有这个 cid。
  static bool has(int cid) => _cache.containsKey(cid);

  /// 取缓存（没有返回 null）。
  static List<DanmakuComment>? peek(int cid) {
    final e = _cache[cid];
    if (e == null) return null;
    return List<DanmakuComment>.unmodifiable(e.comments);
  }

  /// 缓存时间。
  static DateTime? fetchedAt(int cid) => _cache[cid]?.fetchedAt;

  /// 丢弃某个 cid 的缓存。
  static void evict(int cid) => _cache.remove(cid);

  /// 这个 cid 的缓存是不是已经过期。
  static bool isStale(int cid, {int intervalMinutes = defaultIntervalMinutes}) {
    final e = _cache[cid];
    if (e == null) return true;
    return DateTime.now().difference(e.fetchedAt).inMinutes >= intervalMinutes;
  }

  /// 把一批弹幕塞进缓存（直接替换）。
  static void put(int cid, List<DanmakuComment> comments) {
    final e = _CacheEntry(List<DanmakuComment>.of(comments), DateTime.now());
    for (final c in comments) {
      e.byId[c.cid] = c;
    }
    _cache[cid] = e;
    _evictIfNeeded();
  }

  /// 已有的 id 集合（增量比对用）。
  static Set<int> idsOf(int cid) =>
      _cache[cid]?.byId.keys.toSet() ?? <int>{};

  static void _evictIfNeeded() {
    while (_cache.length > maxEntries) {
      int? oldestCid;
      DateTime? oldest;
      _cache.forEach((cid, e) {
        final o = oldest;
        if (o == null || e.fetchedAt.isBefore(o)) {
          oldest = e.fetchedAt;
          oldestCid = cid;
        }
      });
      final victim = oldestCid;
      if (victim == null) break;
      _cache.remove(victim);
    }
  }
}

/// 拉一次并做增量合并。
///
/// [force] = true 时无视缓存时效，一定发请求。
///
/// 出错**不抛**：返回带 error 的结果，并把缓存里已有的内容原样带回来 ——
/// 播放页拿到「上次的弹幕 + 一条错误提示」比拿到空白好。
Future<BiliUpdateResult> updateDanmaku({
  required BiliApi api,
  required int cid,
  bool force = false,
  int intervalMinutes = defaultIntervalMinutes,
}) async {
  final cached = BiliDanmakuStore._cache[cid];

  if (!force &&
      cached != null &&
      !BiliDanmakuStore.isStale(cid, intervalMinutes: intervalMinutes)) {
    return BiliUpdateResult(
      cid: cid,
      total: cached.comments.length,
      added: 0,
      removed: 0,
      fromCache: true,
      changed: false,
      comments: List<DanmakuComment>.unmodifiable(cached.comments),
    );
  }

  List<DanmakuComment> fresh;
  try {
    fresh = await api.danmaku(cid);
  } catch (e) {
    final old = cached;
    return BiliUpdateResult(
      cid: cid,
      total: old == null ? 0 : old.comments.length,
      added: 0,
      removed: 0,
      fromCache: old != null,
      changed: false,
      comments: old == null
          ? const <DanmakuComment>[]
          : List<DanmakuComment>.unmodifiable(old.comments),
      error: e.toString(),
    );
  }

  if (cached == null) {
    BiliDanmakuStore.put(cid, fresh);
    return BiliUpdateResult(
      cid: cid,
      total: fresh.length,
      added: fresh.length,
      removed: 0,
      fromCache: false,
      changed: true,
      comments: List<DanmakuComment>.unmodifiable(fresh),
    );
  }

  // 增量：按 dmid 求差集。服务端每次吐全量，所以「增量」是客户端算的。
  final oldIds = cached.byId.keys.toSet();
  final newIds = <int>{};
  for (final c in fresh) {
    newIds.add(c.cid);
  }

  var added = 0;
  for (final id in newIds) {
    if (!oldIds.contains(id)) added++;
  }
  var removed = 0;
  for (final id in oldIds) {
    if (!newIds.contains(id)) removed++;
  }

  BiliDanmakuStore.put(cid, fresh);

  return BiliUpdateResult(
    cid: cid,
    total: fresh.length,
    added: added,
    removed: removed,
    fromCache: false,
    changed: added > 0 || removed > 0,
    comments: List<DanmakuComment>.unmodifiable(fresh),
  );
}

/// 给定「作品 + 第几集」，一步到位把弹幕取来（带缓存与增量）。
///
/// 这是播放页最省事的入口：它自己会去读绑定（bili_bind.dart），
/// 没有绑定就返回一个「没绑」的结果，不会发任何请求。
Future<BiliUpdateResult> updateForEpisode({
  required BiliApi api,
  required String provider,
  required String id,
  required int episodeIndex,
  bool force = false,
  int intervalMinutes = defaultIntervalMinutes,
}) async {
  final cid =
      resolveCid(provider: provider, id: id, episodeIndex: episodeIndex);
  if (cid <= 0) {
    return const BiliUpdateResult(
      cid: 0,
      total: 0,
      added: 0,
      removed: 0,
      fromCache: false,
      changed: false,
      error: '这一集还没有绑定 B 站弹幕',
    );
  }
  return updateDanmaku(
    api: api,
    cid: cid,
    force: force,
    intervalMinutes: intervalMinutes,
  );
}

// ══════════════════════════════════════════════════════════════════════
//  全局开关（落在 ui_prefs，跨会话记住）
// ══════════════════════════════════════════════════════════════════════

/// 自动更新是否开着。默认**开**（用户要的就是「自动更新」）。
bool biliAutoUpdateEnabled() {
  final v = UiPrefs.get(BiliPrefs.autoUpdateKey);
  if (v == null || v.isEmpty) return true;
  return v != '0';
}

/// 设置自动更新开关。
void setBiliAutoUpdateEnabled(bool on) {
  UiPrefs.set(BiliPrefs.autoUpdateKey, on ? '1' : '0');
}

/// 自动更新间隔（分钟）。非法值回落到 defaultIntervalMinutes。
int biliAutoUpdateInterval() {
  final v = UiPrefs.get(BiliPrefs.intervalKey);
  final n = v == null ? 0 : int.tryParse(v) ?? 0;
  if (n < 5 || n > 24 * 60) return defaultIntervalMinutes;
  return n;
}

/// 设置间隔（会被夹到 5 ~ 1440 分钟）。
void setBiliAutoUpdateInterval(int minutes) {
  final n = minutes < 5 ? 5 : (minutes > 24 * 60 ? 24 * 60 : minutes);
  UiPrefs.set(BiliPrefs.intervalKey, '$n');
}

/// 上次全量刷新时间（毫秒时间戳；0 = 从没刷过）。
int biliLastSyncAt() {
  final v = UiPrefs.get(BiliPrefs.lastSyncKey);
  return v == null ? 0 : int.tryParse(v) ?? 0;
}

/// 记一次全量刷新。
void markBiliSynced() {
  UiPrefs.set(
    BiliPrefs.lastSyncKey,
    '${DateTime.now().millisecondsSinceEpoch}',
  );
}

/// 距离上次同步过了多久（分钟）；从没同步过返回一个很大的数。
int minutesSinceLastSync() {
  final t = biliLastSyncAt();
  if (t <= 0) return 1 << 30;
  return DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(t))
      .inMinutes;
}

/// 该不该现在自动更新（开关开着 + 缓存过期）。
bool shouldAutoUpdate({int? cid}) {
  if (!biliAutoUpdateEnabled()) return false;
  if (cid == null || cid <= 0) return true;
  return BiliDanmakuStore.isStale(cid, intervalMinutes: biliAutoUpdateInterval());
}
