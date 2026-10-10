// ═══════════════════════════════════════════════════════════════════════
//  OPS-5 回归门禁：底栏「倍速入口重复」+「倍速菜单锚点甩到右下角」
//  （业主 2026-10-10 反馈第 2 条，来源截图 图 2）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 现象 ①（看图说话）
//  底栏上出现【两个倍速入口】：左边一组是「▶ 🔊 ──●── 1x」，右边那排里
//  **又**有一枚「1x」圆形图标。两者图标、id、文字全同 ⇒ 同一个功能画了两遍。
//
//  ```text
//  ① 常驻高频组   lib/ui/player/player_bottom_bar.dart:517-523（primary 切片内）
//       _PopoverButton(id: PlayerPopoverIds.rate, icon: Icons.speed,
//                      label: '${_trimRate(rate)}x', tooltip: '倍速')
//     ← 排在 播放 / 音量 之后 ⇒ 截图里**左边**那枚（保留这一枚）
//  ② 条件项列表   lib/ui/player/player_bottom_bar.dart:255-261（_actions() 里）
//       _BarAction(icon: Icons.speed, label: '${_trimRate(rate)}x',
//                  tooltip: '倍速', popoverId: PlayerPopoverIds.rate)
//     ← **无任何 if 门控** ⇒ 恒渲染 ⇒ 截图里**右边**那枚（删掉这一枚）
//  ```
//
//  # 现象 ②
//  悬停倍速按钮弹出的菜单跑到**画面右下角**，与按钮隔着一整条控制条的距离。
//  锚点算的是「整屏右下角 + 固定右边距」而不是按钮自己的位置：
//  ```text
//  lib/ui/player_page.dart:11457-11475
//      Positioned.fill → Align(alignment: Alignment.bottomRight)
//        → Padding(right: Sp.x2, bottom: _kPlayerBottomBarHeight = 96)
//          → ListenableBuilder → buildPopoverLayer()
//  ```
//  而 `PopoverController`（player_popover.dart:76-127）只存 `String? _openId`，
//  **一个几何量都没有** ⇒ 面板无从知道按钮在哪，只能贴右下角。
//  五个 popover（rate/quality/tracks/danmaku/more）共用这一个锚点，**都偏**。
//
//  # 修法与边界（已实现）
//  ① 删掉 `_actions()` 里那枚重复的倍速，**保留 `primary` 里那枚**：
//     primary 是「任何宽度都在第一行、永不折叠」那组（截图左边那组就是它），
//     且 test/t80_cast_wiring_test.dart A⑩ 明确要求 `primary` 切片内
//     按 播放 → 音量 → 倍速 的顺序含 `tooltip: '倍速'` ⇒ 删 primary 会直接打红。
//  ② 锚点改成「贴着按钮自己」：`PopoverAnchorButton` 挂载时把自己的
//     `GlobalKey` 登记进 `PopoverController`（`attachAnchor`），
//     `buildPopoverLayer()` 在**布局期**读那枚按钮的屏幕矩形，把面板平移过去
//     （右缘对齐按钮右缘、底边贴在按钮上沿上方 8px，并 clamp 进窗口）。
//     ★ 宿主那段 `Align(bottomRight)+Padding` **一个字没动** —— test/t68 E⑥
//       钉的就是它（「面板由页面整屏 Stack 承载，不是底栏的子件」）。
//
//  # 为什么测试挂 PlayerBottomBar 而不是驱动整个 PlayerPage
//  `sourin_core.dll` 在 flutter_tester 里加载失败（error 126，见
//  `test/zz_cr_play_bottom_bar_test.dart` 文件头）⇒ PlayerPage 渲染不出控制条。
//  PlayerBottomBar 是纯 Widget（无 FFI），这里照 player_page.dart:11457-11475
//  的**真实挂载点**搭一个同构宿主（含 `right: Sp.x2` / `bottom: 96`）。

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
// ⚠️ `PlayerPopoverIds` 在 player_bottom_bar.dart 与 player_popover.dart 里
//    **各有一份**（同名同值）⇒ 必须 `show` 掉其中一份，否则编译器报歧义。
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerMoreMenuData, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_more_menu.dart' show MoreMenuGroup;
import 'package:sourin_spike/ui/player/player_popover.dart'
    show
        PopoverAnchorButton,
        PopoverController,
        PopoverOption,
        PlayerPopoverSurface;
