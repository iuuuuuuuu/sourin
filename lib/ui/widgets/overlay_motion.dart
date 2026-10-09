// ═══════════════════════════════════════════════════════════════════════
//  浮层入场动效（scrim 淡入 + 卡片轻微上浮）—— task-99
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件
//
// 用户原话（桌面端 9 条问题 · 第 7 条）：
//     「很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化」
//
// ★ 取证结论：本项目有 **4 个自实现的全屏浮层**，它们全都是
//   Positioned.fill → GestureDetector → ColoredBox(scrim) → Center → 卡片
//   这种同构结构，而其中**三个**（弹幕设置 / 字幕面板 / 选集面板）
//   **零入场动画** —— 一帧就出现。这就是「生硬」的主因。
//
// ⇒ 与其在三处各写一遍 TweenAnimationBuilder（那是本项目已经踩过的
//   「同构代码散落 ⇒ 改一处漏两处」），不如抽出这两个包装件。
//
// # 为什么用 TweenAnimationBuilder 而不是 AnimationController
// · 它是**隐式**动画：挂载时自动从 begin 补到 end，不需要 State/Ticker
//   ⇒ 调用点（danmaku_settings_dialog / subtitle_panel / episode_strip）
//     一行都不用改结构，也不会因为多一个 StatefulWidget 而丢状态
// · 面板的入场是**一次性**的（挂载即播），没有「中途反向」的需求
//   ⇒ 不需要 reverse() 这种只有显式 controller 才有的能力
//
// # ★★★ 为什么**不能**用 FadeTransition / ScaleTransition
// ① ScaleTransition 会**改几何**：卡片会缩放 ⇒ 破坏「动画结束后卡片必须
//    仍在原位置原尺寸」这条硬约束（几何被 episode_drawer_test / t57 /
//    zz_t70 钉住）。
// ② FadeTransition 读不出值：它内部是 RenderAnimatedOpacity，树上**没有**
//    Opacity 节点 ⇒ 测试与调试都看不到实际透明度。
//    （zz_t44_fade_in_test.dart:78-88 就是因为这个才去读
//      SliverFadeTransition.opacity.value。）
// ⇒ 统一用 Opacity + Transform：两个都是**可读**的渲染节点，而 Opacity 是
//   RenderProxyBox（不改尺寸）、Transform.translate 是纯平移（不改尺寸、
//   不改布局）。
//
// # ★ Reduce Motion（无障碍）
// 时长一律走 MotionPrefs.duration(context, token)：
//   系统开了「减少动态效果」⇒ Duration.zero
//   ⇒ TweenAnimationBuilder 在**第 0 帧**就落到终值（无中间态）
// ★ 而**子树结构不变** —— 这是 motion_prefs.dart:60-64 明确要求的：
//   「跳过动画」若靠条件分支不渲染动画组件，会让组件子树在两种情况不同
//   ⇒ 可能引起状态丢失（比「动了 260ms」更糟）。
//   （范式见 fade_in_sliver.dart:106-135 与 zz_t44_fade_in_test.dart:166。）

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';

/// `showModalBottomSheet` / `showDialog` 的**动画样式**（时长 + 曲线）
///
/// 取值与理由集中在 `tokens.dart` 的 `OverlayMotion.sheetAnimationStyle()`
/// —— 那里逐字段核对过 `BottomSheetThemeData` / `DialogThemeData`
/// **都没有** animationStyle 字段（所以这两个函数的时长只能逐调用点传），
/// 也记了框架默认值 250/200ms 与 150ms。
///
/// ⚠️ Reduce Motion ⇒ [AnimationStyle.noAnimation]（两个时长都归零）。
///    框架自己的 `AnimationBehavior.normal` 在系统开关打开时**也会**缩短
///    动画（`animation_controller.dart:651` 的 `scale = 0.05`），但显式给出
///    才能与其它浮层保持同一套**可判定**的语义。
AnimationStyle overlaySheetAnimationStyle(BuildContext context) =>
    MotionPrefs.reduce(context)
    ? AnimationStyle.noAnimation
    : OverlayMotion.sheetAnimationStyle();

