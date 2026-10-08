// ═══════════════════════════════════════════════════════════════════════
//  task-50 候选 A：`PosterCard` 按下反馈（组件级接线）
// ═══════════════════════════════════════════════════════════════════════
//
// # 被测的生产改动（`lib/ui/widgets/poster_card.dart`）
// ```text
// build() 里把原来的
//     SizedBox(child: InkWell(child: Column(...)))
// 包成
//     SizedBox(child: PressFeedback(
//       enabled: widget.onTap != null && !_hasPressAncestor,
//       child: InkWell(child: Column(...))))
// ★ 对外构造参数**一字未改**；`coverImage(` 接线（task-74 判据）**未动**。
// ```
//
// ★★ 2026-10-03 追加（**只加不改**）：`PosterCard` 新增一个**可选**参数
//    `this.titleLines = 1`，用于把标题从单行改成两行（对齐原版
//    `base.css:844-854` 的 `-webkit-line-clamp: 2`）。
//    ⇒ 原来那 9 项**顺序、类型、默认值全部未变**，只是**尾部追加**一项；
//      5 个调用点不传它时行为**逐位不变**（D1 已按这个口径加固）。
//
// # Lead 的验收口径（逐字）
// ```text
// 验收 = `tester.pump(Duration)` 推 t=0/45/90/150ms **四个不同的中间值**
//        + `MotionPrefs` 关闭的**阴性对照**（四刻读数应相同）。
// ★ 90ms 与 150ms 若**无法区分** ⇒ 如实报**仪器分辨率不足**，
//   不许写成「时长 ≤150ms」。
// ```
//
// # 仪器：读**渲染出来的**缩放，不是读参数
// ```text
// `AnimatedScale` 是 `ImplicitlyAnimatedWidget` ⇒ widget 上的 `scale` 是**目标值**，
// 不是"现在画多大"。真正画多大在
//   `AnimatedScale` → `ScaleTransition` → `Transform` 的矩阵里
//   （SDK 依据：implicit_animations.dart:1554 `return ScaleTransition(...)`
//              transitions.dart:370 `Matrix4.diagonal3Values(value, value, 1.0)`）
// ⇒ 读 `Transform.transform.storage[0]`。
// ```
//
// # ★ 采样分辨率**不是**"帧"
// ```text
// `tester.pump(Duration)` 把**假时钟**精确推进那么久 ⇒ 动画控制器按
// **精确经过时间**求值 ⇒ 采样分辨率是 double 的精度，不是 16.7ms 一帧。
// ⇒ 两个采样点读到相同值，**只可能**是"这段区间内动画状态没变"，
//   而**不可能**是"仪器太粗"。本文件用「同一次运行里前三点互不相同」
//   来证明这一点（见 A1）。
// ```
//
// # 四刻逐字读数落在哪
// ```text
// `.probe\t50a_press_four_points.txt` —— 本文件运行时写出的 `[T50A]` 行。
// ★ 同时 `print` 一份（控制台可能吞 stdout；两边都要有）。
// ```
//
// # 为什么阴性对照必须存在（#334 那类）
// ```text
// 「四个时刻读到四个不同的值」这句断言，如果仪器**恒返回常数**也一样能过？
//   ⇒ 不能。恒常数时它必红。
// 但反过来：如果仪器**恒返回变动值**（比如读了别的动画），它也能过。
//   ⇒ 所以要有阴性对照：Reduce Motion 下**必须**四刻相同。
// 两条一起才说明"这台仪器能分辨'有过渡'和'没过渡'"。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/press_feedback.dart';

// ═══════════════════════════════════════════════════════════════════════
//  0. 读数落盘
// ═══════════════════════════════════════════════════════════════════════

const String kPosterSrc = 'lib/ui/widgets/poster_card.dart';

final File _log = File('.probe/t50a_press_four_points.txt');

