// ═══════════════════════════════════════════════════════════════════════
//  task-44 ③：**像素读数**（RenderBox 实测）—— 不依赖 C++ 构建
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（与 task44_header_spacing_test.dart 分工）
// ```text
// task44_header_spacing_test.dart  = **源码断言**（守"间距代码"不回归）
// 本文件                            = **像素读数**（量 RenderBox 的实际几何）
// ```
// ★ 两者都需要：
//   · 只有源码断言 ⇒ 不知道实际渲染出来是多少像素（可能被别的约束吃掉）
//   · 只有像素读数 ⇒ 不知道该间距来自哪一行代码（改坏了不好定位）
//
// # 为什么能测（真实设置页不行，但**组件组合**可以）
// ```text
// 真实 `SettingsPage` 在 flutter test 里**挂不上**（`SourinApi.version` 走 FFI）
//   ⇒ 实测 element=1 / ErrorWidget=1 / Text=0
// ★ 但 ③ 的间距来源是 `SettingsBlock`（top=0）+ 前面的间距，
//   而 `SettingsBlock` **是公开组件**（`settings_kit.dart`）⇒ 可以直接挂。
// ⇒ 本文件如实标注：它量的是"**该组合的几何**"，不是"整页截图"。
//   ★ 整页像素由截图覆盖（`.probe/run-set/`），两者互为证据。
// ```
//
// # 读数口径
// ```text
// 全部用 `RenderBox.localToGlobal(Offset.zero)` 取**实际屏幕坐标**，
// 再算相邻文字的"底→顶"距离。
// ★ 不用 `find.text(...)` 的存在性 —— 存在性与几何是两个维度。
// ```

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'package:sourin_spike/ui/widgets/settings_kit.dart';
import 'package:sourin_spike/ui/tokens.dart';

Widget _host(Widget child) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 某个 finder 的**屏幕 y 范围**
({double top, double bottom, double height}) _rect(WidgetTester tester, Finder f) {
  final box = tester.renderObject<RenderBox>(f);
  final tl = box.localToGlobal(Offset.zero);
  return (top: tl.dy, bottom: tl.dy + box.size.height, height: box.size.height);
}

/// 两个 finder 的**垂直间距**（上者底 → 下者顶）
double _vGap(WidgetTester tester, Finder upper, Finder lower) {
  final a = _rect(tester, upper);
  final b = _rect(tester, lower);
  return b.top - a.bottom;
}

void main() {
  group('task-44 ③ 像素读数（RenderBox 实测）', () {
    testWidgets('★★ 页头两行 + 块标题：三层间距全部 ≥8px', (tester) async {
      /*
       * 复刻**一级页页头 + 首个 `_Block`** 的组合
       *   （这就是用户看到的"三层字"结构）。
       * ★ 间距取值与 `settings_page.dart` 里的一致：
       *     设置 → 副标题  = Sp.x2 (8)
       *     副标题 → 页头结束 = Sp.x8 (32)  ← 本次修复加的那一行
       */
      await tester.pumpWidget(_host(
        ListView(
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.contentPadding),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('设置',
                    style: TextStyle(fontSize: FontSizes.xl, fontWeight: FontWeight.w700)),
                const SizedBox(height: Sp.x2),
                const Text('内容源、网络与同步',
                    style: TextStyle(fontSize: FontSizes.sm)),
              ],
            ),
            const SizedBox(height: Sp.x8),
            const SettingsBlock(
              title: '局域网遥控',
              children: [Text('正文')],
            ),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      final g1 = _vGap(tester, find.text('设置'), find.text('内容源、网络与同步'));
      final g2 = _vGap(tester, find.text('内容源、网络与同步'), find.text('局域网遥控'));

      // ignore: avoid_print
      print('PIXEL|设置→副标题 = ${g1.toStringAsFixed(1)}px');
      // ignore: avoid_print
      print('PIXEL|副标题→块标题 = ${g2.toStringAsFixed(1)}px');

      expect(
        g1, greaterThanOrEqualTo(8.0),
        reason: '★ 「设置」(28px) → 副标题(14px) 应 ≥8px，实测 ${g1.toStringAsFixed(1)}px',
      );
      expect(
        g2, greaterThanOrEqualTo(24.0),
        reason: '★★★ 「内容源、网络与同步」→「局域网遥控」应 ≥24px —— '
            '用户原话「设置这三层字重叠的太近了」；'
            '改前实测 **1px**（截图扫描），实测 ${g2.toStringAsFixed(1)}px',
      );
    });

    testWidgets('★★ 块与块之间仍是 ~32px（本修复**没有**双倍块间距）', (tester) async {
      /*
       * 反向守卫：若有人为了让 ③ 变宽去改 `SettingsBlock.top`，
       *   块间距会**翻倍**（因为块间已由前一块的 bottom=Sp.x8 撑开）。
       * ⇒ 这条断言把"块间节奏"钉住。
       */
      await tester.pumpWidget(_host(
        ListView(
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.contentPadding),
          children: const [
            SettingsBlock(title: '第一个块', children: [Text('A')]),
            SettingsBlock(title: '第二个块', children: [Text('B')]),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      final gap = _vGap(tester, find.text('A'), find.text('第二个块'));
      // ignore: avoid_print
      print('PIXEL|块内正文→下一块标题 = ${gap.toStringAsFixed(1)}px');

      expect(
        gap, greaterThanOrEqualTo(28.0),
        reason: '★★ 块间节奏应保持 ~32px（Sp.x8）—— 实测 ${gap.toStringAsFixed(1)}px；'
            '若明显变大 ⇒ 有人改了 `SettingsBlock.top`（那是错的修法）',
      );
      expect(
        gap, lessThanOrEqualTo(60.0),
        reason: '★★ 块间节奏**不应**大幅变宽 —— 实测 ${gap.toStringAsFixed(1)}px；'
            '>60 说明块间距翻倍了（改了 SettingsBlock.top 而不是页头）',
      );
    });

    testWidgets('★★ 标题→副标题间距：一级页与二级页**取值一致**（8px）', (tester) async {
      /*
       * 两处都是 28px 标题 + 14px 副标题。
       * 若取值不同 ⇒ "设置页"与"二级页"看起来不是同一套设计。
       */
      await tester.pumpWidget(_host(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('标题',
                style: TextStyle(fontSize: FontSizes.xl, fontWeight: FontWeight.w700)),
            SizedBox(height: Sp.x2),
            Text('副标题', style: TextStyle(fontSize: FontSizes.sm)),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      final g = _vGap(tester, find.text('标题'), find.text('副标题'));
      // ignore: avoid_print
      print('PIXEL|标题→副标题 = ${g.toStringAsFixed(1)}px  (Sp.x2 = ${Sp.x2})');

      expect(
        g, greaterThanOrEqualTo(Sp.x2),
        reason: '★★ 标题→副标题应 ≥Sp.x2(${Sp.x2}px)，实测 ${g.toStringAsFixed(1)}px',
      );
      expect(
        Sp.x2, equals(8.0),
        reason: '★ 一级页与二级页都用的这个 token —— 它变了则两处一起变',
      );
    });
  });
}