/// 全屏浮层的 **scrim（遮罩）** —— 淡入
///
/// 把原来硬切的 ColoredBox 换成「从透明淡入到该颜色」，**颜色与覆盖范围
/// 一字不改**（动画结束后 Opacity 恒为 1.0 ⇒ 渲染结果与改前逐像素相同）。
///
///     TweenAnimationBuilder(0 → 1)
///       └ Opacity(opacity: t)        ← ★ 可读的渲染节点（测试据此判定）
///           └ ColoredBox(color: …)   ← 原样保留：HitTestBehavior.opaque
///                                       + 全屏 Rect 都不变（Opacity 是
///                                       RenderProxyBox，不参与布局）
///
/// ⚠️ **不要**把卡片放进这个 widget 里 —— 卡片要的是「淡入 **+ 上浮**」，
///    用 [OverlayCardMotion]（两者的时长/曲线不同：遮罩是「铺底」，
///    应当比卡片**更快**到位，否则会看到「黑幕还没铺满卡片就飞进来了」）。
class OverlayScrim extends StatelessWidget {
  const OverlayScrim({
    super.key,
    required this.color,
    required this.child,
    this.duration,
  });

  /// 遮罩色 —— ★ 必须与改前**逐字一致**（含 alpha）
  final Color color;

  final Widget child;

  /// 覆盖默认时长（默认 Motion.fast）
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ Reduce Motion ⇒ Duration.zero ⇒ 第一帧就是终值（opacity = 1.0）
     *   ⇒ 渲染结果与「没有动画层」完全一致。
     */
    final dur = MotionPrefs.duration(
      context,
      duration ?? OverlayMotion.scrimDuration,
    );

    return TweenAnimationBuilder<double>(
      // 0 → 1：挂载即补间（初值 ≠ 终值 ⇒ 一定会播，不会像
      // AnimatedOpacity 那样因「初值==目标值」而静默不播）
      tween: Tween<double>(begin: 0, end: 1),
      duration: dur,
      curve: MotionPrefs.curve(context, OverlayMotion.cardCurve),
      builder: (context, t, child) => Opacity(
        // clamp 是防御：某些 Curve 在极值处会有 1e-16 级的越界，
        // 而 Opacity 对越界值会**断言失败**（SheetTransition 同款处理）
        opacity: t.clamp(0.0, 1.0),
        child: child,
      ),
      /*
       * ★★★ child 是「Opacity 的孩子」，**不是**「ColoredBox 的孩子」。
       *
       * 这个顺序看着等价，其实**不等价** —— 本项目在另一处踩过同族坑
       * （`test/58_embed_layout_test.dart:36-37`：
       *  「不能挂在 Center 里面的 ColoredBox 上：Center 给子节点**松约束**」）。
       * 这里的问题是**着色**：`ColoredBox` 会 `paintChild` 后再刷一层色，
       * 若卡片在它里面，卡片会被再乘一次 0.72 的黑 ⇒ 卡片从 0.98 掉到
       * 约 0.71，而且**面板整体被压暗**（打开面板时画面会肉眼可见地变暗）。
       * ⇒ 卡片必须与 ColoredBox **平级**：
       *
       * ```text
       * Opacity(1.0)                      ← 只盖住这一层
       *   └ Stack
       *       ├ ColoredBox(scrim)         ← 全屏、原色、原命中范围
       *       └ child(卡片…)              ← 不受遮罩着色
       * ```
       * ⚠️ 用 `Stack` 而**不是** `ColoredBox(child: child)` 是有意的：
       *   ColoredBox 一旦有了孩子，它会跟着孩子收缩到孩子的大小
       *   ⇒ 遮罩就不再是全屏（几何被钉住，改不得）。
       */
      child: Stack(
        children: <Widget>[
          /*
           * ★★★ 必须是 `Positioned.fill`，**不能**写成裸的 `ColoredBox`。
           *
           * `Stack` 给**非定位**孩子的约束是 **loose**（`StackFit.loose`），
           * 而没有孩子的 `ColoredBox` 在松约束下会缩成 **0×0**
           * ⇒ 遮罩**整块消失**、点击也穿透到下层（我第一版就是这么写的，
           *   t99 的「遮罩仍是全屏」与「点遮罩仍然关闭」两条当场变红）。
           * 这与 `test/58_embed_layout_test.dart:36-37` 记的是**同一个坑**：
           * 「无子节点的 ColoredBox 会缩成 0x0」。
           *
           * `Positioned.fill` 让它拿到**紧约束** ⇒ 铺满整个 Stack
           * （= 原来的全屏范围，逐像素一致）。
           * 而卡片那一路仍是**非定位**孩子、约束不变 ⇒ 卡片几何不受影响。
           */
          Positioned.fill(child: ColoredBox(color: color)),
          child,
        ],
      ),
    );
  }
}

