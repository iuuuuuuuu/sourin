// ═══════════════════════════════════════════════════════════════════════
//  双区间时间轴（夸克式 —— 四个实心大箭头）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户给的设计参考（2026-09-24）
//
// > 这个片头片尾设置你借鉴一下夸克的好吧,四个小箭头,片头两个,结束两个
// > 虽然片头都是从 00:00 开始,但是两个也可以表示一个时间
// > 结尾也是一样,虽然时间重叠,但是位置不重叠
// > 按照这种去做
//
// 用户还专门**放大截图**给我看：两个大箭头**尖端相对、靠在一起**，
// 形成一个「**领结 / 蝴蝶结**」；实心、比轨道细线高得多。
//
// # 我前两版差在哪
//
// ```text
// 第一版：竖线 + 顶部圆点
//         → 看不出方向（竖线只标位置，不表达"从这跳到那"）
//         → 两端时间相同时完全重叠，只能抓到一个
// 第二版：细三角 + 白描边 + minGap = arrowW + 2
//         → 太细，不像夸克那个饱满的实心箭头
//         → minGap 算错了，两个箭头**重叠 11px**（见下）
// ```
//
// # ★★★ 关键：`minGap` 必须是 `2 × arrowW`，不是 `arrowW + 2`
//
// 领结的形成条件是**两个尖端落在同一个 x**：
// ```text
// 朝右箭头（tip 在 T）:  箭身占 [T-aw, T]
// 朝左箭头（tip 在 T）:  箭身占 [T  , T+aw]
//                        ─────────────────
// 合起来                [T-aw, T+aw]   ← 对称领结，宽 2·aw
// ```
// 所以「让两个端点重合时形成领结」= 让两个 **tip** 落在同一个 x。
//
// 而端点的 `drawX` **就是 tip 的 x**（不是箭身左边）——
// 于是重合时 tip 相同 → **天然就是领结**，根本不需要偏移量！
//
// 我第二版把 `drawX` 当成"箭身左边"用，又加了
// `minGap = arrowW + 2` 的错开 —— 两处语义不一致，结果箭身互相压了 11px，
// 看起来是一个歪的实心块而不是领结。
//
// # ★★ 「位置不重叠」怎么满足（用户明确要求）
//
// 用户要的是"时间重叠但位置不重叠"。领结的两个三角**尖端相接**，
// 视觉上是两个独立箭头（不是一坨）—— 这就满足了"看得清"。
//
// 而**抓取**用的是**箭身中心**而不是尖端：
// ```text
// 朝右箭头 箭身中心 = tip - aw/2     （在交点左侧）
// 朝左箭头 箭身中心 = tip + aw/2     （在交点右侧）
// ```
// 两个中心相距 `aw`（17px），各自可点 —— 这就满足了"抓得到"。
//
// ⚠️ 如果命中判定也用尖端，两个箭头尖端同 x → 距离都是 0 →
//    永远只能抓到第一个，用户会以为"另一个箭头点不动"。
//
// # 退化情况：**同向**两箭头重叠
//
// 正常数据下不会发生（片头 < 片尾 是硬约束）。但极端情况存在：
// ```text
// 片头 0-0（零长度）+ 片尾 0-100  → introStart 与 outroStart 都是"朝右"
//                               → 箭身完全重合，抓不开
// ```
// 所以对**同向且 tip 距离 < arrowW** 的对，把后者右移 `arrowW + 2`。
// 领结（异向）**不受影响** —— 那正是我们要的形态。

import 'dart:math' as math;

// ★ `DragStartBehavior` 只在 gestures 里导出（material_ui 不转出它）
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'skip_marker_dialog.dart' show SkipEdge;

/// 箭头宽度（沿时间轴方向）
///
/// ⚠️ 这是**唯一**的箭头宽度常量（2026-09-24 统一）——
///    同文件里原来还有一对死代码 `_arrowW = 17` / `_inset`，已删除。
///    两个值并存时"改了没反应"，极难查（详见 `_SkipTimelineState` 里的说明）。
///
/// ⚠️ 这个值同时决定三件事，改它要一起想：
/// ```text
/// ① 箭身的胖瘦
/// ② 左右两端的留白（`kArrowInset`）—— 否则箭头会被裁掉
/// ③ 领结的宽度（= 2 × 箭头宽）
/// ```
const double kArrowW = 21;

/// 左右留白
///
/// 朝右的箭头箭身在 tip **左侧**，所以 tip 在 `x=0` 时箭身会跑到画布外
/// 被裁掉。同理朝左的箭头在最右侧。留出一个箭宽就恰好放得下：
/// ```text
/// introStart tip 在 inset          → 箭身 [0, inset]
/// outroEnd   tip 在 w - inset      → 箭身 [w-inset, w]
/// ```
const double kArrowInset = kArrowW;

/// 每个端点的箭头方向
///
/// ```text
/// 区间**开始** → 朝右（"从这里开始跳"）
/// 区间**结束** → 朝左（"跳到这里为止"）
/// ```
bool skipEdgePointsRight(SkipEdge e) =>
    e == SkipEdge.introStart || e == SkipEdge.outroStart;

/// 两个刻度标签**是否挤在一起**（该让位了）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-02：真机截图发现的丑（`.probe\t465-02-布局.png` 放大 10 倍）
/// ══════════════════════════════════════════════════════════════════════
///
/// 位置在 0 时，播放头 x == `kArrowInset`（= 21），而静态起点标签
/// **也**画在 `kArrowInset` ⇒ 两串字完全重叠：
/// ```text
/// ▶ 0:00      ← 当前时间（foreground，w600）
/// 0:00        ← 静态起点（mutedForeground）
/// 叠成一团糊字：放大图里是「▶0(0)0-00」
/// ```
/// 播放到最右端时同理（`xOf(total) == trackRight`）。
///
/// # 为什么"静态标签让位"而不是"把当前时间挪开"
///
/// 当前时间**必须**贴着播放头 —— 它和轨道位置是同一个语义，
/// 挪开就变成"数字和画面对不上"，那比重叠更糟。
/// 而静态起点/终点标签在**重叠的那一刻本来就是冗余的**：
/// 位置 0 时 `▶ 0:00` 说的就是起点，再画一个 `0:00` 毫无信息量。
/// ⇒ 重叠时**只画当前时间**，信息量不减、观感干净。
///
/// # 为什么抽成**纯函数**（而不是留在 painter 里）
///
/// 判据必须与结论**同层**。这个决定只依赖两个矩形，
/// 留在 `paint()` 里就只能靠"渲染出图再数像素"来验证（贵且脆）。
/// 抽出来之后可以直接喂矩形断言边界（见 `test/t466_tick_label_overlap_test.dart`）。
///
/// ⚠️ [pad] 默认 4px：只判 `overlaps` 的话，两串字**紧挨着**（差 1px）
///    仍然很难看 —— 要的是"挨得太近就让位"，不是"压上了才让位"。
bool tickLabelsCollide(Rect a, Rect b, {double pad = 4.0}) =>
    a.inflate(pad).overlaps(b);