import 'package:sourin_spike/ui/tokens.dart';

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Spy {
  final List<double> rates = <double>[];

  void pickRate(double r) => rates.add(r);
}

/// 视口（逻辑像素）—— 与 `tester.view.*` 一致，避免 setSurfaceSize 改不到 MediaQuery
Size _viewport(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

/// 生产里浮层是底栏的**兄弟**节点，挂在页面那个整屏 Stack 里。
/// 这里逐字照抄 `player_page.dart:11457-11475`（含 `right: Sp.x2` 与
/// `bottom: 96`），所以测出来的几何就是生产几何。
Widget _host(PlayerBottomBar bar, PopoverController controller) => Stack(
      children: <Widget>[
        bar,
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Positioned.fill(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: Sp.x2, bottom: 96),
                child: bar.buildPopoverLayer(),
              ),
            ),
          ),
        ),
      ],
    );

final List<PopoverOption<String>> _qualityOptions = <PopoverOption<String>>[
  const PopoverOption<String>(value: 'q1', label: '1080P', checked: true),
  const PopoverOption<String>(value: 'q2', label: '720P'),
];

/// 字幕 / 音轨各一组 —— 让 `tracks` 那枚按钮真的存在（五个 popover 才齐）
Map<String, List<PopoverOption<String>>> _trackGroups() =>
    <String, List<PopoverOption<String>>>{
  '字幕': <PopoverOption<String>>[
    const PopoverOption<String>(value: 's1', label: '中文', checked: true),
    const PopoverOption<String>(value: 's2', label: 'English'),
  ],
};

PlayerBottomBar _bar(PopoverController controller, _Spy spy) => PlayerBottomBar(
      controller: controller,
      playing: true,
      positionListenable: ValueNotifier<Duration>(Duration.zero),
      duration: const Duration(minutes: 24),
      isLive: false,
      rate: 1.0,
      volume: 60,
      muted: false,
      fullscreen: false,
      onTogglePlay: () {},
      onSeek: (_) {},
      onVolume: (_) {},
      onToggleMute: () {},
      onRate: spy.pickRate,
      onToggleFullscreen: () {},
      onEpisodes: () {},
      hasEpisodes: false,
      showEpisodeNav: false,
      onNext: () {},
      hasNext: false,
      more: const PlayerMoreMenuData(groups: <MoreMenuGroup>[]),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: _qualityOptions,
      trackGroups: _trackGroups(),
    );

/// 1400×900（宽档：`avail >= _kBarRowWidth` = 720 ⇒ 走单行 `Row`）
/// ⚠️ 必须用 `tester.view.*`；`setSurfaceSize` 不改 MediaQuery，会造成假红。
/// ★⚠️ 还要自己补一层 `Material`：`PopoverRow` 内部是 `InkWell`，没有 Material
///    祖先时面板一打开就抛 "No Material widget found"（那是环境问题，不是缺陷）。
Future<void> _pumpBar(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          child: _host(_bar(controller, spy), controller),
        ),
      ),
    ),
  );
  _claim(tester);
}

/// 打开某个 popover 并等动画走完（`PopoverMotion` 的 AnimatedSlide 落位）
///
/// ⚠️ 控制器由**测试自己持有**（`_bar` / `_host` 都用同一个实例）：
///    `PopoverController` 不是 Widget，`tester.widget<PopoverController>` 取不到。
Future<void> _open(
  WidgetTester tester,
  PopoverController controller,
  String id,
) async {
  controller.toggle(id);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  _claim(tester);
}

/// 面板本体（`PlayerPopoverSurface` 是面板的**外观**，五个 popover 都用它）
Rect _panelRect(WidgetTester tester) => tester.getRect(
      find.byType(PlayerPopoverSurface, skipOffstage: false),
    );

