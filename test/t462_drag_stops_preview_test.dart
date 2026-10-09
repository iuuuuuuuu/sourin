// ══════════════════════════════════════════════════════════════════════
//  t462 —— ★★★ 行为级验证：播放中拖动 ⇒ 预览**停住**在拖动值
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么不能只靠 t461
//
// `t461` 是**源码文本**断言（`_followPreviewTo` 里有 `_previewFrame(`）——
// 它能证明"代码写对了"，**证明不了"行为对了"**。
// ★ 本仓的铁律：判据必须与证据**同层**。
//
// # 这条测什么
//
// 真渲染**真实弹窗**，然后在里面：
// ```text
// ① 让预览"看起来在播" —— 通过「整段」按钮（若可用）
// ② 拖时间轴箭头
// ③ 断言 `_previewPos`（= SkipTimeline 的 position）**停在拖动值**上，
//    并且在之后若干帧内**不再前进**
// ```
//
// # 关键：怎么判"停住"
//
// `_previewPos` 是乐观值 —— `_previewSeek` 一调就设成目标值。
// ★ 若预览**真的在播**，播放器的 position 流会持续更新 `_previewPos`
//   （见 `_initPreview` 里对 position 流的监听）。
// ⇒ 所以"连续采样 `position` 看它是否稳定"是一个有效的判据。
//
// ⚠️ 本环境 `_preview` 恒为 null（无 `sourin_core.dll`）⇒ 没有 position 流
//    ⇒ 这一条在本环境**测不出"继续播放"**。
//    但它能测出**另一半**：拖动后 `position` 必须**稳定在拖动值**，
//    而不是被 `_loopTimer` 拉回区间起点。
//    ⇒ 这正是"状态重置"的可观察部分。

import 'package:flutter/gestures.dart';
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

void main() {
  group('t462 行为级：拖动后预览必须停住', () {
    testWidgets('★★★ 拖动后 `position` 稳定在拖动值（不被循环拉走）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't462',
          title: 't462 播放中拖动',
          streamUrl: '',
          duration: Duration(minutes: 47, seconds: 6),
        ),
      ));
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        while (tester.takeException() != null) {}
      }

      final tlFinder = find.byType(SkipTimeline);
      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      final rect = tester.getRect(tlFinder);

      // ── ① 先点「整段」（让"正在播"的路径被走到；按钮可能禁用）──
      final rangeBtns = find.textContaining('整段');
      // ignore: avoid_print
      print('T462|「整段」按钮数 = ${rangeBtns.evaluate().length}');
      for (var i = 0; i < rangeBtns.evaluate().length; i++) {
        await tester.tap(rangeBtns.at(i), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('T462|点完「整段」后 position = ${tl().position}');

      // ── ② 先给端点设值（否则幽灵不可抓 —— 那是 t460 覆盖的场景）──
      final plus = find.byIcon(Icons.add);
      for (var i = 0; i < 4; i++) {
        await tester.tap(plus.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
      }
      final tips = computeSkipTips(
        width: rect.width,
        total: tl().total,
        introStart: tl().introStart,
        introEnd: tl().introEnd,
        outroStart: tl().outroStart,
        outroEnd: tl().outroEnd,
      );
      final center = skipEdgeBodyCenter(
        SkipEdge.introStart, tips[SkipEdge.introStart],
      )!;

      // ── ③ 拖动 ──
      final from = Offset(rect.left + center, rect.center.dy);
      final to = Offset(rect.left + rect.width * 0.6, rect.center.dy);
      final binding = GestureBinding.instance;
      const pointer = 9500;
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

      // ── ④ 松手后连续采样 position（等 debounce 250ms + 若干帧）──
      final samples = <double>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        samples.add(tl().position);
      }

      final dragValue = tl().introStart;
      // ignore: avoid_print
      print('T462|拖动后 introStart = $dragValue');
      // ignore: avoid_print
      print('T462|position 采样 = $samples');

      expect(dragValue, isNotNull, reason: '★ 前提：拖动必须生效（t460 覆盖）');

      /*
       * ★★★ 判据：采样序列**稳定**在拖动值上。
       *
       * 若 `_loopTimer` 还在跑（状态没重置），它每 200ms 检查一次，
       * 发现位置越界就把画面**拽回区间起点** ⇒ 采样序列会**跳变**。
       * ⇒ "稳定"就是"状态已重置"的可观察证据。
       */
      final tail = samples.skip(6).toList(); // 跳过 debounce 期的前几帧
      final first = tail.first;
      final stable = tail.every((v) => (v - first).abs() < 0.5);
      // ignore: avoid_print
      print('T462|稳定段 = $tail  首值=$first  稳定=$stable');

      expect(
        stable, isTrue,
        reason: '★★★ 拖动后 `position` **不稳定**（序列 $samples）—— '
            '说明区间循环（`_loopTimer`）没被清掉，画面被反复拉走。'
            'Owner：「状态应该重置,不应该继续播放」',
      );

      expect(
        (first - dragValue!).abs() < 1.5, isTrue,
        reason: '★★★ 拖动后预览**没有停在拖动值**上：'
            '停在 $first，而拖动值是 $dragValue。'
            'Owner：「应该是变回拖动结束后的那一帧预览」',
      );
    });
  });
}
