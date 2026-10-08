// ═══════════════════════════════════════════════════════════════════════
//  方向键焦点遍历 —— 哪些结构下有效、哪些无效（回归用）
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景（2026-09-23 TV 实测抓到的真 bug）
//
// TV 上按方向键，焦点**卡在源条那个 pill 上不动**：
// ```text
// 按 ↓ 前: Focus @(12,469) 187x71
// 按 ↓ 后: Focus @(12,469) 187x71   Δ=(0,0)   ✗
// ```
// 结果是**遥控器根本没法选片** —— 修复见 `lib/ui/spatial_nav.dart`。
//
// # 这个文件固化什么
//
// ① **Flutter 内建遍历在"裸树"里是好的** —— 所以问题不在 Flutter，
//    而在真实壳里有两个东西把它挡住了（见下）。
// ② **真实首页形状**（横向源条 + 纵向海报行）在有界尺寸下遍历正常 ——
//    这是我们期望的行为，作为回归基线。
// ③ **输入框守卫**：在 `TextField` 里方向键必须放行（否则用户没法移动光标）。
//
// # ⚠️ 已删除的几个诊断用例（别再写一遍）
//
// 排查时我写过 `fscaffold_*_test.dart` 四个文件，结论是：
// ```text
// flutter_test 里 FScaffold 的 child 拿到**无界高度**（实测 100000.0），
// 于是所有 cell 都堆在 y=0/100000/200000…，焦点矩形毫无意义。
// ```
// 也就是说**那些用例测的是 harness 假象，不是真实行为**。
// 真实的 FScaffold 行为只能在**真机**上量（TV 实测 4/0）。
// 已删除，避免以后有人看着它们"通过"而误以为覆盖了真实场景。
//
// # 已确证的两个真实阻塞原因（真机证据，不在本文件断言）
//
// ```text
// ① ←/→ 被 shell 的全局 HardwareKeyboard handler 提前消费
//    （它跑在焦点树派发**之前**，return true 就等于 preventDefault）
// ② ↓/↑ 落到 Scrollable 手里变成"滚页面"而不是"移焦点"
// ```
// 两者都由 `lib/ui/spatial_nav.dart` 显式接管方向键解决。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可测量位置的可聚焦块（显式 focusNode，可精确设焦点）
///
/// ⚠️ `InkWell` **不传** `focusNode` 时它内部的 `focusNode` 字段就是 null，
///    所以要显式传 —— 否则 `requestFocus()` 静默无效，
///    测试会"通过"但什么都没测到（我第一版就是这样，见 git 历史）。
class _Cell extends StatelessWidget {
  const _Cell({
    required this.node,
    required this.label,
    this.w = 100,
    this.h = 60,
  });

  final FocusNode node;
  final String label;
  final double w;
  final double h;

  @override
  Widget build(BuildContext context) => InkWell(
        focusNode: node,
        onTap: () {},
        child: SizedBox(width: w, height: h, child: Text(label)),
      );
}

/// 按方向键，打印焦点落到第几个 cell
Future<String> _press(WidgetTester tester, List<FocusNode> nodes) async {
  final trace = <String>[];
  for (final e in {
    'D': LogicalKeyboardKey.arrowDown,
    'R': LogicalKeyboardKey.arrowRight,
    'U': LogicalKeyboardKey.arrowUp,
  }.entries) {
    await tester.sendKeyEvent(e.value);
    await tester.pump();
    trace.add('${e.key}=#${nodes.indexWhere((n) => n.hasPrimaryFocus)}');
  }
  return trace.join(' ');
}