/// 某个 popover 的锚点按钮（悬停 / 点击入口）
Finder _anchorFinder(String id) => find.byWidgetPredicate(
      (w) => w is PopoverAnchorButton && w.id == id,
      skipOffstage: false,
    );

/// 锚点按钮的屏幕矩形 —— 取**第一枚**（= `primary` 里那枚，截图左边那枚）。
///
/// ⚠️ 用 `.first` 而不是「必须唯一」：缺陷态下 `_actions()` 会再画一枚同样的
///   入口（两个 `PopoverAnchorButton` 同 id），此时 `getRect` 会因为
///   "ambiguously found multiple matching widgets" 直接抛框架断言 ——
///   那是**缺陷 ① 的副作用**，会把缺陷 ② 的几何断言遮住。
///   元素树的深度优先顺序里 `primary` 排在 `secondary` 之前 ⇒ `.first`
///   就是业主截图里悬停的那枚；「只该有一枚」由用例 ① 单独钉。
Rect _anchorRect(WidgetTester tester, String id) =>
    tester.getRect(_anchorFinder(id).first);

void main() {
  group('OPS-5 ② 底栏倍速入口只有一处', () {
    testWidgets('① 底栏上 Icons.speed 恰好一枚（右边那枚重复的已删）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy());

      // ★ 这就是业主看到的两枚：左边「▶ 🔊 ──●── 1x」+ 右边那排里的「1x」
      expect(
        find.byIcon(mui.Icons.speed),
        findsOneWidget,
        reason: '★★ 倍速入口只该有一枚 —— 截图里右边那排的重复项必须删掉',
      );
      // 留下的那枚必须是**悬停入口**（primary 那枚没有 onTap ⇒ 被包成锚点）
      expect(
        _anchorFinder(PlayerPopoverIds.rate),
        findsOneWidget,
        reason: '★★ 保留的必须是 primary 里那枚「悬停 150ms 展开」的入口',
      );
    });

    testWidgets('② 悬停那枚倍速按钮 150ms ⇒ 面板真的展开（鼠标那条路能用）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy());

      final anchor = _anchorRect(tester, PlayerPopoverIds.rate);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(anchor.center));
      await tester.pump();
      // 悬停 150ms 才展开（PopoverAnchorButton.hoverDelay）
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      _claim(tester);

      expect(
        controller.openId,
        PlayerPopoverIds.rate,
        reason: '★★ 悬停 150ms 必须展开倍速面板（这是保留的那枚入口的活）',
      );
      expect(find.byType(PlayerPopoverSurface, skipOffstage: false),
          findsOneWidget);
    });
  });

  group('OPS-5 ② 菜单贴着按钮、且不越窗口', () {
    testWidgets('③ 面板右缘 = 按钮右缘，底边贴在按钮上沿上方', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy());

      final anchor = _anchorRect(tester, PlayerPopoverIds.rate);
      final bar = tester.getRect(find.byType(PlayerBottomBar));
      await _open(tester, controller, PlayerPopoverIds.rate);
      final panel = _panelRect(tester);
      // ignore: avoid_print
      print('[OPS5] 倍速按钮=$anchor 面板=$panel 底栏=$bar');

      // ★ 判别性断言（缺陷态这里差 1152px）：右缘贴按钮右缘
      expect(
        (panel.right - anchor.right).abs(),
        lessThan(1.5),
        reason: '★★ 面板必须贴着按钮：右缘差 ${panel.right - anchor.right}px'
            '（缺陷态是甩到窗口右下角，差一整个控制条）',
      );
      // 以下两条是**不变量**（缺陷态也成立，用来防止「修好左右、上下飞了」）：
      // 面板整个在底栏上方，且下沿贴着底栏上沿（留 Sp.x2 的缝）
      expect(
        (bar.top - panel.bottom).abs(),
        lessThanOrEqualTo(Sp.x2 + 0.5),
        reason: '★ 面板的下沿必须停在底栏上沿附近：面板底 ${panel.bottom} '
            'vs 底栏顶 ${bar.top}（宿主用 `bottom: _kPlayerBottomBarHeight` '
            '把它顶到那儿；这条是**不变量**，防止「左右修好了、上下飞了」）',
      );
      expect(
        panel.bottom,
        lessThanOrEqualTo(anchor.top + 0.5),
        reason: '★ 面板必须在按钮**上方**：面板底 ${panel.bottom} vs 按钮顶 ${anchor.top}',
      );
    });

    testWidgets('④ 面板整体在窗口内（右缘不越 `Sp.x2` 边距、左缘不为负）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy());
      final vp = _viewport(tester);

      await _open(tester, controller, PlayerPopoverIds.rate);
      final panel = _panelRect(tester);

      expect(panel.right, lessThanOrEqualTo(vp.width - Sp.x2 + 0.5),
          reason: '★★ 面板越出窗口右沿：$panel');
      expect(panel.left, greaterThanOrEqualTo(Sp.x2 - 0.5),
          reason: '★★ 面板越出窗口左沿：$panel');
      expect(panel.top, greaterThanOrEqualTo(0), reason: '★ 面板被顶出窗口：$panel');
      expect(panel.bottom, lessThanOrEqualTo(vp.height),
          reason: '★ 面板被顶出窗口下沿：$panel');
    });

    testWidgets('⑤ 五个 popover 各自贴**自己的**按钮（共用锚点那条已断）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy());

      for (final id in <String>[
        PlayerPopoverIds.rate,
        PlayerPopoverIds.quality,
        PlayerPopoverIds.tracks,
        PlayerPopoverIds.danmaku,
        PlayerPopoverIds.more,
      ]) {
        final anchor = _anchorRect(tester, id);
        await _open(tester, controller, id);
        final panel = _panelRect(tester);
        // ignore: avoid_print
        print('[OPS5] $id 按钮=$anchor 面板=$panel');
        expect(
          (panel.right - anchor.right).abs(),
          lessThan(1.5),
          reason: '★★ $id 的面板没贴住自己的按钮（右缘差 '
              '${panel.right - anchor.right}px）—— 五个 popover 共用了一个锚点',
        );
        expect(panel.bottom, lessThanOrEqualTo(anchor.top + 0.5),
            reason: '★★ $id 的面板没在按钮上方：$panel vs $anchor');
        controller.close();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      _claim(tester);
    });

    testWidgets('⑥ 窄窗口（手机档 420 宽）面板被 clamp 进窗口，不再甩到右下角',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpBar(tester, controller, _Spy(), size: const Size(420, 900));
      final vp = _viewport(tester);
      expect(vp.width, 420);

      final anchor = _anchorRect(tester, PlayerPopoverIds.rate);
      await _open(tester, controller, PlayerPopoverIds.rate);
      final panel = _panelRect(tester);
      // ignore: avoid_print
      print('[OPS5] 窄窗 按钮=$anchor 面板=$panel');

      expect(panel.left, greaterThanOrEqualTo(Sp.x2 - 0.5),
          reason: '★★ 窄窗下面板越出左沿：$panel');
      expect(panel.right, lessThanOrEqualTo(vp.width - Sp.x2 + 0.5),
          reason: '★★ 窄窗下面板越出右沿：$panel');
      expect(
        panel.right,
        lessThan(vp.width / 2),
        reason: '★★ 窄窗下面板该靠按钮（左半屏），而不是贴窗口右下角：$panel',
      );
    });

    testWidgets('⑦ 点面板里的 1.25x ⇒ onRate 收到 1.25 且面板收起', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy);

      await _open(tester, controller, PlayerPopoverIds.rate);
      expect(find.text('1.25x', skipOffstage: false), findsOneWidget,
          reason: '★ 面板里必须有 1.25x 那一档（贴锚点的改动不许把内容弄丢）');

      await tester.tap(find.text('1.25x', skipOffstage: false));
      await tester.pump();

      expect(spy.rates, <double>[1.25], reason: '★ 档位点击必须落到 onRate');
      expect(controller.openId, isNull, reason: '★ 选完自己收起');
    });
  });
}