/// 浮层里**卡片/面板本体**的入场 —— 淡入 + 轻微上浮（可选横向）
///
///     TweenAnimationBuilder(1 → 0)
///       └ Opacity(1 - t)                        ← 淡入
///           └ Transform.translate(offset: 起点 * t)  ← 从起点滑到原位
///
/// # 为什么幅度只有 [distance] = 24（默认）
/// ★ 本项目**偏好克制的动效**：既有的 page_transition.dart 缩放幅度只有
///   **0.02**（2%），页面切换的位移也只在 20~24px 量级。这里沿用同一个
///   量级 —— 目的是「让用户看出东西是从哪来的」，而不是「表演一段动画」。
/// ⚠️ 位移是**纯平移**：Transform.translate 不改布局、不改尺寸，动画结束时
///   offset = (0,0) ⇒ 卡片几何与改前**逐像素一致**（几何被
///   episode_drawer_test.dart / t57 / zz_t70 钉住）。
///
/// # 方向
///     底部弹出的面板   → Offset(0, 24)  （从下方升起）
///     右侧抽屉         → Offset(24, 0)  （从右侧滑入）
///     居中弹窗         → Offset(0, 24)  （默认；与移动端一致）
/// ★ 必须与面板**实际的几何位置**一致 —— 贴右边的面板却从下面钻出来会像
///   「东西被甩过来」（这条契约见 episode_strip.dart 的 SheetTransition）。
class OverlayCardMotion extends StatelessWidget {
  const OverlayCardMotion({
    super.key,
    required this.child,
    this.distance = OverlayMotion.cardSlide,
    this.slideFrom,
    this.duration,
    this.curve,
  });

  final Widget child;

  /// 上浮距离（逻辑像素）—— 见类文档「为什么幅度只有 24」
  final double distance;

  /// 覆盖滑动方向（默认 Offset(0, distance) = 从下方升起）
  ///
  /// ★ 只给「右侧抽屉」这类需要横向入场的形态用。
  final Offset? slideFrom;

  /// 覆盖默认时长（默认 Motion.base）
  final Duration? duration;

  /// 覆盖默认曲线（默认 OverlayMotion.cardCurve）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★ task-2【⑥】为什么需要这个口子（2026-10-09）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// Owner 原话（第 6 条）：「选集抽屉阻尼感觉太重」。实测根因是
  /// **曲线形状**，不是时长：
  ///
  /// text
  /// OverlayMotion.cardCurve = Motion.easeOut = Cubic(0.22, 1, 0.36, 1)
  ///   260ms 内的进度：26ms 40.1% / 52ms 67.4% / 78ms 83.2%
  ///                  90ms 87.8% / 130ms 96.1% / 260ms 100%
  /// ⇒ 前 90ms 就冲完 87.8%，剩下 170ms 只走 12.2%
  ///   观感是「一冲一顿」，正是 Owner 说的「阻尼重」。
  ///
  /// ★ 为什么不直接改 OverlayMotion.cardCurve：
  ///   它是**全局共享 token**，弹幕设置面板 / 字幕面板 / 直播频道面板 /
  ///   线路面板四处浮层共用（t99 ⑥ 组那条断言的**本意**就是「四处都接
  ///   同一个共享件」）。改 token 等于同时改掉那四处的入场手感 ——
  ///   而 Owner 这条只针对**选集抽屉**。
  ///
  /// ⇒ 正解：共享件保留，把曲线做成**逐调用点可覆盖**的参数。
  ///   选集面板那一处传对称曲线（起步缓、中段快、收尾长），
  ///   其余三处不传 ⇒ 零改动、手感不变。
  ///
  /// ⚠️ 仍必须经 MotionPrefs.curve 降级：Reduce Motion 时给
  ///    Curves.linear，与全局 token 那条路径的行为一致（见
  ///    motion_prefs.dart:72-73 与「系统偏好优先」铁律）。
  final Curve? curve;

