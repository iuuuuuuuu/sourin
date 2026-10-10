// ═══════════════════════════════════════════════════════════════════════
//  Owner 缺陷 6 回归门禁：「更多」菜单里的「下一集」与底栏 ⏭ 是同一个功能
//  （业主 2026-10-10 反馈第 6 条，来源截图图 2 / 图 3 的底栏）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 缺陷（看图说话，不推测）
//
//  底栏靠右一排是「倍速 / CC / 弹幕 / …更多 / ⏭（下一集）」，而点开「更多」
//  之后的「剧集」分组里**又**有一项「下一集」—— 两个入口，**同一个功能**。
//
//  # 两个入口的回调（改前实测，行号为改前）
//
//  ```text
//  ① 底栏 ⏭          lib/ui/player/player_bottom_bar.dart:283-289
//       _BarAction(icon: Icons.skip_next, tooltip: '下一集',
//                   enabled: hasNext, onTap: onNext)
//     宿主接线        lib/ui/player_page.dart:11305
//       onNext: () => unawaited(_gotoNextEpisode()),
//
//  ②「更多」→「剧集」  lib/ui/player_page.dart:4248-4253
//       if (_nextEpisode != null)
//         MoreMenuEntry(
//           label: '下一集',
//           icon: Icons.skip_next,
//           onTap: () => unawaited(_gotoNextEpisode()),
//         ),
//  ```
//
//  ⇒ 两条路径的终点是**同一个** _gotoNextEpisode()（player_page.dart:7091），
//    判据也只是同一个 _nextEpisode != null ⇒ 确认是重复，不是两个功能。
//
//  # 修法与边界
//
//  删掉 ② 那一项。**只删这一项**：
//  - 底栏 ⏭ 的图标 / 位置 / 行为一个字没动；
//  - 「剧集」组里的「上一集」「片头片尾」留着（底栏**没有** ⏮，不重复）。
//
//  # 为什么测试要「读源码 + 挂载」两段
//
//  _moreMenuGroups 是 _PlayerPageState 的**私有**方法，而整个 PlayerPage
//  在 flutter_tester 里渲染不出来（sourin_core.dll 加载失败 error 126，见
//  test/zz_cr_play_bottom_bar_test.dart 开头的注释）⇒ 拿不到「真·生产菜单」。
//
//  所以这里做一个**闭环**：把生产源码里 _moreMenuGroups 的分组与项名**解析出来**，
//  再用这份解析结果去挂载 PlayerMoreMenu ⇒ 面板里渲染出来的项名是**真的由生产
//  源码决定的**，不是测试自己抄一份常量。
//  ⇒ 缺陷代码上这一段会真的红（面板里确实渲染出「下一集」那一行）。
//
//  防矫枉过正那一半（底栏 ⏭ 还在、还能触发）由 widget 断言承担：
//  如果有人顺手把底栏的 ⏭ 也删了，或者把 onNext 摘掉，下面几条 widget 用例会红。

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 生产源码（player_page.dart）里 _moreMenuGroups 的整段方法体
String _moreMenuSource() {
  final src = File('lib/ui/player_page.dart').readAsStringSync();
  final from = src.indexOf('List<MoreMenuGroup> _moreMenuGroups');
  expect(from, greaterThan(-1),
      reason: 'player_page.dart 里找不到 _moreMenuGroups');
  final to = src.indexOf('String? _trackHint(', from);
  expect(to, greaterThan(from),
      reason: 'player_page.dart 里找不到 _moreMenuGroups 的结尾锚点');
  return src.substring(from, to);
}

/// 只认**代码**不认注释：注释里可以自由解释实现
String _codeOnly(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// 把生产源码解析成「(分组名, [项名…])」，直接拿来渲染「更多」面板
List<(String, List<String>)> _parseProductionGroups() {
  final body = _codeOnly(_moreMenuSource());
  final out = <(String, List<String>)>[];
  for (final m in RegExp(
    r"MoreMenuGroup\('([^']*)',\s*\[(.*?)\]\s*\)",
    dotAll: true,
  ).allMatches(body)) {
    final labels = RegExp(r"label:\s*'([^']*)'")
        .allMatches(m.group(2)!)
        .map((x) => x.group(1)!)
        .toList();
    out.add((m.group(1)!, labels));
  }
  return out;
}

class _Spy {
  int next = 0;
  void onNext() => next++;
}

PlayerBottomBar _bar(
  PopoverController controller,
  _Spy spy, {
  required List<MoreMenuGroup> moreGroups,
  required bool showEpisodeNav,
  required bool hasNext,
}) =>
    PlayerBottomBar(
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
      showEpisodeNav: showEpisodeNav,
      onNext: spy.onNext,
      hasNext: hasNext,
      more: PlayerMoreMenuData(groups: moreGroups),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
    );

/// 生产里浮层是底栏的**兄弟**节点（player_page.dart 的全屏 Stack）
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

Future<void> _pumpBar(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy, {
  required List<MoreMenuGroup> moreGroups,
  required bool showEpisodeNav,
  required bool hasNext,
}) async {
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
          child: _host(
            _bar(
              controller,
              spy,
              moreGroups: moreGroups,
              showEpisodeNav: showEpisodeNav,
              hasNext: hasNext,
            ),
            controller,
          ),
        ),
      ),
    ),
  );
  _claim(tester);
}

