import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/settings/about_page.dart';
import 'package:sourin_spike/ui/widgets/release_notes.dart';
import 'package:sourin_spike/ui/widgets/update_dialog.dart';

import 'support/ui_shot.dart';

/// 关于页 / 更新对话框的无头截图 + 结构断言
///
/// ⚠️ 这里**不**把真「关于」页整个拉起来（它 initState 里会打 FFI 核心），
///    而是渲染对话框与「更新下载方式」区块本身 —— 用户看得见的那部分。
void main() {
  setUpAll(loadRealFonts);

  ReleaseInfo release() => parseReleaseJson(jsonDecode(
          File('test/fixtures/github_release_v1_1_0.json').readAsStringSync())
      as Map<String, dynamic>);

  final windowsOnly = ReleaseInfo(
    tag: 'v1.1.0',
    name: '',
    notes: '只有 Windows 包',
    assets: const [
      ReleaseAsset(
        name: 'Sourin-Setup-1.1.0.exe',
        size: 29800000,
        url: 'https://example.com/x.exe',
        browserUrl: 'https://example.com/x.exe',
      ),
    ],
    prerelease: false,
    htmlUrl: '',
    publishedAt: null,
  );

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('sourin_update_ui');
    await UiPrefs.load(tmp.path);
    AppUpdateController.instance.loadPrefs();
    AppUpdateController.instance.debugResetAvailable();
    AppUpdateController.instance.debugSetDownloadState(UpdateDownloadState.idle);
  });

  Widget host(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Microsoft YaHei UI',
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C4DFF),
            brightness: Brightness.dark,
          ),
        ),
        home: Scaffold(body: Center(child: child)),
      );

  /// 拉起对话框（返回触发器，点它开窗）
  Widget opener(ReleaseInfo rel, UpdatePlatform platform) => Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showUpdateDialog(ctx, rel, platform: platform),
          child: const Text('打开'),
        ),
      );

  testWidgets('更新对话框：版本号、说明、三个动作都在', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(opener(release(), UpdatePlatform.windows)));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('发现新版本 1.1.0'), findsOneWidget);
    expect(find.textContaining('Sourin-Setup-1.1.0.exe'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('忽略此版本'), findsOneWidget);

    final f = await saveViewShot(tester, 'update_dialog');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('版本说明被正确渲染（标题/列表/加粗/链接）', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(opener(release(), UpdatePlatform.macos)));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('本次更新'), findsOneWidget, reason: '## 标题');
    expect(find.textContaining('按 ABI 选择安装包'), findsOneWidget);
    expect(find.text('第一项'), findsOneWidget);
    expect(find.textContaining('发行说明'), findsOneWidget,
        reason: '[文字](链接) 应渲染成可读文字，而不是把原始语法露出来');
    expect(find.textContaining('dmg'), findsOneWidget);

    final f = await saveViewShot(tester, 'update_dialog_macos');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('没有本平台安装包时给出说明、下载按钮变灰', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(opener(windowsOnly, UpdatePlatform.macos)));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有提供当前设备的安装包'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '下载更新'));
    expect(btn.onPressed, isNull, reason: '没有可下的东西就不能让用户点下载');

    final f = await saveViewShot(tester, 'update_dialog_no_asset');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('下载中：进度条与取消都在', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    final c = AppUpdateController.instance;
    await tester.pumpWidget(host(_afterBuild(
      () => c.debugSetDownloadState(const UpdateDownloadState(
          active: true, bytes: 12 << 20, total: 28 << 20)),
      opener(release(), UpdatePlatform.windows),
    )));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('正在下载'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    final f = await saveViewShot(tester, 'update_dialog_downloading');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('下载失败：错误以提示条出现，不弹第二个窗', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    final c = AppUpdateController.instance;
    await tester.pumpWidget(host(_afterBuild(
      () => c.debugSetDownloadState(const UpdateDownloadState(
          active: false, error: '下载失败，请检查网络或下载方式设置')),
      opener(release(), UpdatePlatform.windows),
    )));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('下载失败'), findsOneWidget);
    final f = await saveViewShot(tester, 'update_dialog_error');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('「更新下载方式」三种选择都渲染得出来', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    AppUpdateController.instance.setRoute(const UpdateRouteConfig());
    await tester.pumpWidget(host(const UpdateRouteEditor()));
    await tester.pumpAndSettle();

    expect(find.text('直连下载'), findsOneWidget);
    expect(find.text('通过代理下载'), findsOneWidget);
    expect(find.text('镜像加速下载'), findsOneWidget);

    var f = await saveViewShot(tester, 'update_route_direct');
    expect(f.existsSync(), isTrue);

    // 切到代理：地址/端口/跟随系统应出现
    await tester.tap(find.text('通过代理下载'));
    await tester.pumpAndSettle();
    expect(find.text('代理地址（如 127.0.0.1）'), findsOneWidget);
    expect(find.text('端口（如 7890）'), findsOneWidget);
    expect(find.text('跟随系统代理设置'), findsOneWidget);
    f = await saveViewShot(tester, 'update_route_proxy');
    expect(f.existsSync(), isTrue);

    // 切到镜像：预置镜像 + 自定义输入 + 那句说明
    await tester.tap(find.text('镜像加速下载'));
    await tester.pumpAndSettle();
    expect(find.text('ghfast'), findsOneWidget);
    expect(find.textContaining('获取更新信息仍走直连或代理'), findsOneWidget);
    f = await saveViewShot(tester, 'update_route_mirror');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('手机窄屏下更新对话框不溢出', (tester) async {
    await setShotViewport(tester, const Size(412, 915));
    await tester.pumpWidget(
        host(opener(release(), UpdatePlatform.android)));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final f = await saveViewShot(tester, 'update_dialog_phone');
    expect(f.existsSync(), isTrue);
  });

  testWidgets('各种窗口尺寸下都不溢出（桌面/手机/电视）', (tester) async {
    // 看不到图的替代验证：RenderFlex 溢出与 RenderBox 越界都会抛异常，
    // 这里逐个尺寸 pump 一遍并断言没有 —— 三种输入形态各自不会把按钮挤出屏幕。
    for (final size in const [
      Size(1440, 900), // 桌面
      Size(1920, 1080), // 电视
      Size(412, 915), // 手机
      Size(360, 640), // 小屏手机（最紧）
    ]) {
      await setShotViewport(tester, size);
      await tester.pumpWidget(host(opener(release(), UpdatePlatform.android)));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '更新对话框 @ $size');
      expect(find.text('下载更新'), findsOneWidget, reason: '@ $size');
      expect(find.text('忽略此版本'), findsOneWidget, reason: '@ $size');

      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(const UpdateRouteEditor()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '下载方式 @ $size');
      expect(find.text('镜像加速下载'), findsOneWidget, reason: '@ $size');
    }
  });

  testWidgets('空说明退化成一句话，不留空白', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(SingleChildScrollView(
      child: Column(children: buildReleaseNotes('', linkColor: Colors.white)),
    )));
    await tester.pumpAndSettle();
    expect(find.text('这个版本没有写说明。'), findsOneWidget);
  });
}

/// 首帧之后执行一次（用来先摆好控制器状态，再让用户点开对话框）
Widget _afterBuild(VoidCallback after, Widget child) {
  WidgetsBinding.instance.addPostFrameCallback((_) => after());
  return child;
}