  @override
  Widget build(BuildContext context) {
    // ★ Reduce Motion ⇒ Duration.zero ⇒ 第一帧就在原位、完全不透明
    final dur = MotionPrefs.duration(
      context,
      duration ?? OverlayMotion.cardDuration,
    );
    final from = slideFrom ?? Offset(0, distance);
    final cv = curve ?? OverlayMotion.cardCurve;

    return TweenAnimationBuilder<double>(
      // 1 → 0：t 是「距离原位还有多远」的**比例**（1 = 还在起点）
      tween: Tween<double>(begin: 1, end: 0),
      duration: dur,
      curve: MotionPrefs.curve(context, cv),
      builder: (context, t, child) => Opacity(
        opacity: (1 - t).clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(from.dx * t, from.dy * t),
          child: child,
        ),
      ),
      // ★ child 优化：每帧只重建 Opacity/Transform，卡片子树不重建
      child: child,
    );
  }
}

/// 本项目**唯一**的对话框入口 —— 把 `showDialog` 的动效统一到 motion token
///
/// ══════════════════════════════════════════════════════════════════════
/// # 为什么要有它（用户原话 · 桌面端 9 条问题 第 7 条）
/// ══════════════════════════════════════════════════════════════════════
/// ```text
/// 很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化
/// ```
/// 取证结论（2026-10-08 全仓普查）：
/// ```text
/// 改前：15 处**生产**调用点直接调 `showDialog(...)`，一个 `animationStyle`
///       都没传 ⇒ 全部吃框架默认 150ms + `Curves.easeOut`，与本项目 token
///       不是一套节奏；而且**没有任何门禁**能发现"有人又新写了一个不带动效
///       的弹窗"（`animationStyle` 是**可选**参数 ⇒ 漏传不报错）。
/// 改后：15 处全部走这里；静态门禁（test/t104_overlay_exit_test.dart）钉住
///       「lib/ 里除本文件与两个真机探针外，不许再出现裸 `showDialog(`」。
/// ```
///
/// ══════════════════════════════════════════════════════════════════════
/// # 参数与 [showDialog] **逐个同名同序**（含默认值）
/// ══════════════════════════════════════════════════════════════════════
/// 这样 15 处替换是**纯机械**的（只换函数名），不会在替换时把某个实参挪错位；
/// 默认值与框架一致 ⇒ 调用点原来没传的参数，替换后行为**一字不改**。
///
/// ⚠️ 唯一的行为差异是 `animationStyle`（这正是本次改动的**目的**，不是副作用）。
///
/// ══════════════════════════════════════════════════════════════════════
/// # ★★ 退场时长 == 入场时长 —— 框架的**硬限制**，别去"修"它
/// ══════════════════════════════════════════════════════════════════════
/// ```text
/// dialog.dart:1853  transitionDuration: animationStyle?.duration ?? 150ms,
///                   ↑ DialogRoute **只**传了 transitionDuration，
///                     没有传 reverseTransitionDuration
/// routes.dart:234-235
///                   final Duration duration = transitionDuration;
///                   final Duration reverseDuration = reverseTransitionDuration;
///                   ↑ reverseTransitionDuration 的默认值**就是** transitionDuration
/// ⇒ 给 `AnimationStyle(reverseDuration: …)` 对 showDialog **完全无效**
///   （它只对 showModalBottomSheet 有效：bottom_sheet.dart:250 单独读了它）。
/// ```
/// ⇒ 所以 `OverlayMotion.sheetAnimationStyle()` 里那个 `reverseDuration` 只有
///   bottom sheet 吃得到；**不许**为了"让 showDialog 退场更快"去改框架行为
///   （例如自建 `RawDialogRoute` —— 那会丢掉 `_FullWindowDialogWrapper` /
///   `_DialogPopScope` 等 3.47 才有的对话框语义）。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
}) => showDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
  barrierColor: barrierColor,
  barrierLabel: barrierLabel,
  useSafeArea: useSafeArea,
  useRootNavigator: useRootNavigator,
  routeSettings: routeSettings,
  anchorPoint: anchorPoint,
  traversalEdgeBehavior: traversalEdgeBehavior,
  fullscreenDialog: fullscreenDialog,
  requestFocus: requestFocus,
  // ★ 全仓唯一一处把动效接上 showDialog 的地方
  animationStyle: overlaySheetAnimationStyle(context),
);

