// ═══════════════════════════════════════════════════════════════════════
//  空间导航（Spatial Navigation）：让遥控器方向键真的能移动焦点
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须自己实现（2026-09-23 TV 实测复现）
//
// 原版 `src/design/spatialNav.ts`（176 行）几乎照写进这个文件，
// 我在 Flutter 版里**砍掉了一大半**。实测证据（Android TV，ADB 方向键）：
//
// ```text
// 按 ↑ 后  Focus @(12,469) 187x71     ← 源条上的第一个 pill
// 按 ↓ 后  Focus @(12,469) 187x71     Δ=(0,0)   ✗ 焦点没动
// 按 ← 后  Focus @(12,469) 187x71
// 按 → 后  Focus @(12,469) 187x71     Δx=0      ✗ 焦点没动
// ```
//
// 结果是 *遥控器根本没有焦点* —— 这反倒指对了症（遥控器方向键操作不了）。
//
// ## 两个原因（都实测确认过）
//
// **① ↑↓←→ 被我自己的全局 handler 吃掉了**
//
// shell 里为了 TV 上用方向键切 tab，注册了
// `HardwareKeyboard.instance.addHandler(_onGlobalKey)`，对 ↑↓←→ 直接 `return true`。
//
// ⚠️ 关键：`HardwareKeyboard` 的 handler 跑在
//    **焦点树派发之前**。一旦返回 `true`，事件就被标记为已处理，
//    `FocusManager` **再也不会**把它派发给当前焦点 →
//    `DirectionalFocusIntent` 永远不触发。
//
// **② ↑↓←→ 落到 Scrollable 手里，变成"滚页"而不是"移焦点"**
//
// 这是 Flutter/浏览器的一直行为（原版 Chromium 上实测的：
// scrollTop 0→0→0→0 完全对应）。所有能滚动 **不代表**"能选片"。
//
// ## ③ 我上一轮为什么"判断我通过"
//
// 我按了方向键、截图看**发现、设置、切下去了**，就写了
// 「D-pad navigation confirmed working」。但那只验证了
// **tab 切换**，完全没验证 *内容区焦点移动* ——
// 顶多能说"看的是靠的是后者"。
// 原版注释里讲过这**是假象**，并且记录过完全相同的教训：
//
// > 我用 `Tab` 验证的焦点，真是 *遥控器上就没有 Tab 键*。
// > 我现在有 12/12 通过"是假象。"
//
// # 算法（照抄原版的几何邻居 + 交叉轴权重）
//
// 按方向键时：
// ```text
// 1. 取当前焦点的矩形
// 2. 在所有可聚焦节点里找，中心点在右半侧的候选
// 3. cost = dx + |dy| * 2.2   ← 取代价最小的
// ```
// 交叉轴给更大权重（2.2），是为了 *优先走同一行*（一排卡片从左到右移动），
// 而不是"傻直直跑到下一行的某个元素"。
//
// # 为什么不甪 Flutter 内建的 `DirectionalFocusIntent`
//
// 实测（`test/directional_focus_test.dart`）：内建遍历在 *合成树* 里是好的
// （right=1 down=3）。但它在真实壳里不成立，因为：
// ```text
// · ↑↓←→ 被全局 handler 提前消费掉（见原因①）
// · ↑↓←→ 被 Scrollable 抢走去滚动（见原因②）
// ```
// 而且内建策略是 **按阅读顺序** 扫下一个，对"两列不同高度的卡片"
// 会给出很*不合直觉*的结果。原版效用几何邻居，理由是
// 「优先走同一行」。这里保持一致。
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 方向
enum NavDir { up, down, left, right }

/// 交叉轴权重 —— **左右方向**用（照抄原版 `CROSS_WEIGHT = 2.2`）
///
/// 值越大越"只肯走同一行/列"。一排卡片能顺畅左右走，
/// 同时允许"斜下到下一行的对应位置"。
const double _crossWeightHorizontal = 2.2;

/// 交叉轴权重 —— **上下方向**用（照抄原版 `VERTICAL_CROSS_WEIGHT = 0.25`）
///
/// # ★★★ 为什么上下必须用**小得多**的权重（原版记的真 bug，我原样踩到了）
///
/// 原版在详情页实测（逐候选打印）：
/// ```text
/// 起点 返回按钮 cx=83 bottom=62
///   继续观看  top=260 cx=370  main=198 cross=287  cost=198+287x2.2=829
///   HD       top=483 cx=118  main=421 cross= 35  cost=421+ 35x2.2=498 <- 选中
/// ```
/// 于是焦点**跳过中间那排**直达 HD，而那排
/// （继续观看 / 收藏 / 追更 / 换源）**从任何位置都到不了** ——
/// TV 用户因此无法收藏、追更、换源。
///
/// 根因：`cross x 2.2` 让"横向对齐但隔了两排"赢过"横向错开但在正下方"。
/// 而遥控器 down 的直觉恰恰是「到**下面那一排**」。
///
/// 换成 0.25 后：
/// ```text
///   继续观看 = 198 + 287x0.25 = 270  <- 选中 OK
///   HD      = 421 +  35x0.25 = 430
/// ```
///
/// 同一排内的元素 `top` 相同 -> `main` 相等 -> cost 由 cross 决定 ->
/// 仍然选横向最近的那个。即「**先到那一排，再到那一列**」，符合直觉。
const double _crossWeightVertical = 0.25;

/// 上下方向交叉轴的**固定上限**（照抄原版 `VERTICAL_CROSS_LIMIT = 360`）
///
/// # 为什么不用"元素宽度 x 1.4"（原版记的第二个真 bug）
///
/// 详情页布局：
/// ```text
/// +-- 返回按钮（小，cx=83，宽 38）
/// |        继续观看  已收藏  追更中  换源    <- cx=370~752
/// +-- HD（剧集按钮，cx=118）
/// ```
/// 从返回按钮按 down，若用 `crossLimit = 宽38 x 1.4 = 53px`：
/// ```text
/// 「继续观看」偏移 = |370-83| = 287px  -> 被过滤
/// 「HD」      偏移 = |118-83| =  35px  -> 通过
/// => 焦点跳过中间那排，那排**一次都到不了**
/// ```
/// 左右移动时交叉轴是纵向偏移，同一行元素纵向对齐，用高度当阈值对；
/// **上下移动时交叉轴是横向偏移**，而上下相邻两行的横向起点常常完全不同，
/// 用小元素的宽度当阈值必然误杀。所以纵向用固定值。
const double _verticalCrossLimit = 360;

/// 主轴最小推进量（照抄原版 `MIN_ADVANCE = 4`）
///
/// 用 4px 而不是 0：相邻元素边缘常有取整误差，
/// 用 0 会把"同一位置的另一个元素"也算成邻居。
const double _minAdvance = 4.0;

/// 同组的成本优惠（照抄原版 `sameGroup ? 40 : 0`）
///
/// 让焦点**优先在本区块内**移动，找不到才跨区块 ——
/// 否则从"电影"那一排按 down 可能跳到"综艺"那一排，
/// 用户会觉得跳得莫名其妙。
const double _sameGroupBonus = 40;

/// 最近一次 `_collect()` 收集到的候选矩形（诊断 / 防复发断言用）
///
/// # 为什么必须把它暴露出来（2026-09-25 实测，任务 AI）
///
/// 缺陷①的**危害**是"焦点不动"，但**根因**是"候选池里混进了一个全屏 scope"。
/// 只断言危害是不够的：同一个 scope 换个布局就会以别的方式造成危害
/// （比如把 `primeFocus` 的落点抢走），而那时"焦点没动"这个症状
/// **根本不会出现**，防复发断言就失效了。
///
/// 所以断言必须能直接看到**候选集合本身**。`_collect()` 是私有的，
/// 外部原来只能看到 `spatialNavLog` 里的一个**计数** ——
/// 而计数无法区分「27 个真控件」和「26 个真控件 + 1 个全屏 scope」。
///
/// 与 [spatialNavLog] 同一个思路：把内部状态暴露出来，
/// 让证据覆盖到**根因**，而不只是症状。
final List<Rect> spatialNavCandidates = [];

/// 最近一次 [moveFocus] **自动 prime** 时种下的焦点矩形（没发生则为 null）
///
/// # 为什么单独记这一条（真机验证的关键证据）
///
/// 「进了详情页，方向键能动」有两种完全不同的成因：
/// ```text
/// A. 焦点本来就落在一个真控件上 → moveFocus 正常算邻居
/// B. 焦点在容器上 → moveFocus **先 prime 再算邻居**（本次修复的行为）
/// ```
/// 只看"焦点动了"分不出这两者，而它们的**回归风险完全不同**：
/// B 是新加的分支，一旦落点规则退化（比如又种到容器上），
/// 症状会和修复前一模一样 —— 只是更难发现，因为"能动"过。
///
/// 所以真机日志必须能把 B 单独指认出来。
Rect? spatialNavPrimedRect;

/// 一个可聚焦目标
class _Candidate {
  _Candidate(this.node, this.rect, this.group);

  final FocusNode node;
  final Rect rect;

  /// 所属导航组（同组有成本优惠）
  final Object? group;
}

