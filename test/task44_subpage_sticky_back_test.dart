// ═══════════════════════════════════════════════════════════════════════
//  task-44 ④：设置二级页的**返回按钮**必须"随滚动固定到顶部"
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
// ```text
// 4.进入二级页应该要优化交互,比如 返回一开始是在左上方,随着页面下滑,然后固定在上面,
//   而不是随着下滑,就看不到了
// ```
// ⇒ ★ 用户要的是 **sticky**：往上滚之后，返回按钮**仍然可见**
//
// # 这个文件守什么
// ```text
// ① ★★ 滚到底之后，返回按钮**仍在视口内** —— 这是用户诉求的**直接**断言
// ② ★★ 滚动过程中（多个偏移）返回按钮**始终可见** —— 防"只在两端对"
// ③ 返回按钮**真的能返回**（不是画了个不可点的壳）
// ④ 内容确实**能滚动**（否则 ① 是"因为没滚"而假通过）
// ```
//
// # ★★★ 为什么 ④ 很重要（防"红度证明"本身失效）
// ```text
// 若内容**不可滚**，那"滚到底后返回按钮仍可见"会**平凡为真**
//   —— 它没滚，当然还看得见。
// ⇒ 所以必须**先证明内容真的滚动了**（滚动前后 offset 变了），
//   否则 ①② 是**假绿**。
// ```
//
// # 判据方式：用 **RenderBox 的实际屏幕位置**（不是"widget 在树里"）
// ```text
// `find.text('返回设置')` 能找到 ≠ 它**看得见** ——
//   它可能被滚出视口（仍在树里，但 y < 0）。
// ★ 本文件的判据统一用：
//     final box = tester.renderObject<RenderBox>(finder);
//     final top = box.localToGlobal(Offset.zero).dy;
//     expect(top >= 0 && top + box.size.height <= 视口高, isTrue);
// ```
// ★ 这条"在树里 ≠ 看得见"的区分，是本项目已在别处踩过的坑
//   （见 `VERIFY-LESSONS.md`：`find.byType` = 1 只证明 element 在）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/settings_sub_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 测试用的宿主（二级页需要 MaterialApp + 主题，与真实 push 环境一致）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 造一个**足够长、一定能滚动**的内容
List<Widget> _tallChildren({int n = 40}) => List.generate(
      n,
      (i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: SizedBox(height: 48, child: Text('内容行 $i')),
      ),
    );

/// 返回按钮的**屏幕 y 范围**（null = 不在树里）
({double top, double bottom})? _backButtonRect(WidgetTester tester) {
  final f = find.text('返回设置');
  if (f.evaluate().isEmpty) return null;
  final box = tester.renderObject<RenderBox>(f);
  final topLeft = box.localToGlobal(Offset.zero);
  return (top: topLeft.dy, bottom: topLeft.dy + box.size.height);
}

/// 取**内容滚动位置**
///
/// ⚠️ 不能走 `Scrollable.of(element(find.text('返回设置')))` ——
///    修好之后返回按钮**不在滚动区里**（这正是 sticky 的实现方式）⇒
///    那样写会抛 "no Scrollable ancestor"。
/// ★ 改成直接从第一个 `Scrollable` 的 state 取 —— 修前修后**都适用**。
double _scrollOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

void main() {
  group('task-44 ④ 二级页返回按钮 sticky', () {
    testWidgets('★★★ 滚到底之后，返回按钮**仍在视口内**', (tester) async {
      await tester.pumpWidget(_host(SettingsSubPage(
        title: '测试页',
        subtitle: '副标题',
        children: _tallChildren(),
      )));
      await tester.pumpAndSettle();

      final viewportH = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;

      // ① 先证明"内容真的能滚"（否则后面的断言平凡为真）
      //
      // ★ 用 `_scrollOffset` 而不是 `Scrollable.of(...)` —— 见它的注释
      final before = _scrollOffset(tester);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await tester.pumpAndSettle();

      final after = _scrollOffset(tester);
      expect(
        after, greaterThan(before + 100),
        reason: '★★ 前置：内容必须**真的滚动了** —— '
            '否则"滚到底后返回仍可见"会平凡为真（它没滚）。'
            '实测 before=${before.toStringAsFixed(1)} after=${after.toStringAsFixed(1)}',
      );

      // ② 核心断言：滚到底后，返回按钮仍在视口内
      final r = _backButtonRect(tester);
      expect(r, isNotNull, reason: '★ 返回按钮必须还在树里');
      expect(
        r!.top >= 0 && r.bottom <= viewportH,
        isTrue,
        reason: '★★★ 滚到底后返回按钮必须**仍然可见** '
            '（用户原话：「而不是随着下滑，就看不到了」）—— '
            '实测 top=${r.top.toStringAsFixed(1)} bottom=${r.bottom.toStringAsFixed(1)} '
            'viewportH=${viewportH.toStringAsFixed(1)}',
      );
    });

    testWidgets('★★ 滚动过程中（多个偏移）返回按钮**始终可见**', (tester) async {
      await tester.pumpWidget(_host(SettingsSubPage(
        title: '测试页',
        subtitle: '副标题',
        children: _tallChildren(),
      )));
      await tester.pumpAndSettle();

      final viewportH = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;

      for (final step in [200.0, 400.0, 800.0, 1600.0]) {
        await tester.drag(find.byType(Scrollable).first, Offset(0, -step));
        await tester.pumpAndSettle();

        final r = _backButtonRect(tester);
        expect(r, isNotNull, reason: '★ 偏移累计 $step 后返回按钮仍在树里');
        expect(
          r!.top >= 0 && r.bottom <= viewportH,
          isTrue,
          reason: '★★ 累计偏移 $step 后返回按钮必须仍在视口内 —— '
              '实测 top=${r.top.toStringAsFixed(1)} bottom=${r.bottom.toStringAsFixed(1)}',
        );
      }
    });

    testWidgets('★ 返回按钮**真的能返回**（不是不可点的壳）', (tester) async {
      // 用两层路由：push 一个二级页，点返回后应回到第一层
      await tester.pumpWidget(_host(Builder(builder: (context) {
        return Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsSubPage(
                  title: '测试页',
                  subtitle: '副标题',
                  children: _tallChildren(n: 5),
                ),
              ),
            ),
            child: const Text('打开二级页'),
          ),
        );
      })));
      await tester.tap(find.text('打开二级页'));
      await tester.pumpAndSettle();
      expect(find.text('返回设置'), findsOneWidget);

      await tester.tap(find.text('返回设置'));
      await tester.pumpAndSettle();
      expect(
        find.text('打开二级页'), findsOneWidget,
        reason: '★ 点返回必须真的回到上一层',
      );
      expect(find.text('返回设置'), findsNothing);
    });

    testWidgets('★★ Esc 仍能返回（键盘路径不能被 sticky 改坏）', (tester) async {
      await tester.pumpWidget(_host(Builder(builder: (context) {
        return Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsSubPage(
                  title: '测试页',
                  subtitle: '副标题',
                  children: _tallChildren(n: 5),
                ),
              ),
            ),
            child: const Text('打开二级页'),
          ),
        );
      })));
      await tester.tap(find.text('打开二级页'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.text('打开二级页'), findsOneWidget,
        reason: '★ Esc 必须仍能返回（外壳已有的键盘路径不能因 sticky 而失效）',
      );
    });
  });
}
