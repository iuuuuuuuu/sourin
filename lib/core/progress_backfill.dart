// ═══════════════════════════════════════════════════════════════════════
//  播放记录「标题回填」—— **判据与回填逻辑的唯一下拉点**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，task-74 ①）
//
// > 追更页面有个未知,点进去明明有信息,也能播放,像这些信息,
// > 要么缓存,要么每次点进去 能访问就更新,不能访问就保留,
// > 或者你自己想一个优化方案
//
// # 现象
//
// 追更 tab 的卡片是灰底 + 中性图标 + 标题「（标题未知）」，
// 而**点进详情页信息齐全、也能播放** ⇒ 数据在源站是有的，只是没落进本地。
//
// # 根因（三层，前两层已由 task-63 修掉显示侧）
//
// ```text
// ① 写入层：`_saveProgress` 曾读 `widget.title`，而合并页一进页就起播
//    （那时标题还不知道）⇒ 写进库的是**空串**
//    ★ 已修：player_page 改读活值 `_title`；Rust `upsert_progress`
//      也加了 `CASE WHEN excluded.title <> ''` 守卫（store.rs:895-928）
// ② 显示层：`_historyTitle` / `progressDisplayTitle` 三层兜底
//    ⇒ 空标题显示「（标题未知）」，**不崩但也没信息**
// ③ ★ 存量数据：库里**已经**躺着 `title=''` 的行 —— 修①②都救不了它们
// ```
//
// # 方案：`progress` 表本身就是持久缓存（**不新建缓存层**）
//
// ```text
// 「能访问就更新」 ⇒ 拿 `provider + native_id` 调 `getDetail`，把标题/封面写回
// 「不能访问就保留」⇒ 失败**静默**、绝不写空值、绝不删行 ⇒ 下次还显示占位
// ```
// ★ 为什么不新建一张缓存表：`progress` 行**本来就是**那条记录的持久化形态，
//   它已经有 `provider` / `native_id` / `position` / `duration`。
//   再建一层只会多一份会漂的状态（本项目已多次踩"两处同构必须一起改"）。
//
// # ★ 为什么这个文件存在（而不是写在 `follow_page.dart` 里）
//
// 本仓 `title_match.dart` 顶部记录的判断（task-73）：
// ```text
// 判据散在两个消费者里 ⇒ 规则变更时改一处、漏一处 ⇒ 两份判据漂移
// ```
// 回填**判据**（哪些行需要回填）现在有明确的单一答案 ⇒ 放这里。
// `follow_page.dart` 与 `my_shelf.dart` 都从这里取，**不得各写一份**。

// ⚠️ 只 import `sourin_api.dart` —— 它已经 re-export 了 `models.dart`
//    （`Progress` / `MediaDetail` 都从这里来）。
//    与本仓 `lib/ui/widgets/my_shelf.dart:61` 的写法一致。
import 'sourin_api.dart';

/// 这条播放记录**需不需要**回填标题（纯函数）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★ 判据 = 「卡片上会显示占位符」
/// ══════════════════════════════════════════════════════════════════════
///
/// 显示层（`_historyTitle` / `progressDisplayTitle`）的三层兜底是：
/// ```text
/// ① p.title        非空 ⇒ 显示它
/// ② p.episodeTitle 非空 ⇒ 显示它
/// ③ 两者都空        ⇒ 「（标题未知）」   ← ★ 只有这种情况用户看到"未知"
/// ```
/// ⇒ 回填**只需要**处理 ③ —— 这与 Owner 报的现象**逐字对应**
///   （他说的就是那个「（标题未知）」卡片）。
///
/// # ★ 为什么 ② 存在时**不**发请求（这是刻意的，不是漏了）
///
/// ```text
/// 用户已经看得到「第01集」这类可辨认的信息 ⇒ 不是"未知"
/// 而每次多打一次网络请求，收益只是把"第01集"换成"某剧名"
/// ⇒ 用一个**用户看不出差别**的请求换一次网络往返，不划算
/// ★ 且回填走的是详情接口（可能几百 KB），在追更页一进页就打
///   会跟首屏那 3 个并发请求抢带宽
/// ```
/// ⚠️ 若将来 Owner 要"连集名也要补上片名"，改这里**一处**即可
///    （改成 `p.title.trim().isEmpty`），调用方不用动。
///
/// # 为什么用 `trim()` 而不是 `isEmpty`
///
/// ```text
/// 实测用户库里坏记录是 `title=''`，但**不能假设**只有空串：
/// 上游源站可能下发 `'   '`（全空白）—— 那在界面上同样是空白，
/// 而 `isEmpty` 会判它"有标题" ⇒ 永远不回填、永远显示空白
/// ```
/// ★ 与显示层的判据**完全一致**（`_historyTitle` 用的也是 `trim().isNotEmpty`）——
///   两处判据一致才不会出现"显示说未知、回填说不用补"。
bool needsTitleBackfill(Progress p) {
  if (p.title.trim().isNotEmpty) return false;
  final et = p.episodeTitle;
  if (et != null && et.trim().isNotEmpty) return false;
  return true;
}

