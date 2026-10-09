// ═══════════════════════════════════════════════════════════════════════
//  task-41 过渡动画 —— **逐帧几何量**测量（替代"连拍截图"）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要用 widget 测试量，而不是连拍截图
//
// Lead 要"**动态**证据"（连拍 5-8 帧 + 每帧关键几何量）。但真机连拍有个
// 硬问题：
// ```text
// 动画只有 260ms —— 截图（PrintWindow）单次就要 ~100-200ms
// ⇒ 抓到的帧**时间点不可控**，而且很可能整段动画只抓到 1-2 帧
// ⇒ 得出的"位移/不透明度"数字**不可信**（不知道对应动画的哪个时刻）
// ```
// ⇒ ★ 用 widget 测试的 `pump(时长)` **精确控制动画时刻**，
//   再直接读 `SlideTransition` / `FadeTransition` 的**当前值**：
// ```text
// pump(0ms)   → offset = 0.02*dir（起始，最大位移）
// pump(65ms)  → offset ≈ 中间值（曲线 easeOutCubic）
// pump(130ms) → offset 更小
// pump(260ms) → offset = 0（就位）
// ```
// ★ 这比截图**更硬**：它量的是**真实的动画对象**，不是像素的近似。
//
// # 判据（等价于"滑动是否真的发生"）
//
// ```text
// ① 位移**从 0.02*dir 单调减到 0**（证明"滑动"发生，且幅度对）
//    0.02 * 1280 = 25.6px ≈ 原版 24px ✓
// ② 同时不透明度**从 0 单调增到 1**（证明"淡入"发生）
// ③ ★ **反向也要测**：dir = -1（往前切）时位移应是 **-0.02**（从左进）
// ④ 动画结束后**完全就位**（offset=0, opacity=1）—— 不能停在中间
// ```
//
// ⚠️ `find.byType(FadeTransition)` 会命中很多（框架内部也用）——
//    所以要**从我的 `_KeepAliveTransition` 往下找**，或用 `.last`。
//    这里用 `_KeepAliveTransition` 的子树精确定位。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {/* 认领环境噪声（见 keepalive_test.dart） */}
}

/// 读**当前可见页**的动画几何量（位移 dx 像素 + 不透明度）
///
/// # ⚠️ 为什么必须**限定到当前页**（我第一版没限定，读数不可信）
///
/// `find.byType(SlideTransition)` 会命中**框架内部**大量同名 widget
/// （页面切换、滚动指示器、`AnimatedSwitcher` 等都用它）。
/// 我第一版取"位移最大的那个 / 不透明度最小的那个"——
/// 那是个**启发式**，在别的动画同时跑时会取到**别人**的值。
///
/// ⇒ 改成用 `find.ancestor`：**只从当前页往上找**它自己的过渡层。
/// ```text
/// SlideTransition / FadeTransition
///   └ ... └ <当前页>（HomePage / LivePage）
/// ```
/// ★ 这样读到的一定是**这一页的**进入动画。
({double dx, double opacity}) _geometryOf(
  WidgetTester tester,
  Type pageType,
  double width,
) {
  final page = find.byType(pageType, skipOffstage: false);
  if (page.evaluate().isEmpty) return (dx: 0, opacity: 1);

  final slide = find.ancestor(
    of: page,
    matching: find.byType(SlideTransition, skipOffstage: false),
  );
  final fade = find.ancestor(
    of: page,
    matching: find.byType(FadeTransition, skipOffstage: false),
  );

  var dx = 0.0;
  if (slide.evaluate().isNotEmpty) {
    dx = tester.widget<SlideTransition>(slide.first).position.value.dx * width;
  }
  var op = 1.0;
  if (fade.evaluate().isNotEmpty) {
    op = tester.widget<FadeTransition>(fade.first).opacity.value;
  }
  return (dx: dx, opacity: op);
}