/// 记一行读数：**既 print 也落盘**
///
/// ★ 两边都要：控制台可能吞 stdout / 编码可能坏掉，但**产物文件不能没有读数**。
void _rec(String line) {
  // ignore: avoid_print
  print(line);
  _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

// ═══════════════════════════════════════════════════════════════════════
//  1. 挂载 + 测量
// ═══════════════════════════════════════════════════════════════════════

/// 带**真主题**挂载（`PosterCard` 依赖 `Theme.of` 取色；裸 `MaterialApp` 取不到色）
///
/// ★ `reduceMotion` 用 `copyWith` 改**同一个** `MediaQueryData`，
///   而不是 `MediaQueryData(disableAnimations: true)` 造一个新的 ——
///   后者会把 `size` 等字段全变成默认值（`Size.zero`），
///   给"读尺寸"的断言埋一个与本题无关的坑。
Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light
        ? buildLightMaterialTheme(theme)
        : buildMaterialTheme(theme),
    builder: (ctx, c) {
      final base = MediaQuery.maybeOf(ctx) ?? const MediaQueryData();
      return FTheme(
        data: theme,
        child: MediaQuery(
          data: base.copyWith(disableAnimations: reduceMotion),
          child: c ?? const SizedBox(),
        ),
      );
    },
    home: Scaffold(
      backgroundColor: AppTheme.floorColor(brightness),
      body: Center(child: child),
    ),
  );
}

/// 用**真实窗口尺寸** 1280x800（本仓纪律：默认 800x600 太窄 ⇒ 假 overflow）
Future<void> _pumpCard(
  WidgetTester t,
  Widget card, {
  bool reduceMotion = false,
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(host(card, reduceMotion: reduceMotion));
  await t.pump(Duration.zero);
}

/// `of` 子树里**所有** `Transform` 的 `storage[0]`（= x 方向缩放）
///
/// ★ 返回列表而不是单个值：若某处意外多出一层 `Transform`，
///   断言 `length == 1` 会**当场报错**，而不是悄悄读错那一个。
List<double> _transformsUnder(WidgetTester t, Finder of) {
  final tf = find.descendant(of: of, matching: find.byType(Transform));
  final out = <double>[];
  for (var i = 0; i < tf.evaluate().length; i++) {
    out.add(t.widget<Transform>(tf.at(i)).transform.storage[0]);
  }
  return out;
}

/// `PosterCard` 子树里**实际渲染**的缩放（不是 `AnimatedScale.scale` 那个目标值）
double? _cardScale(WidgetTester t) {
  final ss = _transformsUnder(t, find.byType(PosterCard));
  if (ss.isEmpty) return null;
  for (final s in ss) {
    if ((s - 1.0).abs() > 1e-9) return s; // 带缩放的那一层
  }
  return ss.first; // 已回到 1.0
}

/// 从**当前**时刻起，把假时钟推到 t=0/45/90/150ms，每点读一次
///
/// ★ 调用方必须已经把动画**启动**（`pump(Duration.zero)` 过一帧），
///   否则 t=0 读到的是启动前的状态。
Future<List<double?>> _fourPoints(WidgetTester t) async {
  final out = <double?>[_cardScale(t)];
  var acc = 0;
  for (final ms in const [45, 90, 150]) {
    await t.pump(Duration(milliseconds: ms - acc));
    acc = ms;
    out.add(_cardScale(t));
  }
  return out;
}

/// 四个时刻里**最小**的两两间距
///
/// ★ 这量的是**信号属性**（这四个采样时刻之间，动画状态一共变了多少），
///   **不是**"仪器分辨率" —— 本仪器读 `Transform.storage[0]`，拿回来的是
///   精确 double，它的分辨力远小于任何可观测的动画差异。
///   仪器"不自己编造差异"的证据在 **B1/B2**：状态**真的**相同时 minGap = 0。
double _minGap(List<double?> xs) {
  var m = double.infinity;
  for (var i = 0; i < xs.length; i++) {
    for (var j = i + 1; j < xs.length; j++) {
      final d = (xs[i]! - xs[j]!).abs();
      if (d < m) m = d;
    }
  }
  return m;
}

String _fmt(List<double?> xs) =>
    xs.map((e) => e == null ? 'null' : e.toStringAsFixed(6)).join(' / ');

void _noNull(List<double?> xs, String where) {
  expect(xs.every((e) => e != null), isTrue,
      reason: '★ $where：四刻读数都不该是 null'
          '（说明 `PosterCard` 没挂上，或者子树里没有 PressFeedback 那一层）');
}

// ═══════════════════════════════════════════════════════════════════════
//  2. 生产源码静态断言用的仪器
// ═══════════════════════════════════════════════════════════════════════

/// 读生产源码并**剥掉注释**
///
/// ⚠️ 必须剥注释（本仓踩过：把注释里的示例代码当成真代码 ⇒ 假绿/假红）。
///    ★ 本文件尤其需要：`poster_card.dart` 里有一段注释**逐字引用了旧写法**
///      （`? '?'`），不剥注释会让下面的断言读到注释而不是代码。
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

/// 抽出 `const PosterCard({...})` 的参数列表（逐项，已规范化空白）
List<String> _ctorParams(String code) {
  final i = code.indexOf('const PosterCard(');
  if (i < 0) return <String>[];
  final start = code.indexOf('{', i);
  if (start < 0) return <String>[];
  var depth = 0;
  var end = -1;
  for (var k = start; k < code.length; k++) {
    final ch = code[k];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        end = k;
        break;
      }
    }
  }
  if (end < 0) return <String>[];
  return code
      .substring(start + 1, end)
      .split(',')
      .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

