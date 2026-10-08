// ═══════════════════════════════════════════════════════════════════════
//  分类 / 榜单浏览页 —— 对齐原版 BrowseView.vue（201 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 完全数据驱动：Provider 提供分类或榜单，页面渲染网格。接新站无需改动。
//
// # 两种模式（原版由 query 决定，这里用构造参数）
//
// ```text
// categoryId 有值  → 分类列表 → get_list
// rankId     有值  → 榜单内容 → get_rank
// ```
//
// # ★ 为什么复用同一个页面而不是各写一个
//
// 原版注释：
// > 两者除了取数接口不同，**交互完全一致**（网格 + 分页加载 + 空态），
// > 分开写只会让改一处要改两遍。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/models.dart' as models;
import '../core/sourin_api.dart';
import 'tokens.dart';
import 'widgets/fade_in_sliver.dart';
import 'widgets/poster_card.dart';

/// 浏览页（分类 / 榜单）
class BrowsePage extends StatefulWidget {
  const BrowsePage({
    super.key,
    required this.provider,
    this.categoryId = '',
    this.rankId = '',
    this.title = '浏览',
    this.onOpenDetail,
    this.isTv = false,
    this.pageLoaderForTest,
  });

  final String provider;

  /// 分类 id（与 [rankId] 二选一）
  final String categoryId;

  /// 榜单 id（与 [categoryId] 二选一）
  final String rankId;

  final String title;

  /// 点卡片 → 详情页
  ///
  /// ⚠️ 必须跳详情页而非直接开播放器（原版注释）：
  /// > 否则多集内容无法选集、多源内容无法换源。
  final void Function(String provider, String id)? onOpenDetail;

  final bool isTv;

  /// ★ 测试注入口：预置取页函数，**在 `_init()` 之前就位**
  ///
  /// # 为什么必须是构造参数（而不是挂载后再注入）
  ///
  /// 本页在 `initState` 里就 `addPostFrameCallback((_) => _init())` ——
  /// 也就是**第 1 帧结束时**就开始取第 1 页了。而 `tester.pumpWidget()`
  /// 恰好会把第 1 帧跑完（含 post-frame 回调）才返回 ⇒ 等测试拿到
  /// `BrowsePageState` 再调 `debugSetPageLoader`，第 1 页**早就用真 FFI
  /// 取过了**（且必然抛错）⇒ `_items` 恒为空 ⇒ 所有"触底会不会自动翻页"
  /// 的断言都退化成对**空树**的断言。
  ///
  /// 本仓既有同款先例：`skip_page.dart:92 initialMarkersForTest`、
  /// `live_embedded_player.dart:456`。生产代码**永远不传**它
  /// （调用点只有 `shell.dart` 的 `_openBrowse`）⇒ 传 null 时行为与改前逐字相同。
  final Future<models.Page<MediaItem>> Function(int page)? pageLoaderForTest;

  @override
  State<BrowsePage> createState() => BrowsePageState();
}

/// ★ 公开（不是 `_BrowsePageState`）—— 与本仓 `SearchPageState` /
///   `FollowPageState` / `LivePageState` 一致：测试与探针要能
///   `tester.state<BrowsePageState>(find.byType(BrowsePage))` 拿到它，
///   才能验证「触底自动加载」和「页头吸顶」这两条需求。
class BrowsePageState extends State<BrowsePage> {
  List<Category> _categories = [];
  List<MediaItem> _items = [];
  int _page = 1;
  int? _pageCount;
  bool _loading = true;
  bool _loadingMore = false;

  /// 当前分类 id（可被分类切换改变）
  late String _categoryId = widget.categoryId;

  /// 当前标题（切分类时跟着变）
  late String _title = widget.title;

  /// 榜单模式：只有一个数据源，不需要分类切换栏
  bool get _isRankMode => widget.rankId.isNotEmpty;

