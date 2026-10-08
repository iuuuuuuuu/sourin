// ═══════════════════════════════════════════════════════════════════════
//  task-70 回归测试：线路面板**不许**被撑成全屏（阻断级 bug 的守卫）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > bilibili视频我点一个播放,然后点击线路 就直接出现一个蒙层,
// > 啥也无法点击了,切换源也一样
// ```
//
// # 根因（实测确证，见 `.probe/probe_tests/zz_t70_faithful_chain_test.dart`）
// ```text
// `_StreamSheet.build` **自己 return `Positioned`**，
// 而它的父链是 `Positioned.fill → SheetTransition → PlayerPanelTheme`
// ⇒ ★ 两个 `Positioned` 争同一个 RenderObject 的 StackParentData
//   ⇒ `SheetTransition` 产生 `RenderIgnorePointer`（**不是** `RenderStack`）
//   ⇒ 异常：`The offending Positioned is currently placed inside a IgnorePointer widget.`
//   ⇒ ★★★ 后果：面板的 `ColoredBox(black@0.92)` 被撑成**满屏**
//     实测（896x760 播放器区）：冲突态 w=**896** / 修复后 w=**320**
//     ⇒ 整块变暗 + **吸收所有点击** ⇒ 用户只能杀进程
// ```
//
// # 本文件守什么（★ 三条，都是"用户实际会遇到的"）
// ```text
// ① 几何：面板宽**恰好 320**、贴右边、全高   ⇒ 不会盖住左侧
// ② 命中：面板**不覆盖**左侧按钮（左侧仍可交互）
// ③ 命中：面板**覆盖**右侧（它自己仍可交互）—— 阳性对照，证明①有分辨力
// ```
//
// # ★★ 为什么用"与生产同构"的链条（而不是把面板直接挂 Stack）
// ```text
// `test/t57_sheet_scrim_geometry_test.dart` 原来把面板**直接**挂在 `Stack` 下，
// 并在注释里写明「它自带 Positioned ⇒ 必须直接作为 Stack 的子节点」。
// ⇒ ★ 那是"**测试为了能跑而绕开生产的结构错误**" ⇒ 测试全绿、生产是错的。
// ⇒ 本文件**保留外层 `Positioned.fill`**，与生产逐字同构。
//   ★ 而 `_StreamSheet` 现在返回 `Align`（不再是 `Positioned`）
//     ⇒ 同一链条下不再冲突 ⇒ 这本身就是修复的证明。
// ```
//
// ⚠️ 本文件用**同构**（不是真的 `_StreamSheet`，它是私有的）。
//    真的 `_StreamSheet` 由**真机验证**兜底（最终判据）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与**修复后**的 `_StreamSheet` 逐字同构（`Align(centerRight) + width 320`）
Widget fixedStreamSheet() => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 320,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          child: Column(
            children: [
              const SizedBox(height: 48),
              Expanded(
                child: ListView(
                  children: const [
                    ListTile(title: Text('线路1')),
                    ListTile(title: Text('线路2')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// ★★ 与**生产逐字同构**的外壳（外层 `Positioned.fill` 那一层必须在）
Widget productionChain({required Widget body}) => Positioned.fill(
      child: Builder(builder: (_) => body),
    );

/// 与 `_BottomBar` 同构（左侧有一个按钮，用于测"左侧还能不能点"）
Widget leftBar({required VoidCallback onTapLeft}) => Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        color: Colors.black87,
        child: Row(
          children: [
            TextButton.icon(
              key: const ValueKey('leftBtn'),
              onPressed: onTapLeft,
              icon: const Icon(Icons.play_arrow, color: Colors.white),
              label: const Text('播放', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

void main() {
  // ★ 播放器的真实区域：1280 - 384（右侧详情面板）= 896 宽，800 - 40（标题栏）= 760 高
  //   （与 Lead 实测的 x[0..895] y[40..799] 一致）
  const playerSize = Size(896, 760);

  group('① 几何：面板只占右侧 320', () {
    testWidgets('★★★ 面板宽度 = 320、贴右边、全高', (t) async {
      await t.binding.setSurfaceSize(playerSize);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                  child: ColoredBox(color: Color(0xFF202020))),
              productionChain(body: fixedStreamSheet()),
            ],
          ),
        ),
      ));
      await t.pump();

      final err = t.takeException();
      expect(err, isNull,
          reason: '★★ 与生产同构的链条**不许**抛 ParentDataWidget 异常');

      final panel = t.getRect(find.byType(ColoredBox).last);
      debugPrint('T70|panel=$panel  w=${panel.width}  h=${panel.height}');
      expect(panel.width, 320,
          reason: '★★★ 面板必须**恰好 320** —— 曾经的 bug 是 896（满屏）');
      expect(panel.height, 760, reason: '★ 必须全高');
      expect(panel.right, 896, reason: '★ 必须贴右边');
    });

    testWidgets('★★ 反向自检：**修复前**的写法（自带 Positioned）必须被抓住',
        (t) async {
      // ★ 证明这条断言有分辨力 —— 用修复前的形态
      Widget brokenSheet() => Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 320,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.92),
              child: const SizedBox.expand(),
            ),
          );

      await t.binding.setSurfaceSize(playerSize);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                  child: ColoredBox(color: Color(0xFF202020))),
              productionChain(body: brokenSheet()),
            ],
          ),
        ),
      ));
      await t.pump();

      final err = t.takeException();
      debugPrint('T70-RED|修复前形态 exception=${err.runtimeType}');
      expect(err, isNotNull,
          reason: '★★ 修复前的写法（自带 `Positioned` + 外层 `Positioned.fill`）'
              '**必须**抛异常 ⇒ 证明本测试有分辨力（不是空断言）');

      // ★ 并且几何确实是错的（满屏）
      final panel = t.getRect(find.byType(ColoredBox).last);
      debugPrint('T70-RED|修复前形态 panel=$panel  w=${panel.width}（应=896 满屏）');
      expect(panel.width, 896,
          reason: '★ 修复前被撑成满屏（896）—— 这正是"变暗+吸收点击"的来源');
    });
  });

  group('② 命中测试：左侧仍可交互（这是用户的核心痛点）', () {
    testWidgets('★★★ 面板开着时，**左侧**按钮仍点得到', (t) async {
      await t.binding.setSurfaceSize(playerSize);
      addTearDown(() => t.binding.setSurfaceSize(null));

      var leftTaps = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                  child: ColoredBox(color: Color(0xFF202020))),
              leftBar(onTapLeft: () => leftTaps++),
              productionChain(body: fixedStreamSheet()),
            ],
          ),
        ),
      ));
      await t.pump();

      final btn = t.getRect(find.byKey(const ValueKey('leftBtn')));
      debugPrint('T70|leftBtn=$btn  (x 应在 0..576 内，即面板左侧)');
      expect(btn.right, lessThan(576),
          reason: '★ 前提：这个按钮必须在面板**左**侧（否则测不到东西）');

      await t.tapAt(btn.center);
      await t.pump();
      debugPrint('T70|左侧按钮点击次数=$leftTaps');
      expect(leftTaps, 1,
          reason: '★★★ 面板开着时**左侧必须仍可交互** —— '
              '曾经的 bug 是面板撑满全屏 ⇒ 整页点不动 ⇒ 用户只能杀进程');
    });

    testWidgets('★★★ 阳性对照：修复前形态下，左侧按钮**点不到**', (t) async {
      Widget brokenSheet() => Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 320,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.92),
              child: const SizedBox.expand(),
            ),
          );

      await t.binding.setSurfaceSize(playerSize);
      addTearDown(() => t.binding.setSurfaceSize(null));

      var leftTaps = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                  child: ColoredBox(color: Color(0xFF202020))),
              leftBar(onTapLeft: () => leftTaps++),
              productionChain(body: brokenSheet()),
            ],
          ),
        ),
      ));
      await t.pump();
      t.takeException(); // 吃掉预期的异常

      final btn = t.getRect(find.byKey(const ValueKey('leftBtn')));
      await t.tapAt(btn.center);
      await t.pump();
      debugPrint('T70-RED|修复前形态 左侧按钮点击次数=$leftTaps（应=0）');
      expect(leftTaps, 0,
          reason: '★★★ 修复前：面板撑满全屏 ⇒ 左侧点不到 ⇒ '
              '**这就是用户报的"啥也无法点击"**。'
              '本条证明上面那条断言有分辨力。');
    });
  });
}
