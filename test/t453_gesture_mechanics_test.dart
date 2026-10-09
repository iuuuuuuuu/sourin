// ══════════════════════════════════════════════════════════════════════
//  t453 —— 先修**手法**：让手势真的进到 `SkipTimeline` 的 GestureDetector
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么要先修手法
//
// t451 / t452 里，**裸放**的 `SkipTimeline` 也是 `onChanged = 0`、`onSeek = 0`
// —— 连最简单的 `onTapDown` 都没触发。
// ★ 那是**尺子坏了**：在尺子修好之前，"拖不动"这个读数**没有信息量**
//   （分不清是产品坏了还是我的手法不对）。
//
// # 本文件逐层排查手法
//
// ```text
// ① GestureDetector 在树里吗？（find.byType）
// ② 我算的坐标落在它矩形内吗？
// ③ 一个**最简单的** GestureDetector（只有 onTapDown）能被点中吗？
//    ⇒ 若不能 ⇒ 是 tester 层面的问题（视图尺寸/坐标系）
// ④ 加 onHorizontalDragStart 后能被拖动吗？
//    ⇒ 用 tester.dragFrom（框架封装好的）而不是手工 startGesture
// ```
// ★ 每一层都断言，**第一层失败就停** —— 这样能精确定位是哪里断的。

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

void main() {
  group('t453 手势手法逐层排查', () {
    testWidgets('① 最简单的 GestureDetector 能被点中吗', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var taps = 0;
      var drags = 0;
      await tester.pumpWidget(_host(
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => taps++,
            onHorizontalDragStart: (_) => drags++,
            child: Container(width: 400, height: 64, color: const Color(0xFFEEEEEE)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final r = tester.getRect(find.byType(GestureDetector));
      // ignore: avoid_print
      print('T453①|简单 GD rect = $r');

      // ── 点 ──
      await tester.tapAt(r.center);
      await tester.pump(const Duration(milliseconds: 50));
      // ignore: avoid_print
      print('T453①|tap 后 taps=$taps');

      // ── 拖（用框架的 dragFrom）──
      await tester.dragFrom(r.center, const Offset(-100, 0));
      await tester.pump(const Duration(milliseconds: 100));
      // ignore: avoid_print
      print('T453①|drag 后 drags=$drags');

      expect(taps, greaterThan(0),
          reason: '★ 最简单的 GestureDetector 都点不中 ⇒ '
              '**是 tester 层面的问题**（视图尺寸/坐标系），不是产品');
      expect(drags, greaterThan(0),
          reason: '★ 最简单的 GestureDetector 都拖不动 ⇒ 同上');
    });

    testWidgets('② 手工 startGesture 也要能拖（对比框架 dragFrom）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var drags = 0;
      var updates = 0;
      await tester.pumpWidget(_host(
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => drags++,
            onHorizontalDragUpdate: (_) => updates++,
            child: Container(width: 400, height: 64, color: const Color(0xFFEEEEEE)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final r = tester.getRect(find.byType(GestureDetector));
      final g = await tester.startGesture(r.center, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 5; i++) {
        await g.moveTo(r.center + Offset(-20.0 * i, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));

      // ignore: avoid_print
      print('T453②|手工 startGesture: dragStart=$drags  updates=$updates');
      expect(drags, greaterThan(0),
          reason: '★ 手工 startGesture 也要能触发 —— 否则 t451/t452 的'
              '"0 次"是手法问题，不是产品问题');
    });
  });
}
