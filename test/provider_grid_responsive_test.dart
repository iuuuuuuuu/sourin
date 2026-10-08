// ═══════════════════════════════════════════════════════════════════════
//  JS 插件 / 内容源：响应式多列网格 + 拖动排序（2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（两条）
//
// ```text
// 1.区块合并对了,但是不要一个一行
// 3.js插件还没改成一行多个的显示(根据宽度动态处理显示)
// ```
//
// # 这个文件锁住什么
//
// ```text
// ① 宽屏多列    —— 1280 下同一行 ≥2 张卡（dx 不同、dy 相同）
// ② 宽度驱动    —— 列数是**算**出来的，不是写死的（400 → 1 列）
// ③ 拖动排序    —— 拖到别的格子会调 onReorder，且下标语义与
//                  ReorderableListView.onReorderItem 一致（不再 -= 1）
// ④ 卡片 ↑↓     —— 按钮仍在（网格换掉后不能连它一起弄丢）
// ⑤ 不破坏成果  —— boxed:false / _panels 无 Divider / _FailedPlugin
// ```
//
// ⚠️ 为什么 ② 用**纯函数**断言而不是渲染：
//    `ReorderableCardGrid.columnsFor` 是 static 纯函数，
//    直接算术断言比"缩窗口量渲染"更稳（且能覆盖极端宽度）。
//    渲染级验证见 `zz_grid_render_test.dart`（真核心 + 隔离数据目录）。
//
// ⚠️ 拖动用**真手势**（`tester.drag`）而不是直接调 `onReorder` ——
//    后者只能证明"回调接对了"，证明不了"拖得动"。
//    本项目的教训：`healthSweep()` 的包装一直存在、调用点却是 0，
//    光断言"有这个回调"是抓不到这类问题的。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/reorderable_card_grid.dart';

