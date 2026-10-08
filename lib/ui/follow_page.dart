// ═══════════════════════════════════════════════════════════════════════
//  追更页 —— 对齐原版 FollowView.vue（527 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 收藏 + 追更 + 未读更新 + 继续观看。
//
// # 数据平面说明（原版注释）
//
// > 这里全部是**独立平面**（我们自己的收藏与追更），
// > 与「平台自带历史备份」是两回事，互不干扰。
//
// # 三个 tab
//
// ```text
// 追更中      followingOnly=true    （list_following_for_ui，按最近更新排）
// 全部收藏    followingOnly=false   （只含 favorited=1）
// 继续观看    continueWatching
// ```
//
// # ★★★ 这个页面踩过两个真 bug，都要保持修好的状态
//
// ## ① 切追更开关必须用 `setFollowing`，**不能**用 `toggleFavorite`
//
// 原版注释：
// > 这里原先调 `favApi.toggle(...)`，而 `toggle_favorite` 是
// > **"不存在就新建、已删除就复活"** 的语义 —— 它**没有删除分支**。
// > 于是「点铃铛关掉追更」会**让已取消的收藏复活**：
// > ```text
// > 用户在详情页取消收藏   → DB deleted=1（收藏列表里没有了）
// > 回追更页点了一下铃铛   → deleted 被翻回 0
// >                      → ★ 「全部收藏」里它又出现了
// > ```
// > `setFollowing` 只改 `following` 字段，绝不碰收藏状态。
//
// ## ② 失败也要 `load()`
//
// 原版注释：
// > 之前这里没有 try/catch，失败会冒泡上去导致
// > 后面的 `load()` 不执行 —— 界面停在旧状态，
// > 用户以为点成功了。现在无论成败都刷新。

import 'dart:async';
import 'dart:math' as math;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/progress_backfill.dart';
import '../core/sourin_api.dart';
import 'tokens.dart';
import 'widgets/cover_image.dart';
import 'widgets/follow_update_notice.dart';
import 'widgets/poster_card.dart';

/// 追更页
class FollowPage extends StatefulWidget {
  const FollowPage({
    super.key,
    this.onPlay,
    this.onOpenDetail,
    this.onUnreadChanged,
    this.isTv = false,
    this.initialTab,
    this.backfillOverride,
  });

  /// 点条目 → 进播放器（续播）
  final void Function(
    String provider,
    String id,
    String title,
    String? cover,
    String? episodeId,
  )? onPlay;

  final void Function(String provider, String id)? onOpenDetail;

  /// 未读数变化 → 通知 shell 更新底栏徽章
  final ValueChanged<int>? onUnreadChanged;

  final bool isTv;

  /// ★★ task-65：进页时**初始激活**哪个 tab（`null` = 用默认 `following`）
  ///
  /// # 为什么需要它（Owner 原话）
  ///
  /// > 首页的 追更，历史，收藏 应该有一个**查看更多**按钮……
  /// > 点一下就跳转到 追更页面，**激活对应的 tab**，
  /// > 比如我从首页的追更点击查看更多 就跳转到 追更页面的**追更为激活状态**
  ///
  /// # 取值
  ///
  /// ```text
  /// 'following'  追更（默认）
  /// 'all'        收藏
  /// 'continue'   历史
  /// ```
  /// 与 [FollowPageState._tab] 是**同一套字符串 key**（见 `_FollowTab.key`
  /// 的说明：不用枚举 `name` 是因为 `continueWatching != 'continue'`）。
  ///
  /// ⚠️ 非法值**不会崩**：`initState` 里经 [FollowPageState.isValidTab]
  ///    校验，非法则回退默认（并在 debug 下打一行日志）。
  ///    ★ 不静默吞掉 —— 但要"响亮地退回安全值"而不是崩页面。
  final String? initialTab;

  /// ★★ task-74 ①：标题回填器的**注入口**（`null` ⇒ 用真实网络实现）
  ///
  /// # Owner 原话（逐字）
  ///
  /// > 追更页面有个未知,点进去明明有信息,也能播放,像这些信息,
  /// > 要么缓存,要么每次点进去 能访问就更新,不能访问就保留,
  /// > 或者你自己想一个优化方案
  ///
  /// # 为什么要有这个参数（而不是直接 `new` 一个）
  ///
  /// 回填**必须联网**（调 `getDetail`）。而 widget 测试里：
  /// ```text
  /// ① 真实 FFI 调不通（`sourin_core.dll` 在测试进程里加载失败）
  /// ② 就算通了，测试也不该打真实网络 —— 慢、不可重复、依赖源站
  /// ③ 而"失败静默、不重试、并发上限"这些**恰恰是最需要被测的行为**
  /// ```
  /// ⇒ 把回填器做成可注入，测试注入假 fetcher/saver，
  ///   就能**确定性地**覆盖成功、失败、去重三条路径。
  ///
  /// ⚠️ 与 [initialTab] 一样，这是**可选**参数：生产路径不传（用真实实现）。
  ///    本仓先例：`skip_marker_dialog.dart` 的 `streamUrl`、
  ///    `detail_page.dart` 的可注入 fetcher。
  final ProgressTitleBackfill? backfillOverride;

  @override
  State<FollowPage> createState() => FollowPageState();
}