/// 回填用的取详情函数（可注入 —— 测试里换成假实现）
typedef DetailFetcher = Future<MediaDetail> Function(String provider, String id);

/// 回填用的写回函数（可注入）
///
/// ⚠️ 参数故意是**整条记录 + 新值**而不是散开的 8 个参数：
///    回填**只**改标题/封面，位置/时长/集 id 必须**原样保留**
///    （否则回填会把用户的观看进度冲掉 —— 那比"没标题"严重得多）。
///    把原记录整体传进来，实现里逐字段照抄，就不容易漏。
typedef ProgressSaver = Future<void> Function(
  Progress p, {
  required String title,
  String? cover,
});

/// 把回填后的记录**合并**回原列表（纯函数）
///
/// 按 `key` 匹配（`item_key(provider, id)`，见 `rust/sourin_core/src/commands.rs:196`）。
/// 匹配不到的原样保留 —— 回填**不许**增删列表项。
List<Progress> mergeBackfilled(List<Progress> current, List<Progress> patched) {
  if (patched.isEmpty) return current;
  final byKey = <String, Progress>{for (final p in patched) p.key: p};
  return [
    for (final p in current) byKey[p.key] ?? p,
  ];
}

/// 用新标题/封面复制一条记录（其余字段**逐字照抄**）
Progress withBackfilledMeta(Progress p, {required String title, String? cover}) =>
    Progress(
      key: p.key,
      provider: p.provider,
      nativeId: p.nativeId,
      title: title,
      // ⚠️ 新封面为空时**保留旧封面**（COALESCE 语义）——
      //    详情接口偶尔不给封面，直接覆盖会把本来能显示的海报清掉
      cover: (cover != null && cover.isNotEmpty) ? cover : p.cover,
      episodeId: p.episodeId,
      episodeTitle: p.episodeTitle,
      position: p.position,
      duration: p.duration,
      finished: p.finished,
      updatedAt: p.updatedAt,
    );

/// 播放记录标题回填器
///
/// # 用法（`follow_page.dart`）
///
/// ```dart
/// final patched = await _backfill.backfill(_continueList);
/// if (mounted && patched.isNotEmpty) {
///   setState(() => _continueList = mergeBackfilled(_continueList, patched));
/// }
/// ```
///
/// # 三条纪律（都是 Owner 原话里的"要么/要么"翻译过来的）
///
/// ```text
/// 「能访问就更新」   ⇒ 成功 ⇒ 写回 DB（下次 continue_watching 直接带标题）
/// 「不能访问就保留」 ⇒ 失败 ⇒ **静默**、不写、不删 ⇒ 界面仍是占位符
/// 「要么缓存」       ⇒ progress 表本身就是缓存（见文件头）
/// ```
///
/// # ★ 去重（`_tried`）：这是"别把网络打爆"的关键
///
/// 追更页的 `_load` 会在**切 tab / 回前台 / 下拉刷新**时反复调用
/// （`follow_page.dart` 的 `_refreshOnEnter`）。若每次都重试失败的条目：
/// ```text
/// 用户来回切 5 次 tab ⇒ 同一个坏记录被请求 5 次
/// 而它失败的原因（源站挂了/条目下架）**不会**因为重试而改变
/// ⇒ 纯浪费，还可能拖慢首屏
/// ```
/// ⇒ 凡是**尝试过**的 key（无论成败）都记进 `_tried`，本次会话不再碰。
///    ⚠️ 成功的不再重试**也有必要**：成功后 `_continueList` 里那条
///       已经有标题了，但**同一批**的其它条目可能还需要；
///       且下次 `_load` 从 DB 读回来时它已带标题 ⇒ `needsTitleBackfill` 自然为 false。
class ProgressTitleBackfill {
  ProgressTitleBackfill({
    DetailFetcher? fetchDetail,
    ProgressSaver? saveProgress,
    this.maxConcurrent = 4,
  })  : _fetch = fetchDetail ?? _defaultFetch,
        _save = saveProgress ?? _defaultSave;

