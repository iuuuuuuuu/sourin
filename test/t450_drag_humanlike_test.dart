// ══════════════════════════════════════════════════════════════════════
//  t450 —— 拟人化拖拽：**真的**按住箭头 → 移动 → 松手，看画面跟不跟
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 「片头片尾的设置根本没用,那四个箭头是可以拖动的,
//   然后拖动松手就应该定格在松手的那一帧才对,
//   你自己拟人化操作试试看看到底行不行」
// ```
//
// # 这条测试要回答的问题
// ```text
// ① 箭头**能不能**拖动（手势链通不通）
// ② 松手后**有没有**定格到那一帧（= 调 `_previewSeek`）
// ```
// ★ 关键是 ② —— 我读代码怀疑 `onChanged` 只改数值、不碰预览，
//   但**读代码不算数**（本项目已多次证明"看起来对"和"真的对"是两件事）。
//   所以这里用 `tester.drag` 真发手势，然后**观察预览播放器的 seek 有没有被调**。
//
// # 怎么观察"预览有没有跟"
// 预览播放器在测试环境加载不了 `sourin_core.dll`（无核心库），
// `_preview` 恒为 null ⇒ `_previewSeek` 会提前 return。
// ⇒ 直接观察 `_preview` 不可行。
//
// ★ 改用**可观察的代理**：`_previewPos`
// ```text
// `_previewSeek` 的第一件事就是乐观地设 `_previewPos = 目标秒`
//   （见它自己的注释："`_previewPos` 是**乐观**的"）
// ⇒ 它变了 ⇒ `_previewSeek` 被调过
// ⇒ 它没变 ⇒ 松手**没有**触发预览
// ```
// 而 `_previewPos` 会经 `SkipTimeline(position:)` 反映到时间轴画家，
// 所以也能从渲染层验证。

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