/// 未设置的端点，幽灵箭头该画在哪（task-28 ㉝）
///
/// ══════════════════════════════════════════════════════════════════════
/// # 用户原话（逐字）
/// ══════════════════════════════════════════════════════════════════════
///
/// > 片头片尾 设置根本不好用，**片头的开始和片尾开始都在最前面**
/// > **片头的结尾和片尾的结尾都在最后面**，应该是片头的设置，
/// > 开始与结束都在最前面 **是一对的**，然后。片尾。的设置
/// > **都在最后面，并且是一对的**  你现在的设计完全就是。违反操作直觉
///
/// # 改之前（用户抱怨的那个）
///
/// 旧写法**只按箭头方向**定位：
/// ```dart
/// final ghostTip = right ? inset + arrowW : (size.width - inset - arrowW);
/// ```
/// ```text
/// 两个「开始」（都朝右）→ 都贴最左 ⇒ **完全重合**
/// 两个「结束」（都朝左）→ 都贴最右 ⇒ **完全重合**
/// ```
/// 实测（轴宽 800）：`introStart x=42.0` 与 `outroStart x=42.0` **同一点**，
/// `introEnd x=758.0` 与 `outroEnd x=758.0` **同一点**。
/// 渲染出来**只有两个**幽灵箭头（`.probe/t33_unset.png`），
/// 用户分不清哪个是片头、哪个是片尾。
///
/// # 现在：每个幽灵**贴着自己的同伴**，形成两对
///
/// ```text
/// [片头开始][片头结束] ················ [片尾开始][片尾结束]
///   ↑ 片头一对，在**最前**（左）           ↑ 片尾一对，在**最后**（右）
/// ```
///
/// # ★ 为什么偏移用 `kGhostPairGap` 而不是"均匀铺开"
///
/// ```text
/// 均匀铺开（4 等分）→ 幽灵落在时间轴**中段**
///   而"片尾"语义上就该在**末尾**。中段的幽灵会告诉用户
///   "片尾在这里" —— 那是**错误信息**。
/// 贴着同伴 → 位置本身就在表达"这一对管哪一段"：片头靠前、片尾靠后。
/// ```
///
/// # ★ 偏移量为什么取 `kGhostPairGap`
///
/// 两个约束要同时满足：
/// ```text
/// 下界：要 > 箭头宽（kArrowW=21），否则两个幽灵**看起来还是叠在一起**
/// 上界：要远小于轴长，否则"片头结束"跑到轴中间，
///       会被误读成"片头有 50 秒那么长"（幽灵位置 = 假的时间信息）
/// ```
/// 取 `kArrowW + 8 = 29`：比一个箭头宽再多 8px ——
/// 足够分辨成两个独立箭头，又仍在"最前/最后"的语义范围内。
double ghostTipFor({
  required SkipEdge edge,
  required double width,
  required double inset,
  required double arrowW,
}) {
  // 轴的最左/最右（朝右箭头的箭身在左，朝左的在右）
  final leftMost = inset + arrowW;
  final rightMost = width - inset - arrowW;

  switch (edge) {
    case SkipEdge.introStart:
      // 片头开始 = 整条轴的最前
      return leftMost;
    case SkipEdge.introEnd:
      // 片头结束 = 片头一对的**后半**（靠左，但能分辨）
      return leftMost + kGhostPairGap;
    case SkipEdge.outroStart:
      // 片尾开始 = 片尾一对的**前半**（靠右，但能分辨）
      return rightMost - kGhostPairGap;
    case SkipEdge.outroEnd:
      // 片尾结束 = 整条轴的最后
      return rightMost;
  }
}

/// 幽灵箭头成对时，两个幽灵之间的间距（task-28 ㉝）
///
/// 见 [ghostTipFor] 里"偏移量为什么取这个值"的推导。
const double kGhostPairGap = kArrowW + 8;