void main() {
  testWidgets('① 基线：Wrap + InkWell（有界尺寸）方向键能走', (t) async {
    final nodes = List.generate(6, (_) => FocusNode());
    addTearDown(() => nodes.forEach((n) => n.dispose()));

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Wrap(
            children: [
              for (var i = 0; i < nodes.length; i++)
                _Cell(node: nodes[i], label: '$i'),
            ],
          ),
        ),
      ),
    ));
    nodes[0].requestFocus();
    await t.pump();
    expect(nodes[0].hasPrimaryFocus, isTrue,
        reason: '焦点没设上 → 后面的测量都没有意义');

    final r = await _press(t, nodes);
    debugPrint('【① Wrap+InkWell】$r');
    /*
     * ⚠️ 断言要按**实测值**写，不能按"我以为的布局"写。
     *
     * 实测 trace：`D=#0 R=#1 U=#1`
     * 6 个 100x60 的 cell 在 800px 宽的视口里**排成一行**（Wrap 不换行），
     * 所以：
     * ```text
     * D=#0   下方没有东西 → 合法地不动
     * R=#1   同排右移 → 到第 2 个     ← 这才是本用例要验证的
     * U=#1   上方没有东西 → 合法地不动
     * ```
     * 我第一版把断言写成 `U=#0`（以为 ↑ 会回到第一个），
     * 那是**凭空假设布局**，与实测不符。
     */
    expect(r, contains('R=#1'), reason: '同一排内 → 应该到第 2 个');
    expect(r, contains('D=#0'), reason: '下方无元素 → ↓ 合法地不动');
    expect(r, contains('U=#1'), reason: '上方无元素 → ↑ 合法地不动');
  });

  testWidgets('② 垂直 ListView（有界）方向键能走', (t) async {
    final nodes = List.generate(9, (_) => FocusNode());
    addTearDown(() => nodes.forEach((n) => n.dispose()));

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var r = 0; r < 3; r++)
              Row(
                children: [
                  for (var c = 0; c < 3; c++)
                    _Cell(node: nodes[r * 3 + c], label: '$r-$c'),
                ],
              ),
          ],
        ),
      ),
    ));
    nodes[0].requestFocus();
    await t.pump();
    expect(nodes[0].hasPrimaryFocus, isTrue);

    final r = await _press(t, nodes);
    debugPrint('【② 垂直 ListView】$r');
    expect(r, contains('D=#3'), reason: '按 ↓ 应该到下一行第 1 个');
  });

  testWidgets('③ 真实首页形状（横向源条 + 纵向海报行）能走', (t) async {
    final nodes = List.generate(9, (_) => FocusNode());
    addTearDown(() => nodes.forEach((n) => n.dispose()));

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 3,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) =>
                    _Cell(node: nodes[i], label: '源$i', w: 120, h: 44),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  SizedBox(
                    height: 200,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var c = 0; c < 3; c++)
                          _Cell(node: nodes[3 + c], label: '0-$c', w: 100, h: 180),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
    nodes[0].requestFocus();
    await t.pump();
    expect(nodes[0].hasPrimaryFocus, isTrue);

    final r = await _press(t, nodes);
    debugPrint('【③ 源条+海报行】$r');
    /*
     * 实测 trace：`D=#3 R=#4 U=#1`
     * ```text
     * D=#3   源条(#0) → 下方的海报行第 1 个     ← 这正是 TV 上要的能力
     * R=#4   海报行内右移 → 海报行第 2 个
     * U=#1   回到源条第 2 个（横向对齐：源条 pill 120px，海报 100px）
     * ```
     * 三条都符合"遥控器能选片"的预期。
     *
     * ⚠️ 我第一版断言写成 `R=#1`（以为起始焦点会先横向走源条），
     *    但 `_press` 是**连续按 D/R/U** —— R 发生时焦点已经在海报行里了。
     *    断言必须按按键**顺序**推演，不能只看单个方向。
     */
    expect(r, contains('D=#3'), reason: '源条 ↓ 应该进到海报行（TV 选片的关键路径）');
    expect(r, contains('R=#4'), reason: '海报行内 → 应该到该行第 2 个');
    expect(r, contains('U=#1'), reason: '↑ 应该回到源条（横向对齐的那个）');
  });

  testWidgets('④ 输入框守卫：TextField 里方向键不抢', (t) async {
    /*
     * shell 的全局 handler 会在输入框里**放行**方向键
     * （`_isTypingInTextField()` 守卫）。
     * 这里验证"焦点在 TextField 上时，方向键不会把焦点带走" ——
     * 否则用户在搜索框里没法移动光标。
     */
    final cell = FocusNode();
    addTearDown(cell.dispose);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const TextField(autofocus: true),
            _Cell(node: cell, label: '其它'),
          ],
        ),
      ),
    ));
    await t.pump();

    // 确认焦点确实在输入框上
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull, reason: 'TextField autofocus 应该拿到焦点');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();

    expect(cell.hasPrimaryFocus, isFalse,
        reason: '焦点在输入框时，方向键不应该跳到其它控件上');
  });
}