void main() {
  group('task-41 ★ 过渡动画：逐帧几何量（证明"滑动 + 淡入"仍在）', () {
    testWidgets('★★ 往后切（dir=+1）：位移从 +25.6px 递减到 0，不透明度 0→1', (tester) async {
      const w = 1280.0;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      // 从 home(0) → live(1)：序号变大 ⇒ dir = +1（从右进）
      shell.debugSwitchTo(AppTab.live);
      await tester.pump(); // 让 setState 生效，动画从 0 开始

      // ★ 逐帧采样（★ 这就是 Lead 要的"每帧关键几何量"）
      final samples = <({int ms, double dx, double opacity})>[];
      const steps = [0, 40, 80, 120, 180, 260];
      var prev = 0;
      for (final ms in steps) {
        if (ms > prev) {
          await tester.pump(Duration(milliseconds: ms - prev));
          prev = ms;
        }
        final g = _geometryOf(tester, LivePage, w);
        samples.add((ms: ms, dx: g.dx, opacity: g.opacity));
      }
      _claim(tester);

      // ── 打印（人可读的证据）──
      // ignore: avoid_print
      print('T41ANIM|dir=+1 (home→live, 从右进)');
      for (final s in samples) {
        // ignore: avoid_print
        print('T41ANIM|  t=${s.ms.toString().padLeft(3)}ms  '
            'dx=${s.dx.toStringAsFixed(2).padLeft(7)}px  '
            'opacity=${s.opacity.toStringAsFixed(3)}');
      }

      // ── 判据 ──
      // ① 起始位移 ≈ +25.6px（0.02 * 1280），且方向为**正**（从右进）
      expect(samples.first.dx, greaterThan(20.0),
          reason: '★ 起始应有明显位移（≈25.6px）。若不位移 ⇒ 滑动动画丢了');
      expect(samples.first.dx, lessThan(32.0),
          reason: '起始位移不该过大（原版 24px，我们按 0.02*1280=25.6px 对齐）');
      expect(samples.first.opacity, lessThan(0.35),
          reason: '★ 起始应几乎透明（淡入的起点）');

      // ② 单调递减（滑动是"进入"，位移只能越来越小）
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].dx, lessThanOrEqualTo(samples[i - 1].dx + 0.01),
            reason: '★ 位移必须**单调递减**（不能来回晃）；第 $i 帧异常:\n'
                '  前一帧 ${samples[i - 1].dx}px → 本帧 ${samples[i].dx}px');
      }

      // ③ 不透明度单调递增
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].opacity, greaterThanOrEqualTo(samples[i - 1].opacity - 0.005),
            reason: '★ 不透明度必须**单调递增**；第 $i 帧异常');
      }

      // ④ 结尾**完全就位**（offset=0, opacity=1）—— 不能停在中间
      expect(samples.last.dx.abs(), lessThan(0.5),
          reason: '★ 动画结束后位移必须归零（否则页面会偏着）');
      expect(samples.last.opacity, greaterThan(0.99),
          reason: '★ 动画结束后必须完全不透明');
    });

    testWidgets('★★ 往前切（dir=-1）：位移从 **-25.6px** 递增到 0（从左进）', (tester) async {
      const w = 1280.0;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      /*
       * ★ 要测"往前切"，得先到 live，再回 home（序号变小 ⇒ dir = -1）
       * ⚠️ 第一跳 home→live 是 dir=+1，要等它**走完**再测第二跳，
       *    否则会量到上一段动画的残留。
       */
      shell.debugSwitchTo(AppTab.live);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 等第一跳走完
      _claim(tester);

      // live(1) → home(0)：序号变小 ⇒ dir = -1（从左进）
      shell.debugSwitchTo(AppTab.home);
      await tester.pump();

      final samples = <({int ms, double dx, double opacity})>[];
      const steps = [0, 40, 120, 260];
      var prev = 0;
      for (final ms in steps) {
        if (ms > prev) {
          await tester.pump(Duration(milliseconds: ms - prev));
          prev = ms;
        }
        final g = _geometryOf(tester, HomePage, w);
        samples.add((ms: ms, dx: g.dx, opacity: g.opacity));
      }
      _claim(tester);

      // ignore: avoid_print
      print('T41ANIM|dir=-1 (live→home, 从左进)');
      for (final s in samples) {
        // ignore: avoid_print
        print('T41ANIM|  t=${s.ms.toString().padLeft(3)}ms  '
            'dx=${s.dx.toStringAsFixed(2).padLeft(7)}px  '
            'opacity=${s.opacity.toStringAsFixed(3)}');
      }

      // ★ 起始位移应为**负**（从左进）—— 这是"方向感"的核心
      expect(samples.first.dx, lessThan(-20.0),
          reason: '★★ 往前切时起始位移必须是**负的**（从左进）。\n'
              '  若为正 ⇒ 方向算错了（`_transitionDir` 失效）⇒ 用户会看到"回退也往右滑"');
      expect(samples.first.opacity, lessThan(0.35), reason: '起始应几乎透明');

      // 单调递增到 0（从负值"升"上来）
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].dx, greaterThanOrEqualTo(samples[i - 1].dx - 0.01),
            reason: '★ 应从 -25.6px **递增**到 0（单调）');
      }
      expect(samples.last.dx.abs(), lessThan(0.5), reason: '结束时应就位');
      expect(samples.last.opacity, greaterThan(0.99), reason: '结束时完全不透明');
    });

    testWidgets('★ 首帧**不播**动画（启动不该闪一下）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      // ★ 再 pump 一帧：首帧后的 postFrameCallback（如 loadAll）会在这里跑
      await tester.pump(const Duration(milliseconds: 50));
      _claim(tester);

      /*
       * ★ 为什么首帧不该有动画
       *
       * `_KeepAliveTransition` 的 controller 初值设为 1（已就位）——
       * 若设成 0，启动瞬间首页会"从右边滑进来 + 淡入"，
       * 而用户**并没有切 tab** ⇒ 那是**凭空的动画**（观感很怪）。
       * 只有 `active` 从 false→true 才 `forward(from: 0)`。
       */
      final g = _geometryOf(tester, HomePage, 1280.0);
      expect(g.dx.abs(), lessThan(0.5),
          reason: '★ 启动首帧不该有位移（否则会无端"滑入"）');
      expect(g.opacity, greaterThan(0.99),
          reason: '★ 启动首帧不该淡入（应该是直接可见的）');
    });

    // ═══════════════════════════════════════════════════════════════════
    // ★★★ M6 判据：动画必须**经历中间过程**（不是"瞬间就位"）
    // ═══════════════════════════════════════════════════════════════════
    //
    // # 为什么补这一条（来自**独立验证**的变异测试，2026-09-25）
    //
    // 独立验证者（`fix-autoscroll`）做了变异测试：把动画时长从
    // `260ms` 改成 `1ms`（等于"过渡动画丢了"）——
    // ★ **本文件原有 3 条判据全部通过**，5 个测试文件全绿。
    //
    // 实测读数（`.probe/v41_m6m7_equivalent.txt`）：
    // ```text
    // 基线:   t=  0ms dx= 25.60 opacity=0.000
    //         t= 40ms dx= 15.16 opacity=0.408   ← ★ 中间态
    //         t= 80ms dx=  7.97 opacity=0.689
    //         t=260ms dx=  0.00 opacity=1.000
    // M6(1ms):t=  0ms dx= 25.60 opacity=0.000
    //         t= 40ms dx=  0.00 opacity=1.000   ← ★ 已经"瞬间就位"
    // ```
    // ⇒ 原有判据为什么抓不住：
    // ```text
    // · `first.dx > 20`     —— 首帧仍是 25.6 ✓（动画起点没变）
    // · 单调性              —— 25.6 → 0 仍单调 ✓
    // · `last.dx ≈ 0`       —— 仍是 0 ✓
    // ⇒ ★ 它们只约束**两个端点**，不约束"中间是否真的在动"
    // ```
    //
    // # ★★ 判据设计：**严格介于两端之间**
    //
    // ```text
    // 动画"经历了中间过程"的**定义**就是：
    //   存在某一帧，其值**严格位于**首帧与末帧之间。
    // ⇒ 用 `t=40ms` 那一帧：
    //     dx  : first.dx(25.60) > t40.dx > last.dx(0)
    //     不透明度: first.op(0) < t40.op < last.op(1)
    // ```
    // ⚠️ **我一度想用 lead 建议的"t=40ms 时 dx < first.dx"** ——
    //    但那**抓不住 M6**：`0.00 < 25.60` 同样成立（实测验证过）。
    //    ⇒ 必须加**下界**（"还在动"），不能只有上界（"比首帧小"）。
    //    ★ 这正是铁律 78 的形态："匹配/成立"必须能区分"合规"与"没测到"。
    testWidgets('★★★ 动画**经历中间过程**（不是瞬间就位）—— 变异测试补的判据',
        (tester) async {
      const w = 1280.0;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;
      shell.debugSwitchTo(AppTab.live);
      await tester.pump(); // 动画从 0 开始

      // ★ 只采 3 个点：首帧 / 中间帧 / 末帧
      final samples = <({int ms, double dx, double opacity})>[];
      const steps = [0, 40, 260];
      var prev = 0;
      for (final ms in steps) {
        if (ms > prev) {
          await tester.pump(Duration(milliseconds: ms - prev));
          prev = ms;
        }
        final g = _geometryOf(tester, LivePage, w);
        samples.add((ms: ms, dx: g.dx, opacity: g.opacity));
      }
      _claim(tester);

      final first = samples.first;
      final mid = samples[1];
      final last = samples.last;

      // ignore: avoid_print
      print('T41ANIM-M6|first t=${first.ms}ms dx=${first.dx.toStringAsFixed(2)} '
          'op=${first.opacity.toStringAsFixed(3)}');
      // ignore: avoid_print
      print('T41ANIM-M6|mid   t=${mid.ms}ms dx=${mid.dx.toStringAsFixed(2)} '
          'op=${mid.opacity.toStringAsFixed(3)}');
      // ignore: avoid_print
      print('T41ANIM-M6|last  t=${last.ms}ms dx=${last.dx.toStringAsFixed(2)} '
          'op=${last.opacity.toStringAsFixed(3)}');

      // ── 前置：两端必须成立（否则"中间"无从谈起）──
      expect(first.dx, greaterThan(20.0),
          reason: '前置：首帧应有明显位移（否则动画根本没开始）');
      expect(last.dx.abs(), lessThan(0.5),
          reason: '前置：末帧应就位');
      expect(first.opacity, lessThan(0.35),
          reason: '前置：首帧应几乎透明');

      // ── ★★★ 核心判据 ①：位移**严格介于**两端之间（= 真的在动）──
      expect(mid.dx, lessThan(first.dx),
          reason: '★ 中间帧位移应小于首帧（动画在推进）');
      expect(mid.dx, greaterThan(last.dx + 0.5),
          reason: '★★★ 中间帧位移必须**大于末帧**（= 还在滑动）。\n'
              '  若 `mid.dx ≈ last.dx` ⇒ 动画**瞬间就位**（时长被改小/丢失）。\n'
              '  ★ 实测：时长 1ms 时 mid.dx=0.00 == last.dx ⇒ 这条会**红**。\n'
              '  实测读数：first=${first.dx} mid=${mid.dx} last=${last.dx}');

      // ── ★★★ 核心判据 ②：不透明度也**严格介于**两端之间 ──
      expect(mid.opacity, greaterThan(first.opacity),
          reason: '★ 中间帧应比首帧更不透明（淡入在推进）');
      expect(mid.opacity, lessThan(0.99),
          reason: '★★★ 中间帧**不该已经完全就位**。\n'
              '  若 `mid.opacity ≈ 1` ⇒ 动画瞬间完成。\n'
              '  ★ 实测：时长 1ms 时 mid.opacity=1.000 ⇒ 这条会**红**。\n'
              '  实测读数：first=${first.opacity} mid=${mid.opacity} '
              'last=${last.opacity}');
    });
  });
}