  /// 滚动控制器 —— 触底**自动**加载下一页（task-75 需求①）
  ///
  /// # 为什么用 `ScrollController` 而不是 `NotificationListener`
  ///
  /// `NotificationListener<ScrollNotification>` 会收到**所有**后代的滚动
  /// 通知 —— 包括分类栏那个**横向** `ListView`。横滑一下分类栏就会
  /// 冒泡出一个 `ScrollUpdateNotification`，被当成"网格触底"。
  /// 靠 `metrics.axis == Axis.vertical && depth == 0` 能挡住，但那是
  /// **又多一处能写错的地方**；`ScrollController` 只挂在下面这一个
  /// `CustomScrollView` 上，天生不需要过滤。
  final _scrollController = ScrollController();

  /// 触底判据的**提前量**（px）
  ///
  /// 不等到 `extentAfter == 0`（真的贴到最底）才发请求 —— 那样用户会
  /// 盯着一段空白等。提前约两行（实测每行 ≈318px @1280 宽 7 列：
  /// 卡片 165.7 宽 ÷ 宽高比 0.5564 + 间距 20）就把下一页发出去，
  /// 滚到底时数据通常已经回来了。
  ///
  /// ⚠️ 这个数**只影响"早多久开始取"**，不影响正确性：取回来的页
  ///    总是拼在列表尾部，早取晚取结果一样。
  static const double _loadMoreAhead = 600;

  /// 视口补取的**轮数上限**（防御性兜底，不是常规路径）
  ///
  /// # 为什么还要一个计数器
  ///
  /// [`_fillViewportIfNeeded`] 的 `grew` 判据已经挡住了"空页死循环"，
  /// 但它挡不住另一种：**上游每次都返回同样多的条目、页号却不前进**
  /// （`page` 恒为 1 ⇒ `_page` 不增 ⇒ `_hasMore` 恒真 ⇒ 每轮都"grew"
  /// ⇒ 无限取下去）。这是上游的病，不该由 UI 层静默地转到天荒地老。
  /// 给一个足够宽松的上限（[`_viewportFillBudgetMax`] 轮），
  /// 到顶就**留下 debugPrint** 并停下。
  ///
  /// ⚠️ 只约束"**视口没填满时的自动补取**"这一条路径，
  ///    **不**限制用户滚动触发的正常翻页 —— 那条路径没有预算概念。
  int _viewportFillBudget = _viewportFillBudgetMax;

  /// 视口补取轮数上限：6 轮 × 每页 20 条 = 120 条。
  /// 一屏最多也就几十条，正常源 1~2 轮就填满了。
  static const int _viewportFillBudgetMax = 6;

