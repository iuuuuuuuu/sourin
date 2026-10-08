// ═══════════════════════════════════════════════════════════════════════
//  响应式卡片网格 + 拖动排序（用户要求「一行多个」「根据宽度动态处理」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（2026-09-25）
//
// ```text
// 1.区块合并对了,但是不要一个一行
// 3.js插件还没改成一行多个的显示(根据宽度动态处理显示)
// ```
//
// 「不要一个一行」= 26 张源卡片原来**竖着排 26 行**，一屏只看得到 4~5 个，
// 要滚很久。要的是**一行放多个**，且列数**跟着宽度变**。
//
// # 为什么不直接用现成的组件（逐个查过，不是懒得用）
//
// ```text
// ① ReorderableListView
//    Flutter 内置，但它**只有单列** —— 它的构造函数就没有
//    crossAxisCount / gridDelegate 之类的参数。这正是本次要解决的问题。
//
// ② SliverReorderableGrid
//    网上常见的推荐。但**这个 Flutter 版本（3.47）里没有** ——
//    实测 `flutter/packages/flutter/lib/src/widgets/` 下只有
//    `reorderable_list.dart`，没有 grid 版（grep 结果为空）。
//    所以"用内置的 SliverReorderableGrid"这条路走不通。
//
// ③ reorderable_grid_view 包（2.2.8）
//    能装（pub 解析通过）。**但它的 item 尺寸来自 `SliverGridDelegate`**
//    —— 网格布局的本质就是"每行高度统一、由 delegate 决定"，
//    而本页的卡片**高度是会变的**：
//    ```text
//    卡片内嵌 ProxyPanel + ProviderLoginPanel（集成任务 M 的成果）
//    代理已配置 / 登录已失效时它们会**自动展开**（见 proxy_panel._load）
//    → 同一张卡在 146px 与 580px 之间变化（实测，见下）
//    ```
//    固定行高的网格会**把展开的面板裁掉**（或强行留空白）。
//    而"配置和登录合并进卡片"是用户明确要求过的成果，不能为了网格牺牲它。
//    另外它是个第三方包，用户对加依赖的要求是"必须有用" ——
//    在能自己写 40 行解决、且效果更好的情况下，不值得引入。
//
// ④ GridView / SliverGrid
//    同上：**必须有固定的 mainAxisExtent**（或按 aspectRatio 反算），
//    同样会裁掉展开的面板。而且它们**自带滚动**，
//    嵌进外层 ListView 时要 shrinkWrap，网格算全部卡片高度很贵。
// ```
//
// # 所以自己搭：`LayoutBuilder` + 按行切块 + `Row(stretch)`
//
// 这与原版的 CSS **逐条对应**（原版 `.plug__list`）：
//
// ```css
// /* SettingsView.vue:4522 —— 宽屏才变网格 */
// @media (min-width: 1200px) {
//   .plug__list {
//     display: grid;
//     grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
//     gap: var(--sp-2);
//   }
// }
// ```
//
// ```text
// repeat(auto-fill, minmax(400px, 1fr))
//   → 「每列至少 400px，能塞几列就塞几列，剩下的宽度平分」
//   → 我们的 columns = floor((可用宽 + 间距) / (400 + 间距))
//
// align-items: stretch（CSS grid 默认）
//   → 「同一行里所有卡片等高（跟着最高的那个）」
//   → 我们的 Row(crossAxisAlignment: CrossAxisAlignment.stretch)
// ```
//
// # ★ 400 这个数字不是抄来的，是**量出来的**
//
// `minmax(400px, 1fr)` 里的 400 在原版是"排版经验值"（原版注释：
// 「用 `minmax(400px, 1fr)` 后：1316px 视口 → 3 列，每列约 430px
// ✅ 标题单行」）。我们这边**实测了溢出阈值**（真核心 + 隔离数据目录）：
//
// ```text
// 窗口宽   卡片宽   RenderFlex 溢出
// 400      352      26 处 ★ 溢出
// 428      380      51 处 ★ 溢出
// 448      400      0     ✓ 刚好不溢出
// 468      420      0     ✓
// ```
// → **卡片的最小可用宽度就是 400px**，与原版的经验值**正好吻合**。
//   所以 `minItemWidth = 400` 不是"照抄一个魔法数字"，而是同一个结论。
//
// # 三个排序路径一个都不少
//
// ```text
// ① 拖动        → 本文件的 Draggable(把手) + DragTarget(每个格子)
// ② 卡片 ↑↓     → `_ProviderCard._actions` 的按钮（不经本文件）
// ③ 排序面板    → 「调整顺序」按钮 → `_OrderDialog`（不经本文件）
// ```
//
// ⚠️ ① 原先是 `ReorderableListView` + `ReorderableDragStartListener`。
//    换成网格后**必须换机制** —— `ReorderableDragStartListener` 只能
//    在 `ReorderableListView` 的子树里工作（它靠 `SliverReorderableList`
//    的 InheritedWidget 找祖先）。所以把手改成 `Draggable`，
//    落点用 `DragTarget`。语义完全一致（拖到第 j 格 = 移到第 j 位）。
//
// ⚠️ **不做自动滚动**：拖动时把卡片拖到屏幕外不会自动滚（那要自己写
//    边缘检测 + 定时器）。原版也没有。长距离移动有另外两条路径 ——
//    ↑↓ 按钮连点、排序面板一次到位（见 `settings_page._moveProviderBy`
//    的注释：「26 个源里把第 25 个挪到第 3 个，拖动要跨 22 张卡，
//    按钮连点反而更可控」）。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart' show Sp, FontSizes, FontWeights;

