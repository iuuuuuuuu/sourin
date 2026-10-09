// ═══════════════════════════════════════════════════════════════════════
//  搜索页 —— 对齐原版 SearchView.vue（400 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 跨 Provider 聚合搜索。
//
// # 关键设计：**错误隔离**
//
// 单个源失败不影响其他源的结果，且失败的源会明确列在下方
//（而非静默消失）。
//
// # ★★★ 流式搜索（Owner 的要求，2026-09-19）
//
// 原版注释：
// > 搜索页面,不应该等待所有源一起搜索完毕再显示出来,
// > **搜索结束一个就显示一个**,后面的往里面 push 就行了
//
// ```text
// 改之前:  [等 25 个源全部跑完，可能十几秒] → 一次性显示全部
// 改之后:  [0.5 秒] 出现第 1 个源的结果 → 用户已经能点了
//          [1.3 秒] 又冒出 3 个
//          [2.1 秒] 再 5 个 …
// ```
//
// # ★★ 三个容易写错的点（原版都踩过）
//
// ## ① 新搜索必须**取消**上一次
//
// 原版注释：
// > 用户连续改关键词时，旧的那次还在跑 —— 不取消的话旧结果会
// > **混进新结果里**（"幽灵结果"）。
//
// ## ② 立刻清空旧结果，而不是等第一个源回来再清
//
// 原版注释：
// > 否则用户改了关键词后，会先看到**旧关键词的结果**挂在那里，
// > 几秒后才被替换 —— 看起来像"搜索没生效"。
//
// ## ③ 骨架屏只在「一个源都还没回来」时显示
//
// 原版注释：
// > 改之前是无条件「只要还在搜就盖住全部结果」。
// > 但流式搜索下，**第一个源回来后就应该能看到内容**，
// > 如果骨架还盖着，用户仍然要等全部跑完才看得见 —— 白改了。
// > 所以条件收紧成：**正在搜 且 目前一个结果都没有**。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/ffi.dart';
import '../core/sourin_api.dart';
import '../core/title_match.dart';
import 'tokens.dart';
import 'widgets/fade_in_sliver.dart';
import 'widgets/poster_card.dart';

/// 一个命中源的结果组：(provider 标识, 源显示名, 该源返回的条目)
///
/// ★ 提成 typedef 是为了让**排序判据**能作为参数传递并被单独测试，
///   而不是把 record 字面量散落在 build 与回调里。
typedef SearchHitGroup = ({
  String provider,
  String name,
  List<MediaItem> items,
});

/// ★★ 按**匹配度**给整组排序（task-73 的核心判据）
///
/// # 判据
/// ```text
/// 组的分数 = 组内**最高**分（`bestTitleScore`）
/// 降序；**同分保持到达顺序**（稳定排序）
/// ```
///
/// # 为什么用组内最高分而不是平均分
///
/// 一个源返回 30 条时通常只有 1~2 条是用户要的，取平均会让
/// 「准确命中了 1 条、其余是噪声」的这种**最准的源**排到后面。
/// 详见 `lib/core/title_match.dart` 的 `bestTitleScore`。
///
/// # 为什么排序判据要提成**顶层函数**
///
/// `_hits` 的重排在 widget 测试里没有 FFI 就走不到（见 `debugBeginSearch`），
/// 而排序规则本身是纯逻辑 ⇒ 提出来可以直接喂输入断言输出。
/// ★ 但**只有这个函数被测是不够的**（那是"测了个没人用的东西"）——
///   所以另有 `debugFeedHit` 让真 widget 树走**同一条代码路径**
///   （`_addHit`），用 `tester.getRect` 读坐标断言渲染顺序。
List<SearchHitGroup> rankHitGroups(
  String keyword,
  List<SearchHitGroup> groups,
) =>
    stableRankDesc(groups, (g) => bestTitleScore(keyword, g.items));

