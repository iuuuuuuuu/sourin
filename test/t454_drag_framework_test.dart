// ══════════════════════════════════════════════════════════════════════
//  t454 —— 用**框架的** `dragFrom` 驱动 SkipTimeline（先证明能驱动）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么再写一个
//
// t453 证明了**手法本身是好的**（最简单的 GestureDetector：
// tap=1 / dragStart=1 / updates=5）。
// 而 t452 用**同一套手法**驱动 `SkipTimeline` ⇒ `onChanged=0`。
// ⇒ 差别只能在 `SkipTimeline` 自己。
//
// # 本文件把变量逐个消掉
//
// ```text
// ① `tester.dragFrom`（框架封装）—— 排除"我的分步手法"这个变量
// ② 起点直接用 `find.byType(GestureDetector)` 的 rect（排除"我算错坐标"）
// ③ 从**矩形正中**开始（那里没有箭头，会走 onTapDown ⇒ 应该触发 onSeek）
//    ⇒ 若 ③ 连 onSeek 都不触发，说明**手势根本没进这个 GestureDetector**
// ④ 再从**箭头位置**开始拖 ⇒ 应该触发 onChanged
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart' show SkipEdge;
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('t454 用框架 dragFrom 驱动 SkipTimeline', () {
    testWidgets('③ 从矩形正中点一下 ⇒ onSeek 必须触发（手势进得去吗）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final seeks = <double>[];
      await tester.pumpWidget(_host(
        SizedBox(
          width: 800,
          height: 64,
          child: SkipTimeline(
            total: 600,
            position: 0,
            introStart: 30,
            introEnd: 90,
            outroStart: 500,
            outroEnd: 560,
            onSeek: seeks.add,
            onChanged: (_, __) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final r = tester.getRect(find.byType(GestureDetector));
      // ignore: avoid_print
      print('T454③|GD rect = $r');

      // 正中（远离任何箭头）⇒ 应走 onTapDown ⇒ onSeek
      await tester.tapAt(Offset(r.center.dx, r.center.dy));
      await tester.pump(const Duration(milliseconds: 100));

      // ignore: avoid_print
      print('T454③|tap 正中 ⇒ onSeek = $seeks');
      expect(seeks, isNotEmpty,
          reason: '★★★ 点时间轴正中，`onSeek` 都没触发 ⇒ '
              '**手势根本没进到 SkipTimeline 的 GestureDetector**。'
              '这是最基础的一环，它不通的话拖拽必然也不通。');
    });

    testWidgets('④ 用 dragFrom 拖箭头 ⇒ onChanged 必须触发',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final changed = <(SkipEdge, int)>[];
      var introStart = 30;

      await tester.pumpWidget(_host(
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 800,
            height: 64,
            child: SkipTimeline(
              total: 600,
              position: 0,
              introStart: introStart,
              introEnd: 90,
              outroStart: 500,
              outroEnd: 560,
              onSeek: (_) {},
              onChanged: (e, v) {
                changed.add((e, v));
                if (e == SkipEdge.introStart) {
                  setState(() => introStart = v);
                }
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final r = tester.getRect(find.byType(GestureDetector));
      final tips = computeSkipTips(
        width: r.width,
        total: 600,
        introStart: introStart,
        introEnd: 90,
        outroStart: 500,
        outroEnd: 560,
      );
      final center = skipEdgeBodyCenter(
        SkipEdge.introStart,
        tips[SkipEdge.introStart],
      )!;
      final from = Offset(r.left + center, r.center.dy);
      // ignore: avoid_print
      print('T454④|GD rect = $r  箭头中心 = $center  起点 = $from');

      // ★ 框架封装的 dragFrom（内部会正确处理 slop 与竞技场）
      await tester.dragFrom(from, const Offset(200, 0));
      await tester.pump(const Duration(milliseconds: 400));

      // ignore: avoid_print
      print('T454④|dragFrom ⇒ onChanged = $changed  最终 introStart = $introStart');
      expect(changed, isNotEmpty,
          reason: '★★★ 用框架的 `dragFrom` 从箭头位置拖，'
              '`onChanged` 一次都没被调 ⇒ 拖拽链路真的断了');
    });
  });
}
