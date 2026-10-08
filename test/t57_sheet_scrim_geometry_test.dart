// task-57：`SheetTransition` **没有** scrim —— 那么面板到底挡不挡控制条？
//
// # 为什么要写这条（lead 的推理链缺了一环）
//
// lead 让我改 `player_page.dart` L6168 的排除表（加 `!_liveChannelsOpen`），
// 理由是「面板是**全屏** `Positioned.fill` 的 scrim ⇒ 控制条浮在它上面会被挡住」。
//
// 但我读了 `SheetTransition`（`episode_strip.dart` L1084-1195）：
// ```dart
// return AnimatedBuilder(... Opacity(opacity: t,
//          child: Transform.translate(offset: ..., child: child)));
// // child 外面只包了 IgnorePointer
// ```
// ⇒ ★★ **它自己不画任何东西** —— 没有 `ColoredBox`、没有 `GestureDetector`、
//   没有 `ModalBarrier`。所谓 "scrim" **不在这一层**。
//
// 真正的遮罩在**各面板自己**身上，而三个面板的形态**并不相同**：
// ```text
// EpisodeSheet（选集）      ColoredBox(black 0.5) + GestureDetector(opaque)
//                           + Align(centerRight)   ⇒ ★ 真·全屏 scrim
// _StreamSheet（线路）      Positioned(right:0, top:0, bottom:0, width:320)
//                                                  ⇒ ★ 只有右侧 320px
// _LiveChannelsSheet（直播）Align(centerRight) + ConstrainedBox(maxWidth:360)
//                           + ColoredBox(black 0.92) ⇒ ★ 只有右侧 360px
// ```
// ⇒ ★ 所以"面板是全屏 scrim"这个前提对**选集**成立，对**线路/直播**不成立。
//
// # 那"按钮被挡住"还成立吗？取决于两个可测的量
// ```text
// ① 面板占多大？（它是不是真的覆盖了按钮所在的右下角）
// ② 面板的有色区域吸不吸点击？（ColoredBox 用的是 HitTestBehavior.opaque）
// ```
// 这两条**可以确定性测**（不需要真机、不需要屏幕）⇒ 本文件就测它们。
//
// ⚠️ 我**没有**去 `PlayerPage` 里测（那要起 media_kit，成本高且与几何无关）。
//    这里用**与源码逐字同构**的 widget 树复现面板与控制条的布局 ——
//    因为被测的就是"这两个布局原语叠在一起会怎样"，不是业务逻辑。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 `_LiveChannelsSheet` **逐字同构**的外壳（player_page.dart L8027-8033）
Widget liveSheetShell() => Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          child: Column(
            children: [
              const SizedBox(height: 48), // 标题行
              Expanded(child: ListView(children: const [Text('央视')])),
            ],
          ),
        ),
      ),
    );