/// 该节点是不是一个**真正可落焦点的叶子控件**
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 缺陷①的根因与修法（2026-09-25 实测，任务 AI）
/// ══════════════════════════════════════════════════════════════════════
///
/// # 现象（实测输出，960x540）
///
/// ```text
/// 当前焦点 = 顶部按钮 (430,0,530,40)        ← 水平居中
/// moveFocus(down) => moved=true
///   log: 选中=(0,0,960,540)                ← ★ 全屏矩形赢了
/// 目标卡片 hasPrimaryFocus=false            ← ★ 焦点**实际没动**
/// ```
///
/// `moveFocus` 返回 `true`（"我请求移焦了"），但焦点**一步都没走**。
/// 这正是本项目反复强调的那条：「某个按键有反应」≠「这个按键完成了它该完成的事」。
///
/// # 为什么全屏 scope 会赢
///
/// `_collect()` 原来的过滤条件是：
/// ```dart
/// if (child.canRequestFocus && !child.skipTraversal) { ... }
/// ```
/// 而 `FocusScopeNode`（`View Scope` / `Navigator Scope` /
/// `_ModalScopeState Focus Scope`）**满足这两个条件**，
/// 且它们的 `RenderBox` 矩形是**整屏**。代价函数下：
/// ```text
/// 目标卡片 = main(160) + cross(0)*0.25 = 160
/// 全屏scope = main(0-40 -> clamp 0) + cross(0)*0.25 = 0    ← 必然更低
/// ```
/// 只要当前焦点元素的中心**靠近屏幕中心**，`cross` 就趋近 0，
/// 全屏 scope 必然以最低成本赢走这次移动。
///
/// # 为什么真机探针一直没抓到
///
/// 触发条件是"当前焦点中心靠近屏幕中心"。首页元素都在**左侧**
/// （源条 pill、左侧海报卡），`cross` 很大 → scope 赢不了。
/// 所以这是一个**只有居中布局才会暴露**的缺陷 —— 靠真机首页永远测不出来。
///
/// # 为什么不能用 `descendantsAreFocusable == false`
///
/// 一度考虑用「叶子节点才算候选」（`child.descendantsAreFocusable == false`）。
/// 实测全量 dump 后**否决**了 —— 这个版本里
/// **每一个**节点的 `descendantsAreFocusable` 都是 `true`：
/// ```text
/// [候选] View Scope        descFocusable=true
/// [候选] Navigator Scope   descFocusable=true
/// [候选] _ModalScope Focus Scope descFocusable=true
/// [候选] A (真控件)        descFocusable=true
/// ```
/// 用它过滤会**把所有候选清空**，方向键彻底失效 —— 比原缺陷更严重。
///
/// # 原版是怎么过滤的（这才是判据的真正来源）
///
/// 原版 `spatialNav.ts` 用 `querySelectorAll(FOCUSABLE_SELECTOR)`，
/// 而那个选择器只匹配 `a[href]` / `button` / `input` /
/// `[tabindex]:not([tabindex="-1"])` / `[role="button"]` ——
/// **全是真正承载焦点的叶子控件**。
/// DOM 里根本没有"焦点容器也是元素"的概念，所以原版**天然不会**把容器当候选。
///
/// Flutter 的焦点树不一样：**容器（`FocusScopeNode`）本身就是一个 `FocusNode`**，
/// 而且 `canRequestFocus == true`。照抄原版的过滤条件时漏掉了这一层语义差异，
/// 于是容器混进了候选池。这就是缺陷①的来源。
///
/// 所以修法就是**把原版天然成立的那个不变量显式写出来**：
/// 候选只能是"本身可聚焦、且**不包含任何其他可聚焦后代**"的节点。
///
/// # 为什么用「无子节点」而不是「无**可聚焦**子节点」
///
/// ```text
/// child.children.isEmpty          ← 用的是这个
/// ```
/// 因为"有子节点但都不接受焦点"的容器（比如 `FocusTraversalGroup`）
/// 本来就被 `canRequestFocus == false` 挡掉了；
/// 而按 `children` 判可以**同时**排除掉那些
/// 「自己可聚焦 + 有可聚焦子节点」的中间层 —— 那种节点才是
/// 真正会造成"焦点落到看不见的容器上"的元凶。
///
/// ⚠️ 被排除的只是**作为导航目标**的资格，
///    `walk()` 仍然会递归进它的子节点 —— 所以页面里的真控件一个都不会丢。
bool _isLeafFocusTarget(FocusNode node) => node.children.isEmpty;

/// 收集当前树里**真正可见且可聚焦**的节点
///
/// # 为什么要自己过滤，不能用 `traversalDescendants`
///
/// `FocusNode.traversalDescendants` 会把**所有**后代都给你，包括：
/// ```text
/// · 在 IndexedStack 里没显示的那 4 个 tab 的节点
///   （它们在树里但不可见 —— 会把焦点带到一个看不见的页面上）
/// · 尺寸为 0 的占位节点
/// · canRequestFocus == false 的拦截器节点
/// ```
/// 原版注释里也强调过同类问题：
/// > "元素在视口外时 getBoundingClientRect() 仍然给坐标 ——
/// >  所以要按可见矩形裁剪，否则会跳到看不见的元素上"
///
/// * **不按可见性裁剪** —— 这是照抄原版的关键一步。
///
///   # 为什么不能裁（2026-09-23 我裁错了，↓ 直接失效）
///
///   我第一版加了"矩形必须与屏幕相交"的过滤，结果 TV 实测：
///   ```text
///   [导航] 候选=27 | 方向=down | 方向不符=26 交叉轴超限=0 进入比较=0
///          | 没有可用邻居 -> 不动
///   ```
///   **按 ↓ 一个候选都不剩** —— 因为源条在 y=469、屏幕逻辑高 540，
///   下面那一排海报卡**在屏幕外**，全被裁掉了。
///   而"往下走"恰恰意味着目标**本来就在屏幕外**。
///
///   原版的做法是：**收集全部 → 选几何上最合适的 → 把它滚进可视区**。
///   所以裁剪这一步是错的，滚动才是对的（见 `_scrollIntoView`）。
List<_Candidate> _collect() {
  final root = FocusManager.instance.rootScope;
  final out = <_Candidate>[];

  void walk(FocusNode node, Object? group) {
    for (final child in node.children) {
      /*
       * 组标识：Flutter 没有 `data-nav-group` 的等价物，
       * 这里退化成**最近的 Scrollable 祖先** —— 语义等价：
       * 「同一个横排/区块」通常就在同一个 Scrollable 里。
       */
      Object? childGroup = group;
      final ctx = child.context;
      if (ctx != null) {
        ctx.visitAncestorElements((el) {
          final w = el.widget;
          if (w is Scrollable) {
            childGroup = w;
            return false;
          }
          return true;
        });
      }

      /*
       * ★ 候选必须是**叶子焦点目标**（见 [_isLeafFocusTarget] 的完整推导）
       *
       * 原来的条件 `child.canRequestFocus && !child.skipTraversal`
       * 会把 `FocusScopeNode`（矩形 = 整屏）也收进来 —— 缺陷①。
       * 补上叶子判据后，容器层被排除，真控件一个不少。
       */
      if (child.canRequestFocus &&
          !child.skipTraversal &&
          _isLeafFocusTarget(child)) {
        final ro = child.context?.findRenderObject();
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          final size = ro.size;
          if (size.width > 1 && size.height > 1) {
            final rect = ro.localToGlobal(Offset.zero) & size;
            out.add(_Candidate(child, rect, childGroup));
          }
        }
      }
      walk(child, childGroup);
    }
  }

  walk(root, null);

  /*
   * 把候选矩形同步出去（[spatialNavCandidates]）——
   * 让外部能直接断言"候选池里没有全屏容器"，而不是只能看一个计数。
   */
  spatialNavCandidates
    ..clear()
    ..addAll(out.map((c) => c.rect));

  return out;
}

/// 当前焦点矩形（拿不到返回 null）
Rect? _currentRect() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  final ro = ctx?.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 诊断输出（探针用；生产里只是个空列表，无开销）
///
/// * 为什么要留这个钩子（2026-09-23）
///
/// 第一次接上空间导航后，`->` 能移动但 `down` 不动。
/// 光看"没动"无法判断是：
/// ```text
/// A. 根本没收集到候选（收集逻辑漏了）
/// B. 收集到了但都被代价函数筛掉（算法参数问题）
/// C. 收集到了、选了，但 requestFocus 失败
/// ```
/// 这三种的修法完全不同。把内部数字暴露出来才能一次定位。
final List<String> spatialNavLog = [];

/// ★ 真机导航追踪开关（2026-09-24，任务 AH）
///
/// # 为什么必须做成**编译期**开关
///
/// Android TV 上验证遥控器时，`spatialNavLog` 只在**进程内**存在 ——
/// 而真机（release APK）没有调试器能读它。原版交付时踩过的坑：
/// ```text
/// 只看截图 hash 变化 → 分不清「焦点真的移到了正确的控件」
///                      还是「画面因为别的原因变了」
/// ```
/// 截图 hash 相同更糟：既可能是"没动"，也可能是**探针本身失效**
///（本项目历史上误判过一次：机器锁屏后抓到的全是锁屏画面）。
///
/// 所以真机验证必须有一条**独立的、机器可读的**证据通道。
/// 这里把它接到 `debugPrint` → logcat。
///
/// # 为什么用 `bool.fromEnvironment` 而不是普通常量
///
/// ```text
/// 不传 --dart-define=TV_NAV_TRACE=true → 常量折叠成 false
///                                        → 整段追踪代码被 tree-shake 掉
/// ```
/// 也就是**生产包零开销、零日志噪音**，只有显式打开的真机测试包才有输出。
/// 这比"运行时判断一个全局变量"干净 —— 后者会把字符串拼接的开销
/// 留在生产包里。
///
/// ⚠️ 追踪走 `print` 而不是 `debugPrint` —— 理由见 `_traceNav` 的文档
///    （`debugPrint` 默认节流，会**静默丢行**，实测造成过假象）。
const bool _navTrace = bool.fromEnvironment('TV_NAV_TRACE');

/// ★★ 「只算不搬」模式（2026-09-24，用来定位"一次按键走两格"）
///
/// # 为什么需要这样一个开关
///
/// 真机抓到：一次 RIGHT 让焦点**前进两格**。
/// 而 `moveFocus` 的入口日志只有**一行** —— 说明它只跑了一次。
/// 那第二格是谁搬的？两个候选：
/// ```text
/// A. 我这边 requestFocus 之后，Flutter 内建的方向遍历**又搬了一次**
/// B. 别的什么代码在抢焦点
/// ```
/// 光看"焦点最终在哪"永远分不出来。
///
/// 打开这个开关后 `moveFocus` **照常算出邻居、但不调用 requestFocus**：
/// ```text
/// 按一次 RIGHT 后焦点仍然前进了一格  → A 成立（内建遍历在搬）
/// 焦点完全不动                       → 只有我的 requestFocus 在搬，A 不成立
/// ```
/// 这是**因果实验**（去掉自变量看因变量），比继续读日志可靠 ——
/// 读日志只能给出相关性，去掉一个变量才能定因果。
///
/// ⚠️ 编译期常量，不传就是 false —— 生产包不受影响。
const bool _navDryRun = bool.fromEnvironment('TV_NAV_DRYRUN');


