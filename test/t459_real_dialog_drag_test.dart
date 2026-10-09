// ══════════════════════════════════════════════════════════════════════
//  t459 —— ★★★ 在**真实弹窗**里拖（我上一次测错了宿主）
// ══════════════════════════════════════════════════════════════════════
//
// # 我上一次错在哪（必须记下来）
//
// `skip_marker_dialog.dart:1474-1475` 的注释**明确写着**：
// ```text
// 「探针里**单独**放 SkipTimeline（无外层滚动）时，拖拽 100% 成功
//   —— 所以问题只出在弹窗这个组合里」
// ```
// ★ 而我的 `lib/t458_drag_selftest.dart` 用的宿主是
//   `Center > SizedBox > SkipTimeline` ——
//   **正是那个"已知能成功"的配置**！
// ⇒ 它 PASS 了，而**什么也没证明**。
// ⇒ Owner 随后说「那个三角根本就不能拖动」—— 他是对的。
//
// ★★ 教训：**验证必须复现缺陷所在的配置**。
//    我修了一个 bug（`DragStartBehavior`），然后在一个
//    **已知不触发该 bug 的宿主**上验证 —— 那等于没验。
//
// # 本文件：宿主就是**真实的 `SkipMarkerDialog`**
//
// 不抽 `SkipTimeline` 单独测，而是把整个弹窗挂起来，
// 在里面找到时间轴、按**真实坐标**发指针事件。
//
// # 同时验证 Owner 的第二条：初始位置
// ```text
// Owner：「我说了初始位置，片头的三角两个中间是 00:00，片尾的也就是对应的，
//         具体可以参考夸克网盘视频播放器的逻辑」
// ```
// ⇒ 断言：**未设置时**，四个幽灵箭头的位置必须体现
//   「片头两个在 0（最左）、片尾两个在最右」。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 挂真实弹窗并等它稳定
Future<void> _pumpDialog(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_host(
    const SkipMarkerDialog(
      provider: 'demo',
      id: 't459',
      title: 't459 真实弹窗拖拽',
      streamUrl: '',
      duration: Duration(minutes: 47, seconds: 6),
    ),
  ));
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    while (tester.takeException() != null) {}
  }
}