/// 解析出来的生产项名 → 可渲染的 MoreMenuEntry（图标一律用中性图标，
/// 这样整棵树里 Icons.skip_next 出现几次，就只由**底栏**决定，不受菜单影响）
List<MoreMenuGroup> _renderable(List<(String, List<String>)> parsed) => [
      for (final (title, labels) in parsed)
        MoreMenuGroup(
          title,
          <MoreMenuEntry>[
            for (final l in labels)
              MoreMenuEntry(label: l, icon: mui.Icons.circle, onTap: () {}),
          ],
        ),
    ];

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.text('更多'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  test('★ 解析器本身要真的读到了生产菜单（防空跑）', () {
    final parsed = _parseProductionGroups();
    expect(
      parsed.map((e) => e.$1),
      containsAll(<String>['画面', '播放', '弹幕', '剧集']),
    );
  });

  testWidgets(
    '★ 打开「更多」：里面【不再有】下一集，但底栏 ⏭ 仍然在',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(
        tester,
        controller,
        spy,
        moreGroups: _renderable(_parseProductionGroups()),
        showEpisodeNav: true,
        hasNext: true,
      );

      await _openMore(tester);
      expect(controller.openId, 'more');

      // ★ 本次的诉求：「更多」里那一项没了
      expect(
        find.text('下一集'),
        findsNothing,
        reason: '★「更多」菜单里不该再有「下一集」—— 它与底栏 ⏭ 是同一个功能'
            '（两处都调 _gotoNextEpisode）',
      );

      // ★ 同一组 / 其它组里的项一个都没被顺手删掉
      expect(find.text('上一集'), findsOneWidget);
      expect(find.text('片头片尾'), findsOneWidget);
      expect(find.text('截图'), findsOneWidget);
      expect(find.text('换源'), findsOneWidget);

      // ★ 整个子树里 Icons.skip_next 只应出现一次 = 底栏那一枚 ⏭
      expect(
        find.byIcon(mui.Icons.skip_next),
        findsOneWidget,
        reason: '★ skip_next 只该是底栏 ⏭ 一处',
      );

      _claim(tester);
    },
  );

  testWidgets('★ 防矫枉过正：底栏 ⏭ 点得动且回调真的响', (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    await _pumpBar(
      tester,
      controller,
      spy,
      moreGroups: _renderable(_parseProductionGroups()),
      showEpisodeNav: true,
      hasNext: true,
    );

    // 底栏 ⏭ 在（tooltip 就是「下一集」）
    expect(find.byIcon(mui.Icons.skip_next), findsOneWidget);
    expect(find.byTooltip('下一集'), findsOneWidget);

    // 真去点它
    await tester.tap(find.byIcon(mui.Icons.skip_next));
    await tester.pump();
    expect(spy.next, 1, reason: '★ 底栏 ⏭ 仍然必须能触发 onNext');
    // 点它不该顺手把「更多」面板也打开
    expect(controller.openId, isNull);

    _claim(tester);
  });

  testWidgets('★ 对照：最后一集（hasNext=false）时 ⏭ 仍禁用，行为与改前一致',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    await _pumpBar(
      tester,
      controller,
      spy,
      moreGroups: _renderable(_parseProductionGroups()),
      showEpisodeNav: true,
      hasNext: false,
    );

    // `find.byIcon` 命中的是 `Icon`，禁用态挂在它**外面**那枚 IconButton 上
    final btn = tester.widget<mui.IconButton>(
      find
          .ancestor(
            of: find.byIcon(mui.Icons.skip_next),
            matching: find.byType(mui.IconButton),
          )
          .first,
    );
    expect(btn.onPressed, isNull, reason: '★ 没有下一集时 ⏭ 必须仍然是禁用态');
    _claim(tester);
  });

  test('★ 源码门禁：「更多」里不再有「下一集」项，底栏 ⏭ 仍在且仍接 _gotoNextEpisode',
      () {
    final more = _codeOnly(_moreMenuSource());
    expect(
      more.contains("label: '下一集'"),
      isFalse,
      reason: '★ player_page.dart 的「更多」菜单里不该再有「下一集」项',
    );

    final bar = _codeOnly(
      File('lib/ui/player/player_bottom_bar.dart').readAsStringSync(),
    );
    expect(bar.contains('Icons.skip_next'), isTrue, reason: '★ 底栏 ⏭ 必须还在');
    expect(bar.contains('onTap: onNext'), isTrue,
        reason: '★ 底栏 ⏭ 必须仍然接 onNext，不能被顺手摘掉');

    final page = _codeOnly(
      File('lib/ui/player_page.dart').readAsStringSync(),
    );
    expect(
      page.contains('onNext: () => unawaited(_gotoNextEpisode()),'),
      isTrue,
      reason: '★ 宿主仍要把 onNext 接到 _gotoNextEpisode',
    );
    expect(
      page.contains('Future<void> _gotoNextEpisode() async {'),
      isTrue,
      reason: '★ _gotoNextEpisode 本身不许被删',
    );
  });
}