/// 结构层噪音 —— 这些类型每个控件都有，打印出来只会挤掉有信息量的
///
/// ⚠️ 我第一版只过滤了 `_Inherited*` 系列，结果真机日志长这样：
/// ```text
/// MouseRegion<_ActionsScope<Actions<FocusableActionDetector<_BottomItem<SizedBox
/// ```
/// **真正有判别力的 `_BottomItem` 被挤到第 5 位** ——
/// 而外面判读的脚本只取前 3 层，于是「底栏 tab」和「海报卡」
/// 都显示成 `_ActionsScope/Actions/...`，**完全分不出来**。
/// 那正是这次验证最需要区分的一件事（焦点到底在底栏还是内容区）。
///
/// 教训：探针的**输出格式**要按"判读者需要什么"设计，
/// 而不是按"树上有什么"原样倾倒。
const Set<String> _focusNoise = {
  // 焦点/动作包装（每个可聚焦控件都有）
  'MouseRegion', '_ActionsScope', 'Actions', 'FocusableActionDetector',
  '_ParentInkResponseProvider', '_InkResponseStateWidget',
  '_FocusInheritedScope', 'Focus', '_FocusMarker',
  // 纯布局
  'SizedBox', 'Padding', 'Center', 'Column', 'Row', 'Stack', 'Wrap',
  'RepaintBoundary', 'Semantics', 'Builder', 'ClipRect', 'ClipRRect',
  'AnimatedContainer', 'Container', 'DecoratedBox', 'Opacity',
  // 主题/环境注入
  'MediaQuery', 'Directionality', 'DefaultTextStyle', 'IconTheme',
  'AnimatedDefaultTextStyle', 'AnimatedTheme', 'Theme', '_InheritedTheme',
  'FTheme', 'FTooltip', 'Localizations', 'Shortcuts', 'DefaultSelectionStyle',
};

/// 焦点节点的**结构身份** —— 真机验证"焦点到了哪个控件"的唯一可靠手段
///
/// # 为什么不能只报矩形
///
/// 「某个按键有反应」≠「这个按键完成了它该完成的事」。
/// 矩形 `(36,202,184,468)` 只能说明"有个东西在左上角"，
/// **完全无法断言**它是海报卡、是底栏 tab、还是标题栏按钮。
/// 而"焦点停在追更 tab 上"和"焦点停在设置 tab 上"在截图上
/// 可能只是 100px 的差别，肉眼和 hash 都判不准。
///
/// 所以这里向上走元素树，取**真实 widget 类型名**（已滤掉 [_focusNoise]）：
/// ```text
/// _BottomItem<_BottomBar<BottomBarMarker   → 底栏 tab（★ 一眼可判）
/// PosterCard<...                           → 海报卡
/// ```
///
/// # 为什么 `runtimeType.toString()` 在 release 包里可用
///
/// `flutter build apk --release` **默认不做符号混淆**
///（要 `--obfuscate` 才会把类名换成 `a`/`b`）。
/// 本项目的 Android 构建命令没有 `--obfuscate`，所以类名是真的。
/// 这一点必须写下来 —— 否则将来有人加了混淆，
/// 这条证据会**静默失效**（打印出一堆 `a<b<c`），
/// 而"静默失效的证据"比没有证据更危险。
String _describeFocus(FocusNode? node, {int depth = 6}) {
  if (node == null) return '<null>';
  final label = node.debugLabel;
  final parts = <String>[];

  final ctx = node.context;
  if (ctx != null) {
    ctx.visitAncestorElements((el) {
      final t = el.widget.runtimeType.toString();
      if (!_focusNoise.contains(t) && !t.startsWith('_Inherited')) {
        parts.add(t);
      }
      return parts.length < depth;
    });
  }
  final chain = parts.isEmpty ? '?' : parts.join('<');
  return label == null ? chain : '$label:$chain';
}

/// 把一次导航决策打到 logcat（只在 `TV_NAV_TRACE=true` 的构建里有内容）
///
/// # ★ 为什么这里用 `print` 而不是 `debugPrint`（2026-09-24 实测踩到）
///
/// `debugPrint` 默认绑的是 **`debugPrintThrottled`** —— 它为了不把日志冲爆，
/// 会**静默丢弃**积压的输出（内部有个 1 秒的 stopwatch，超时就
/// `_debugPrintBuffer.clear()`）。
///
/// 而这条追踪每次按键要打两行、每行两三百字符。真机上实测到的症状：
/// ```text
/// RIGHT#5   hash 变了，但 [NAV] 一行都没有   ← 看起来像"按键没被处理"
/// DOWN#2..#8 同样一行都没有                  ← 看起来像"方向键失灵"
/// ```
/// **两个都是探针丢行造成的假象**，不是应用的问题。
/// 差一点就据此写出一条错误结论（"DOWN 键被吞"）。
///
/// 这正是本项目反复记录的那类错误：**证据通道自身不可靠时，
/// 得出的结论比没有结论更危险**。
///
/// 修法：追踪走 `print`（不节流）。因为 [print] 只在
/// `TV_NAV_TRACE=true` 的构建里才可达，生产包会被常量折叠整段删掉，
/// 所以不存在"把生产日志冲爆"的顾虑。
void _traceNav(String tag) {
  if (!_navTrace) return;
  final focus = FocusManager.instance.primaryFocus;
  final r = _currentRect();
  // ignore: avoid_print
  print('[NAV] $tag | ${spatialNavLog.join(" | ")} '
      '| 焦点=${_describeFocus(focus)}'
      // 矩形也带上 —— 控件身份说明"是谁"，矩形说明"在哪"，
      // 两者合起来才能判断"这一步走得对不对"
      '| 矩形=${r == null ? "<null>" : _fmtRect(r)}');
}

/// 找几何邻居（原版 `findNeighbor`）
///
/// [exclude] 用来做"先在某个范围内找"的两轮搜索（见 `moveFocus`）。
_Candidate? _findNeighbor({
  required NavDir dir,
  required Rect from,
  required List<_Candidate> candidates,
  required FocusNode? cur,
  required Object? curGroup,
  bool Function(_Candidate)? exclude,
  Rect? viewport,
}) {
  final isHorizontal = dir == NavDir.left || dir == NavDir.right;
  final fromCx = from.center.dx;
  final fromCy = from.center.dy;

  _Candidate? best;
  var bestCost = double.infinity;
  var rejectedDir = 0;
  var rejectedCross = 0;
  var offscreen = 0;
  var considered = 0;

  for (final c in candidates) {
    if (identical(c.node, cur)) continue;
    if (exclude?.call(c) ?? false) continue;

    /*
     * ★ 视口闸门（只有传了 `viewport` 才启用）
     *
     * 只保留**与视口相交**的候选 —— 这是"两轮搜索"的第一轮
     * （调用方见 `_findNeighborInViewport`）。被挡掉的记进 `越界=N`。
     *
     * ⚠️ 这里只是"**这一轮**不看它"，**不是从候选池里删掉**：
     * 第一轮空手而归时调用方会不带 `viewport` 再找一遍（第二轮）。
     * 早先"直接裁候选池"的写法让 ↓ 彻底失效 ——
     * 实测日志 `候选=27 | 方向=down | 进入比较=0 | 没有可用邻居 -> 不动`，
     * 见 `_scrollIntoView` 的文档。
     */
    if (viewport != null && !c.rect.overlaps(viewport)) {
      offscreen++;
      continue;
    }

    final r = c.rect;
    final cx = r.center.dx;
    final cy = r.center.dy;

    /*
     * 主轴推进量 `main` 与交叉轴偏移 `cross`。
     *
     * 上下方向**不能用"整条边在外"**判据。
     *
     * 原版实测（TV 首页）：当前卡片 top=670 bottom=1080，底栏 top=985。
     * ```text
     * down 时算底栏: main = 985 - 1080 = -95 < -4 -> 被跳过
     * ```
     * 底栏是**浮在卡片上**的部分重叠元素 ->
     * 用边判据会被永久排除，而它恰恰是屏幕最下方那一排。
     *
     * 所以上下改用**中心点差**：
     * ```text
     * down: 候选中心在下方（c.cy > cur.cy）且距离超过 MIN_ADVANCE
     * ```
     */
    final double main;
    final double cross;
    switch (dir) {
      case NavDir.right:
        main = r.left - from.right;
        cross = (cy - fromCy).abs();
      case NavDir.left:
        main = from.left - r.right;
        cross = (cy - fromCy).abs();
      case NavDir.down:
        main = r.top - from.bottom;
        cross = (cx - fromCx).abs();
      case NavDir.up:
        main = from.top - r.bottom;
        cross = (cx - fromCx).abs();
    }

    if (isHorizontal) {
      if (main < -_minAdvance) {
        rejectedDir++;
        continue;
      }
    } else {
      // 上下：用中心点差判方向（允许部分重叠）
      final centerDelta = dir == NavDir.down ? cy - fromCy : fromCy - cy;
      if (centerDelta < _minAdvance) {
        rejectedDir++;
        continue;
      }
    }

    final crossLimit =
        isHorizontal ? math.max(from.height, 1) * 1.4 : _verticalCrossLimit;
    if (cross > crossLimit) {
      rejectedCross++;
      continue;
    }
    considered++;

    /*
     * `main` 可能是负数（部分重叠时）—— 必须夹到 0 以上，
     * 否则"重叠越多、成本越低"，会优先跳到几乎重合的元素上。
     */
    final crossWeight =
        isHorizontal ? _crossWeightHorizontal : _crossWeightVertical;
    final sameGroup = curGroup != null && c.group != null && curGroup == c.group;
    final cost = math.max(main, 0) +
        cross * crossWeight -
        (sameGroup ? _sameGroupBonus : 0);

    if (cost < bestCost) {
      bestCost = cost;
      best = c;
    }
  }

  spatialNavLog.add('  方向=$dir 不符=$rejectedDir 交叉超限=$rejectedCross '
      '越界=$offscreen 比较=$considered');
  return best;
}

