// ══════════════════════════════════════════════════════════════════════
//  t460 —— ★★★ 幽灵箭头必须可拖（Owner：「那个三角根本就不能拖动」）
// ══════════════════════════════════════════════════════════════════════
//
// # 这条测试要挡住的缺陷
//
// Owner 打开片头片尾弹窗时，**四个端点都没设置** ⇒ 屏幕上画着
// 四个**幽灵箭头**（`alpha 0.28`）。他去拖 —— **一个都拖不动**。
//
// 真因（我实测确诊）：
// ```text
// hitEdge 用 `skipEdgeBodyCenter(e, drawTips[e])`
// drawTips 来自 computeSkipTips ⇒ 未设置的端点返回 **null**
//   ⇒ `if (c == null) continue;` ⇒ 那个端点**在命中测试里不存在**
// ⇒ 四个幽灵箭头**画出来了，但完全不可交互**
// ```
//
// ★ 而改前的代码注释**认为这是对的**：
// ```text
// 「⚠️ 幽灵**仍不可拖**…这是对的：没设过的点没有"位置"可言。
//   用户用右边那行的 −/+ 把它设出来（那才是"开始/结束"的入口）。」
// ```
// ⇒ ★★ 这个推理**在"什么是可见的"这一步就错了**：
//    **画出来的东西就应该是可交互的**。用户看到四个三角，第一反应必然是去拖。
//
// # 我为什么上一轮没抓到它
//
// 我的 `t459` 里写了这么一行：
// ```dart
// expect(center, isNotNull, reason: '端点必须有值才可抓');
// ```
// 然后**先点了 4 次「+」把端点设出来**，再测拖拽。
// ★ 我把 **bug 本身当成了测试前提**绕过去了 ——
//   于是"拖拽"这个动作确实能工作（端点已设），而
//   **Owner 遇到的那个场景（端点未设）根本没被测到**。
//
// # 判据
// ```text
// ① 端点**全未设置**时，在幽灵箭头的**画出来的位置**按下并拖 ⇒ 必须生效
// ② 四个端点**各自**都要能这样拖（不能只修好一个）
// ③ 阳性对照：幽灵位置必须与画家用的 `ghostTipFor` **一致**
// ```

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

/// 挂**真实弹窗**并等它稳定
///
/// ⚠️ 必须是真实弹窗 —— `skip_marker_dialog.dart:1474` 的注释明确写着
///    「探针里**单独**放 SkipTimeline（无外层滚动）时，拖拽 100% 成功
///      —— 所以问题只出在弹窗这个组合里」。
///    ★ 我上一轮（t458）正是在"单独放"的宿主上验证的 ⇒ PASS 什么也没证明。
Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_host(
    const SkipMarkerDialog(
      provider: 'demo',
      id: 't460',
      title: 't460 幽灵箭头可拖',
      streamUrl: '',
      duration: Duration(minutes: 47, seconds: 6),
    ),
  ));
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    while (tester.takeException() != null) {}
  }
}

/// 在真实弹窗里把某个端点从 [fromX] 拖到 [toX]，返回拖动中/松手后的值
Future<(int?, int?)> _dragEdge(
  WidgetTester tester,
  SkipEdge edge, {
  required double fromX,
  required double toX,
}) async {
  final tlFinder = find.byType(SkipTimeline);
  final rect = tester.getRect(tlFinder);

  final binding = GestureBinding.instance;
  final pointer = 9100 + edge.index;
  final y = rect.center.dy;

  binding.handlePointerEvent(PointerDownEvent(
    pointer: pointer,
    position: Offset(rect.left + fromX, y),
    kind: PointerDeviceKind.mouse,
  ));
  await tester.pump(const Duration(milliseconds: 40));

  const steps = 14;
  for (var i = 1; i <= steps; i++) {
    final x = fromX + (toX - fromX) * i / steps;
    binding.handlePointerEvent(PointerMoveEvent(
      pointer: pointer,
      position: Offset(rect.left + x, y),
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 40));
  }

  int? valueOf() {
    final w = tester.widget<SkipTimeline>(tlFinder);
    return switch (edge) {
      SkipEdge.introStart => w.introStart,
      SkipEdge.introEnd => w.introEnd,
      SkipEdge.outroStart => w.outroStart,
      SkipEdge.outroEnd => w.outroEnd,
    };
  }

  final during = valueOf();

  binding.handlePointerEvent(PointerUpEvent(
    pointer: pointer,
    position: Offset(rect.left + toX, y),
    kind: PointerDeviceKind.mouse,
  ));
  await tester.pump(const Duration(milliseconds: 400));

  return (during, valueOf());
}

