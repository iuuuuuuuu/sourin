// ═══════════════════════════════════════════════════════════════════════
//  方向键焦点遍历 —— 判定 Flutter 内建能力到哪一步
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景（2026-09-23 TV 实测抓到的真 bug）
//
// TV 上按方向键，焦点**卡在源条那个 pill 上不动**：
// ```text
// 按 ↓ 前: Focus @(12,483) 187x57
// 按 ↓ 后: Focus @(12,483) 187x57   Δ=(0,0)   ✗
// 按 → 前: Focus @(12,483) 187x57
// 按 → 后: Focus @(12,483) 187x57   Δx=0      ✗
// ```
// 结果是**遥控器根本没法选片** —— 而这正是原版
// `src/design/spatialNav.ts`（776 行）存在的原因。
//
// # 这个测试要回答的问题
//
// 修之前必须先分清是哪一种，否则就是盲改：
// ```text
// A. Flutter 内建的方向键遍历本来就能用 ——
//    是我的树里有东西挡住了（比如 shell 全局 ←/→ handler 吃掉了事件）
// B. Flutter 内建能力在这个树形里不工作 ——
//    必须像原版那样自己实现几何邻居算法
// ```
// 所以这里递进地测四种树形，看焦点到底在哪一层开始不动。
//
// ⚠️ 用 **material_ui** 的 MaterialApp（和真机一致）——
//    上一轮踩过"两套 Material 主题互相看不见"的坑，
//    这里如果 import 错了包，测出来的结论同样不可信。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

/// 造 n 个可聚焦方块，排成 rows×cols
List<FocusNode> _grid(int n) => List.generate(n, (_) => FocusNode());

Widget _gridWidget(List<FocusNode> nodes, {int cols = 3}) => Column(
      children: [
        for (var r = 0; r * cols < nodes.length; r++)
          Row(
            children: [
              for (var c = 0; c < cols && r * cols + c < nodes.length; c++)
                Focus(
                  focusNode: nodes[r * cols + c],
                  child: const SizedBox(width: 100, height: 100),
                ),
            ],
          ),
      ],
    );

/// 哪个 node 拿到了主焦点（-1 = 都没有）
int _which(List<FocusNode> nodes) =>
    nodes.indexWhere((n) => n.hasPrimaryFocus);

void main() {
  const arrows = {
    'right': LogicalKeyboardKey.arrowRight,
    'left': LogicalKeyboardKey.arrowLeft,
    'down': LogicalKeyboardKey.arrowDown,
    'up': LogicalKeyboardKey.arrowUp,
  };

  /// 依次按方向键，打印焦点序号变化
  Future<String> sweep(WidgetTester tester, List<FocusNode> nodes) async {
    final trace = <String>['start=${_which(nodes)}'];
    for (final e in arrows.entries) {
      await tester.sendKeyEvent(e.value);
      await tester.pump();
      trace.add('${e.key}=${_which(nodes)}');
    }
    return trace.join(' ');
  }

  testWidgets('① 裸 MaterialApp + Scaffold（基线：内建遍历能用吗）', (t) async {
    final nodes = _grid(6);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: _gridWidget(nodes)),
    ));
    nodes[0].requestFocus();
    await t.pump();
    debugPrint('【① 裸 MaterialApp】${await sweep(t, nodes)}');

    for (final n in nodes) {
      n.dispose();
    }
  });

  testWidgets('② 套 FTheme + FToaster + FScaffold（真实壳的形状）', (t) async {
    final nodes = _grid(6);
    final theme = FTheme.neutral.dark.desktop;

    await t.pumpWidget(MaterialApp(
      theme: theme.toApproximateMaterialTheme(),
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(child: child ?? const SizedBox()),
      ),
      home: FScaffold(child: _gridWidget(nodes)),
    ));
    nodes[0].requestFocus();
    await t.pump();
    debugPrint('【② FTheme+FScaffold】${await sweep(t, nodes)}');

    for (final n in nodes) {
      n.dispose();
    }
  });

  testWidgets('③ 全局 HardwareKeyboard handler 吃掉 ←/→（复现 shell 的写法）', (t) async {
    final nodes = _grid(6);
    final theme = FTheme.neutral.dark.desktop;

    // 复刻 shell.dart 的 _onGlobalKey：←/→ 直接返回 true（消费掉）
    bool handler(KeyEvent e) {
      if (e is! KeyDownEvent) return false;
      final k = e.logicalKey;
      if (k == LogicalKeyboardKey.arrowRight ||
          k == LogicalKeyboardKey.arrowLeft) {
        return true; // 消费，不往下传
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));

    await t.pumpWidget(MaterialApp(
      theme: theme.toApproximateMaterialTheme(),
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(child: child ?? const SizedBox()),
      ),
      home: FScaffold(child: _gridWidget(nodes)),
    ));
    nodes[0].requestFocus();
    await t.pump();
    debugPrint('【③ 全局吃掉 ←/→】${await sweep(t, nodes)}');

    for (final n in nodes) {
      n.dispose();
    }
  });

  testWidgets('④ 显式注册 DirectionalFocusIntent（候选修法）', (t) async {
    final nodes = _grid(6);
    final theme = FTheme.neutral.dark.desktop;

    await t.pumpWidget(MaterialApp(
      theme: theme.toApproximateMaterialTheme(),
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(child: child ?? const SizedBox()),
      ),
      home: FScaffold(
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                DirectionalFocusIntent(TraversalDirection.left),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                DirectionalFocusIntent(TraversalDirection.right),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                DirectionalFocusIntent(TraversalDirection.up),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DirectionalFocusIntent(TraversalDirection.down),
          },
          child: Actions(
            actions: {
              DirectionalFocusIntent: DirectionalFocusAction(),
            },
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: _gridWidget(nodes),
            ),
          ),
        ),
      ),
    ));
    nodes[0].requestFocus();
    await t.pump();
    debugPrint('【④ 显式 DirectionalFocus】${await sweep(t, nodes)}');

    for (final n in nodes) {
      n.dispose();
    }
  });
}