/// 卡片所在列的**最小宽度**（网格用它决定列数）
///
/// # ★ 400 → 290：用户 2026-09-25 要求「尺寸还是太大了，再缩小点，一行还可以多占一个」
///
/// ```text
/// 用户原话：
/// > js插件这个尺寸还是太大了,在缩小点,一行我觉得还可以多占一个
///
/// 上一轮：1280 窗口可用宽 1232 → min=400 时 floor(1244/412) = **3 列**（每列 402.67px）
/// 这一轮：min=290 时                 floor(1244/302) = **4 列**（每列 299px）  ✓ 用户要的
/// ```
///
/// ## 为什么是 290 这个数（**倒推**出来的，不是试出来的）
///
/// 目标是「1280 下 4 列」，反解：
/// ```text
/// columnsFor(1232) >= 4
///   ⇔ floor((1232 + 12) / (min + 12)) >= 4
///   ⇔ (1244) / (min + 12) >= 4
///   ⇔ min + 12 <= 311
///   ⇔ min <= 299
/// 取 290（留 9px 余量，避免字体/主题差异把列数挤回 3）
/// ```
///
/// ## ★ 290 **不等于**「卡片能塞进 290px」
///
/// 实测（探针，等待 providers 完全加载、chip 都出现之后）：
/// ```text
/// 卡片宽 401 → 26 处溢出
/// 卡片宽 402 → 0     ✓
/// ```
/// 也就是说**卡片内部横排**需要 ~402px（含把手 22 + 图标 30 + 正文 156 + 按钮 264 + 内边距 24）。
/// 那为什么 299px 的格子不会溢出？**因为卡片自己会响应式换行**
/// （`settings_page._cardWideMinWidth`：窄格子时按钮换到第二行）——
/// 兜底的是那条换行逻辑，不是这个常量。
///
/// ⚠️ 所以改这个常量必须**同时**确认卡片换行后的预算够用：
/// ```text
/// 窄版一行所需 = 内边距 24 + 把手 22 + 图标 30 + 间距 12 + 正文 156 = 244px
/// 按钮单独一行 = 内边距 24 + 按钮区 264                          = 288px
/// → 299px 格子**两项都满足**（按钮那行只剩 11px 余量，很紧）
/// ```
/// 正因为只剩 11px，本轮**同时精简了卡片内容**（去掉冗余的「JS 插件」
/// chip、版本号移到描述行），把按钮那行的余量拉开 —— 见 `_nameRow` 的注释。
const double kMinCardWidth = 290;

/// 一行最多几列
///
/// ⚠️ **不设上限**（照原版）—— 原版注释：
/// > 1920px 视口 → 4 列（每列约 460px）✅ 依然够宽
/// > 也就是**仍能到 3 列甚至更多，但只在宽度真的够时才加列**。
///   所以这里传 `1 << 30`（= 实质上不限），列数完全由宽度决定。
///   真给个 `3` 的话，2560 宽的显示器会白留一大片。
const int kMaxCardColumns = 1 << 30;

