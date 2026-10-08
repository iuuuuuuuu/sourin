// ═══════════════════════════════════════════════════════════════════════
//  「我的」三合一版块 —— 对齐原版 MyShelf.vue（655 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 最近追更 / 最近收藏 / 播放历史。
//
// # 为什么合成一个版块（原版注释）
//
// > 这三者都是「用户自己的数据」（独立平面），且**高度重叠** ——
// > 同一部番可能同时出现在收藏和历史里。分成三个横排区块会让首页
// > 变成一长条重复内容，故用 **tabs 切换**：一次只展示一类，
// > 密度高、扫视快。
//
// # ★★★ 三个必须保持的修复（都是真 bug）
//
// ## ① 收藏与追更要**分别查**（2026-09-21）
//
// 原版注释：
// > 原先只调一次 `list(false)`，然后从同一个数组里用 `filter` 切出两个 tab。
// > 但 `list(false)` 在后端是 `list_favorites(false)`，其 SQL 是
// > `WHERE favorited=1` —— 它**只返回收藏过的行**。于是 `following`
// > 那份永远拿不到「**只追更不收藏**」的条目：
// > ```text
// > 用户在详情页只点了「追更」、没点「收藏」
// >   → DB: favorited=0, following=1, deleted=0
// >   → 后端 list_favorites 查不到它
// >   → ★ 首页「最近追更」里看不到它
// > ```
//
// ## ② 两个 tab 的判据字段必须分开
//
// ```text
// 收藏看 favorited
// 追更看 following
// ```
// **绝不能再用 `deleted`** —— 它的语义是"两个状态都没了"
//（`deleted=1 ⇔ !favorited && !following`）。
//
// ## ③ 刷新时**不要**把 loading 置回 true（原版实测踩到的滚动 bug）
//
// 原版注释：
// > 本区块被 keep-alive 保活，每次回首页都会重取一次。
// > 若置 true，内容会瞬间塌缩成骨架 → 容器高度骤降 →
// > 浏览器把 `.app-main` 的 scrollTop 钳到新的最大值（实测被钳到 261），
// > 于是「滚动位置记忆」永远恢复不到用户离开时的位置。
// >
// > 正确做法：只在**首次**加载显示骨架，之后的刷新静默替换数据。
//
// # ★ 「清空历史」的二次确认（功能闭环补完，2026-09-19）
//
// 原版注释：
// > 审计发现：后端有 `clear_history` 命令、前端 API 也包好了，
// > 但**全项目 0 个调用点** —— 「删除历史」功能**实际不存在**。
// > 播放历史的隐私属性比收藏/追更强，没有清空入口是个真实缺口。

import 'dart:async';
import 'dart:math' as math;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'poster_card.dart';
import 'press_feedback.dart';

/// tab 类型
enum ShelfTab { following, favorites, history }

/// 「我的」版块
class MyShelf extends StatefulWidget {
  const MyShelf({
    super.key,
    this.onPlay,
    this.onOpenDetail,
    this.isTv = false,
    this.onSeeAll,
  });

  /// 点卡片 → 进播放器（续播）
  final void Function(
    String provider,
    String id,
    String title,
    String? cover,
    String? episodeId,
  )? onPlay;

  final void Function(String provider, String id)? onOpenDetail;

  final bool isTv;

  /// ★★ task-65：「查看更多」被点击 —— 参数是**追更页的 tab key**
  ///
  /// # 为什么参数是 key 而不是"第几个 tab"（Owner 原话）
  ///
  /// > 首页的 追更，历史，收藏 应该有一个**查看更多**按钮……
  /// > 点一下就跳转到 追更页面，**激活对应的 tab**
  ///
  /// 传的字符串与 `follow_page.dart` 的 `_FollowTab.key` **同一套**：
  /// ```text
  /// 'following'  追更
  /// 'all'        收藏
  /// 'continue'   历史
  /// ```
  /// ★ 不传 `ShelfTab` 枚举：那会让 `my_shelf.dart` 与 `follow_page.dart`
  ///   互相 import（`follow_page` 已 import `my_shelf` 的兄弟组件 ⇒ 会成环）。
  ///   字符串 key 是两边**已经共用**的契约（`_FollowTab.key` 有说明）。
  ///
  /// ★ 为什么是**一个**入口而不是"三块各一个"：
  ///   本组件是 **tabs 切换**的（同一时刻只显示一个 tab，见文件头），
  ///   屏幕上只有一块内容 ⇒ 放**标题行右侧**，跟随当前 tab。
  ///   （"三个独立版块各一个"要拆掉 tabs，属于结构改版，未做。）
  final void Function(String tabKey)? onSeeAll;

  @override
  State<MyShelf> createState() => MyShelfState();
}

/// `ShelfTab` → 追更页的 tab key（**唯一映射处**）
///
/// ★ 与 `follow_page.dart::_FollowTab.key` 必须一致。提成函数是为了
///   让"映射"只有一处 —— 本仓反复踩过"两处同构必然漂"。
String shelfTabToFollowKey(ShelfTab t) => switch (t) {
      ShelfTab.following => 'following',
      ShelfTab.favorites => 'all',
      ShelfTab.history => 'continue',
    };

class MyShelfState extends State<MyShelf> {
  ShelfTab _tab = ShelfTab.following;
  bool _loading = true;

  /// 是否已完成首次加载
  ///
  /// ★ 之后的刷新**不再显示骨架**（见文件头 ③ 的说明）。
  bool _loadedOnce = false;

  List<Favorite> _following = [];
  List<Favorite> _favorites = [];
  List<Progress> _history = [];

  /// 「清空历史」的二次确认态
  ///
  /// ```text
  /// 第一次点 → 变成「再点一次确认清空」
  /// 第二次点 → 真的清空
  /// ```
  /// ⚠️ 3 秒内没点第二次就自动复位 ——
  ///    否则用户点一下走开、回来再点就无意中清空了。
  bool _clearingConfirm = false;
  bool _clearResetScheduled = false;