/// 视口优先的两轮搜索（★ 修"焦点落到屏幕外"）
///
/// # 为什么要有这一层
///
/// 真机实测（2026-09-23，emulator-5554 冷启动 → 底栏 autofocus → 连按 ↑）：
/// ```text
/// #2 [NAV] dir=NavDir.up 当前=(36,167,184,433) | 不符=15 交叉超限=2 比较=3
///        | 选中=(96,-74,192,-38)      ← y 为负，**整个控件在屏幕上方之外**
/// #3 [NAV] dir=NavDir.up 当前=(96,24,192,60) | 不符=20 交叉超限=0 比较=0
///        | 没有可用邻居 -> 不动（不绕回）
/// ```
/// 第 2 次 ↑ 把焦点搬到**屏幕外**：焦点环画在看不见的地方，
/// 用户只能等 `_scrollIntoView` 那 180ms 的动画慢慢追上来。
///
/// # 做法：两轮，**绝不硬砍候选**
///
/// ```text
/// 第一轮：只在"与视口相交"的候选里找  -> 焦点环落在看得见的地方
/// 第二轮：第一轮没结果才回退到全池    -> 保证 ↓ 不会被砍死
/// ```
/// 第二轮回退是**必须**的，不是保险 —— 早先裁候选池的写法把 ↓ 砍死过。
_Candidate? _findNeighborInViewport({
  required NavDir dir,
  required Rect from,
  required List<_Candidate> candidates,
  required FocusNode? cur,
  required Object? curGroup,
  bool Function(_Candidate)? exclude,
}) {
  final vp = _viewportRect();
  final inView = _findNeighbor(
    dir: dir,
    from: from,
    candidates: candidates,
    cur: cur,
    curGroup: curGroup,
    exclude: exclude,
    viewport: vp,
  );
  if (inView != null) return inView;

  spatialNavLog.add('  视口内没邻居 -> 回退全池（不砍候选，保证 ↓ 不被砍死）');
  return _findNeighbor(
    dir: dir,
    from: from,
    candidates: candidates,
    cur: cur,
    curGroup: curGroup,
    exclude: exclude,
  );
}