/// 搜索页
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.onOpenDetail,
    this.isTv = false,
  });

  /// 点结果卡片 → 详情页
  ///
  /// ⚠️ 与首页一致：**必须跳详情页**而非直接开播放器，
  ///    否则多集内容无法选集、多源内容无法换源。
  final void Function(String provider, String id)? onOpenDetail;

  final bool isTv;

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// 搜索框那层 `Container` 的 GlobalKey
  ///
  /// ★ task-74：搜索框现在住在 `SliverPersistentHeader` 里，而
  ///   `SliverPersistentHeaderDelegate.build()` 在**滚动过程中会被反复调用**
  ///   （`shrinkOffset` 每帧都在变），每次都返回一棵新子树。
  ///
  ///   没有显式 key 时，Flutter 靠 runtimeType 相同 + 位置稳定复用 Element
  ///   —— `TextField` 内部的 `EditableTextState`（光标、选区、输入法组合态）
  ///   **通常**能保住。这里是把这个身份**显式化**，不再依赖"通常"。
  ///
  ///   ⚠️ 诚实说明：我**没有**在本次改动里复现出"不加 key 就丢状态"的现场。
  ///   加它的依据是本仓库已有的同款真实事故
  ///   （`lib/ui/home_page.dart:752-769`：`SliverPersistentHeader` 里
  ///     `SourceBar` 的 `ScrollController` 被重建 ⇒ 用户滚到第 10 个源，
  ///     一滚动全跳回第 1 个），代价为零而收益是消除一类隐患。
  final _searchBoxKey = GlobalKey();

  bool _searching = false;
  bool _searched = false;

  /// 命中的源：(provider, providerName, items)
  ///
  /// ★ 顺序 = **匹配度降序**（不是到达顺序）—— 见 `rankHitGroups`。
  List<SearchHitGroup> _hits = [];

  /// 被跳过的源：(provider, reason)
  List<({String provider, String reason})> _skipped = [];

  /// 已搜完的源数（用于"已搜 12/25 个源"的进度提示）
  ///
  /// 流式搜索下，用户能实时看到"还在搜，已经搜了 12 个"，
  /// 而不是干等一个转圈 —— 这是流畅感的关键。
  int _settled = 0;
  int _totalProviders = 0;

  /// 当前这次搜索的关键词
  ///
  /// ★ task-73 ⑤：排序判据是 `titleSimilarity(keyword, item.title)`，
  ///   所以关键词必须能到达**处理事件的代码**（`_addHit`）。
  ///   它原来是 `_doSearch()` 的**局部变量** —— 局部变量到不了那里。
  ///
  /// ⚠️ 为什么**不能**改在渲染时才排序：
  ///   用户改了关键词后，**上一次搜索的延迟结果仍会到达**
  ///   （`_cancelCurrent()` 实际取消不掉 —— `_currentToken` 从来没被
  ///     赋成真实 token，见 `_doSearch` 的说明）。
  ///   若在渲染时排序，那些旧结果会被**新关键词**打分 —— 顺序更乱。
  ///   ⇒ 一律在**收到事件的那一刻**用**当时那个关键词**算分并固化。
  String _lastKeyword = '';

  /// 当前这次搜索的 token（用于取消）
  ///
  /// ⚠️ 用户连续改关键词时，旧的那次还在跑 ——
  ///    不取消的话旧结果会**混进新结果里**（"幽灵结果"）。
  int? _currentToken;

  @override
  void initState() {
    super.initState();
    _loadProviderCount();
  }

  @override
  void dispose() {
    // 离开页面时取消 —— 别让搜索在后台白跑
    _cancelCurrent();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadProviderCount() async {
    try {
      final providers = await SourinApi.listProviders();
      final enabled = providers.where((p) => p.enabled).length;
      if (mounted) setState(() => _totalProviders = enabled);
    } catch (e) {
      debugPrint('[SEARCH] 取源数失败: $e');
    }
  }

  void _cancelCurrent() {
    final t = _currentToken;
    if (t != null) {
      SourinCore.cancelStream(t);
      _currentToken = null;
    }
  }

  Future<void> _doSearch() async {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;

    // ★ 取消上一次（否则旧源的延迟结果会追加到新列表里）
    _cancelCurrent();

    setState(() {
      _searching = true;
      _searched = true;
      _settled = 0;
      /*
       * ⚠️ 这里**立刻清空**结果，而不是等第一个源回来再清。
       *    否则用户改了关键词后，会先看到**旧关键词的结果**挂在那里，
       *    几秒后才被替换 —— 看起来像"搜索没生效"。
       */
      _hits = [];
      _skipped = [];
      // ★ 事件的打分基准 —— 必须在清空结果的同时定下来
      _lastKeyword = kw;
    });

    try {
      await SourinApi.searchAllStream(kw, (ev) {
        if (!mounted) return false;

        switch (ev.kind) {
          case SearchEventKind.hit:
            /*
             * ★ 每搜到一个源就追加 —— 这就是"搜完一个显示一个"的实现点
             *
             * ★ task-73：追加之后**按匹配度重排**（见 `_addHit`）。
             *
             * ⚠️ 关键词传的是**闭包捕获的 kw**，不是 `_lastKeyword` ——
             *    上一次搜索的延迟结果到达时，必须用**它自己那次**的
             *    关键词打分，否则会被新关键词错误地重排。
             */
            _addHit(kw, ev);

          case SearchEventKind.miss:
            setState(() {
              /*
               * ⚠️ reason 为空 = 搜到了但没结果，**不算"跳过"**
               *
               * 原版：`if (r.reason) { ... }`
               * 把"没结果"也列进"未能返回结果"会让用户以为源坏了。
               */
              if (ev.reason != null && ev.reason!.isNotEmpty) {
                _skipped = [
                  ..._skipped,
                  (provider: ev.provider, reason: ev.reason!),
                ];
              }
              _settled++;
            });

          case SearchEventKind.done:
          case SearchEventKind.error:
            // 这两个由 callStream 内部处理，不会走到这里
            break;
        }
        return true;
      });

      if (mounted) {
        setState(() {
          _searching = false;
          _currentToken = null;
        });
      }
    } catch (e) {
      debugPrint('[SEARCH] 搜索失败: $e');
      if (mounted) {
        setState(() {
          _searching = false;
          _currentToken = null;
        });
      }
    }
  }

  /// 收到**一个源**的命中结果：追加 + 按匹配度重排
  ///
  /// # ★★ 流式回填 vs 排序的取舍（task-73 ③ —— 这是**明确的**产品决策）
  ///
  /// ```text
  /// 选的是：**保留流式回填，并在每次回填后重排**
  ///
  /// 理由：流式是 Owner 2026-09-19 亲自提的要求（见文件头 L12-23 的原话）——
  ///       "搜索结束一个就显示一个"，实测首个结果 0.25 秒就到，
  ///       而非流式版要干等 37 秒。**为了排序而放弃流式是明显的倒退。**
  ///
  /// 代价（如实说明，不掩盖）：先到的组可能被后到的更匹配的组**挤下去**，
  ///       所以用户在搜索过程中会看到结果列表重排。
  ///
  /// 为什么这个代价可接受：
  ///   · 用户明确要求"匹配度高的排上面"——重排正是他要的效果
  ///   · 重排只发生在**新结果到达**时（不是每帧），一个源只触发一次
  ///   · 同分组用稳定排序 ⇒ 不会出现"两个同分的结果来回换位"的抖动
  ///   · 搜索通常在 1~3 秒内结束，之后顺序就稳定了
  ///
  /// ❌ 已考虑并否决的方案：先缓冲、等全部源返回再排序显示
  ///      （那会退回"干等 37 秒"的体验，Owner 已经为此提过一次意见）
  /// ```
  ///
  /// ⚠️ 用「新列表」而不是 `_hits.add(...)` —— 后者在某些情况下
  ///    不会触发重建（列表引用没变）。
  void _addHit(String keyword, SearchStreamEvent ev) {
    setState(() {
      _hits = rankHitGroups(keyword, [
        ..._hits,
        (
          provider: ev.provider,
          name: ev.providerName,
          /*
           * ★ 组内也排（task-73 ②）—— 与组间**同一套判据**。
           *
           * ⚠️ 用 `item.title` 算，**不是** `item.note`
           *    （`note` 是"全 27 集"这类副标题，与匹配度无关。
           *      卡片副标题显示的确实还是 note —— 那是对的，
           *      但**排序**不能用它）。
           */
          items: rankItemsByTitleDesc(keyword, ev.items),
        ),
      ]);
      _settled++;
    });
  }

  /// ★ 测试注入口（`@visibleForTesting`）：等于真实链路里
  /// `_doSearch()` 开头那段 setState 的效果（清空 + 记录关键词 + 进入结果态）。
  ///
  /// # 为什么必须有这个口子
  ///
  /// 真实结果来自 `SourinApi.searchAllStream()`（走 FFI 到 Rust 核心）。
  /// `flutter test` 里**没有核心 DLL** ⇒ 该调用必然抛异常
  /// （项目已知：`Failed to load dynamic library 'sourin_core.dll'`）
  /// ⇒ `_hits` 恒为空 ⇒ 所有"顺序"断言都变成对**空列表**的断言。
  ///
  /// ⚠️ 这正是铁律 149 的陷阱：**候选集为空时，全称断言恒真**
  ///    （"排对了"和"根本没数据"看起来一模一样）。
  ///
  /// ⚠️ 生产代码**永远不调用**这两个 debug 方法 ⇒ 行为不变。
  ///    本仓既有同款先例：`my_shelf.dart:253`、`skip_page.dart:92`、
  ///    `detail_page.dart:501`、`follow_page.dart:552`。
  @visibleForTesting
  void debugBeginSearch(String keyword) {
    setState(() {
      _searching = true;
      _searched = true;
      _settled = 0;
      _hits = [];
      _skipped = [];
      _lastKeyword = keyword;
    });
  }

  /// ★ 测试注入口：喂一个 `hit` 事件 —— 走的是**真实那条代码路径**
  /// （`_addHit`），不是测试里另写一份排序。
  @visibleForTesting
  void debugFeedHit(SearchStreamEvent ev) => _addHit(_lastKeyword, ev);

  /// ★ 测试注入口：等于 `_loadProviderCount()` **成功**时的效果。
  ///
  /// # 为什么单独开一个口子（而不是塞进 `debugBeginSearch`）
  ///
  /// 因为 `build` 里的分支顺序是：
  /// ```
  ///   if (_totalProviders == 0)       ← 先判这个
  ///     『当前没有支持搜索的内容源』
  ///   else if (_searching && _hits.isEmpty)
  ///     骨架
  ///   else if (_searched) … 结果 …
  /// ```
  /// ⇒ `_totalProviders == 0` 会**挡住整个结果区**：
  ///    一个源明明回来了、`_hits` 里也真有数据，
  ///    界面上却还是那句"没有支持搜索的内容源"。
  ///
  /// ⚠️ 而 `flutter test` 里 `listProviders()` 必然抛异常（无核心 DLL）⇒
  ///    `_totalProviders` 恒为 0 ⇒ 结果区**永远不渲染** ⇒
  ///    所有"顺序"断言都会退化成对空树的断言（铁律 149）。
  ///
  /// ⇒ 这个口子只补**环境前置条件**，不改任何渲染逻辑；
  ///    与 `debugBeginSearch` 各对应真实链路里的一段（`_doSearch` / `_loadProviderCount`）。
  @visibleForTesting
  void debugSetProviderCount(int n) {
    setState(() => _totalProviders = n);
  }

  void _clear() {
    _cancelCurrent();
    setState(() {
      _controller.clear();
      _hits = [];
      _skipped = [];
      _searched = false;
      _searching = false;
      _settled = 0;
      _lastKeyword = '';
    });
  }

  void _open(MediaItem item) {
    final i = item.id.indexOf(':');
    if (i < 0) return;
    widget.onOpenDetail?.call(
      item.id.substring(0, i),
      item.id.substring(i + 1),
    );
  }

  int get _totalResults =>
      _hits.fold(0, (n, h) => n + h.items.length);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★ 原版是「内容带 1440px 上限 + 居中」（`base.css:549-558` 的
     *   `.container { max-width: var(--content-max-w); margin: 0 auto }`）。
     *   ★ 2026-10-04（业主：改为两侧占满）起 [Layout.bandFor] 不再封顶
     *   ⇒ `Layout.sideInsetOf` **恒返回 0**，这一层现在是空操作。
     *
     * 为什么是**外层 `Padding`**：`RenderViewport.sizedByParent == true`
     * （SDK `rendering/viewport.dart:1676`）⇒ 视口取 `constraints.biggest`，
     * `Center` 传下来的 `maxWidth` 还是整窗宽 ⇒ 空操作；`Padding` 先把
     * `maxWidth` 减掉 `2*side` ⇒ 视口真的变窄（★ 现在 `side == 0`，
     * 逐字节等于改动前的树）。
     * ⚠️ `CustomScrollView` **没有** `padding` 参数，只能这样写。
     */
    return Padding(
      padding: Layout.sideInsetOf(context),
      child: CustomScrollView(
        clipBehavior: Clip.antiAlias,
        slivers: [
        // ── 页头 ──（随内容滚走）
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(
              top: Sp.x8,
              // ★ 窄屏收一档（16）—— 与原版 `.container` 的 640px 断点一致
              left: Layout.contentPaddingOf(context),
              right: Layout.contentPaddingOf(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '搜索',
                  style: TextStyle(
                    fontSize: FontSizes.xl,
                    fontWeight: FontWeights.semibold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  '同时搜索全部已启用内容源',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── 搜索框 ──（★ pinned：滚到哪都留在视口顶）
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickySearchBar(
            minExtent: _searchBarHeight,
            maxExtent: _searchBarHeight + AppMetrics.homeTopPadding,
            background: colors.surface,
            child: Padding(
              padding: Layout.contentInsetOf(context),
              child: Container(
                key: _searchBoxKey,
                padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: Radii.rLg,
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        // ★ TV / 键盘唯一的入口：没有它遥控器永远进不了输入框
                        //  （`_searchBoxKey` 只用来 ensureVisible 滚动，不管焦点）
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _doSearch(),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: '输入片名、剧名或关键词…',
                          border: InputBorder.none,
                        ),
                        style: const TextStyle(fontSize: FontSizes.base),
                      ),
                    ),
                    if (_controller.text.isNotEmpty)
                      IconButton(
                        onPressed: _clear,
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: '清空',
                      ),
                    const SizedBox(width: Sp.x1),
                    FilledButton(
                      onPressed:
                          (_searching || _controller.text.trim().isEmpty)
                              ? null
                              : _doSearch,
                      child: Text(_searching ? '搜索中…' : '搜索'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: Sp.x6)),

        // ── 无可搜索源 ──
        if (_totalProviders == 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: Layout.contentInsetOf(context),
              child: Container(
                padding: const EdgeInsets.all(Sp.x4),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: Radii.rLg,
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 17, color: colors.onSurfaceVariant),
                    const SizedBox(width: Sp.x3),
                    Expanded(
                      child: Text(
                        '当前没有支持搜索的内容源（央视官方无公开搜索接口）',
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )

        // ── ★★ 骨架只在「一个源都还没回来」时显示 ──
        else if (_searching && _hits.isEmpty)
          const SliverToBoxAdapter(child: _SearchSkeleton())

        // ── 结果 ──
        //
        // ★ task-80：骨架 → 内容 的淡入（与首页 `home_page.dart` 同款）
        //
        // ## 为什么只包**内容侧**，不包骨架侧
        //
        // 骨架屏是**立刻反馈** —— 它的职责是马上告诉用户"在加载了"。
        // 给它加 200ms 淡入等于**延迟反馈**，与它存在的目的相反。
        // 该淡入的是**取代它的内容**（首页也是这么做的）。
        //
        // ## 为什么是 `FadeInSliver` 而不是 `AnimatedOpacity`
        //
        // 这里是**首次挂载**（初值 == 目标值）⇒ `AnimatedOpacity` 要等
        // "目标值变化"才补间 ⇒ **不会播**。`FadeInSliver` 内部的
        // `TweenAnimationBuilder` 首帧就开始补间 ⇒ 天然"出现"动画。
        //
        // ⚠️ 而且它包的是 **sliver 版**（`SliverFadeTransition`）——
        //    换成盒模型的 `Opacity` 就得套 `SliverToBoxAdapter`，
        //    那会把整个 `SliverList` 变成盒模型孩子 ⇒ **丢掉懒加载**。
        //
        // ## Reduce Motion
        //
        // `FadeInSliver` 内部走 `MotionPrefs.duration` ⇒ 系统关掉动画时
        // duration 变 `Duration.zero`，**第 0 帧就到位**（不播）。
        else if (_searched)
          FadeInSliver(
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                /*
                 * 「没找到」只在**搜索全部结束**后才下结论
                 *
                 * ⚠️ 如果一有结果就判空，搜索刚开始（还没源回来）就会
                 *    闪一下"没有找到相关内容" —— 那是误报。
                 */
                if (_totalResults == 0 && !_searching)
                  const _NoResult()
                else if (_totalResults > 0) ...[
                  for (final h in _hits) _ResultGroup(group: h, onOpen: _open),

                  // ★ 还在搜：底部显示进度
                  if (_searching)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sp.x8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: Sp.x3),
                          Text(
                            '还在搜索…（已搜 $_settled'
                            '${_totalProviders > 0 ? "/$_totalProviders" : ""} 个源）',
                            style: TextStyle(
                              fontSize: FontSizes.sm,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],

                // ★ 被跳过的源：明确告知，不静默失败
                if (_skipped.isNotEmpty) _SkippedList(skipped: _skipped),
              ]),
            ),
          )

        // ── 未搜索：空态引导（对齐 SearchView.vue 的 `未搜索` 分支）──
        //
        // ⚠：`slivers:` 里只能放 Sliver。这里用
        //    `SliverToBoxAdapter` 包一个普通 Box widget（同 `_NoResult`）。
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.x16),
              child: Column(
                children: [
                  Icon(
                    Icons.search,
                    size: 56,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: Sp.x4),
                  Text(
                    '搜索全部内容源',
                    style: TextStyle(
                      fontSize: FontSizes.base,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  Text(
                    '输入关键词后回车即可同时搜索',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // ── 底部让位（悬浮底栏盖在所有路由之上）──
        //
        // ⚠️ 这里**不能**加 `const`：`Sp.bottomBarInset` 是 getter
        //    （`Device.isTv ? 110 : 90`，见 `lib/ui/tokens.dart:73`），
        //    不是编译期常量 ⇒ `const SliverToBoxAdapter(...)` 会报
        //    `invalid_constant`。同款写法见 `settings_sub_page.dart:275`。
        SliverToBoxAdapter(child: SizedBox(height: Sp.bottomBarInset)),
      ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ task-74：搜索框吸顶条
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（m04668）：
// > 搜索页面,搜索框固定在上面,下面内容区域滚动
//
// # 为什么用 `SliverPersistentHeader(pinned: true)` 而不是自己监听滚动偏移
//
// 与 `lib/ui/widgets/settings_sub_page.dart:220-227` 的结论同源（照抄既有惯用法）：
// ```text
// ① Flutter 的**惯用法**（用户说"参考 github 开源项目"）
// ② pinned 的语义就是"滚到哪都留在视口顶" —— 正是用户要的
// ③ 比"监听滚动偏移 + AnimatedPositioned 自己摆"稳：
//    后者要与滚动物理/回弹/焦点滚动打架，本项目已有 `spatial_nav`
//    的 `ensureVisible` 与滚轮互相干扰的前例（task-3）
// ```
// `ListView` 的所有子项是平级的，没有一个能"钉住"；
// `CustomScrollView` 的子项是 sliver，而 `SliverPersistentHeader` 正是
// Flutter 里对应 CSS `position: sticky` 的东西
// （同款改造见 `lib/ui/home_page.dart:565-594` 的源条吸附）。

/// 搜索框吸顶条的**吸顶高度**（= 搜索框自身的高度）
///
/// ★ 实测值，不是估的：探针 `.probe/probe_tests/t75_measure_probe_test.dart`
///   在视口 1400×900 下量得搜索框那个 `Container` 高 **50**
///   —— `TextField` / `FilledButton` 各 48（高度由主题决定）+ 上下各 1px 边框。
///
/// ⚠️ `SliverPersistentHeader` 给子件的是**紧约束**：子件高度不等于 extent
///   就会报 `RenderFlex overflowed`。所以这个数字必须与真实高度一致 ——
///   `test/t75_search_pinned_test.dart` 会渲染整页并滚动，溢出会直接让测试变红。
const double _searchBarHeight = 50;

/// 搜索框的吸顶条
class _StickySearchBar extends SliverPersistentHeaderDelegate {
  const _StickySearchBar({
    required this.minExtent,
    required this.maxExtent,
    required this.background,
    required this.child,
  });

  /// 吸顶后的高度（= 搜索框自身高度）
  @override
  final double minExtent;

  /// 未滚动时的展开高度（= 吸顶高度 + [AppMetrics.homeTopPadding]）
  @override
  final double maxExtent;

  /// ★★ pinned 条**必须不透明**
  ///
  /// 它 pinned 在顶部、内容从**它下面**滚过 —— 若透明，
  /// 结果卡片会与搜索框叠在一起。用 `colors.surface`
  /// （与页面底色同源，见 `lib/ui/app_theme.dart:350`：浅色下
  /// `surface = LightTokens.bgBase = #EEF0F6`）。
  ///
  /// ⚠️ 不要拿搜索框**自身**那层
  ///    `surfaceContainerHighest.withValues(alpha: 0.35)` 当条背景：
  ///    那是框内填充（设计的一部分，保留），但它透光 ——
  ///    滚动时内容会从框外那 [AppMetrics.homeTopPadding] 里透出来。
  ///
  /// ⚠️ 也不要用 `FTheme.colors.background` —— forui 的
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
     * `maxExtent - shrinkOffset` 随滚动从 maxExtent 递减到 minExtent；
     * 多出来的那截（= homeTopPadding）通过 padTop 还给子件 ⇒
     * 展开时顶距 20、吸顶后收到 0，且子件**始终**是 minExtent 高。
     *
     * ★ 这与 `settings_sub_page.dart` 的 `_StickyBackBar` 是同一套算法
     *   （那里是"返回条 + 大标题收起"，这里是"搜索框 + 顶距收起"）。
     */
    final h = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    final padTop = ((maxExtent - shrinkOffset) - minExtent)
        .clamp(0.0, maxExtent - minExtent);
    return Container(
      height: h,
      color: background,
      padding: EdgeInsets.only(top: padTop),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_StickySearchBar old) =>
      old.minExtent != minExtent ||
      old.maxExtent != maxExtent ||
      old.background != background ||
      old.child != child;
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({required this.group, required this.onOpen});

  final SearchHitGroup group;
  final void Function(MediaItem) onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★ 列数与间距都与**真实网格**同源（`Layout`）—— 等价原版
     *   `base.css:1020-1024` 的
     *   `repeat(auto-fill, minmax(calc(var(--poster-w) - 16px), 1fr))`。
     *
     * 旧写法 `(w - 48) / 160` 到 2560px 宽的屏幕上仍是 12 列（列数被上限截住、
     * 单张被拉到 ~198px = 原版 160px 的 1.24 倍：`(2560-48-11×12)/12`）；
     * 现在同一个 2560px 由 Layout 算：inner = 2560−48 = 2512，
     * cols = min(⌊(2512+16)/(152+16)⌋, 12) = min(15, 12) = **12**，
     * cell = (2512−16×11)/12 = **194.67** —— 与 t493 探针实测逐值相同
     * (`page=browse size=2560x1440 cols=12 cell=194.67 gap=16.00 left=24.00 span=2512.00`，Layout 同源)。
     *
     * ⚠️ 入参是**内容带宽度**（`bandFor(窗口宽)`，★ 2026-10-04 起恒等于窗口宽）
     *    —— 减左右内边距那一步在 `Layout` 里只做一次（task-74⑤ 那个双重相减的坑）。
     */
    final band = Layout.bandFor(MediaQuery.sizeOf(context).width);
    final cols = Layout.columnsForBand(band);

    return Padding(
      padding: EdgeInsets.only(bottom: Sp.bottomBarInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: Layout.contentInsetOf(context),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  group.name,
                  style: TextStyle(
                    /*
                     * ★★★ 2026-10-09（Owner 第 12 条「文字大小/粗细不一致」）
                     *     这里原本是 `FontSizes.base`(16)，已统一为 `lg`(20)。
                     * ```text
                     * 判据（同语义同刻度，不是审美偏好）：
                     *   本行与本页 home 首页的 rail 标题（home_page.dart:1069）
                     *   是**同一个视觉角色**——「一屏里可重复出现的区块标题」，
                     *   且两处除字号外的三个属性**逐项相同**：
                     *     home_page.dart:1069  lg + w600 + colors.onSurface
                     *     search_page.dart:850  base + w600 + colors.onSurface
                     *   ⇒ 只有字号漂移过，属于需要修的「不一致」。
                     *   同类区块标题（设置页:2439 / 我的片库 / 快捷键 / 字幕面板）
                     *   全体都是 lg ⇒ 这一处是唯一的例外。
                     * ```
                     * ⚠️ 这是**已裁决的统一**（lead 已独立核实两处源码），
                     *    不要因为「搜索页字小一点更紧凑」再把它改回 base ——
                     *    那会让同角色刻度再次分裂。
                     */
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  '${group.items.length} 个结果',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x4),
          Padding(
            padding: Layout.contentInsetOf(context),
            child: GridView.builder(
              clipBehavior: Clip.antiAlias,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                // ★ 宽档 16（原版 `--poster-gap`）/ 窄档 12，与列数同源
                crossAxisSpacing: Layout.gapFor(band),
                mainAxisSpacing: Sp.x5,
                // 高度 = 海报高 + 标题两行（原版 base.css:844-854 固定两行）
                childAspectRatio: AppMetrics.posterWidth /
                    (AppMetrics.posterWidth /
                        AppMetrics.posterAspect +
                        AppMetrics.posterMetaHeight(titleLines: 2)),
              ),
              itemCount: group.items.length,
              itemBuilder: (_, i) => PosterCard(
                title: group.items[i].title,
                cover: group.items[i].cover,
                subtitle: group.items[i].note,
                titleLines: 2,
                onTap: () => onOpen(group.items[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkippedList extends StatelessWidget {
  const _SkippedList({required this.skipped});

  final List<({String provider, String reason})> skipped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: Layout.contentInsetOf(context),
      child: Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: Radii.rLg,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: colors.error),
                const SizedBox(width: Sp.x2),
                Text(
                  '${skipped.length} 个源未能返回结果',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.x3),
            for (final s in skipped)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Text(
                      s.provider,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Text(
                        '· ${s.reason}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoResult extends StatelessWidget {
  const _NoResult();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x16),
      child: Column(
        children: [
          Icon(
            Icons.search_off,
            size: 56,
            color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: Sp.x4),
          Text(
            '没有找到相关内容',
            style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '换个关键词试试，或检查是否已启用对应内容源',
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

class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Sp.bottomBarInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: Layout.contentInsetOf(context),
                  child: Container(
                    width: 110,
                    height: 18,
                    decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                const SizedBox(height: Sp.x4),
                SizedBox(
                  // 与结果网格逐值相同（否则骨架→内容跳高）
                  height: AppMetrics.railHeight(titleLines: 2),
                  child: ListView.separated(
                    clipBehavior: Clip.antiAlias,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: Layout.contentInsetOf(context),
                    itemCount: 6,
                    separatorBuilder: (_, __) => const SizedBox(width: Sp.x3),
                    itemBuilder: (_, __) => Container(
                      width: AppMetrics.posterWidth,
                      decoration: BoxDecoration(
                        color: colors.onSurface.withValues(alpha: 0.05),
                        borderRadius: Radii.rMd,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