/// 浮层的**退场**动效：卸载前先淡出 —— task-104
///
/// ══════════════════════════════════════════════════════════════════════
/// # 用户原话（桌面端 9 条问题 · 第 7 条）
/// ══════════════════════════════════════════════════════════════════════
/// ```text
/// 很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化
/// ```
/// task-99 做的是**入场**（`OverlayScrim` / `OverlayCardMotion`）；
/// 本件补**退场** —— 改前那三个面板的挂载点是
/// `if (_danmakuSheetOpen) DanmakuSettingsDialog(...)`，flag 翻 false 的
/// **那一帧**子树就被移除了（一帧硬切，"关"比"开"还生硬）。
///
/// ══════════════════════════════════════════════════════════════════════
/// # 用法：本件**常挂**，真源是 `visible`
/// ══════════════════════════════════════════════════════════════════════
/// ```dart
/// // ★ 直接做 Stack 的孩子，**不要**再套 `if (_xOpen)` / 三元
/// SheetExitMotion(
///   visible: _danmakuSheetOpen,
///   child: DanmakuSettingsDialog(..., fill: false),
/// ),
/// ```
/// ★ 为什么必须**常挂**（这是本件的核心约束，写错就完全没有退场动画）：
/// ```text
/// 若写成 `if (_xOpen) SheetExitMotion(...)`：
///   flag 翻 false ⇒ 那个 Element **被整个移除** ⇒ 框架走
///   deactivate/unmount，**根本不会调 didUpdateWidget** ⇒ 没有 reverse、
///   没有淡出 —— 与改前的"一帧硬切"**一模一样**。
/// ⇒ 只有让本件的 Element 一直在树上、只让 `visible` 变化，
///   才能拿到"先淡出、跑完再卸载"这条时间线。
/// ```
///
/// ══════════════════════════════════════════════════════════════════════
/// # ★★ 为什么面板自己不能再写 `Positioned.fill`（`fill: false` 的由来）
/// ══════════════════════════════════════════════════════════════════════
/// 三个面板的根节点原本是 `Positioned.fill`，而 `Positioned` 是
/// `ParentDataWidget<StackParentData>` ⇒ **只能做 `Stack` 的直接孩子**。
/// 本件要在中间放 `Opacity` / `IgnorePointer`（都产生 RenderObject）⇒
/// 面板的父链变成 `… → RenderIgnorePointer → Positioned`（**不是** RenderStack）
/// ⇒ 两个 ParentDataWidget 争同一个 StackParentData ⇒ 抛
/// `Incorrect use of ParentDataWidget`（这条阻断级教训见 `_SheetScrim`
/// 的类文档与 `probe_tests/zz_t70_positioned_probe_test.dart`）。
/// ⇒ 所以给三个面板各加一个 `bool fill = true`：`fill: false` 时面板
///   **直接返回内容**（不再自己写 `Positioned.fill`），定位交给本件。
///   ★ 默认 true ⇒ 既有 6 个测试文件 / 探针里的直接挂载**一字不用改**。
///
/// ⚠️ `fill: false` 时面板靠 `Center`（`widthFactor == null` ⇒ 撑满有界约束）
///    拿到全屏尺寸 —— 与 `Positioned.fill` 的 tight 约束**几何等价**
///    （`Positioned.fill` 本来就是"填满父 Stack"，见
///     `overlay.dart:2813-2823` 的"so developers can use the Positioned widget"）。
///
/// ══════════════════════════════════════════════════════════════════════
/// # ★★ 为什么**不是** `SheetTransition` 的子类、也不给它加参数
/// ══════════════════════════════════════════════════════════════════════
/// `find.byType(X)` 是**精确**匹配 `widget.runtimeType == X`（子类/父类都不匹配）
/// ⇒ 独立新类**不会**改变 `find.byType(SheetTransition)` 的命中数：
/// `player_panel_wiring_test` 的组 A（阳性对照）/ 组 B（slideFrom）/
/// 组 D（≥2 个）与 `sheet_close_animation_test` 全部不受影响。
/// 反过来，若给 `SheetTransition` 加参数或让它多一层，那 4 组断言与
/// 18 个 import 了 `episode_strip.dart` 的测试文件都要重新评估。
///
/// ══════════════════════════════════════════════════════════════════════
/// # 与 `SheetTransition` 的分工（两个都是"退场"，别混）
/// ══════════════════════════════════════════════════════════════════════
/// ```text
/// SheetTransition   自实现全屏浮层的**入场 + 退场**（带位移：右抽屉 (24,0) /
///                   底部 (0,24)）—— 用在选集 / 直播 / 线路三个面板上，
///                   它们的父链是 Positioned.fill → SheetTransition → …
/// SheetExitMotion   只做**退场淡出**（无位移）—— 用在弹幕设置 / B 站导入 /
///                   字幕面板上；入场由 OverlayScrim / OverlayCardMotion 负责
///                   ⇒ 同一个方向不会动两次（避免"抖动/双重动画"）
/// ```
///
/// # Reduce Motion（无障碍）
/// `MotionPrefs.reduce(context)` ⇒ **第 0 帧直接卸载**，不走 reverse。
/// 判据：Reduce Motion 下"关"必须是**立即**的（同族契约见
/// `motion_prefs.dart:60-66` 与 `tokens.dart` 的 `OverlayMotion`）。
class SheetExitMotion extends StatefulWidget {
  const SheetExitMotion({
    super.key,
    required this.visible,
    required this.child,
    this.duration = OverlayMotion.exitDuration,
    this.curve = OverlayMotion.exitCurve,
  });

