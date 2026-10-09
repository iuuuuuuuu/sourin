// 头部截图自查（polish 区域：外壳 / 首页 / 追更 / 浏览 / 直播）
//
// 为什么要有这个文件：本区域每次改版都要"看一眼再交付"，
// 而锁屏时真窗口截图拿不到（见共用说明第 5 节）⇒ 用无头截图。
//
// ⚠️ 它是**自查工具**，不是断言文件：只断言"截图落盘了"，
//    像素好不好看靠人（agent）读 PNG —— 把"好不好看"写成断言
//    只会得到一条恒真的断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart' as models;
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/browse_page.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

import 'support/ui_shot.dart';

/// 造一个能渲染的源清单
List<models.ProviderManifest> _manifests() => [
      models.ProviderManifest(
          id: 'cycani', name: '影视仓', working: true, enabled: true, icon: '🎬'),
      models.ProviderManifest(
          id: 'bili', name: '哔哩哔哩', working: true, enabled: true, icon: '📺'),
      models.ProviderManifest(
          id: 'iqiyi', name: '爱奇艺', working: true, enabled: true, icon: ''),
      models.ProviderManifest(
          id: 'qq', name: '腾讯视频', working: true, enabled: true, icon: '🐧'),
      models.ProviderManifest(
          id: 'mfy', name: '魔方', working: false, enabled: true, icon: ''),
    ];

Widget host(Widget child, Size size) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

/// 首页源切换条单独出图（它是"内容区"的一部分，脱离 shell 看更清楚）
Future<void> _sourceBarShot(WidgetTester t) async {
  await setShotViewport(t, const Size(1440, 900));
  await t.pumpWidget(host(
    Center(
      child: SourceBar(
        sources: _manifests(),
        current: 'bili',
        onSelect: (_) {},
      ),
    ),
    const Size(1440, 900),
  ));
  await t.pumpAndSettle();
  final f = await saveViewShot(t, 'polish_source_bar_desktop');
  expect(f.existsSync(), isTrue);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('外壳（桌面）：完整 shell 首屏', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    await t.pumpWidget(host(
        ShellPage(key: debugShellKey), const Size(1440, 900)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    // 认领环境噪声（测试进程里没有核心库 ⇒ FFI 必抛）
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_shell_desktop');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('外壳（手机 412×915）', (t) async {
    await setShotViewport(t, const Size(412, 915));
    await t.pumpWidget(
        host(ShellPage(key: debugShellKey), const Size(412, 915)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_shell_phone');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('外壳（TV 1920×1080）', (t) async {
    await setShotViewport(t, const Size(1920, 1080));
    await t.pumpWidget(
        host(ShellPage(key: debugShellKey), const Size(1920, 1080)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_shell_tv');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('首页：含源切换条', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    await t.pumpWidget(
        host(const HomePage(), const Size(1440, 900)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_home_desktop');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('源切换条：单独出图', _sourceBarShot);

  testWidgets('追更页：继续观看', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    await t.pumpWidget(
        host(const FollowPage(initialTab: 'continue'), const Size(1440, 900)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final st = t.state<FollowPageState>(find.byType(FollowPage));
    st.debugSetContinueList([
      for (var i = 0; i < 18; i++)
        models.Progress(
          key: 'cycani:$i',
          provider: 'cycani',
          nativeId: '$i',
          title: i == 0
              ? '一个很长的剧名用来测试标题在卡片里的截断与换行表现'
              : '剧名 $i',
          episodeTitle: '第 ${i % 9 + 1} 集',
          position: 100 + i * 37,
          duration: 2400,
          updatedAt: 1700000000 + i,
        ),
    ]);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_follow_desktop');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('浏览页：网格 + 吸顶页头', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    await t.pumpWidget(host(
      BrowsePage(
        provider: 'cycani',
        categoryId: '1',
        title: '电影',
        pageLoaderForTest: (page) async => models.Page<models.MediaItem>(
          items: [
            for (var i = 1; i <= 24; i++)
              models.MediaItem(
                id: 'cycani:$i',
                title: '影片标题 $i',
                note: '更新至 ${i % 12 + 1} 集',
              ),
          ],
          page: page,
          pageCount: 5,
        ),
      ),
      const Size(1440, 900),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_browse_desktop');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('直播页：加载骨架（无核心库 ⇒ 取不到频道，这是真实首屏形态）',
      (t) async {
    await setShotViewport(t, const Size(1440, 900));
    await t.pumpWidget(host(const LivePage(), const Size(1440, 900)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    var n = 0;
    while (t.takeException() != null && n++ < 50) {}
    final f = await saveViewShot(t, 'polish_live_desktop');
    expect(f.existsSync(), isTrue);
  });

  test('截图目录已指定（否则上面的文件会落到默认位置）', () {
    expect(Platform.environment['SOURIN_SHOT_DIR'],
        isNotNull,
        reason: '必须由调用方设 SOURIN_SHOT_DIR，否则会写到仓库里');
  });
}