  /// 本区块是否曾经**被别的路由盖住**过
  ///
  /// # 为什么需要它（task-36：用户要求「切换页面应该要自动刷新」）
  ///
  /// 原版 `MyShelf.vue:255` 靠 **Vue Router 的路由监听**刷新：
  /// ```js
  /// watch(() => route.path, (p) => { if (p === "/") void load(); })
  /// ```
  /// Flutter 侧没有等价钩子：首页在 `IndexedStack` 里常驻，
  /// 从详情页/播放页返回时**不会**重建、也不会触发 `initState`。
  ///
  /// 这里用 `ModalRoute.isCurrentOf(context)` 补上（与 `follow_page.dart`
  /// 同一套办法，两处必须一致 —— 否则又会出现"一个页面对一个页面不对"）：
  /// ```text
  /// 本页是当前路由 → false     被详情页/播放页盖住 → true
  /// ```
  /// 一旦被盖住过就记下来；等它**重新变成当前路由**时刷一次。
  ///
  /// ★ 实测（`.probe/probe_tests/zz_t36_pages_test.dart` PROBE-3b）：
  ///   修之前 push 详情页 → pop 回来，`load()` 调用次数 **delta=0**。
  bool _wasCovered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  /// ★ 从详情页 / 播放页返回时刷新
  ///
  /// 依赖 `_ModalScopeStatus` 这个 `InheritedModel`：路由的 `isCurrent`
  /// 变化时 `didChangeDependencies` 会被调用。
  ///
  /// ⚠️ 这个方法在**每一帧的依赖变化**时都可能被调用，所以里面必须
  ///    **只做标记判断** —— 条件不满足时绝不能发请求，否则会变成
  ///    "每次依赖变化打三个 IPC"。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!isCurrent) {
      _wasCovered = true;
      return;
    }
    if (_wasCovered) {
      _wasCovered = false;
      /*
       * ★ 静默刷新：`load()` 内部在 `_loadedOnce` 之后不再置 `_loading`
       *   ⇒ 不会闪骨架（见文件头 ③ —— 那是一条修过的真 bug）。
       *
       * ★★★ 这里**故意不加 `_loadedOnce` 条件**（2026-09-25 实测修正）
       *
       * # 为什么（真实 ShellPage 探针抓出来的）
       *
       * 我第一版写的是 `if (mounted && _loadedOnce) unawaited(load());`。
       * 单独挂载 MyShelf 的探针**测不出问题**（那条路径会先
       * `debugSetData`，它把 `_loadedOnce` 置成了 true）。
       * 但在**真实 ShellPage** 里（`.probe/probe_tests/
       * zz_t36_realshell_return_test.dart`）：
       * ```text
       * POS before=2 after=3 delta=1            ← 阳性对照通过（仪器灵敏）
       * while_covered=3
       * after_pop=3 delta_on_return=0           ← ★ 返回刷新没发生
       * VERDICT pos_control_ok=true real_shell_refreshes_on_return=false
       * ```
       * 根因：`_loadedOnce` 只在**至少一路成功**时才置位
       * （见下面 `load()` 里那条"失败保留旧数据"的修法）。
       * ⇒ **首次加载失败时 `_loadedOnce` 永远是 false**
       *   ⇒ 从详情页返回**永远不会重试**，界面一直空着，
       *     直到用户去点 tab 才有救。
       *
       * # 那"防重复请求"靠什么？
       *
       * 靠 `_wasCovered` 本身 —— 它才是真正的闸门：
       * ```text
       * 挂载时         _wasCovered=false ⇒ 不请求（initState 的 postFrame 负责首次）
       * 被盖住         _wasCovered=true  ⇒ 不请求
       * 重新变当前      true → false      ⇒ ★ 恰好请求一次
       * ```
       * `didChangeDependencies` 会因为**任意依赖变化**被反复调用，
       * 但只有"被盖住过"这**一次**转换会走到请求 —— 所以不会变成
       * "每次依赖变化打三个 IPC"。
       */
      if (mounted) unawaited(load());
    }
  }

  /// 注入三份数据（**只给测试用**），跳过 FFI 取数
  ///
  /// # 为什么需要这个缝隙
  ///
  /// `load()` 走 `SourinApi` → FFI `sourin_core.dll`，在 `flutter test` 里
  /// 必然加载失败（`error code: 126`），于是**三份数据永远是空的** →
  /// 卡片一个都不渲染 → 就**没法验证"点卡片进详情页"**这件事本身。
  ///
  /// 而「点卡片走详情页还是播放页」正是用户报的缺陷（任务㉑ ②），
  /// 必须有能真的渲染 + 真的点击的测试盯着，否则下次又会改回去。
  ///
  /// ⚠️ 用 `@visibleForTesting` 标注：生产代码调用它会得到 lint 警告。
  ///    它**不改变任何生产行为**，只是把 `_following/_favorites/_history`
  ///    三个私有字段填上 —— 与 `load()` 成功后的状态完全一致。
  @visibleForTesting
  void debugSetData({
    List<Favorite>? following,
    List<Favorite>? favorites,
    List<Progress>? history,
    ShelfTab? tab,
    /*
     * ★ task-40 追加：允许测试直接注入"每部还剩几集"
     *
     * # 为什么必须加这个口子
     *
     * `_remainingByKey` 由 `_refreshRemaining()` 从
     * `SourinApi.listAllProgress()` 算出来 —— 而那条路要 FFI，
     * 在 `flutter test` 里**必然失败**（error code: 126）。
     * ⇒ 不注入的话，测试里 `_remainingOf(f)` **永远是 0**
     *   ⇒ 徽标永远不画 ⇒ "徽标显示还剩几集"这件事**根本没法验证**。
     *
     * ★ 我实测踩到：`zz_t40b_label_test.dart` 抓的 PNG 里
     *   **看不到徽标**，因为 `debugSetData` 当时没这个参数。
     *
     * ⚠️ 传 null = 不动（与上面三个数据字段同一约定）。
     *    传一个 map = 直接用它当算好的结果。
     */
    Map<String, int>? remaining,
  }) {
    setState(() {
      if (following != null) _following = following;
      if (favorites != null) _favorites = favorites;
      if (history != null) _history = history;
      if (tab != null) _tab = tab;
      if (remaining != null) _remainingByKey = remaining;
      _loading = false;
      _loadedOnce = true;
    });
  }

  /// 切换 tab —— **先切、再静默重拉**
  ///
  /// # 用户要求（task-36）
  ///
  /// > 还有，每个页面不应该每次点进去都是完全新的状态，页面应该有缓存
  /// > 但是像首页的。追更收藏历史  还有。追更页面的这三个，
  /// > **切换页面应该要自动刷新的**
  ///
  /// # ★ 这是**超出原版**的增强，不是照抄
  ///
  /// 原版 `MyShelf.vue:301` 是 `@click="tab = t.key"` —— **只切 tab，
  /// 不重新 load**。理由是它的 `load()` 一次拉三份（`Future.wait`），
  /// 三份数据已经在内存里了，切 tab 只是换渲染哪一份。
  ///
  /// 但数据**会过期**：在详情页点了收藏、在播放页看完一集（进度变了）、
  /// 在别处取消了追更 —— 这些都不会反映到已加载的三份数组里。
  /// 用户要的正是「切过去就能看到最新的」。
  ///
  /// # 三个必须守住的约束
  ///
  /// ```text
  /// ① 必须重拉        —— 否则"自动刷新"是假的
  /// ② 不能闪骨架      —— load() 在 _loadedOnce 之后不置 _loading
  ///                      （文件头 ③ 记着这是一条修过的滚动 bug）
  /// ③ 不能卡住交互    —— 用 unawaited 而非 await：
  ///                      load() 是 3 个并发 FFI 调用，await 会让
  ///                      "点下去到 tab 变色"之间插进一次网络往返
  /// ```
  ///
  /// ★ 顺序是 **先 setState 再 load**：tab 的视觉反馈必须立刻发生，
  ///   数据后到。反过来会让点击看起来"没反应"。
  ///
  /// # ★★ 「点**当前** tab 也刷新」是**设计决定**，不是用户明确要求
  ///
  /// 用户原话只说「切换页面应该要自动刷新的」—— **没有**说点当前 tab
  /// 要不要刷新。这里做成也刷新，理由是"想看看有没有新的"是最自然的
  /// 解读之一，且代价小（3 个并发 FFI 调用，`_loadedOnce` 防骨架闪烁）。
  ///
  /// Lead 2026-09-25 裁决：**保留**。
  ///
  /// ⚠️ 若将来要撤（比如用户嫌流量）：把下面那行 `unawaited(load());`
  ///    移进 `if (t != _tab)` 的花括号里即可。
  ///    ★ `follow_page.dart` 的 `_selectTab` 是**同一套写法** ——
  ///      两处必须一起改（本项目已踩过"一个页面对、一个页面不对"的坑，
  ///      见 `test/shelf_card_opens_detail_test.dart` 文件头）。
  void _selectTab(ShelfTab t) {
    /*
     * ★ 记一行日志 —— 这是「切 tab 到底有没有触发刷新」的**唯一**运行期证据
     *
     * # 为什么必须有（2026-09-25 task-36）
     *
     * 成功的 `load()` **什么都不打印**（只有失败路径有 `[SHELF] ...失败`）。
     * 于是"切 tab 刷新了没有"在真机日志里**完全看不出来** ——
     * 而本任务的核心交付就是这个行为。
     *
     * 与项目里其它探针同一个思路（`[HOME] loadAll 开始` / `[NAV] a -> b`）：
     * 把不可见的行为变成**可观测**的。
     */
    debugPrint('[SHELF] 切 tab: ${_tab.name} -> ${t.name}（随后静默重拉）');
    if (t != _tab) setState(() => _tab = t);
    /*
     * ★ 即使点的是**当前** tab 也刷新 —— 那正是用户"想看看有没有新的"
     *   时最自然的动作（下拉刷新之外的第二条路径）。
     *   ⚠️ 这是**设计决定**（用户未明确要求），Lead 裁决保留；
     *      要撤就把这一行挪进上面的 if 里（见方法头注释）。
     */
    unawaited(load());
  }

  /// 拉取三份数据
  Future<void> load() async {
    // ⚠️ 刷新时**不要**把 _loading 置回 true（见文件头 ③）
    if (!_loadedOnce && mounted) setState(() => _loading = true);

    try {
      /*
       * ★★★ 收藏与追更要**分别查**（见文件头 ①）
       *
       * ```text
       * listFavorites(followingOnly: false)  收藏（WHERE favorited=1）
       * listFavorites(followingOnly: true)   追更（WHERE deleted=0 AND following=1）
       * continueWatching(12)                 历史
       * ```
       * 原版用 `Promise.all` 并发 —— 这里同样。
       *
       * ⚠️ 每个都单独 catch —— 一个失败不该让另外两个也空掉。
       */
      /*
       * ★★★ 每个查询各自记下"**到底成没成功**"（task-36 补）
       *
       * # 为什么必须区分（这是一个真实的数据丢失 bug）
       *
       * 原来三个 `.catchError` 都返回**空列表** —— 于是"查失败"与
       * "确实是空的"在下游**完全同形**，都会被写进 `_favorites` 等字段。
       *
       * 在只有"首次加载一次"的时候这不明显（失败就是空的，没得比）。
       * 但 task-36 让**切 tab / 从详情页返回都重拉**之后，它就变成一个
       * 真 bug：
       * ```text
       * 用户有 20 条收藏 → 切个 tab 触发重拉 → 核心正忙/瞬时失败
       *   → catchError 返回 [] → setState 把 20 条**覆盖成空**
       *   → ★ 界面显示"还没有收藏"，而用户的数据明明还在
       * ```
       * ★ 实测复现：`.probe/probe_tests/zz_t36_repro_test.dart`
       *   `B_texts_after_tap` 从「收藏片」变成「还没有收藏 —— 在详情页
       *   点「收藏」保存想看的内容」（那是 `_emptyText`，不是真实状态）。
       *
       * # 修法：失败的那一路**保留旧值**
       *
       * 每个 catchError 返回 `null` 作为"失败"标记，下面按 `null` 判断
       * 是否覆盖。这样：
       * ```text
       * 成功 → 用新数据（哪怕真的是空的 —— 那是真实的空）
       * 失败 → 保留旧数据（宁可显示稍旧的，也不清空）
       * ```
       * ⚠️ 注意 `null` 与"空列表"必须能区分 —— 这正是原代码丢掉的信息。
       */
      /*
       * ⚠️ `Future.wait` 要求**同一个元素类型**，而三份数据的类型不同
       *    （`List<Favorite>` / `List<Favorite>` / `List<Progress>`）。
       *    所以统一用 `Object?` 装箱，下面各自 `as` 回来。
       *    `null` = 那一路失败（见上面"保留旧数据"的说明）。
       */
      final results = await Future.wait<Object?>([
        SourinApi.listFavorites(followingOnly: false)
            .then<Object?>((v) => v)
            .catchError((e) {
          debugPrint('[SHELF] 取收藏失败（保留旧数据）: $e');
          return null;
        }),
        SourinApi.listFavorites(followingOnly: true)
            .then<Object?>((v) => v)
            .catchError((e) {
          debugPrint('[SHELF] 取追更失败（保留旧数据）: $e');
          return null;
        }),
        SourinApi.continueWatching(limit: 12)
            .then<Object?>((v) => v)
            .catchError((e) {
          debugPrint('[SHELF] 取历史失败（保留旧数据）: $e');
          return null;
        }),
      ]);

      if (!mounted) return;
      setState(() {
        // ★ 只有成功的那几路才覆盖（null = 失败 = 保留旧值）
        final fav = results[0] as List<Favorite>?;
        final fol = results[1] as List<Favorite>?;
        final his = results[2] as List<Progress>?;
        if (fav != null) _favorites = fav;
        if (fol != null) _following = fol;
        if (his != null) _history = his;
        /*
         * ⚠️ 后端已各自过滤好了，这里**不需要再 filter** ——
         *    多加一层 `!deleted` 只会掩盖问题
         *    （它在两个查询里都恒为真）。
         */
        /*
         * ★ `_loadedOnce` 只在**至少有一路成功**时置位 ——
         *   全失败还置位的话，骨架会消失但内容是空的，
         *   用户看到"加载完了，什么都没有"，比一直转圈更误导。
         */
        if (fav != null || fol != null || his != null) _loadedOnce = true;
      });

      /*
       * ★★ 算「每部追更还剩几集」（task-40）—— 必须在上面 setState
       *    **之后**：`_refreshRemaining` 读的是 `_following`，
       *    而 `_following` 刚在上一行才被写入。
       *    ★ 单独一个 await（不塞进 Future.wait）—— 见方法头
       *      "仪器兼容性"那段：那三个查询的**数量**是 task-36
       *      仪器的除数，不能动。
       */
      await _refreshRemaining();
    } catch (e) {
      debugPrint('[SHELF] 加载失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 每部追更剧「还剩几集没看」（task-40）—— 与底部徽标/追更页**同一算法**
  ///
  /// # 用户原话
  ///
  /// > 首页的追更  底部的追更 追更页面的追更   这几个都应该按照这个追更
  /// > 这个剧还有多少集没看来显示这个徽标，比如 12集，只看了一集 就显示11
  ///
  /// # ⚠️ 为什么单独一个方法，而不是塞进 `load()`
  ///
  /// **仪器兼容性**（这不是洁癖，是硬约束）：
  /// ```text
  /// task-36 的测试（test/t36_cache_refresh_test.dart）用
  ///   「'[SHELF]' 行数 ÷ 3 = load() 调用次数」
  /// 当仪器。若把第 4 个查询塞进 load()，那个除数就不对了
  /// ⇒ 已通过 8/8 红度证明的仪器会**失准**。
  /// ⇒ 所以这里单独一个方法，且日志 tag 用 `[SHELF-REM]`
  ///   （该字符串**不含** '[SHELF]' 子串，不会污染那个仪器）。
  /// ```
  ///
  /// ⚠️ 必须在 `_following` 已经填充之后调用（否则算出来全是 0）。
  ///
  /// ⚠️ 用 `listAllProgress()` 而**不是** `continueWatching()`：
  ///    后者带 `WHERE finished=0 AND position > 5`（store.rs:909），
  ///    会把"已看完"的行滤掉 ⇒ 看完最后一集徽标**不消失**。
  Map<String, int> _remainingByKey = const {};

  /// 某部剧还剩几集（拿不到 ⇒ 0 ⇒ `PosterCard` 不显示徽标）
  int _remainingOf(Favorite f) => _remainingByKey[f.key] ?? 0;

  /// 拉全部进度 → 算每部追更的"还剩几集"
  Future<void> _refreshRemaining() async {
    try {
      final all = await SourinApi.listAllProgress();
      if (!mounted) return;
      final byKey = followRemainingByKey(
        following: _following,
        allProgress: all,
      );
      setState(() => _remainingByKey = byKey);
    } catch (e) {
      // ★ 失败保留旧值（与"失败不许清空"同一原则）
      debugPrint('[SHELF-REM] 取进度失败（保留旧值）: $e');
    }
  }

  /// 清空播放历史（二次确认）
  ///
  /// # 为什么加这个（功能闭环补完）
  ///
  /// 原版注释：
  /// > 审计发现：后端有 `clear_history` 命令、前端 API 也包好了，
  /// > 但**全项目 0 个调用点** —— 「删除历史」功能**实际不存在**。
  /// > 播放历史的隐私属性比收藏/追更强（它反映用户看过什么），
  /// > 没有清空入口是个真实缺口。
  Future<void> _clearHistory() async {
    if (!_clearingConfirm) {
      // 第一次点 → 进入确认态，3 秒后自动复位
      setState(() => _clearingConfirm = true);
      if (!_clearResetScheduled) {
        _clearResetScheduled = true;
        Future.delayed(const Duration(seconds: 3), () {
          _clearResetScheduled = false;
          if (mounted && _clearingConfirm) {
            setState(() => _clearingConfirm = false);
          }
        });
      }
      return;
    }

    // 第二次点 → 真的清空
    setState(() => _clearingConfirm = false);

    try {
      await SourinApi.clearHistory();
      if (mounted) setState(() => _history = []);
      /*
       * ⚠️ 清完要**重新拉一次**而不是只清本地数组 ——
       *    后端可能保留了部分记录（比如其它设备同步过来的），
       *    只清本地会让界面与实际不一致。
       */
      await load();
    } catch (e) {
      debugPrint('[SHELF] 清空历史失败: $e');
      /*
       * 失败也要刷新 —— 让界面反映真实状态，
       * 而不是留一个"看起来清空了但实际没有"的假象。
       */
      await load();
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  卡片数据（三个 tab 统一成一种形状）
  // ═══════════════════════════════════════════════════════════════════

  List<_Card> get _cards {
    switch (_tab) {
      case ShelfTab.following:
        return _following
            .map((f) => _Card(
                  title: f.title,
                  cover: f.cover,
                  /*
                   * ★★★ 副标题 = 「最近一集的标题」，**没有就不画**（task-40）
                   *
                   * # 用户原话（2026-09-25 追加要求，逐字）
                   *
                   * > 最近追更  所追更的影视下面删除，追更中文字，
                   * > 追更中``的影视要显示徽标  用来显示还有多少集没看
                   *
                   * # 原来是 `... : '追更中'` 这个 fallback
                   *
                   * 实测（`.probe/t40_db_probe.py` 只读查用户真实数据）：
                   * ```text
                   * 追更中（following=1）:
                   *   怒鲨狂潮                      last_episode_title=None
                   *   剧场版 鬼灭之刃 无限城篇…      last_episode_title=None
                   * ⇒ ★ **所有**追更卡片的 lastEpisodeTitle 都是空
                   *   ⇒ 那个 fallback 会在**每一张**卡片下面打出「追更中」
                   *   ⇒ 这正是用户说的"所追更的影视下面…追更中文字"
                   * ```
                   *
                   * # 修法：传 `null`，而不是删掉整个 subtitle
                   *
                   * `PosterCard` 的判据是
                   * `if (subtitle != null && subtitle!.isNotEmpty)`
                   * ⇒ 传 null 就**不画那一行**，且**不占高度**。
                   * ★ 有标题时那行仍是有用信息，所以只去掉 fallback。
                   *
                   * ⚠️ 与追更页保持一致：`follow_page.dart` 传的就是
                   *    裸的 `f.lastEpisodeTitle`（没有 fallback）——
                   *    两处同构，本项目已踩过"一个页面对、一个页面不对"的坑。
                   */
                  subtitle: (f.lastEpisodeTitle?.isNotEmpty ?? false)
                      ? f.lastEpisodeTitle
                      : null,
                  // ★ 徽标 = 还剩几集没看（task-40，用户要求；
                  //   原来是 f.unreadCount = "巡检新增了几集"，语义不同）
                  unread: _remainingOf(f),
                  provider: f.provider,
                  id: f.nativeId,
                ))
            .toList();

      case ShelfTab.favorites:
        return _favorites
            .map((f) => _Card(
                  title: f.title,
                  cover: f.cover,
                  // 收藏的副标题是类型
                  subtitle: f.kind == 'series' ? '剧集' : '影片',
                  provider: f.provider,
                  id: f.nativeId,
                ))
            .toList();

      case ShelfTab.history:
        return _history
            .map((p) => _Card(
                  /*
                   * ══════════════════════════════════════════════════
                   * ★★★ task-63：标题为空时**逐级兜底**，绝不把空串传下去
                   * ══════════════════════════════════════════════════
                   *
                   * # Owner 原话（逐字）
                   * ```text
                   * > 还有，播放记录多了几个 显示 ？ 的记录，
                   * > 没有封面没有名字点进去才知道是什么
                   * ```
                   * ★ 那个「？」是三层叠加的结果，本行是**第 2 层**：
                   * ```text
                   * 第 1 层（数据）`_saveProgress` 写空标题  ⇒ lead 已修
                   * 第 2 层（传参）★ 本行把空串原样传给 PosterCard
                   * 第 3 层（渲染）`poster_card.dart` 空标题画 '?' ⇒ 已改成中性图标
                   * ```
                   *
                   * # 兜底顺序（★ 为什么是这个顺序）
                   * ```text
                   * ① p.title        源给的正式名（最好，直接显示）
                   * ② p.episodeTitle 退而求其次：至少告诉用户"看到哪一集"
                   * ③ '（标题未知）'  ★ 中性、不假装、不像 bug
                   * ```
                   * ⚠️ ③ **必须存在**，不能只靠 ②：
                   *    实测用户库里那 3 条坏记录 `episode_title` **也是 NULL**
                   *    （`.probe/t63_read_db.py` 读数：
                   *      `360:86969` / `cycani:3862` / `cycani:3841` 三条全为 None）
                   *    ⇒ 只做 ② 的话那三条**仍然是空**，等于没修。
                   */
                  title: _historyTitle(p),
                  cover: p.cover,
                  /*
                   * ⚠️ 副标题**不能与标题重复** ——
                   *    当标题为空、用 `episodeTitle` 兜底时，
                   *    下面这行原本也会输出同一个 `episodeTitle`
                   *    ⇒ 卡片上会出现**两遍同样的字**（"第01集" / "第01集"）。
                   *    ★ 这是我加兜底时**新引入**的边角情况，必须一起处理。
                   */
                  subtitle: _historySubtitle(p),
                  pct: p.percent,
                  provider: p.provider,
                  id: p.nativeId,
                  episodeId: p.episodeId,
                ))
            .toList();
    }
  }

  /// ★★★ task-63：播放记录的**显示标题**（逐级兜底，永不返回空串）
  ///
  /// ```text
  /// p.title → p.episodeTitle → '（标题未知）'
  /// ```
  ///
  /// # 为什么必须有它（三层根因的第 2 层）
  /// ```text
  /// Owner：「播放记录多了几个 显示 ？ 的记录，没有封面没有名字」
  /// ★ 用户库里那 3 条坏记录 title='' 且 episode_title=NULL
  ///   （`.probe/t63_read_db.py` 实测读数）
  ///   ⇒ 没有这一层，空串会一路传到 `PosterCard` ⇒ 渲染出「？」
  /// ```
  ///
  /// ★★★ task-63：播放记录的标题（三层兜底，**永不返回空串**）
  ///
  /// ★★ task-74 ① 的取舍：**这里刻意不发任何网络请求**
  ///
  /// ```text
  /// 「我的」在**首页**、且是启动路径上的组件
  /// ⇒ 进页面就打 getDetail 会拖慢启动（用户最敏感的一刻）
  /// ⇒ 回填只由追更页发起（lib/core/progress_backfill.dart），
  ///   本页**只享受已回填的结果** —— 因为回填会写回 DB，
  ///   而本页读的是同一个 progress 表 ⇒ 下次进来标题就有了
  /// ```
  /// ⚠️ 代价（如实记录）：**若用户从不去追更页**，
  ///    首页那几条坏记录会一直显示「（标题未知）」。
  ///    判据/回填逻辑仍只有一处实现 ⇒ 将来要在这里也接，
  ///    只需复用 `ProgressTitleBackfill`，不必重写规则。
  ///
  /// # 为什么占位是「（标题未知）」而不是别的
  /// ```text
  /// · 不含 '?' —— ★ Owner 反感的就是那个字符（UI 语义是"出错"，
  ///   而这里**没有出错**，只是数据里没标题）
  /// · 用**全角括号**包裹 ⇒ 一眼看出"这是占位，不是真片名"
  ///   （若直接写"标题未知"，用户会以为那部片就叫这个）
  /// · 中性、不假装、语言一致（本项目 UI 全中文）
  /// ```
  ///
  /// ⚠️ 与 `poster_card.dart` 的分工（**两层都要，不是重复**）
  /// ```text
  /// 本函数        ⇒ 保证**文字行**（卡片下方那行）非空 ⇒ 用户知道这是什么
  /// poster_card   ⇒ 保证**海报区**不画 '?'（画中性图标）
  /// ★ 只做本函数：海报区仍会画 '?'（若某调用点直接传空串）
  /// ★ 只做 poster_card：文字行会显示空白（比「？」更让人困惑）
  /// ```
  static String _historyTitle(Progress p) {
    if (p.title.trim().isNotEmpty) return p.title;
    final et = p.episodeTitle;
    if (et != null && et.trim().isNotEmpty) return et;
    return '（标题未知）';
  }

  /// ★★★ task-63：播放记录的**副标题**（与 [_historyTitle] 配对，防重复）
  ///
  /// # 为什么需要它（这是加兜底时**新引入**的边角情况）
  ///
  /// 原来的副标题逻辑是：
  /// ```dart
  /// subtitle: (p.episodeTitle?.isNotEmpty ?? false) ? p.episodeTitle! : '播放记录'
  /// ```
  /// 它**单看是对的**。但 [_historyTitle] 现在也会拿 `episodeTitle` 兜底
  /// ⇒ 当 `title` 为空、`episodeTitle` 非空时：
  /// ```text
  /// 标题   = p.episodeTitle   ← 兜底来的
  /// 副标题 = p.episodeTitle   ← 同一句
  /// ⇒ 卡片上出现**两遍同样的字**（"第01集" / "第01集"）
  /// ```
  /// ★ 所以副标题必须**知道标题用掉了什么**。
  ///
  /// # 规则
  ///
  /// ```text
  /// ① 标题已经是 episodeTitle（兜底用掉了）⇒ 副标题退回类型名「播放记录」
  /// ② 标题是 p.title 且 episodeTitle 非空   ⇒ 副标题 = episodeTitle（正常情况）
  /// ③ 没有 episodeTitle                     ⇒ 副标题 = 「播放记录」
  /// ```
  /// ⚠️ 用**同一个判据函数**（[_historyTitle]）来判断"标题用掉了什么"，
  ///    而不是在这里重写一遍"title 是否为空"——
  ///    否则两处判据会漂（本项目已踩过"两处同构必须一起改"的坑）。
  static String _historySubtitle(Progress p) {
    final et = p.episodeTitle;
    final hasEp = et != null && et.trim().isNotEmpty;
    if (!hasEp) return '播放记录';
    // ① 标题就是这一集的名字 ⇒ 别再说一遍
    if (_historyTitle(p) == et) return '播放记录';
    // ② 正常情况：标题是片名，副标题是集名
    return et;
  }

  /// 空状态文案（每个 tab 不同，比统一「暂无数据」有用）
  String get _emptyText {
    switch (_tab) {
      case ShelfTab.following:
        return '还没有追更的内容 —— 在详情页点「追更」即可追踪更新';
      case ShelfTab.favorites:
        return '还没有收藏 —— 在详情页点「收藏」保存想看的内容';
      case ShelfTab.history:
        return '还没有播放记录 —— 看过的内容会出现在这里';
    }
  }

  int _countOf(ShelfTab t) {
    switch (t) {
      case ShelfTab.following:
        return _following.length;
      case ShelfTab.favorites:
        return _favorites.length;
      case ShelfTab.history:
        return _history.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cards = _cards;

    /*
     * ★ 窄屏（手机）判定 —— 断点 640dp，取自原版 Vue 的同一条 media query：
     *   `@media (max-width: 640px) { ... }`（MyShelf.vue:503）
     *
     * 用 `maybeOf` 而不是 `of` 是刻意的：单测里 `MyShelf` 是**裸 pump** 的，
     * 外面不一定有 `MediaQuery`；取不到时退化成「宽屏」
     * ⇒ 与改动前的行为**完全一致**（旧代码没有任何宽度判断）。
     */
    final narrow =
        (MediaQuery.maybeOf(context)?.size.width ?? double.infinity) < 640;

    /*
     * ★ 「清空历史」只在历史 tab 显示
     *
     * 二次确认的按钮文案会变 —— 这是原版的设计
     *（不用弹窗，少一次打断）。
     *
     * ★ 抽成局部变量是因为**两个位置**要用它（宽屏=标题行内，
     *   窄屏=第二行右对齐）—— 见下面 `narrow` 的两处注释。
     */
    final clearHistoryButton = (_tab == ShelfTab.history && _history.isNotEmpty)
        ? TextButton.icon(
            onPressed: _clearHistory,
            icon: Icon(
              _clearingConfirm ? Icons.warning_amber : Icons.delete_outline,
              size: 15,
              color: _clearingConfirm ? colors.error : null,
            ),
            label: Text(
              _clearingConfirm ? '再点一次确认清空' : '清空历史',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: _clearingConfirm ? colors.error : null,
              ),
            ),
          )
        : null;

    /*
     * ══════════════════════════════════════════════════════════
     * ★★★ 「查看更多」—— 三个阶段：task-65 建 → task-26 换形式
     *     → **2026-10-06 再换（纯箭头）**
     * ══════════════════════════════════════════════════════════
     *
     * Owner 原话（task-65，2026-10-02）：
     * > 首页的 追更，历史，收藏 应该有一个**查看更多**按钮，
     * > 或者你想一个好的方式，点一下就跳转到 追更页面，
     * > **激活对应的 tab**
     *
     * ★ Owner 第二次复审（2026-10-05，安卓端）：
     * > 安卓端这个首页上面的查看更多好难看,能不能换换形式,太难看了
     *
     * ★ Owner 第三次复审（2026-10-06，安卓端）：
     * > 然后这个查看更多看起来还是不合理啊
     *
     * # 三代形态（每一代都是对上一代**具体缺点**的回答）
     * ```text
     * v1 (task-65)  12 号灰字 + 15px chevron，无容器
     *               （FontSizes.cap + onSurfaceVariant）
     *               ⇒ 手机上几乎看不见 ⇒ 被投诉「太难看」
     * v2 (task-26)  常驻胶囊：1px 描边 + 72% 白底 + 14 号字 + 16px 箭头
     *               ⇒ 与分段控件**抢戏**（同屏两个圆角容器）
     *               ⇒ 被投诉「还是不合理」
     * v3 (本次)     纯箭头 Icons.chevron_right 20dp，44dp 触控目标
     * ```
     *
     * # 为什么是**一个**按钮（而不是三块各一个）
     *
     * 本组件是 **tabs 切换**的 —— 同一时刻屏幕上只有**一块**内容
     * （见文件头「为什么合成一个版块」）。所以「三块各加一个」
     * 在结构上不成立：另外两块根本没渲染。
     * ⇒ 跳转目标**跟随当前 tab**（`shelfTabToFollowKey(_tab)`）。
     *
     * # 为什么**不**用 `GlassContainer`
     * `test/my_shelf_test.dart:71-78` 冻结了「整个文件里 `GlassContainer` +
     * 左括号只能出现 **1 次**」（= 外层 tabs 那一块）。
     * ⚠️ 连**注释里**都不能写出那个带括号的字面量 —— 该断言是在**原始源码
     *   文本**上跑的正则计数，注释也算数（实测：写进注释后计数从 1 变 2，
     *   用例当场变红）。
     * v3 已经没有容器了，这条约束自然满足（不必再绕道 BoxDecoration）。
     *
     * # 为什么外层还留着 `PressFeedback`
     * 图标本身是个**可点的实体**，按下没反馈会显得"死"（判据① 反馈操作）。
     * `PressFeedback` 用 `Listener`，**不消费手势** ⇒ 外层 `onPressed`
     * 一个字节都没改（`press_feedback.dart:36-59` 的实测结论）。
     *
     * # 为什么「清空历史」**不**跟着改
     * 两者只在窄屏第二行同排（且只在「播放历史」tab 下）。
     * 「清空历史」是**破坏性**次要操作（Material 的取向是让它安静），
     * 而它是**文字**按钮 —— 破坏性操作必须把后果写在脸上。
     * ⇒ 两者**有意**不同形：一个箭头（导航），一行字（危险）。
     *
     * # 位置（2026-10-02 手机实测后修正）
     *
     * 宽屏：标题行最右侧。
     * 窄屏：**换到第二行**右对齐 —— 见下面 `narrow` 分支的注释。
     *
     * ⚠️ `onSeeAll == null` 时**不渲染**（而不是渲染一个点了没反应的
     *    按钮）—— 与 `PosterCard.onTap` 可空是同一原则。
     */
    final seeAllLight = colors.brightness == Brightness.light;
    /*
     * ⚠️ 2026-10-06：原来的 `seeAllStroke`（描边色）**随胶囊一起删掉** ——
     *   现在只有一个箭头图标，没有容器就没有描边。
     *   删干净而不是留着不用：留着会让下一个读代码的人以为
     *   「容器还在，只是没接线」。
     */
    final seeAllFg = seeAllLight
        ? const Color(0xFF10121A).withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.86);
    final seeAllBg = seeAllLight
        ? const Color(0xFF10121A).withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.10);

    final seeAllButton = widget.onSeeAll == null
        ? null
        : PressFeedback(
            child: IconButton(
              onPressed: () => widget.onSeeAll!(shelfTabToFollowKey(_tab)),
              /*
               * ★★★ 2026-10-06（Owner 第二次复审）：**去掉胶囊容器**。
               *
               * Owner 原话：
               * > 然后这个查看更多看起来还是不合理啊
               *
               * # 这一版跟上一版（task-26）到底差在哪
               *
               * 上一版把原版**只在 hover 时出现**的容器提上来常驻
               *（描边 + 72% 白底 + 14 号字 + 16px 箭头），结果在手机上
               * 变成一颗**跟分段控件抢戏**的白药丸：同屏出现两个圆角容器
               *（tabs 玻璃 + 查看更多胶囊），一行里两种容器语言，
               * 视觉重心被拉到右上角。Owner 说的「还是不合理」就是它。
               *
               * # 现在的形态：**纯箭头 + 44dp 触控目标**
               *
               *   Icons.chevron_right，20dp
               *   constraints: BoxConstraints.tightFor(width: 44, height: 44)
               *   ⇒ 满足项目规范（DEVELOPMENT.md 坑 35：触控目标 ≥34px）
               *   ⇒ 视觉宽度从 ~110dp 收到 44dp，比标题「我的」的 39.6dp
               *     还窄 ⇒ 标题行右端不再出现第二个「块」
               *
               * # 为什么**不**继续用文字按钮
               *
               * · 同屏已有「查看全部 ›」（首页分区行）与「清空历史」
               *   两种文字按钮 —— 再放一个，三个「次要操作」互相稀释
               *   （原版自己的取向：.section__more 是 **hover 才显形**，
               *   说明它本来就该是最弱的一层）；
               * · 触屏**没有 hover**，最弱的一层要有一个**恒定**的载体
               *   ⇒ 一个箭头图标：它读不成「另一个按钮」，而是
               *     「这一块还能往里走」的**指示**。
               *
               * # 无障碍不能退
               *
               * 文字没了 ⇒ 读屏要能说出来。tooltip 同时是 a11y 标签
               *（Semantics.label），也保留长按提示；文案与原按钮语义一致
               *（跟随当前 tab 跳转）。
               */
              tooltip: '查看更多',
              icon: Icon(Icons.chevron_right, size: 20, color: seeAllFg),
              iconSize: 20,
              constraints: const BoxConstraints.tightFor(
                width: 44,
                height: 44,
              ),
              padding: EdgeInsets.zero,
              // 底色只出现在**按压**时（原版 hover 态的触屏等价物）
              style: IconButton.styleFrom(
                highlightColor: seeAllBg,
                shape: const RoundedRectangleBorder(
                  borderRadius: Radii.rFull,
                ),
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-10-03【内容带】「我的」这一整块**归零横向内边距**
         * ══════════════════════════════════════════════════════════════
         *
         * # 原版层级（`src/components/MyShelf.vue`）
         * ```text
         * div.container            ← 横向 --sp-6 = 24（TV 档 = max(24, 5vw)）
         *  └ div.mine
         *     ├ div.mine__head    ← :430-437 **无**横向 padding
         *     └ div.mine__rail    ← :495-501 **无**横向 padding（只有 padding-bottom）
         * ```
         * ⇒ 「我的」在整条链上**只吃容器那一层**（×1）。
         *
         * # 这里原来是什么
         * `MyShelf` 是首页的一个 sliver，而首页此前**没有**容器那层
         * ⇒ 它只好**自己扮演** `.container`（5 处写死 24）。
         * 现在页根补上了 `Layout.horizontalInsetOf(context)`（见 `home_page.dart`）
         * ⇒ 这 5 处必须归零，否则「我的」变成 ×2，会与下方分区轨道的**卡宽**
         *   错开 —— 而原版注释明确说过这件事不能错：
         * > ★ 与内容区的 `.section__rail` **用同一套令牌**，这样「我的」与
         * > 下方内容区的封面尺寸完全一致（此前这里是 132px、内容区是 165px，
         * > 被批评「又大又小」）   —— `MyShelf.vue:491-494`
         *
         * ★ 真浏览器权威读数（`.probe/_m4_readings.txt`）：
         * ```text
         * d1904  mineItem l=256.00   （容器 232 + 24，第二层 0）
         * tv1904 mineItem l= 95.19   （容器 95.2，第二层 0）
         * tv960  mineItem l= 48.00   （容器 48，第二层 0）
         * n500   mineItem l= 16.00   （容器 16，第二层 0）
         * ```
         * 四条都验证「`.mine__rail` 的 paddingLeft = **0px**」。
         */
        // ── 标题行 + tabs ──
        Padding(
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              /*
               * ★★★ 2026-10-06（Owner 新诉求）：
               * > 手机端可以把左上角的 我的 这两个文字隐藏吧
               *
               * ⇒ 窄屏（`narrow` = 逻辑宽 < 640dp）**不画**这个标题。
               *
               * # 为什么是「隐藏」而不是「改小 / 换位置」
               *
               * 手机这一页的版块名是**纯开销**：标题 39.6dp + 间距 16dp
               * = 55.6dp 的横向预算，换来的信息量为 0（底栏上方的分段控件
               * 自己就说明了这是什么版块）。拿掉之后 tabs 可用宽从
               * 324.4dp 涨到 380dp（412 − 32）——
               * 三个 tab 的 96dp **上限**仍然吃得下（3×96+8 = 296）
               * ⇒ `t36_cache_refresh_test.dart:539` 的
               *   「412dp 下 tab InkWell 宽 = 96.00」契约**不受影响**。
               *
               * ⚠️ 宽屏（≥640dp）**一个字都不改** —— 桌面/TV 上标题是版块
               *   结构的一部分（原版 `MyShelf.vue` 的 `.mine__head` 就有它），
               *   而且 `t65_follow_cards_test.dart` 的 1280dp 档要看这一行。
               */
              if (!narrow)
                Text(
                  '我的',
                  style: TextStyle(
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              // ⚠️ 间距跟着标题一起收 —— 否则窄屏 tabs 左边会凭空多 16dp。
              if (!narrow) const SizedBox(width: Sp.x4),
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 内联 tabs —— **一个玻璃容器装三个 tab**（2026-09-24 修正）
               * ══════════════════════════════════════════════════════════
               *
               * 用户指出：
               * > 上面那两个液态玻璃,跟底部的液态玻璃样式根本就不一样
               *
               * # 根因：结构错了（不是参数错了）
               *
               * 我第一版给**每个 tab** 各套一块 `GlassContainer` ——
               * 于是屏幕上出现三个独立的小玻璃胶囊。
               *
               * 原版 `MyShelf.vue` 是**两层**：
               * ```css
               * .mine__tabs {          /* ← 一个玻璃容器 */
               *   display: flex; gap: 4px; padding: 4px;
               *   border-radius: var(--r-full);
               *   background: var(--surface-1);      /* 玻璃底 */
               *   outline: 1px solid var(--glass-stroke);
               * }
               * .mtab {                 /* ← 单个 tab 是**透明**的 */
               *   background: transparent;
               *   color: var(--text-tertiary);
               * }
               * .mtab.is-active {       /* ← 只有选中那个有底 */
               *   background: var(--surface-4);      /* 比周围更亮一层 */
               *   color: var(--text-primary);
               *   box-shadow: var(--shadow-sm);
               * }
               * ```
               * 这**正是底栏的结构**（一条玻璃 + 一个滑动选中药丸）——
               * 所以两者观感自然一致。
               *
               * ★ 教训：**"看起来不像"时先怀疑结构，不要先调参数**。
               *   我第一版一直在调 tint/quality，方向就错了。
               */
              Expanded(
                child: LayoutBuilder(
                  /*
                   * ★★ 2026-10-05：`LayoutBuilder` 必须在这里 ——
                   *   **横向 `SingleChildScrollView` 的外面**。
                   *
                   * # 为什么（探针实测 + SDK 源码，双证据）
                   *
                   * 我第一版把 `LayoutBuilder` 放在 `GlassContainer` 里面
                   *（即 SCV 的子树里），结果 360dp 上钳制**完全没生效**：
                   * ```text
                   * 探针实测 360dp：SCV 视口 w=272.00
                   *                 GlassContainer 内容宽 296.00（= 4+3×96+4）
                   *                 tab 宽仍是 96.00（期望 88.00）
                   *                 末 tab 右沿 364 > 视口右沿 344 ⇒ 被裁 20dp
                   * ```
                   * 根因在 `_RenderSingleChildViewport._getInnerConstraints`：
                   * ```dart
                   * Axis.horizontal => constraints.heightConstraints(),
                   * Axis.vertical   => constraints.widthConstraints(),
                   * ```
                   * 横向 SCV 给子树的约束里 **width 是 unbounded**（0..∞）
                   * ⇒ `LayoutBuilder` 拿到的 `maxWidth` 是 `∞`
                   * ⇒ `min(96, (∞ − 8)/3)` 恒等于 96，钳制形同虚设。
                   *
                   * ⇒ 唯一能看到**视口真宽**的位置，就是 SCV 外面这一层。
                   *   （`Expanded` 给的是 tight 约束，`maxWidth` = 视口宽）
                   */
                  builder: (context, constraints) {
                    final tabWidth = _shelfTabWidthFor(constraints.maxWidth);
                    return SingleChildScrollView(
                      clipBehavior: Clip.antiAlias,
                      scrollDirection: Axis.horizontal,
                      child: GlassContainer(
                        // 外层：一个胶囊玻璃容器（全圆角）
                        shape: const LiquidRoundedSuperellipse(borderRadius: 999),
                        quality: GlassQuality.standard,
                        /*
                         * ⚠️ `padding: 4px` 是原版的值（`.mine__tabs { padding: 4px }`）
                         *    —— 让内部 tab 的选中底与容器边缘留出呼吸空间。
                         */
                        child: _ShelfTabs(
                          tabWidth: tabWidth,
                          current: _tab,
                          countOf: _countOf,
                          onSelect: _selectTab,
                        ),
                      ),
                    );
                  },
                ),
              ),

              /*
               * ★ 「清空历史」只在历史 tab 显示
               *
               * 二次确认的按钮文案会变 —— 这是原版的设计
               *（不用弹窗，少一次打断）。
               */
              if (!narrow && clearHistoryButton != null)
                clearHistoryButton,

              /*
               * ★★★ 「查看更多」放在**标题行最右侧**
               *
               * 完整论证（为什么只有一个按钮 / 为什么改常驻胶囊 /
               * 为什么不用 `GlassContainer` / 为什么包 `PressFeedback`）
               * 见上面构造 `seeAllButton` 处的那一整块注释 ——
               * ★ **单一真源**，这里不重复，免得两处注释将来漂移。
               */
              /*
               * ⚠️ **不要**加 `Spacer()` —— 上面那个 tabs 已经是
               *    `Expanded`（flex 1），`Spacer` 也是 flex 1
               *    ⇒ 两者会**平分**剩余空间 ⇒ tabs 区被压到一半宽。
               *    `Expanded` 自己就会把后面的按钮**推到最右**，
               *    所以直接放按钮即可。
               */
              if (!narrow && seeAllButton != null)
                seeAllButton,
            ],
          ),
        ),
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 窄屏（手机）：两个次要操作**换行**到自己的一行
         * ══════════════════════════════════════════════════════════════
         *
         * # 症状（2026-10-02 手机 emulator-5556 实测，逻辑宽 411.43dp）
         *
         * 「我的」这一行里 tabs 是 `Expanded`，右侧还挂着「清空历史」
         * 和「查看更多」⇒ tabs 只剩 ~205dp，而三个 tab 需要
         * `3 × 96 + 8(容器内边距) = 296dp`
         * ⇒ 「播放历史」整块被推出可视区（`SingleChildScrollView` 虽然
         *   横向可滚，但一个三格分段控件要**横滑**才看得全 = 不可用）。
         *
         * # 根因：不是参数不对，是**结构**不对
         *
         * 原版 `MyShelf.vue` 里：
         *   · 「清空历史」(`.mine__clear`) 是 head **下面**的独立块
         *     （`margin-top: var(--sp-2)`），**不在** 我的/tabs 这一行里；
         *   · 原版**根本没有**「查看更多」（是 task-65 Owner 新加的）；
         *   · `.mine__head` 带 `flex-wrap: wrap`，`.mine__tabs` 带
         *     `max-width: 100%` ⇒ 挤不下时**换行**，而不是压 tabs。
         * ⇒ 我们往这一行多塞了两个按钮，却没有原版的换行能力。
         *
         * # 处方
         *
         * 640dp 断点（与原版 `@media (max-width:640px)` 同）以下，把这两个
         * 按钮换到第二行右对齐 ⇒ tabs 独占首行
         *（`412 − 32(页面内边距 Sp.x4×2) − 我的(39.6) − 16(Sp.x4) = 324.4dp`
         *  `≥ 296dp = 3×96 + 8` ⇒ 三个 tab 全部可见，无需横滑；
         *  ★ 2026-10-05 补 **360dp** 的账：`360 − 32 − 39.6 − 16 = 272.4dp`
         *  `≥ 272dp = 3×88 + 8` —— 靠 `_shelfTabWidthFor` 收到 88.00 才成立，
         *  硬值 96 在这一档溢出 24dp（Owner m24232 报的「缺口」）。
         *  ⚠️ 原注释写的 `48(页面内边距)` 是错账：窄档是 `Sp.x4(16)`×2 = 32）。
         *
         * # 为什么**不**照抄原版窄屏的「隐藏 tab 文字只留图标」
         *
         * 原版窄屏把 `span` 藏掉只留 svg + count。照抄**解决不了**本症状，
         * 且会引入新问题：
         *   · `t36_cache_refresh_test.dart:539` 冻结了 412dp 下三个 tab 的
         *     InkWell 宽度**必须**是 96.00（±0.5）—— 那是**上限**生效的档位
         *     （钳制只在真装不下时才收窄）
         *     ⇒ 文字藏了宽度也不会变，一点宽度都省不出来；
         *   · 代价是**丢掉中文标签**（`t36` 还要求 `find.text('最近收藏')`
         *     这类标签在宽屏下可寻）；
         *   · 挤压**不是** tab 太宽造成的（96dp × 3 本来就够），
         *     是**我们自己**多塞了两个按钮 ⇒ 该动的是按钮，不是 tab。
         *
         * ⚠️ 宽屏路径**一行都没动**：`t65_follow_cards_test.dart` 要求
         *    1280dp 下「查看更多」**恰好一个**且可点；`t36` 的阳性对照是
         *    `Size(1280, 800)`。两者都走宽屏分支。
         */
        if (narrow && (clearHistoryButton != null || seeAllButton != null))
          Padding(
            // ★ 内容带：窄屏这一行同样只吃容器那层 ⇒ 横向归零，只留 top。
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (clearHistoryButton != null) clearHistoryButton,
                if (seeAllButton != null) seeAllButton,
              ],
            ),
          ),
        const SizedBox(height: Sp.x4),

        // ── 内容 ──
        if (_loading)
          const _ShelfSkeleton()
        else if (cards.isEmpty)
          /*
           * ★ 内容带：外层这圈横向 24 **归零** —— 原版 `.mine__empty` 是
           *   `.mine__rail` 位置上的空态，横向只吃容器那一层（×1）。
           *   ⚠️ 内层 `horizontal: Sp.x5` 不动：那是原版
           *   `.mine__empty { padding: var(--sp-6) var(--sp-5); }` 的**卡片内边距**。
           */
          Padding(
            padding: EdgeInsets.zero,
            child: Container(
              width: double.infinity,
              // 原版 .mine__empty { padding: var(--sp-6) var(--sp-5); } 是单层
              // padding（纵向 24 / 横向 20）。改之前这里是外层 vertical Sp.x6
              // + 内层 all Sp.x5 = 纵向 88dp 包 29dp 文字，手机上白占近 1/5 屏。
              padding: const EdgeInsets.symmetric(
                vertical: Sp.x6,
                horizontal: Sp.x5,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: Radii.rLg,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Text(
                _emptyText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: AppMetrics.posterWidth / AppMetrics.posterAspect + _shelfCardHeight,
            child: ListView.separated(
              clipBehavior: Clip.antiAlias,
              scrollDirection: Axis.horizontal,
              // ★ 内容带：「我的」轨道 ×1（原版 `.mine__rail` 无横向 padding）
              //   ⇒ 横向由页根的 `Layout.horizontalInsetOf` 给，这里归零。
              padding: EdgeInsets.zero,
              itemCount: cards.length,
              separatorBuilder: (_, __) => const SizedBox(width: Sp.x3),
              itemBuilder: (_, i) {
                final c = cards[i];
                return SizedBox(
                  width: AppMetrics.posterWidth,
                  child: Stack(
                    children: [
                      PosterCard(
                        title: c.title,
                        cover: c.cover,
                        subtitle: c.subtitle,
                        unread: c.unread ?? 0,
                        onTap: () {
                          /*
                           * ══════════════════════════════════════════════
                           * ★★★ 点卡片进**详情页**（不是播放页）
                           *     —— 修用户报的「首页三个 tab 点进去变成播放页」
                           * ══════════════════════════════════════════════
                           *
                           * # 用户原话
                           *
                           * > 追更 历史 收藏 点进去又变成直接播放页了。
                           * > 这里我刚测试,追更页面这三个点进去正常,
                           * > 首页的是直接进播放页
                           *
                           * 以及更早的明确要求（记录在 `follow_page.dart:436`）：
                           * > 最近追更 最近收藏 播放历史 点进去都应该进
                           * > **详情页**,而不是播放页
                           *
                           * # 原先这里错在哪
                           *
                           * 这里调的是 `onPlay` → 直接 push 播放器。
                           * 而**追更页已经改对了**（`follow_page.dart` 的三个
                           * tab 全走 `onOpenDetail`），所以只有首页是坏的 ——
                           * 与用户的描述**逐字吻合**。
                           *
                           * # 为什么"详情页"才是对的（不只是听用户话）
                           *
                           * 多集内容直接进播放器，用户就**没有选集入口**了
                           * （播放页的选集在进页面之后）。先看详情页能拿到
                           * 简介 / 选集 / 换源，再决定播哪一集 —— 这是原版
                           * `MyShelf.vue:262-270` 的注释原话：
                           * > 与首页其它区块一致：**必须走详情页**而不是直接开
                           * > 播放器，否则多集内容无法选集。
                           *
                           * ⚠️ 原版有一处例外：`history` tab 走 `resume()`
                           *    直接续播（`tab === 'history' ? resume(c) : open(c)`）。
                           *    但用户**后来明确推翻了这个例外**（见上面第二段
                           *    原话，要求历史也进详情页），且追更页已按新要求
                           *    实现。所以这里**三个 tab 一视同仁**。
                           *
                           * # provider / id 缺失时如实处理，不静默
                           *
                           * 老数据可能缺字段。静默无反应是最难查的表现 ——
                           * 与 `follow_page._openDetailFor` 同样的处理。
                           */
                          if (c.provider.isEmpty || c.id.isEmpty) {
                            debugPrint(
                              '[SHELF] 无法打开详情：provider="${c.provider}" '
                              'id="${c.id}"（数据不完整）',
                            );
                            return;
                          }
                          widget.onOpenDetail?.call(c.provider, c.id);
                        },
                      ),
                      // 历史的进度条（贴在封面底部）
                      if (c.pct != null && c.pct! > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: AppMetrics.posterWidth / AppMetrics.posterAspect -
                              3,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: c.pct! / 100.0,
                              minHeight: 3,
                              backgroundColor: Colors.black38,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// 统一的卡片形状
class _Card {
  const _Card({
    required this.title,
    required this.provider,
    required this.id,
    this.cover,
    this.subtitle,
    this.pct,
    this.unread,
    this.episodeId,
  });

  final String title;
  final String? cover;
  final String? subtitle;

  /// 进度百分比（仅历史有）
  final int? pct;

  final int? unread;
  final String provider;
  final String id;
  final String? episodeId;
}

/// 单个 tab 的宽度**上限**
///
/// # 为什么要等宽（而不是让内容自己撑）
///
/// 滑动药丸的位置是**纯算术**算出来的（`index * 宽度`）——
/// 这要求三个 tab **等宽**。让它按内容自适应的话：
/// ```text
/// · 未设角标时"最近追更"比"最近追更 2"窄 → 药丸算出来会**错位**
/// · 想修就得去量真实布局（LayoutBuilder/GlobalKey），
///   而那要等一帧，首帧药丸会闪一下
/// ```
/// 等宽最直接、也最可预测 —— **与底栏用的是同一个办法**
///（`shell.dart` 的 `_tabWidth` + `_pillLeft`）。
///
/// ★ 2026-10-05：96 从「硬值」改成「**上限**」—— 360dp 上三个 96 装不进
///   272.4dp 的视口（`3×96+8 = 296 > 272`），末 tab 的计数角标
///   被玻璃容器右沿切掉（真机取证 `.probe/phone/ck109_badge_zoom.png`）。
///   实际宽度 = `min(96, (可用宽 − 8) / 3)`，见 `_shelfTabWidthFor`：
///   412dp 仍是 96.00、1280dp 仍是 96.00，只有**真的装不下**时才收窄。
///
/// 宽度算账（三个标签都是 4 个全角汉字，宽度恒定）：
/// ```text
/// 标签   4 字 × 12px(cap)  = 48
/// 间距                     =  4
/// 角标   ~3 位 × 10px      = 18
/// 内边距  8 × 2 (Sp.x2)    = 16
/// ─────────────────────────────
/// 合计                     ≈ 86  →  上限取 96 留一点余量
/// ```
/// ⚠️ 横向内边距从 `Sp.x3(12)` 收到 `Sp.x2(8)` 就是为了给窄屏
///   让出这 6dp（`86 ≤ 88`）；**纵向仍是 `Sp.x3`** —— 那是
///   ≥34dp 触控目标契约，不许动。
///
/// tab 宽度**上限**（药丸位置靠纯算术算，所以必须等宽）
const double _shelfTabWidth = 96;

/// 实际使用的 tab 宽度 = `min(上限, 可用宽三等分)`
///
/// `avail` 是 **`Padding(all(4))` 之外**的可用宽（即玻璃容器内沿宽），
/// 所以先扣掉左右各 4dp 的内边距（共 8）再三等分。
///
/// ★ 为什么不能直接用常量：360dp 上容器只有 272.4dp，三个 96 需要 296
///   ⇒ 溢出 24dp（Owner m24232 报的「缺口」）。钳制后：
/// ```text
/// 360dp  → (272.4 − 8)/3 = 88.13 → 88.00   3×88 + 8 = 272 ≤ 272.4  ✓
/// 412dp  → (324.4 − 8)/3 = 105.47 → min(96) = 96.00  （不变）
/// 1280dp → (1232  − 8)/3 = 408    → min(96) = 96.00  （不变）
/// ```
///
/// ⚠️ `avail` 必须是**视口**宽，不是玻璃容器的内容宽。两个坑：
///   · 放到 `Padding(all(4))` **里面** ⇒ 4dp 内边距扣两次
///     （360dp 算出 85.33 而不是 88.00）；
///   · 放到**横向 `SingleChildScrollView` 的子树里** ⇒ 宽约束是
///     unbounded（`_RenderSingleChildViewport._getInnerConstraints`），
///     `maxWidth` = ∞ ⇒ `min(96, ∞)` 恒等于 96，钳制**完全失效**。
///     探针实测（`.probe/phone/probe_tabfit_run.txt`）：放里面时
///     360dp 的 tab 宽仍是 96.00、末 tab 右沿 364 > 视口右沿 344。
///     唯一正确的位置 = SCV **外面**那一层（`Expanded` 下）。
double _shelfTabWidthFor(double avail) =>
    math.min(_shelfTabWidth, (avail - 8.0) / 3);

/// 卡片轨道的高度 = 海报 + 文字区预留
///
/// # 这个 50 是量出来的，不是拍脑袋（原值 46 会**溢出 4px**）
///
/// `poster_card.dart` 的纵向构成（148 宽的海报）：
/// ```text
/// AspectRatio 海报          148 / (2/3)      = 222
/// SizedBox(height: Sp.x2)                    =   8
/// 标题 Text(fontSize 16)                     =  23   ← ★ 实测，不是 16
/// Padding(top: 2) + 副标题 Text(12)          =  19
///                                       总计 = 272
/// ```
/// 原先写 `+ 46` → 轨道 268 → **RenderFlex overflowed by 4.0 pixels**。
///
/// ⚠️ 关键点：`fontSize: 16` **不等于**渲染高度 16px。
///    实测标题的 `Text` 盒子是 **23px** 高（行高 + 字体度量）。
///    我第一版用 `TextPainter` 手算得到 16px，据此认为"46 够用" ——
///    **手算错了**，真机渲染才暴露出来。所以这里用实测值。
///
/// ⚠️ 只在有副标题时才需要 50。没有副标题的卡片用不满，
///    但轨道高度必须按**最高**的那种卡片给 —— 否则混排时矮的撑不住高的。
const double _shelfCardHeight = 50;

/// 「我的」分段控件的**滑动选中药丸**层（与底栏同构）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 用户验收标准（2026-09-24）
/// ══════════════════════════════════════════════════════════════════════
///
/// > 左上角和这个源切换,还是跟底部的不太一样
///
/// 「左上角」就是这个控件。**唯一的确认方法**是把底栏和它裁到同一张图里
/// 对比 —— 所以这里刻意**逐项对齐**底栏 `_BottomBar` 的参数：
/// ```text
/// 项目          底栏（shell.dart）              这里
/// ────────────────────────────────────────────────────────────────
/// 外层          GlassContainer                 GlassContainer（同一个）
/// 形状          LiquidRoundedSuperellipse(999)   同
/// 质量          GlassQuality.standard          同
/// 药丸          AnimatedPositioned             同
/// 药丸时长      420ms                          同
/// 药丸曲线      Curves.easeOutBack             同
/// 药丸填充      白渐变 0.96→0.80（浅色）        同
/// ```
///
/// # ★ 关键认知：药丸是**白**的，所以药丸上的字必须**是深色**
///
/// 原版 `tokens.css`（深色）与 `theme-light.css`（浅色）给了**两套**值：
/// ```css
/// /* 深色主题 */
/// --tab-pill-bg: linear-gradient(180deg,
///                  rgb(255 255 255 / 0.19), rgb(255 255 255 / 0.10));
/// --tab-fg-strong: #ffffff;              /* 药丸很透 → 底还是暗的 → 白字 */
///
/// /* 浅色主题 */
/// --tab-pill-bg: linear-gradient(180deg,
///                  rgb(255 255 255 / 0.96), rgb(255 255 255 / 0.80));
/// --tab-fg-strong: rgb(16 18 26 / 0.94); /* 药丸几乎纯白 → 深字 */
/// ```
/// ⚠️ 也就是说**药丸的实心程度与文字明暗必须成对**。
///    只抄一边（比如"永远白药丸 + 永远用 `foreground` 当文字色"）
///    会在深色主题下变成「白药丸 + 白字」= **完全看不见**。
///
///    实测确认本机 `AppsUseLightTheme = 1`（浅色），所以**现在**
///    浅色那套生效；但两套都要写对，否则用户切到深色就废了。
///
/// # 滑动动画
///
/// 用 `AnimatedPositioned`（与底栏同一个做法），420ms `easeOutBack`
/// —— `easeOutBack` 会**轻微过冲**再回弹，那就是"液态"手感。
/// 因为三个 tab 等宽（同一个 `tabWidth` 喂给药丸和三个 tab），
/// `left = index * tabWidth` 是纯算术，**不需要量真实布局**：
/// 宽度由**外面**那一层 `LayoutBuilder`（横向 SCV 之外）算好传进来，
/// 一帧内就有值，不必等 `GlobalKey` 的布局回读（那要等一帧，首帧药丸会闪）。
class _ShelfTabs extends StatelessWidget {
  const _ShelfTabs({
    required this.tabWidth,
    required this.current,
    required this.countOf,
    required this.onSelect,
  });

  /// 每个 tab 的宽度（由**外面**按可用宽算好的，见 `_shelfTabWidthFor`）
  ///
  /// ⚠️ 为什么是参数而不是自己量：本组件在横向 `SingleChildScrollView`
  ///    的子树里，宽约束是 **unbounded**，`LayoutBuilder` 会拿到 ∞。
  final double tabWidth;

  final ShelfTab current;
  final int Function(ShelfTab) countOf;
  final ValueChanged<ShelfTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final isLight =
        Theme.of(context).colorScheme.brightness == Brightness.light;
    final cols = _ShelfPalette.of(isLight);

    /*
     * ★ 2026-10-05：宽度由**外面**算好传进来（上限 `_shelfTabWidth`）。
     *
     * ⚠️ 这里**不能**自己放 `LayoutBuilder`：本组件在横向
     *    `SingleChildScrollView` 的子树里，宽约束是 **unbounded**
     *   ⇒ `maxWidth` 是 ∞ ⇒ 钳制永远算成 96。
     *    必须在 SCV 外面（`Expanded` 下那一层）算好再传进来 ——
     *    见 `MyShelfState` 里调用点的长注释。
     */
    final tabWidth = this.tabWidth;
    return Padding(
          // 原版 `.mine__tabs { padding: 4px }` —— 药丸与容器边缘留呼吸空间
          padding: const EdgeInsets.all(4),
          child: Stack(
            children: [
              // ── 滑动选中药丸 ──
              AnimatedPositioned(
                duration: Motion.slow, // 420ms，与底栏同一个时长
                curve: Curves.easeOutBack,
                left: current.index * tabWidth,
                top: 0,
                bottom: 0,
                width: tabWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: cols.pillGradient,
                    ),
                    borderRadius: Radii.rFull,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: cols.pillShadow),
                        blurRadius: 8,
                        spreadRadius: -2,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),

              // ── 三个 tab（文字层，压在药丸上面）──
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in ShelfTab.values)
                    SizedBox(
                      width: tabWidth,
                      child: _ShelfTabChip(
                        label: switch (t) {
                          ShelfTab.following => '最近追更',
                          ShelfTab.favorites => '最近收藏',
                          ShelfTab.history => '播放历史',
                        },
                        count: countOf(t),
                        active: t == current,
                        cols: cols,
                        onTap: () => onSelect(t),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
  }
}

/// 分段控件的配色（浅色/深色两套，照抄原版令牌）
///
/// 把"两套值"集中在这里，避免散落在各处写 `isLight ? ... : ...`
/// —— 漏改一处的表现是"某个元素在深色下看不见"，极难发现。
class _ShelfPalette {
  const _ShelfPalette({
    required this.pillGradient,
    required this.pillShadow,
    required this.activeText,
    required this.idleText,
    required this.badgeBg,
  });

  /// 药丸填充（浅色=近纯白；深色=很透的白叠加）
  final List<Color> pillGradient;

  /// 药丸投影的不透明度（浅色明显、深色更重，因为深色下靠阴影分层）
  final double pillShadow;

  /// 选中态文字（**必须与药丸明暗相反**，见 `_ShelfTabs` 的说明）
  final Color activeText;

  /// 未选中文字
  final Color idleText;

  /// 角标底色（原版 `.mtab__count { background: var(--surface-track) }`）
  final Color badgeBg;

  static _ShelfPalette of(bool isLight) => isLight
      ? _ShelfPalette(
          pillGradient: [
            Colors.white.withValues(alpha: 0.96),
            Colors.white.withValues(alpha: 0.80),
          ],
          pillShadow: 0.16,
          // `--tab-fg-strong: rgb(16 18 26 / 0.94)`
          activeText: const Color(0xFF10121A).withValues(alpha: 0.94),
          // `--tab-fg: rgb(16 18 26 / 0.62)`
          idleText: const Color(0xFF10121A).withValues(alpha: 0.62),
          badgeBg: const Color(0xFF10121A).withValues(alpha: 0.10),
        )
      : _ShelfPalette(
          pillGradient: [
            Colors.white.withValues(alpha: 0.19),
            Colors.white.withValues(alpha: 0.10),
          ],
          pillShadow: 0.34,
          // `--tab-fg-strong: #ffffff`
          activeText: Colors.white,
          // `--tab-fg: rgb(255 255 255 / 0.76)`
          idleText: Colors.white.withValues(alpha: 0.76),
          badgeBg: Colors.white.withValues(alpha: 0.16),
        );
}

/// 单个 tab
///
/// ⚠️ **本身是透明的** —— 玻璃在外层容器、选中药丸在 `_ShelfTabs` 里。
///    原版 `.mtab { background: transparent }`。
///
///    （我第一版给**每个 tab** 各套了一块 `GlassContainer`，
///     于是屏幕上出现三个独立小玻璃胶囊，与底栏那条大玻璃完全不像。
///     ★ 教训：**"看起来不像"时先怀疑结构，不要先调参数**。）
class _ShelfTabChip extends StatefulWidget {
  const _ShelfTabChip({
    required this.label,
    required this.count,
    required this.active,
    required this.cols,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final _ShelfPalette cols;
  final VoidCallback onTap;

  @override
  State<_ShelfTabChip> createState() => _ShelfTabChipState();
}

/// ★ 2026-10-03 补上的**焦点指示**（task-2 §10 实测缺陷）
///
/// # 之前为什么没有
///
/// 这个 chip 里只有一个**裸 `InkWell`**，而 `_ShelfTabs` 里**没有
/// `Material` 祖先**（本文件 `Material(` 命中 0 次）—— Material 的
/// 焦点高亮画在 `Material` 上，没有它就没有任何指示。
///
/// # 实测证据（release 包 + `--dart-define=TV_NAV_TRACE=true`）
///
/// ```text
/// UP×2 确实落到 InkWell<_ShelfTabChip<_ShelfTabs<InheritedLiquidGlass<…
/// 帧后确认: 实际矩形=(96,-74,192,-38) 一致=true      ← 拿到了焦点
/// 但 P3_up3.png 与 P0_boot.png **逐字节相同**
///   len=549755  filesha=243B0CF9E8F2  ⇒ 焦点**零像素**绘制
/// ```
/// 阳性对照：直播页频道行拿到焦点时**会**画环 ⇒ 缺的正是本 widget 的环。
///
/// # 为什么是 `foregroundDecoration`
///
/// `Container(decoration:)` 会把 border 宽度算进 padding
/// （`_paddingIncludingDecoration`）→ 尺寸 +4px → 焦点一移动整行就跳。
/// `foregroundDecoration` 走 `DecoratedBox(position: foreground)` ——
/// `RenderProxyBox`，**只画不改约束**，尺寸恒定。
/// 与 `episode_strip.dart:2250-2262`、`reorderable_card_grid.dart:744-753`
/// 是同一套写法（后者注释里记着这个 +4px 的旧 bug）。
///
/// # 颜色
///
/// 取 `Theme.of(context).colorScheme.primary` —— 与
/// `reorderable_card_grid.dart:749` 的焦点环**同一来源**，
/// 而 `material_ui` 本文件已 import，**不需要新增 import**。
class _ShelfTabChipState extends State<_ShelfTabChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ 文字色**不能**用 `Theme.of(context).colorScheme.onSurface` ——
     *    那在深色下是近白，而药丸（深色下）是"很透的白叠加"，
     *    叠在深色背景上仍然是**深**色，白字勉强能看；
     *    但浅色下 `onSurface` 是近黑，药丸是近纯白 → 也能看。
     *
     *    真正的问题是"两套值要成对"，所以统一走 `_ShelfPalette`，
     *    它把药丸和文字色**绑在一起**给。
     */
    final textColor = widget.active ? widget.cols.activeText : widget.cols.idleText;

    /*
     * ★ 角标：原版 `.mtab__count` 是**药丸形小底 + 文字**，不是裸数字。
     *
     * ⚠️ 角标底色的对比度：选中时它压在**白药丸**上，
     *    用 `badgeBg`（浅色下是 10% 黑）能形成一层淡灰底；
     *    文字用 `activeText`（深色）保证在白药丸上读得清。
     */
    final body = InkWell(
      onTap: widget.onTap,
      borderRadius: Radii.rFull,
      onFocusChange: (f) {
        if (mounted && f != _focused) setState(() => _focused = f);
      },
      child: Padding(
        /*
         * ★★ 纵向内边距必须 ≥ Sp.x3(12)，**不是** Sp.x2(8)
         *
         * # 为什么（实测 + 原版注释，双证据）
         *
         * 原版 `MyShelf.vue` 的 `.mtab` 逐字记着（CSS 注释，此处转述）：
         * > 触控目标 ≥34px（见 DEVELOPMENT.md 坑 35）。
         * > 8px 上下内边距 + 14px 行高只到 31px，差一点不达标，故加到 10px。
         * 而它的实际取值是 `padding: 10px 14px`。
         *
         * 项目规范（`cctv_to_client/DEVELOPMENT.md` 坑 35）：
         * > ★ 触控目标不得小于 ~34px —— 实测巡检发现 52 处偏小
         *
         * # 我们的实测（task-36，仪器有阳性对照）
         *
         * ```text
         * 修之前：InkWell = 96 x 33   → under34 = true   ✗ 违反项目自己的规范
         * 阳性对照：200x20 的东西被判 under34 = true     ✓ 仪器有效
         * ```
         * 算式：`Sp.x2*2 (16) + 17 (文字行高)` = 33 —— 与原版注释里
         * "8px + 14px 只到 31px" 是**同一个坑**。
         *
         * ★ 用 Sp.x3(12) 而不是原版的 10：12*2 + 17 = 41，比 34 的底线
         *   留出余量（字体度量随平台/字体变化，贴着 34 写会在某些设备
         *   上掉下去）。
         */
        padding: const EdgeInsets.symmetric(
          // ★ 横向 12 → 8：窄屏（360dp）要把这 6dp 让给 tab 宽度
          horizontal: Sp.x2,
          // ⚠️ 纵向**不许动** —— 见上面的 ≥34dp 触控目标论证
          vertical: Sp.x3,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
            if (widget.count > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: widget.cols.badgeBg,
                  borderRadius: Radii.rFull,
                ),
                child: Text(
                  '${widget.count}',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    height: 1.5,
                    fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return AnimatedContainer(
      duration: Motion.fast,
      foregroundDecoration: BoxDecoration(
        borderRadius: Radii.rFull,
        border: Border.all(
          color: _focused
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: body,
    );
  }
}

class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: AppMetrics.posterWidth / AppMetrics.posterAspect + _shelfCardHeight,
      child: ListView.separated(
        clipBehavior: Clip.antiAlias,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        // ★ 内容带：骨架轨道与真轨道逐值一致（×1），横向由页根给。
        padding: EdgeInsets.zero,
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(width: Sp.x3),
        itemBuilder: (_, __) => SizedBox(
          width: AppMetrics.posterWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: 0.05),
                    borderRadius: Radii.rMd,
                  ),
                ),
              ),
              const SizedBox(height: Sp.x2),
              Container(
                height: 12,
                width: 90,
                decoration: BoxDecoration(
                  color: colors.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
