// ═══════════════════════════════════════════════════════════════════════
//  task-24 ② 卡片"同一行等高" —— 回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 还有js源的卡片高度不一致也要优化
//
// # 根因（2026-09-25 实测定位，**与最初的假设不同**）
//
// 最初的假设是：
// ```text
// 卡片内容有三个独立变量（能力 chip 行 / 代理行 / 登录行）
//   ⇒ 不同卡内容高度不同
//   ⇒ IntrinsicHeight 把同一行拉到最高那张 ⇒ 矮卡里大量空白
// ```
// 前半句**成立**（内容确实不等高），但后半句**不成立** ——
// 实测发现 `IntrinsicHeight` 根本没把行拉平：
//
// ```text
// .probe/t24_profile.py  量真机截图 SETTINGS-full-top.png（1280x800）
//   第 1 行：col0 = 194px   col1/2/3 = 144px   → 同一行差 50px
//   第 3 行：col0 = 144     col2      = 176     → 同一行差 32px
// ```
// 按 `.probe/VERIFY-LESSONS.md` 铁律④「最像嫌疑人的往往不是真凶」，
// 我做了**阳性对照**（`.probe/probe_tests/t24_grid_equality_test.dart`）：
// 用 8 个**故意不等高**（100/160 交替）的占位块铺网格，量每格实际高度。
//
// ```text
// 修前：100,160,100,160,100,160,100,160   row delta = 60px  ← 没拉平
// 修后：160,160,160,160,160,160,160,160   row delta =  0px  ← 拉平了
// ```
//
// # 真凶：`AnimatedSwitcher.layoutBuilder` 里的 `Stack` 默认 `fit`
//
// ```text
// IntrinsicHeight > Row(crossAxisAlignment: stretch)
//   → 给每格发**紧高度**（h = 行高）
//   → 但格子里的 AnimatedSwitcher.layoutBuilder 返回 `Stack(...)`
//   → `Stack` 默认 `fit: StackFit.loose` 把紧约束**降级成松约束**
//     （0 <= h <= 行高）
//   → 卡片选择"按内容高度"，只有内容最高的那张撑满行高
//   → 同一行参差不齐
// ```
// 修法：`fit: StackFit.passthrough`（把收到的约束**原样**传给孩子）。
//
// ⚠️ 这个坑本项目**已经记过一次**（`reorderable_card_grid.dart` 里
//    "第二版：`Stack` + `Positioned.fill` —— 也不对"那段注释），
//    当时在**高亮层**踩到并用 `DecoratedBox` 绕开了；
//    而 `AnimatedSwitcher` 的 `layoutBuilder` 必须返回 `Stack`，绕不开 ——
//    所以必须在**这里**显式指定 `fit`。
//
// # 为什么这条测试必须存在
//
// `StackFit.loose` 是 `Stack` 的**默认值**，所以"删掉这一行"看起来
// 只是"少了一个参数"，编译、其它测试都不会报错 —— 但 26 张卡会立刻
// 变回参差不齐。没有这条测试，这个 bug 会**静默复发**。

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/reorderable_card_grid.dart';

/// 量一个子树的高度
class _Measure extends StatefulWidget {
  const _Measure({super.key, required this.child, required this.onHeight});

  final Widget child;
  final ValueChanged<double> onHeight;

  @override
  State<_Measure> createState() => _MeasureState();
}

class _MeasureState extends State<_Measure> {
  final _k = GlobalKey();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ro = _k.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) widget.onHeight(ro.size.height);
    });
    return SizedBox(key: _k, child: widget.child);
  }
}

void main() {
  group('task-24 ② 网格必须把同一行拉成等高', () {
    testWidgets('★★ 故意不等高的 8 格 → 同一行必须全部等高', (tester) async {
      /*
       * ★ 这是**阳性对照**：故意让格子内容高度不同（100 / 160 交替），
       *   这样"是否拉平"才可观测。
       *
       * ⚠️ 若用等高的格子，无论 `fit` 对不对都会通过 —— 那是**假绿**。
       *    （我第一版探针就差点这么写。）
       */
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const available = 1280 - AppMetrics.contentPadding * 2;
      final cols = ReorderableCardGrid.columnsFor(available);
      const n = 8;
      double wantHeight(int i) => i.isEven ? 100.0 : 160.0;

      final heights = <int, double>{};
      final theme = FTheme.neutral.light.desktop;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.toApproximateMaterialTheme(),
          builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReorderableCardGrid(
                itemCount: n,
                onReorder: (_, __) {},
                itemBuilder: (context, i, dragHandle, cellWidth) => _Measure(
                  key: ValueKey('m$i'),
                  onHeight: (h) => heights[i] = h,
                  child: Container(
                    height: wantHeight(i),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEEEE),
                      border: Border.all(color: const Color(0xFFCCCCCC)),
                    ),
                    child: Center(child: Text('card $i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(heights.length, n, reason: '8 格都要量到');

      for (var r = 0; r * cols < n; r++) {
        final inRow = <int>[
          for (var i = r * cols; i < (r + 1) * cols && i < n; i++) i,
        ];
        final hs = inRow.map((i) => heights[i]!).toList();
        final mn = hs.reduce((a, b) => a < b ? a : b);
        final mx = hs.reduce((a, b) => a > b ? a : b);

        expect(
          (mx - mn).abs() <= 0.5,
          isTrue,
          reason: '★★ 第 $r 行必须等高（min=$mn max=$mx delta=${mx - mn}）。\n'
              '  实测值：${inRow.map((i) => 'card$i=${heights[i]}').join(", ")}\n'
              '  根因：`AnimatedSwitcher.layoutBuilder` 里的 `Stack` 默认\n'
              '        `fit: StackFit.loose` 会把 `Row(stretch)` 发下来的\n'
              '        **紧高度**降级成**松约束**，于是每张卡按自己的内容高度\n'
              '        收缩 —— 同一行就参差不齐了（用户报的正是这个）。\n'
              '  修法：`Stack(fit: StackFit.passthrough, ...)`。\n'
              '  ⚠️ 别删那个 `fit:` —— 它是默认值，删掉能编译、别的测试也不红，\n'
              '     但 26 张卡会立刻变回参差不齐（静默复发）。',
        );
      }
    });

    testWidgets('★ 同一行等高的同时，行高必须取"最高那张"（不能被压扁）',
        (tester) async {
      /*
       * 防"反向修错"：把行高固定成某个小值也能让同一行等高，
       * 但那会把内容裁掉。所以还要断言行高 == 该行最高内容高度。
       */
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final heights = <int, double>{};
      final theme = FTheme.neutral.light.desktop;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.toApproximateMaterialTheme(),
          builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReorderableCardGrid(
                itemCount: 4,
                onReorder: (_, __) {},
                itemBuilder: (context, i, dragHandle, cellWidth) => _Measure(
                  key: ValueKey('q$i'),
                  onHeight: (h) => heights[i] = h,
                  child: Container(
                    // 第 2 张最高（200），行高必须是 200
                    height: i == 1 ? 200.0 : 120.0,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEEEE),
                      border: Border.all(color: const Color(0xFFCCCCCC)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (var i = 0; i < 4; i++) {
        expect(
          (heights[i]! - 200.0).abs() <= 0.5,
          isTrue,
          reason: '★ 行高必须取该行**最高**内容（200），'
              '而不是被压扁。card$i 实测 ${heights[i]}',
        );
      }
    });
  });
}