void main() {
  group('① 列数由宽度算出来（纯函数，不渲染）', () {
    test('★★ 1280 窗口 → **4 列**（用户 2026-09-25 要求「一行还可以多占一个」）', () {
      /*
       * 窗口 1280 − `_Block` 的 contentPadding 24×2 = **可用宽 1232**
       * （不是 1280！用窗口宽算会多 48px —— 见 `columnsFor` 的注释）
       *
       * ```text
       * floor((1232 + 12) / (290 + 12)) = floor(1244/302) = 4
       * → 每列 (1232 - 3*12) / 4 = 299px
       * ```
       *
       * # 用户原话（这是从 3 列改成 4 列的直接依据）
       * > js插件这个尺寸还是太大了,在缩小点,一行我觉得还可以多占一个
       *
       * 上一轮 min=400 → 3 列（每列 402.67px）；这一轮 min=290 → 4 列（每列 299px）。
       */
      expect(ReorderableCardGrid.columnsFor(1232), 4);
    });

    test('★★ 窄屏 400 窗口 → 1 列（用户要的「根据宽度动态处理」）', () {
      // 窗口 400 − 48 = 352 可用宽 → floor(364/302) = 1
      expect(ReorderableCardGrid.columnsFor(352), 1);
      // 手机常见的 360 逻辑宽 → 312
      expect(ReorderableCardGrid.columnsFor(312), 1);
    });

    test('★ 900 窗口 → 2 列（中屏过渡）', () {
      // 900 − 48 = 852 → floor(864/302) = 2
      expect(ReorderableCardGrid.columnsFor(852), 2);
    });

    test('★ 列数随宽度**单调不减**（不会有"宽了反而少一列"）', () {
      /*
       * 这条防的是"除错了"这类 bug：`/` 写成 `*`、
       * 或者 `+ spacing` 加错位置，都可能让某个宽度区间反常。
       * 单调性是最基本的不变量，值得锁住。
       */
      var prev = 1;
      for (var w = 300.0; w <= 2400; w += 2) {
        final n = ReorderableCardGrid.columnsFor(w);
        expect(n, greaterThanOrEqualTo(prev),
            reason: '宽 ${w}px 时列数 $n 比更窄时的 $prev 还少 —— 算错了');
        expect(n, greaterThanOrEqualTo(1), reason: '至少一列');
        prev = n;
      }
    });

    test('★ 每列宽度都不小于 kMinCardWidth（网格侧的意图）', () {
      /*
       * ⚠️ **注意这条断言的含义**：它保证的是"网格不会切出比
       *    `kMinCardWidth` 更窄的列"，**不是**"卡片能塞进这么窄的列"。
       *
       * 卡片内部横排实测需要 ~402px（`24+22+30+12+156+8+264`），
       * 而 4 列时每列只有 299px —— 差得很远。兜住它的是
       * **卡片自己的响应式换行**（窄格子时按钮换到第二行，
       * 见 `settings_page._cardWideMinWidth`）。
       *
       * 而且本轮还**精简了卡片内容**（去掉冗余的「JS 插件」chip、
       * 版本号移到描述行），把窄版的宽度预算拉开 ——
       * 那笔账记在 `settings_page._nameRow` 的注释里。
       *
       * 真实"不溢出"的验证在 `.probe/probe_tests/zz_task20_probe_test.dart`
       * 里（真核心 + 隔离数据目录，实测 excs=0）。
       */
      for (final w in [400.0, 848.0, 1232.0, 1800.0, 2400.0, 3000.0]) {
        final n = ReorderableCardGrid.columnsFor(w);
        final each = (w - (n - 1) * 12) / n;
        expect(each, greaterThanOrEqualTo(kMinCardWidth - 0.001),
            reason: '可用宽 ${w}px 分成 $n 列，每列只有 ${each}px '
                '< $kMinCardWidth —— 比配置的下限还窄');
      }
    });

    test('★ 边界：0 / 负数宽度也要返回 1 而不是崩或 0', () {
      /*
       * `LayoutBuilder` 在某些父级下会给出 `maxWidth = 0`
       * （例如被放进一个 zero-size 的测试容器）。
       * 那时 `floor()` 会得 0，`Expanded` 分 0 列 → 白屏。
       */
      expect(ReorderableCardGrid.columnsFor(0), 1);
      expect(ReorderableCardGrid.columnsFor(-100), 1);
    });

    test('★★ 290 是**倒推**出来的（1280 下必须够 4 列），不是随便写的数', () {
      /*
       * 反解过程（见 `kMinCardWidth` 的文档）：
       * ```text
       * 要 columnsFor(1232) >= 4
       *   ⇔ floor((1232+12)/(min+12)) >= 4
       *   ⇔ min + 12 <= 311
       *   ⇔ min <= 299
       * 取 290 → 留 9px 余量
       * ```
       * ⚠️ 这个断言把"两个数之间的关系"锁住：
       *    有人把 kMinCardWidth 改成 300，4 列就会掉回 3 列 ——
       *    那正好是用户这次要求修掉的东西。改常量必须同时看这里。
       */
      expect(kMinCardWidth, 290,
          reason: '★ 改这个值前先确认 1280 下仍是 4 列（见 kMinCardWidth 文档）');
      // 而且 300 就是分界线 —— 刚好卡住"不许退化成 3 列"
      expect(ReorderableCardGrid.columnsFor(1232), 4);
      expect(
        ReorderableCardGrid.columnsFor(1232, minItemWidth: 300),
        3,
        reason: '★ 300 会掉回 3 列 —— 这正是 290 而不是 300 的原因',
      );
    });
  });

  group('② 拖动排序（真手势）', () {
    /// 挂一个最小可用的网格（3 张定宽卡片）
    Future<List<int>> pumpGrid(
      WidgetTester tester, {
      double width = 1280,
    }) async {
      final reordered = <int>[];
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: ReorderableCardGrid(
                itemCount: 3,
                onReorder: (a, b) => reordered.addAll([a, b]),
                itemBuilder: (context, i, handle, cellWidth) => Container(
                  key: ValueKey('card$i'),
                  color: const Color(0xFF222222),
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [handle, Text('卡$i')]),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return reordered;
    }

    testWidgets('★★ 拖第 0 张到第 2 格 → onReorder(0, 2)', (tester) async {
      /*
       * 语义必须与 `ReorderableListView.onReorderItem` 一致：
       * **newIndex 已经是目标位**，调用方不要再 `-= 1`。
       * `settings_page._onReorderProviders` 的注释专门讲过这条
       *（`onReorder` 要减、`onReorderItem` 不用减，混用会"跳过一格"）。
       */
      final got = await pumpGrid(tester);

      // 抓第 0 张的把手，拖到第 2 张的中心
      final handle = find.byIcon(Icons.drag_indicator).at(0);
      final target = tester.getCenter(find.byKey(const ValueKey('card2')));

      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(got, isNotEmpty, reason: '★ 拖动必须真的触发 onReorder（拖不动就是回归）');
      expect(got.sublist(0, 2), [0, 2],
          reason: '★ 拖到第 2 格应报 (0, 2) —— 目标位语义，不要再 -= 1');
    });

    testWidgets('★ 拖到自己身上**不触发**（避免白写一次盘）', (tester) async {
      /*
       * `_onReorderProviders` 里有 `if (newIndex == oldIndex) return;`，
       * 但那道是给程序调用兜底的。UI 这层也该挡住 ——
       * 否则每次轻点把手都走一遍 setProviderOrder。
       */
      final got = await pumpGrid(tester);
      final handle = find.byIcon(Icons.drag_indicator).at(1);
      final c = tester.getCenter(handle);

      final gesture = await tester.startGesture(c);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(c);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(got, isEmpty, reason: '★ 原地放下不该触发重排');
    });

    testWidgets('★★ 每张卡都有一个把手（否则那张卡拖不动）', (tester) async {
      await pumpGrid(tester);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
    });
  });

  group('②b ★★ 拖动**实时预览**（用户要「有动画那个效果」）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * 用户原话
     * ══════════════════════════════════════════════════════════════════
     * > js插件拖动的时候我希望能实时预览 就是有动画那个效果
     *
     * # 这条测的就是"实时"二字
     *
     * ```text
     * 松手才换位   → 拖动过程中其他卡一动不动，松手瞬间整块跳变（廉价）
     * 实时预览     → 拖动中其他卡**当场让位**（与 ReorderableListView 一致）
     * ```
     *
     * ⚠️ 所以断言必须在**手势还按着的时候**量（`gesture.up()` **之前**）。
     *    松手之后再量，两种实现的结果是一样的 —— 那样等于没测到"实时"。
     *    这是本 group 唯一的关键点，写成别的形式都会变成假绿。
     *
     * # 怎么判定"让位了"
     *
     * 2 列、4 张卡 → 格子是 [0][1] / [2][3]。
     * 把**第 0 张**拖到**第 1 格**，预览顺序变成 `[1, 0, 2, 3]`：
     * ```text
     * 拖动前：  cell0=card0(左)   cell1=card1(右)
     * 拖动中：  cell0=card1(左)   cell1=card0(右)   ← 两者**左右互换**
     * ```
     * 于是"card1 的 dx 从大于 card0 变成小于 card0"就是
     * **让位发生的直接证据**（量的是同一批 widget 的位置，不是数量）。
     */

    /// 挂一个 2 列、4 张卡的网格
    Future<void> pumpFour(WidgetTester tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              child: ReorderableCardGrid(
                itemCount: 4,
                onReorder: (a, b) {},
                itemBuilder: (context, i, handle, cellWidth) => Container(
                  key: ValueKey('card$i'),
                  // 固定高，避免 intrinsic 高度差异干扰 rect 比较
                  height: 80,
                  color: const Color(0xFF222222),
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [handle, Text('卡$i')]),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('★★★ 拖动中（未松手）其他卡片就**让位** —— 左右互换', (tester) async {
      await pumpFour(tester);

      /*
       * ⚠️ 用 `.first`：`AnimatedSwitcher` 过渡期间同一张卡可能短暂
       *    存在两份（旧内容淡出 + 新内容淡入）。量位置时取第一个即可，
       *    不影响"让位"这个结论（两份在同一格里，位置相同）。
       */
      Rect rectOf(String k) =>
          tester.getRect(find.byKey(ValueKey(k)).first);

      final r0a = rectOf('card0');
      final r1a = rectOf('card1');
      expect(r0a.left, lessThan(r1a.left),
          reason: '前置：拖动前 card0 应在 card1 **左边**（否则下面的断言无意义）');

      // 抓 card0 的把手（第一张的把手），按住不放
      final handle = find.byIcon(Icons.drag_indicator).at(0);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      // 让 Draggable 进入拖动状态（它要一帧才认）
      await tester.pump(const Duration(milliseconds: 50));

      // 移到 card1 的中心 —— 触发第 1 格的 DragTarget.onMove
      await gesture.moveTo(rectOf('card1').center);
      await tester.pump(const Duration(milliseconds: 50));
      // 让 AnimatedSwitcher 的 180ms 切换动画跑完（**仍然按着**）
      await tester.pump(const Duration(milliseconds: 250));

      final r0b = rectOf('card0');
      final r1b = rectOf('card1');

      print('PREVIEW before: card0.dx=${r0a.left} card1.dx=${r1a.left}');
      print('PREVIEW during: card0.dx=${r0b.left} card1.dx=${r1b.left}');

      /*
       * ★ 核心断言：**手势还按着**，两张卡已经换了左右位置。
       * 这就是"实时预览"—— 不是松手后才换。
       */
      expect(r1b.left, lessThan(r0b.left),
          reason: '★★ 拖动中（未松手）card1 就该挪到左边让位 —— '
              '若这里失败说明还是"松手才换位"，即用户说的没有实时预览');

      // 再确认位置真的**变了**（不是本来就这样）
      expect(r0b.left, isNot(equals(r0a.left)),
          reason: '★ card0（被拖的那张）也应移动到第 1 格的位置');

      // 收尾：松手，把状态清干净（否则 tearDown 时还有活动手势）
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('★★ 让位时**新旧内容交叉淡化**（真有过渡动画，不是硬切）', (tester) async {
      /*
       * ══════════════════════════════════════════════════════════════════
       * ⚠️ 这条测试写过三版，前两版都是**假绿** —— 记下来避免重犯
       * ══════════════════════════════════════════════════════════════════
       *
       * ```text
       * 第 1 版：断言"卡片外存在 FadeTransition"
       *   → 静止时 MaterialApp 路由 + AnimatedOpacity 就产生 6~8 个
       *   → 恒真，等于没测
       *
       * 第 2 版：断言"卡片外存在 opacity 在 (0,1) 的值"
       *   → 取到 0.931，**看着绿了**
       *   → ★ 但变异测试发现：把 AnimatedSwitcher **整个删掉**，
       *     那个中间值**依然出现**（它来自同一格里 AnimatedOpacity
       *     的拖动化淡）→ 假绿
       * ```
       *
       * # 第 3 版（现在）：直接观测 `AnimatedSwitcher` 的 **outgoing 子项**
       *
       * 读 SDK `animated_switcher.dart`：子项 key 变了 →
       * `_addEntryForNewChild(animate: true)` → 旧子项进 `_outgoingWidgets`
       *（仍在树上、由动画驱动淡出）→ `layoutBuilder(current, previous)`
       * 收到 **previous 非空**。
       *
       * 所以唯一可靠的判据是"问 layoutBuilder 有没有收到 outgoing"。
       * 生产代码为此留了 `onSwitchObserved`（默认 null，零开销）——
       * 见它的文档，那里也记着上面两版假绿的教训。
       *
       * 变异验证：
       * ```text
       * · 保留 AnimatedSwitcher(180ms)   → 收到 outgoing  ✓ 绿
       * · 删掉 AnimatedSwitcher          → 收不到        ✗ 红
       * ```
       */
      final outgoingSeen = <int>[];

      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              child: ReorderableCardGrid(
                itemCount: 4,
                onReorder: (a, b) {},
                onSwitchObserved: outgoingSeen.add,
                itemBuilder: (context, i, handle, cellWidth) => Container(
                  key: ValueKey('card$i'),
                  height: 80,
                  color: const Color(0xFF222222),
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [handle, Text('card$i')]),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      outgoingSeen.clear();
      expect(outgoingSeen, isEmpty, reason: '前置：静止时不该有任何过渡');

      final handle = find.byIcon(Icons.drag_indicator).at(0);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(
          tester.getRect(find.byKey(const ValueKey('card1')).first).center);

      // 推进整个过渡窗口（180ms），逐帧收集
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      print('PREVIEW switcher outgoing observed = $outgoingSeen');

      expect(outgoingSeen, isNotEmpty,
          reason: '★★ 让位时 `AnimatedSwitcher.layoutBuilder` 应收到 outgoing 子项'
              '（旧内容仍在树上淡出）—— 收不到说明是**硬切**：'
              '要么没包 AnimatedSwitcher，要么 duration=0'
              '（用户要的"动画效果"没做出来）');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('★ 拖动中的卡片原位**化淡**（"被拿起来了"的反馈）', (tester) async {
      /*
       * `_slot` 用 `AnimatedOpacity(opacity: isDragSource ? 0.35 : 1.0)`。
       * 拖动中被拖那张卡应该变淡（纯绘制，不改约束）。
       */
      await pumpFour(tester);

      double opacityOf(String key) {
        final f = find.ancestor(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(AnimatedOpacity),
        );
        if (f.evaluate().isEmpty) return -1;
        return (f.evaluate().first.widget as AnimatedOpacity).opacity;
      }

      expect(opacityOf('card0'), 1.0, reason: '前置：静止时是不透明的');

      final handle = find.byIcon(Icons.drag_indicator).at(0);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 200));

      expect(opacityOf('card0'), lessThan(1.0),
          reason: '★ 被拖的卡原位要化淡 —— 否则用户看不出"哪张被拿起来了"');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('★★ 同一格内抖动**不重建其它卡片**（不能每帧重建全部 26 张）', (tester) async {
      /*
       * 用户要求：「26 张卡实时让位……**不能每帧重建全部**」。
       *
       * `DragTarget.onMove` 在鼠标移动时每帧都可能触发，
       * 若每次都 `setState` 就会每帧重建 26 张卡。
       * `_setHovered` 里有 `if (_hovered == index || _dragging == index) return;`
       * 挡住重复的。
       *
       * # 判据：**逐张卡**计数，只要求"没参与的卡不重建"
       *
       * ⚠️ 不能断言"总构建次数完全不变" —— 实测抖动 6 次会多 2 次。
       *    查了 SDK：`_DragTargetState.didMove` 自己会 `setState`
       *    （更新 `candidateData`），所以**悬停那一格**必然重建一次。
       *    那是一次、不是每帧 26 张 —— 与用户担心的"每帧重建全部"
       *    是两件事。
       *
       * 所以真正要守的不变量是：
       * ```text
       * · 被悬停的格子      重建（SDK 行为，可接受，一次一格）
       * · 其它所有卡        不得重建  ← ★ 这才是"不能全量重建"
       * ```
       */
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final builds = <int, int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              child: ReorderableCardGrid(
                itemCount: 4,
                onReorder: (a, b) {},
                itemBuilder: (context, i, handle, cellWidth) {
                  builds[i] = (builds[i] ?? 0) + 1;
                  return Container(
                    key: ValueKey('card$i'),
                    height: 80,
                    color: const Color(0xFF222222),
                    padding: const EdgeInsets.all(8),
                    child: Row(children: [handle, Text('卡$i')]),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final handle = find.byIcon(Icons.drag_indicator).at(0);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(
          tester.getRect(find.byKey(const ValueKey('card1')).first).center);
      await tester.pump(const Duration(milliseconds: 250));

      final settled = Map<int, int>.from(builds);

      /*
       * 在**同一格内**小幅抖动 6 次（`card1` 中心 ±2px 仍在第 1 格）。
       */
      final c = tester.getRect(find.byKey(const ValueKey('card1')).first).center;
      for (var i = 0; i < 6; i++) {
        await gesture.moveTo(c + Offset(i.isEven ? 2 : -2, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }

      print('PERF settled=$settled now=$builds');

      /*
       * ★ 核心：**未参与**的两张卡（card2 / card3）一次都不该重建。
       * 它们既不在拖动路径上，也没被悬停 —— 重建它们纯属浪费。
       * 实测：抖动 6 次后它们仍是 3（不动），只有被悬停的 card1
       * 和它旁边的 card0 各 +1（`DragTarget.didMove` 的 SDK 行为）。
       */
      for (final i in [2, 3]) {
        expect(builds[i], settled[i],
            reason: '★★ card$i 没参与拖动，抖动时不该重建 —— '
                '重建说明某处 setState 变成了全量重建（26 张会每帧全刷）');
      }

      /*
       * 被悬停的 card1 允许重建（SDK 的 `_DragTargetState.didMove` 会
       * `setState` 更新 candidateData）—— 但**只允许常数次**，不能每帧一次。
       *
       * 抖动 6 次 → 若每帧都重建，增长会是 6；这里应该是个位数小值。
       */
      final growth = builds[1]! - settled[1]!;
      print('PERF hovered card1 growth=$growth (jitter frames=6)');
      expect(growth, lessThan(6),
          reason: '★ 悬停格的重复悬停不该每次都重建（抖动 6 帧，增长 $growth）——'
              '增长到 6 说明 onMove 每次都 setState');
    });
  });

  group('③ ★★ 响应式实现不得踩 intrinsics 陷阱（2026-09-25 实测踩到过）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * 背景：`IntrinsicHeight` 会把"问子树内在高度"这个查询**向下**传
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 情况 A：LayoutBuilder 是 IntrinsicHeight 的**祖先** → 安全 ✓
     *   IntrinsicHeight 向下问，永远问不到上面的 LayoutBuilder
     *
     * 情况 B：LayoutBuilder 是 IntrinsicHeight 的**后代** → ★ 抛
     *   向下问就会问到它，而 LayoutBuilder 无法"投机布局"
     *   → "LayoutBuilder does not support returning intrinsic dimensions"
     * ```
     *
     * 本项目的网格**两种情况都真实出现过**：
     * ```text
     * ① 祖先：网格用 LayoutBuilder 量可用宽（算列数）—— 保留
     * ② 后代：卡片第一版自己 LayoutBuilder 量"要不要换行"—— ★ 实测真的抛了
     * ```
     * ② 的修复是**把宽度传下去**（`itemBuilder(..., cellWidth)`），
     * 网格本来就知道每格多宽，卡片不需要自己量。
     *
     * 这两条静态断言就是那个坑的**回归防护**（不需要真核心，秒级）。
     * 渲染级验证（pump 设置页确认不抛）在 `.probe/probe_tests/` 里。
     */
    String codeOnly(String path) {
      final buf = StringBuffer();
      for (final line in File(path).readAsStringSync().split('\n')) {
        final t = line.trimLeft();
        if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
          continue;
        }
        buf.writeln(line);
      }
      return buf.toString();
    }

    const gridPath = 'lib/ui/widgets/reorderable_card_grid.dart';
    const pagePath = 'lib/ui/settings_page.dart';

    test('★ 网格的 LayoutBuilder 在 IntrinsicHeight **之前**（祖先位置）', () {
      final code = codeOnly(gridPath);
      final lb = code.indexOf('LayoutBuilder(');
      final ih = code.indexOf('IntrinsicHeight(');
      expect(lb >= 0, isTrue, reason: '网格应该用 LayoutBuilder 量可用宽');
      expect(ih >= 0, isTrue, reason: '网格应该用 IntrinsicHeight 做"同一行等高"');
      // 源码顺序 = 嵌套顺序（外层先出现）
      expect(lb < ih, isTrue,
          reason: '★ LayoutBuilder 必须是 IntrinsicHeight 的**祖先**；'
              '一旦进到里面，intrinsic 查询就会问到它 → 直接抛异常');
      expect('LayoutBuilder('.allMatches(code).length, 1,
          reason: '★ 网格里只应有 1 个 LayoutBuilder（祖先位置的那个）');
    });

    test('★★ settings_page 里**不得**有 LayoutBuilder（卡片在 intrinsic 子树里）', () {
      /*
       * ★ 这是那次真 bug 的**直接回归测试**。
       *
       * 卡片是 `IntrinsicHeight` 的后代（网格包着它），
       * 所以卡片里**不能**放 `LayoutBuilder` —— 宽度必须由网格
       * 通过 `cellWidth` 参数传进来。
       *
       * ⚠️ 用 `codeOnly` 剥注释：我在调用点写了大段注释**引用**
       *    `LayoutBuilder` 这个词（解释为什么不许用）——
       *    不剥注释的话这条断言永远假红（项目里踩过 6 次同类坑）。
       */
      final code = codeOnly(pagePath);
      expect(code.contains('LayoutBuilder'), isFalse,
          reason: '★ `settings_page.dart` 里不得出现 LayoutBuilder ——\n'
              '  卡片在 `IntrinsicHeight` 的子树里，自己量宽度会让 intrinsic\n'
              '  查询撞上它 → "LayoutBuilder does not support returning\n'
              '  intrinsic dimensions" → 点设置页就抛。\n'
              '  宽度应由网格用 `cellWidth` 传下来。');
      expect(code.contains('cellWidth'), isTrue,
          reason: '★ 卡片必须从网格接收 `cellWidth`（替代自己量宽）');
    });
  });
}