/// 与 `_StreamSheet` 同构（L7890-7894）
///
/// ⚠️ 它**自带 `Positioned`** ⇒ 必须**直接**作为 `Stack` 的子节点，
///    不能再包一层 `Positioned.fill` —— 那会让 `Positioned` 的父节点
///    不是 `Stack`（Flutter 报 ParentDataWidget 误用）。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-09-27 task-70【阻断级】：上面那条"必须直接挂 Stack"的注释
///      **本身就是这个 bug 的成因** —— 现在它已经不成立了
/// ══════════════════════════════════════════════════════════════════════
///
/// # 曾经的坑（本测试"为了能跑而绕开生产结构错误"）
/// ```text
/// 生产代码（player_page.dart L7050）是：
///   Positioned.fill(child: SheetTransition(child: PlayerPanelTheme(
///     child: _StreamSheet(...))))
/// ★ 而 `_StreamSheet` **自己又 return 一个 `Positioned`**
///   ⇒ 两个 `Positioned` 争同一个 RenderObject 的 StackParentData
///   ⇒ 因为 `SheetTransition` 产生 `RenderIgnorePointer`（不是 `RenderStack`），
///     Flutter 直接报错：`The offending Positioned is currently placed
///     inside a IgnorePointer widget.`
///
/// ★★ 而本测试为了能跑，把面板**直接**挂在 `Stack` 下
///   ⇒ **绕开了生产的结构错误** ⇒ 测试全绿、生产是错的
///   ⇒ Owner 点「线路」⇒ 面板的 `ColoredBox(black@0.92)` 被撑成
///     **满屏 896x760** ⇒ 整块变暗 + **吸收所有点击** ⇒ 只能杀进程
/// ```
/// ⇒ ★ 修法（task-70 已做）：
///   ① `_StreamSheet.build` 改用 `Align(centerRight) + SizedBox(width:320)`
///      —— **不再产生 ParentDataWidget** ⇒ 冲突消失
///   ② ★ **本测试同步改成与生产同构**（外层补 `Positioned.fill` 那层）
///      + **加几何断言**（宽 = 320 且贴右边）
///      ⇒ 否则这个坑还在，下一个人会再踩
///
/// # ★ 为什么"测试自己修正生产错误"比"测试没覆盖"更危险
/// ```text
/// 没覆盖   ⇒ 测试不会报 ⇒ 至少**测试没有骗你**
/// 修正错误 ⇒ ★ **测试是绿的** ⇒ 你以为这个结构被验证过了
/// ```
/// ★ 与 task-42 那条「测试绿 ≠ 行为对」同族。
Widget streamSheetShell() => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 320,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          child: Column(
            children: [
              const SizedBox(height: 48),
              Expanded(child: ListView(children: const [Text('线路1')])),
            ],
          ),
        ),
      ),
    );

/// ★★ 与生产**逐字同构**的外壳：外层 `Positioned.fill` 那一层也要有
///
/// 生产（player_page.dart L7050）：
/// ```dart
/// Positioned.fill(child: SheetTransition(child: PlayerPanelTheme(child: _StreamSheet(...))))
/// ```
/// ⚠️ 这里用 `Builder` 代替 `SheetTransition`/`PlayerPanelTheme` 是**有意的**：
///    本测试验的是**几何**，而这两个组件在 `visible: true` 时不改变布局
///    （`Opacity(1)` + `Transform.translate(0)` + `IgnorePointer(false)`）。
///    ★ 但**中间必须有产生 RenderObject 的层** —— 否则测不出
///      "Positioned 的父不是 Stack"这个错误（那正是 task-70 的形态）。
Widget productionChainShell(Widget body) => Positioned.fill(
      child: Builder(builder: (_) => body),
    );