const List<String> kExpectedParams = <String>[
  'super.key',
  'required this.title',
  'this.cover',
  'this.subtitle',
  'this.badge',
  'this.unread = 0',
  'this.onTap',
  'this.width',
  'this.focused = false',
  // ★★ 2026-10-03 追加：**可选**的标题行数（默认 1 ⇒ 与旧行为逐位相同）
  'this.titleLines = 1',
];

// ═══════════════════════════════════════════════════════════════════════

void main() {
  _log.parent.createSync(recursive: true);
  _log.writeAsStringSync('');

  // ═════════════════════════════════════════════════════════════════════
  group('A. 四刻中间态（Lead 口径：t=0/45/90/150ms）', () {
    testWidgets('A1 按下（Motion.press=90ms）：四刻读数 + 90/150 相同的**原因**',
        (t) async {
      await _pumpCard(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
      );

      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      await t.pump(Duration.zero); // 触发 setState 的那一帧：动画从 t=0 开始
      final r = await _fourPoints(t);

      _noNull(r, 'A1 按下');
      _rec('[T50A] A1 按下 90ms 四刻读数 (t=0/45/90/150ms) = ${_fmt(r)}');
      _rec('[T50A] A1 按下 前三点最小两两间距 = '
          '${_minGap(<double?>[r[0], r[1], r[2]]).toStringAsFixed(9)}');

      expect(r[0]!, closeTo(1.0, 1e-6),
          reason: '★ t=0 应当还是**起始值** 1.0（动画刚起步，还没走）');
      expect(r[1]! > 0.97 + 1e-4, isTrue,
          reason: '★ t=45ms 应当已经动了一点（实测=${r[1]}）');
      expect(r[1]! < 1.0 - 1e-4, isTrue,
          reason: '★ 但还没到终点 —— 否则就是"没有过渡"（实测=${r[1]}）');
      expect(r[2]!, closeTo(0.97, 1e-6),
          reason: '★ t=90ms 应当**已经**到终点 0.97（Motion.press=90ms）');
      expect(r[3]!, closeTo(0.97, 1e-6),
          reason: '★ t=150ms 与 t=90ms 相同 —— 因为按下动画**在 90ms 就结束了**。'
              '这不是"仪器分辨率不足"：同一次运行里前三点互不相同（见下一条断言）');

      /*
       * ★★ 这一条是 A1 的**核心论证**（也是 Lead 那条 ★ 的正面回答）
       *
       * 若 r[2] == r[3] 是"仪器太平"造成的，那么 r[0]/r[1]/r[2] 也会互相相同。
       * 实测它们互不相同 ⇒ 仪器能分辨状态 ⇒ r[3] == r[2] 只能解释为
       * **区间 (90ms, 150ms] 内动画状态确实没变**（90ms 的动画早已走完）。
       */
      expect(_minGap(<double?>[r[0], r[1], r[2]]) > 1e-4, isTrue,
          reason: '★★ 同一次运行里 t=0/45/90 必须互不相同 —— '
              '它同时证明了"仪器有分辨力"和"t=150 相同 = 动画已结束"');

      await g.up();
      await t.pump(const Duration(milliseconds: 300));
    });

    testWidgets('A2 回弹（Motion.fast=150ms）：四刻读数**四点全不同**', (t) async {
      await _pumpCard(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
      );

      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      /*
       * ★ 这里必须**两次** pump，不能一次 `pump(300ms)`：
       *   手势的 `onPointerDown` 只做 `setState` ⇒ 下一次 pump **才**重建，
       *   而 `AnimatedScale` 的 `didUpdateWidget` 正是在那次重建里
       *   `forward(from: 0)` ⇒ **那一帧读到的仍是起点值**。
       *   一次 `pump(300ms)` 把"重建"和"推进 300ms"压在同一个 tick 里，
       *   动画从这一帧才开始 ⇒ 读回 1.0。
       *   （我第一版就是这么写的，红在这里；A1 的首次读数 1.000000 是同一机制的正面证据。）
       */
      await t.pump(Duration.zero); // ① 重建：按下动画在这一帧起步
      await t.pump(const Duration(milliseconds: 300)); // ② 走完 90ms 的按下动画
      expect(_cardScale(t), closeTo(0.97, 1e-6),
          reason: '前提：按下已经走完 ⇒ 回弹的起点才是 0.97');

      await g.up();
      await t.pump(Duration.zero); // 回弹动画从 t=0 开始
      final r = await _fourPoints(t);

      _noNull(r, 'A2 回弹');
      _rec('[T50A] A2 回弹 150ms 四刻读数 (t=0/45/90/150ms) = ${_fmt(r)}');
      _rec('[T50A] A2 回弹 四点最小两两间距 = '
          '${_minGap(r).toStringAsFixed(9)}  <- 四个采样时刻之间的最小状态变化量');

      expect(r[0]!, closeTo(0.97, 1e-6), reason: '★ 回弹起点 = 按下终点 = 0.97');
      expect(r[1]! > 0.97 + 1e-4, isTrue,
          reason: '★ t=45ms 应当比起点更接近 1.0（实测=${r[1]}）');
      expect(r[2]! > r[1]! + 1e-4, isTrue,
          reason: '★ t=90ms 应当**继续**朝 1.0 走（实测=${r[2]}）—— '
              '若这里已经等于 r[1]，说明回弹**不是** 150ms');
      expect(r[2]! < 1.0 - 1e-4, isTrue,
          reason: '★ t=90ms 还没到 1.0（Motion.fast=150ms，实测=${r[2]}）');
      expect(r[3]!, closeTo(1.0, 1e-6),
          reason: '★ t=150ms 应当已回到 1.0（Motion.fast=150ms）');

      // ★★ Lead 的验收口径本体：四个时刻读到**四个不同的中间值**
      expect(_minGap(r) > 1e-4, isTrue,
          reason: '★★ 四个时刻必须**两两不同**（实测最小间距='
              '${_minGap(r).toStringAsFixed(9)}）—— 这就是'
              '"t=0/45/90/150ms 各读到不同的中间值"');
    });

    /*
     * ★★ A3 = 对 Lead 那条 ★ 的**正面回答**：90ms 与 150ms **能不能区分**？
     *
     * A1/A2 各自证明了"90ms 的动画在 90ms 走完、150ms 的动画在 150ms 走完"，
     * 但那是**两条独立的运行**。Lead 问的是：这台仪器能不能把两者**判开**？
     *
     * 判别法 = **同一个 widget、同一个经过时间 90ms**，看两条动画各自的读数：
     *   按下动画（Motion.press=90ms）在 90ms 时**已经结束** ⇒ 读到终点 0.97
     *   回弹动画（Motion.fast =150ms）在 90ms 时**还在跑** ⇒ 读到中间值
     * ⇒ 同一时刻两个读数**不同** ⇒ 90ms 与 150ms 在这台仪器上**可区分**。
     *
     * 若两条时长其实一样（例如都被写成 150ms），90ms 时两个读数会**相同**。
     * ⇒ 这一条是"可区分"的**充分证据**，不依赖任何"仪器分辨率"的说法。
     */
    testWidgets('A3 同一时刻 90ms：按下已结束(0.97) vs 回弹还在跑 ⇒ 可区分',
        (t) async {
      await _pumpCard(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
      );

      // ── ① 按下动画走到 90ms（Motion.press = 90ms ⇒ 此刻应当**已结束**）
      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      await t.pump(Duration.zero);
      await t.pump(const Duration(milliseconds: 45));
      await t.pump(const Duration(milliseconds: 45)); // 累计 90ms
      final atPress90 = _cardScale(t);
      expect(atPress90, isNotNull, reason: '★ 按下 90ms 读不到缩放');
      _rec('[T50A] A3 同一时刻 90ms：按下动画读数 = '
          '${atPress90!.toStringAsFixed(6)}（Motion.press=90ms ⇒ 应已到 0.97）');

      // ── ② 松开，回弹动画**同样**走到 90ms（Motion.fast = 150ms ⇒ 还没结束）
      await g.up();
      await t.pump(Duration.zero); // 回弹从 0.97 起步
      await t.pump(const Duration(milliseconds: 45));
      await t.pump(const Duration(milliseconds: 45)); // 累计 90ms
      final atRelease90 = _cardScale(t);
      expect(atRelease90, isNotNull, reason: '★ 回弹 90ms 读不到缩放');
      _rec('[T50A] A3 同一时刻 90ms：回弹动画读数 = '
          '${atRelease90!.toStringAsFixed(6)}（Motion.fast=150ms ⇒ 应还在途中）');

      final gap = (atRelease90 - atPress90).abs();
      _rec('[T50A] A3 同一时刻两读数之差 = ${gap.toStringAsFixed(6)}'
          '（> 0 即证明 90ms 与 150ms **可区分**）');

      // 按下动画：90ms 时**已经结束**
      expect(atPress90, closeTo(0.97, 1e-6),
          reason: '★ 按下动画 90ms 应当已到终点（Motion.press=90ms），实测=$atPress90');
      // 回弹动画：90ms 时**还在途中**（这就是 150ms 与 90ms 的差别）
      expect(atRelease90 > 0.97 + 1e-4, isTrue,
          reason: '★ 回弹 90ms 应当已经离开起点（实测=$atRelease90）');
      expect(atRelease90 < 1.0 - 1e-4, isTrue,
          reason: '★★ 回弹 90ms 时**必须还没到 1.0** —— 若已到，说明回弹也是 90ms，'
              '那 90ms 与 150ms 就真的**不可区分**了（实测=$atRelease90）');
      // ★ 判别本体
      expect(gap > 1e-3, isTrue,
          reason: '★★ 同一个经过时间 90ms，两条动画读数必须**不同**（实测差=$gap）'
              ' —— 这就是"90ms 与 150ms 可区分"的直接证据');

      await t.pump(const Duration(milliseconds: 300));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('B. 阴性对照：Reduce Motion ⇒ 四刻读数**相同**', () {
    testWidgets('B1 按下：四刻全是 0.97（第一帧就到位，没有过渡）', (t) async {
      await _pumpCard(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
        reduceMotion: true,
      );

      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      await t.pump(Duration.zero);
      final r = await _fourPoints(t);

      _noNull(r, 'B1');
      _rec('[T50A] B1 阴性对照 按下（Reduce Motion）四刻读数 = ${_fmt(r)}');
      _rec('[T50A] B1 四刻最小两两间距 = ${_minGap(r).toStringAsFixed(9)}'
          '（应当 = 0）');

      expect(_minGap(r) < 1e-9, isTrue,
          reason: '★★ 阴性对照：四刻读数必须**完全相同**'
              '（实测最小间距=${_minGap(r).toStringAsFixed(9)}）—— '
              '它证明 A 组的"四点不同"不是仪器自己编出来的');
      expect(r.every((e) => (e! - 0.97).abs() < 1e-6), isTrue,
          reason: '★ Reduce Motion 下**仍然缩小**（反馈的"信息"不因无障碍丢失），'
              '丢掉的只是**过渡** —— 实测=${_fmt(r)}');

      await g.up();
      await t.pump(const Duration(milliseconds: 300));
    });

    testWidgets('B2 回弹：四刻全是 1.0', (t) async {
      await _pumpCard(
        t,
        PosterCard(title: '怒鲨狂潮', onTap: () {}),
        reduceMotion: true,
      );

      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      await t.pump(const Duration(milliseconds: 300));
      await g.up();
      await t.pump(Duration.zero);
      final r = await _fourPoints(t);

      _noNull(r, 'B2');
      _rec('[T50A] B2 阴性对照 回弹（Reduce Motion）四刻读数 = ${_fmt(r)}');

      expect(_minGap(r) < 1e-9, isTrue,
          reason: '★★ 回弹同样必须**无过渡**（实测最小间距='
              '${_minGap(r).toStringAsFixed(9)}）');
      expect(r.every((e) => (e! - 1.0).abs() < 1e-6), isTrue,
          reason: '★ 实测=${_fmt(r)}');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('C. 接线 / 零开销 / 不破坏行为', () {
    testWidgets('C1 卡片子树里**确有** PressFeedback，且只有一层缩放', (t) async {
      await _pumpCard(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));

      expect(
        find.descendant(
          of: find.byType(PosterCard),
          matching: find.byType(PressFeedback),
        ),
        findsOneWidget,
        reason: '★ 按下反馈必须**在卡片内部**（这样 5 个调用点都受益）',
      );
      expect(
        find.descendant(
          of: find.byType(PosterCard),
          matching: find.byType(AnimatedScale),
        ),
        findsOneWidget,
        reason: '★ 判据⑤：用 Flutter 惯用法 `AnimatedScale`（不是手写 controller）',
      );

      final ss = _transformsUnder(t, find.byType(PosterCard));
      _rec('[T50A] C1 PosterCard 子树 Transform 缩放列表（未按下）= $ss');
      expect(ss.length, 1,
          reason: '★ 未按下时子树里应当**恰好一层** `Transform`（= AnimatedScale 的）；'
              '多了说明有别的东西也插了 Transform，读数会读错');
      expect(ss.first, closeTo(1.0, 1e-9), reason: '★ 未按下必须是 1.0（不动）');
    });

    testWidgets('C2 不传 onTap ⇒ 零额外层（但卡片照常渲染）', (t) async {
      await _pumpCard(t, const PosterCard(title: '怒鲨狂潮'));

      expect(
        find.descendant(
          of: find.byType(PosterCard),
          matching: find.byType(AnimatedScale),
        ),
        findsNothing,
        reason: '★ `onTap == null` ⇒ `enabled=false` ⇒ `PressFeedback` **直接'
            '返回 child**，不留任何包装（"关"是真的关）',
      );
      expect(_transformsUnder(t, find.byType(PosterCard)), isEmpty,
          reason: '★ 零 `Transform` 层');

      // ★ 阳性对照：这条"零"不是"整个子树都没渲染"造成的
      expect(find.text('怒鲨狂潮'), findsOneWidget,
          reason: '★★ 阳性对照：卡片本身必须照常渲染（否则上面两条"零"是空的）');
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('C3 ★ 双层守卫：外层已包 PressFeedback 时，内层不得叠加', (t) async {
      // 复刻 `lib/ui/home_page.dart:991` 的形态（调用点已包一层）
      await _pumpCard(
        t,
        PressFeedback(
          key: const ValueKey<String>('outer-press'),
          child: PosterCard(title: '怒鲨狂潮', onTap: () {}),
        ),
      );

      final g = await t.startGesture(t.getCenter(find.byType(PosterCard)));
      await t.pump(Duration.zero); // ① 重建：按下动画起步（机制同 A2 的注释）
      await t.pump(const Duration(milliseconds: 300)); // ② 走完

      expect(
        find.descendant(
          of: find.byType(PosterCard),
          matching: find.byType(AnimatedScale),
        ),
        findsNothing,
        reason: '★★ 守卫的**直接**证据（不靠"数 Transform"间接推）：'
            '内层卡片里连 `AnimatedScale` 都不该有 —— '
            '`enabled=false` ⇒ `PressFeedback` 直接 `return widget.child`',
      );

      final ss = _transformsUnder(t, find.byKey(const ValueKey<String>('outer-press')));
      final prod = ss.fold<double>(1.0, (a, b) => a * b);
      _rec('[T50A] C3 双层挂载 按下后 外层子树 Transform 缩放列表 = $ss');
      _rec('[T50A] C3 缩放乘积 = ${prod.toStringAsFixed(6)}'
          '（0.97 = 守卫生效；0.9409 = 两层叠加）');

      expect(ss.length, 1,
          reason: '★★ 内层必须因为**祖先守卫**而关掉 ⇒ 只剩外层那一层。'
              '若这里 = 2，说明叠加了（0.97 × 0.97 = 0.9409）');
      expect(prod, closeTo(0.97, 0.001),
          reason: '★★ 按下后**总**缩放必须正好是 0.97。'
              '实测=${prod.toStringAsFixed(6)}'
              '（若 ≈0.9409 ⇒ 双层叠加，卡片会"按下去更深"）');

      await g.up();
      await t.pump(const Duration(milliseconds: 300));
    });

    testWidgets('C4 ★★★ 点击**没被破坏**（Listener 不消费手势）', (t) async {
      var taps = 0;
      await _pumpCard(t, PosterCard(title: '怒鲨狂潮', onTap: () => taps++));

      await t.tap(find.byType(PosterCard));
      await t.pump(const Duration(milliseconds: 300));

      expect(taps, 1,
          reason: '★★★ 加了按下反馈之后 `onTap` 必须**照常触发且只触发一次**。'
              '`PressFeedback` 用的是 `Listener`（不进手势竞技场）—— '
              '这正是选它而不选 `GestureDetector` 的唯一理由');
    });

    testWidgets('C5 ★ 几何不变：多出来的那一层不改变布局', (t) async {
      // 挂载 1：传 onTap ⇒ 有 Listener + AnimatedScale(1.0)
      await _pumpCard(t, PosterCard(title: '怒鲨狂潮', onTap: () {}));
      final r1 = t.getRect(find.byType(PosterCard));

      // 挂载 2：不传 onTap ⇒ 零额外层
      await _pumpCard(t, const PosterCard(title: '怒鲨狂潮'));
      final r2 = t.getRect(find.byType(PosterCard));

      _rec('[T50A] C5 有按下层 rect = $r1');
      _rec('[T50A] C5 无按下层 rect = $r2');

      for (final pair in <List<Object>>[
        <Object>['left', r1.left, r2.left],
        <Object>['top', r1.top, r2.top],
        <Object>['width', r1.width, r2.width],
        <Object>['height', r1.height, r2.height],
      ]) {
        expect(pair[1] as double, closeTo(pair[2] as double, 1e-6),
            reason: '★ 加一层 `Listener`+`AnimatedScale(identity)` 不得改变 '
                '`PosterCard` 的 ${pair[0]} —— 既有测试'
                '（`t75_search_pinned_test.dart` 读 `.top`、'
                '`task37_poster_placeholder_test.dart` 读尺寸）依赖这个几何');
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('D. Lead 的硬约束（静态，逐条）', () {
    test('D0 ★ 阳性对照：构造参数解析器**看得见**参数', () {
      const fake = 'class X { const PosterCard({ super.key, required this.title, '
          'this.cover, }); }';
      expect(_ctorParams(fake),
          <String>['super.key', 'required this.title', 'this.cover'],
          reason: '★★ 若解析器恒返回空列表，D1 就会变成一条**永远失败**的断言；'
              '若它恒返回任意非空列表，D1 又会变成**恒真**。先证明它真的在解析');
    });

    test('D1 ★ 对外构造参数**逐项未变**（9 项原样 + 1 项可选追加）', () {
      final got = _ctorParams(_src(kPosterSrc));
      _rec('[T50A] D1 构造参数实测 = $got');
      expect(got, kExpectedParams,
          reason: '★★ Lead 硬约束：不许改对外签名/构造参数 —— '
              '5 个调用点都在按这 9 个参数传值');

      // ★★ 加固：原来那 9 项必须是**前缀**（顺序 + 默认值都不许动），
      //   新增项只能出现在**尾部**且必须是**可选带默认**的。
      final legacy = kExpectedParams.sublist(0, 9);
      expect(got.sublist(0, 9), legacy,
          reason: '★★ 2026-10-03 的 `titleLines` 是**追加**，不是改写 —— '
              '前 9 项必须逐字原位');
      expect(got.length, legacy.length + 1,
          reason: '★★ 只允许**多出** `titleLines` 这一项');
      expect(got.last, startsWith('this.titleLines'),
          reason: '★★ 新参数只能加在**尾部**（不许插到中间打乱位置参数顺序）');
    });

    test('D2 ★ task-74 的 `coverImage(` 接线必须存活', () {
      final code = _src(kPosterSrc);

      expect(code.contains('Image.network('), isFalse,
          reason: '★ task-74：`PosterCard` 不能再直接 `Image.network`'
              '（那样 `cacheWidth` 就丢了，海报会按源分辨率解码）');

      final lines = code.split('\n');
      final i = lines.indexWhere((l) => l.trim() == 'coverImage(');
      expect(i >= 0, isTrue,
          reason: '★★ task-74 判据依赖这处接线存活：`coverImage(` 必须独占一行');
      final window =
          lines.sublist(i, (i + 5).clamp(0, lines.length)).join('\n');
      _rec('[T50A] D2 coverImage( 在第 ${i + 1} 行（剥离注释后的行号）');
      expect(window.contains('url: widget.cover!,'), isTrue,
          reason: '★★ `coverImage(` 之后 5 行内必须出现 `url: widget.cover!,`；'
              '实测窗口 = ${window.replaceAll('\n', ' ⏎ ')}');
      expect(window.contains('layoutWidth:'), isTrue,
          reason: '★ 解码宽度必须继续由布局宽度推导（task-74 的机制本身）');
    });

    test('D3 ★ 不 import `package:flutter/material.dart`（仓库硬纪律）', () {
      expect(_src(kPosterSrc).contains('package:flutter/material.dart'), isFalse,
          reason: '★ 生产代码只用 `package:material_ui/material_ui.dart`'
              '（有测试在全仓范围强制这条）');
      expect(_src(kPosterSrc).contains('package:material_ui/material_ui.dart'),
          isTrue,
          reason: '★ 阳性对照：它当然应当 import material_ui');
    });

    test('D4 ★ 只包了**一层** PressFeedback（不重复接线）', () {
      final code = _src(kPosterSrc);
      final n = RegExp(r'PressFeedback\(').allMatches(code).length;
      _rec('[T50A] D4 `PressFeedback(` 在 poster_card.dart 中出现 $n 次');
      expect(n, 1, reason: '★ 恰好一处（`child: PressFeedback(`）');
      expect(code.contains("import 'press_feedback.dart';"), isTrue,
          reason: '★ 且必须 import 了它');
      expect(
        code.contains(
            'enabled: widget.onTap != null && !_hasPressAncestor,'),
        isTrue,
        reason: '★★ 守卫条件必须**逐字**在：`onTap == null` 时不包；'
            '祖先已有 PressFeedback 时不重复包',
      );
    });
  });
}
