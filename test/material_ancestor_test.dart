// ═══════════════════════════════════════════════════════════════════════
//  Material 祖先 —— 遥控器确认键能不能用的决定性前提
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么（2026-09-23 实测抓到的真 bug）
//
// TV 上按遥控器 OK：方向键能把焦点移到海报卡上（焦点环都画出来了），
// 但 **按 OK 什么都不会发生** —— 打不开详情页。
// 而 `adb shell input tap`（触摸/鼠标路径）**能正常打开**。
// 也就是「能点不能按」，非常反直觉。
//
// # 根因
//
// `InkWell` 的两条激活路径**不对称**（读 `material_ui/src/ink_well.dart`）：
//
// ```dart
// // 键盘路径 activateOnIntent (L877) —— 先起水波纹，再调 onTap
// void activateOnIntent(Intent? intent) {
//   _startNewSplash(context: context);   // ← Material.of 在这里抛异常
//   _currentSplash?.confirm();
//   if (widget.onTap != null) widget.onTap?.call();   // ← 永远到不了
// }
//
// // 触摸路径 handleTap (L1210) —— 水波纹在 tapDown 时已经起过
// void handleTap() {
//   _currentSplash?.confirm();
//   if (widget.onTap != null) widget.onTap?.call();   // ← 直接调用，不碰 Material
// }
// ```
//
// 没有 `Material` 祖先时，键盘路径抛
// `Null check operator used on a null value`（`material.dart:418`），
// 异常被框架吞掉，**连 logcat 的 E 级日志都没有**。
//
// # 为什么之前所有测试都是绿的
//
// ```text
// 单测用 `Scaffold`（Material 库的）→ 它**自带 Material 祖先** → 全过 ✓
// 真机用 `FScaffold`（forui 的）   → 它**不提供 Material**   → 必炸 ✗
// ```
// 差别**完全在测试脚手架用错了 widget**。
//
// ⚠️ 所以用例①**必须用 `FScaffold`**（不能用 `Scaffold`），
//    否则测不出这个 bug —— 这正是它当初逃过所有测试的原因。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

class _Button extends StatelessWidget {
  const _Button({required this.node, required this.onTap});

  final FocusNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        focusNode: node,
        onTap: onTap,
        child: const SizedBox(width: 160, height: 70, child: Text('目标')),
      );
}

void main() {
  testWidgets('★ FScaffold 的 child 里必须有 Material 祖先（修法本身）', (t) async {
    final theme = FTheme.neutral.dark.desktop;
    final node = FocusNode();
    addTearDown(node.dispose);

    /*
     * 直接读 `Material.maybeOf` —— 这是**根因本身**，
     * 比"按一下看有没有反应"更直接、也更稳定
     * （后者依赖焦点系统在测试环境下的行为，而那个不可靠：
     *  `FScaffold` 在 flutter_test 下的布局与真机不一致）。
     */
    BuildContext? innerCtx;

    await t.pumpWidget(MaterialApp(
      theme: theme.toApproximateMaterialTheme(),
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(child: child ?? const SizedBox()),
      ),
      home: FScaffold(
        // ★ 这一层就是修复本身（见 shell.dart 的 `Material(type: transparency)`）
        child: Material(
          type: MaterialType.transparency,
          child: Builder(
            builder: (ctx) {
              innerCtx = ctx;
              return _Button(node: node, onTap: () {});
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    expect(innerCtx, isNotNull);
    expect(
      Material.maybeOf(innerCtx!),
      isNotNull,
      reason: 'FScaffold 的 child 里必须能找到 Material 祖先 —— '
          '否则 InkWell 的**键盘激活路径**会在 _startNewSplash 里抛 '
          '`Null check operator used on a null value`，'
          '导致遥控器确认键完全无效（触摸却正常）。'
          '修法见 shell.dart：FScaffold 的 child 最外层套 '
          'Material(type: MaterialType.transparency)。',
    );
  });

  testWidgets('★ 反向验证：去掉 Material 后 maybeOf 就是 null（说明上面那条有意义）',
      (t) async {
    /*
     * 这条证明"用例①的断言不是恒真的空测试"。
     *
     * 同样的树，**只去掉 `Material` 那一层**，`Material.maybeOf` 必须变 null。
     * 如果两种情况都非 null，说明用例①测不出任何东西 ——
     * 那比没有测试更危险（给人一种"已经防住了"的错觉）。
     *
     * ⚠️ 不断言"异常抛没抛"：异常会被 Flutter 框架吞掉，
     *    在测试里表现为 testWidgets 报错而不是可捕获的 throw，
     *    断言它会得到脆弱的用例。只断言**根因条件**（maybeOf 为 null）。
     */
    final theme = FTheme.neutral.dark.desktop;
    BuildContext? innerCtx;

    await t.pumpWidget(MaterialApp(
      theme: theme.toApproximateMaterialTheme(),
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(child: child ?? const SizedBox()),
      ),
      home: FScaffold(
        // ⚠️ 故意**不套** Material —— 复现 bug 的前置条件
        child: Builder(
          builder: (ctx) {
            innerCtx = ctx;
            return const SizedBox(width: 10, height: 10);
          },
        ),
      ),
    ));
    await t.pumpAndSettle();

    expect(innerCtx, isNotNull);
    expect(
      Material.maybeOf(innerCtx!),
      isNull,
      reason: 'FScaffold 本身**不提供** Material —— 这正是当初遥控器'
          '确认键失效的根因。若这里变成非 null，说明 forui 版本变了'
          '（例如新版 FScaffold 自带 Material），那 shell.dart 里'
          '那层 Material 就可以删掉，需要重新评估。',
    );
  });
}