/// 秒 → `12:34` / `1:02:03` —— 时间轴**刻度文字**用
///
/// ⚠️ 与 `skip_marker_dialog.dart` 的 `_fmtSeconds` **逻辑相同但独立**：
/// ```text
/// _fmtSeconds : 弹窗四行读数用（私有，`String _fmtSeconds(int sec)`）
/// _fmtClock   : 时间轴画布里用（本函数）
/// ```
/// ★ 为什么不共用：`skip_timeline.dart` **不能** import 弹窗文件
///   （弹窗反过来 import 它 ⇒ 循环依赖）。
///   ⇒ 两份实现是**结构性**的，不是偷懒。
///   ⚠️ 但格式**必须一致** —— 否则"时间轴写 00:12、读数行写 12"
///      会让人以为是两个不同的东西。改动其一时记得同步。
///
/// ⚠️ 参数是 `num`（不是 `int`）：时间轴的 `position` / `total` 是 `double`
///    （拖动时是小数秒）。
String _fmtClock(num sec) {
  final t = sec.isFinite ? sec.round() : 0;
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final s = t % 60;
  String p(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '${p(h)}:${p(m)}:${p(s)}' : '${p(m)}:${p(s)}';
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 配对配色 —— **全局唯一来源**（task㉝）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须抽成公开函数
//
// 现在有**两处**要用"片头色 / 片尾色"：
// ```text
// ① 时间轴上的箭头（`_QuarkTimelinePainter`）
// ② 弹窗四行左侧的**配对色条**（`_EdgeRow.accent`，task㉝ 新增）
// ```
// 而这两处**必须是同一个颜色** —— 用户就是靠"行上的色条"和
// "轴上的箭头"颜色一致，才能把"我调的这一行"和"轴上哪个箭头"对上。
//
// ★ 如果两处各写一份常量，将来改了一处就会**静默漂移**：
//   色条还是琥珀、箭头变成别的色 ⇒ 用户对不上，而测试可能还是绿的。
//   这个项目已经踩过同类坑（`skip_timeline.dart` 里 `_arrowW` 与
//   `kArrowW` 两份常量，注释里明确记着"将来谁改一个会以为改了另一个"）。
//
// ⇒ 所以：**颜色只在下面两个函数里定义**，画笔和色条都调它们。
//
// # 浅色主题为什么要压暗（原有结论，照搬）
//
// 原版 `#e8b04b` 是给**深色**播放器底做的。本机浅色主题下轨道是
// `colors.secondary` ≈ `#E8EAF0`（接近白），对比度只有 **1.69:1** ——
// 箭头会糊在轨道上。所以浅色下压暗、**不动色相**：
// ```text
// 琥珀 #e8b04b → #A8720A   对比度 ≈ 3.6:1
// 蓝   #5b8cff → #1F4FD8   对比度 ≈ 5.5:1
// ```

/// 片头色（琥珀）—— 时间轴箭头与配对色条**共用**
Color skipIntroColor(Brightness b) =>
    b == Brightness.light ? const Color(0xFFA8720A) : const Color(0xFFE8B04B);

/// 片尾色（蓝）—— 时间轴箭头与配对色条**共用**
///
/// ⚠️ 与片头用**两个颜色**是有意的：两个区间在时间轴上可能挨得很近，
///    同色的话分不清哪个是哪个。
Color skipOutroColor(Brightness b) =>
    b == Brightness.light ? const Color(0xFF1F4FD8) : const Color(0xFF5B8CFF);

/// 秒 → tip x —— **全局唯一**的时间↔像素换算
///
/// # 为什么要抽成一个函数（2026-09-24）
///
/// 这个式子原来在**两处**各写了一遍：
/// ```text
/// ① computeSkipTips 里的 xOf()   ← 几何纯函数，单测断言的对象
/// ② 画家的 xOf()                 ← 真正画到屏幕上的
/// ```
/// 两份实现"看起来一样"，但只要有一处被改动（比如给 `span` 加个下限、
/// 或换掉 `clamp` 的写法），**单测断言的几何和实际画出来的就不是同一个东西** ——
/// 测试全绿，箭头却画错位。这类"测试和生产各算一遍"是最隐蔽的漂移来源。
///
/// 所以统一成这一个函数，三处共用（几何解算 / 绘制 / 播放头）。
///
/// ⚠️ 它与 `_SkipTimelineState.secOf`（x → 秒）必须**互为逆函数**，
///    否则拖拽时箭头跟不上手指（或者反过来飞出去）。
double xOfTip({
  required double width,
  required double total,
  required num sec,
}) {
  final span = math.max(width - kArrowInset * 2, 1.0);
  return kArrowInset + span * (sec / math.max(total, 1)).clamp(0.0, 1.0);
}

/// 时间轴的几何解算（**纯函数** —— 便于单测，不用 pump widget）
///
/// # 为什么抽出来
///
/// 领结 / 错开这套几何是**最容易算错**的部分（我前两版都算错了），
/// 而它藏在 `build` 里就没法单测 —— 只能靠"看截图猜"。
/// 抽成纯函数后可以精确断言像素关系。
///
/// # 参数
///
/// [width] 是时间轴控件的可用宽度（不是屏幕宽）。
///
/// # 返回
///
/// 每个端点的 **tip x**（箭头尖端的横坐标）。`null` = 该端点未设置。
Map<SkipEdge, double?> computeSkipTips({
  required double width,
  required double total,
  required int? introStart,
  required int? introEnd,
  required int? outroStart,
  required int? outroEnd,
}) {
  double xOf(num sec) => xOfTip(width: width, total: total, sec: sec);

  final tips = <SkipEdge, double?>{
    SkipEdge.introStart: introStart == null ? null : xOf(introStart),
    SkipEdge.introEnd: introEnd == null ? null : xOf(introEnd),
    SkipEdge.outroStart: outroStart == null ? null : xOf(outroStart),
    SkipEdge.outroEnd: outroEnd == null ? null : xOf(outroEnd),
  };

  /*
   * ══════════════════════════════════════════════════════════════════
   * 退化情况的错开 —— **两轮**
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么需要两轮（2026-09-24 验算发现）
   *
   * 第一轮只处理**同向**箭头重叠（箭身形状会糊在一起）。
   * 但验算发现还有第二种重叠没人管：
   * ```text
   * 输入：片头 0-0（零长度）+ 片尾 0-100
   *   introStart ▶ tip=17  body= 8.5
   *   introEnd   ◀ tip=17  body=25.5     ← 领结，正常
   *   outroStart ▶ tip=36  body=27.5     ← 只跟 introEnd 的 body 差 2px！
   * ```
   * 两个箭头**形状上不重叠**（异向，错开了），
   * 但**命中区几乎完全重叠** —— 用户点那儿永远只能抓到其中一个。
   *
   * # 判据：按**箭身中心**而不是 tip
   *
   * 因为命中判定用的就是箭身中心（见 `skipEdgeBodyCenter`）。
   * 阈值取 `kArrowW`：
   * ```text
   * 领结：两 body 相距恰好 kArrowW  → 不触发  ✓ 保留领结
   * 上面那种：相距 2px            → 触发    ✓ 推开
   * ```
   *
   * ⚠️ 用 `kArrowW` 而不是更大的值 —— 阈值一大就会把**领结**也推开，
   *    而领结正是夸克那个设计的核心形态。
   */
  const order = SkipEdge.values;

  /// 推开的落点间距 —— 比一个箭宽多 2px
  ///
  /// 只推到"恰好一个箭宽"的话两个箭头**边缘相贴**，抗锯齿下仍显糊；
  /// 多 2px 让它们明显分开。（领结不受影响 —— 那是**异向**，不走这条。）
  const gap = kArrowW + 2;

  // ── 第一轮：同向箭头形状重叠 ──
  for (var i = 0; i < order.length; i++) {
    final a = order[i];
    if (tips[a] == null) continue;
    for (var j = 0; j < i; j++) {
      final b = order[j];
      if (skipEdgePointsRight(a) != skipEdgePointsRight(b)) continue;
      final bx = tips[b];
      if (bx == null) continue;
      /*
       * ⚠️ 每轮都**重新读** `tips[a]`，不要在外面缓存一份 ——
       *    上一次 j 循环可能刚把它推走过，缓存的话下一次判据用的是旧位置。
       */
      if ((tips[a]! - bx).abs() >= kArrowW) continue;

      /*
       * ★ 先往右推，但**要验证推完真的分开了**（2026-09-24 穷举测试抓到）
       *
       * 原来的写法是 `min(bx + kArrowW + 2, width - kArrowInset)` 一把梭。
       * 问题：推到画布边缘会被 `min` 顶住，此时结果**可能仍然压在 b 身上**。
       * 实测场景（片头 99-100 + 片尾 100-100，全挤在最右端）：
       * ```text
       * introStart  tip = 672.4   箭身 [651.4, 672.4]  ← 朝右
       * outroStart  tip = 679.0   箭身 [658.0, 679.0]  ← 朝右，压了 14.4px
       * 想推到 695.4，但画布最右只能到 679（kArrowInset 留白）
       * → min() 把它留在 679，**一点没动**，两个箭头糊成一坨
       * ```
       * 所以右边推不动就改往**左**推 —— 左右都试过才算尽力。
       * ⚠️ 这只影响退化场景（正常数据同向端点离得很远，根本不会进这个分支）。
       */
      final right = math.min(bx + gap, width - kArrowInset);
      tips[a] = (right - bx).abs() >= kArrowW
          ? right
          : math.max(bx - gap, kArrowInset);
    }
  }

  // ── 第二轮：命中区（箭身中心）重叠 ──
  for (var i = 0; i < order.length; i++) {
    final a = order[i];
    final ax = tips[a];
    if (ax == null) continue;
    final ac = skipEdgeBodyCenter(a, ax)!;
    for (var j = 0; j < i; j++) {
      final b = order[j];
      final bc = skipEdgeBodyCenter(b, tips[b]);
      if (bc == null) continue;
      final cur = skipEdgeBodyCenter(a, tips[a])!;
      if ((cur - bc).abs() < kArrowW) {
        // 朝右的往右推、朝左的往左推（各自离对方远一点，方向更自然）
        final delta = skipEdgePointsRight(a) ? (bc + kArrowW - cur) : (bc - kArrowW - cur);
        tips[a] = (tips[a]! + delta)
            .clamp(kArrowInset, width - kArrowInset)
            .toDouble();
      }
    }
    // 变量 ac 只用于空安全校验，避免 lint 报未使用
    assert(ac.isFinite);
  }

  return tips;
}

/// 箭身中心 x —— **命中判定用这个**
///
/// # 为什么不用 tip
///
/// 领结形态下两个箭头**尖端同 x**。若命中判定也用尖端：
/// ```text
/// 两个箭头到点击点的距离都是 0
///   → 永远只能抓到第一个
///   → 用户会以为"另一个箭头点不动"
/// ```
/// 用箭身中心则两个中心相距一个箭宽（17px），各自可点 ——
/// 这就满足了用户「**位置不重叠**」的要求。
double? skipEdgeBodyCenter(SkipEdge e, double? tip) {
  if (tip == null) return null;
  return skipEdgePointsRight(e) ? tip - kArrowW / 2 : tip + kArrowW / 2;
}

/// 双区间时间轴（夸克式四箭头）
class SkipTimeline extends StatefulWidget {
  const SkipTimeline({
    super.key,
    required this.total,
    required this.position,
    required this.introStart,
    required this.introEnd,
    required this.outroStart,
    required this.outroEnd,
    required this.onSeek,
    required this.onChanged,
    this.onTapEdge,
  });

  final double total;
  final double position;
  final int? introStart;
  final int? introEnd;
  final int? outroStart;
  final int? outroEnd;
  final ValueChanged<double> onSeek;
  final void Function(SkipEdge edge, int value) onChanged;

  /// ★★★ 2026-10-06（task-13 ⑥）：**单击箭头 ⇒ 预览该端点停留的那一帧**
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// 「片头片尾的片头 片尾 的开始与结束，单独点击预览没有反应，
  ///   点击后应该预览这一帧的画面才对，剪头也是一样的，
  ///   支持单击后预览这个停留的位置的画面」
  /// ```
  ///
  /// # 改前为什么“没有反应”
  /// 命中箭头时 [hitEdge] 返回非 null，而旧的 `onTapDown` 里
  /// 只有 `if (hitEdge(...) == null) onSeek(...)` —— **命中的分支是空的**。
  /// 于是点在箭头上 = 世界静止（既没跳转、也没预览）。
  ///
  /// # 为什么回调带 `SkipEdge` 而不是秒数
  /// “这一帧” = 该端点**当前停留的位置**，而这个位置只有弹窗知道
  /// （拖拽中的乐观值、`_clampTo` 夹取后的值都在那边）。
  /// 时间轴只负责“你点的是哪个箭头”，秒数由回调方去读自己的状态 ——
  /// 这样不会出现“时间轴按画出来的 tip 反算秒数”的第二次几何换算。
  ///
  /// 未提供时（旧调用方 / 裸挂单测）退化成“跳到该处”，**不会静默**。
  final ValueChanged<SkipEdge>? onTapEdge;

  @override
  State<SkipTimeline> createState() => _SkipTimelineState();
}

class _SkipTimelineState extends State<SkipTimeline> {
  /// 轨道条高度（细线 —— 夸克的轨道很细，靠箭头撑视觉）
  static const double _trackH = 8;

  /// 箭头高度（垂直方向）—— 明显高于轨道，这是"大箭头"的观感来源
  static const double _arrowH = 30;

  /*
   * ⚠️ 这里**原来**还有一对 `_arrowW = 17` / `_inset = _arrowW`（2026-09-24 删掉）
   *
   * # 为什么删
   *
   * 它们是**死代码**：`_arrowW` 只被 `_inset` 引用，而 `_inset` 谁也没引用 ——
   * 真正传给画笔的是顶层的 `kArrowW`（= 21）。
   * 于是同一份文件里躺着**两个箭头宽度**，差 4px：
   * ```text
   * 常量   _arrowW = 17   ← 死代码，没人用
   * 实际   kArrowW = 21   ← 真正画出来的箭头
   * ```
   * 而 `computeSkipTips` / `skipEdgeBodyCenter`（几何纯函数，单测断言的对象）
   * 用的又是 `kArrowW`。将来谁改 `_arrowW` 会**以为改了箭头宽度**，
   * 实际什么都没发生 —— 这类"改了没反应"的常量最难查。
   *
   * ★ 教训：同一个物理量只能有**一个**常量。要改箭头宽度就改 `kArrowW`，
   *   它同时决定 ①箭身胖瘦 ②左右留白 `kArrowInset` ③领结宽度（2×）。
   */

  /// 画布总高（上下留白给箭头和播放头）
  ///
  /// 箭头高 30 + 播放头圆点在轨道上方 8 + 一点余量 ≈ 62。
  static const double _canvasH = 64;

  /// 命中半径（触摸端要够大）
  static const double _hitR = 20;

  SkipEdge? _dragging;

  /// 拖拽时"手指落点"与"箭头 tip"的偏移
  ///
  /// # 为什么需要（2026-09-24 实测手感问题）
  ///
  /// 用户抓到的是**箭身**，而 arrow 的语义位置是**尖端** ——
  /// 两者差 `arrowW/2`（8.5px）。
  /// 不做补偿的话，一按下箭头就**跳 8.5px**，手感是"抓不住"。
  ///
  /// 记下按下的偏移，更新时减掉 → 箭头**跟着手指走**，不跳。
  double _grabOffset = 0;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;

    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;

        /// 可用跨度（去掉左右留白）—— 只用于 x → 秒 的反解
        final span = math.max(w - kArrowInset * 2, 1.0);

        /// x → 秒（反解）
        ///
        /// ⚠️ 必须与 `computeSkipTips` 里的 `xOf` **互为逆函数**，
        ///    否则拖拽时箭头跟不上手指（或者反过来飞出去）。
        ///    所以两者用**同一组常量**（`kArrowInset` / `span`）。
        int secOf(double x) =>
            (widget.total * ((x - kArrowInset) / span).clamp(0.0, 1.0)).round();

        /*
         * ★ 几何解算走**纯函数**（`computeSkipTips`）—— 便于单测
         *
         * 领结 / 错开这套几何是最容易算错的部分，藏在 build 里
         * 就只能"看截图猜"；抽出来后能精确断言像素关系。
         */
        final drawTips = computeSkipTips(
          width: w,
          total: widget.total,
          introStart: widget.introStart,
          introEnd: widget.introEnd,
          outroStart: widget.outroStart,
          outroEnd: widget.outroEnd,
        );

        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ 2026-10-01：**幽灵箭头必须可拖**（Owner：「那个三角根本就不能拖动」）
         * ══════════════════════════════════════════════════════════════════
         *
         * # 改前的行为（真 bug）
         * ```text
         * hitEdge 遍历四个端点，用 `skipEdgeBodyCenter(e, drawTips[e])`
         * 而 `drawTips` 来自 `computeSkipTips` —— 对**未设置**的端点返回 null
         *   ⇒ `if (c == null) continue;` ⇒ 那个端点**在命中测试里不存在**
         * ```
         * ★ 于是：用户打开弹窗（四个端点都没设）→ 屏幕上画着**四个三角**
         *   （幽灵箭头，`alpha 0.28`）→ 用户去拖 → **一个都拖不动**。
         *
         * 实测（`_tmp_ghost_diag_test`，真实弹窗 1280x800）：
         * ```text
         * 未设置时 computeSkipTips = {四个全是 null}
         * 幽灵位置：introStart tip=42.0  introEnd tip=71.0
         *          outroStart tip=709.0  outroEnd tip=738.0   ← 画出来了
         * 在幽灵「片头开始」的箭身中心(31.5)按下，拖 10 步共 300px
         *   ⇒ introStart 仍然是 **null**（完全没反应）
         * ```
         *
         * # 改前的注释认为这是"对的"
         * ```text
         * ⚠️ 幽灵**仍不可拖**（`hitEdge` 只看 `tipX`，null 命中不到）——
         *    这是对的：没设过的点没有"位置"可言。用户用右边那行的
         *    `−/+` 把它设出来（那才是"开始/结束"的入口）。
         * ```
         * ★ 这个推理**在"什么是可见的"这一步就错了**：
         *   ```text
         *   用户看到的：四个**画出来的三角**（可交互的样子）
         *   代码认为的：它们"没有位置可言"、不该可拖
         *   ⇒ 两者矛盾 ⇒ 用户的第一反应必然是"去拖它"
         *     ⇒ 拖不动 ⇒ 「根本就不能拖动」
         *   ```
         * ⇒ ★ **画出来的东西就应该是可交互的**。
         *   要么让它可拖，要么别画成"可拖的样子"（比如画成虚线/纯文字提示）。
         *   我们选了前者 —— 因为 Owner 明确说了「那四个箭头是可以拖动的」。
         *
         * # 修法：未设置时用**幽灵位置**参与命中测试
         * ```text
         * 已设置 ⇒ bodyCenter(tip)          （原样，不变）
         * 未设置 ⇒ bodyCenter(ghostTip)     ← ★ 新增：与**画出来的位置**同源
         * ```
         * ⚠️ 关键：命中用的位置必须与**画家画的位置**是**同一个函数**
         *    （`ghostTipFor`）—— 否则又会出现"看得见但点不中"。
         *    这正是本项目反复吃过的亏：**同一个几何在两处各算一遍**。
         *
         * ⚠️ 拖动**未设置**的端点时，第一次 `onChanged` 就会给它赋一个值
         *    ⇒ 它立刻变成"已设置"，之后走正常路径。用户感觉是
         *    "把一个空位拖到某处" —— 与夸克的交互一致。
         */
        /// 某个端点的 **tip x** —— 供命中测试与拖拽偏移**共用**
        ///
        /// ```text
        /// 已设置 ⇒ computeSkipTips 的值（= 画家画的实心箭头位置）
        /// 未设置 ⇒ ghostTipFor 的值    （= 画家画的幽灵箭头位置）
        /// ```
        /// ★ 两者都与**画家用的那个值**同源 —— 这是本函数的全部意义。
        ///   本项目反复吃过"同一个几何在两处各算一遍"的亏
        ///   （见 `skipIntroColor` 的说明、`_arrowW` 与 `kArrowW` 的旧坑）。
        double tipForHit(SkipEdge e) =>
            drawTips[e] ??
            ghostTipFor(
              edge: e,
              width: w,
              inset: kArrowInset,
              arrowW: kArrowW,
            );

        SkipEdge? hitEdge(Offset p) {
          SkipEdge? best;
          var bestD = _hitR;
          for (final e in SkipEdge.values) {
            final c = skipEdgeBodyCenter(e, tipForHit(e));
            if (c == null) continue;
            final d = (c - p.dx).abs();
            if (d < bestD) {
              bestD = d;
              best = e;
            }
          }
          return best;
        }

        return SizedBox(
          height: _canvasH,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              /*
               * ══════════════════════════════════════════════
               * ★★★ 2026-10-06（task-13 ⑥）：**点箭头不再是“没反应”**
               * ══════════════════════════════════════════════
               *
               * Owner 原话（逐字）：
               * 「片头片尾的片头 片尾 的开始与结束，单独点击预览没有反应，
               *   点击后应该预览这一帧的画面才对，剪头也是一样的，
               *   支持单击后预览这个停留的位置的画面」
               *
               * 改前（本行就是那个缺口）：
               * ```text
               * if (hitEdge(pos) == null) onSeek(...);   ← 命中的分支**根本不存在**
               * ```
               * ⇒ 点在箭头上什么都不发生。这不是“预览没反应”，
               *   而是**连跳转都没有** —— 用户感受到的就是“点了没用”。
               *
               * 现在：命中 ⇒ 交给 onTapEdge（弹窗去 seek 到该端点的值并暂停）；
               * 未提供回调 ⇒ 仍退化成跳转，**任何点击都有反馈**。
               */
              final e = hitEdge(d.localPosition);
              if (e == null) {
                widget.onSeek(secOf(d.localPosition.dx).toDouble());
                return;
              }
              final tap = widget.onTapEdge;
              if (tap != null) {
                tap(e);
                return;
              }
              widget.onSeek(secOf(d.localPosition.dx).toDouble());
            },
            /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 2026-10-01：修「四个箭头拖不动」（Owner 报「根本没用」）
             * ══════════════════════════════════════════════════════════
             *
             * # 症状（Owner 原话）
             * ```text
             * 「片头片尾的设置根本没用,那四个箭头是可以拖动的,
             *   然后拖动松手就应该定格在松手的那一帧才对,
             *   你自己拟人化操作试试看看到底行不行」
             * ```
             *
             * # 实测复现（`.probe` 手法见 `test/t454_drag_framework_test.dart`）
             * 我加了一行临时日志打出 `dragStart` 收到的真实坐标：
             * ```text
             * 我按下在 local x = 48.4（正是「片头开始」箭身的中心）
             * dragStart 收到的却是 local x = 68.4   ← ★ 差了整整 20px
             * hitEdge(68.4) 去找 bodyCenter=48.4
             *   |68.4 - 48.4| = 20.0  ≥  _hitR(20)  ⇒ 判成 null
             * ⇒ `if (e == null) return;` ⇒ **整个拖拽被丢弃**
             * ```
             *
             * # 根因：`DragStartBehavior` 默认是 `start`，不是 `down`
             * ```text
             * enum DragStartBehavior {
             *   down,   // 用**第一次按下**的位置
             *   start,  // 用**竞技场获胜时**的位置   ← ★ 默认是这个
             * }
             * ```
             * （`gestures/recognizer.dart:48-56`）
             *
             * 而竞技场获胜要等手指移动超过 `kTouchSlop`（18 逻辑 px）
             * ⇒ `onHorizontalDragStart` 的 `localPosition` 是
             *   **按下点 + 已滑过的距离**，**不是**按下点。
             *
             * ★ 于是命中判定用的坐标，比用户真正按下的地方偏了 ~20px：
             * ```text
             * 箭身宽 21px，_hitR = 20px
             * 用户按在箭身**中心**  ⇒ 偏移 20px 后正好落在半径边界上 ⇒ 勉强命中
             * 用户按在箭身**边缘**  ⇒ 偏移后**必然出界** ⇒ 抓不住
             * ```
             * ⇒ 真机上"必须按得极准且手不能动"才拖得动 —— 手感就是**坏的**。
             *
             * # 修法：`dragStartBehavior: DragStartBehavior.down`
             * ⇒ 让 `onHorizontalDragStart` 收到**按下时**的位置，
             *   与 `onTapDown` 的 `localPosition` 同源
             *   （实测 `onTapDown` 一直是准的：点正中拿到 `secOf(400)=300.0`）。
             *
             * ⚠️ 为什么不在 `hitEdge` 里放宽半径（那是"治症状"）：
             *    放宽到 40px 会让**两个相邻箭头**同时进入命中范围
             *    （`introStart`/`introEnd` 在退化情况下会挨得很近，
             *    见 `computeSkipTips` 的"错开"那两轮），
             *    那时用户想抓 A 却抓到 B —— 比"抓不住"更糟。
             *    ★ 正解是**让坐标回到它本该是的东西**，而不是把判据放宽。
             */
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (d) {
              final e = hitEdge(d.localPosition);
              if (e == null) return;
              /*
               * 记下"手指落点 - 箭头 tip"的偏移 —— 拖动时减掉它，
               * 箭头就不会在按下瞬间跳一下（见 `_grabOffset` 说明）。
               *
               * ⚠️ 2026-10-01：未设置的端点（幽灵箭头）**也要**算这个偏移。
               *    改前这里是 `drawTips[e] ?? 0` —— 对幽灵来说
               *    `drawTips[e] == null` ⇒ 偏移 = **整个 localPosition**
               *    （即"离左边缘多远"）⇒ 一按下箭头就**跳到手指位置**，
               *    手感是"抓不住、箭头飞了"。
               *    ★ 用 `tipForHit(e)`（与 `hitEdge`、与画家**同一个来源**）
               *      才是对的。
               */
              _grabOffset = d.localPosition.dx - tipForHit(e);
              setState(() => _dragging = e);
            },
            onHorizontalDragUpdate: (d) {
              final e = _dragging;
              if (e == null) return;
              /*
               * ⚠️ 用**真实 x** 换算秒数（不是 `drawTips`）
               *
               * 平移只是为了"看得见、抓得到"。拖拽若按平移后的位置算，
               * 用户会发现拖到某个像素时秒数跳变 —— 手感很怪。
               */
              widget.onChanged(e, secOf(d.localPosition.dx - _grabOffset));
            },
            onHorizontalDragEnd: (_) {
              if (_dragging != null) setState(() => _dragging = null);
            },
            onHorizontalDragCancel: () {
              if (_dragging != null) setState(() => _dragging = null);
            },
            child: CustomPaint(
              size: Size(w, _canvasH),
              painter: _QuarkTimelinePainter(
                total: widget.total,
                position: widget.position,
                tipX: drawTips,
                pointsRightFn: skipEdgePointsRight,
                introStart: widget.introStart,
                introEnd: widget.introEnd,
                outroStart: widget.outroStart,
                outroEnd: widget.outroEnd,
                dragging: _dragging,
                trackH: _trackH,
                arrowW: kArrowW,
                arrowH: _arrowH,
                inset: kArrowInset,
                canvasH: _canvasH,
                colors: colors,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuarkTimelinePainter extends CustomPainter {
  _QuarkTimelinePainter({
    required this.total,
    required this.position,
    required this.tipX,
    required this.pointsRightFn,
    required this.introStart,
    required this.introEnd,
    required this.outroStart,
    required this.outroEnd,
    required this.dragging,
    required this.trackH,
    required this.arrowW,
    required this.arrowH,
    required this.inset,
    required this.canvasH,
    required this.colors,
  });

  final double total;
  final double position;
  final Map<SkipEdge, double?> tipX;
  final bool Function(SkipEdge) pointsRightFn;
  final int? introStart;
  final int? introEnd;
  final int? outroStart;
  final int? outroEnd;
  final SkipEdge? dragging;
  final double trackH;
  final double arrowW;
  final double arrowH;
  final double inset;
  final double canvasH;
  final FColors colors;

  /// 片头色 —— 原版 `--skipdlg-accent: #e8b04b`（琥珀，给**深色**播放器底做的）
  static const _introAmber = Color(0xFFE8B04B);

  /// 片尾色 —— 原版另一套 `--skipdlg-accent: #5b8cff`（蓝）
  ///
  /// ⚠️ 用**两个颜色**区分片头/片尾是有意的：
  ///    两个区间在时间轴上可能挨得很近，同色的话分不清哪个是哪个。
  static const _outroBlue = Color(0xFF5B8CFF);

  /// 浅色主题下的箭头色（**必须压暗**）
  ///
  /// # 为什么不能直接用原版那个琥珀（2026-09-24 算出来的）
  ///
  /// 原版 `#e8b04b` 是给**深色**播放器底做的，对比度很足。
  /// 但本机是浅色主题，时间轴轨道是 `colors.secondary` = `#E8EAF0`
  /// （接近白）。两者放一起：
  /// ```text
  /// 琥珀 #e8b04b 相对亮度 0.4643
  /// 轨道 #e8eaf0 相对亮度 0.8206
  /// 对比度 = (0.8206+0.05) / (0.4643+0.05) = 1.69 : 1
  /// ```
  /// **1.69:1** —— 箭头会糊在轨道上，几乎看不出形状。
  /// 这是"设计参考是深色截图、直接把色搬进浅色主题"的经典翻车
  /// （项目里踩过同款：设置页标题对比度只剩 1.16:1）。
  ///
  /// # 修法：只压亮度、**不动色相**
  ///
  /// ```text
  /// 琥珀 #e8b04b → #A8720A   对比度 ≈ 3.6:1
  /// 蓝   #5b8cff → #1F4FD8   对比度 ≈ 5.5:1
  /// ```
  /// 色相/角色不变（片头还是琥珀、片尾还是蓝），只是把明度压到
  /// 浅底上能看清 —— 语义保留、可读性恢复。
  static const _introOnLight = Color(0xFFA8720A);
  static const _outroOnLight = Color(0xFF1F4FD8);

  /// 片头实际用色（按主题亮度选）
  ///
  /// ★ 走**公开**的 [skipIntroColor] —— 与弹窗四行的配对色条同源，
  ///   保证"行上的色条"和"轴上的箭头"永远同色（见该函数的说明）。
  Color get introColor => skipIntroColor(colors.brightness);

  /// 片尾实际用色（按主题亮度选）
  ///
  /// ★ 走**公开**的 [skipOutroColor] —— 与弹窗四行的配对色条同源。
  Color get outroColor => skipOutroColor(colors.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final trackTop = (canvasH - trackH) / 2;
    final trackLeft = inset;
    final trackRight = w - inset;
    final trackW = math.max(trackRight - trackLeft, 1.0);
    final r = Radius.circular(trackH / 2);

    double xOf(num sec) => xOfTip(width: w, total: total, sec: sec);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-02：**时间刻度 + 当前时间**（Owner：「时间轴加时间刻度」）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么画在**同一个 64px 画布里**，不加高
     * 弹窗的高度预算是**硬约束**（`kMidRestH`，见 `skip_marker_dialog.dart`）：
     * 加一行 24px 的刻度条 ⇒ 预览区就得矮 24px ⇒ 四行读数被挤出视口
     * （那正是 Owner 报过的「只看到片头两行」）。
     * ★ 而画布本来就上下留白：轨道只占 y=28..36，
     *   **y=44..58 是空的** ⇒ 刻度画在那里**零成本**。
     *
     * # 画什么
     * ```text
     * 底部：0:00        当前 12:34        47:06
     *        └ 起点刻度      └ 跟随画面      └ 终点刻度
     * ```
     * ★ "当前"用**主题色**（`colors.primary`）且**加粗** ——
     *   它是这一行里唯一**会动**的东西，用户扫一眼就能定位。
     *   ⚠️ 但 `colors.primary` 在 forui 浅色主题下是近黑（见 lesson #559），
     *      所以这里**不用它** —— 改用 `colors.foreground`（明确的文字色），
     *      与左右两个静态度量用 `mutedForeground` 区分开。
     */
    void drawTickLabels() {
      const fontSize = 10.0;
      final y = canvasH - 6; // 贴着画布底边

      TextPainter tp(String s, Color c, {bool bold = false}) {
        final p = TextPainter(
          text: TextSpan(
            text: s,
            style: TextStyle(
              color: c,
              fontSize: fontSize,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        return p;
      }

      // 三个标签都先量好尺寸，**再决定画谁**（见下面的重叠判定）
      final left = tp('0:00', colors.mutedForeground);
      final right = tp(_fmtClock(total), colors.mutedForeground);
      final cur = tp('▶ ${_fmtClock(position)}', colors.foreground, bold: true);

      /*
       * ── 中：当前时间（跟随画面）──
       * ⚠️ 位置**跟随播放头 x**（而不是永远居中）——
       *    这样它和轨道上的位置是**同一个语义**，用户能把
       *    "数字"和"画面在哪"直接对上。
       * ⚠️ 左右夹住，避免贴边时文字出界。
       */
      var cx = xOf(position) - cur.width / 2;
      cx = cx.clamp(trackLeft, math.max(trackLeft, trackRight - cur.width));

      final curRect = Rect.fromLTWH(
        cx,
        y - cur.height,
        cur.width,
        cur.height,
      );
      final leftRect = Rect.fromLTWH(
        trackLeft,
        y - left.height,
        left.width,
        left.height,
      );
      final rightRect = Rect.fromLTWH(
        trackRight - right.width,
        y - right.height,
        right.width,
        right.height,
      );

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：**静态刻度必须给「当前时间」让位**（真机截图发现的丑）
       * ══════════════════════════════════════════════════════════════════
       *
       * 判据在 [tickLabelsCollide]（纯函数，有独立的边界测试）。
       * 这里只负责"按判据决定画谁"。
       *
       * 为什么是这个方向（静态让位、当前时间不动）：见 [tickLabelsCollide] 的文档。
       */
      if (!tickLabelsCollide(leftRect, curRect)) {
        left.paint(canvas, leftRect.topLeft);
      }
      if (!tickLabelsCollide(rightRect, curRect)) {
        right.paint(canvas, rightRect.topLeft);
      }
      cur.paint(canvas, curRect.topLeft);
    }

    drawTickLabels();

    // ── ① 轨道（细线，两端留出箭头位置）──
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(trackLeft, trackTop, trackW, trackH),
        r,
      ),
      Paint()..color = colors.secondary,
    );

    // ── ② 已播进度 ──
    final played = xOf(position);
    if (played > trackLeft) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(trackLeft, trackTop, played - trackLeft, trackH),
          r,
        ),
        Paint()..color = colors.foreground.withValues(alpha: 0.30),
      );
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 绘制顺序（2026-09-24 真机 6 倍放大后发现的问题）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 症状
     *
     * `position = 0`（预览停在开头）+ `introStart = 0` 时，
     * 播放头和"片头开始"箭头**在同一个 x**。而播放头原本是**最后画**的
     * —— 于是那条黑线**盖在箭头上**，6 倍放大看得清清楚楚：
     * ```text
     * ▶ 琥珀三角 | ← 黑色播放头线插在尖端
     * ```
     * 观感是"箭头被劈成两半"，很脏。
     *
     * # 修法：按**交互优先级**排绘制顺序
     *
     * ```text
     * 底 → 轨道
     *      已播进度
     *      区间高亮      ← 表达"这段会被跳过"
     *      播放头        ← 只是"当前位置"指示
     * 顶 → 四个箭头      ← **用户要抓的东西，永远最上层**
     * ```
     * 理由：几个元素重合时，**可交互的那个必须可见** ——
     * 用户抓不到箭头就以为功能坏了，而播放头只是个指示。
     *
     * ⚠️ 播放头被箭头盖住是**可接受的**（它还在，只是被挡一下）；
     *    反过来才对（箭头被盖住 → 抓不到）。
     *
     * ★ 2026-09-24 第二次修正：播放头从"区间高亮**之前**"挪到"**之后**"
     *
     * 原来的顺序是 播放头 → 区间高亮，于是又冒出一个新症状：
     * ```text
     * 预览拖到区间**内部**（例如片头 0-123 的中间）时，
     * 0.72 不透明的琥珀高亮**整条盖在播放头上面**
     * → 播放头那条线和圆点直接消失
     * → 用户拖动时看不出"当前画面在第几秒"，
     *   而这恰恰是这个弹窗唯一能判断"设得对不对"的依据
     * ```
     * 所以顺序再调一次：**高亮在下、播放头在上**。
     * 高亮是"面"（表达一段范围），播放头是"点"（表达当前时刻）——
     * 点盖面才不会互相吃掉。
     */

    // ── ③ 两个区间的"会被跳过"高亮 ──
    //
    // ⚠️ 用 `tipX`（箭头的语义位置）而不是 `xOf(秒)` ——
    //    两者在退化情况下可能不同（同向箭头被右移过），
    //    高亮必须跟着箭头走，否则"高亮从箭头右边开始"。
    //
    // ⚠️ 透明度 0.55 → **0.72**（2026-09-24）
    //    实测浅色主题下 `colors.secondary`（轨道底）本身很浅，
    //    琥珀 55% 叠上去是 `(237,206,152)` —— 一片"洗白"的浅棕，
    //    完全看不出"这段会被跳过"。
    void drawRange(SkipEdge startEdge, SkipEdge endEdge, Color color) {
      final a = tipX[startEdge];
      final b = tipX[endEdge];
      if (a == null || b == null) return;
      final lo = math.max(math.min(a, b), trackLeft);
      final hi = math.min(math.max(a, b), trackRight);
      if (hi - lo < 1) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lo, trackTop, hi - lo, trackH),
          r,
        ),
        Paint()..color = color.withValues(alpha: 0.72),
      );
    }

    drawRange(SkipEdge.introStart, SkipEdge.introEnd, introColor);
    drawRange(SkipEdge.outroStart, SkipEdge.outroEnd, outroColor);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-01：**播放头已删除**（Owner 第三次提这根线）
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（三次，逐字）
     * ```text
     * ① 「一个竖着的东西」                      ← 2026-09-24，当时加了 caret
     * ② 「片头片尾设置那里,有一个黑色的竖着的线,给删除了这个」
     * ③ 「删除掉那个黑色的,然后只保留片头片尾的四个箭头就行了」  ← 本次拍板
     * ```
     *
     * # 为什么加了 caret 还是被当成"黑色的竖线"
     *
     * ```text
     * ① 颜色确实是黑的 —— 不是观感问题，是**取色取错了**：
     *      `_drawPlayhead` 用的是 `colors.primary`，
     *      而这里的 `colors` 是 **forui 的 `FColors`**
     *      （`FTheme.of(context).colors`，见 `:487`）。
     *      实测 `FTheme.neutral.light` 的 `primary = #171717`（近黑）
     *      —— **不是** Material 那套 `#3B6FE0` 品牌蓝。
     *      ★ 原注释写着「颜色 colors.foreground → colors.primary，
     *        品牌色 = 明确的"控件"语义」—— 那个"品牌色"的假设
     *        **对 forui 不成立**。Owner 截图里量到的是 `#2E2E2E`
     *        （`#171717` 抗锯齿后的值），与这条完全吻合。
     *   ② 形状仍然是一根 2px 宽的**竖线**（`Rect.fromLTWH(px-1, …, 2, …)`）
     *      ⇒ 在一条**浅色**轨道上，一根近黑的 2px 竖线**就是**"黑色的竖线"，
     *        无论它上面有没有一个小三角。
     * ```
     *
     * # 为什么直接删（而不是改颜色）
     *
     * Owner 明确说了「**只保留片头片尾的四个箭头就行了**」。
     * 而且从功能上讲这个决定是自洽的：
     * ```text
     * · 时间轴上方就是**视频预览**（`_previewBox`）——
     *   "当前在第几秒"由画面本身回答，比一根线更直观
     * · 四个箭头才是**可交互**的东西（用户要抓的是它们）
     * · 播放头只是"指示"，删掉不损失任何操作能力
     * ```
     * ⇒ 前两次我都在"改进播放头"（先调绘制顺序、后加 caret + 换色），
     *   而 Owner 的诉求是**不要它**。★ 教训：当同一个东西被反复提
     *   三次，要先问"要不要删"，而不是继续"怎么把它做好看"。
     *
     * ⚠️ `_drawPlayhead` 方法**一并删除**（不是留着不调用）——
     *    留一个死方法，下一个人会以为它还在用，或者顺手又接回去。
     * ⚠️ `position` 这个参数**仍然保留**：`shouldRepaint` 与
     *    `computeSkipTips` 都在用它，且将来若要恢复播放头还得有它。
     *    只是**不再画出来**。
     */

    // ── ④ 四个实心大箭头（夸克式的核心，画在最上层）──
    //
    // 方向语义：
    // ```text
    // 区间**开始** → 箭头指向**右**（"从这里开始跳"）
    // 区间**结束** → 箭头指向**左**（"跳到这里为止"）
    // ```
    // 两个开始 + 两个结束 = 四个，正是用户说的
    // 「四个小箭头,片头两个,结束两个」。
    //
    // 几何（tip 是语义位置）：
    // ```text
    // 朝右:  [tip-aw, tip-ah/2] → [tip, 0] → [tip-aw, tip+ah/2]
    // 朝左:  [tip+aw, tip-ah/2] → [tip, 0] → [tip+aw, tip+ah/2]
    // ```
    // 于是两个 tip 落在同一 x 时**天然形成对称领结**（宽 2·aw）。
    void drawArrow(SkipEdge edge, Color color) {
      final tip = tipX[edge];
      final active = dragging == edge;
      final right = pointsRightFn(edge);

      final cy = trackTop + trackH / 2;
      // 拖动中的箭头画大一点（视觉反馈）
      final scale = active ? 1.18 : 1.0;
      final aw = arrowW * scale;
      final ah = arrowH * scale;

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 未设置的端点画**幽灵箭头**（2026-09-25 用户实测的核心问题）
       * ══════════════════════════════════════════════════════════════
       *
       * # 用户原话
       *
       * > **只有片头的两个按钮，没有片尾的两个按钮**
       *
       * # 真机复现到的根因（`.probe\dlg\dlg-probe.txt`）
       *
       * 代码里**四个 `_EdgeRow` 都在**（真机实测 `四行命中: 4/4`），
       * 时间轴也**确实调了四次 `drawArrow`**。但原来第一行是：
       * ```dart
       * final tip = tipX[edge];
       * if (tip == null) return;      // ← ★ 未设置就直接不画
       * ```
       * 而用户当时的数据是「片头 0-123，片尾未设置」（见
       * `.probe\user-view` 的 `tyyszy:70260`）→ 四个端点里
       * **只有 introStart/introEnd 有值** → 屏幕上**只看到两个琥珀箭头**。
       *
       * 用户看到的是"只有片头的两个箭头"，就以为"片尾那两个按钮没做"。
       * 他的判断链完全合理 —— **是我们没把"未设置"这个状态画出来**。
       *
       * # 修法：未设置时画一个**半透明的实心**箭头占位
       *
       * ```text
       * 已设置  → 实心 + 投影（原样，可拖）
       * 未设置  → 实心但**淡**（表达"这里**可以**放一个端点，但还没设"）
       * ```
       * 于是四个位置**永远都看得见**，用户一眼就知道"片尾两个也在，
       * 只是还没设"—— 这才是他要的"四个按钮"。
       *
       * ⚠️ **不能用描边**来区分 ——
       *    本项目有一条硬规则：夸克那种箭头是**实心无描边**的，
       *    加描边在深色底上会显得"空心/细"，与参考图不符
       *    （`skip_marker_test.dart` 有断言守着：源码里不得出现描边样式）。
       *    所以幽灵态用**实心 + 低透明度**，保持同一套形状语言，
       *    只靠浓淡区分状态。
       *
       * ⚠️ 幽灵箭头**不可拖**（`hitEdge` 只看 `tipX`，null 就命中不到）——
       *    这是对的：没设过的点没有"位置"可言，用户应该用右边那行的
       *    `−/+` 把它设出来（那才是"开始/结束"的入口）。
       */
      if (tip == null) {
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 幽灵位置 = **按「配对」摆放**（2026-09-25 任务㉝）
         * ══════════════════════════════════════════════════════════════
         *
         * # 用户原话（逐字）
         *
         * > 片头片尾 设置根本不好用，**片头的开始和片尾开始都在最前面**
         * > **片头的结尾和片尾的结尾都在最后面**，应该是片头的设置，
         * > 开始与结束都在最前面 **是一对的**，然后。片尾。的设置
         * > **都在最后面，并且是一对的**
         * > 你现在的设计完全就是。违反操作直觉
         *
         * # 改之前的写法（就是用户抱怨的那个）
         *
         * ```dart
         * final ghostTip = right ? inset + arrowW : (size.width - inset - arrowW);
         * ```
         * 它**只按箭头方向**决定位置，于是：
         * ```text
         * 两个「开始」（都朝右）→ 都贴**最左** ⇒ **完全重合**
         * 两个「结束」（都朝左）→ 都贴**最右** ⇒ **完全重合**
         * ```
         * 实测（轴宽 800）：`introStart x=42.0` 与 `outroStart x=42.0` 同一点，
         * `introEnd x=758.0` 与 `outroEnd x=758.0` 同一点。
         *
         * ★ 渲染出来只有**两个**幽灵箭头（我渲了图，`.probe/t33_unset.png`）——
         *   而用户要的是**四个**（"片头两个、片尾两个"）。
         *   他分不清哪个是片头的、哪个是片尾的 ⇒ 这就是"违反操作直觉"。
         *
         * # 现在的写法：每个幽灵**贴着自己的同伴**
         *
         * ```text
         * [片头开始][片头结束] ·········· [片尾开始][片尾结束]
         *   ↑ 片头一对在**最前**          ↑ 片尾一对在**最后**
         * ```
         * 逐条对上用户的话：
         * ```text
         * 「片头的设置，开始与结束都在最前面，是一对的」→ intro 一对在最左 ✓
         * 「片尾的设置，都在最后面，并且是一对的」      → outro 一对在最右 ✓
         * ```
         *
         * # ★ 为什么用「同伴的默认位置」而不是「均匀铺开」
         *
         * ```text
         * 均匀铺开（4 等分）→ 幽灵会落在时间轴**中段**，
         *   而"片尾"在语义上就该在**末尾**。中段的幽灵会让用户
         *   以为"片尾在这里"，反而给出**错误信息**。
         * 贴着同伴 → 幽灵位置本身就在表达"这一对管的是哪一段"：
         *   片头一对靠前、片尾一对靠后。位置就是信息。
         * ```
         *
         * ⚠️ **2026-10-01 更正**：本段原来写着「幽灵**仍不可拖**…这是对的」。
         *    ★ 那个判断**是错的** —— Owner 实测反馈「那个三角根本就不能拖动」。
         *    真因：`hitEdge` 只用 `computeSkipTips` 的值（未设置 ⇒ null）
         *    ⇒ 四个幽灵箭头**画出来了但在命中测试里不存在**。
         *    ⇒ 已改为**用 `ghostTipFor` 的位置参与命中**（见 `bodyCenterForHit`）。
         *    ★ 纪律：**画出来的东西就应该是可交互的**。
         */
        final ghostTip = ghostTipFor(
          edge: edge,
          width: size.width,
          inset: inset,
          arrowW: arrowW,
        );
        final gBase = right ? ghostTip - aw : ghostTip + aw;
        final ghostPath = Path()
          ..moveTo(gBase, cy - ah / 2)
          ..lineTo(ghostTip, cy)
          ..lineTo(gBase, cy + ah / 2)
          ..close();
        canvas.drawPath(
          ghostPath,
          Paint()..color = color.withValues(alpha: 0.28),
        );
        return;
      }

      final base = right ? tip - aw : tip + aw;

      final path = Path()
        ..moveTo(base, cy - ah / 2)
        ..lineTo(tip, cy)
        ..lineTo(base, cy + ah / 2)
        ..close();

      /*
       * 投影：让实心箭头从细轨道上"立起来"
       *
       * ⚠️ 夸克那个箭头是**实心无描边**的。我第二版加了 1.5px 白描边，
       *    在深色底上会显得"空心/细"，与参考图不符 —— 去掉。
       */
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.30)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      canvas.drawPath(path, Paint()..color = color);
    }

    drawArrow(SkipEdge.introStart, introColor);
    drawArrow(SkipEdge.introEnd, introColor);
    drawArrow(SkipEdge.outroStart, outroColor);
    drawArrow(SkipEdge.outroEnd, outroColor);
  }

  @override
  bool shouldRepaint(_QuarkTimelinePainter old) =>
      old.position != position ||
      old.total != total ||
      old.dragging != dragging ||
      old.introStart != introStart ||
      old.introEnd != introEnd ||
      old.outroStart != outroStart ||
      old.outroEnd != outroEnd;
}