  /// 取数**代次** —— 每换一次分类就 +1
  ///
  /// # ⚠️ 为什么必须有（自动加载把它从"理论竞态"变成"常态竞态"）
  ///
  /// 自动加载意味着"第 2 页还在飞、用户已经点了别的分类"是**常见**路径。
  /// 迟到的那一页会把**旧分类**的条目 `[..._items, ...page.items]`
  /// 拼到**新分类**的列表上 —— 列表里混进上一个分类的片子。
  /// 换分类时 `_gen++`，[`_load`] 回来时对不上就把结果丢掉。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    /*
     * ★ 测试注入口必须在**这里**生效，不能等测试挂载后再调
     *   `debugSetPageLoader` —— `_init()` 挂在 post-frame 回调上，
     *   而 `pumpWidget()` 会把第 1 帧（含 post-frame 回调）跑完才返回。
     */
    _pageLoaderOverride = widget.pageLoaderForTest;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// 滚动回调：接近底部就再取一页
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter > _loadMoreAhead) return;
    _maybeLoadMore();
  }

  /// 还有下一页就再取一页 —— **自动加载的唯一入口**
  ///
  /// 三处会调它（滚动触底 / 视口没填满 / 分类栏切完），所以闸门写在这里，
  /// 而不是散在各个调用点上：
  /// ```text
  /// _loading     第 1 页正在取   ⇒ 再取会把第 2 页拼到"还没被替换"的旧列表上
  /// _loadingMore 下一页正在取    ⇒ 再取会取到**同一页**（`_page + 1` 没变）
  /// !_hasMore    已经到底了      ⇒ 再取是白跑一趟网络
  /// ```
  void _maybeLoadMore() {
    if (!mounted || _loading || _loadingMore || !_hasMore) return;
    unawaited(_load(_page + 1));
  }

  /// 取完一页后量一次：**视口都没被填满**就再取一页
  ///
  /// # ⚠️ 为什么必须有（"去掉按钮"引入的新问题）
  ///
  /// 「加载更多」按钮还在时，内容不满一屏只是"按钮挂在最下面"。
  /// 换成触底自动加载之后：**内容不满一屏 ⇒ 页面根本没法滚动 ⇒
  /// 滚动回调永远不触发 ⇒ 永远取不到第 2 页**，用户被卡在第 1 页。
  /// 每页 20 条时必现：1920 宽下 12 列 = 2 行 ≈636px，填不满 1080 高的窗口。
  /// ⇒ 每页取完量一次 `maxScrollExtent`，还是 0 就再取。
  ///
  /// ⚠️ 只在**上一页真的带回了条目**时才继续往下走 —— 否则上游返回空页时
  ///    这里就是死循环（空页不增加内容 ⇒ `maxScrollExtent` 恒为 0 ⇒
  ///    无限发请求）。
  void _fillViewportIfNeeded(bool grew) {
    if (!grew) return;
    if (_viewportFillBudget <= 0) {
      /*
       * ★ 兜底闸：见 [`_viewportFillBudget`]。
       * 正常情况**永远走不到这里** —— 真的走到就是上游行为异常，
       * 必须留下痕迹而不是静默停住（否则看起来就是"加载卡住了"）。
       */
      debugPrint('[BROWSE] 视口补取已达上限（$_viewportFillBudgetMax 轮）'
          '，停止自动补取；_page=$_page _hasMore=$_hasMore');
      return;
    }
    _viewportFillBudget--;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent > 0) return;
      _maybeLoadMore();
    });
  }

  Future<void> _init() async {
    if (widget.provider.isEmpty) {
      // 原版：`router.replace("/")` —— 没有源就回首页
      if (mounted) Navigator.of(context).maybePop();
      return;
    }

    // 榜单模式下不拉分类（它没有分类概念）
    if (!_isRankMode) {
      try {
        final c = await SourinApi.getCategories(widget.provider);
        if (mounted) setState(() => _categories = c);
      } catch (_) {
        // 原版：`catch {}` —— 无分类不影响列表
        debugPrint('[BROWSE] 取分类失败（不影响列表）');
      }
    }
    await _load(1);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _load(int p) async {
    if (p == 1) {
      if (mounted) setState(() => _loading = true);
    } else {
      if (mounted) setState(() => _loadingMore = true);
    }

    // ★ 记下本次请求属于哪一代（见 [`_gen`] 的注释）
    final gen = _gen;
    // ★ 本次是否真的**新增**了条目 —— 决定要不要再量一次视口
    var grew = false;

    try {
      final page = _pageLoaderOverride != null
          ? await _pageLoaderOverride!(p)
          : _isRankMode
              ? await SourinApi.getRank(widget.provider, widget.rankId, page: p)
              : await SourinApi.getList(widget.provider, _categoryId, page: p);

      if (!mounted) return;
      /*
       * ★★★ 代次对不上 ⇒ 用户在等这一页的时候换了分类，**把结果丢掉**。
       *
       * 不丢的话：这一页是**旧分类**的第 N 页，会被拼到**新分类**的列表
       * 尾部 ⇒ 列表里混进上一个分类的片子，而且 `_page` / `_pageCount`
       * 会被旧分类的值覆盖，后续分页全错。
       */
      if (gen != _gen) {
        debugPrint('[BROWSE] 丢弃过期的一页（第 $p 页，代次 $gen ≠ $_gen）');
        return;
      }
      setState(() {
        // 原版：`p === 1 ? res.items : [...items, ...res.items]`
        _items = p == 1 ? page.items : [..._items, ...page.items];
        _page = page.page;
        _pageCount = page.pageCount;
        grew = page.items.isNotEmpty;
      });
      _fillViewportIfNeeded(grew);
    } catch (e) {
      debugPrint('[BROWSE] 加载列表失败: $e');
    } finally {
      if (mounted && gen == _gen) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _switchCategory(Category c) async {
    setState(() {
      _categoryId = c.id;
      _title = c.name;
      /*
       * ★ 换分类 = 换一代（见 [`_gen`] 的注释）。
       *
       * 必须**同时**把分页状态清干净 —— 否则旧分类的 `_page` / `_pageCount`
       * 还留着，`_load(1)` 回来之前若有滚动事件，[`_maybeLoadMore`] 会拿
       * **旧分类的页号**去请求新分类（`_hasMore` 此时也是旧分类的答案）。
       */
      _gen++;
      _page = 1;
      _pageCount = null;
      _loadingMore = false;
      /*
       * ★★ `_loading = true` 必须在**这里**就置位，不能等 [`_load`] 去置。
       *
       * 下面那句 `jumpTo(0)` 会**同步**触发 `_onScroll`（`jumpTo` 走
       * `forcePixels` ⇒ `notifyListeners`）。此刻 `_page` 已经是 1、
       * `_pageCount` 已经是 null、`_loadingMore` 已经被清掉，而
       * `_load(1)` 还没被调用 ⇒ `_loading` 仍是 false
       * ⇒ [`_maybeLoadMore`] 的闸门全开 ⇒ 会抢在 `_load(1)` **之前**
       * 发出 `_load(2)`，也就是**新分类的第 2 页比第 1 页先发**。
       *
       * 后果：第 2 页先回来时 `_items` 还是旧分类的 20 条，会被拼成
       * 40 条；第 1 页再回来直接覆盖掉。用户看到的是"换了分类却还是
       * 旧内容"，或者新分类里混进一页来路不明的数据。
       */
      _loading = true;
      // 新分类要重新有机会把视口填满（预算只约束"没填满时的补取"）
      _viewportFillBudget = _viewportFillBudgetMax;
    });
    // 换分类后回到顶部 —— 不跳的话用户停在第 5 页的高度上看新分类的第 1 页
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _load(1);
  }

  /// 是否还有下一页
  ///
  /// ⚠️ `pageCount == null` 时**返回 true** —— 很多源不返回总页数，
  ///    这时不能判定"到底了"，得让用户继续点。
  ///    （原版 `hasMore()` 就是这个语义。）
  bool get _hasMore => _pageCount == null || _page < _pageCount!;

  // ══════════════════════════════════════════════════════════════════════
  //  测试注入口（task-75）
  //
  //  `flutter test` 里 `sourin_core.dll` **必然加载失败** ⇒ `getList` 必抛
  //  ⇒ `_items` 恒为空 ⇒ 所有"滚动触底会不会自动取下一页"的断言都会
  //  退化成对**空树**的断言（铁律 149）。本仓既有同款口子：
  //  `search_page.dart:392 debugSetProviderCount`（补环境前置条件，
  //  不改渲染逻辑）、`follow_page.dart:612 debugSetContinueList`。
  //
  //  ⚠️ 这里替换的是**取数那一步**（= 真实链路里 `SourinApi.getList`
  //     那一次调用），**不是**替换 `_load` —— 代次检查、列表拼接、
  //     视口补取、`_page`/`_pageCount` 更新全都还是生产那份代码在跑。
  //     否则测的就是"影子实现"了。
  //
  //  ⚠️ 生产路径既不设置它、也不依赖它（默认 null ⇒ 走 FFI）。
  // ══════════════════════════════════════════════════════════════════════

  /// 测试用：替代 FFI 的取页函数（`null` = 恢复走真实 FFI）
  ///
  /// ⚠️ 类型写 `models.Page` 而不是 `Page`：`material_ui`（经
  ///    `navigator.dart`）也导出一个 `Page`，不加前缀就是
  ///    `ambiguous_import`（实测 analyze 报错）。
  Future<models.Page<MediaItem>> Function(int page)? _pageLoaderOverride;

  @visibleForTesting
  void debugSetPageLoader(
    Future<models.Page<MediaItem>> Function(int page)? loader,
  ) {
    _pageLoaderOverride = loader;
  }

  /// 测试用：替代 `getCategories` 的分类注入
  @visibleForTesting
  void debugSetCategories(List<Category> cats) {
    setState(() => _categories = cats);
  }

  /// 测试用：直接触发一次「取下一页」（不经过滚动）
  ///
  /// 走的是与滚动回调**同一个** [`_maybeLoadMore`] ⇒ 闸门语义一致。
  @visibleForTesting
  Future<void> debugLoadMore() async => _maybeLoadMore();

  /// 测试用：观测点（只读）
  @visibleForTesting
  int get debugPage => _page;

  @visibleForTesting
  int get debugItemCount => _items.length;

  @visibleForTesting
  List<MediaItem> get debugItems => List.unmodifiable(_items);

  @visibleForTesting
  bool get debugLoadingMore => _loadingMore;

  @visibleForTesting
  bool get debugHasMore => _hasMore;

  @visibleForTesting
  ScrollController get debugScrollController => _scrollController;

  void _open(MediaItem item) {
    final i = item.id.indexOf(':');
    if (i < 0) return;
    /*
     * 与首页/搜索一致：**不直接开播放器**，而是跳详情页
     *
     * 原版注释：
     * > 必须跳详情页而非直接开播放器，否则多集内容无法选集、
     * > 多源内容无法换源。
     */
    widget.onOpenDetail?.call(
      item.id.substring(0, i),
      item.id.substring(i + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        /*
         * ★★ 原版是「内容带 1440px 上限 + 居中」，对齐 `base.css:549-558`：
         *    `.container { width:100%; max-width:var(--content-max-w);
         *                 margin:0 auto; padding:0 var(--sp-6) }`
         *    ★ 2026-10-04（业主：改为两侧占满）起 [Layout.bandFor] 不再封顶
         *    ⇒ `Layout.sideInsetOf` **恒返回 0**，这一层现在是空操作（但调用点保留）。
         *
         * # 为什么是**外层 `Padding`** 而不是 `Center`/`ConstrainedBox`
         * `RenderViewport.sizedByParent == true`（SDK `rendering/viewport.dart:1676`）
         * ⇒ 视口取 `constraints.biggest`；`Center` 传下来的 `maxWidth` 还是整窗宽
         * ⇒ 纯空操作。`Padding` 会先把 `maxWidth` 减掉 `2*side` 再传下去
         * ⇒ 视口真的变窄 ✓（★ 现在 `side == 0`，与改动前逐字节相同）。
         *
         * ⚠️ `CustomScrollView` **没有** `padding` 参数，只能这样写。
         */
        child: Padding(
          padding: Layout.sideInsetOf(context),
          child: CustomScrollView(
            clipBehavior: Clip.antiAlias,
            // ★ 触底自动加载的落点（见 [`_onScroll`]）——
            //   必须是**唯一**挂这个 controller 的滚动体。
            controller: _scrollController,
          slivers: [
            /*
             * ── 顶部：返回 + 标题（★ 吸顶，不随内容滚走）──
             *
             * ★ task-75 需求②（Owner 原话）：
             * > 返回按钮不要随这页面消失,往下滑固定在上面
             *
             * # 为什么必须钉住（不只是"好看"）
             *
             * 与 `lib/ui/widgets/settings_sub_page.dart:331-340` 同一条硬约束：
             * ```text
             * 本项目自绘标题栏（`_TitleBarHost`）**没有返回按钮**，
             * 页内这个 `<` 是唯一的返回入口。
             * ⇒ 它一滚走，用户滚到第 10 行之后就**出不去这一页**了
             *   （只能按 Alt+← 或 Esc，普通用户不知道）。
             * ```
             * ⚠️ 这也是为什么它不能做成"滚动时淡出"之类的效果 ——
             *    返回入口在任何滚动位置都必须在。
             *
             * # 为什么用 `SliverPersistentHeader(pinned: true)`
             *
             * 与 `lib/ui/search_page.dart:648-661` / `home_page.dart:643-652`
             * 同源（照抄既有惯用法，不自己监听滚动偏移）：
             * ```text
             * ① Flutter 的惯用法：`CustomScrollView` 的子项是 sliver，
             *    而 `SliverPersistentHeader` 正是对应 CSS `position: sticky`
             *    的东西 —— `ListView` 的子项平级，没有一个能"钉住"
             * ② pinned 的语义就是"滚到哪都留在视口顶" —— 正是要的
             * ③ 比"监听滚动偏移 + AnimatedPositioned 自己摆"稳：
             *    后者要与滚动物理/回弹/焦点滚动打架（本项目已有
             *    `spatial_nav` 的 `ensureVisible` 与滚轮互相干扰的前例）
             * ```
             */
            SliverPersistentHeader(
              pinned: true,
              delegate: _StickyHeaderBar(
                minExtent: _headerMinExtent,
                maxExtent: _headerMaxExtent,
                background: colors.surface,
                child: _header(context),
              ),
            ),

            // ── 分类切换 ──
            if (_categories.isNotEmpty && !_isRankMode)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 40,
                  child: ListView.separated(
                    clipBehavior: Clip.antiAlias,
                    scrollDirection: Axis.horizontal,
                    padding: Layout.contentInsetOf(context),
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: Sp.x2),
                    itemBuilder: (context, i) {
                      final c = _categories[i];
                      final active = c.id == _categoryId;
                      return Center(
                        child: InkWell(
                          onTap: () => _switchCategory(c),
                          borderRadius: Radii.rFull,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Sp.x4,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: active
                                  ? colors.primary.withValues(alpha: 0.16)
                                  : Colors.transparent,
                              borderRadius: Radii.rFull,
                              border: Border.all(
                                color: active
                                    ? colors.primary
                                    : colors.outlineVariant,
                              ),
                            ),
                            child: Text(
                              c.name,
                              style: TextStyle(
                                fontSize: FontSizes.sm,
                                fontWeight:
                                    active ? FontWeight.w600 : FontWeight.w400,
                                color: active
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: Sp.x5)),

            // ── 骨架 ──
            if (_loading)
              SliverPadding(
                // ⚠️ 不能是 `const`：内边距要按当前内容带宽度算
                //    （★ 2026-10-04 起不再封顶 ⇒ 居中偏移恒 0，只有断点内边距）
                padding: Layout.contentInsetOf(context),
                sliver: const _SkeletonGrid(),
              )

            // ── 空态 ──
            //
            // ★ task-80：骨架 → 内容 的淡入（完整理由见 `search_page.dart`
            //   结果分支上方那段同款注释）
            else if (_items.isEmpty)
              const FadeInSliver(
                sliver: SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyBlock(
                    icon: Icons.movie_outlined,
                    title: '这个分类暂无内容',
                  ),
                ),
              )

            // ── 网格 ──
            else ...[
              FadeInSliver(
                sliver: SliverPadding(
                  padding: Layout.contentInsetOf(context),
                  sliver: SliverGrid(
                    gridDelegate: _gridDelegate(context),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => PosterCard(
                        title: _items[i].title,
                        cover: _items[i].cover,
                        subtitle: _items[i].note,
                        titleLines: 2,
                        onTap: () => _open(_items[i]),
                      ),
                      childCount: _items.length,
                    ),
                  ),
                ),
              ),

              // ── 底部：自动加载指示 / 到底了 ──
              //
              // ★ task-75 需求①（Owner 原话）：
              // > 触底加载更多,不要 加载更多  按钮
              //
              // 触发的**唯一**入口是 [`_maybeLoadMore`]（滚动回调 + 填满视口
              // 补取 + 换分类后补取都汇到那里）。这里只负责**画状态**：
              // ```text
              // _loadingMore  → 转圈（"正在取下一页"）
              // !_hasMore     → 「已经到底了」
              // 其余           → 什么都不画（等滚动把它带进视野）
              // ```
              // ⚠️ 这里**不能**再挂一个"进入视野就取下一页"的探针 ——
              //    它会与 [`_maybeLoadMore`] 各发一次请求，同一页取两遍
              //    （`_loadingMore` 闸门挡不住：两次调用可能在同一帧内
              //    都还没走到 `setState`）。
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.x10),
                  child: Center(
                    child: _loadingMore
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : _hasMore
                            ? const SizedBox.shrink()
                            : Text(
                                '已经到底了',
                                style: TextStyle(
                                  fontSize: FontSizes.sm,
                                  color: colors.onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                  ),
                ),
              ),
            ],
          ],
          ),
        ),
      ),
    );
  }

  /// 网格列数 —— 等价原版 `base.css:1020-1024`：
  /// `grid-template-columns: repeat(auto-fill, minmax(calc(var(--poster-w) - 16px), 1fr))`
  ///
  /// # ★ 为什么不写死 148 当"每列宽"
  /// 原版用的是 **`auto-fill` + `minmax(152px, 1fr)`**：列宽**下限** 152，
  /// 实际宽度由剩余空间等分（会被 `1fr` 拉大）。旧写法
  /// `usable / (posterWidth + Sp.x3)` 用的是**下限**当除数、又拿
  /// `clamp(2, 12)` 封顶 ⇒ 2560px 宽的屏幕上每行只有 12 张、
  /// 单张被拉到 `(2560-48-11*12)/12 ≈ 194.67px`（比原版的 160px 大 21.7%）。
  /// ⇒ 换成语义等价的 `Layout.columnsForBand`（0 不符，W=200..4000 全表已验）。
  ///
  /// ⚠️ 入参必须是**内容带宽度**（`Layout.bandFor(窗口宽)`，
  ///    ★ 2026-10-04 起恒等于窗口宽），
  ///    减左右内边距这一步在它内部**只做一次**。
  SliverGridDelegate _gridDelegate(BuildContext context) {
    final band = Layout.bandFor(MediaQuery.sizeOf(context).width);
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: Layout.columnsForBand(band),
      crossAxisSpacing: Layout.gapFor(band),
      mainAxisSpacing: Sp.x5,
      // 高度 = 海报高 + 标题两行（原版 base.css:844-854 固定两行）
      childAspectRatio: AppMetrics.posterWidth /
          (AppMetrics.posterWidth /
              AppMetrics.posterAspect +
              AppMetrics.posterMetaHeight(titleLines: 2)),
    );
  }

  /// 页头内容（返回 + 标题）—— **只有横向内边距**
  ///
  /// ⚠️ 纵向的内边距**归 [`_StickyHeaderBar`] 管**（它要用 `padTop`
  ///    把顶部呼吸随滚动收掉）。这里若再写一遍纵向 padding，
  ///    吸顶时就是"两层 32px"，子件会被挤出紧约束 ⇒ `RenderFlex overflowed`。
  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: Layout.contentInsetOf(context),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.chevron_left),
            tooltip: '返回',
          ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.xl,
                fontWeight: FontWeights.semibold,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页头吸顶条的**吸顶高度**（= 返回按钮那一行的高度 + 底部呼吸）