/// 按几何邻居找下一个焦点（照抄原版 `spatialNav.ts` 的算法）
///
/// # 返回值
///
/// `true` = **找到了候选并已请求移焦**（不代表"焦点已生效"——
/// `requestFocus()` 下一帧才生效，同帧读 `hasFocus` 必然是 false）。
///
/// 想确认"焦点最终在哪"，请读真实状态，不要依赖这个返回值。
bool moveFocus(NavDir dir) {
  spatialNavLog.clear();
  // 每轮重置 —— 否则上一轮的 prime 会被误读成"这一轮也 prime 了"
  spatialNavPrimedRect = null;
  /*
   * ★ 入口计数（诊断"一次按键移动了两格"用）
   *
   * # 为什么要单独打这一行
   *
   * 真机实测抓到一个现象：一次 RIGHT **让焦点前进了两格**：
   * ```text
   * [NAV] dir=NavDir.right 移动到 ... | 当前=(356,274,504,540) | 选中=(516,274,664,540)
   * [NAV] 帧后确认: 期望=(516,274) 实际矩形=(676,274)   <- 又前进了一格
   * ```
   * 两个可能，修法完全不同：
   * ```text
   * A. 我的 handler 被注册了两次 → 每次按键 moveFocus 跑两遍
   *    （入口会打出 2 行）
   * B. 我的 handler 只跑一遍，但**事件没有被消费掉**，
   *    继续流到 Flutter 内建的 DirectionalFocusIntent → 又走了一格
   *    （入口只打 1 行）
   * ```
   * 光看焦点最终位置永远分不出这两者。
   */
  if (_navTrace) {
    // ignore: avoid_print
    print('[NAV] >> 进入 moveFocus dir=$dir');
  }
  final cur0 = FocusManager.instance.primaryFocus;

  /*
   * 起点矩形：正常情况下取当前焦点的；若起点是容器则被下面的
   * prime 分支替换成"刚种下的那个控件的矩形"（所以必须可变）。
   */
  Rect? from = _currentRect();

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 起点是容器（scope）时，**先 prime**（缺陷②的调用侧修法）
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 为什么必须在这里修，而不是只改调用点
   *
   * `shell.dart` 的守卫是 `if (primaryFocus == null) primeFocus()` ——
   * 而实测 `primaryFocus` **永远不为 null**（`ModalScope` 一挂载就持有它）。
   * 那个分支是死的，所以这个修复**不能**只依赖调用点：
   * 任何调用 `moveFocus` 的地方（探针、将来的别的页面）
   * 都必须自己能处理"起点是容器"的情况。
   *
   * 改调用点还要动 `shell.dart`（正被 AB/AD/AG 改）——
   * 在 `spatial_nav.dart` 内部解决可以零冲突，且覆盖面更广。
   * 调用点那行因此变成**冗余但无害**（`primeFocus` 自己会判据）。
   *
   * # 这就是原版 `onKeyDown` 里的同一件事
   *
   * ```js
   * const cur = pool.find((c) => c.el === active);
   * if (!cur) { focusFirst(root); return; }   // ← 起点不在候选池里 → 先落一个
   * ```
   * 原版是**内联在导航里的**，不是靠外层守卫。这里对齐原版结构。
   *
   * ⚠️ `primeFocus()` 内部会再 `_collect()` 一次（代价可接受：
   *    只在"起点不可用"时发生，正常导航一次都不会走这里）。
   */
  if (cur0 != null && !_isLeafFocusTarget(cur0)) {
    spatialNavLog.add('起点是容器(${cur0.debugLabel ?? cur0.runtimeType}) -> 先 prime');

    final primed = _primeTarget();
    if (primed != null) {
      /*
       * ★ 关键：**用刚种下的那个候选的矩形当起点**，不要回头去问
       *   `_currentRect()`。
       *
       * `requestFocus()` 的实际生效时机（同帧 / 下一帧）在 Flutter
       * 版本之间变过，而 `moveFocus` 是**同步**函数，没法等一帧。
       * 依赖"读完就是新焦点"会让这个修复变成一个**时序赌博**：
       * 猜对了能用，猜错了就静默退回"起点=整屏"的老行为。
       *
       * 而我**已经知道**种给谁了（`_primeTarget()` 的返回值），
       * 它的矩形是现成的 —— 直接拿来当起点，时序无关、必然正确。
       * 这正是本项目那条纪律：不要依赖"我以为已经生效"的状态，
       * 用已知的事实。
       */
      from = primed.rect;
      spatialNavPrimedRect = primed.rect;
      spatialNavLog.add('  已 prime 到=${_fmtRect(primed.rect)}（用作起点）');
    }
  }

  if (from == null) {
    spatialNavLog.add('当前焦点矩形拿不到 -> 放弃');
    /*
     * ★ 这一条也必须追踪
     *
     * 实测时出现过一个**看起来像"按键没送达"**的现象：
     * ```text
     * DOWN#2..#8  移动→<无>  实际→<无>  hash 完全不变
     * ```
     * 而真相是：焦点在底栏 tab 上（`_BottomItem`），
     * 「底栏是最后一行」的守卫**刻意**让它不动 —— 这是**设计**，不是 bug。
     *
     * 不把这条打出来的话，日志里**一行都没有**，
     * 与「handler 根本没收到按键」在证据上**完全无法区分**。
     * 而那两者的结论是相反的（一个是正确行为，一个是真故障）。
     */
    _traceNav('dir=$dir 无焦点矩形 -> 放弃');
    return false;
  }

  final candidates = _collect();
  spatialNavLog.add('候选=${candidates.length}');
  if (candidates.isEmpty) {
    spatialNavLog.add('候选为空（页面上没有可聚焦控件）');
    _traceNav('dir=$dir 无候选');
    return false;
  }

  final cur = FocusManager.instance.primaryFocus;
  Object? curGroup;
  cur?.context?.visitAncestorElements((el) {
    if (el.widget is Scrollable) {
      curGroup = el.widget;
      return false;
    }
    return true;
  });

  spatialNavLog.add('方向=$dir 当前=${_fmtRect(from)}');

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 两轮搜索：`↓` 时先在内容区里找，找不到才允许落到底栏
   *     （照抄原版 `spatialNav.ts` L729-740）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 真机实测抓到的 bug（2026-09-23）
   *
   * 连按 12 次 `↓`，焦点轨迹：
   * ```text
   * #1 (12,469,199,540)   源条 pill
   * #2 (36,101,184,367)   海报行第 1 个
   * #3..#7 (36,202,184,468) 矩形相同、focusId 每次不同（不同轨道的第 1 张）
   * #8 (12,469,199,540)   ← **绕回源条**
   * #9..#12 (12,469,199,540) 卡住不动
   * ```
   * **焦点在一个闭环里循环，永远到不了屏幕最下方的底栏**
   * （y≈1008 从没出现过）。而底栏是切换 tab 的**唯一入口** ——
   * 结果是**用户被困在首页**，遥控器根本换不了页。
   *
   * # 原版怎么解的
   *
   * ```js
   * const inTabbar = (c) => !!(c.el.closest && c.el.closest(TABBAR_SEL));
   * let next = null;
   * if (dir === "down" && !inTabbar(cur)) {
   *   next = findNeighbor(cur, pool, dir, inTabbar);   // ① 先排除底栏找
   *   if (!next) next = findNeighbor(cur, pool, dir);  // ② 内容区没了才允许落底栏
   * }
   * ```
   * 而且原版对"找不到邻居"的处理写得很明确：
   * > 否则 → 什么都不做（**不要绕回第一个，那很晕**）
   *
   * 我第一版漏了两件事：① 没有两轮搜索（底栏被 `crossLimit` 挡在外面就永远进不来）；
   * ② 没有"到底了就不动"的收敛（于是按 ↓ 会绕回去）。
   *
   * # 为什么底栏会被交叉轴挡住
   *
   * 底栏 tab 的中心 x ≈ 960（屏幕中点），而源条 pill 的中心 x ≈ 105：
   * ```text
   * cross = |960 - 105| = 855  >  VERTICAL_CROSS_LIMIT(360)  -> 被排除
   * ```
   * 从左侧的源条往下走，底栏**永远**在交叉轴超限名单里。
   * 所以必须靠"第二轮不带排除条件"或"放宽"来救 —— 用两轮搜索最干净，
   * 也正好是原版的做法。
   */
  final curInBottomBar = _isInBottomBar(cur);

  _Candidate? best;
  if (dir == NavDir.down && !curInBottomBar) {
    // ① 先在**内容区**里找（排除底栏）
    best = _findNeighborInViewport(
      dir: dir,
      from: from,
      candidates: candidates,
      cur: cur,
      curGroup: curGroup,
      exclude: (c) => _isInBottomBar(c.node),
    );
    // ② 内容区没有更多了 → 才允许落到底栏
    if (best == null) {
      spatialNavLog.add('  内容区没邻居 -> 允许落底栏（第二轮）');
      best = _findNeighborInViewport(
        dir: dir,
        from: from,
        candidates: candidates,
        cur: cur,
        curGroup: curGroup,
      );
    }
  } else {
    best = _findNeighborInViewport(
      dir: dir,
      from: from,
      candidates: candidates,
      cur: cur,
      curGroup: curGroup,
    );
  }

  if (best == null) {
    /*
     * 这个方向上没有邻居 —— **什么都不做**。
     *
     * 原版注释：
     * > 否则 → 什么都不做（**不要绕回第一个，那很晕**）
     *
     * ──────────────────────────────────────────────────────────────
     * ★ 实测的**结构性死路**（2026-09-23，emulator-5554 冷启动，
     *   `TV_NAV_TRACE=true` 构建）—— 记录在这里，免得以后有人把它
     *   当成"算法 bug"去改判据：
     * ──────────────────────────────────────────────────────────────
     * ```text
     * #3 [NAV] dir=NavDir.up 未移动 | 候选=21 | 方向=NavDir.up 当前=(96,24,192,60)
     *        | 不符=20 交叉超限=0 比较=0 | 没有可用邻居 -> 不动（不绕回）
     *    焦点=InkWell<_ShelfTabChip<...>> | 矩形=(96,24,192,60)
     * #4 与 #3 逐字节相同（帧 P3 == P4）
     * ```
     * 当前焦点是源条上的 pill chip（`_ShelfTabChip`），矩形
     * `(96,24,192,60)` **在视口内**；21 个候选里 20 个被
     * "中心点差 < `_minAdvance`"挡掉、**0 个**进入比较 ——
     * 也就是它上方真的没有可去的控件。
     *
     * 所以"UP3 不动"是**正确行为**（比绕回第一个好）。
     * ⚠️ 不许为了让它变绿去放宽 `_minAdvance` 或改这行日志文本。
     */
    spatialNavLog.add('没有可用邻居 -> 不动（不绕回）');
    _traceNav('dir=$dir 未移动');
    return false;
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 底栏是"最后一行"：从底栏按 ↓ 一律不动
   *     （照抄原版 `spatialNav.ts` L788-793）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 真机实测抓到的 bug（2026-09-23）
   *
   * 候选列表按 y 排序后一眼就能看出布局：
   * ```text
   *   20,  92-74x22      ← 顶部小控件
   *  195, 134-123x33     ← 源条 pill
   *  271,  36-148x266    ← 海报行 1
   *  469,  12-187x71 [底栏]   ← ★ 底栏 5 个 tab
   *  605,  36-148x266    ← 海报行 2（**在底栏下面**）
   * ```
   * 当前焦点 `(12,469,199,540)` **就是第一个底栏 tab**，
   * 而从它按 ↓ 时，算法找到了 `y=605` 的海报行 —— 那在底栏**下方**。
   *
   * 于是：
   * ```text
   * 底栏 tab → ↓ → 内容区(y=605) → ↓ → … → 绕回底栏/源条
   * ```
   * **焦点在一个大环里转圈**，用户按 12 次 ↓ 都回不到"稳定"状态。
   *
   * # 原版怎么解的
   *
   * ```js
   * const curInTabbar  = !!(cur.el.closest(TABBAR_SEL));
   * const nextInTabbar = !!(next.el.closest(TABBAR_SEL));
   * if (dir === "down" && curInTabbar && !nextInTabbar) {
   *   return;   // 已在最底部那一排，下面没有真实内容 → 不动
   * }
   * ```
   * 原版注释解释了理由：
   * > 底栏在视觉上永远是最底部的一排，它下面**不该有任何东西**。
   * > 所以从底栏按 ↓ 时直接返回（什么都不做）。
   * >
   * > ⚠️ 只拦 ↓（不拦 ↑）—— 从底栏按 ↑ 回到内容区是**符合直觉**的
   * >    （用户想"往上回到内容里"）。
   *
   * # 为什么底栏下面会有内容
   *
   * 因为内容是 `ListView`，**滚动位置**让海报行 2 落在了 y=605
   * （底栏在 y=469 是**浮在上面**的 `Stack`/`Column` 重叠）。
   * 几何上"它在下面"，视觉上"它在底栏后面"—— 所以必须靠
   * **结构判据**（谁属于底栏）来拦，不能靠坐标比大小。
   */
  if (dir == NavDir.down && curInBottomBar && !_isInBottomBar(best.node)) {
    spatialNavLog.add('已在底栏 + 目标是内容区 -> 不动（底栏是最后一行）');
    _traceNav('dir=down 底栏守卫拦截');
    return false;
  }

  /*
   * ★ 选中的候选**在不在视口内** —— 决定要不要"同帧滚入"
   *
   * 实测（UP2）选中矩形 y = -74..-38，整个在屏幕上方之外：
   * 焦点环画在看不见的地方 = 用户按了键却"什么都没发生"。
   */
  final vp = _viewportRect();
  final selInside = _rectFullyInside(best.rect, vp);
  spatialNavLog.add(
      '选中=${_fmtRect(best.rect)}（${selInside ? "在视口内" : "越界 -> 同帧滚入"}）');

  /*
   * ⚠️ 顺序：**先移焦点，再滚动**
   *
   * 反过来时滚动会让 `ListView` 懒加载重建子节点，原来那个
   * `FocusNode` 可能已被回收，`requestFocus()` 就打在不存在的节点上。
   */
  /*
   * ★ 记录**目标控件的结构身份**（真机验证的关键证据）
   *
   * 必须在 `requestFocus()` **之前**取：移焦之后
   * `primaryFocus` 就变了，那时再取只能证明"焦点在新位置"，
   * 无法证明"新位置就是算法选中的那个"。
   */
  final targetDesc = _describeFocus(best.node);

  /*
   * ★ `TV_NAV_DRYRUN=true` 时**只算不搬**（因果实验，见 [_navDryRun] 的文档）
   *
   * 判读方式：
   * ```text
   * 按一次 RIGHT 后焦点仍前进一格  → 搬运方是 Flutter 内建遍历，不是这里
   * 焦点完全不动                   → 搬运方就是这里的 requestFocus
   * ```
   */
  if (_navDryRun) {
    spatialNavLog.add('DRYRUN 不搬（只算）');
    _traceNav('dir=$dir 算出 $targetDesc 但 DRYRUN 不 requestFocus');
    return true;
  }

  best.node.requestFocus();
  _scrollIntoView(best.node, immediate: !selInside);

  spatialNavLog.add('已 requestFocus');
  _traceNav('dir=$dir 移动到 $targetDesc');

  if (_navTrace) {
    /*
     * ★ 下一帧再确认一次 —— `requestFocus()` 是**异步生效**的
     *
     * `FocusManager` 把实际移焦排进 microtask/下一帧，
     * 所以 `requestFocus()` 返回后立刻读 `primaryFocus`
     * **可能仍是旧节点**（`spatial_nav.dart` 的文档里记过这条：
     * 「`requestFocus()` 下一帧才生效，同帧读 `hasFocus` 必然是 false」）。
     *
     * 只报"我调用了 requestFocus"等于**没有验证** ——
     * 那只是"我以为"，不是"实际发生了什么"。
     * 必须下一帧读回真实状态，才能区分：
     * ```text
     * A. 选了正确的节点，但 requestFocus 被拒（节点不可聚焦/被遮挡）
     * B. 选了错误的节点
     * C. 一切正常
     * ```
     */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = FocusManager.instance.primaryFocus;
      /*
       * ★ 带上"实际"焦点的矩形
       *
       * 真机实测抓到过一个**算法意图与最终结果不一致**的现象：
       * ```text
       * [NAV] dir=right 移动到 _BottomItem<...      <- 算法选了底栏 tab
       * [NAV] 帧后确认: 期望=_BottomItem 实际=InkWell<PosterCard 一致=false
       * ```
       * 只报身份的话分不清两种可能：
       * ```text
       * A. 有别的代码把焦点抢走了（真 bug，要去查谁抢的）
       * B. 只是 requestFocus 落在了另一个**同样合理**的节点上
       * ```
       * 加上矩形就能判：矩形在卡片行 = 焦点跑到内容区去了，
       * 那正是用户按方向键时**意料之外**的跳转。
       */
      final rc = _currentRect();
      // ignore: avoid_print
      print('[NAV] 帧后确认: 期望=$targetDesc '
          '实际=${_describeFocus(now)} '
          '实际矩形=${rc == null ? "<null>" : _fmtRect(rc)} '
          '一致=${identical(now, best!.node)}');
    });
  }

  return true;
}