/// 响应式卡片网格，支持**拖动排序**
///
/// # 参数
///
/// ```text
/// itemCount     卡片总数
/// itemBuilder   建第 index 张卡；★ 第三个参数是**拖动把手**，
///               调用方要把它放进卡片里（放在 [dragSlotWidth] 那一格）
/// onReorder     (oldIndex, newIndex) —— newIndex 是**落点格子的下标**
///               （与 `ReorderableListView.onReorderItem` 的语义一致：
///                已经是换算好的目标位，调用方不要再 -= 1）
/// ```
///
/// ⚠️ 为什么把把手**交给调用方**而不是由本文件直接包住整张卡：
///    只有把手能拖（整张卡可拖会吃掉「编辑/停用/移除/代理/登录」
///    所有按钮的点击 —— `settings_page` 里记着这条实测教训）。
///    而把手放在卡片内部的哪一格，是卡片的版式知识（它还要与
///    `_panels()` 的左缩进逐像素对齐），所以由卡片决定，
///    本文件只负责"造一个能开始拖的控件"。
class ReorderableCardGrid extends StatefulWidget {
  const ReorderableCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onReorder,
    this.dragSlotWidth = 22,
    this.minItemWidth = kMinCardWidth,
    this.maxColumns = kMaxCardColumns,
    this.spacing = Sp.x3,
    this.onSwitchObserved,
  });

  /// 【测试专用】`AnimatedSwitcher.layoutBuilder` 收到 **outgoing 子项**时回调
  ///
  /// # 为什么生产代码里要留一个测试钩子
  ///
  /// 「拖动时有动画」这件事**没有别的方式能可靠断言**。实测踩了两版假绿：
  /// ```text
  /// 第 1 版：断言"卡片外存在 FadeTransition"
  ///   → 静止时 MaterialApp 路由/AnimatedOpacity 就产生 6~8 个 → 恒真
  ///
  /// 第 2 版：断言"卡片外存在 opacity 在 (0,1) 的值"
  ///   → 取到了 0.931，看着绿了
  ///   → 但把 AnimatedSwitcher **整个删掉**，那个值**依然出现**
  ///     （它来自同一格里 AnimatedOpacity 的拖动化淡）
  ///   → 假绿
  /// ```
  /// 真正能区分的信号只有一个：`AnimatedSwitcher` 让位时
  /// 把旧内容放进 `_outgoingWidgets`，于是 `layoutBuilder` 的
  /// 第二个参数（`previous`）**非空**。删掉 AnimatedSwitcher
  /// 或把 duration 设 0，这个回调就再也不会被调到。
  ///
  /// ⚠️ 默认 `null`，生产路径**没有额外开销**（一次 null 判断 + 一次调用）。
  ///    传了才会计数，且只用于测试。
  final void Function(int outgoingCount)? onSwitchObserved;

  final int itemCount;

  /// `(context, index, dragHandle, cellWidth)` → 第 index 张卡
  ///
  /// ⚠️ 第四个参数 [cellWidth] 是**本格的实际宽度**（已扣除间距）。
  /// 卡片用它决定"要不要换行"（见 `settings_page._ProviderCard`）——
  /// ★ 这是**刻意传下去**的，而不是让卡片自己 `LayoutBuilder` 量：
  /// ```text
  /// 卡片里放 LayoutBuilder → 会让整棵子树**不支持 intrinsics**
  /// → 外层 IntrinsicHeight 直接抛
  ///   "LayoutBuilder does not support returning intrinsic dimensions"
  /// ```
  /// 而网格**本来就知道**每格多宽（就是它算的列数），
  /// 所以直接传下去：既省一趟布局，又不破坏 intrinsics。
  final Widget Function(
    BuildContext context,
    int index,
    Widget dragHandle,
    double cellWidth,
  ) itemBuilder;

  final void Function(int oldIndex, int newIndex) onReorder;

  /// 把手那一格的宽度（要跟卡片里的 `SizedBox` 用同一个值）
  final double dragSlotWidth;

  /// 每列最小宽度（低于它卡片会溢出 —— 见 [kMinCardWidth]）
  final double minItemWidth;

  final int maxColumns;

  /// 卡片之间的间距（原版 `.plug__list { gap: var(--sp-2) }`，
  /// 我们用 `Sp.x3` = 12px，与卡片列表原来的 `bottom: Sp.x3` 一致）
  final double spacing;

  /// 按可用宽度算列数（**纯函数**，单独抽出来便于测试）
  ///
  /// ```text
  /// available=1232(1280 窗口) → floor(1244/302) = 4 列  ✓ 用户要的 4 列
  /// available= 852( 900 窗口) → floor( 864/302) = 2 列
  /// available= 352( 400 窗口) → floor( 364/302) = 1 列
  /// ```
  ///
  /// ⚠️ `+ spacing` 再除：n 列之间只有 `n-1` 个间距，
  ///    但用 `(w + gap) / (min + gap)` 这个常见写法可以直接得到 n，
  ///    不必先 `(w + gap) / (min + gap)` 再去凑 —— 两式等价且不会差一。
  static int columnsFor(
    double available, {
    double minItemWidth = kMinCardWidth,
    double spacing = Sp.x3,
    int maxColumns = kMaxCardColumns,
  }) {
    if (available <= 0) return 1;
    final n = ((available + spacing) / (minItemWidth + spacing)).floor();
    if (n < 1) return 1;
    if (n > maxColumns) return maxColumns;
    return n;
  }

  /// 计算"把 [from] 移到 [to] 之后"的顺序（**纯函数**，便于测试）
  ///
  /// 返回 `List<int>`，第 i 项 = **第 i 格应该显示原来第几个条目**。
  /// 与 `ReorderableListView` 的语义一致：拖动中列表就已经是落地后的样子。
  ///
  /// ```text
  /// count=5, from=0, to=2  →  [1, 2, 0, 3, 4]
  ///   原来的第 0 项挪到第 2 格，第 1/2 项各往前一位
  ///
  /// count=5, from=3, to=1  →  [0, 3, 1, 2, 4]
  ///   反向同理
  ///
  /// from == to             →  恒等（原地不动）
  /// from 越界              →  恒等（防御：遥控/程序调用可能给脏下标）
  /// ```
  static List<int> previewOrder(int count, int from, int to) {
    final order = List<int>.generate(count < 0 ? 0 : count, (i) => i);
    if (from == to || from < 0 || from >= order.length) return order;
    final moved = order.removeAt(from);
    final at = to.clamp(0, order.length);
    order.insert(at, moved);
    return order;
  }

  @override
  State<ReorderableCardGrid> createState() => _ReorderableCardGridState();
}

class _ReorderableCardGridState extends State<ReorderableCardGrid> {
  /// 正在被拖动的**原始下标**（`null` = 没在拖）
  ///
  /// ⚠️ 必须放在 `State` 里而不是每张卡自己管 —— 因为"让位"是**全局**行为：
  ///    第 0 张被拖到第 5 格时，第 1~5 张都要跟着挪，它们得知道"有人在拖"。
  int? _dragging;

  /// 拖到了**哪一格**（`null` = 还在原位或没在拖）
  ///
  /// 这是"实时预览"的核心：`_dragging` 与 `_hovered` 之间的所有格子
  /// 都会**当场让位**（不等松手），与 `ReorderableListView` 的默认效果一致。
  int? _hovered;

  /// 松手之后、**数据还没回来**之前继续沿用的顺序（`null` = 无）
  ///
  /// # 为什么需要它（不然会闪一下）
  ///
  /// `onReorder` 的调用方（`_onReorderProviders`）做的是
  /// **异步落盘 + `loadAll()` 重取数据**，中间有几百毫秒。
  /// 若松手时立刻清空拖动状态，网格会马上按**旧的数据顺序**渲染 ——
  /// 用户看到卡片"弹回原位 → 再跳到新位置"，很廉价。
  ///
  /// 存下落地顺序后，这段窗口期继续按它渲染，等
  /// `didUpdateWidget` 发现条目变了再清掉 → 视觉上是一次连贯落位。
  List<int>? _pending;

  @override
  void didUpdateWidget(covariant ReorderableCardGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    /*
     * 数据（条目数或内容）变化 = 上游已经把新顺序给我了 →
     * 丢掉 `_pending`，改为相信数据。
     *
     * ⚠️ 这里只比 `itemCount`：我们没有条目的身份列表可比
     *（那样要给 `ReorderableCardGrid` 加一个 `ids` 参数）。
     * 对"重排"这个用例够用 —— 重排不改变条目数。
     * 若将来要在网格里**删除**条目，`itemCount` 也会变，同样会清掉。
     */
    if (oldWidget.itemCount != widget.itemCount) _pending = null;
  }