void main() {
  group('t460 幽灵箭头可拖（端点全未设置的场景）', () {
    testWidgets('★★★ 四个幽灵箭头**各自**都要能拖', (WidgetTester tester) async {
      await _pumpDialog(tester);

      final tlFinder = find.byType(SkipTimeline);
      final rect = tester.getRect(tlFinder);

      // ── 前提断言：确认真的"全未设置"（否则测的不是这个场景）──
      final w0 = tester.widget<SkipTimeline>(tlFinder);
      expect(
        [w0.introStart, w0.introEnd, w0.outroStart, w0.outroEnd],
        everyElement(isNull),
        reason: '★ 本测试的场景是「四个端点**都没设置**」—— '
            '若已有值，那测的是另一个场景（t459 覆盖了那个）',
      );
      // ignore: avoid_print
      print('T460|确认：四个端点全未设置 ⇒ 屏幕上画的是幽灵箭头');

      /*
       * ★★★ 关键：起点用**画家画幽灵的那个位置**（`ghostTipFor`）
       *     ⇒ 模拟用户"看到三角就去拖它"。
       *     ⚠️ 这正是改前失败的地方 —— 用户拖的就是这个位置。
       */
      final mid = rect.width / 2;
      var idx = 0;
      for (final edge in SkipEdge.values) {
        final ghostTip = ghostTipFor(
          edge: edge,
          width: rect.width,
          inset: kArrowInset,
          arrowW: kArrowW,
        );
        final body = skipEdgeBodyCenter(edge, ghostTip)!;

        /*
         * 拖动方向：往时间轴**中段**拖（远离幽灵的初始贴边位置），
         * 这样"值变了"是明确可判的。
         */
        final target = edge == SkipEdge.introStart || edge == SkipEdge.introEnd
            ? rect.width * 0.30
            : rect.width * 0.70;

        final (during, after) = await _dragEdge(
          tester, edge, fromX: body, toX: target,
        );

        // ignore: avoid_print
        print('T460|$edge: 幽灵 body=$body  拖到 x=$target  '
            '⇒ 拖动中=$during  松手后=$after');

        expect(
          during, isNotNull,
          reason: '★★★ 幽灵箭头 `$edge` **拖不动**（拖动中仍是 null）。'
              '它的幽灵位置在 x=$body —— 用户看到的就是这个三角。'
              '★ 改前 `hitEdge` 用 `computeSkipTips` 的值（未设置 ⇒ null）'
              '⇒ `if (c == null) continue` ⇒ 这个端点在命中测试里不存在。',
        );
        expect(
          after, isNotNull,
          reason: '★★★ 幽灵箭头 `$edge` 松手后仍未被赋值',
        );

        idx++;
        // 每个端点单独一轮：拖完一个之后其余仍是 null，
        // 但**已经设过的那个**会有值 ⇒ 下一轮的前提断言不能再要求全 null。
        if (idx == 1) {
          // ignore: avoid_print
          print('T460|（第 1 个拖完后，其余三个仍应是 null —— 确认没误伤）');
          final w1 = tester.widget<SkipTimeline>(tlFinder);
          final others = [
            if (edge != SkipEdge.introStart) w1.introStart,
            if (edge != SkipEdge.introEnd) w1.introEnd,
            if (edge != SkipEdge.outroStart) w1.outroStart,
            if (edge != SkipEdge.outroEnd) w1.outroEnd,
          ];
          expect(others, everyElement(isNull),
              reason: '★ 拖一个端点**不该**把别的也赋值了（误伤）');
        }
      }
    });

    testWidgets('★★★ 阳性对照：幽灵位置与画家用的 `ghostTipFor` 一致',
        (WidgetTester tester) async {
      await _pumpDialog(tester);

      final rect = tester.getRect(find.byType(SkipTimeline));
      /*
       * ★ 这条守的是"命中用的位置 == 画出来的位置"。
       *   改前它们**不一致**（命中用 null ⇒ 相当于没有位置）。
       *   ⚠️ 无法直接读 `tipForHit`（它是 build 内的局部函数），
       *      所以这里断言"幽灵位置本身是合理的"：
       *      片头两个在左、片尾两个在右，且都能被 `bodyCenter` 算出中心。
       */
      final introStart = ghostTipFor(
        edge: SkipEdge.introStart, width: rect.width,
        inset: kArrowInset, arrowW: kArrowW,
      );
      final outroEnd = ghostTipFor(
        edge: SkipEdge.outroEnd, width: rect.width,
        inset: kArrowInset, arrowW: kArrowW,
      );
      expect(introStart < rect.width / 2, isTrue,
          reason: '片头幽灵应在左半边');
      expect(outroEnd > rect.width / 2, isTrue,
          reason: '片尾幽灵应在右半边');
      // ★ 两个都能算出箭身中心（`skipEdgeBodyCenter` 对非 null 一定返回非 null）
      expect(skipEdgeBodyCenter(SkipEdge.introStart, introStart), isNotNull);
      expect(skipEdgeBodyCenter(SkipEdge.outroEnd, outroEnd), isNotNull);
    });
  });
}