/// 底栏标记 widget（等价于原版的 `TABBAR_SEL = ".tabbar"`）
///
/// ══════════════════════════════════════════════════════════════════════
/// 为什么用**结构标记**而不是"看矩形在不在屏幕下方"
/// ══════════════════════════════════════════════════════════════════════
///
/// 我第一版用几何猜测：
/// ```dart
/// // 底边落在屏幕最下方 15% 内 → 认为是底栏
/// return rect.bottom > screenH * 0.85;
/// ```
/// 在 960x540（逻辑）的 TV 上，阈值 = 459，于是**海报卡被误判成底栏**
/// —— 一张 `(36,202,184,468)` 的卡片 bottom=468 > 459。
///
/// 后果是我给 `↓` 加的"先排除底栏找内容"的两轮搜索**排错了对象**，
/// 焦点行为变得莫名其妙。
///
/// ★ 教训：**几何阈值在"不同分辨率/不同布局"下必然出错**。
///   原版用的是 `c.el.closest(".tabbar")` —— **结构判据**，
///   一个 CSS 类名就永远不会因为屏幕尺寸而判错。
///   这里用同样的思路：给底栏套一个标记 widget，向上找祖先即可。
///
/// 用法（见 `shell.dart` 的 `_BottomBar`）：
/// ```dart
/// BottomBarMarker(child: Row(children: [...每个 tab...]))
/// ```
class BottomBarMarker extends StatelessWidget {
  const BottomBarMarker({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 该节点是否位于**底栏**里（向上找 [BottomBarMarker] 祖先）
bool _isInBottomBar(FocusNode? node) {
  if (node == null) return false;
  final ctx = node.context;
  if (ctx == null) return false;

  var found = false;
  ctx.visitAncestorElements((el) {
    if (el.widget is BottomBarMarker) {
      found = true;
      return false; // 找到就停
    }
    return true;
  });
  return found;
}

/// 屏幕逻辑高度（诊断用）
double _screenHeight() {
  final v = WidgetsBinding.instance.platformDispatcher.views;
  if (v.isEmpty) return 1080;
  final dpr = v.first.devicePixelRatio;
  return dpr == 0 ? 1080 : v.first.physicalSize.height / dpr;
}

/// 屏幕**逻辑**矩形（视口判据 + 诊断用）
///
/// 与 [_screenHeight] 同源：`physicalSize / devicePixelRatio`。
/// 模拟器实测：逻辑 960x540 / 物理 1920x1080 / dpr=2 ⇒ 比例正好 2。
///
/// ⚠️ 注意 `_screenHeight` 的兜底值是 1080（**物理**高度）——
/// 与这里返回的**逻辑**高度不是同一量纲，只是诊断用，别拿来做判据。
Rect _viewportRect() {
  final v = WidgetsBinding.instance.platformDispatcher.views;
  if (v.isEmpty) return const Rect.fromLTWH(0, 0, 960, 540);
  final dpr = v.first.devicePixelRatio;
  if (dpr == 0) return const Rect.fromLTWH(0, 0, 960, 540);
  final s = v.first.physicalSize / dpr;
  return Rect.fromLTWH(0, 0, s.width, s.height);
}

/// `r` 是否**完整地**落在视口内
///
/// 只用来判断"要不要滚"，不参与选邻居 ——
/// 选邻居的判据是 `Rect.overlaps`（相交即可，哪怕只露一条边）。
bool _rectFullyInside(Rect r, Rect vp) =>
    r.left >= vp.left &&
    r.top >= vp.top &&
    r.right <= vp.right &&
    r.bottom <= vp.bottom;

String _fmtRect(Rect r) =>
    '(${r.left.round()},${r.top.round()},${r.right.round()},${r.bottom.round()})';

/// 把方向键接到空间导航上（放在 shell 的全局 handler 里）
///
/// # 为什么用 `HardwareKeyboard.addHandler` 而不是 `Focus(onKeyEvent:)`
///
/// shell 里的实测结论（见 shell.dart 的注释）：
/// ```text
/// · Focus(onKeyEvent:) 放在底栏   → handler 被调用 0 次
///   （底栏与主焦点是兄弟，不在同一条祖先链上）
/// · 放到包住整个 FScaffold        → 仍然 0 次
///   （FScaffold 内部有 overlay 结构，焦点被 re-parent 到我的 Focus 之外）
/// ```
/// `HardwareKeyboard` 的 handler **不依赖焦点树**，一定能收到。
///
/// ⚠️ 但它跑在焦点派发**之前**，所以：
/// ```text
/// 想自己处理方向键             → 必须 return true
///                               （否则事件继续流到 Scrollable 去滚动）
/// 不想处理（比如输入框里打字） → 必须 return false（放行）
/// ```
class SpatialNavHandler {
  SpatialNavHandler({
    required this.enabled,
    this.isTyping,
    this.isConsumedByPage,
  });

  /// 是否启用（只有 TV / 需要焦点环的设备才启用）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 必须按设备门控（2026-09-23 实测抓到的真回归）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 原版 `spatialNav.ts` 讲得很清楚：
  /// > 那些是给**桌面键盘**用的，TV 上方向键应该先被空间导航消费掉。
  /// > 用 capture + stopPropagation，保证 TV 上方向键不会触发播放器快捷键。
  /// > **桌面不受影响 —— 因为桌面根本不装这个模块（见调用点）。**
  ///
  /// 我第一版**无条件**注册，于是在桌面/播放器里方向键全被吃掉：
  /// 播放器把 ←/→ 当快退快进、↑/↓ 当音量（`player_page.dart` 的
  /// `_onKey`），而 `HardwareKeyboard` 的 handler 跑在焦点树**之前**，
  /// 一旦 `return true` 播放器就永远收不到 → **音量/快进全废**。
  ///
  /// 真机实测证据（Android TV + `adb shell input keyevent DPAD_RIGHT`）：
  /// ```text
  /// 在播放器里连按两次 →，logcat **一行输出都没有**
  /// （播放器完全没收到按键）
  /// ```
  final bool Function() enabled;

  /// 当前页面是否**自己要**用方向键（播放器就是）
  ///
  /// # 为什么需要这个口子
  ///
  /// 光靠"是不是 TV"不够 —— **TV 上播放器也需要方向键**：
  /// 遥控器的 ←/→ 是快退快进、↑/↓ 是音量、OK 是播放/暂停
  /// （见 `player_page.dart` 的 `_onKey`，那是原版 ArtPlayer 的键位）。
  ///
  /// 所以判定要分两层：
  /// ```text
  /// enabled()          设备层：桌面根本不启用空间导航
  /// isConsumedByPage() 页面层：播放器自己接管方向键
  /// ```
  /// 两者都放行时，才把方向键交给焦点树。
  final bool Function()? isConsumedByPage;

  /// 是否正在文本输入框里打字（是的话方向键要放行给输入框）
  final bool Function()? isTyping;

  /// 上一次的方向与是否真的移动成功（诊断用）
  NavDir? lastDir;
  bool lastMoved = false;

  bool handle(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!enabled()) return false;
    if (isTyping?.call() ?? false) return false;
    /*
     * ★ 页面自己要用方向键时放行（播放器）
     *
     * 放行 = `return false` = 不消费 → 事件继续走焦点树 →
     * 播放器那层 `Focus(onKeyEvent: _onKey)` 能收到。
     */
    if (isConsumedByPage?.call() ?? false) return false;

    final k = event.logicalKey;
    NavDir? dir;
    if (k == LogicalKeyboardKey.arrowUp) {
      dir = NavDir.up;
    } else if (k == LogicalKeyboardKey.arrowDown) {
      dir = NavDir.down;
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      dir = NavDir.left;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      dir = NavDir.right;
    }
    if (dir == null) return false;

    /*
     * 没有焦点时不接管 —— 启动瞬间 primaryFocus 可能为 null，
     * 这时 return true 等于把按键吃掉，不如让事件继续流下去。
     */
    if (FocusManager.instance.primaryFocus == null) return false;

    lastDir = dir;
    lastMoved = moveFocus(dir);

    /*
     * ★ 无论有没有找到邻居，**都要 return true**
     *
     * 否则事件会继续流到 `Scrollable`，变成"一边滚页面一边移焦点"。
     * 原版注释把这条列为三个坑之首：
     * > ① 必须 `preventDefault()`
     * >    否则方向键的默认滚动行为照旧执行，页面一边滚一边移焦点，体验很糟。
     */
    return true;
  }
}

/// 把焦点显式放到**第一个可聚焦节点**上（测试用）
///
/// # 为什么测试需要这个（2026-09-23）
///
/// 探针要量"按 ↓ 焦点动不动"，但"起始焦点在哪"取决于上一次按键的残留 ——
/// 不同轮次跑出来起始位置不同，结论就不可复现。
/// 实测踩到：一次跑在首页（有海报行，↓ 有邻居），
/// 另一次跑在 live 页（源条下面没内容，↓ 无路可走）→ **假失败**。
///
/// 显式种焦点才能让测量有确定前提。
///
/// 返回是否种成功。
bool seedFocusToFirst() {
  final candidates = _collect();
  if (candidates.isEmpty) return false;

  /*
   * 取**最靠上、再最靠左**的那个 —— 桌面/TV 上就是页面顶部第一个控件，
   * 对首页来说即源条的第一个 pill。
   */
  candidates.sort((a, b) {
    final dy = a.rect.top.compareTo(b.rect.top);
    if (dy != 0) return dy;
    return a.rect.left.compareTo(b.rect.left);
  });

  candidates.first.node.requestFocus();
  return true;
}

/// 进页面时把焦点**主动**放到第一个可聚焦元素上（原版 `primeFocus`）
///
/// ══════════════════════════════════════════════════════════════════════
/// 为什么需要（原版注释说得比我好，直接引）
/// ══════════════════════════════════════════════════════════════════════
///
/// > TV 上如果没有焦点，用户按方向键是"从零开始"，
/// > 而我们的算法在"当前没有焦点"时才会落到第一个 ——
/// > 主动做一次更自然（页面一进来就有焦点环，用户知道从哪开始）。
///
/// # 真机实测到的症状（2026-09-23）
///
/// 遥控器 OK 打开详情页之后，**按方向键完全没反应**。
/// 表现就是「首页能选片，进了详情页就动不了」——
/// 用户会以为遥控器坏了。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 上面那条注释的**前提是错的** —— 缺陷②的真正根因（2026-09-25 实测）
/// ══════════════════════════════════════════════════════════════════════
///
/// 旧注释把原因写成「详情页里没有地方设过焦点 → `primaryFocus == null`」。
/// 实测（真实 `MaterialApp` + `Navigator.push`）**推翻了它**：
///
/// ```text
/// 未请求任何焦点时      primaryFocus = _ModalScopeState Focus Scope
/// 进详情页之后          primaryFocus = _ModalScopeState Focus Scope
/// primaryFocus == null ? false
/// ```
///
/// **它永远不是 `null`** —— 路由的 `ModalScope` 一挂载就自动持有主焦点。
/// 所以旧守卫 `if (primaryFocus != null) return false` **必然提前返回**，
/// 而 `shell.dart` 里那层 `if (primaryFocus == null) primeFocus()` 更是
/// **永远进不去的死分支**。结果就是：
/// ```text
/// 详情页的 primaryFocus = 一个矩形为整屏 (0,0,960,540) 的 scope
/// moveFocus(right) => moved=false
///   log: 方向=right 不符=4 比较=0 | 没有可用邻居 -> 不动（不绕回）
/// ```
/// 「详情页按方向键完全没反应」**根本没被修好** ——
/// 只是注释以为修好了，而症状一直在。
///
/// # 原版真正的守卫是什么（判据的来源）
///
/// 原版 `spatialNav.ts` 的 `onKeyDown` 里：
/// ```js
/// const pool = collect(root);
/// if (!pool.length) return;
/// const active = document.activeElement;
/// const cur = pool.find((c) => c.el === active);
/// // 当前没有焦点（或焦点在作用域外）→ 落到第一个
/// if (!cur) { focusFirst(root); return; }
/// ```
///
/// ★ 判据是 **`pool.find(c => c.el === active)`** ——
///   「当前焦点**是不是候选池里的一个成员**」，
///   **不是** `activeElement == null`。
///
/// 原版注释自己写明了这一点：
/// > 当前没有焦点（**或焦点在作用域外**）→ 落到第一个
///
/// 这两件事在 DOM 里几乎等价（DOM 只有真控件能拿焦点），
/// 所以原版写 `!cur` 就够了。但 Flutter 里**容器自己就是 `FocusNode`**，
/// 「`primaryFocus` 非空」和「`primaryFocus` 是一个能承载焦点的控件」
/// 是两件不同的事 —— 这正是照抄时丢掉的那层语义差异。
///
/// # 修法：把判据换成"当前焦点是不是一个可用的导航起点"
///
/// ```text
/// primaryFocus == null                     → 需要 prime（旧的唯一条件）
/// primaryFocus 是 FocusScopeNode（容器）   → 也需要 prime  ← ★ 新增
/// primaryFocus 是叶子控件                  → 不动（把用户正看的焦点抢走是错的）
/// ```
///
/// 用 `_isLeafFocusTarget` 作为判据，与 `_collect()` 的候选资格**完全同源** ——
/// 两边一旦不一致就会出现"焦点在 A 上，但 A 不算候选"的错配，
/// 而那正是 `moveFocus` 拿不到起点、静默返回 false 的另一种写法。
///
/// ⚠️ 为什么"焦点在 scope 上"**等同于**"没有焦点"：
///    `moveFocus` 的起点矩形来自 `_currentRect()` = 全屏 (0,0,960,540)。
///    从整屏中心出发，任何方向的 `cross` 都巨大、`main` 也大多为负，
///    实测就是 `不符=4 比较=0` —— 一个候选都进不了比较。
///    即**在算法眼里它和"没有焦点"完全等价**。
///    所以这里把它归到"需要 prime"那一类，而不是当成一个正常起点。
///
/// 返回是否成功放置焦点。
bool primeFocus() {
  final cur = FocusManager.instance.primaryFocus;

  /*
   * ★ 守卫：只有"当前焦点不是可用导航起点"时才放焦点。
   *
   * 旧写法 `if (cur != null) return false;` 是缺陷②的**直接原因**
   * （`ModalScope` 一挂载就让 `cur != null`，分支永不触发）。
   */
  if (cur != null && _isLeafFocusTarget(cur)) return false;

  return _primeTarget() != null;
}

/// 选出"该把焦点种给谁"并种下去；返回被选中的候选（没得种返回 null）
///
/// # 为什么把选点逻辑抽出来（而不是让 [primeFocus] 和 [moveFocus] 各写一遍）
///
/// [moveFocus] 在"起点是容器"时也要种一次焦点，且它**必须知道
/// 种给了谁、那个控件的矩形是多少** —— 因为它是同步函数，
/// 不能等一帧再回头读 `_currentRect()`（见 [moveFocus] 里的推导）。
///
/// 两处各写一遍选点逻辑，就等于把"落点规则"复制成两份 ——
/// 而本项目已经因为"测试和实现各说各话"栽过好几次。
/// 落点规则只留一处，两边行为必然一致。
///
/// ⚠️ `primeFocus` 与 [moveFocus] 的落点**刻意不同**：
/// ```text
/// primeFocus : 几何上"最靠上最靠左"（原版 focusFirst 的语义，左上角第一个）
/// moveFocus  : 几何上**离当前起点最近**的（用户已经在一个位置上，
///              跳去左上角会很突兀）
/// ```
/// 所以选择策略由 [selector] 外置，而不是硬编码一种。
_Candidate? _primeTarget({
  int Function(_Candidate a, _Candidate b)? selector,
}) {
  final candidates = _collect();
  if (candidates.isEmpty) return null;

  /*
   * 默认取**最靠上、再最靠左**的那个。
   *
   * 原版用的是 DOM 顺序（`collect()` 的返回顺序），
   * Flutter 这边的焦点树顺序不保证是视觉顺序（尤其是
   * `ListView` 懒加载 + `IndexedStack` 保活的组合），
   * 所以显式按几何排序更可靠 —— 结果与原版一致（左上角第一个）。
   */
  candidates.sort(selector ??
      (a, b) {
        final dy = a.rect.top.compareTo(b.rect.top);
        if (dy != 0) return dy;
        return a.rect.left.compareTo(b.rect.left);
      });

  final chosen = candidates.first;
  chosen.node.requestFocus();
  return chosen;
}


/// 开机 / 进新路由时**主动**种一次焦点
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须有这个函数（2026-09-25 真机实测，任务 AI）
/// ══════════════════════════════════════════════════════════════════════
///
/// # 真机现象：**按键完全没反应**，连我自己的 handler 都没被调用
///
/// 缺陷② 一开始看起来只是"进详情页方向键不动"。
/// 但真机复测暴露出**更严重的一层**：冷启动后的一段时间里，
/// **一次 `[NAV]` 日志都不打** —— 连"进入 moveFocus"那行都没有。
///
/// 这说明按键**根本没走到我的代码**。去打 Flutter SDK 才找到原因
/// （`focus_manager.dart` 的 `handleKeyMessage`）：
/// ```dart
/// bool handleKeyMessage(KeyMessage message) {
///   ...
///   assert(_focusDebug(() => 'Received key event $message'));
///   if (FocusManager.instance.primaryFocus == null) {
///     assert(_focusDebug(() => 'No primary focus for key event, ignored: $message'));
///     return false;                       // ★★ 在这里就返回了
///   }
///   var handled = false;
///   if (_earlyKeyEventHandlers.isNotEmpty) { ... }   // ← 连 early handler 都到不了
///   ...
/// }
/// ```
///
/// 也就是说：**`primaryFocus == null` 时，`FocusManager` 直接丢弃按键，
/// 所有 handler（early / 节点 / late）一个都不跑。**
///
/// # 这为什么让"按一下方向键就会自动好"的假设失效
///
/// 我原本以为"第一次按方向键 -> `moveFocus` 里发现起点是容器 -> 自动 prime"
/// 就够了（那个分支确实有用，见 [moveFocus]）。
/// 但它有一个**前提**：`primaryFocus != null` 才能进到 `moveFocus`。
/// 而启动早期 `primaryFocus` **就是 null** —— 于是：
/// ```text
/// primaryFocus == null
///   -> FocusManager 丢弃按键（handler 全不跑）
///   -> moveFocus 永远不被调用
///   -> primeFocus 永远不被调用
///   -> primaryFocus 永远是 null        ★ 死锁，按多少次都没用
/// ```
/// 这是一个**自锁**：唯一的破局手段（primeFocus）本身要靠按键触发，
/// 而按键恰恰被"没有焦点"这个状态挡掉了。
///
/// # 所以必须有一个**不依赖按键**的触发点
///
/// 两处，都用"等一帧"把时机放到 widget 挂载之后：
/// ```text
/// ① 开机      —— 首帧渲染完成后种一次
/// ② 进新路由  —— 每个路由 push 完成后种一次（缺陷② 的本体）
/// ```
///
/// # 为什么 `primeFocus()` 只在"没有可用起点"时才动手
///
/// 它内部有守卫（`cur != null && _isLeafFocusTarget(cur)` → 直接返回），
/// 所以**不会**把用户已经选好的焦点抢走 ——
/// 在已经正常导航的页面上调用它是**无副作用**的。
/// 这一点很关键：它意味着"多调用几次"是安全的，
/// 不需要精确知道"什么时候该调"。
///
/// 返回是否真的种上了。
bool primeFocusSoon() {
  var primed = false;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    primed = primeFocus();
  });
  return primed;
}

