// ═══════════════════════════════════════════════════════════════════════
//  确认键（遥控器 OK）能否激活焦点项
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独测（2026-09-23 TV 实测留下的疑点）
//
// 真实按键实测已确认**方向键能把焦点移到海报卡上**：
// ```text
// #1 Arrow Down → 海报行 rect=(36,101,184,367)   ✓
// ```
// 但设备上按 OK 时**没看到详情页打开**，需要分开验证
// "方向键移动焦点"和"确认键激活"这两件事。
//
// # 本文件证明什么
//
// `Enter` / `Select`（遥控器 OK）/ `Space` 三个键**都能激活 `InkWell`** ——
// 即 Flutter + material_ui 的默认快捷键映射是正确的，
// **我们不需要额外注册任何快捷键**。（实测 `Enter=1 Select=1 Space=1`）
//
// ★ `Select` 是关键：遥控器 OK 在 Android 上是 `KEYCODE_DPAD_CENTER = 23`，
//   Flutter 的 `services/keyboard_maps.g.dart:38` 把它映射成
//   `LogicalKeyboardKey.select`，而 `widgets/app.dart:1269` 有
//   `SingleActivator(select): ActivateIntent()`。这条链必须是通的，
//   否则**遥控器永远打不开内容**。
//
// # ⚠️ 本文件不测 FScaffold 之下的行为（有明确理由）
//
// 试过了，结论是**这个 harness 测不出可信结论**：
// ```text
// flutter_test 里 FScaffold 的 child 布局异常（早期版本甚至抛异常），
// requestFocus() 拿不到主焦点（hasPrimaryFocus=false），
// 而真机 TV 实测焦点明明能移（4/0）。
// ```
// 也就是说 FScaffold 在测试环境下的焦点行为**与真机不一致**。
// 对它写断言只会得到"假失败"或"假通过" —— 两种都比没有测试更糟。
// 真实壳里的激活由**设备日志**覆盖（`tv_realkey_probe.dart`：
// 祖先 Actions=3 / Shortcuts=3 / `任一层绑了Activate=true`）。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  testWidgets('Enter / Select（遥控器 OK）/ Space 都能激活 InkWell', (t) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: _Button(node: node, onTap: () => taps++)),
    ));
    await t.pumpAndSettle();

    node.requestFocus();
    await t.pump();
    expect(node.hasPrimaryFocus, isTrue, reason: '焦点没设上，后面的测量无意义');

    Future<int> countFor(LogicalKeyboardKey key) async {
      taps = 0;
      await t.sendKeyEvent(key);
      await t.pump();
      return taps;
    }

    final enter = await countFor(LogicalKeyboardKey.enter);
    final select = await countFor(LogicalKeyboardKey.select);
    final space = await countFor(LogicalKeyboardKey.space);

    debugPrint('【激活】Enter=$enter Select=$select Space=$space');

    expect(enter, 1, reason: 'Enter 应该激活一次');
    expect(select, 1,
        reason: 'Select（遥控器 OK）应该激活一次 —— TV 上打不开内容就是这里断了');
    expect(space, 1, reason: 'Space 应该激活一次');
  });

  testWidgets('方向键会移走焦点（不会被激活逻辑吞掉）', (t) async {
    /*
     * 反向对照：方向键不应该触发激活。
     *
     * 如果 `→` 也算了 tap，说明"移动"和"激活"两条路混在一起了 ——
     * 用户每走一格就会误开一个内容。
     */
    var taps = 0;
    final nodes = List.generate(2, (_) => FocusNode());
    addTearDown(() => nodes.forEach((n) => n.dispose()));

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            for (var i = 0; i < 2; i++)
              _Button(node: nodes[i], onTap: () => taps++),
          ],
        ),
      ),
    ));
    await t.pumpAndSettle();

    nodes[0].requestFocus();
    await t.pump();

    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();

    expect(taps, 0, reason: '按方向键**不应该**激活任何东西');
    expect(nodes[1].hasPrimaryFocus, isTrue, reason: '→ 应该把焦点移到第 2 个');
  });
}
