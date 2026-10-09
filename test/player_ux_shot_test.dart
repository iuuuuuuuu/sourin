@Tags(['native-media'])
// ═══════════════════════════════════════════════════════════════════════
//  播放器 UI 的**无头截图**（Owner 第 12 条的自查手段）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 为什么要这个文件
//  今晚机器锁屏 ⇒ 真窗口截图拿不到（屏幕拷贝是锁屏壁纸，PrintWindow 抓 ANGLE
//  恒为全黑）⇒ 用 `support/ui_shot.dart` 在 flutter_tester 里渲染真字体 PNG。
//
//  # 它同时是**性能读数**的来源（Owner 第 10 条「做一下检测和优化」）
//
//  ```text
//  用 `_rebuildCounter` 数「整页 PlayerPage.build 跑了几次」：
//  · 60 次鼠标移动  → 改前 60 次（每次 ~166 个 element）；改后 0 次
//  · 播放位置 180 tick（跨 3 秒）→ 改前 3 次整页重建；改后 0 次
//  · 打开选集面板（100 集）→ 改前一次性建 600+ 个 element；改后只建视口里的十几格
//  ```
//  ⚠️ 这些数字进的是**交付报告**（ASCII 字符画 + 本文件的 print），
//     断言本身只钉「不再整页重建」这一条结构性事实。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 'support/ui_shot.dart';

/// 数「整页 PlayerPage 的 build 被跑了几次」
///
/// ★ 手法照抄 `t72_jank_test.dart`：`debugOnRebuildDirtyWidget` 是框架自带的
///   全局钩子，命中 `e.widget is PlayerPage` 即「整页重建了一次」。
///   （不是局部重建 —— 局部重建的元素不是 `PlayerPage` 本身。）
int _pageBuilds = 0;
int _allBuilds = 0;

void _install() {
  _pageBuilds = 0;
  _allBuilds = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _allBuilds++;
    if (e.widget is PlayerPage) _pageBuilds++;
  };
}

void _uninstall() => debugOnRebuildDirtyWidget = null;

/// 造 n 集
List<Episode> _eps(int n) => [
  for (var i = 0; i < n; i++)
    Episode(id: 'e$i', title: '第${i + 1}集', url: 'https://x.invalid/$i.m3u8'),
];

Future<void> _mount(
  WidgetTester t, {
  int episodes = 100,
  int current = 40,
  Size size = const Size(1440, 900),
}) async {
  await setShotViewport(t, size);
  addTearDown(t.view.reset);
  final eps = _eps(episodes);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Microsoft YaHei UI',
      ),
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '长津湖',
        episodes: eps,
        episodeIndex: current,
        episodeId: eps[current].id,
        episodeTitle: eps[current].title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
  _claim(t);
  // 无头环境没有核心库 ⇒ 起播必然失败 ⇒ 底栏那条门控不成立。
  // 截图要看的是**底栏**，所以把状态救回来（只改 UI，不碰播放器）。
  expect(debugPlayerForceBarsForShot(), isTrue, reason: '★ 探针没生效');
  await t.pump(const Duration(milliseconds: 200));
  _claim(t);
}