  /// 是否应当**在位**（真源在宿主：`_danmakuSheetOpen` 这类 flag）
  final bool visible;

  /// 被淡出的子树
  final Widget child;

  /// 退场时长 —— 默认 [OverlayMotion.exitDuration]（= cardDuration，260ms）
  final Duration duration;

  /// 退场曲线 —— 默认 [OverlayMotion.exitCurve]（= cardCurve）
  final Curve curve;

  @override
  State<SheetExitMotion> createState() => _SheetExitMotionState();
}

class _SheetExitMotionState extends State<SheetExitMotion>
    with SingleTickerProviderStateMixin {
  /// 1.0 = 在位，0.0 = 淡出到底（★ 与 `SheetTransition` 同款：初值跟 visible）
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.visible ? 1.0 : 0.0,
  );

  /// 子树是否还挂在树上 —— `reverse` 跑完才置 false
  late bool _mounted = widget.visible;

  @override
  void didUpdateWidget(SheetExitMotion old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;

    if (widget.visible) {
      // 再打开：直接落到"在位" —— ★ **不接管入场**
      //   （入场由 OverlayScrim / OverlayCardMotion 自己跑，否则同一段路
      //    会动两次；这条与 SheetTransition:1138-1159 同一决策）
      _c.value = 1.0;
      setState(() => _mounted = true);
      return;
    }

    // ★ Reduce Motion ⇒ 不走 reverse，**第 0 帧**就卸载
    if (MotionPrefs.duration(context, widget.duration) == Duration.zero) {
      setState(() => _mounted = false);
      return;
    }

    _c.reverse().whenComplete(() {
      if (mounted) setState(() => _mounted = false);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 卸载态：仍占着 Stack 里的那一格（0×0）——
    // ★ 不能返回 null，本件是**常挂**的 Stack 孩子
    if (!_mounted) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Opacity(
        // ★ 必须是 Opacity（**不能**用 FadeTransition）：后者内部是
        //   RenderAnimatedOpacity，树上**没有** Opacity 节点 ⇒ 测试与调试
        //   都读不到实际值（文件头 :25-35 与 zz_t44_fade_in_test.dart:78-88）
        opacity: widget.curve.transform(_c.value).clamp(0.0, 1.0),
        child: child,
      ),
      // ★ 退场期间**立即**停止接收点击：Opacity 只影响绘制、不影响命中测试
      //   ⇒ 不包的话用户点"正在淡出的"面板会打在已经关闭的面板上
      //   （同 SheetTransition 的类文档：那条 = 用户报的"点了没反应"）
      child: IgnorePointer(ignoring: !widget.visible, child: widget.child),
    );
  }
}