/// 进新路由时自动种焦点（挂到 `MaterialApp.navigatorObservers`）
///
/// # 为什么用 `NavigatorObserver` 而不是在每个页面里写
///
/// 本项目有 6+ 个页面（发现/直播/追更/搜索/设置/详情/播放），
/// 每个都写一遍 `initState -> primeFocus` 意味着：
/// ```text
/// · 漏一个页面 -> 那个页面"遥控器失灵"（正是缺陷② 的症状）
/// · 新加页面的人不知道要写 -> 又漏一个
/// ```
/// 而"**每次路由变化都种一次**"是**一处收口**，
/// 新页面自动获得这个保障 —— 不需要任何人记得写。
///
/// ⚠️ 这与原版的结构差异是**故意的**：
///    原版 `primeFocus` 是**页面显式调用**的（`PlayerView.vue:3401`
///    在 `onMounted` 里调一次），因为 Vue 那边每个视图都有 `onMounted` 钩子。
///    Flutter 这边路由切换是统一入口，用 observer 更不容易漏。
///    判据本身（"当前焦点不是可用起点就种一个"）与原版**完全一致**。
///
/// # 为什么在这两个钩子里都调
///
/// 路由动画期间新页面的 widget 还没挂载完，
/// 此刻 `_collect()` 收不到新页面的控件（会种到旧页面上）。
/// 等一帧后新页面已 build/布局完成，`_collect()` 才能看到它。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 「只等一帧」**不够** —— 有界重试（任务 AN，2026-09-25 逐帧取证）
/// ══════════════════════════════════════════════════════════════════════
///
/// # 原来的实现是**空操作**（有 A/B 对照证据）
///
/// 旧写法只排一帧：
/// ```dart
/// void _prime() {
///   WidgetsBinding.instance.addPostFrameCallback((_) => primeFocus());
/// }
/// ```
/// 实测（`.probe/an_obs12_probe_test.dart`，同一场景跑两遍，只有 observer 有无之别）：
/// ```text
/// 【有 observer】 push 后 pf=_ModalScopeState Focus Scope  dl=false
/// 【无 observer】 push 后 pf=_ModalScopeState Focus Scope  dl=false   ← 逐字节相同
/// ```
/// 也就是说：**加不加这个 observer，行为完全一样**。
/// 它写在那儿，但从来没起过作用 —— 属于"看起来有、实际没有"的保障。
///
/// # 根因：那一帧**必然**被守卫挡下（而且挡得对）
///
/// `didPush` 里排的回调在**路由转场动画的第 1 帧**就跑完了。
/// 那一刻逐帧取证（`.probe/an_obs11_probe_test.dart`）：
/// ```text
/// push 同帧       pf=首页(真控件)                    ← 焦点还在老路由
/// postFrame#1     进入 pf=首页  kids.isEmpty=true    → 守卫返回 false（正确！）
///                 候选池=[(430,250,530,290)]          ← 只有老路由那 1 个候选
/// pump#0          pf=_ModalScopeState Focus Scope    ← ★ 转场在这里把它顶掉
/// pump#1..settle  pf=容器（再也没有东西来种）
/// ```
/// 关键在最后两行：**把焦点顶掉的是路由转场本身**，而它发生在
/// 我们那次 prime **之后**。所以：
/// ```text
/// 第 1 帧：焦点在老路由的叶子上 → 守卫正确地拒绝动手（不该抢用户焦点）
/// 第 2 帧：转场把焦点顶到 ModalScope 容器上 → 现在**该**动手了
///          但我们只排了一帧，已经没人再试
/// ```
/// 守卫在第 1 帧拒绝是**对的**（那一刻焦点确实是可用起点），
/// 错的是"只试一次" —— 真正的机会窗口在它后面。
///
/// # 为什么"等到动画完成"也不行（试过，否决）
///
/// 另一条思路是 `route.animation.addStatusListener` 等转场结束再 prime。
/// 实测（`.probe/an_obs14_probe_test.dart`）：转场完成时焦点**已经**是容器，
/// 那一刻 prime 确实能成功 —— 但 `MaterialPageRoute` 的转场是 **300ms**，
/// 而 `flutter_test` 里 `pumpAndSettle` 会一路推到结束，真机上不会。
/// ⇒ 用户在这 300ms 里按方向键仍然失灵，只是窗口从"永远"缩小到"300ms"。
/// 而 `moveFocus` 的兜底分支本来就能覆盖这 300ms（见下），
/// 所以为一个更小的窗口引入"监听动画"的复杂度不划算。
///
/// # 修法：有界重试，**成功即停**
///
/// 停止条件只有一个：`primeFocus()` 返回 `true`（真的种上了）。
/// 若一直没种上（新页面本来就没有可聚焦控件，比如纯文本页），
/// 重试 [maxPrimeTries] 帧后放弃 —— 不会无限排帧。
///
/// 实测（`.probe/an_obs15_probe_test.dart`，同一个 observer 改法）：
/// ```text
/// 第1次: 进入 pf=首页(叶子)          prime=false   ← 守卫正确拒绝
/// 第2次: 进入 pf=ModalScope(容器)    prime=true    ← ★ 抓到了机会窗口
/// ★ push 后 pf=详情左  dl=true                      ← 不按任何键，焦点已在详情页
/// ```
///
/// # 为什么这不是"抢用户焦点"
///
/// 重试**不会**把用户已经选好的焦点抢走 —— 每一轮都要过 `primeFocus()`
/// 的同一个守卫（"当前焦点是叶子就不动手"）。
/// 上面第 1 次返回 `false` 正是这个守卫在起作用。
/// 重试只是**多给几次机会**去抓"焦点被转场顶掉"那个窗口。
///
/// # 与 `moveFocus` 兜底的分工（两层，都要有）
///
/// ```text
/// 本 observer      路由切换后主动种一次   → 用户还没按键时焦点环就该在
/// moveFocus 兜底   "起点是容器 -> 先 prime" → 即使上面没赶上，第一次按键也能恢复
/// ```
/// 两层**都不能省**：只有兜底的话，用户进详情页会先看到"没有焦点环"
/// （不知道遥控器能往哪走）；只有 observer 的话，一旦 Flutter 改了
/// 转场时机就彻底没有退路。
class FocusPrimingObserver extends NavigatorObserver {
  /// ⚠️ 不能是 `const` —— `NavigatorObserver` 的构造函数不是 const
  ///    （实测编译错：`A constant constructor can't call a non-constant
  ///    super constructor of 'NavigatorObserver'`）
  FocusPrimingObserver({this.maxPrimeTries = 8});