  void _setDragging(int? index) {
    if (_dragging == index) return;
    setState(() {
      _dragging = index;
      if (index == null) {
        _hovered = null;
      } else {
        _hovered = index;
      }
    });
  }

  void _setHovered(int index) {
    /*
     * ⚠️ 这里**只在新落点与当前不同**时 setState。
     *
     * `DragTarget.onMove` 在鼠标移动时**每帧都可能触发**，
     * 若每次都 `setState` 就会每帧重建 26 张卡（用户明确要求"不能每帧重建全部"）。
     * 加了这道判断之后，只有"跨到另一格"才真的重建一次 ——
     * 一次拖动最多触发 (经过的格子数) 次，而不是 (帧数) 次。
     */
    if (_hovered == index || _dragging == index) return;
    setState(() => _hovered = index);
  }

  /// 「让位」后的**目标顺序**（拖动中 / 刚松手都走这里）
  ///
  /// 优先级：
  /// ```text
  /// ① 正在拖  → 把 _dragging 挪到 _hovered（实时预览）
  /// ② 刚松手  → 用 _pending（数据还没回来，先按落地顺序渲染，避免闪回）
  /// ③ 其它    → 恒等顺序（交给上游数据）
  /// ```
  List<int> _currentOrder() {
    final from = _dragging;
    final to = _hovered;
    if (from != null && to != null) {
      return ReorderableCardGrid.previewOrder(widget.itemCount, from, to);
    }
    final p = _pending;
    if (p != null && p.length == widget.itemCount) return p;
    return List<int>.generate(widget.itemCount, (i) => i);
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 用 LayoutBuilder 量**真实可用宽**，不猜窗口宽
     *
     * 这一页的宽度链是：
     * ```text
     * 窗口 1280
     *  − _Block 的 contentPadding 24×2  = 1232   ← 这才是可用宽
     * ```
     * 拿 `MediaQuery.of(context).size.width` 当可用宽会**多算 48px**，
     * 于是 1280 窗口下算出 3 列、实际每列只有 402.67px（刚好卡在阈值上）——
     * 略窄一点的窗口（1200）就会算成 2.93→2 列？不，会更糟：
     * 用窗口宽算 1200 → 2 列，用可用宽算 1152 → 2 列，看起来一样，
     * 但 1240 窗口：窗口宽 → 3 列（每列 397px ★ 溢出），
     *                可用宽 → 2 列（每列 576px ✓）。
     * `LayoutBuilder` 拿到的 `constraints.maxWidth` 才是**真正**能用的宽度。
     */
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ReorderableCardGrid.columnsFor(
          constraints.maxWidth,
          minItemWidth: widget.minItemWidth,
          spacing: widget.spacing,
          maxColumns: widget.maxColumns,
        );

        /*
         * ★★ 实时预览：按**让位后**的顺序铺格子（不是原始顺序）
         *
         * `_currentOrder()` 返回"每一格显示原来第几个条目"。
         * 拖动中它就把 `_dragging` 挪到了 `_hovered`，
         * 于是这一帧渲染出来**已经是落地后的样子** —— 这就是"实时预览"。
         * 松手时 `onReorder` 上报 `(from, cellIndex)`，
         * 调用方落盘、数据重排，两边结果一致。
         */
        final order = _currentOrder();
        final cellWidth =
            (constraints.maxWidth - (columns - 1) * widget.spacing) / columns;

        /*
         * 按行切块 —— 这样 `Row` 才能做「同一行等高」
         * （CSS grid 的 `align-items: stretch`，见文件头）。
         *
         * ⚠️ 不用 `Wrap`：`Wrap` 的每个子项各自决定高度，
         *    同一行不会等高（CSS grid 会），26 张卡会参差不齐。
         *    而"高度参差"正是原版 Owner 抱怨过的那件事
         *    （「这高度都不一样显示的太丑了」，见 `_nameRow` 的注释）。
         */
        final rows = <List<int>>[];
        for (var i = 0; i < widget.itemCount; i += columns) {
          rows.add([
            for (var j = i; j < i + columns && j < widget.itemCount; j++) j,
          ]);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) SizedBox(height: widget.spacing),
              /*
               * ★★ 同一行等高 —— 必须用 `IntrinsicHeight` 包住
               *
               * # 为什么（这里踩了一个真 bug，记下来）
               *
               * CSS grid 的默认 `align-items: stretch` 让同一行的卡片等高。
               * Flutter 里最直觉的对应是 `Row(crossAxisAlignment: stretch)`
               * —— **但它会崩**：
               * ```text
               * BoxConstraints forces an infinite height.
               * The offending constraints were:
               *   BoxConstraints(0.0<=w<=Infinity, h=Infinity)
               * ```
               * 根因：本网格是被放进**外层 `ListView`** 里的
               * （见 `settings_page` 的调用点），
               * 那里的高度约束是 `0 <= h <= Infinity`。
               * 而 `stretch` 要求"把子项拉到行高" ——
               * 行高本身要先由子项决定，子项又想被拉到行高，
               * 无界高度下就成了**死循环**，Flutter 直接断言。
               *
               * # `IntrinsicHeight` 怎么解决
               *
               * 它先问一遍"这行里最高的子项有多高"（**内在高度**），
               * 得到一个**有界的**高度，再用它当紧约束给 `Row`。
               * 于是 `stretch` 有了可拉的目标，循环解开。
               *
               * ⚠️ 代价：多一趟布局（intrinsic 要递归问子树）。
               *    本机 26 张卡 / 4 列 = 7 行，每行 4 张 —— 量很小。
               *    而且**原来也一样是"全部构建"**：
               *    `ReorderableListView(shrinkWrap: true)` 同样会把
               *    26 个条目全部构建（shrinkWrap 的语义就是先量全部）。
               *    所以这里没有引入新的性能问题。
               *
               * ⚠️ 若将来卡片里加了**不支持 intrinsics** 的控件
               *    （例如 `Expanded` 放在**竖直**方向的无界容器里、
               *     或自定义 RenderObject 没实现 computeMaxIntrinsicHeight），
               *    这里会抛错。那时把 `IntrinsicHeight` 换成
               *    `crossAxisAlignment: CrossAxisAlignment.start`
               *    （放弃等高、保证不崩）即可。
               */
              IntrinsicHeight(
                child: Row(
                  /*
                   * ★ 等高（CSS grid 的 `align-items: stretch`）
                   *
                   * 上面 `IntrinsicHeight` 已给出**有界**的行高，
                   * 所以这里的 `stretch` 是安全的。
                   * 卡片里是 `Column`，多出来的空间落在底部
                   *（内容仍顶部对齐），视觉上就是"同一行卡片底边对齐"。
                   */
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var c = 0; c < columns; c++) ...[
                      if (c > 0) SizedBox(width: widget.spacing),
                      /*
                       * ★★ `flat` = 这一格在**整个网格**里的扁平下标
                       *
                       * ⚠️ **不能用 `c`（行内列号）代替它** —— 这里踩到过一个
                       *    真 bug，症状很隐蔽（2026-09-25）：
                       * ```text
                       * 写了 _slot(context, c, order[c], ...)
                       *   → 第 r 行的每一格都用 c（0..列数-1）
                       *   → **每一行都渲染了 order[0..列数-1]**！
                       * ```
                       * 实测（itemCount=4, 2 列）：
                       * ```text
                       * 期望： row0 = card0 card1 / row1 = card2 card3
                       * 实际： row0 = card0 card1 / row1 = card0 card1  ← 重复！
                       *        card2/card3 **一次都没构建**
                       *        find.byKey('card0') 找到 **2 个**（歧义）
                       * ```
                       * 也就是说**第二行开始全是第一行的副本** ——
                       * 26 张卡会变成"第一行重复 7 遍"，而且拖拽的
                       * `cellIndex` 也全撞在一起（DragTarget 身份重复）。
                       *
                       * `flat = r * columns + c` 才是"第几格"的唯一正确表达。
                       */
                      if (c < rows[r].length) ...[
                        Builder(
                          builder: (context) {
                            final flat = r * columns + c;
                            return Expanded(
                              /*
                               * ★★ 实时预览（用户要求「拖动的时候我希望能实时预览
                               *    就是有动画那个效果」）
                               *
                               * ⚠️ **`DragTarget` 的身份必须按"格子"稳定，
                               *    不能按"卡片"** —— 这是一个很容易踩的坑：
                               * ```text
                               * 若把 AnimatedSwitcher 放在 DragTarget **外面**
                               * （key = 卡片下标），预览一让位，那一格的
                               * DragTarget 就被销毁重建。
                               * 而拖动中的 Draggable 仍持有**旧的** target 引用，
                               * 松手时回调打到已销毁的 widget 上 ——
                               * 上报的下标可能是错的（甚至不触发）。
                               * ```
                               * 所以顺序是：`DragTarget`（按格子下标 flat，稳定）
                               *   → `AnimatedSwitcher`（按**条目**下标，做内容切换动画）
                               *   → 卡片。
                               */
                              child: _slot(
                                context,
                                flat, // 格子扁平下标（DragTarget 身份，稳定）
                                order[flat], // 该格当前显示的**条目**下标
                                cellWidth,
                                isDragSource: _dragging == order[flat],
                              ),
                            );
                          },
                        ),
                      ] else
                        const Expanded(child: SizedBox.shrink()),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 一格：`DragTarget`（接住别处拖来的卡）+ **带动画的内容切换** + 卡片本体
  ///
  /// [cellIndex] 是**格子**下标 —— 它是 `DragTarget` 的身份，**必须稳定**
  ///（理由见调用点那段注释：按卡片下标会让 target 被销毁重建，
  /// 松手时回调打到已销毁的 widget 上）。
  ///
  /// [itemIndex] 是这一格**当前显示哪个条目** —— 拖动让位时格子不动、
  /// 内容换，这个值才变（它是 `AnimatedSwitcher` 的 key）。
  ///
  /// [cellWidth] 是本格的实际宽度 —— 由网格算好传下去（卡片靠它决定换不换行，
  /// 而不是自己 `LayoutBuilder`，理由见 [ReorderableCardGrid.itemBuilder] 的注释）。
  ///
  /// [isDragSource] 为 true 时这张卡**正在被拖**（原位化淡，表示"它被拿起来了"）。
  Widget _slot(
    BuildContext context,
    int cellIndex,
    int itemIndex,
    double cellWidth, {
    required bool isDragSource,
  }) {
    return DragTarget<int>(
      /*
       * ⚠️ 不接受"拖到自己身上"（原地放下）——
       *    否则每次轻点把手都会触发一次 onReorder，
       *    白写一次盘（`_onReorderProviders` 里也有一道同样的判断，
       *    两处都留是因为那道是给"程序调用"兜底的）。
       *
       * ★ 注意这里比的是**条目**下标（`itemIndex`），不是格子下标 ——
       *   "拖到自己身上"的语义是"落点显示的就是我自己"，
       *   而拖动中自己已经被挪到别处了（`_currentOrder`），
       *   所以要用 `itemIndex` 才能正确判断。
       */
      onWillAcceptWithDetails: (d) => d.data != itemIndex,
      /*
       * ★★ `onMove` —— **实时预览的关键**
       *
       * 鼠标每滑过一格就更新 `_hovered`，于是 `_currentOrder()` 当场
       * 把卡片挪过去（不等松手）—— 这就是用户要的「实时预览」。
       *
       * `onAcceptWithDetails` 只在**松手**时触发（真正上报重排）。
       */
      onMove: (d) => _setHovered(cellIndex),
      onAcceptWithDetails: (d) {
        final from = d.data;
        /*
         * ⚠️ 先复位拖动状态，再上报重排。
         *
         * 复位会 `setState`（清空 `_dragging`/`_hovered`），于是网格回到
         * **数据顺序**渲染 —— 而此时数据还没重排（`onReorder` 通常是
         * 异步落盘 + `loadAll`，见 `_persistOrder`）。
         * 那一瞬间会闪回旧顺序，几百毫秒后数据回来才跳成新顺序。
         *
         * 所以先把"落地后的顺序"存进 `_pending`，让网格在数据回来之前
         * 继续按这个顺序渲染 —— 用户看到的是**一次连贯的落位**，不闪。
         * `didUpdateWidget` 里清掉它（那时数据已经是新顺序了）。
         */
        setState(() {
          _pending = ReorderableCardGrid.previewOrder(
              widget.itemCount, from, cellIndex);
          _dragging = null;
          _hovered = null;
        });
        if (from != cellIndex) widget.onReorder(from, cellIndex);
      },
      builder: (context, candidate, rejected) {
        /*
         * ⚠️ `candidate` 只在"悬停在这一格"时非空；拖动中经过的格子会
         *    不断来来去去，所以高亮的判定以 `_hovered` 为准（更稳），
         *    `candidate` 作为辅助（真正悬停时一定有）。
         */
        final hot = _hovered == cellIndex && _dragging != null;
        /*
         * ★★ 高亮**绝不能改变布局**（实测踩到两次，2026-09-25）
         *
         * # 第一版：`AnimatedContainer` + `Border.all(width: 2)` —— 错
         *
         * `Border` 会**吃掉布局空间**：
         * ```text
         * 格子 402.67px − 左右边框各 2px = 卡片实际只有 398.67px
         * → 26 张卡的 `_nameRow` 全部溢出
         * ```
         * 隐患在于：**不拖动时高亮框是透明的，但它已经在挤卡片了**
         *（透明 ≠ 不占位）。报错指向卡片内部的 `_nameRow`，完全不提边框 ——
         * 这种"错误现场离根因很远"的 bug 最费时间。
         *
         * # 第二版：`Stack` + `Positioned.fill` —— 也不对
         *
         * `Stack` 默认 `fit: StackFit.loose`，会把**紧约束**变成**松约束**
         * 传给非定位子项（`0 <= w <= 402.67` 而不是 `w = 402.67`）。
         * 卡片内部的 `Row`/`Expanded` 因此在**小于格子**的宽度上布局，
         * 实测阈值从 400px 变成了 402px（401 溢出、402 干净）——
         * 明明格子够宽，卡片还是溢出。
         *
         * # 最终：`foregroundDecoration` + `AnimatedOpacity` —— 画在上层，**不参与布局**
         *
         * `Container.foregroundDecoration` 是在子项**之后**绘制的一层装饰，
         * 它不改变子项的尺寸约束（只影响绘制顺序）。
         * 高亮画在卡片最外层、卡片该多宽还是多宽 ——
         * 这正是"视觉反馈"应有的语义：**纯绘制，零布局副作用**。
         *
         * ⚠️ 别再用 `Stack`/`AnimatedContainer` 绕回来。要动画就动**颜色/透明度**
         *    （`AnimatedOpacity` / `TweenAnimationBuilder` 包颜色）。
         */
        return AnimatedOpacity(
          /*
           * 被拖起来的那张卡原位化淡（"我把它拿起来了"）——
           * 这也是纯绘制（Opacity 不改约束）。
           */
          opacity: isDragSource ? 0.35 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: DecoratedBox(
            /*
             * ★★ 高亮层必须是**恒定结构**的 `DecoratedBox`（不是带条件装饰的 `Container`）
             *
             * # 这里踩到过一个真 bug（2026-09-25，第三版才修对）
             *
             * 原来写的是：
             * ```dart
             * Container(
             *   foregroundDecoration: hot ? BoxDecoration(...) : null,
             *   child: AnimatedSwitcher(...),
             * )
             * ```
             * 看着自然（"不高亮就不加装饰"），但它会**换掉 widget 树的结构**：
             * ```text
             * Container.build() 的行为：
             *   foregroundDecoration == null → **直接返回 child**（= AnimatedSwitcher）
             *   foregroundDecoration != null → 返回 DecoratedBox(child: AnimatedSwitcher)
             * ```
             * 拖动**经过**某一格时 `hot` 翻转，那一格的 `AnimatedSwitcher`
             * 在树里的位置从"第 N 层"变成"第 N+1 层"，Flutter 的 Element 调和
             * 看到 `DecoratedBox` ≠ `AnimatedSwitcher` → **销毁旧的、新建一个**
             * → `AnimatedSwitcher` 的 State 没了（`_currentEntry == null`）。
             *
             * 实测证据（探针打印 `layoutBuilder` 的参数）：
             * ```text
             * SWDBG layoutBuilder cur=[<0>] prev=0
             * SWDBG layoutBuilder cur=[<1>] prev=0   ← 内容换了，prev 却**一直是 0**
             * ```
             * `prev=0` = "没有旧内容在淡出" = **动画根本没发生**，
             * 用户看到的还是硬切。位移是好的，所以肉眼很难发现。
             *
             * # 修法：结构恒定，只改颜色
             *
             * 无条件用 `DecoratedBox`，不高亮时给**透明边框**而不是 `null`：
             * ```text
             * 高亮    border: primary 2px
             * 不高亮  border: transparent 2px   ← 关键：decoration 一直存在
             * ```
             * 树永远是 `DecoratedBox > AnimatedSwitcher`，开关只改一个颜色属性
             * → `AnimatedSwitcher` 的 State 保留 → 动画正常。
             *
             * ⚠️ 为什么**不会**影响布局（上一轮那个 bug 的教训）：
             * ```text
             * `DecoratedBox` 是 RenderProxyBox —— **只画，不改约束**。
             * `BoxDecoration.border` 也只影响绘制，不占布局空间。
             *
             * 对比：`Container(decoration:)`（不是 foreground）会把 border
             * 宽度算进 padding（`_paddingIncludingDecoration`）→ 卡片被压窄 4px
             * → 26 张全溢出。那个行为只对 `decoration` 生效，
             * 对 `foregroundDecoration` / `DecoratedBox` 都**不**生效。
             * ```
             */
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hot
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            /*
             * ★★ 让位动画（用户要「有动画那个效果」）
             *
             * `AnimatedSwitcher`：这一格的**内容**（`itemIndex`）变了就做交叉淡化。
             *
             * # ⚠️ `layoutBuilder` 必须**只显示新内容**（这里踩到过真 bug）
             *
             * `AnimatedSwitcher` 的默认 layoutBuilder 是：
             * ```dart
             * Stack(children: [...previousChildren, if (currentChild != null) currentChild])
             * ```
             * 也就是说**过渡期间新旧两个子项同时存在**（旧的淡出、新的淡入）。
             * 对本网格来说这是**错的**，实测两个后果：
             * ```text
             * ① 卡片有 Key（`ValueKey('card0')`）→ 过渡期间
             *    find.byKey 会找到**两个**同 key 的 widget
             *    → 测试报 "ambiguously found multiple matching widgets"
             *    → 而且真实渲染时两张卡短暂重叠（鬼影）
             * ② 那一格的高度/宽度按"两个子项"算，虽然此处两者同尺寸，
             *    但语义上仍是重复绘制
             * ```
             * 所以这里改成"只放新内容"，淡入由 `AnimatedSwitcher` 内建的
             * `FadeTransition` 提供（新内容从透明到不透明）——
             * 视觉上仍是"换内容时有过渡"，但**不会有两份同时存在**。
             *
             * ⚠️ 另一条路是"给旧内容也保留、但不重复 Key"，那要改调用方的
             *    Key 结构（卡片 Key 是上游用来认条目的，不能动）。
             *    而且重叠绘制在 26 张卡的网格里更容易看出鬼影 ——
             *    所以选"只显示新内容"。
             */
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              /*
               * ★ 测试可观测点：`previous`（outgoing 子项）非空 = 真的在过渡
               *
               * 见 `onSwitchObserved` 的文档 —— 这是唯一能区分
               * "有过渡动画" 与 "硬切" 的可靠信号（前两版断言都是假绿）。
               */
              layoutBuilder: (current, previous) {
                if (previous.isNotEmpty) {
                  widget.onSwitchObserved?.call(previous.length);
                }
                return Stack(
                  /*
                   * ★★★ `fit: StackFit.passthrough` —— **同一行等高**的关键
                   * （2026-09-25 task-24 实测定位）
                   *
                   * # 这里踩到的真 bug：默认的 `StackFit.loose` 把行高吃掉了
                   *
                   * 外层是 `IntrinsicHeight > Row(crossAxisAlignment: stretch)`，
                   * 它给每一格发的是**紧高度**（`h = 行高`）—— 这正是"同一行等高"
                   * 的实现方式。但 `Stack` 默认 `fit: StackFit.loose` 会把它
                   * 降级成**松约束**（`0 <= h <= 行高`），于是卡片各自缩回
                   * **内容高度**，行高白算了。
                   *
                   * 实测（`.probe/probe_tests/t24_grid_equality_test.dart`，
                   * 阳性对照：8 格故意做成 100/160 交替）：
                   * ```text
                   * 默认 loose   → 实测 100,160,100,160,100,160,100,160
                   *                row0 delta=60px  ★ 同一行**不等高**
                   * passthrough → 实测 160,160,160,160,160,160,160,160
                   *                row0 delta= 0px  ★ 同一行等高
                   * ```
                   *
                   * # 为什么这个问题"看起来"不像 bug
                   *
                   * 因为 `IntrinsicHeight` **确实**在算行高（它的工作是给
                   * `stretch` 一个可拉的目标，避免"无限高度"断言），
                   * 而卡片也确实被拉到了……不，**没有被拉到**：
                   * 松约束下卡片选择"按内容"，所以只有内容本来就最高的那张
                   * 撑满行高，其余都短一截。
                   *
                   * ⚠️ 这个坑本项目**已经记过一次**（见上面 `_slot` 的注释里
                   *    "第二版：`Stack` + `Positioned.fill` —— 也不对"那段：
                   *    `Stack` 默认 loose 会把紧约束变松）。
                   *    当时是在**高亮层**踩到的并改用 `DecoratedBox` 绕开；
                   *    而这里 `AnimatedSwitcher` 的 `layoutBuilder` **必须**
                   *    返回一个 `Stack`（要把新旧子项叠起来），所以绕不开 ——
                   *    正解是显式指定 `fit: StackFit.passthrough`：
                   * ```text
                   * passthrough = 把**收到的约束原样**传给孩子
                   *             = 紧高度原样下去 → 卡片被拉到行高 → 等高
                   * ```
                   *
                   * ⚠️ 不能用 `StackFit.expand`：那会强制 `w/h` 都取最大，
                   *    宽度上没问题（本来就是紧的），但它要求**有界**约束 ——
                   *    语义上不如 `passthrough` 准确（我们要的是"别改约束"，
                   *    不是"撑满"）。
                   */
                  fit: StackFit.passthrough,
                  // 两个子项同尺寸（同一格），topLeft 对齐避免居中偏移
                  alignment: Alignment.topLeft,
                  children: [if (current != null) current],
                );
              },
              child: KeyedSubtree(
                key: ValueKey<int>(itemIndex),
                child: widget.itemBuilder(
                  context,
                  itemIndex,
                  _handle(context, itemIndex),
                  cellWidth,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 拖动把手 —— `Draggable` 包一个抓手图标
  ///
  /// # 为什么是 `Draggable` 而不是长按版
  ///
  /// 与原来那条实测结论一致（`_ProviderCard` 的注释）：
  /// ```text
  /// 桌面/电视是**鼠标/遥控**，按下即可拖，不需要长按；
  /// 长按版（LongPressDraggable）是给触屏准备的，
  /// 用鼠标会"按半天没反应"。
  /// ```
  ///
  /// # ★ 图标颜色**必须够深**（实测教训，2026-09-25，从 `_ProviderCard` 带过来）
  ///
  /// 第一版写的是 `onSurfaceVariant.withValues(alpha: 0.7)`，
  /// 结果把手在**浅色卡片上几乎看不见** —— 用红色块做标记测试才定位到
  /// 「槽位在、图标淡到测不出」。算一下（`onSurfaceVariant` ≈ (112,114,122)）：
  /// ```text
  /// alpha 0.7 叠在卡片底 (252,252,253) 上
  ///   → 0.7*112 + 0.3*252 ≈ 154   ← 只比底色深 98
  /// alpha 1.0
  ///   → (112,114,122)              ← 深 140，一眼可见
  /// ```
  /// 拖动把手是**唯一的拖动入口**，看不见等于「拖不动」——
  /// 所以这里用**满不透明**的主题色，不做淡化。
  ///
  /// # `feedback` —— 拖动中的卡片跟随鼠标
  ///
  /// `feedback` 渲染在 `Overlay` 里，**没有父级宽度约束**
  ///（`constraints.maxWidth` 是无穷）→ 必须给**死宽度**，
  /// 否则带文字的卡片预览会直接断言失败。
  ///
  /// ★ 用户要的是「实时预览」，所以这里给的不是一个小方块，
  ///   而是**跟真实卡片同宽**的一条"拿起来了"的预览条：
  /// ```text
  /// · 宽度 = dragSlotWidth 撑到 cellWidth（由 _handle 的调用方传进来）
  /// · 半透明主色底 + 圆角 + 抬起阴影（三层视觉反馈：颜色/透明/阴影）
  /// ```
  /// 这些全是**绘制属性**（`decoration` / `boxShadow`），不参与网格布局，
  /// 所以不会重演"高亮把卡片挤到阈值以下"那个 bug。
  Widget _handle(BuildContext context, int index) {
    final colors = Theme.of(context).colorScheme;
    final grip = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child:
          Icon(Icons.drag_indicator, size: 20, color: colors.onSurfaceVariant),
    );

    return SizedBox(
      width: widget.dragSlotWidth,
      child: Draggable<int>(
        data: index,
        /*
         * ★★ 拖动开始/结束要通知网格 —— 这是"实时预览"的开关
         *
         * ```text
         * onDragStarted   → _setDragging(index)：网格开始让位（其他卡挪开）
         * onDragEnd       → _setDragging(null)：收尾（若没落在任何格子上也要复位）
         * onDraggableCanceled → 拖到空白处松手（没被任何 DragTarget 接住）
         * ```
         * ⚠️ `onDragEnd` 里**不能**做重排上报 —— 落点由 `DragTarget`
         *    的 `onAcceptWithDetails` 负责（那里才知道落点下标）。
         *    这里只负责**复位拖动状态**。
         *
         * ⚠️ `onDraggableCanceled`（拖到空白处松手）也必须复位，
         *    否则网格会永远停在"有人在拖"的状态 —— 卡片一直是淡的、
         *    而且再也不能拖动（`_dragging` 卡住）。
         */
        onDragStarted: () => _setDragging(index),
        onDragEnd: (_) {
          if (_dragging != null) _setDragging(null);
        },
        onDraggableCanceled: (_, __) {
          if (_dragging != null) _setDragging(null);
        },
        /*
         * 拖动时原位**留一个淡化的把手**（不是整张卡消失）——
         * 卡片留在原地，用户能看清"我从哪拖的"；
         * 真正的"让位"由 `_currentOrder()` 完成（其他卡会挪开）。
         *
         * ⚠️ 卡片本身的淡化在 `_slot` 里（`AnimatedOpacity`，看 `isDragSource`），
         *    这里只淡化把手 —— 两处叠加就是"整张卡变淡"。
         */
        childWhenDragging: Opacity(opacity: 0.25, child: grip),
        /*
         * ★ 拖动中的预览：跟随鼠标，且**比真实卡片更醒目**
         *
         * 用 `Material` 包住（`feedback` 在 Overlay 里没有 Material 祖先，
         * 文字/图标会因缺 `DefaultTextStyle` 而报错）。
         */
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.92,
            child: Container(
              width: 180,
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x3,
                vertical: Sp.x2,
              ),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.primary, width: 2),
                /*
                 * 抬起阴影 —— 纯绘制，让"这张卡被拿起来了"更明显。
                 *（阴影不参与布局，所以不会影响任何尺寸计算。）
                 */
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.drag_indicator, size: 18, color: colors.primary),
                  const SizedBox(width: Sp.x2),
                  Flexible(
                    child: Text(
                      '移动到…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeights.regular,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        child: grip,
      ),
    );
  }
}