void main() {
  group('t459 真实弹窗里的拖拽（复现缺陷所在的配置）', () {
    testWidgets('★★★ 在真实弹窗里拖箭头 ⇒ 必须生效', (WidgetTester tester) async {
      await _pumpDialog(tester);

      final tlFinder = find.byType(SkipTimeline);
      expect(tlFinder, findsOneWidget, reason: '弹窗里必须有时间轴');

      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      final rect = tester.getRect(tlFinder);
      // ignore: avoid_print
      print('T459|时间轴 rect = $rect');
      // ignore: avoid_print
      print('T459|初始 introStart=${tl().introStart} introEnd=${tl().introEnd} '
          'outroStart=${tl().outroStart} outroEnd=${tl().outroEnd}');

      /*
       * ★ 先给端点设值 —— 否则幽灵箭头**抓不住**
       *   （`hitEdge` 里 `tip == null ⇒ continue`）。
       *   走**读数行的「+」**，与用户的操作路径一致。
       */
      final plus = find.byIcon(Icons.add);
      // ignore: avoid_print
      print('T459|「+」按钮数量 = ${plus.evaluate().length}');
      for (var i = 0; i < 4; i++) {
        await tester.tap(plus.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('T459|点 4 次「+」后 introStart = ${tl().introStart}');

      final tips = computeSkipTips(
        width: rect.width,
        total: tl().total,
        introStart: tl().introStart,
        introEnd: tl().introEnd,
        outroStart: tl().outroStart,
        outroEnd: tl().outroEnd,
      );
      // ignore: avoid_print
      print('T459|tipX = $tips');

      final center = skipEdgeBodyCenter(
        SkipEdge.introStart,
        tips[SkipEdge.introStart],
      );
      expect(center, isNotNull, reason: '端点必须有值才可抓');

      // ★ 记录 onChanged 是否被调（用 SkipTimeline 的入参变化观察）
      final before = tl().introStart;
      final from = Offset(rect.left + center!, rect.center.dy);
      final to = Offset(rect.left + rect.width * 0.6, rect.center.dy);
      // ignore: avoid_print
      print('T459|拖拽 $from -> $to');

      // ── 真实指针事件，分 14 步 ──
      final binding = GestureBinding.instance;
      final pointer = 9001;
      binding.handlePointerEvent(PointerDownEvent(
        pointer: pointer, position: from, kind: PointerDeviceKind.mouse,
      ));
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 1; i <= 14; i++) {
        final p = Offset.lerp(from, to, i / 14)!;
        binding.handlePointerEvent(PointerMoveEvent(
          pointer: pointer, position: p, kind: PointerDeviceKind.mouse,
        ));
        await tester.pump(const Duration(milliseconds: 40));
      }
      final during = tl().introStart;
      binding.handlePointerEvent(PointerUpEvent(
        pointer: pointer, position: to, kind: PointerDeviceKind.mouse,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      // ignore: avoid_print
      print('T459|拖动中 introStart = $during  （拖动前 = $before）');
      // ignore: avoid_print
      print('T459|松手后 introStart = ${tl().introStart}');

      expect(
        during != before, isTrue,
        reason: '★★★ **在真实弹窗里**拖箭头，`introStart` 从 $before 变成 $during —— '
            '没有变化 ⇒ 拖拽在弹窗里仍然失效。'
            '★ 这正是 Owner 说的「那个三角根本就不能拖动」。'
            '（我上一次在**裸放**的宿主上验证，那个配置本来就能拖动，'
            '所以 PASS 什么也没证明）',
      );
    });

    testWidgets('★★★ 初始位置：未设置时片头一对在 0、片尾一对在最右',
        (WidgetTester tester) async {
      await _pumpDialog(tester);

      final tlFinder = find.byType(SkipTimeline);
      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      final rect = tester.getRect(tlFinder);

      // ignore: avoid_print
      print('T459B|初始值 introStart=${tl().introStart} introEnd=${tl().introEnd} '
          'outroStart=${tl().outroStart} outroEnd=${tl().outroEnd}');

      /*
       * ★ Owner 的诉求（逐字）
       * ```text
       * 「我说了初始位置，片头的三角两个中间是 00:00，
       *   片尾的也就是对应的，具体可以参考夸克网盘视频播放器的逻辑」
       * ```
       * ⇒ 未设置时四个幽灵箭头的**语义位置**必须是：
       * ```text
       * 片头开始 ≈ 0（最左）      片头结束 ≈ 0（紧挨着，形成"一对"）
       * 片尾开始 ≈ 总时长（最右）  片尾结束 ≈ 总时长（紧挨着）
       * ```
       * ⚠️ 注意 `computeSkipTips` 对 null 端点返回 **null** ——
       *    幽灵位置由 `ghostTipFor` 单独算。所以这里直接量**画出来的**。
       */
      final ghostStart = ghostTipFor(
        edge: SkipEdge.introStart, width: rect.width, inset: kArrowInset,
        arrowW: kArrowW,
      );
      final ghostIntroEnd = ghostTipFor(
        edge: SkipEdge.introEnd, width: rect.width, inset: kArrowInset,
        arrowW: kArrowW,
      );
      final ghostOutroStart = ghostTipFor(
        edge: SkipEdge.outroStart, width: rect.width, inset: kArrowInset,
        arrowW: kArrowW,
      );
      final ghostOutroEnd = ghostTipFor(
        edge: SkipEdge.outroEnd, width: rect.width, inset: kArrowInset,
        arrowW: kArrowW,
      );
      // ignore: avoid_print
      print('T459B|幽灵 tip: 片头开始=$ghostStart 片头结束=$ghostIntroEnd '
          '片尾开始=$ghostOutroStart 片尾结束=$ghostOutroEnd');

      // ★ 判据：片头那一对必须在**最左**，片尾那一对必须在**最右**
      final mid = rect.width / 2;
      expect(ghostStart! < mid, isTrue,
          reason: '★★★ 「片头开始」的初始位置在 $ghostStart —— '
              '不在左半边。Owner 要的是"片头的三角两个中间是 00:00"');
      expect(ghostIntroEnd! < mid, isTrue,
          reason: '★★★ 「片头结束」的初始位置在 $ghostIntroEnd —— 不在左半边');
      expect(ghostOutroStart! > mid, isTrue,
          reason: '★★★ 「片尾开始」的初始位置在 $ghostOutroStart —— '
              '不在右半边。Owner 要的是"片尾的也就是对应的"（在最右）');
      expect(ghostOutroEnd! > mid, isTrue,
          reason: '★★★ 「片尾结束」的初始位置在 $ghostOutroEnd —— 不在右半边');

      // ★ 而且"一对"要挨在一起（同一侧、靠近端点）
      expect((ghostIntroEnd - ghostStart).abs() < 60, isTrue,
          reason: '★ 片头那两个必须挨在一起（差 ${(ghostIntroEnd - ghostStart).abs()}）'
              '—— 它们是"一对"');
      expect((ghostOutroEnd - ghostOutroStart).abs() < 60, isTrue,
          reason: '★ 片尾那两个必须挨在一起');
    });
  });
}
