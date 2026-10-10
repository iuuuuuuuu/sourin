// CR-17 / CR-18 回归测试：播放页底栏的「字幕与音轨」入口
//
// ★ 为什么把底栏**单独挂载**而不是驱动整个 PlayerPage：
//   `sourin_core.dll` 在 flutter_tester 里加载失败（error 126，见
//   `lib/ui/detail_page.dart:790-814` 与 `test/player_panel_wiring_test.dart`），
//   PlayerPage 因此渲染不出控制条。PlayerBottomBar 本身是纯 Widget（无 FFI），
//   这里照 `lib/ui/player_page.dart:14463-14508` 的真实接法挂它，并把
//   `buildPopoverLayer()` 当作**兄弟节点**放进同一个 Stack（生产里也是这样）。
//
// ★ 断言口径（不许退化成「按钮不灰」）：
//   CR-18：点「字幕与音轨」后 `controller.openId == 'tracks'`，且面板里
//          真的有内容（2 个分组标签 + 4 行 PopoverRow）并可见可点。
//   CR-17：**先用控制器直接打开面板**（绕开 CR-18 的入口缺陷），再点某一行 →
//          `onPickTrack(group, id)` 被调用，`onPickQuality` 一次都不能被调用。
//          单独这样切是为了让两条测试各自钉住自己的缺陷，互不遮蔽。
//   对照：清晰度面板仍走共用行，行为不能被本次改动弄坏。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Spy {
  final List<String> tracks = <String>[];
  final List<String> qualities = <String>[];

  void pickTrack(String group, String id) => tracks.add('$group / $id');
  void pickQuality(String id) => qualities.add(id);
}

/// 两条字幕 + 两条音轨；同时给清晰度列表，让 tracks / quality 两条路径同时在场
Map<String, List<PopoverOption<String>>> _trackGroups() =>
    <String, List<PopoverOption<String>>>{
  '字幕': <PopoverOption<String>>[
    const PopoverOption<String>(value: 's1', label: '中文', checked: true),
    const PopoverOption<String>(value: 's2', label: 'English'),
  ],
  '音轨': <PopoverOption<String>>[
    const PopoverOption<String>(value: 'a1', label: '国语'),
    const PopoverOption<String>(value: 'a2', label: '粤语'),
  ],
};

final List<PopoverOption<String>> _qualityOptions = <PopoverOption<String>>[
  const PopoverOption<String>(value: 'q1', label: '1080P'),
  const PopoverOption<String>(value: 'q2', label: '720P'),
];

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
      onRate: (_) {},
      onToggleFullscreen: () {},
      onEpisodes: () {},
      hasEpisodes: false,
      showEpisodeNav: false,
      onNext: () {},
      hasNext: false,
      more: const PlayerMoreMenuData(groups: []),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: _qualityOptions,
      onPickQuality: spy.pickQuality,
      trackGroups: _trackGroups(),
      onPickTrack: spy.pickTrack,
    );

/// 生产里浮层是底栏的**兄弟**节点（`player_page.dart` 的全屏 Stack）
Widget _host(PlayerBottomBar bar, PopoverController controller) => Stack(
      children: <Widget>[
        bar,
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Positioned.fill(
            child: Align(
              alignment: Alignment.bottomRight,
              child: bar.buildPopoverLayer(),
            ),
          ),
        ),
      ],
    );

/// 宽视口（≥ `_kBarRowWidth` = 720）⇒ 走 `Row` 那一档，按钮全部在屏内可直接点。
///
/// ⚠️ 必须用 `tester.view.*`；`setSurfaceSize` 不改 MediaQuery，会造成假红
///    （见 `test/bottom_bar_fit_test.dart` 的长注释）。
///
/// ★⚠️ 还必须自己补一层 `Material`：`PopoverRow` 内部是 `InkWell`，没有 Material
///    祖先时面板一打开就抛 "No Material widget found"，整块面板变成 ErrorWidget
///    —— 那是**环境问题**，不是本次要修的缺陷（生产里 Scaffold 自带这层）。
Future<void> _pumpBar(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
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

void main() {
  testWidgets('CR-18 「字幕与音轨」点开后弹层真的打开且有内容', (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    await _pumpBar(tester, controller, spy);

    // 入口在，且此时面板是关的
    expect(find.byIcon(mui.Icons.closed_caption), findsOneWidget);
    expect(controller.openId, isNull);

    await tester.tap(find.byIcon(mui.Icons.closed_caption));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ★ CodeRabbit 的判据：控制器真的切到了 tracks
    expect(controller.openId, 'tracks');
    // ★ 而且面板里真有内容：2 个分组标签 + 4 行选项
    expect(find.byType(PopoverGroupLabel), findsNWidgets(2));
    expect(find.byType(PopoverRow), findsNWidgets(4));
    expect(find.text('字幕'), findsOneWidget);
    expect(find.text('音轨'), findsOneWidget);
    // ★ 可见才可点：`PopoverMotion` 在关闭时是 `IgnorePointer(ignoring: true)`
    //   —— 面板虽然一直在 build，但那时点不动。
    final shields = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.byType(PopoverGroupLabel).first,
            matching: find.byType(IgnorePointer),
          ),
        )
        .toList();
    expect(shields, isNotEmpty);
    expect(shields.where((w) => w.ignoring), isEmpty);

    // ★ 最硬的一条：真去点面板里的一行，回调必须真的响（证明「打开 + 有内容」）
    await tester.tap(find.text('English'));
    await tester.pump();
    expect(spy.tracks, <String>['字幕 / s2']);
    expect(controller.openId, isNull);

    _claim(tester);
  });

  testWidgets('CR-17 点面板里的音轨 → onPickTrack 触发且 onPickQuality 不触发',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    await _pumpBar(tester, controller, spy);

    // 用控制器直接开面板：只测「行 → 回调」的接线，不被 CR-18 的入口缺陷遮蔽
    controller.toggle('tracks');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.openId, 'tracks');
    expect(find.text('粤语'), findsOneWidget);

    await tester.tap(find.text('粤语'));
    await tester.pump();

    // ★ 走的是 onPickTrack，不是 onPickQuality
    expect(spy.tracks, <String>['音轨 / a2']);
    expect(spy.qualities, isEmpty);
    // 行点击后自己收起
    expect(controller.openId, isNull);

    _claim(tester);
  });

  testWidgets('对照：清晰度面板仍走共用行，行为未变', (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    await _pumpBar(tester, controller, spy);

    await tester.tap(find.text('清晰度'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.openId, 'quality');

    await tester.tap(find.text('720P'));
    await tester.pump();
    expect(spy.qualities, <String>['q2']);
    expect(spy.tracks, isEmpty);
    expect(controller.openId, isNull);

    _claim(tester);
  });
}