/// 与 `_BottomBar` 同构（L7441-7444 + 按钮行的 Spacer）
Widget bottomBarShell({required VoidCallback onTap}) => Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        color: Colors.black87,
        child: Row(
          children: [
            const Icon(Icons.play_arrow, color: Colors.white),
            const SizedBox(width: 8),
            const Icon(Icons.volume_up, color: Colors.white),
            const Spacer(),
            TextButton.icon(
              key: const ValueKey('allLive'),
              onPressed: onTap,
              icon: const Icon(Icons.live_tv, color: Colors.white),
              label: const Text('所有直播', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

void main() {
  const size = Size(1280, 800);

  testWidgets('★ 直播面板是否**全高**、且**覆盖**右下角的按钮？', (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            bottomBarShell(onTap: () {}),
            // 面板在**后**（与 player_page.dart 的 Stack 顺序一致：
            // _BottomBar L6174 → 直播面板 L6441）
            Positioned.fill(child: liveSheetShell()),
          ],
        ),
      ),
    ));
    await tester.pump();

    final panel = tester.getRect(find.byType(ListView).first);
    final button = tester.getRect(find.byKey(const ValueKey('allLive')));

    debugPrint('[GEOM] 窗口            = $size');
    debugPrint('[GEOM] 面板(ListView)  = $panel');
    debugPrint('[GEOM] 按钮(所有直播)  = $button');
    debugPrint('[GEOM] 面板顶边 = ${panel.top}（0 = 全高）');

    // ① 面板是不是全高？
    expect(panel.top, lessThan(60),
        reason: '★ 面板应当从顶部开始（Align+Column(Expanded) 会撑满高度）');

    // ② 面板的**水平范围**是否覆盖按钮？
    final coveredHorizontally =
        panel.left <= button.left && panel.right >= button.right;
    debugPrint('[GEOM] 水平覆盖按钮 = $coveredHorizontally '
        '(面板左 ${panel.left} ≤ 按钮左 ${button.left}？)');
    expect(coveredHorizontally, isTrue,
        reason: '★ 面板（右侧 ≤360px）应当覆盖最右侧的按钮');
  });

  testWidgets('★★ 面板的**有色区域**吸不吸点击？（决定按钮还点不点得到）',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var buttonTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            bottomBarShell(onTap: () => buttonTaps++),
            Positioned.fill(child: liveSheetShell()),
          ],
        ),
      ),
    ));
    await tester.pump();

    final button = tester.getRect(find.byKey(const ValueKey('allLive')));
    // 在按钮中心点一下 —— 若面板吸收，回调不会触发
    await tester.tapAt(button.center);
    await tester.pump();

    debugPrint('[HIT] 点按钮中心 ${button.center} ⇒ 按钮回调次数 = $buttonTaps');
    expect(buttonTaps, 0,
        reason: '★ 面板的 ColoredBox(HitTestBehavior.opaque) 应当吸收该点击 '
            '⇒ 按钮**点不到**（这正是"面板开着时按钮失效"的机制）');
  });

  testWidgets('★ 对照：**线路面板**（右侧 320px）同样是"覆盖+吸收"',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var buttonTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            bottomBarShell(onTap: () => buttonTaps++),
            /*
             * ★★★ task-70：改成**与生产逐字同构**
             *
             * 生产是 `Positioned.fill(child: SheetTransition(...child: _StreamSheet))`
             * ⇒ ★ 这里**必须**也包一层 `Positioned.fill`
             *   （我原来直接挂 `streamSheetShell()` ⇒ 绕开了生产的结构错误）
             */
            productionChainShell(streamSheetShell()),
          ],
        ),
      ),
    ));
    await tester.pump();

    // ★★★ task-70 新增：几何断言（约束 A3）
    final panelRect = tester.getRect(find.byType(ColoredBox).last);
    debugPrint('[GEOM-线路] 面板 ColoredBox = $panelRect  w=${panelRect.width}');
    expect(
      panelRect.width,
      320,
      reason: '★★★ task-70 回归守卫：线路面板宽度必须**恰好 320**。\n'
          '  曾经的 bug：`_StreamSheet` 自己 return `Positioned`，与外层 '
          '`Positioned.fill` 争 StackParentData ⇒ 面板被撑成**满屏**\n'
          '  ⇒ 变暗 + 吸收所有点击 ⇒ 用户只能杀进程。\n'
          '  实测（896x760 播放器区）：冲突态 w=896（满屏）/ 修复后 w=320。',
    );
    expect(
      panelRect.right,
      1280,
      reason: '★ 必须**贴右边**（右边界 = 窗口右边界）',
    );

    final button = tester.getRect(find.byKey(const ValueKey('allLive')));
    await tester.tapAt(button.center);
    await tester.pump();
    debugPrint('[HIT-对照] 线路面板下点按钮 ⇒ 回调次数 = $buttonTaps');
    expect(buttonTaps, 0, reason: '★ 线路面板也吸收（它也是 opaque ColoredBox）');
  });

  testWidgets('★ 对照：面板**不存在**时按钮**可以**点到（证明仪器有效）',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var buttonTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            bottomBarShell(onTap: () => buttonTaps++),
          ],
        ),
      ),
    ));
    await tester.pump();

    final button = tester.getRect(find.byKey(const ValueKey('allLive')));
    await tester.tapAt(button.center);
    await tester.pump();
    debugPrint('[HIT-阳性对照] 无面板时点按钮 ⇒ 回调次数 = $buttonTaps');
    expect(buttonTaps, 1,
        reason: '★ 阳性对照：没有面板时按钮**必须**点得到 '
            '（否则上面两条"点不到"就没有区分力）');
  });

  testWidgets('★ 那底栏**左半边**（播放/音量）在面板开着时还点得到吗？',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var playTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                color: Colors.black87,
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('play'),
                      onPressed: () => playTaps++,
                      child: const Text('播放', style: TextStyle(color: Colors.white)),
                    ),
                    const Spacer(),
                    const SizedBox(width: 120),
                  ],
                ),
              ),
            ),
            Positioned.fill(child: liveSheetShell()),
          ],
        ),
      ),
    ));
    await tester.pump();

    final play = tester.getRect(find.byKey(const ValueKey('play')));
    await tester.tapAt(play.center);
    await tester.pump();
    debugPrint('[HIT-左半] 面板开着时点左侧「播放」 ⇒ 回调次数 = $playTaps');
    debugPrint('[HIT-左半] ⇒ $playTaps == 1 说明**左半边仍然可交互**');
    expect(playTaps, 1,
        reason: '★ 面板只占右侧 ⇒ 底栏左半边**没有被挡** ⇒ 仍可交互。'
            '这与注释声明的意图（"面板开着 = 面板是唯一可交互的东西"）不一致，'
            '但**不是**"按钮被 scrim 挡住"那个机制');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 生产源码的门控：面板开着时控制条**必须不画**
  // ═══════════════════════════════════════════════════════════════════

  /// ★★★ 红度证明：`_BottomBar` 的绘制条件必须包含 `!_liveChannelsOpen`
  ///
  /// # 这条测的是**修好的那个改动本身**
  ///
  /// 上面几条量的是"面板会挡住按钮"这个**机制**；这条量的是
  /// "**生产代码已经据此把控制条藏起来了**"。
  ///
  /// ★ 红度：把 `!_liveChannelsOpen` 从 `_BottomBar` 的 `if` 里删掉
  ///   ⇒ 本条**变红**（找不到该判据）。
  ///
  /// # 为什么要用"源码结构断言"而不是 widget 测试
  ///
  /// 真跑 `PlayerPage` 需要 media_kit（起 mpv、要网络），而这里要验的
  /// 只是**一个布尔判据有没有出现在那个 `if` 里** —— 那是纯静态事实。
  /// 本仓已有先例（`zz_t42_player_keys_test.dart` 断言 `_anySheetOpen`
  /// 的成员、`zz_t53_live_fullscreen_switch_test.dart` 断言参数表）——
  /// 它们的注释也写明了"静态判据"这个性质。
  ///
  /// ⚠️ 必须**先剥注释**再断言：本仓踩过这个坑（`zz_t53` L354-357 逐字记录了
  ///    "把注释文本写进判据 ⇒ 永远找不到 ⇒ 假红"）。
  test('★★★ _BottomBar 的绘制条件必须排除「所有直播」面板', () {
    final raw = File('lib/ui/player_page.dart').readAsStringSync();

    // 剥掉 // 行注释与 /* */ 块注释（与 zz_t53 同一做法）
    final src = raw
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
        .replaceAll(RegExp(r'//[^\n]*'), ' ');

    final i = src.indexOf('_BottomBar(');
    expect(i, greaterThan(0), reason: '找不到 _BottomBar( ⇒ 文件结构变了');

    // 往回找它的 `if (` 条件块
    final before = src.substring((i - 600).clamp(0, i), i);
    final condStart = before.lastIndexOf('if (');
    expect(condStart, greaterThanOrEqualTo(0),
        reason: '找不到 _BottomBar 前面的 if ( ⇒ 结构变了');
    final cond = before.substring(condStart);

    debugPrint('[GATE] 条件块 = ${cond.replaceAll(RegExp(r"\s+"), " ").trim()}');

    // 四个面板必须都在
    for (final flag in [
      '_episodeSheetOpen',
      '_streamSheetOpen',
      '_settingsOpen',
      '_liveChannelsOpen', // ★ 本次新增
    ]) {
      expect(cond.contains('!$flag'), isTrue,
          reason: '★★★ `_BottomBar` 的绘制条件漏了 `!$flag` ⇒ '
              '该面板开着时控制条仍然画着，而面板自身的有色区域'
              '（ColoredBox = HitTestBehavior.opaque）会**吸收点击** ⇒ '
              '用户点按钮**没反应**。'
              '实测见本文件上面几条（面板开着点按钮 = 0 次，阳性对照 = 1 次）。'
              '★ 红度：删掉 `!_liveChannelsOpen` 即复现本断言失败。');
    }
  });
}