void main() {
  group('t450 拟人化拖拽', () {
    testWidgets('★★★ 拖箭头 → 松手：预览必须跟到那一秒', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      /*
       * ★ 关键：捕获 `SkipTimeline` 的 `position` 入参随时间的**序列**。
       *
       * `position` = `_previewPos`（弹窗的预览位置）。
       * `_previewSeek` 一被调用就会把它设成目标值 ⇒
       * **这个序列变了 ⇒ 预览被驱动过**。
       */
      final positions = <double>[];

      await tester.pumpWidget(_host(
        Builder(
          builder: (context) {
            return SkipMarkerDialog(
              provider: 'demo',
              id: 't450',
              title: 't450 拖拽验收',
              streamUrl: '',
              duration: const Duration(minutes: 47, seconds: 6),
            );
          },
        ),
      ));

      // 等它读完数据 + 布局稳定
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        while (tester.takeException() != null) {}
      }

      // 找到时间轴
      final tlFinder = find.byType(SkipTimeline);
      expect(tlFinder, findsOneWidget, reason: '弹窗里必须有时间轴');

      // 记录初始 position
      SkipTimeline tl() => tester.widget<SkipTimeline>(tlFinder);
      positions.add(tl().position);
      // ignore: avoid_print
      print('T450|初始 position = ${tl().position}');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 第一版这里错了，记下来（2026-10-01）
       * ══════════════════════════════════════════════════════════════
       *
       * 我第一版拿 `computeSkipTips` 的返回值当"箭头位置"去拖。
       * 实测四个 tip **全是 null**（本环境读不到已存的跳过点），
       * 于是我退到 `tlRect.left + 20` 去按 —— 那**没落在箭头上**：
       * ```text
       * onTapDown  → hitEdge == null → onSeek(...)  ← 走了**点击跳转**分支
       * ⇒ position 变成 953（"看起来变了"）
       * ⇒ 而 introStart 恒为 null（**根本没抓住箭头**）
       * ⇒ 我那条"position 变了就算通过"的判据**假绿**了
       * ```
       * ★ 教训：判据必须能区分"抓住了箭头"与"只是点了空白" ——
       *   否则测的不是拖拽。⇒ 现在**先断言抓住了**，再断言预览跟随。
       *
       * ⚠️ 而且必须**先让端点有值**：`hitEdge` 用 `skipEdgeBodyCenter(e, tip)`，
       *    `tip == null` ⇒ `continue` ⇒ 那个端点**根本不可抓**。
       *    本环境读不到 store（无核心库）⇒ 四个端点都是 null
       *    ⇒ **必须走读数行的「+」先把端点设出来**，否则测不了拖拽。
       */
      final tlRect = tester.getRect(tlFinder);
      // ignore: avoid_print
      print('T450|时间轴 rect = $tlRect');

      // ── 先给四个端点设上值（模拟"用户已经调过一些"）──
      // 每行一个「+」按钮；点几次把它推到一个可见的位置
      for (var round = 0; round < 3; round++) {
        final plus = find.byIcon(Icons.add);
        if (plus.evaluate().isEmpty) break;
        // 第 1 个「+」= 片头开始那一行
        await tester.tap(plus.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('T450|点过「+」后 introStart = ${tl().introStart}');

      final tips = computeSkipTips(
        width: tlRect.width,
        total: tl().total,
        introStart: tl().introStart,
        introEnd: tl().introEnd,
        outroStart: tl().outroStart,
        outroEnd: tl().outroEnd,
      );
      // ignore: avoid_print
      print('T450|四个箭头 tipX = $tips');

      // ★ 用**生产同一个函数**算箭身中心（`hitEdge` 用的就是它）
      final bodyCenter = skipEdgeBodyCenter(
        SkipEdge.introStart,
        tips[SkipEdge.introStart],
      );
      expect(bodyCenter, isNotNull,
          reason: '★ 「片头开始」端点必须已有值，否则它**不可抓** —— '
              '那是本测试的前提，不是被测对象');

      // ignore: avoid_print
      print('T450|「片头开始」箭身中心 x = $bodyCenter');

      final g = await tester.startGesture(
        Offset(tlRect.left + bodyCenter!, tlRect.top + tlRect.height / 2),
      );
      await tester.pump(const Duration(milliseconds: 30));

      // 分 8 步移动（拟人：不是瞬移）
      const steps = 8;
      final fromX = tlRect.left + bodyCenter;
      final targetX = tlRect.left + tlRect.width * 0.55;
      for (var i = 1; i <= steps; i++) {
        final x = fromX + (targetX - fromX) * i / steps;
        await g.moveTo(Offset(x, tlRect.top + tlRect.height / 2));
        await tester.pump(const Duration(milliseconds: 30));
      }

      final during = tl().introStart;
      // ignore: avoid_print
      print('T450|拖动中 introStart = $during');

      // ★★★ 前提断言：必须真的抓住了箭头（否则下面测的不是拖拽）
      expect(during, isNotNull,
          reason: '★★★ 拖动中 `introStart` 仍是 null ⇒ **没抓住箭头**，'
              '测的不是拖拽（多半落在了空白处，走了 onTapDown 的跳转分支）');

      // ── 松手 ──
      await g.up();
      await tester.pump(const Duration(milliseconds: 30));

      // 等 debounce（250ms）走完
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        positions.add(tl().position);
      }

      // ignore: avoid_print
      print('T450|松手后 introStart = ${tl().introStart}');
      // ignore: avoid_print
      print('T450|position 序列 = $positions');

      /*
       * ★★★ 判据：松手后 `position` 必须**变过**
       *
       * `_previewSeek` 一被调用就把 `_previewPos` 设成目标值。
       * ⇒ 若松手后 position 从头到尾 == 初始值，
       *   说明**预览从没被驱动** —— 正是 Owner 说的"根本没用"。
       */
      final changed = positions.any((p) => (p - positions.first).abs() > 0.5);
      expect(
        changed, isTrue,
        reason: '★★★ 拖完松手，预览位置**一次都没变**（序列 $positions）—— '
            'Owner 报的「拖动松手应该定格在松手的那一帧」没有被满足。'
            '`onChanged` 只改了数值，没有驱动预览。',
      );
    });
  });
}
