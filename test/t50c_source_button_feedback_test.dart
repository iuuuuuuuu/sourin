/*
 * task-50 · 候选 3（`_SourceButton` 选中态补间）的 widget 测试
 *
 * # 这个测试要证的东西
 * 详情页「换源」这条按钮的选中反馈从**硬切**变成了 **150ms 补间**。
 * 光断言"有个 AnimatedContainer"等于没测 —— 必须证明**补间真的在跑**，
 * 而且**状态切换没有被动画拖慢**。
 *
 * # 三件仪器
 * A. 声明值：直接读 `AnimatedContainer` 这个 widget 上的 `duration` / `curve`。
 *    ⇒ 判据④（尊重 Reduce Motion）在这里是**精确**读数：
 *       `Motion.fast`(150ms)+`Motion.easeOut` ↔ `Duration.zero`+`Curves.linear`。
 * B. ★ 实际补间值：读按钮底色 `BoxDecoration.color.a`。
 *    ```text
 *    未选中 ⇒ color 是 **null**；选中 ⇒ 品牌色 18% alpha。
 *    `Color.lerp(null, y, t)`（sky_engine `painting.dart:434-435`）
 *      ⇒ `_scaleAlpha(y, t)` ⇒ `y.withValues(alpha: y.a * t)`
 *      ⇒ 补间中的 alpha **正好落在 (0, 0.18) 区间内**，可读、可数。
 *    ```
 *    ⇒ 这是"动画真的在跑"的证据（硬切的话第一帧就已经是 0.18）。
 * C. 状态即时性：同一帧上 `fontWeight` 已经变成 w600、`onPick` 已经回调，
 *    而 alpha 还在 0.0 ⇒ **状态立即生效，只有"样子"在补间**（判据②）。
 *
 * # 为什么读 alpha 而不是读 `AnimatedContainer.duration` 就够
 * ```text
 * duration 只说明"声明了要补间"；如果 widget 被重建（key 变了 / 换了 State），
 * 补间会被重置成硬切，而 duration 照样是 150ms ⇒ 声明值读不出这个 bug。
 * ```
 *
 * # 为什么必须用生产同一套主题（照抄 `task32_source_highlight_test.dart:49-77`）
 * ```text
 * 用 `theme.toApproximateMaterialTheme()` 会跳过 buildLightMaterialTheme，
 * `colors.primary` 变成 forui 的中性兜底色 ⇒ 测的不是用户看到的画面。
 * ```
 *
 * # 打断（判据③）
 * 隐式动画**天然可打断**：第二次点会以"当前中间值"为新起点重新补间
 * （`implicit_animations.dart:400-404`：
 *   `tween..begin = tween.evaluate(_animation)..end = targetValue` 然后
 *   `controller.forward(from: 0.0)`）
 * ⇒ ① 反手点的那一刻 alpha 必须**连续**（等于打断前的读数，不回跳）
 *    ② 从反手那一刻到落定必须还是 **150ms**（不是"先播完上一次再回来"）
 *
 * # ★ 教训：阈值不许凭感觉编（这是本任务第二次犯）
 * ```text
 * 第一版里我写了 `expect(traj.minGap, greaterThan(1e-3))`，1e-3 是"觉得差不多"编出来的。
 * 后来用 `.probe/t50c_pred_c3.py` 把整条轨迹按 SDK 数学**解析算出来**，发现：
 *   最大相邻差 = 0.0505012133（第 0→1 帧）
 *   最小正差   = 0.0000081929（第 14→15 帧）   ← 比 1e-3 小 122 倍 ⇒ 那条断言必挂
 * 为什么最小差这么小：`Motion.easeOut` 尾部极平，第 14 帧已经到 0.1799918071。
 * ⇒ 结论：拿"最小差"当阈值卡是错的（它由曲线形状决定，不是仪器能力）；
 *   要卡分辨率就用**最大差**（起始斜率 ≈ 4.5，远大于噪声）。
 * ```
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';

/// 被测文件（红度证明按这个路径改 / 还原）
const String kBtnSrc = 'lib/ui/widgets/detail_raw_meta.dart';

const String kLabelA = 'CYCHUB 线路';
const String kLabelB = 'CDN 直连';

/// 选中态的 alpha（生产里是 `colors.primary.withValues(alpha: 0.18)`）
const double kActiveAlpha = 0.18;

/// 采样：10ms 一步，20 步 = 200ms > `Motion.fast`(150ms)
const int kStepMs = 10;
const int kSteps = 20;

/// `Motion.fast` = 150ms ⇒ 第 15 步落定
const int kSettleIndex = 15;

/// ★ 第 1 步（t=10/150）的**解析**读数，由 `.probe/t50c_pred_c3.py` 算出：
/// `alpha[1] = 0.18 × easeOut(10/150) = 0.18 × 0.2805622964 = 0.0505012133`
///
/// 这条常数存在的意义：它是**算出来的**，不是"看着差不多"定的。
const double kC3Step1 = 0.0505012133;

/// 读数落盘 —— 目录不存在就**先建**。
///
/// ★ 为什么需要这一层（2026-10-08 加）：
///   `.probe/` 是**开发期的本地目录**，它**不在仓库里**（见 .gitignore）。
///   在干净的检出（CI、别人的机器）上它根本不存在 ⇒ 直接
///   `writeAsStringSync` 会抛 `PathNotFoundException`，
///   **把一条本该通过的动画断言变成失败**（而且报错位置在落盘那一行，
///   看起来像断言挂了，实际是**仪器故障**）。
///   ★ 这与本仓的一条铁律同源：先问「是我的仪器错了吗」。
File _ensureLog(String path) {
  final f = File(path);
  final d = f.parent;
  if (!d.existsSync()) d.createSync(recursive: true);
  return f;
}

final File _log = _ensureLog('.probe/t50c_source_points.txt');

void _rec(String line) {
  // ignore: avoid_print
  print(line);
  _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

List<PlaySource> _two() => const <PlaySource>[
      PlaySource(code: 'cychub', title: kLabelA, count: 24),
      PlaySource(code: 'cdn', title: kLabelB, count: 4),
    ];

/// 生产同一套主题（`shell.dart:726-729`）
Widget _host(Widget child, {required Brightness brightness, bool reduceMotion = false}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light
        ? buildLightMaterialTheme(theme)
        : buildMaterialTheme(theme),
    // ★ builder 在 Navigator 之上 ⇒ 下游（含 home）都看得到这个 MediaQuery
    builder: (BuildContext ctx, Widget? c) => FTheme(
      data: theme,
      child: MediaQuery(
        data: (MediaQuery.maybeOf(ctx) ?? const MediaQueryData())
            .copyWith(disableAnimations: reduceMotion),
        child: c ?? const SizedBox(),
      ),
    ),
    home: Scaffold(
      backgroundColor: theme.colors.background,
      body: Center(child: child),
    ),
  );
}

/// 会**真的换源**的宿主（模拟用户点一下）
class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.initial});

  final String initial;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String active = widget.initial;
  int picks = 0;

  @override
  Widget build(BuildContext context) {
    return DetailSourcePicker(
      sources: _two(),
      active: active,
      onPick: (PlaySource s) {
        picks++;
        active = s.code;
        setState(() {});
      },
    );
  }
}

/// 取某个按钮的 `BoxDecoration`
///
/// `AnimatedContainer` 的 build 就是 `Container(...)`（`implicit_animations.dart:824-838`）
/// ⇒ `find.byType(Container)` 照样命中，且**最近的** Container 祖先就是它。
BoxDecoration? _decoOf(WidgetTester t, String label) {
  final finder = find.ancestor(
    of: find.text(label),
    matching: find.byType(Container),
  );
  for (final e in finder.evaluate()) {
    final w = e.widget;
    if (w is Container && w.decoration is BoxDecoration) {
      return w.decoration! as BoxDecoration;
    }
  }
  return null;
}

/// 底色 alpha（未选中 ⇒ color 为 null ⇒ 记 0.0）
double _alphaOf(WidgetTester t, String label) =>
    _decoOf(t, label)?.color?.a ?? 0.0;

/// 字重（选中 w600 / 未选中 w400）
double _weightOf(WidgetTester t, String label) =>
    t.widget<Text>(find.text(label)).style!.fontWeight!.value.toDouble();

/// 声明值仪器：按钮里那个 `AnimatedContainer`
AnimatedContainer _animOf(WidgetTester t, String label) =>
    t.widget<AnimatedContainer>(find.ancestor(
      of: find.text(label),
      matching: find.byType(AnimatedContainer),
    ));

/// 采样一条轨迹（点一下 → 每 10ms 记一次 alpha / 字重）
class _Traj {
  _Traj(this.alphas, this.weights, this.rects);

  /// index i = 点完第 i 帧的读数（index 0 = 点完那一帧，时钟没走）
  final List<double> alphas;
  final List<double> weights;
  final List<Rect> rects;

  /// 第一次达到 `kActiveAlpha` 的步号（10ms/步）；没到就是 -1
  int get settleIndex {
    for (int i = 0; i < alphas.length; i++) {
      if (alphas[i] == kActiveAlpha) return i;
    }
    return -1;
  }

  int get distinct => alphas.toSet().length;

  /// 相邻读数的**最小正差**（仪器分辨率）
  double get minGap {
    double g = double.infinity;
    for (int i = 1; i < alphas.length; i++) {
      final d = (alphas[i] - alphas[i - 1]).abs();
      if (d > 0 && d < g) g = d;
    }
    return g;
  }

  String get nums =>
      alphas.map((double a) => a.toStringAsFixed(6)).join(' ');
}

/// 点 `label` 那条线路，然后每 `kStepMs` 采一次
Future<_Traj> _tapAndSample(WidgetTester t, String label) async {
  final alphas = <double>[];
  final weights = <double>[];
  final rects = <Rect>[];

  await t.tap(find.text(label));
  await t.pump(); // ★ 点完那一帧：时钟没走（fake clock 不 pump 就不前进）
  alphas.add(_alphaOf(t, label));
  weights.add(_weightOf(t, label));
  rects.add(t.getRect(find.text(label)));

  for (int i = 0; i < kSteps; i++) {
    await t.pump(const Duration(milliseconds: kStepMs));
    alphas.add(_alphaOf(t, label));
    weights.add(_weightOf(t, label));
    rects.add(t.getRect(find.text(label)));
  }
  return _Traj(alphas, weights, rects);
}

void _mount(WidgetTester t) {
  t.view.physicalSize = const Size(700, 300);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  group('task-50 C3：换源按钮的选中反馈是"真补间"', () {
    for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('★★ [$tag] 选中补间真的在跑：alpha 从 0 连续爬到 0.18（150ms）',
          (WidgetTester t) async {
        _mount(t);
        final key = GlobalKey<_HarnessState>();
        await t.pumpWidget(_host(
          _Harness(key: key, initial: 'cychub'),
          brightness: brightness,
        ));
        await t.pump();

        // ── 仪器 A：声明值 ──
        final anim = _animOf(t, kLabelB);
        expect(anim.duration, Motion.fast,
            reason: '换源是高频动作 ⇒ 必须走最低档 150ms');
        expect(anim.curve, Motion.easeOut);

        // 静止态：A 选中 0.18，B 未选中 0.0
        expect(_alphaOf(t, kLabelA), kActiveAlpha);
        expect(_alphaOf(t, kLabelB), 0.0);
        expect(_weightOf(t, kLabelA), 600.0);
        expect(_weightOf(t, kLabelB), 400.0);

        // ── 点 B，采轨迹 ──
        final traj = await _tapAndSample(t, kLabelB);
        _rec('T50C3|$tag|dur=${anim.duration.inMilliseconds}ms'
            '|settle=${traj.settleIndex * kStepMs}ms'
            '|distinct=${traj.distinct}|minGap=${traj.minGap.toStringAsExponential(3)}');
        _rec('T50C3|$tag|alpha=${traj.nums}');

        // ① ★ 第一帧：状态已经换了（字重 + 回调），但**颜色还没到**
        expect(key.currentState!.active, 'cdn', reason: '换源必须立即生效');
        expect(key.currentState!.picks, 1);
        expect(traj.weights[0], 600.0,
            reason: '★ 字重是状态，必须**同帧**变（动画不能拖慢操作）');
        expect(traj.alphas[0], 0.0,
            reason: '★ 同一帧上颜色还在起点 ⇒ 补间真的在跑（硬切的话这里已经是 0.18）');

        // ② 中间帧严格落在 (0, 0.18) 开区间内 —— 硬切不可能出现这种读数
        final int interior = traj.alphas
            .where((double a) => a > 0.0 && a < kActiveAlpha)
            .length;
        expect(interior, greaterThanOrEqualTo(10),
            reason: '★ 必须有足够多的"中间值"帧，实际 $interior 帧：${traj.nums}');
        expect(traj.distinct, greaterThanOrEqualTo(12),
            reason: '读数种类太少说明是几帧硬跳，不是补间：${traj.nums}');

        // ③ 单调不降，且正好在 150ms 落定
        for (int i = 1; i < traj.alphas.length; i++) {
          expect(traj.alphas[i], greaterThanOrEqualTo(traj.alphas[i - 1]),
              reason: '第 $i 帧回退了：${traj.nums}');
        }
        expect(traj.settleIndex, kSettleIndex,
            reason: '★ 应在 Motion.fast=150ms 落定（第 $kSettleIndex 步），'
                '实际第 ${traj.settleIndex} 步');
        for (int i = kSettleIndex; i < traj.alphas.length; i++) {
          expect(traj.alphas[i], kActiveAlpha, reason: '落定后不该再变');
        }

        // ④ ★ 曲线形状：第 1 步（t=10/150）必须落在 easeOut 的**解析值**附近
        //
        // 解析值 `0.18 × easeOut(1/15) = 0.0505012133`（`.probe/t50c_pred_c3.py` 算出）。
        // 容差 0.005 的来历：SDK 的 `Cubic.transformInternal` 用二分，判停条件是
        // `|x(mid) - t| < _cubicErrorBound`（`curves.dart:396`，= 0.001）
        // ⇒ y 的误差 ≈ (dy/dx) × 0.001；t=1/15 处 dy/dx ≈ 4.2
        // ⇒ alpha 误差 ≈ 0.18 × 4.2 × 0.001 ≈ 0.0008 ⇒ 取 0.005（约 6 倍余量）。
        // 分辨力：若曲线是**线性**的，这里会是 0.18 × 1/15 = 0.012 ⇒ 远在带外。
        expect(traj.alphas[1], closeTo(kC3Step1, 0.005),
            reason: '★ 第 1 步读数应贴近 easeOut 解析值 $kC3Step1'
                '（线性曲线会给 0.012）实际 ${traj.alphas[1]}');

        // ⑤ 读数确实在变，且远超 double 噪声
        //
        // ★ 这里**不能**卡"最小正差"：解析最小正差 = 8.1929e-06（第 14→15 帧，
        //   因为 easeOut 尾部极平），我第一版凭感觉写的 `1e-3` 比它大 122 倍 ⇒ 必挂。
        //   要卡分辨率就用**起始斜率**（上面那条），不要用最小差。
        expect(traj.minGap, greaterThan(1e-9),
            reason: '★ 最小正差 ${traj.minGap}（解析值 8.19e-06）不该小到 double 噪声量级');

        // ⑥ 判据②：补间**不动布局**（边框宽度两态都是 1.0）
        expect(traj.rects.toSet().length, 1,
            reason: '★ 补间期间按钮几何不该有任何变化：${traj.rects.toSet()}');
      });

      testWidgets('★★ [$tag] 打断（判据③）：反手点回，alpha 连续且仍是 150ms 落定',
          (WidgetTester t) async {
        _mount(t);
        final key = GlobalKey<_HarnessState>();
        await t.pumpWidget(_host(
          _Harness(key: key, initial: 'cychub'),
          brightness: brightness,
        ));
        await t.pump();

        // 点 B，走 40ms（还没落定）
        await t.tap(find.text(kLabelB));
        await t.pump();
        await t.pump(const Duration(milliseconds: 40));
        final double mid = _alphaOf(t, kLabelB);
        expect(mid, greaterThan(0.0));
        expect(mid, lessThan(kActiveAlpha),
            reason: '40ms 时应该还在半路，实际 $mid');

        // ★ 反手点回 A
        await t.tap(find.text(kLabelA));
        await t.pump(); // 打断那一帧：时钟没走
        final double atCut = _alphaOf(t, kLabelB);
        _rec('T50C3|$tag|cut|mid=${mid.toStringAsFixed(6)}'
            '|atCut=${atCut.toStringAsFixed(6)}|jump=${(atCut - mid).abs()}');

        expect(atCut, mid,
            reason: '★★ 打断必须**连续**：以当前中间值 $mid 为新起点，'
                '不能回跳到 0（回跳 = 先播完/重置，不是真打断）');
        expect(key.currentState!.active, 'cychub', reason: '反手点也要立即生效');

        // 从打断那一刻起，每 10ms 采一次，看多久落定
        int settle = -1;
        final alphas = <double>[atCut];
        for (int i = 0; i < kSteps; i++) {
          await t.pump(const Duration(milliseconds: kStepMs));
          alphas.add(_alphaOf(t, kLabelB));
          if (alphas.last == 0.0) {
            settle = (i + 1) * kStepMs;
            break;
          }
        }
        _rec('T50C3|$tag|cut|settle=${settle}ms'
            '|alpha=${alphas.map((double a) => a.toStringAsFixed(6)).join(' ')}');

        expect(settle, 150,
            reason: '★★ 打断后仍是完整的一档 150ms（不是"先播完上一次再回来"'
                '= 40+150=190ms 或排队更久）');
      });

      testWidgets('★★★ [$tag] 对照：disableAnimations=true ⇒ 读数塌成"一步到位"',
          (WidgetTester t) async {
        /*
         * ★ Lead 要的对照实验。
         *
         * 开动画时：第一帧 alpha=0.0，中间有十几个中间值（上面的测试已证）。
         * 关动画（`disableAnimations=true` ⇒ `MotionPrefs.duration` 返回
         * `Duration.zero`）时：`controller.forward(from: 0)` 会**同步**走完
         * （`animation_controller.dart:672-681`：`simulationDuration == Duration.zero`
         *  ⇒ 直接写值 + 标 completed + 返回 `TickerFuture.complete()`）
         * ⇒ 第一帧就该是 0.18，**中间值一个都不剩**。
         */
        _mount(t);
        final key = GlobalKey<_HarnessState>();
        await t.pumpWidget(_host(
          _Harness(key: key, initial: 'cychub'),
          brightness: brightness,
          reduceMotion: true,
        ));
        await t.pump();

        // ── 仪器 A：声明值也必须归零 ──
        final anim = _animOf(t, kLabelB);
        expect(anim.duration, Duration.zero,
            reason: '★ Reduce Motion 下不能还有 150ms 的补间');
        expect(anim.curve, Curves.linear);

        final traj = await _tapAndSample(t, kLabelB);
        _rec('T50C3|$tag|reduce|dur=${anim.duration.inMilliseconds}ms'
            '|distinct=${traj.distinct}|alpha=${traj.nums}');

        // ★ 状态照样立即生效（判据④：只是没有过渡，不是没有反馈）
        expect(key.currentState!.active, 'cdn');
        expect(traj.weights[0], 600.0);

        // ★★ 关键对照：开动画时的"中间值"读数**全部消失**
        expect(traj.distinct, 1,
            reason: '★★ 关动画后读数必须只剩一种，实际 ${traj.distinct} 种：${traj.nums}');
        expect(traj.alphas.toSet(), <double>{kActiveAlpha},
            reason: '★★ 关动画后第一帧就该是终值 0.18：${traj.nums}');
        expect(traj.settleIndex, 0,
            reason: '★★ 关动画后第 0 帧就落定（开动画时是第 $kSettleIndex 帧）');
      });
    }
  });
}