  /// 最多重试多少帧（每帧一次 `primeFocus()`）
  ///
  /// # 为什么是 8
  ///
  /// 实测（`.probe/an_obs15_probe_test.dart`）第 **2** 帧就种上了 ——
  /// 机会窗口出现在转场把焦点顶掉之后。8 给足了余量
  /// （更长的转场、更慢的首帧布局），同时**有界**：
  /// 新页面真的没有可聚焦控件时，最多排 8 帧就停，不会无限排。
  final int maxPrimeTries;

  void _prime() {
    var tries = 0;
    void attempt() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        /*
         * ★ 停止条件只有"真的种上了"。
         *
         * ⚠️ **不能**写成"焦点是叶子就停" —— 第 1 帧时焦点是
         *    **老路由**的叶子，看起来"已经有焦点了"，但转场马上会把它顶掉。
         *    我第一版就是这么写的（`.probe/an_obs13_probe_test.dart`），
         *    结果第 1 帧就停了，什么都没改善。
         */
        if (primeFocus()) return;
        if (++tries >= maxPrimeTries) return;
        attempt();
      });
    }

    attempt();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _prime();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    // 返回上一页后，原来那页的焦点可能被销毁了 -> 也要重新种
    _prime();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _prime();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _prime();
  }
}

/// 把节点滚进它**自己的滚动容器**（不动整页）
///
/// 用 `Scrollable.ensureVisible` —— 它只影响最近的 Scrollable 祖先，
/// 与原版"绕开 scrollIntoView（会同时滚动所有祖先）"的意图一致。
///
/// # 为什么必须滚动（2026-09-23 我第一版裁掉了屏幕外候选，↓ 直接失效）
///
/// 我一开始加了"矩形必须与屏幕相交"的过滤，结果 TV 实测：
/// ```text
/// [导航] 候选=27 | 方向=down | 进入比较=0 | 没有可用邻居 -> 不动
/// ```
/// **按 ↓ 一个候选都不剩** —— 因为源条在 y=469、屏幕高 540，
/// 下面那一排海报卡**在屏幕外**，全被裁掉了。
/// 而"往下走"恰恰意味着目标**本来就在屏幕外**。
///
/// 原版的做法是：**收集全部 → 选几何上最合适的 → 把它滚进可视区**。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 给 task-3（fix-autoscroll）的约束：**遥控/键盘导航必须保留滚动**
/// ══════════════════════════════════════════════════════════════════════
///
/// task-3 会在这里加"输入来源门控"（只让键盘/遥控滚，不让鼠标滚轮滚）——
/// 因为鼠标滚动时焦点变化会触发 `ensureVisible(alignment: 0.5)`
/// 把内容强行拉回焦点项居中（实测：滚轮 30 次完全不动）。
///
/// ⚠️ 门控**不能**把遥控/键盘路径一起关掉：
/// ```text
/// task-39 给直播页接了方向键切频道（`LivePageState.cycleChannel`）。
/// 用户按下键切到下一个频道后，**必须**把它滚进可视区 ——
/// 否则高亮的台在屏幕外，用户以为"没反应"。
/// ```
/// # task-39 的接线点（task-3 改这里时请一并确认）
/// ```text
/// lib/ui/live_page.dart
///   · `LivePageState._onKey`      —— ↑/↓ 切频道（返回 handled）
///   · `LivePageState.cycleChannel` —— 循环语义（末尾回到开头）
/// lib/ui/widgets/live_embedded_player.dart
///   · 内嵌播放器（不可见时 pause，见 `LivePage.visible`）
/// ```
/// ★ 直播页的频道列表**自己**用 `Scrollable.ensureVisible` 保证选中项可见
///   （在 `_ChannelTile` 的焦点回调里），所以即使门控改了这里的内部路径，
///   直播页仍正确。但**若门控把 `moveFocus` 的滚动整体关掉**，
///   别的页面（首页/追更）的遥控导航就会退化 —— 那才是要避免的。
/// # ★ `immediate: true` —— 同帧滚动（修"焦点环画在屏幕外"）
///
/// 选中矩形整个在视口外时（实测 UP2：`y = -74..-38`），
/// 用 180ms 动画滚动 = 焦点环先画在看不见的地方，再慢慢滑进来。
/// 改成 `Duration.zero` 后滚动**在本次调用内就完成**，
/// 于是"新焦点"和"新滚动位置"落在**同一帧**里。
///
/// 为什么 `Duration.zero` 是同步的（读 Flutter 源码，不是猜的）：
/// ```text
/// packages/flutter/lib/src/widgets/scrollable.dart:492  static Future<void> ensureVisible(BuildContext context, {... Duration duration = Duration.zero ...})
/// packages/flutter/lib/src/widgets/scrollable.dart:510  while (scrollable != null) {
/// packages/flutter/lib/src/widgets/scrollable.dart:512    (newFutures, scrollable) = scrollable._performEnsureVisible(...)   ← 同步调用
/// packages/flutter/lib/src/widgets/scrollable.dart:527  if (futures.isEmpty || duration == Duration.zero) { return Future<void>.value(); }
///
/// packages/flutter/lib/src/widgets/scroll_position.dart:869  if (target == pixels) { return; }
/// packages/flutter/lib/src/widgets/scroll_position.dart:873  if (duration == Duration.zero) { jumpTo(target); return; }   ← jumpTo 是同步的
/// packages/flutter/lib/src/widgets/scroll_position.dart:878  return animateTo(target, duration: duration, curve: curve);
/// ```
/// ⚠️ 所以**不要**自己改成 `animateTo(Duration.zero)`：
/// `scroll_activity.dart:705  }) : assert(duration > Duration.zero) {`
/// 会在 debug 下断言失败。走 `ensureVisible` 才会命中 :873 那个分支。
///
/// # 顺序仍然是"先移焦点，再滚动"
///
/// 两者都在同一个同步回调里跑完，**没有任何 await**，
/// 所以"滚动重建子节点把 FocusNode 回收掉"的风险没有变大
/// （见 moveFocus 里那段 ⚠️ 顺序注释）。
void _scrollIntoView(FocusNode node, {bool immediate = false}) {
  final ctx = node.context;
  if (ctx == null) return;
  try {
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: immediate ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  } catch (_) {
    // 不在任何 Scrollable 里（比如底栏）→ 不需要滚动，忽略
  }
}