  final DetailFetcher _fetch;
  final ProgressSaver _save;

  /// 并发上限
  ///
  /// ⚠️ 取值 4 的理由：追更页首屏**自己**已经并发打了 3 个 IPC
  ///    （`follow_page.dart:437` 的 `Future.wait`）。
  ///    回填再全量并发（最多 20 条）会瞬间打出 20+ 个详情请求 ——
  ///    每个都可能几百 KB，直接和首屏抢带宽 ⇒ 首屏更慢。
  ///    4 是"能推进"与"不抢带宽"之间的折中。
  final int maxConcurrent;

  /// 本次会话**尝试过**的 key（成败都记）—— 见类文档
  final Set<String> _tried = <String>{};

  /// 已尝试过的 key（只读，给测试/诊断用）
  Set<String> get triedKeys => Set.unmodifiable(_tried);

  static Future<MediaDetail> _defaultFetch(String provider, String id) =>
      SourinApi.getDetail(provider, id);

  static Future<void> _defaultSave(
    Progress p, {
    required String title,
    String? cover,
  }) =>
      SourinApi.saveProgress(
        p.provider,
        p.nativeId,
        title: title,
        cover: cover,
        /*
         * ⚠️ 这四个必须**原样带回去** —— 见 [ProgressSaver] 的说明。
         *    `save_progress` 是 **upsert**：少传哪个字段就可能把哪一列写坏。
         */
        episodeId: p.episodeId,
        episodeTitle: p.episodeTitle,
        position: p.position,
        duration: p.duration,
        finished: p.finished,
      );

  /// 对 [items] 里需要回填的条目跑一轮（返回**已回填**的那些，可能为空）
  ///
  /// ⚠️ **不抛异常**：任何单条失败都吞掉（`catch (_) {}`），
  ///    因为回填是**尽力而为**的旁路 —— 它失败不该让追更页报错。
  Future<List<Progress>> backfill(List<Progress> items) async {
    final todo = <Progress>[];
    for (final p in items) {
      if (!needsTitleBackfill(p)) continue;
      // ★ 记在**发请求之前** —— 否则并发调用会各自看到"没试过"
      if (_tried.add(p.key)) todo.add(p);
    }
    if (todo.isEmpty) return const [];

    final done = <Progress>[];
    for (var i = 0; i < todo.length; i += maxConcurrent) {
      final end = (i + maxConcurrent).clamp(0, todo.length);
      final chunk = todo.sublist(i, end);
      final got = await Future.wait(chunk.map(_one));
      for (final g in got) {
        if (g != null) done.add(g);
      }
    }
    return done;
  }

  /// 回填**单条**（失败/无标题 ⇒ 返回 null，不抛）
  Future<Progress?> _one(Progress p) async {
    try {
      final d = await _fetch(p.provider, p.nativeId);
      final t = d.title.trim();
      /*
       * ⚠️ 详情拿到了但**标题仍是空** ⇒ 什么都不做。
       *    这正对应 Owner 的「不能访问就保留」：
       *    宁可不写，也不能把一条记录写得更差（或写个空标题）。
       */
      if (t.isEmpty) return null;

      await _save(p, title: d.title, cover: d.cover);
      return withBackfilledMeta(p, title: d.title, cover: d.cover);
    } catch (_) {
      /*
       * ★ 静默：不弹 toast、不写日志噪音、不改列表。
       *   失败**不影响**界面（那条继续显示「（标题未知）」），
       *   也**不会**被重试（`_tried` 已记）。
       */
      return null;
    }
  }
}
