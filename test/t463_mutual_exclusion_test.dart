// ══════════════════════════════════════════════════════════════════════
//  t463 —— ★★★ 四条互斥（Owner：箭头不许互相穿过）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 「还有这四个是互斥关系,片尾的两个箭头不能跑到片头的两个前面去
//   然后 片头的两个,片头的结束不能跑到片头的开始前面去
//   片尾的也是同理」
// ```
//
// ⇒ 四条约束：
// ```text
// ① introStart <  introEnd
// ② introEnd   <  outroStart      ← "片尾两个不能跑到片头两个前面"
// ③ outroStart <  outroEnd
// ④ 全部落在 [0, total]
// ```
//
// # 为什么需要这条测试
//
// `_boundFor` / `_clampTo` **早就存在且写对了**（`_applyEdge` 用）。
// 但**拖拽那条链路根本没调它们** —— 直接 `_introStart = value`。
// ⇒ 用户拖箭头可以**穿过**别的箭头 ⇒ 四条互斥全失效。
//
// ★ 这是本文件第三次同类问题（前两次：预览跟随、幽灵箭头可拖）：
//   **同一个语义两条链路、只实现了一处**。
//
// # 判据
//
// 真渲染**真实弹窗**，然后用**真实指针事件**把每个箭头**往越界方向拖**，
// 断言四条约束**始终成立**。
//
// ★ 关键：不是"断言它没变"，而是"断言结果**合法**" ——
//   夹取会把它停在边界上（值会变，但合法）。
//   若判"没变"，那"夹对了"和"根本没响应"就分不清了。

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

Widget _host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 认领一次 pump 期间积压的环境异常（无核心库的 FFI 异常等）
///
/// ⚠️ 不认领会报 `Multiple exceptions (9) were detected` ——
///    ★ 那不是被测对象的失败，是本环境**加载不了 `sourin_core.dll`**
///      导致的副作用（弹窗读跳过点 / 起预览都会抛）。
///    本仓既有测试（`bottom_bar_fit_test.dart` 等）都用同一个手法。
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_host(
    const SkipMarkerDialog(
      provider: 'demo',
      id: 't463',
      title: 't463 四条互斥',
      streamUrl: '',
      duration: Duration(minutes: 47, seconds: 6), // 2826 秒
    ),
  ));
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    _claim(tester);
  }
}

/// 把某个端点拖到时间轴的**某个比例位置**
Future<void> _dragEdgeTo(
  WidgetTester tester,
  SkipEdge edge,
  double fraction,
) async {
  final tlFinder = find.byType(SkipTimeline);
  final rect = tester.getRect(tlFinder);
  final tl = tester.widget<SkipTimeline>(tlFinder);

  // 起点：该端点的**当前**位置（已设置用实心，未设置用幽灵）
  final tips = computeSkipTips(
    width: rect.width,
    total: tl.total,
    introStart: tl.introStart,
    introEnd: tl.introEnd,
    outroStart: tl.outroStart,
    outroEnd: tl.outroEnd,
  );
  final tip = tips[edge] ??
      ghostTipFor(
        edge: edge, width: rect.width,
        inset: kArrowInset, arrowW: kArrowW,
      );
  final body = skipEdgeBodyCenter(edge, tip)!;

  final from = Offset(rect.left + body, rect.center.dy);
  final to = Offset(rect.left + rect.width * fraction, rect.center.dy);

  final binding = GestureBinding.instance;
  final pointer = 9700 + edge.index;
  binding.handlePointerEvent(PointerDownEvent(
    pointer: pointer, position: from, kind: PointerDeviceKind.mouse,
  ));
  await tester.pump(const Duration(milliseconds: 40));
  for (var i = 1; i <= 14; i++) {
    binding.handlePointerEvent(PointerMoveEvent(
      pointer: pointer,
      position: Offset.lerp(from, to, i / 14)!,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 40));
  }
  binding.handlePointerEvent(PointerUpEvent(
    pointer: pointer, position: to, kind: PointerDeviceKind.mouse,
  ));
  await tester.pump(const Duration(milliseconds: 400));
  _claim(tester);
}