///
/// ★ 实测值，不是估的：`test/t75_browse_autoload_test.dart` 渲染整页并
///   量 `RenderBox.size.height`。`IconButton` 在 forui/material 主题下的
///   自然高度由主题决定（`iconSize` + `padding`，且受 `tapTargetSize`
///   影响）—— 猜错就是 `RenderFlex overflowed`（紧约束），所以必须量。
///
/// ⚠️ `SliverPersistentHeader` 给子件的是**紧约束**：子件高度不等于
///    `extent` 就会报溢出。`t75` 那条测试会渲染并滚动整页，
///    溢出直接让它变红 —— 这个数字**有守卫**。
const double _headerMinExtent = 48 + Sp.x5;

/// 未滚动时的展开高度 = 吸顶高度 + 顶部呼吸 [Sp.x8]
///
/// ★ 与改造前**逐像素一致**：原来那个 `SliverToBoxAdapter` 用的是
///   `EdgeInsets.fromLTRB(contentPadding, Sp.x8, contentPadding, Sp.x5)`
///   ⇒ 静止时总高 = `Sp.x8 + 48 + Sp.x5` = 32 + 48 + 20 = 100，
///   正是这个值。所以这次改造**只改滚动行为，不改静止时的观感**。
const double _headerMaxExtent = _headerMinExtent + Sp.x8;