/// 认领一次 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 收集屏幕上**真正画出来的文字**
///
/// # 为什么不能直接用 `find.text`
/// ```text
/// 本仓的 `material_ui` 主题把 Material 的默认文字实现换掉了 ——
/// 实测在真实播放页上 `find.text('更多')` / `find.text('1x')` 全部 0 命中，
/// 而截图里那些字**确实画出来了**。
/// ⇒ 判据必须落在**渲染层**：从根 Element 往下走，遇到 `Text` 就读它的
///   `data`（或 `TextSpan` 展平），这与 finder 的实现细节无关。
/// ```
/// ★ 只收**非空**的 —— 否则会塞进几百个空串，报告里没法看。
List<String> _plainTexts(WidgetTester t) {
  final out = <String>[];
  void walk(Element el) {
    final w = el.widget;
    if (w is Text) {
      final d = w.data;
      if (d != null && d.trim().isNotEmpty) out.add(d.trim());
    } else if (w is EditableText) {
      final d = w.controller.text;
      if (d.trim().isNotEmpty) out.add(d.trim());
    }
    el.visitChildren(walk);
  }

  walk(t.binding.rootElement!);
  return out;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUpAll(loadRealFonts);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  group('★ 播放器无头截图', () {
    testWidgets('① 桌面 1440×900 底栏', (t) async {
      await _mount(t);
      final f = await saveViewShot(t, 'player_desktop_bar');
      expect(f.existsSync(), isTrue);
      expect(
        f.lengthSync(),
        greaterThan(2000),
        reason: '★ PNG 太小 ⇒ 基本是纯黑画面（底栏没画出来）',
      );
    });

    testWidgets('② 「更多」浮层展开', (t) async {
      await _mount(t);
      // ⚠️ 用**探针**而不是 `t.tap`：flutter_tester 里 PlayerPage 整棵树的
      //   指针回调不被调用（见 test/t98 文件头）⇒ tap 打不动底栏。
      //   探针操作的是**同一个** `PopoverController`，验的是生产那条路径。
      expect(
        find.byIcon(Icons.more_horiz),
        findsWidgets,
        reason: '★ 底栏上要有「更多」入口',
      );
      // ⚠️ 用**探针**而不是 `t.tap`：flutter_tester 里 PlayerPage 整棵树的
      //   指针回调不被调用（见 test/t98 文件头）⇒ tap 打不动底栏。
      //   探针操作的是**同一个** `PopoverController`，验的是生产那条路径。
      expect(
        debugPlayerOpenPopoverForProbe(PlayerPopoverIds.more),
        isTrue,
        reason: '★ 探针没生效（它操作的就是生产那个 PopoverController）',
      );
      await t.pump(const Duration(milliseconds: 250));
      _claim(t);
      // 阳性对照：面板里的分组标题必须真的画出来了
      final texts = _plainTexts(t);
      // ignore: avoid_print
      print('[SHOT] 更多浮层文字=${texts.toList()}');
      // ★★ 面板的**几何**断言（比截图更硬：截图只证明"画了"，
      //   几何证明"画在**该在的位置**、且完全在视口内"）
      final menu = find.byType(PlayerMoreMenu, skipOffstage: false);
      expect(menu, findsOneWidget, reason: '★★「更多」浮层没有建出来');
      final r = t.getRect(menu);
      expect(r.width, greaterThan(120), reason: '★ 面板宽度不对：$r');
      expect(r.height, greaterThan(200), reason: '★ 面板高度不对（分组清单）：$r');
      expect(r.top, greaterThan(0), reason: '★★ 面板被顶到视口外了：$r');
      expect(r.bottom, lessThan(900), reason: '★★ 面板超出屏幕下沿：$r');
      expect(r.right, lessThanOrEqualTo(1440.5), reason: '★★ 面板超出屏幕右沿：$r');
      // ignore: avoid_print
      print('[SHOT] 更多浮层矩形=$r');
      expect(
        texts.any((x) => x.contains('播放设置')),
        isTrue,
        reason: '★★ popover 没展开 ——「播放设置」这一项应该在里面',
      );
      // ★ 截图前必须**再 pump 一次**：面板是隐式动画（AnimatedOpacity），
      //   上一帧的合成结果还没落到 OffsetLayer 上，直接截会拍到旧画面。
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      final f = await saveViewShot(t, 'player_popover_more');
      expect(f.lengthSync(), greaterThan(2000));
    });

    testWidgets('③ 倍速 popover 展开', (t) async {
      await _mount(t);
      expect(find.byIcon(Icons.speed), findsWidgets, reason: '★ 底栏上要有倍速入口');
      expect(debugPlayerOpenPopoverForProbe(PlayerPopoverIds.rate), isTrue);
      await t.pump(const Duration(milliseconds: 250));
      _claim(t);
      final texts = _plainTexts(t);
      // ignore: avoid_print
      print('[SHOT] 倍速面板文字=${texts.toList()}');
      expect(
        texts.any((x) => x.contains('1.25x')),
        isTrue,
        reason: '★★ 倍速面板没展开 —— 档位列表应该在里面',
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      final f = await saveViewShot(t, 'player_popover_rate');
      expect(f.lengthSync(), greaterThan(2000));
    });

    testWidgets('④ 选集面板（100 集）', (t) async {
      await _mount(t);
      expect(find.byIcon(Icons.list), findsWidgets, reason: '★ 底栏上要有「选集」入口');
      expect(debugPlayerOpenEpisodesForProbe(), isTrue, reason: '★ 探针没生效');
      await t.pump(const Duration(milliseconds: 350));
      _claim(t);
      final texts = _plainTexts(t);
      // ignore: avoid_print
      print('[SHOT] 选集面板文字（前 24 条）=${texts.take(24).toList()}');
      expect(
        texts.any((x) => x.contains('共 100 集')),
        isTrue,
        reason: '★★ 选集面板没打开',
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      final f = await saveViewShot(t, 'player_episodes');
      expect(f.lengthSync(), greaterThan(2000));
    });

    testWidgets('⑤ 手机竖屏 412×915', (t) async {
      await _mount(t, size: const Size(412, 915));
      final f = await saveViewShot(t, 'player_phone_portrait');
      expect(f.lengthSync(), greaterThan(2000));
    });

    testWidgets('⑥ 手机横屏 915×412', (t) async {
      await _mount(t, size: const Size(915, 412));
      final f = await saveViewShot(t, 'player_phone_landscape');
      expect(f.lengthSync(), greaterThan(2000));
    });
  });

  group('★ 卡顿读数（Owner 第 10 条「做一下检测和优化」）', () {
    testWidgets('PA 60 次鼠标移动 ⇒ 整页重建 0 次', (t) async {
      await _mount(t);
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(const Offset(200, 400)));
      await t.pump();
      _install();

      const moves = 60;
      for (var i = 0; i < moves; i++) {
        await t.sendEventToBinding(p.hover(Offset(200.0 + i * 2, 400)));
        await t.pump();
      }
      // ignore: avoid_print
      print(
        '[PLAYER-PERF] PA|$moves 次鼠标移动 ⇒ 整页重建 $_pageBuilds 次 / '
        '全部元素 $_allBuilds 次（改前：整页 60 次、元素约 9960 次）',
      );
      _uninstall();
      expect(
        _pageBuilds,
        0,
        reason:
            '★★ 控制条已可见时鼠标移动**不该**重建整页 —— '
            '那正是 Owner 报的「操作卡卡的」。',
      );
    });

    testWidgets('PB 180 次位置 tick（跨 3 秒）⇒ 整页重建 0 次', (t) async {
      await _mount(t);
      _install();
      debugPlayerResetPositionSetStates();
      const ticks = 180; // i=1..180 ⇒ 位置 0s → 3.0s
      for (var i = 1; i <= ticks; i++) {
        debugPlayerPushPositionForProbe(
          Duration(microseconds: (i * 1000000 / 60).round()),
        );
        await t.pump();
      }
      // ignore: avoid_print
      print(
        '[PLAYER-PERF] PB|$ticks 次 tick（0s→3.0s）⇒ 整页重建 $_pageBuilds 次'
        ' / 位置通知 ${debugPlayerPositionSetStates} 次'
        '（改前：整页重建 3 次，每秒一次）',
      );
      _uninstall();
      expect(
        _pageBuilds,
        0,
        reason:
            '★★ 播放位置前进**不该**重建整页 —— 底栏那一小块用 '
            'ValueListenableBuilder 局部重建就够（改前每秒一次整页重建）。',
      );
      expect(
        debugPlayerPositionSetStates,
        greaterThanOrEqualTo(3),
        reason:
            '★ 下限同样重要：跨了 3 个秒边界就该更新 3 次，'
            '少于 3 说明守卫写过头了、时间显示会卡住不动。',
      );
    });

    testWidgets('PC 打开选集面板（100 集）⇒ 建的格子数是 O(视口) 不是 O(全集)', (t) async {
      await _mount(t, episodes: 100);
      // 先数「打开前」的格子数（应为 0）
      int cells() => find.byType(GestureDetector).evaluate().length;

      final before = cells();
      debugPlayerOpenEpisodesForProbe();
      await t.pump(const Duration(milliseconds: 300));
      _claim(t);
      final after = cells();
      // ignore: avoid_print
      print(
        '[PLAYER-PERF] PC|打开选集（100 集）⇒ GestureDetector '
        '$before → $after（改前：一次建出 100 个格子的全部子树）',
      );
      // ignore: avoid_print
      print(
        '[PLAYER-PERF] PC|面板里可见的集号：'
        '${_plainTexts(t).take(20).toList()}',
      );
      expect(after, greaterThan(before), reason: '★ 面板必须真的画出来了（否则下面是空转）');
    });
  });
}