void main() {
  group('t463 四条互斥：箭头不许互相穿过', () {
    testWidgets('★★★ 四个箭头各自往越界方向拖 ⇒ 约束必须始终成立',
        (WidgetTester tester) async {
      await _pumpDialog(tester);

      final tlFinder = find.byType(SkipTimeline);
      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      final total = tl().total.toInt();
      // ignore: avoid_print
      print('T463|total = $total 秒');

      // ── 先给四个点设成一组合法值 ──
      /*
       * ★ 我第一版写的是 `plus.at(i % 4)` —— **只设出了 introStart 一个点**。
       *   原因：`+` 按钮的数量不一定是 4（有些行可能显示别的图标），
       *   而 `i % 4` 会在按钮少于 4 个时反复点同一个。
       * ⇒ 改成：**先把「+」的总数打出来**，再按"每个按钮点几次"设值。
       *   ★ 这很重要：四个点都有值，四条约束才**真的被检验到**
       *     （只有 introStart 有值时，② ③ 两条根本无从违反）。
       */
      final plus = find.byIcon(Icons.add);
      final nPlus = plus.evaluate().length;
      // ignore: avoid_print
      print('T463|「+」按钮数 = $nPlus');
      for (var round = 0; round < 4; round++) {
        for (var k = 0; k < nPlus; k++) {
          await tester.tap(plus.at(k), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 80));
          _claim(tester);
        }
      }
      // ignore: avoid_print
      print('T463|设完初值: introStart=${tl().introStart} introEnd=${tl().introEnd} '
          'outroStart=${tl().outroStart} outroEnd=${tl().outroEnd}');

      /*
       * ★ 前提断言：四个点**必须都有值** ——
       *   否则四条约束里有几条无从检验（那会让本测试**假绿**）。
       */
      final w0 = tl();
      expect(
        [w0.introStart, w0.introEnd, w0.outroStart, w0.outroEnd],
        everyElement(isNotNull),
        reason: '★★★ 前提不成立：四个点没有全部设上值 '
            '(${w0.introStart}, ${w0.introEnd}, ${w0.outroStart}, ${w0.outroEnd}) '
            '—— 那样四条互斥里有几条根本不会被检验到，测试会**假绿**',
      );

      /// 断言四条约束
      void assertInvariants(String where) {
        final w = tl();
        final a = w.introStart, b = w.introEnd;
        final c = w.outroStart, d = w.outroEnd;
        // ignore: avoid_print
        print('T463|$where: [$a, $b, $c, $d]');

        if (a != null && b != null) {
          expect(a < b, isTrue,
              reason: '★★★ ① 违反：introStart($a) 必须 < introEnd($b) —— $where');
        }
        if (b != null && c != null) {
          expect(b < c, isTrue,
              reason: '★★★ ② 违反：introEnd($b) 必须 < outroStart($c) —— '
                  'Owner：「片尾的两个箭头不能跑到片头的两个前面去」（$where）');
        }
        if (c != null && d != null) {
          expect(c < d, isTrue,
              reason: '★★★ ③ 违反：outroStart($c) 必须 < outroEnd($d) —— $where');
        }
        for (final (name, v) in [
          ('introStart', a), ('introEnd', b),
          ('outroStart', c), ('outroEnd', d),
        ]) {
          if (v != null) {
            expect(v >= 0 && v <= total, isTrue,
                reason: '★★★ ④ 违反：$name($v) 越界 [0, $total] —— $where');
          }
        }
      }

      assertInvariants('设完初值');

      /*
       * ★★★ 逐个往**越界方向**拖：
       * ```text
       * introStart → 拖到 90%   （想跑到最右，越过所有人）
       * introEnd   → 拖到 5%    （想跑到最左，越过 introStart）
       * outroStart → 拖到 5%    （想跑到最左，越过片头整对）
       * outroEnd   → 拖到 50%   （想跑到中间，越过 outroStart）
       * ```
       */
      await _dragEdgeTo(tester, SkipEdge.introStart, 0.90);
      assertInvariants('拖 introStart 到 90%');

      await _dragEdgeTo(tester, SkipEdge.introEnd, 0.05);
      assertInvariants('拖 introEnd 到 5%');

      await _dragEdgeTo(tester, SkipEdge.outroStart, 0.05);
      assertInvariants('拖 outroStart 到 5%');

      await _dragEdgeTo(tester, SkipEdge.outroEnd, 0.50);
      assertInvariants('拖 outroEnd 到 50%');
    });

    testWidgets('★★★ 阳性对照：`+` 按钮那条链路也必须守约束',
        (WidgetTester tester) async {
      /*
       * ★ 没有这条，"拖拽修好了但 +/- 坏了"不会被发现 ——
       *   而 `_applyEdge` 与拖拽共用 `_clampTo` ⇒ 两条一起坏或一起好。
       *   这里把 `+` 猛点 30 次（远超任何点的合法上界），断言仍然合法。
       */
      await _pumpDialog(tester);

      final tlFinder = find.byType(SkipTimeline);
      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      final total = tl().total.toInt();

      // 先把「片头开始」推起来
      final plus = find.byIcon(Icons.add);
      for (var i = 0; i < 30; i++) {
        await tester.tap(plus.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 60));
      }
      final w = tl();
      // ignore: avoid_print
      print('T463B|猛点 30 次「+」后: introStart=${w.introStart} '
          'introEnd=${w.introEnd}');

      if (w.introStart != null) {
        expect(w.introStart! >= 0 && w.introStart! <= total, isTrue,
            reason: '★ 越界');
        if (w.introEnd != null) {
          expect(w.introStart! < w.introEnd!, isTrue,
              reason: '★★★ ① 违反：猛点 30 次后 introStart(${w.introStart}) '
                  '跑到了 introEnd(${w.introEnd}) 前面');
        }
      }
    });
  });
}