/// 「返回 + 标题」吸顶条的 delegate（task-75 需求②）
///
/// # 为什么单独一个类
/// 与 `lib/ui/widgets/settings_sub_page.dart:384-451` 的 `_StickyBackBar`、
/// `lib/ui/search_page.dart:674-741` 的 `_StickySearchBar` 同源：
/// `SliverPersistentHeader` 要一个 `SliverPersistentHeaderDelegate`，
/// 内联匿名类会让 `shouldRebuild` 无从比较。
class _StickyHeaderBar extends SliverPersistentHeaderDelegate {
  _StickyHeaderBar({
    required this.minExtent,
    required this.maxExtent,
    required this.background,
    required this.child,
  });

  @override
  final double minExtent;

  @override
  final double maxExtent;

  /// 条的**不透明**底色
  ///
  /// ★★ 必须不透明：它 pinned 在顶部、内容从**它下面**滚过 ——
  ///    若透明，海报卡会与返回按钮叠在一起。
  ///    用 `colors.surface`（与页面底色同源；浅色下 = `#EEF0F6`，
  ///    见 `lib/ui/app_theme.dart:350`）。
  ///    ⚠️ 不要用 `FTheme.colors.background` —— forui 的
  ///    `neutral.light.background` 是**纯白 #FFFFFF**，会白叠白
  ///    （见 `lib/ui/app_theme.dart:191-196`）。
  final Color background;