class FollowPageState extends State<FollowPage>
    with WidgetsBindingObserver {
  /// 当前 tab
  ///
  /// ⚠️ 原版默认是 `following`（追更中）—— 不是"全部收藏"。
  String _tab = 'following';

  List<Favorite> _following = [];
  List<Favorite> _allFavs = [];
  List<Progress> _continueList = [];

  /// ★★ task-74 ①：标题回填器（懒建一次，会话内复用 ⇒ `_tried` 去重集有效）
  ///
  /// ⚠️ 必须**复用同一个实例**：去重集 `_tried` 挂在实例上。
  ///    若每次 `_load` 都 `new` 一个，切 tab 回来就会把失败的条目
  ///    **重打一遍网络** —— 那正是这个任务要避免的。
  ProgressTitleBackfill? _backfillCache;

  /// 取回填器（首次访问时创建；测试可经 `widget.backfillOverride` 注入）
  ProgressTitleBackfill get _backfill =>
      _backfillCache ??= (widget.backfillOverride ?? ProgressTitleBackfill());

  /// 更新检查结果
  ///
  /// ★ 直接用 `models.dart` 的 [UpdateInfo] —— 它的 `added` / `latestTitle`
  /// 已经按 `rust/sourin_core/src/store.rs:383,386` 对齐好了。
  ///
  /// # 这里原先是什么样（绕行已撤）
  ///
  /// 曾经用 `FollowUpdateItem` + `checkUpdatesRaw` + `buildUpdateItems`
  /// —— 因为 `UpdateInfo` 读的是 `new_count`（总数，语义用错）与
  /// `new_episode_title`（后端**从不下发**，真名 `latest_title`），
  /// 所以追更页自己调核心层再解一遍原始 JSON。
  ///
  /// 那是**第二份契约**，根因修好后必须撤：
  /// ```text
  /// 留着的话，以后 Rust 改了字段名，两处都要改，
  /// 而漏掉哪一处都不报错（正是这个缺口本身的形态）。
  /// ```
  /// 现在数据只有**一条来源**：`SourinApi.checkUpdates()`。
  List<UpdateInfo> _updates = [];

  bool _loading = true;
  String? _toast;

  /// 是否**已经加载成功过一次**（决定要不要显示整页骨架）
  ///
  /// # 为什么不能直接用 `_loading`
  ///
  /// 同一个真 bug 在设置页也犯过（用户报「设置页往下滑会自动往上滚」）：
  /// ```text
  /// if (_loading) return 骨架;     // ← 整个列表被替换
  /// return ListView(...);          // ← 重建时滚动位置从 0 开始
  /// ```
  /// 本页的刷新入口很多（切 tab 回来、从详情页返回、播放页返回、
  /// 应用回前台）—— 每次刷新都把列表换成骨架，用户就会看到
  /// **列表闪一下 + 滚动位置跳回顶部**。
  ///
  /// 所以骨架只在**首次**显示：`_loading && !_loadedOnce`。
  /// 之后的刷新都是"数据原地更新"。
  bool _loadedOnce = false;

  /// 本页是否曾经**被别的路由盖住**过
  ///
  /// # 为什么需要这个标记（Flutter 里没有现成的 `onActivated`）
  ///
  /// 原版是 Vue Router 的 KeepAlive 页面，有 `onActivated` 钩子：
  /// ```js
  /// onActivated(loadAll);   // 每次**返回**本页都重新拉
  /// ```
  /// 原版注释说明了为什么必须刷：
  /// > 本页在 keepAlivePages 里，onMounted 只跑一次。
  /// > 而这里的数据很容易在别处被改：
  /// >   · 在播放页看完一集 → 进度变了
  /// >   · 在详情页点了「追更」/「收藏」→ 列表应立刻反映
  /// > 不刷新就会出现「明明刚追更，回来却看不到」。
  ///
  /// Flutter 侧**没有** `onActivated`：本页在 `IndexedStack` 里常驻，
  /// 从详情页/播放页返回时**不会**重建，也不会触发 `initState`。
  /// 切底栏 tab 那条路径由 shell 的 `_followKey.currentState?.loadAll()`
  /// 覆盖了，但「详情页返回」这条**没被覆盖**。
  ///
  /// 这里用 `ModalRoute.isCurrentOf(context)` 补上：
  /// ```text
  /// 本页是当前路由 → false     被详情页/播放页盖住 → true
  /// ```
  /// 一旦被盖住过就记下来；等它**重新变成当前路由**时刷一次。
  bool _wasCovered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    /*
     * ★ task-65：进页时按 `initialTab` 激活对应 tab（「查看更多」跳转用）
     *
     * ⚠️ 放在 `initState` 而**不是** `build` 里读 ——
     *    在 build 里改状态会触发 "setState during build" 断言。
     */
    _applyRequestedTab(widget.initialTab, reason: 'initState');
    WidgetsBinding.instance.addPostFrameCallback((_) => loadAll());
  }

  /// 父级把 `initialTab` 改了（同一个 FollowPage 实例被复用）⇒ 跟着切
  ///
  /// ★ 为什么必须有：`shell.dart` 用 `_contentFor` **保活**了本页
  ///   （切走不销毁）⇒ 第二次点「查看更多」时**不会**重建 State ⇒
  ///   只读 `initState` 的话，第二次跳转**不会切 tab**。
  ///   这正是"保活 + 构造参数"组合下最容易漏的一处。
  @override
  void didUpdateWidget(FollowPage old) {
    super.didUpdateWidget(old);
    if (old.initialTab != widget.initialTab) {
      _applyRequestedTab(widget.initialTab, reason: 'didUpdateWidget');
    }
  }

  /// tab key 是否合法（三个之一）
  ///
  /// ★ 提成**静态纯函数** ⇒ 可被单测直接覆盖，不必挂 widget 树。
  static bool isValidTab(String? key) =>
      key != null && _FollowTab.values.any((t) => t.key == key);

  /// ★★ task-65：当前激活的 tab key（**只读观测口**）
  ///
  /// # 为什么要有它
  ///
  /// 本任务的验收是「点查看更多 ⇒ **激活对应的 tab**」。
  /// 而 `_tab` 是私有字段，测试**读不到** ⇒ 只能靠"看起来像"的间接判据
  /// （比如找某个文字的样式）—— 那正是本仓踩过的"符号存在式断言"。
  ///
  /// ⇒ 提供一个**公开只读**口，与 [showTab] 对称：
  /// ```text
  /// showTab(key)     写入口（带合法性校验）
  /// activeTabKey     读出口（测试/外层都可用）
  /// ```
  /// ★ 它只读，不暴露可变引用 ⇒ 不会成为"绕过 setState 改状态"的后门。
  String get activeTabKey => _tab;

  /// 应用一个"请求的 tab"（来自 `initialTab` 或 [showTab]）
  ///
  /// 非法值 ⇒ **响亮地退回**（debug 日志 + 保持当前值），不崩、不静默。
  void _applyRequestedTab(String? key, {required String reason}) {
    if (key == null) return; // 没请求 ⇒ 保持现状
    if (!isValidTab(key)) {
      debugPrint('[FOLLOW] ★ 非法 tab key "$key"（来自 $reason）'
          '⇒ 保持当前 "$_tab"。合法值：'
          '${_FollowTab.values.map((t) => t.key).join(" / ")}');
      return;
    }
    if (key == _tab) return; // 已经是它了 ⇒ 不动（避免无谓重建）
    debugPrint('[FOLLOW] $reason 激活 tab: $_tab -> $key');
    setState(() => _tab = key);
  }

  /// ★★ task-65：**公开入口** —— 让外层（`shell.dart`）请求切到某个 tab
  ///
  /// # 为什么用"公开方法 + GlobalKey"而不是全局可变单例
  ///
  /// 本仓对**隐式全局状态**有明确教训（跨测试泄漏、跨页面串台）。
  /// `shell.dart` 已经持有 `_followKey`（`GlobalKey<FollowPageState>`），
  /// 直接调它上面的方法 ⇒
  /// ```text
  /// ① 作用域显式（就是"那一个 FollowPage 实例"）
  /// ② 可测（widget 测试里拿 Key 调它，不用造全局）
  /// ③ 生命周期安全（`currentState` 为 null = 页面不在树上 ⇒ 调用方自己判）
  /// ```
  ///
  /// ⚠️ 调用方**必须**先确保本页已在树上（`currentState != null`），
  ///    否则这次请求会被丢掉。`shell.dart` 的 `_openFollowTab` 里
  ///    先 `_switchTo(AppTab.follow)` 再调用，顺序有注释说明。
  ///
  /// 返回值：`true` = 已切到目标 tab；`false` = key 非法（已记日志）
  bool showTab(String key) {
    if (!isValidTab(key)) {
      debugPrint('[FOLLOW] ★ showTab("$key") 非法 ⇒ 忽略。合法值：'
          '${_FollowTab.values.map((t) => t.key).join(" / ")}');
      return false;
    }
    if (key != _tab) {
      debugPrint('[FOLLOW] showTab 激活 tab: $_tab -> $key');
      setState(() => _tab = key);
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// ★ 应用回到前台时刷新（用户要求「追更页面应该是自动更新」）
  ///
  /// # 为什么这条必要
  ///
  /// 用户的使用场景是「切出去看别的 / 手机上看完一集再回来」——
  /// 回到前台时进度、未读数、收藏都可能已经变了。
  /// 不刷新就显示的是离开那一刻的旧数据。
  ///
  /// ⚠️ 用 `resumed` 而不是 `inactive`：`inactive` 在**弹窗、
  ///    下拉通知栏、切换窗口**时都会触发，太频繁（每次都会打一遍
  ///    三个 IPC）。`resumed` 才是"用户真的回来了"。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _loadedOnce) {
      // silent：回前台时列表已经在屏幕上，不该闪骨架
      unawaited(_refreshOnEnter());
    }
  }

  /// ★ 从别的页面（详情页 / 播放页）返回时刷新
  ///
  /// 依赖 `_ModalScopeStatus` 这个 `InheritedModel`：
  /// 路由的 `isCurrent` 变化时，`didChangeDependencies` 会被调用
  ///（Flutter 源码 `routes.dart` 的 `_ModalScopeStatus.updateShouldNotifyDependent`）。
  ///
  /// ⚠️ 这个方法在**每一帧的依赖变化**时都可能被调用，所以里面
  ///    必须**只做标记判断**，不能在条件不满足时也发起网络请求 ——
  ///    否则会变成"每次依赖变化打三个 IPC"。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!isCurrent) {
      // 被详情页/播放页盖住了 —— 记下来，等回来时刷
      _wasCovered = true;
      return;
    }
    if (_wasCovered) {
      _wasCovered = false;
      if (mounted && _loadedOnce) unawaited(_refreshOnEnter());
    }
  }

  /// ★ 自动更新三模块（**所有"回到本页"的入口都走这里**）
  ///
  /// # 用户要求
  ///
  /// > 追更页面,去掉检查更新,应该是自动更新 这三个模块的数据
  ///
  /// # 为什么抽成一个方法（而不是三处各写一遍）
  ///
  /// 「自动更新」= **两个不同代价的动作**，漏掉任一个都会看起来像没更新：
  /// ```text
  /// ① _load(silent) + _refreshUnread   读本地 DB（快）
  ///    → 「追更中 / 最近收藏 / 播放历史」三个列表的**内容与顺序**
  ///    → 底栏未读徽章
  /// ② _maybeSweep                      联网巡检（慢、有节流）
  ///    → 「N 部有更新」那块提示 + unread_count
  /// ```
  /// 三个入口（切回本 tab / 从详情页返回 / 应用回前台）都必须做**两件**，
  /// 所以只有一处实现。分散写必然出现"某个入口只刷新了列表、
  /// 没跑巡检"，表现就是**从不同路径回来看到的内容不一样**——
  /// 这种 bug 极难复现。
  ///
  /// ⚠️ 用 `unawaited` 而不是 `await`：巡检可能要十几秒（联网逐条
  ///    detail），不能拖住列表刷新 —— 用户该立刻看到列表，
  ///    然后"N 部有更新"稍后自己冒出来。
  Future<void> _refreshOnEnter() async {
    await _load(silent: true);
    await _refreshUnread();
    unawaited(_maybeSweep());
  }

  /// 拉取全部数据
  ///
  /// 原版用 `Promise.all` 并发三个请求 —— 这里同样并发。
  ///
  /// ★ 这是**公开**方法：`shell.dart` 在切回本 tab 时通过
  /// `_followKey.currentState?.loadAll()` 调它。
  ///（原版是 Vue Router 的 `onActivated(loadAll)`。）
  Future<void> loadAll() async {
    await _load();
    await _refreshUnread();
    // 切回本 tab 也算"回到本页" —— 同样要跑巡检（内部有节流）
    unawaited(_maybeSweep());
  }

  /// 切换 tab —— **先切、再静默重拉**
  ///
  /// # 用户要求（task-36）
  ///
  /// > 还有，每个页面不应该每次点进去都是完全新的状态，页面应该有缓存
  /// > 但是像首页的。追更收藏历史  还有。**追更页面的这三个**，
  /// > **切换页面应该要自动刷新的**
  ///
  /// # 与首页「我的」同一套办法（`my_shelf.dart` 的 `_selectTab`）
  ///
  /// 两处必须一致 —— 本项目已踩过"一个页面对、一个页面不对"的坑
  /// （见 `test/shelf_card_opens_detail_test.dart`：用户原话
  /// 「追更页面这三个点进去正常，首页的是直接进播放页」）。
  ///
  /// # 三个约束（与首页「我的」逐条相同）
  ///
  /// ```text
  /// ① 必须重拉        —— 否则"自动刷新"是假的
  /// ② 不能闪骨架      —— _load(silent: true) 不置 _loading
  /// ③ 不能卡住交互    —— unawaited，不 await（_load 是 3 个并发 FFI）
  /// ```
  ///
  /// ★ 顺序：**先 setState 再刷新** —— tab 的视觉反馈必须立刻发生。
  ///
  /// # ★★ 「点**当前** tab 也刷新」是**设计决定**，不是用户明确要求
  ///
  /// 同 `my_shelf.dart` 的 `_selectTab`（那里有完整说明）：
  /// 用户原话「切换页面应该要自动刷新的」**没有**说点当前 tab 要不要刷新。
  /// 这里做成也刷新，Lead 2026-09-25 裁决**保留**。
  ///
  /// ⚠️ 要撤就两处一起撤 —— 本项目已踩过"一个页面对、一个页面不对"的坑。
  void _selectTab(_FollowTab t) {
    // ★ 与 `my_shelf.dart` 同款：成功的刷新不打日志，
    //   所以"切 tab 有没有触发刷新"必须自己记一行（可观测性）
    debugPrint('[FOLLOW] 切 tab: $_tab -> ${t.key}（随后静默重拉）');
    if (t.key != _tab) setState(() => _tab = t.key);
    // ★ 点当前 tab 也刷新（用户"想看看有没有新的"时最自然的动作）
    //   ⚠️ 设计决定（用户未明确要求），Lead 裁决保留
    unawaited(_refreshOnEnter());
  }

  /// 拉三个列表（追更 / 收藏 / 继续观看）
  ///
  /// [silent] 为 true 时**不显示骨架**（数据原地更新）。
  ///
  /// # 为什么要有 silent 这个参数（而不是干脆不设 `_loading`）
  ///
  /// `_loading` 还兼任"这次请求还在飞"的判据。刷新期间用户如果又
  /// 切了 tab，界面不该在这中间闪一下骨架 —— 所以刷新走 silent，
  /// 只有**首次**（`!_loadedOnce`）才把 `_loading` 置起来显示骨架。
  Future<void> _load({bool silent = false}) async {
    if (mounted && !silent) setState(() => _loading = true);
    try {
      /*
       * ★ 并发拉三份（原版 `Promise.all`）
       *
       * ```text
       * listFavorites(followingOnly: true)   追更列表
       * listFavorites(followingOnly: false)  收藏列表
       * continueWatching(20)                 继续观看
       * ```
       */
      final results = await Future.wait([
        SourinApi.listFavorites(followingOnly: true),
        SourinApi.listFavorites(followingOnly: false),
        SourinApi.continueWatching(limit: 20),
      ]);

      if (!mounted) return;
      setState(() {
        _following = results[0] as List<Favorite>;
        _allFavs = results[1] as List<Favorite>;
        _continueList = results[2] as List<Progress>;
        _loadedOnce = true;
      });

      /*
       * ★★ task-74 ①：**渲染完之后**再回填标题（不阻塞首屏）
       *
       * # 为什么必须放在 setState 之后、且用 unawaited
       *
       * ```text
       * 回填要打网络（getDetail，可能几百 KB）
       * 若 await 它 ⇒ 首屏要多等一次网络往返才能显示列表
       * ⇒ 用户看到的是"追更页变慢了"，而不是"标题补上了"
       * ```
       * ★ 这正是 Owner 要的顺序：先让**已有信息**上屏，
       *   能访问的稍后自己更新，不能访问的**保留**占位符。
       *
       * ⚠️ 只在这里发起 —— **绝不在 `build()` 里**发请求
       *    （`build` 每帧都可能跑 ⇒ 会变成每帧一个网络请求）。
       */
      unawaited(_backfillTitles());
    } catch (e) {
      debugPrint('[FOLLOW] 加载追更失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// ★★ task-74 ①：对「（标题未知）」的播放记录做**异步回填**
  ///
  /// # Owner 原话（逐字）
  ///
  /// > 追更页面有个未知,点进去明明有信息,也能播放,像这些信息,
  /// > 要么缓存,要么每次点进去 能访问就更新,不能访问就保留,
  /// > 或者你自己想一个优化方案
  ///
  /// # 这条路径做三件事
  ///
  /// ```text
  /// ① 判据：哪些行**需要**回填  → needsTitleBackfill（唯一下拉点）
  /// ② 联网：getDetail(provider, nativeId) ⇒ 拿到真标题/封面
  /// ③ 落库：saveProgress(...) ⇒ **下次进页面 DB 里就有标题了**
  ///                          （= Owner 说的"缓存"，无需新表）
  /// ```
  ///
  /// # ★ 为什么"落库"这一步是这个方案的**核心**
  ///
  /// 只改内存的话，用户切走再回来 ⇒ `_load` 从 DB 读回**旧的空标题**
  /// ⇒ 标题又变回「（标题未知）」，且**每次进页面都要重打一遍网络**。
  /// 写回 DB 之后：
  /// ```text
  /// 第一次进页面   → 打网络 → 补上 → 落库
  /// 之后每次进页面 → 读 DB 直接就有标题，**零网络**
  /// ```
  /// 这正是 Owner 说的「要么缓存」——
  /// **`progress` 表本身就是那个缓存**，不需要新建任何表/字段。
  ///
  /// # ★ 为什么失败**什么都不做**（对应"不能访问就保留"）
  ///
  /// ```text
  /// 回填是**尽力而为**的旁路，不是主功能：
  /// · 失败 ⇒ 那条继续显示「（标题未知）」= "保留" ✅
  /// · 失败若写空值 ⇒ 把一条**有集名**的记录写得更差 ❌
  /// · 失败若删行   ⇒ 用户的观看记录消失 ❌❌（最严重）
  /// ```
  /// ⇒ 实现里任何异常都被吞掉（见 `progress_backfill.dart` 的 `_one`），
  ///   本方法**不 try/catch** 也安全 —— 但为了"即使回填器自己有 bug
  ///   也不能把追更页搞崩"，这里再兜一层。
  ///
  /// # ⚠️ 本方法**不**设 `_loading`、**不** await（由调用方 `unawaited`）
  Future<void> _backfillTitles() async {
    try {
      final patched = await _backfill.backfill(_continueList);
      /*
       * ⚠️ 三个必须的判断：
       * ```text
       * patched.isEmpty  ⇒ 没补到任何东西（全失败/全不需要）⇒ 别 setState
       *                    （无谓重建会让列表闪一下）
       * !mounted         ⇒ 页面已销毁 ⇒ setState 会抛
       *                    （回填是网络往返，回来时页面很可能已经不在了）
       * ```
       */
      if (patched.isEmpty || !mounted) return;
      setState(() {
        _continueList = mergeBackfilled(_continueList, patched);
      });
      debugPrint('[FOLLOW] ★ 标题回填成功 ${patched.length} 条'
          '（已写回 DB ⇒ 下次进页面零网络）');
    } catch (e) {
      // 回填绝不影响主流程 —— 失败只记一行，界面保持占位符
      debugPrint('[FOLLOW] 标题回填跳过: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  task-74 ① 的**测试注入口**（与 `my_shelf.dart:253 debugSetData` 同手法）
  // ══════════════════════════════════════════════════════════════════════
  //
  // # 为什么必须有这两个口子
  //
  // 「标题回填」的触发条件是「`_continueList` 里有**空标题**的行」。
  // 而 `_continueList` 唯一的**生产**来源是 `_load()` 里那三个 FFI：
  // ```text
  // listFavorites(followingOnly: true)
  // listFavorites(followingOnly: false)
  // continueWatching(limit: 20)
  // ```
  // ★ `flutter test` 里 `sourin_core.dll` 加载失败 ⇒ 三路**必然全失败**
  //   ⇒ `_continueList` 永远是空 ⇒ 回填**根本没机会跑**
  //   ⇒ 「补上了没」「失败会不会崩」「会不会重复打网络」**全都测不到**。
  //
  // # 为什么是**两个**而不是一个
  //
  // ```text
  // debugSetContinueList  注入数据（替代 _load 的第三路）
  // debugRunBackfill      手动跑一次并**等它结束**
  // ```
  // ⚠️ 生产路径里回填是 `unawaited(_backfillTitles())` —— 那个 future
  //    **拿不到** ⇒ 测试没法知道"回填结束了没" ⇒ 必须有一个**可 await**
  //    的入口。否则断言只能靠"多 pump 几帧"猜时间，
  //    而本仓已经因为"猜时间"翻过车（见 `.probe/flutter_test_lock.ps1` 头注释）。
  //
  // ⚠️ 两者都**不改变任何生产行为**：生产路径既不调它们，
  //    也没有任何生产分支依赖它们。

  /// 测试用：直接设定「继续观看」列表（`null` 语义同 `debugSetData`：不动）
  @visibleForTesting
  void debugSetContinueList(List<Progress> list) {
    setState(() => _continueList = list);
  }

  /// 测试用：手动跑一次标题回填并**等它结束**
  ///
  /// ⚠️ 直接转发 `_backfillTitles()` —— 故意**不复制**一份逻辑，
  ///    否则测的就不是生产那条路了（那正是"影子测试"）。
  @visibleForTesting
  Future<void> debugRunBackfill() => _backfillTitles();

  /// 测试用：读当前「继续观看」列表（观测回填有没有真的改到状态）
  @visibleForTesting
  List<Progress> get debugContinueList => List.unmodifiable(_continueList);

  /// 底部徽标的总数（追更**还剩多少集没看**，task-40）
  ///
  /// # ★ 与旧实现的区别（用户明确要求改语义）
  ///
  /// 旧：`SourinApi.totalUnread()` → `SUM(unread_count)`
  ///     = "自上次巡检后更新了几集"，且**只在巡检时变**。
  /// 新：Σ(每部剧的 `总集数 − 已看集数`)
  ///     = 用户要的"追更还有多少集没看"。
  ///
  /// ⚠️ 用 `listAllProgress()` 而**不是** `continueWatching()`：
  ///    后者带 `WHERE finished=0 AND position > 5`（store.rs:909），
  ///    会把"已看完的剧"整个滤掉 ⇒ 看完一集后徽标**不会减少**。
  ///
  /// ⚠️ 失败静默（不清零）—— 与 task-36 那条"失败不许清空"同一原则。
  Future<void> _refreshUnread() async {
    try {
      final all = await SourinApi.listAllProgress();
      final byKey = followRemainingByKey(
        following: _following,
        allProgress: all,
      );
      var sum = 0;
      for (final v in byKey.values) {
        sum += v;
      }
      widget.onUnreadChanged?.call(sum);
      _remainingByKey = byKey;
      if (mounted) setState(() {});
      debugPrint('[FOLLOW] 追更还剩 = $sum（${_following.length} 部）');
    } catch (e) {
      debugPrint('[FOLLOW] 取未读数失败（保留旧值）: $e');
    }
  }

  /// 每部追更剧「还剩几集没看」—— 卡片徽标用
  ///
  /// ★ 与底部徽标**同一个** `followRemainingByKey`，避免两处漂。
  ///   ⚠️ 由 `_FavGrid` 通过构造参数接收（它是独立的 StatelessWidget，
  ///      拿不到本 State 的字段）。
  Map<String, int> _remainingByKey = const {};

  /// ★ 追更巡检 —— 自动路径（原「检查更新」按钮的功能搬到这里）
  ///
  /// # 用户要求
  ///
  /// > 追更页面,去掉检查更新,应该是自动更新 这三个模块的数据
  ///
  /// # 为什么不能直接删掉它（这个判断很重要）
  ///
  /// 「检查更新」按钮原先调 `check_updates` —— 它做的是**追更巡检**：
  /// ```text
  /// FollowEngine::check_all  → 逐个追更条目去插件 detail() 拉最新集数
  ///                          → 比对 last_episode_count → 算出"新增 N 集"
  ///                          → 写 unread_count，返回 Vec<UpdateInfo>
  /// ```
  /// ⚠️ 这与 [_load] **不是一回事**：
  /// ```text
  /// _load()         只读本地 DB（3 个 IPC，毫秒级）
  /// check_updates   真的联网问每个插件（20 个源 × detail 超时 20s）
  /// ```
  /// 所以巡检**必须独立调度** —— 只刷新列表的话，"有没有新集"
  /// 永远不会被重新计算，那块「N 部有更新」的提示会永远空着。
  ///
  /// # ★ 调度策略（三档，都与"用户正在看这一页"绑定）
  ///
  /// ```text
  /// ① 节流：距上次巡检 < _sweepInterval → 跳过
  ///    理由：巡检很贵（联网 + 逐条 detail）。切 tab 来回切
  ///    不该每次都触发一轮 20 源的网络请求。
  ///
  /// ② 触发点 = 与 `_load(silent: true)` 完全相同的三处：
  ///    · didChangeDependencies（从详情页/播放页返回）
  ///    · didChangeAppLifecycleState(resumed)（应用回前台）
  ///    · shell 切回本 tab 时调的 `loadAll()`
  ///    理由：这三处正是"用户回到追更页"的全部入口 ——
  ///    巡检要在用户**看得到**的时候做才有意义。
  ///
  /// ③ 不做定时轮询（`Timer.periodic`）
  ///    理由：定时器在页面不可见时也会跑，等于后台空转联网。
  ///    追更数据的"新鲜度"要求不高（新集不会几分钟出一集），
  ///    而代价是实打实的网络请求 —— 不划算。
  /// ```
  ///
  /// ⚠️ 节流窗口 [_sweepInterval] 取 **10 分钟**：
  ///    比"每集更新间隔"（通常几小时~一天）小得多，
  ///    用户任何一次正经回到追更页都会看到最新数据；
  ///    又足够挡住"反复切 tab"造成的重复巡检。
  static const Duration _sweepInterval = Duration(minutes: 10);

  DateTime? _lastSweepAt;

  /// 是否需要跑巡检（纯判断，**不发请求** —— 方便单测）
  ///
  /// 抽成独立方法是为了可测：widget 测试里直接断言"什么时候该跑、
  /// 什么时候该跳过"，不用等真实的 10 分钟。
  @visibleForTesting
  bool shouldSweep(DateTime now) {
    final last = _lastSweepAt;
    if (last == null) return true; // 首次必跑
    return now.difference(last) >= _sweepInterval;
  }

  /// 跑一次追更巡检（**节流后**）
  ///
  /// ⚠️ 与 [_load] 分开：`_load` 是"读列表"，这个是"联网算有没有新集"。
  ///    两者互不阻塞 —— 巡检慢（可能十几秒），不该拖住列表显示。
  Future<void> _maybeSweep() async {
    if (!mounted) return;
    if (!shouldSweep(DateTime.now())) return;
    // ★ 先记时间再发请求 —— 否则并发调用（切 tab + 回前台同时触发）
    //   会各自看到"没跑过"，于是打两轮巡检
    _lastSweepAt = DateTime.now();
    try {
      final updates = await SourinApi.checkUpdates(maxItems: 50);
      if (!mounted) return;
      setState(() => _updates = updates);
      /*
       * 巡检会改 `unread_count`（新增集数 → 未读），所以要把
       * 列表与底栏徽章一起刷新，否则界面显示的还是巡检前的状态。
       */
      await _load(silent: true);
      await _refreshUnread();
    } catch (e) {
      /*
       * ⚠️ 自动路径**不弹 toast**：巡检是后台行为，用户没主动点，
       *    失败时弹一个红条只会造成困惑（"我没点它啊？"）。
       *    如实记日志即可 —— 下次回到本页会重试。
       */
      debugPrint('[FOLLOW] 自动巡检失败（下次回本页重试）: $e');
    }
  }

  Future<void> _markRead(Favorite f) async {
    try {
      await SourinApi.markFavoriteRead(f.key);
    } catch (e) {
      debugPrint('[FOLLOW] 标记已读失败: $e');
    }
    await _load();
    await _refreshUnread();
  }

  /// ★★★ 切换追更开关 —— **已移除**（2026-09-25）
  ///
  /// # 为什么删掉（不是忘了写）
  ///
  /// 用户原话：
  /// > 追更这里 下面的 这两个操作按钮很丑,直接删了吧
  ///
  /// 卡片下面那一行按钮（追更铃铛 / 标记已读 / 取消收藏）整个删掉了，
  /// 所以这个方法没有调用点了。
  ///
  /// # ★ 能力没有丢 —— 它搬到了详情页
  ///
  /// 「开启 / 取消追更」现在从**详情页**操作
  ///（`lib/ui/detail_page.dart` 的 `_toggleFollow`，同样用 `setFollowing`）。
  /// 用户点卡片 → 进详情页 → 在那里追更/收藏，路径是通的。
  ///
  /// ⚠️ 原版（`FollowView.vue:98-127`）那条真 bug 的教训**没有丢**：
  ///    「切追更必须用 `setFollowing`，不能用 `toggleFavorite`」
  ///    （后者有"已删除就复活"的语义，会让取消掉的收藏复活）。
  ///    这条不变量现在由 `lib/ui/detail_page.dart` 守着，
  ///    回归断言在 `test/detail_follow_test.dart` 里已改指到那个文件。

  /// ★ 打开**详情页**（用户要求：三个 tab 点进去都进详情页，不是播放页）
  ///
  /// 用户原话：
  /// > 最近追更 最近收藏 播放历史 点进去都应该进 详情页,而不是播放页
  ///
  /// # 为什么不再走播放页
  ///
  /// 原先三个 tab 的点击**全部**落到 `onPlay` → 直接 push 播放器。
  /// 用户要的是先看详情页（简介 / 选集 / 换源），再决定播哪一集。
  ///
  /// # provider / id 缺失时**如实处理**，不静默
  ///
  /// 老数据可能缺 `provider` / `native_id`。这时**不能**静默什么都不做
  /// —— 用户点了没反应是最难查的表现。所以：记日志 + 明确提示。
  void _openDetailFor(Favorite f) {
    if (f.provider.isEmpty || f.nativeId.isEmpty) {
      debugPrint(
        '[FOLLOW] 无法打开详情：provider="${f.provider}" '
        'id="${f.nativeId}"（数据不完整）',
      );
      _flash('这条记录缺少来源信息，无法打开详情');
      return;
    }
    /*
     * ★★ 顺带清掉未读（**这是删按钮后的必要补偿**，不是新功能）
     *
     * # 为什么必须做
     *
     * `unread_count` 的清零入口，全项目**只有** `mark_favorite_read` 一处，
     * 而它原先唯一的调用点就是被删掉的「标记已读」按钮：
     * ```text
     * lib/core/sourin_api.dart   markFavoriteRead  ← 定义
     * lib/ui/follow_page.dart    _markRead         ← 唯一的调用点（原按钮）
     * rust/.../store.rs:788      UPDATE favorites SET unread_count=0
     * ```
     * 按钮删了但不清未读 → 红点**永远消不掉**，用户只能一直看着它。
     * 那是删按钮引入的**新 bug**，必须一起解决。
     *
     * # 为什么是「打开详情页」这个时机
     *
     * 红点的语义是「有**你还没看过**的更新」。用户点进详情页就是
     * "我来看这个更新了" —— 这是最自然、也最不需要额外 UI 的时机。
     *（原版是让用户点一个 ✓ 按钮；按钮被用户要求删了，
     *  这个时机就是它的等价替代。）
     *
     * ⚠️ 只在 `unreadCount > 0` 时调用 —— 避免每次点卡片都白打一次 IPC。
     */
    if (f.unreadCount > 0) _markRead(f);
    widget.onOpenDetail?.call(f.provider, f.nativeId);
  }

  /// 继续观看 → 详情页（用户要求「播放历史 点进去也应该进详情页」）
  ///
  /// ⚠️ 与 [_openDetailFor] 分开：`Progress` **没有**未读概念
  ///    （未读是「追更」特有的字段，见 `Favorite.unreadCount`），
  ///    所以这里不需要清未读那一步。
  void _openDetailForProgress(Progress p) {
    if (p.provider.isEmpty || p.nativeId.isEmpty) {
      debugPrint(
        '[FOLLOW] 无法打开详情：provider="${p.provider}" '
        'id="${p.nativeId}"（数据不完整）',
      );
      _flash('这条记录缺少来源信息，无法打开详情');
      return;
    }
    widget.onOpenDetail?.call(p.provider, p.nativeId);
  }

  /// 剩余时间文案
  String _remaining(Progress p) {
    final left = (p.duration - p.position).clamp(0, 1 << 30);
    final m = left ~/ 60;
    if (m >= 60) return '剩 ${m ~/ 60} 小时 ${m % 60} 分';
    return '剩 $m 分钟';
  }

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _toast = msg);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _toast == msg) setState(() => _toast = null);
    });
  }

  List<Favorite> get _currentList =>
      _tab == 'all' ? _allFavs : _following;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Stack(
      children: [
        ListView(
          clipBehavior: Clip.antiAlias,
          /*
           * ★ 原版是「内容带 1440px 上限 + 居中」（`base.css:549-558` 的
           *   `.container { max-width: var(--content-max-w); margin: 0 auto }`）。
           *   ★ 2026-10-04（业主：改为两侧占满）起 [Layout.bandFor] 不再封顶
           *   ⇒ `Layout.sideInsetOf` **恒返回 0**，这一层现在是空操作。
           *   调用点保留，是为了将来若要恢复居中只需改 [Layout.bandFor] 一处。
           *
           * `ListView` 的上下 padding 是**故意**写死的（顶部呼吸 + 给悬浮
           * 底栏让位），所以这里只把"居中"那一段补进来，纵向不动：
           * ⚠️ 不能在外面套 `Center` —— `RenderViewport.sizedByParent == true`
           *   （SDK `rendering/viewport.dart:1676`）会吃掉宽松的交叉轴约束。
           */
          padding: EdgeInsets.only(
            top: Sp.x8,
            bottom: Sp.bottomBarInset,
          ).add(Layout.sideInsetOf(context)),
          children: [
            // ── 页头 ──
            Padding(
              padding: Layout.contentInsetOf(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '追更',
                    style: TextStyle(
                      fontSize: FontSizes.xl,
                      fontWeight: FontWeights.semibold,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: '收藏与追更是'),
                        TextSpan(
                          text: '你自己的数据',
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const TextSpan(text: '，跨设备同步；平台自带历史仅作备份'),
                      ],
                    ),
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x5),

            /*
             * ── 工具条：三个 tab（液态玻璃）──
             *
             * ★★ 2026-09-25：套上底栏那套液态玻璃 + **删掉「检查更新」按钮**
             *
             * # 用户的两条要求
             *
             * > 追更页面的 追更中 收藏 历史,这三个没有做液态玻璃
             * > 追更页面,去掉检查更新,应该是自动更新 这三个模块的数据
             *
             * # ① 为什么用 `GlassContainer` 而不是自己写模糊
             *
             * 用户原话：
             * > 我们现在的底栏的那种液态玻璃效果,你就直接套用就行了
             *
             * 项目里已经踩过这个坑（`shell.dart:2787-2809` 记着用户
             * **两次打回**）：自己写的 `ClipRRect > BackdropFilter(blur)`
             * 只能做**毛玻璃（frosted）**，做不出液态玻璃的核心
             * —— **折射（refraction）**。真液态玻璃要 fragment shader
             * 采样背后纹理、按法线做位移。
             *
             * 所以这里和底栏/标题栏/my_shelf 用**同一个组件、同一套材质**：
             * ```text
             * 外层   GlassContainer(shape: LiquidRoundedSuperellipse(999))
             * 质量   GlassQuality.standard   ← 包文档推荐（95% 场景）
             * 内层   透明 tab + 滑动选中药丸（结构照 my_shelf.dart）
             * ```
             *
             * ★ 结构照抄 `lib/ui/widgets/my_shelf.dart` —— 它是
             *   「多个 tab 包在一个胶囊玻璃容器里」的**现成正确范例**。
             *   那条注释里的教训尤其重要：
             *   > "看起来不像"时**先怀疑结构，不要先调参数**。
             *   （它第一版给**每个 tab** 各套一块玻璃，屏幕上出现三个
             *     独立小胶囊，与底栏那条大玻璃完全不像。）
             *
             * # ② 为什么「检查更新」按钮删掉是安全的
             *
             * 那个按钮原先调 `_checkUpdates()` —— 它做的是**追更巡检**
             *（`check_updates`：逐个追更条目去插件拉最新集数），
             * 并把结果填进 `_updates`（"N 部有更新"那块提示）。
             *
             * ⚠️ 这**不是** `_load()` 能替代的：`_load()` 只读本地 DB，
             *    而"有没有新集"必须真的联网问插件。所以按钮删了，
             *    巡检要**搬进自动路径**（见 `_maybeSweep`），
             *    否则那块"N 部有更新"的提示会**永远空着** ——
             *    那是删按钮引入的新 bug。
             */
            Padding(
              padding: Layout.contentInsetOf(context),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GlassContainer(
                  /*
                   * ★ 全圆角胶囊 —— 与底栏同一个形状语言
                   *（`shell.dart:3560` 用的是 `barHeight / 2`，
                   *  这里就是胶囊高度的一半；999 是"给足"的写法，
                   *  与 my_shelf 一致。）
                   */
                  shape: const LiquidRoundedSuperellipse(borderRadius: 999),
                  // 与底栏同一档（包文档：95% 场景的正确选择）
                  quality: GlassQuality.standard,
                  child: _FollowTabs(
                    /*
                     * ★ `_tab`（String）→ `_FollowTab`（枚举）
                     *
                     * ⚠️ 必须**显式匹配**而不是试着用下标——
                     *    状态字段是字符串（既有代码与测试都依赖
                     *    `'following'` / `'all'` / `'continue'`），
                     *    而枚举名是 `continueWatching` ≠ `'continue'`。
                     *    `firstWhere` 的 `orElse` 兜住"未知字符串"
                     *   （不该发生，但不能让页面崩）。
                     */
                    current: _FollowTab.values.firstWhere(
                      (t) => t.key == _tab,
                      orElse: () => _FollowTab.following,
                    ),
                    countOf: (t) => switch (t) {
                      _FollowTab.following => _following.length,
                      _FollowTab.all => _allFavs.length,
                      _FollowTab.continueWatching => _continueList.length,
                    },
                    onSelect: _selectTab,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Sp.x5),

            // ── 更新提示 ──
            //
            // ★ 抽成 [FollowUpdateNotice] 的原因：这里原先**漏渲染了两个字段**
            //
            // 原版 `FollowView.vue:254-260` 每条渲染三样：
            // ```vue
            // <span class="ellipsis t-primary">{{ u.title }}</span>
            // <span class="chip chip--brand">+{{ u.added }} 集</span>     ← 新增集数
            // <span class="t-tertiary t-xs">{{ u.latest_title }}</span>   ← 最新一集
            // ```
            // ⚠️ 曾经用的是 `UpdateInfo.newCount`（= `new_count`，**总**集数）
            //    且完全没有最新一集标题 —— 现在模型的 `added` / `latestTitle`
            //    已按 `store.rs:383,386` 对齐，直接用即可。
            if (_updates.isNotEmpty)
              Padding(
                // ★ 左右内边距改成"内容带内边距"（两侧随时取当前带宽）——
                //   宽档 24 / 窄档 16，与原版 640px 断点一致
                padding: EdgeInsets.fromLTRB(
                  Layout.contentPaddingOf(context),
                  0,
                  Layout.contentPaddingOf(context),
                  Sp.x5,
                ),
                child: FollowUpdateNotice(items: _updates),
              ),

            // ── 骨架（★ 只在**首次**加载时显示 —— 见 `_loadedOnce`）──
            if (_loading && !_loadedOnce) const _FollowSkeleton()

            // ── 继续观看 ──
            //
            // ★ 点条目 → **详情页**（用户要求「点进去都应该进详情页」）
            //
            // ⚠️ 这里原先调 `_playItem`（直接进播放器）。用户原话：
            //    > 最近追更 最近收藏 播放历史 点进去都应该进 详情页,而不是播放页
            //
            // 为什么详情页比播放页合理：用户从「继续观看」点进去，
            // 常常是想**换一集**或看看简介，而不是续播那一集。
            // 直接开播等于替他做了决定，还得退出来才能选集。
            else if (_tab == 'continue')
              _ContinueList(
                list: _continueList,
                remaining: _remaining,
                onTap: _openDetailForProgress,
              )

            // ── 追更 / 收藏 ──
            else
              _FavGrid(
                list: _currentList,
                emptyTitle: _tab == 'following' ? '还没有追更的内容' : '还没有收藏',
                onOpen: _openDetailFor,
                /*
                 * ★ 把"每部还剩几集"传下去（task-40）。
                 *
                 * ⚠️ `_FavGrid` 是**独立** StatelessWidget，
                 *    拿不到 `FollowPageState` 的字段 —— 我第一版直接在
                 *    它内部写 `_remainingOf(f)`，编译报
                 *    「The method '_remainingOf' isn't defined for the
                 *      type '_FavGrid'」。必须显式传参。
                 */
                remaining: _remainingByKey,
              ),
          ],
        ),

        // ── Toast ──
        if (_toast != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: Sp.x10,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x5,
                  vertical: Sp.x3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: Radii.rFull,
                ),
                child: Text(
                  _toast!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: FontSizes.sm,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

/// 追更页的三个 tab（**液态玻璃分段控件**）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★ 2026-09-25：从「三个各自带边框的 pill」改成「一块玻璃 + 滑动药丸」
/// ══════════════════════════════════════════════════════════════════════
///
/// # 用户原话
///
/// > 追更页面的 追更中 收藏 历史,这三个没有做液态玻璃
/// > 我们现在的底栏的那种液态玻璃效果,你就直接套用就行了
///
/// # 结构照抄 `lib/ui/widgets/my_shelf.dart`（现成的正确范例）
///
/// ```text
/// GlassContainer(shape: LiquidRoundedSuperellipse(999))   ← 外层：一块胶囊玻璃
///   └ Padding(all: 4)                                     ← 原版 .mine__tabs padding
///       └ Stack
///           ├ AnimatedPositioned  滑动选中药丸（白渐变 + 阴影）
///           └ Row                 三个 tab（透明，压在药丸上面）
/// ```
///
/// # ★★ 为什么是「一块玻璃包三个 tab」而不是「三个玻璃 pill」
///
/// 这正是 `my_shelf.dart:330-360` 记下的教训（它第一版做错了）：
/// > 我第一版给**每个 tab** 各套一块 `GlassContainer` ——
/// > 于是屏幕上出现三个独立的小玻璃胶囊。
/// > ★ 教训：**"看起来不像"时先怀疑结构，不要先调参数**。
///
/// 底栏也是这个结构（**一条玻璃 + 一个滑动选中药丸**）——
/// 所以两者观感自然一致。这也正是用户说的「套用底栏那套」。
///
/// # 为什么药丸与文字色必须**成对**取自 [_FollowPalette]
///
/// 药丸是**白**的（浅色主题下近纯白），所以药丸上的字必须**是深色**。
/// 只抄一边（比如"永远白药丸 + 用 `colorScheme.onSurface` 当文字色"）
/// 会在深色主题下变成「白药丸 + 白字」= **完全看不见**。
/// 所以两套值集中在一个 palette 里，绑在一起给。
class _FollowTabs extends StatelessWidget {
  const _FollowTabs({
    required this.current,
    required this.countOf,
    required this.onSelect,
  });

  final _FollowTab current;
  final int Function(_FollowTab) countOf;
  final ValueChanged<_FollowTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final isLight =
        Theme.of(context).colorScheme.brightness == Brightness.light;
    final cols = _FollowPalette.of(isLight);

    /*
     * ★ 2026-10-05：与首页 `_ShelfTabs` 同构 —— 宽度自适应（上限 `_followTabWidth`）。
     *
     * ⚠️ `LayoutBuilder` 必须在 `Padding(all(4))` **外面** —— 里面的
     *    `constraints.maxWidth` 已经把 4dp×2 扣掉了，`_followTabWidthFor`
     *    会再扣一次 8。
     */
    return LayoutBuilder(
      builder: (context, constraints) {
        final tabWidth = _followTabWidthFor(constraints.maxWidth);
        return Padding(
          // 原版 `.mine__tabs { padding: 4px }` —— 药丸与容器边缘留呼吸空间
          padding: const EdgeInsets.all(4),
          child: Stack(
            children: [
              // ── 滑动选中药丸 ──
              AnimatedPositioned(
                duration: Motion.slow, // 420ms，与底栏同一个时长
                curve: Curves.easeOutBack, // 轻微过冲再回弹 = "液态"手感
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
                  for (final t in _FollowTab.values)
                    SizedBox(
                      width: tabWidth,
                      child: _FollowTabChip(
                        label: t.label,
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
      },
    );
  }
}

/// 三个 tab 的定义（**顺序即 `index`** —— 药丸的 `left` 靠它算）
///
/// ⚠️ `index` 直接用于 `left = index * tabWidth`（`tabWidth` 来自
///    `_followTabWidthFor(constraints.maxWidth)`）：
///    所以枚举顺序**就是**屏幕上的顺序，不能随意调整。
///    三个 tab 等宽，`left` 是纯算术，不需要量真实布局
///   （量布局要等一帧，首帧药丸会闪 —— `my_shelf` 的注释讲了这点）。
enum _FollowTab {
  following('追更中', 'following'),
  all('全部收藏', 'all'),
  continueWatching('继续观看', 'continue');

  const _FollowTab(this.label, this.key);

  /// 显示文案
  final String label;

  /// ★ 与 `FollowPageState._tab` 对应的字符串 key
  ///
  /// ⚠️ **为什么不直接用 `name`**：状态字段 `_tab` 是既有代码与
  ///    测试都依赖的字符串（`'following'` / `'all'` / `'continue'`），
  ///    而枚举名 `continueWatching` ≠ `'continue'`。
  ///    显式给出 key 让**映射关系只有一处**，改枚举名不会静默改掉状态值。
  final String key;
}

/// tab 分段控件的宽度**上限**（三个等宽）
///
/// 96 与 `my_shelf.dart` 的 `_shelfTabWidth` 一致 —— 同样的
/// `[标签 + 计数角标]` 内容，同样的字号，宽度该一样。
///
/// ★ 2026-10-05：与首页同构，改成**上限** + 按可用宽三等分钳制
///   （`min(96, (avail − 8) / 3)`）。两页**必须**用同一套语义：
///   否则一个页面 96、另一个 88，看起来就是「两个页面对不齐」。
///   ⚠️ 这里的 `avail` 是 `Padding(all(4))` **之外**的可用宽。
const double _followTabWidth = 96;

/// 实际使用的 tab 宽度 = `min(上限, 可用宽三等分)`（与首页同名同义）
///
/// 追更页这一行**没有** `Expanded`/`SingleChildScrollView`（`Align` 给的是
/// loose 约束，maxWidth = 整页内容宽）⇒ 常见档位算下来都是 96.00：
/// `360dp → (328 − 8)/3 = 106.67 → 96.00`、`412dp → 96.00`、
/// `1280dp → 96.00`。钳制只在容器真的被压窄时才生效。
double _followTabWidthFor(double avail) =>
    math.min(_followTabWidth, (avail - 8.0) / 3);

/// 分段控件的配色（浅色/深色两套，**照抄 `my_shelf.dart` 的 `_ShelfPalette`**）
///
/// # 为什么照抄而不是自己调
///
/// 用户的要求是「跟底栏的一样」。两者的药丸、文字色、角标底
/// 必须**成对**取自同一套值 —— 自己另调一套参数就会"看起来不一样"，
/// 而那正是用户已经打回过的问题。
///
/// 把两套值集中在这里，避免散落各处写 `isLight ? ... : ...`
/// —— 漏改一处的表现是"某个元素在深色下看不见"，极难发现。
class _FollowPalette {
  const _FollowPalette({
    required this.pillGradient,
    required this.pillShadow,
    required this.activeText,
    required this.idleText,
    required this.badgeBg,
  });

  /// 药丸填充（浅色=近纯白；深色=很透的白叠加）
  final List<Color> pillGradient;

  /// 药丸投影的不透明度
  final double pillShadow;

  /// 选中态文字（**必须与药丸明暗相反**，见 `_FollowTabs` 的说明）
  final Color activeText;

  /// 未选中文字
  final Color idleText;

  /// 角标底色
  final Color badgeBg;

  static _FollowPalette of(bool isLight) => isLight
      ? _FollowPalette(
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
      : _FollowPalette(
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
/// ⚠️ **本身是透明的** —— 玻璃在外层 `GlassContainer`、
///    选中药丸在 `_FollowTabs` 里。与 `my_shelf` 的 `_ShelfTabChip`
///    结构完全一致（原版 `.mtab { background: transparent }`）。
class _FollowTabChip extends StatelessWidget {
  const _FollowTabChip({
    required this.label,
    required this.count,
    required this.active,
    required this.cols,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final _FollowPalette cols;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ 文字色**不能**用 `Theme.of(context).colorScheme.onSurface` ——
     *    必须与药丸明暗成对，统一走 `_FollowPalette`。
     */
    final textColor = active ? cols.activeText : cols.idleText;

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rFull,
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
         * 算式：`Sp.x2*2 (16) + 17 (文字行高)` = 33。
         *
         * ★ 追更页这三个 tab 与首页「我的」**逐字同构**，两处必须一起改 ——
         *   只改一处会立刻变成"一个页面对、一个页面不对"。
         */
        padding: const EdgeInsets.symmetric(
          // ★ 横向 12 → 8：与首页 `my_shelf.dart` 的 chip 保持逐字一致
          horizontal: Sp.x2,
          // ⚠️ 纵向**不许动** —— 那是 ≥34dp 触控目标契约
          vertical: Sp.x3,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 4),
              // 角标是**药丸形小底 + 文字**，不是裸数字
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: cols.badgeBg,
                  borderRadius: Radii.rFull,
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    height: 1.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 播放记录的**显示标题**（逐级兜底，**永不返回空串**）
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么追更页也要有它（Owner 报的「？」在**两条**渲染路径上）
/// ═══════════════════════════════════════════════════════════════════════
///
/// Owner 原话：
/// > 播放记录多了几个 显示 ？ 的记录，没有封面没有名字点进去才知道是什么
///
/// # 同一份数据，两个组件各画一遍
///
/// ```text
/// 首页「我的」→ 播放历史 = MyShelf._cards → PosterCard     ✓ task-63 已修
/// 追更页 → 「历史」tab   = _ContinueList → _ContinueCard   ✗ 本条修的就是它
/// ```
/// ★ 两者读**同一张表、同一条 SQL**（`continueWatching`）——
///   所以 task-63 只修首页时，Owner 那句投诉在追更页**依然存在**。
///   活库实测（只读）：`cycani:3841` `title=''` `cover=NULL`
///   ⇒ 追更页「历史」tab 仍会画出 `?`。
///
/// # 兜底顺序（与 `my_shelf.dart::_historyTitle` **同一套口径**）
///
/// ```text
/// ① p.title        源给的正式名（最好，直接显示）
/// ② p.episodeTitle 退而求其次：至少告诉用户"看到哪一集"
/// ③ '（标题未知）'  ★ 中性、不假装、不像 bug
/// ```
/// ⚠️ ③ **必须存在**，不能只靠 ②：
///    实测那 3 条坏记录 `episode_title` **也是 NULL**
///    （`360:86969` / `cycani:3862` / `cycani:3841` 三条全为 None）
///    ⇒ 只做 ② 的话它们仍然是空，等于没修。
///
/// # ★ 为什么占位是「（标题未知）」而不是别的
///
/// ```text
/// · 不含 '?' —— ★ Owner 反感的就是那个字符（UI 语义是"出错"，
///   而这里**没有出错**，只是数据里没标题）
/// · 用**全角括号**包裹 ⇒ 一眼看出"这是占位，不是真片名"
///   （若直接写"标题未知"，用户会以为那部片就叫这个）
/// · 中性、不假装、语言一致（本项目 UI 全中文）
/// ```
///
/// ⚠️ **为什么不直接把 `my_shelf.dart::_historyTitle` 提出来共用**：
///    `test/t61_progress_title_test.dart` 对 `_historyTitle` 的**函数体文本**
///    有断言（必须含 `p.title` / `p.episodeTitle` / `（标题未知）`，
///    且不得含 `?`）⇒ 把它改成一行转发会让那条测试**变红**。
///    那条测试归 task-63，不在我的写权范围内。
///    ⇒ 这里的取舍：**两处各写一份，但加一条"两份口径必须一致"的测试**
///      （见 `t65_follow_cards_test.dart` 的 ⑤ 组）——
///      漂了就会红，比"看起来共用"更可靠。
String progressDisplayTitle(Progress p) {
  if (p.title.trim().isNotEmpty) return p.title;
  final et = p.episodeTitle;
  if (et != null && et.trim().isNotEmpty) return et;
  return '（标题未知）';
}

/// 播放记录的**「第几集」文案**（与 [progressDisplayTitle] 配对，防重复）
///
/// # 为什么需要它（这是加兜底时**新引入**的边角情况）
///
/// 原写法是 `p.episodeTitle ?? "单集"` —— 单看是对的。
/// 但 [progressDisplayTitle] 现在也会拿 `episodeTitle` 兜底 ⇒
/// ```text
/// title 为空、episodeTitle = "第01集" 时：
///   标题   = "第01集"   ← 兜底来的
///   副标题 = "第01集"   ← 同一句
/// ⇒ 卡片上出现**两遍同样的字**
/// ```
/// ⇒ 副标题必须**知道标题用掉了什么**。
///
/// # 规则（与 `my_shelf.dart::_historySubtitle` 同构）
///
/// ```text
/// ① 标题已经是 episodeTitle（兜底用掉了）⇒ 退回「单集」
/// ② 标题是 p.title 且 episodeTitle 非空   ⇒ 用 episodeTitle（正常情况）
/// ③ 没有 episodeTitle                     ⇒ 用「单集」
/// ```
/// ⚠️ 用**同一个判据函数**（[progressDisplayTitle]）判断"标题用掉了什么"，
///    而不是在这里重写一遍"title 是否为空"—— 否则两处判据会漂。
String progressDisplayEpisode(Progress p) {
  final et = p.episodeTitle;
  final hasEp = et != null && et.trim().isNotEmpty;
  if (!hasEp) return '单集';
  // ① 标题就是这一集的名字 ⇒ 别再说一遍
  if (progressDisplayTitle(p) == et) return '单集';
  // ② 正常情况：标题是片名，这一栏是集名
  return et;
}

/// 卡片网格的**列数**（三个 tab 共用 —— 一处定义，不会漂）
///
/// # 为什么提成共享函数（task-65）
///
/// Owner 原话：
/// > 追更页面的 追更 收藏 历史，都要是**卡片布局**，不要一行一个，太占用空间了
///
/// 追更 / 收藏 本来就走 `_FavGrid`（`GridView`），只有**历史**是
/// `Column` + 整宽 `Container`（一行一个）。
///
/// ★ 把列数公式提出来而不是在历史那边**再写一遍**，理由是本仓反复踩的
///   "两处同构必须一起改"：
/// ```text
/// 若 _ContinueList 自己写一份 (usable / (posterWidth + Sp.x3)).floor()
///   ⇒ 将来谁调了 posterWidth 或间距，只改一处 ⇒ 两个 tab 列数不同
///   ⇒ 表现是"历史比追更挤/松"，很难被发现是"公式漂了"
/// ```
///
/// ⚠️ 下界 2 保证**极窄屏**也不会退化成一行一个（那正是 Owner 抱怨的形态）；
///    上界 12 防超宽屏上一行几十张。
///
/// # ★ 2026-10 修正：同一个 48 被减了**两次**（task-74⑤ 漏网的那一半）
///
/// 入参 `availableWidth` 的含义是「本区**可用**宽度」，也就是**减过左右
/// 内边距之后**的那个宽度 —— 而它两个调用点传的都是 `LayoutBuilder` 的
/// `c.maxWidth`（外面的 `Padding` 已经把 48 减掉了）。旧实现又减了一次：
/// ```text
/// 1366px 窗口：本区可用宽 = 1366 − 48 = 1318
///   正解  (1318 − 48) / (152 + 16) = 7 列   ← 与原版 CSS `auto-fill` 一致
///   旧实现 (1318 − 0) / (148 + 12) = 8 列   ← 每张卡窄 12px，整行错位
/// ```
///
/// ★★ 2026-10 二次修正：上面那一改只做了一半。
///
/// [Layout.columnsForBand] 的入参是**内容带宽度**（**没**减过内边距 ——
/// 减内边距是在它内部做的），而本函数的入参是**已经减过**的本区可用宽。
/// 两者差一个「两侧内边距」（48）。
///
/// 顺带把 640px 断点、`auto-fill` 的 152/112 列宽下限、`--poster-gap` 间距
/// 一起对齐（该函数的全宽度表已逐值验证过）。
///
/// ⚠️ 传入的必须仍是**本区可用宽度**（`LayoutBuilder` 的 `maxWidth`），
///    不是整窗宽度 —— 本页可能被放进比窗口窄的容器里（见 `_ContinueList`）。
int followGridColumns(double availableWidth) =>
    Layout.columnsForBand(availableWidth);

/// 把「本区可用宽」（= 轨道宽 − 两侧内边距，即 LayoutBuilder 的 maxWidth）
/// 还原成 [Layout.columnsForBand] / [Layout.gapFor] 要的**内容带宽度**。
///
/// ★★ 为什么需要它（2026-10 二次修正）
///
/// 外层 Padding 用的是 Layout.contentInsetOf ⇒ LayoutBuilder 拿到的
/// maxWidth **已经减过一次内边距**，而 [Layout.columnsForBand] /
/// [Layout.gapFor] 的入参是**没减过**的内容带宽度，内部还会再减一次。
/// 少加回这 48 会让窗口在 1400px 附近**少算一列**：
/// ```text
/// 1400px 窗口：本区可用宽 = 1400 − 48 = 1352
///   正解    (1400 − 48 + 16) / (152 + 16) = 1368 / 168 = 8.14 → 8 列
///   只改一半 (1352 + 16) / (152 + 16) = 1320 / 168 = 7.85 → 7 列 ✗
/// ```
double _followBandFor(BuildContext context, double availableWidth) =>
    availableWidth + Layout.contentPaddingOf(context) * 2;

/// 卡片网格的 `childAspectRatio`（三个 tab 共用）
///
/// ★★ 2026-10-03：标题从**一行**改成**两行**（对齐原版）。
///    原版 `base.css:844-854` 的 `.poster-meta__title` 逐字写着
///    `-webkit-line-clamp: 2` + 注释 `/* 固定两行：标题长短不一时卡片仍对齐 */`，
///    而 headless Chrome 实测该元素盒高 **40.41px**（16px × 1.35 行高，两行）。
///    原先这里只留了**单行**（`+ 44`）⇒ 长标题被压成省略号，与原版观感不符。
///
/// 算式（`posterMetaHeight` 的构成，见 `tokens.dart`）：
/// ```text
/// 海报              148 / (2/3)  = 222.0
/// 标题区（titleLines: 2）          =  65.6   ← posterMetaOther 22.4 + 21.6×2
///                                 ───────
///                                  287.6
/// childAspectRatio = 148 / 287.6 ≈ 0.5146
/// ```
/// ⚠️ 三个 tab 必须用**同一个** aspect —— 否则历史卡片会比追更的高/矮，
///    滚动时"每行错位"，看起来就是没对齐。
/// ⚠️ 骨架屏（`_FollowSkeleton`）必须用**同一个**函数 —— 否则骨架→内容跳高。
double followGridAspect() =>
    AppMetrics.posterWidth /
    (AppMetrics.posterWidth / AppMetrics.posterAspect +
        AppMetrics.posterMetaHeight(titleLines: 2));

/// 继续观看（历史）—— **卡片网格**（task-65 从"一行一个"改过来）
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 改之前是什么样（Owner 原话：「太占用空间了」）
/// ═══════════════════════════════════════════════════════════════════════
///
/// ```dart
/// Column(children: [
///   for (final p in list)
///     Container(   // ← 整宽，一行一个
///       child: Row([封面 60, 标题/进度, ▶]),
///     ),
/// ])
/// ```
/// ⇒ 每条记录占**一整行**（宽 ~1200px），而它只用了左边 ~300px
///   ⇒ 右边 900px 全是空的，一屏只看得到 3-4 条。
///
/// ⇒ 现在改成与 `_FavGrid` **同一套几何**（列数 / aspect 都走共享函数），
///   一屏能看十几条，且三个 tab 视觉一致。
///
/// # ★ 保留的行为（一个都不能丢）
///
/// ```text
/// 封面          仍有（网格里的 AspectRatio(2/3)）
/// 标题          仍有
/// 进度条        仍有（贴在封面**底部**，位置与原来一致）
/// 第N集 · 剩M分钟  仍有（作为副标题）
/// onTap         ★ 仍然是 `onTap(p)` ⇒ `_openDetailForProgress` ⇒ **进详情页**
///                 ⚠️ 不许改成"直接播放" —— Owner 明确要求过：
///                 > 最近追更 最近收藏 播放历史 点进去都应该进 详情页,而不是播放页
/// ```
class _ContinueList extends StatelessWidget {
  const _ContinueList({
    required this.list,
    required this.remaining,
    required this.onTap,
  });

  final List<Progress> list;
  final String Function(Progress) remaining;
  final void Function(Progress) onTap;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return const _EmptyBlock(
        icon: Icons.history,
        title: '还没有观看记录',
        desc: '开始播放后，这里会出现可以继续观看的内容',
      );
    }

    return Padding(
      // ★ 窄屏收一档（16）、宽屏 24 —— 与原版 `.container` 的 640px 断点一致
      padding: Layout.contentInsetOf(context),
      child: LayoutBuilder(
        builder: (ctx, c) {
          /*
           * ★ 用 `LayoutBuilder` 的 `maxWidth`（**本区可用宽度**）算列数，
           *   不用 `MediaQuery.size.width`（窗口宽度）。
           *
           * 理由与 task-60 同源：本页可能被放进比窗口窄的容器里
           * （首页的「我的」版块、或将来任何嵌入用法）——
           * 那时窗口宽度会**算多列**，卡片被挤到溢出。
           * `LayoutBuilder` 拿的是父级真正给的约束，永远对。
           *
           * ⚠️ 但它给的是**已减过外层内边距**的宽，而 Layout 的入参是
           *    **没减过**的内容带宽度 ⇒ 先经 _followBandFor 加回去。
           */
          final cols = followGridColumns(_followBandFor(context, c.maxWidth));
          /*
           * ★ 列间距也按**本区宽度**分档：宽档 16（对齐原版 `--poster-gap`），
           *   ≤640 窄档 12（`Sp.x3`）—— 原版 `base.css:1026-1031` 那个断点
           *   换的不只是列宽下限，间距也一起收了一档。
           */
          final gap = Layout.gapFor(_followBandFor(context, c.maxWidth));
          return GridView.builder(
            clipBehavior: Clip.antiAlias,
            // 与外层 `ListView` 共存：自己不滚，高度由内容决定
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: gap,
              mainAxisSpacing: Sp.x6,
              childAspectRatio: followGridAspect(),
            ),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final p = list[i];
              return _ContinueCard(
                progress: p,
                remaining: remaining(p),
                onTap: () => onTap(p),
                /*
                 * ★ task-74⑤：把**本格实际宽度**交给卡片，让它按真实显示尺寸解码封面。
                 *
                 * 算式与 `SliverGridDelegateWithFixedCrossAxisCount` 内部逐字同源：
                 *   可用宽 = 总宽 − 间距 × (列数 − 1)，单格宽 = 可用宽 / 列数。
                 * `c.maxWidth` 已经是**减过外层 `contentPadding`** 的本区宽
                 * （`Padding` 在 `LayoutBuilder` 外面）⇒ 这里**不再**减 contentPadding，
                 * 否则会算窄（封面解码尺寸偏小 ⇒ 糊）。
                 */
                coverWidth: (c.maxWidth - gap * (cols - 1)) / cols,
              );
            },
          );
        },
      ),
    );
  }
}

/// 「继续观看」的一张卡（几何与 `PosterCard` 一致，多了**进度条**）
///
/// ⚠️ 单独一个组件而不是塞进 `PosterCard`：`PosterCard` 吃的是
///    `title/cover/subtitle`（领域无关），而这里要画 `percent` 进度条。
///    给 `PosterCard` 加一个"进度"参数会让它认识 `Progress` ——
///    破坏它"不认识任何平台/模型"的定位（见该文件头注释）。
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.progress,
    required this.remaining,
    required this.onTap,
    required this.coverWidth,
  });

  final Progress progress;
  final String remaining;
  final VoidCallback onTap;

  /// ★ task-74⑤：封面**实际显示宽度**（逻辑像素），由 `_ContinueList` 的
  /// `LayoutBuilder` 算好传下来。
  ///
  /// ⚠️ 必须**传下来**而不是在这里新加 `LayoutBuilder`：
  ///    本页的列数与间距由外层 grid delegate 决定，卡片自己拿不到
  ///    "我被分到多宽"（`AspectRatio` 只约束比例、不告诉你宽度）。
  ///    自己套一个 `LayoutBuilder` 也能拿到，但会多一层布局节点，
  ///    且 `provider_grid_responsive_test.dart:604-616` 那类断言钉着
  ///    "同族网格里 `LayoutBuilder(` 恰好 1 个"的约定。
  final double coverWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final p = progress;

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 封面 + 进度条 ──
          AspectRatio(
            aspectRatio: AppMetrics.posterAspect,
            child: ClipRRect(
              borderRadius: Radii.rMd,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 占位底色 —— 前景色 5%（task-37，与 poster_card 同一口径）
                  Container(
                    color: colors.onSurface
                        .withValues(alpha: AppColors.posterPlaceholderAlpha),
                  ),
                  /*
                   * ══════════════════════════════════════════════════════
                   * ★★★ 封面区占位 —— 空标题**不画 '?'**（task-63 的收口）
                   * ══════════════════════════════════════════════════════
                   *
                   * 改之前：
                   * ```dart
                   * p.title.isEmpty ? '?' : p.title.characters.first
                   * ```
                   * Owner 原话：
                   * > 播放记录多了几个 显示 ？ 的记录，没有封面没有名字
                   *
                   * ★ 与 `poster_card.dart` 的处理**逐字同款**（那边 task-63 已改）：
                   * ```text
                   * 标题非空 ⇒ 首字占位（原版 `title.slice(0,1)` 的移植）
                   * 标题为空 ⇒ 中性图标 `Icons.movie_outlined`
                   * ```
                   *
                   * # 为什么"首字占位"在空标题下失效
                   * ```text
                   * 该策略的前提是"标题至少有一个字"。标题为空 ⇒ **没有首字可画**
                   * ⇒ 三种做法都不对：
                   *   · 什么都不画 ⇒ 看着像"图挂了"
                   *   · 随便画一个字 ⇒ **假装是数据**（用户更困惑）
                   *   · 画 '?'      ⇒ ★ UI 语义是"出错/未知"，而这里**没有出错**
                   * ⇒ 用**中性图形**：语言无关、不假装、不像 bug。
                   * ```
                   *
                   * ⚠️ 判据是 `p.title.isEmpty`（**原始** title），
                   *    不是 `progressDisplayTitle(p).isEmpty` ——
                   *    后者**永不返回空串**（空标题时给「（标题未知）」）
                   *    ⇒ 若用它当判据，图标分支**永远走不到**，
                   *      海报区会画「（」这个首字（因为占位串以全角括号开头）。
                   *    ★ 这正是"兜底函数"与"渲染判据"必须分开的原因。
                   */
                  if (p.cover != null && p.cover!.isNotEmpty)
                    coverImage(
                      context,
                      url: p.cover!,
                      layoutWidth: coverWidth,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    )
                  else
                    Center(
                      child: p.title.isEmpty
                          ? Icon(
                              Icons.movie_outlined,
                              size: FontSizes.display * 0.6,
                              color: colors.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                            )
                          : Text(
                              // 原版 `title.slice(0, 1)` —— 中文一个字就是完整的字
                              p.title.characters.first,
                              style: TextStyle(
                                fontSize: FontSizes.display * 0.6,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                    ),
                  // 进度条贴在封面**底部**（与改之前的位置一致）
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: p.percent / 100.0,
                      minHeight: 3,
                      backgroundColor: Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 标题 / 副标题（与 PosterCard 的排版一致）──
          const SizedBox(height: Sp.x2),
          /*
           * ★ task-63 收口（第 2 层：传参）：
           *   改之前是 `p.title` —— 空串会一路传到这里 ⇒ 卡片上**空白一行**
           *   （比「？」更让人困惑：用户不知道是没加载还是没数据）。
           *   ⇒ 走 `progressDisplayTitle`，**永不返回空串**。
           */
          Text(
            progressDisplayTitle(p),
            // ★ 与 PosterCard 的 titleLines: 2 同步 —— 两种卡片并排显示时
            //   标题行数不一致会看起来没对齐（原版两处都是 line-clamp: 2）
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeights.regular,
              color: colors.onSurface,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              /*
               * ★ 用 `progressDisplayEpisode` 而**不是** `p.episodeTitle ?? "单集"`：
               *   当标题为空、用 episodeTitle 兜底时，两者会是**同一句**
               *   ⇒ 卡片上出现两遍同样的字（"第01集" / "第01集"）。
               *   ★ 这是"加兜底"这个动作**自己引入**的新情况，必须一起处理。
               */
              '${progressDisplayEpisode(p)} · $remaining',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏 / 追更网格
class _FavGrid extends StatelessWidget {
  const _FavGrid({
    required this.list,
    required this.emptyTitle,
    required this.onOpen,
    this.remaining = const {},
  });

  final List<Favorite> list;
  final String emptyTitle;

  /// 点卡片 → 打开**详情页**（用户要求，不是播放页）
  final void Function(Favorite) onOpen;

  /// 每部剧「还剩几集没看」（key → 剩余数）—— task-40
  ///
  /// ★ 由 `FollowPageState` 用共享的 `followRemainingByKey` 算好传进来，
  ///   这里**不重复实现**算法（三处写三遍必然漂）。
  final Map<String, int> remaining;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return _EmptyBlock(
        icon: Icons.star_border,
        title: emptyTitle,
        desc: '在详情页点击收藏，即可在这里追踪更新',
      );
    }

    /*
     * ★ task-65：列数 / aspect 用**共享函数**（见 `followGridColumns`），
     *   且改用 `LayoutBuilder` 拿**本区可用宽度**。
     *
     * # 为什么从 `MediaQuery` 改成 `LayoutBuilder`（Lead 点名让我自己拍）
     *
     * 原写法 `MediaQuery.of(context).size.width` 拿的是**窗口**宽度。
     * 而本组件可能被放进比窗口窄的容器里（首页「我的」版块嵌入、
     * 或任何窄栏布局）⇒ 那时窗口宽度会**算多列** ⇒ 卡片被挤到溢出。
     *
     * ★ 与 task-60 那个坑**同源**（`SizedBox` 不重新界定 `MediaQuery`）。
     *   本任务的判据是"三 tab 视觉一致"，而列数算法不一致会直接破坏它
     *   —— 所以这里改是对的，不是"顺手多改"。
     *
     * ⚠️ 行为对**满宽窗口**完全不变：
     *    `LayoutBuilder.maxWidth` 在满宽时 == `MediaQuery.size.width`
     *    ⇒ 列数逐值相同（有测试断言）。
     */
    return Padding(
      // ★ 窄屏收一档（16）、宽屏 24 —— 与原版 `.container` 的 640px 断点一致
      padding: Layout.contentInsetOf(context),
      child: LayoutBuilder(
        builder: (ctx, c) => GridView.builder(
          clipBehavior: Clip.antiAlias,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount:
                followGridColumns(_followBandFor(context, c.maxWidth)),
            // ★ 宽档 16（原版 `--poster-gap`）/ 窄档 12 —— 与 `_ContinueList` 同源
            crossAxisSpacing:
                Layout.gapFor(_followBandFor(context, c.maxWidth)),
            mainAxisSpacing: Sp.x6,
            /*
             * ★ 2026-09-25：`+ 78` → `+ 44`（删掉卡片下的操作按钮后同步收回）
             *
             * 用户原话：
             * > 追更这里 下面的 这两个操作按钮很丑,直接删了吧
             *
             * # 那个 78 是干嘛的
             *
             * 它给「海报 + 标题 + 副标题」**之外**多留的高度 ——
             * 原先卡片下面还有一行 `_MiniButton`（追更铃铛 / 标记已读 /
             * 取消收藏），那行约占 78 − 44 = 34px。
             *
             * # 为什么删了按钮必须改这个数
             *
             * `childAspectRatio` 决定**每个格子多高**。按钮删了但格子
             * 还是原来那么高 → 每张卡下面空出 34px 的**纯留白**，
             * 一行 7 张就是一片空白（用户会以为"卡住了"）。
             *
             * # 为什么不再是 44
             *
             * 原来那句「`44` 是海报之外标题区的实测高度」是**单行**标题的
             * 高度。★★ 2026-10-03 起标题改成**两行**（对齐原版
             * `base.css:844-854` 的 `-webkit-line-clamp: 2`），
             * 标题区变成 `posterMetaHeight(titleLines: 2)` = 65.6。
             * ★ task-65 起这个算式提成 `followGridAspect()`，
             *   与历史 tab /骨架屏共用（否则卡片高矮不同、每行错位）。
             */
            childAspectRatio: followGridAspect(),
          ),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final f = list[i];
            return PosterCard(
              title: f.title,
              cover: f.cover,
              subtitle: f.lastEpisodeTitle,
              titleLines: 2,
              /*
               * ★★★ 卡片徽标 = **还剩几集没看**（task-40）
               *
               * 原来是 `f.unreadCount`（"自上次巡检后新增了几集"）——
               * 与用户要的语义**不同**：
               * ```text
               * 用户原话：
               * > 这几个都应该按照这个追更这个剧还有多少集没看来显示这个徽标，
               * > 比如 12集，只看了一集 就显示11，
               * > 以此类推，当往后看到12集则计数器为0，纠正一下这里的逻辑
               * ```
               * ★ 0 ⇒ `PosterCard` 内部 `unread > 0` 判据 ⇒ **徽标消失**
               *   （正是用户说的"看到12集则计数器为0"该有的表现）。
               */
              unread: remaining[f.key] ?? 0,
              /*
               * ★ 「追更中」角标**已删除**（2026-09-25 用户要求）
               *
               * 用户原话：
               * > 最近追更这里 下面不用显示 追更中 这三个字
               *
               * 原来这里是 `badge: f.following ? '追更中' : null`。
               *
               * ⚠️ 为什么直接删而**不是**「只在非追更时不显示」：
               *    这个列表本身就是「最近追更」——列表里的每一项**都是**
               *    追更中的，那个角标等于给每一项打同一个标签，
               *    没有任何区分度，纯占视觉空间。
               *
               * `PosterCard.badge` 这个参数**保留**（其它地方仍可能用，
               * 且删参数会波及组件契约），只是这里不再传。
               */
              onTap: () => onOpen(f),
            );
          },
        ),
      ),
    );
  }
}

/// ★★ `_MiniButton` —— **已删除**（2026-09-25）
///
/// # 为什么删
///
/// 用户原话：
/// > 追更这里 下面的 这两个操作按钮很丑,直接删了吧
///
/// 这个小组件原先只服务于卡片下那一行按钮（追更铃铛 / 标记已读 /
/// 取消收藏），三个调用点全在那一行里。整行删掉后它没有任何调用点。
///
/// ⚠️ **能力没有丢**，都搬到了详情页（`lib/ui/detail_page.dart`）：
/// ```text
/// 追更 / 取消追更   → 详情页的追更按钮（_toggleFollow，同样用 setFollowing）
/// 取消收藏         → 详情页的收藏按钮（_toggleFav）
/// 标记已读         → ★ 改成"打开详情页时自动清未读"
///                    （见 `_openDetailFor` 里的说明 —— 这是必要的补偿，
///                      否则红点永远消不掉）
/// ```
/// 所以这里删的是**一个 UI 组件**，不是一项能力。
///
/// ⚠️ 保留这段注释（而不是整块删掉不留痕）是为了让后来者能对上
///    "这行按钮去哪了"这个问题 —— 否则下一个代理会以为是自己看漏了。

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x16),
      child: Column(
        children: [
          Icon(
            icon,
            size: 56,
            color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: Sp.x4),
          Text(
            title,
            style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
            desc,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowSkeleton extends StatelessWidget {
  const _FollowSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      // ★ 与 `_ContinueList` / `_FavGrid` 逐字同一套内边距（640px 断点）
      padding: Layout.contentInsetOf(context),
      /*
       * ★★ 骨架的列数必须与**真实网格**逐值相同，否则"骨架 → 内容"
       *   淡入的那一帧卡片会整体跳位（本仓对这条最敏感，见 task-80）。
       *
       * ⚠️ 这里比 `_ContinueList` / `_FavGrid` **多**引入了一个
       *    `LayoutBuilder`：那两个在 `LayoutBuilder` 里，骨架在外面。
       *    ★ 2026-10-04 起内容带不再封顶（`band == 整窗宽`）⇒ 用 `MediaQuery`
       *    取整窗宽其实也**已经**等价了；保留 `LayoutBuilder` 是为了不动结构，
       *    且将来若恢复 1440 封顶它仍然正确（那时 `MediaQuery` 会算错列数）。
       */
      child: LayoutBuilder(
        builder: (ctx, c) => GridView.builder(
          clipBehavior: Clip.antiAlias,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount:
                followGridColumns(_followBandFor(context, c.maxWidth)),
            crossAxisSpacing:
                Layout.gapFor(_followBandFor(context, c.maxWidth)),
            mainAxisSpacing: Sp.x5,
            // ★ 必须与 followGridAspect() 逐值相同（否则骨架→内容卡跳位）
            childAspectRatio: followGridAspect(),
          ),
          itemCount: 8,
          itemBuilder: (_, __) => Column(
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