  final Widget child;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    /*
     * 与 `_StickySearchBar.build`（`lib/ui/search_page.dart:724-732`）
     * 逐字同一套算法：
     * ```text
     * maxExtent - shrinkOffset 随滚动从 maxExtent 递减到 minExtent；
     * 多出来的那截（= 顶部呼吸）通过 padTop 还给子件
     * ⇒ 展开时顶距 32、吸顶后收到 0，且子件**始终**是 minExtent 高。
     * ```
     * clamp 是**防御性**的：若将来 Flutter 改了 `shrinkOffset` 的语义，
     * 也不会算出负高度（负高度直接抛异常，比视觉错更糟）。
     */
    final h = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    final padTop = ((maxExtent - shrinkOffset) - minExtent)
        .clamp(0.0, maxExtent - minExtent);
    return Container(
      height: h,
      color: background,
      // ★ 底部呼吸固定留 [Sp.x5]（它不参与收缩，否则吸顶后标题贴边）
      padding: EdgeInsets.only(top: padTop, bottom: Sp.x5),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _StickyHeaderBar old) =>
      old.minExtent != minExtent ||
      old.maxExtent != maxExtent ||
      old.background != background ||
      old.child != child;
}

/// 网格骨架
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 与 [_gridDelegate] 同源：骨架的列数/间距必须与真实网格**逐值相同**，
    //   否则"骨架 → 内容"淡入时卡片会跳位（原版对这条最敏感）。
    final band = Layout.bandFor(MediaQuery.sizeOf(context).width);

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: Layout.columnsForBand(band),
        crossAxisSpacing: Layout.gapFor(band),
        mainAxisSpacing: Sp.x5,
        // ★ 必须与 _gridDelegate 逐值相同，否则骨架→内容卡片跳位
        childAspectRatio: AppMetrics.posterWidth /
            (AppMetrics.posterWidth /
                AppMetrics.posterAspect +
                AppMetrics.posterMetaHeight(titleLines: 2)),
      ),
      delegate: SliverChildBuilderDelegate(
        (_, __) => Column(
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
        childCount: 18,
      ),
    );
  }
}

/// 空态
class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
          ],
        ),
      ),
    );
  }
}


