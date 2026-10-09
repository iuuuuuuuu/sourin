// settings agent 的无头截图台（自用，不是断言型测试）。
// 只 pump + 落盘 PNG，供人工看图自查。
//
// ⚠️ 两个必须知道的坑：
//   ① 页面首帧常是转圈态 —— 只 pump 一帧会截到一片黑，
//      必须反复 pump 让异步加载（含跨 FFI 的那几趟）真正落地。
//   ② 需要真核心时把 sourin_core.dll 拷到 worktree 根再跑，
//      跑完**必须删掉**（它存在会让约 30 条 widget 测试因
//      「A Timer is still pending」变红）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings/emby_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/plugin_edit_dialog.dart';

import 'support/ui_shot.dart';

Widget _app(Widget home) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: home),
  );
}

/// 反复 pump，直到真的画出内容（而不是转圈 / 空页）。
///
/// ⚠️★ 必须包在 `tester.runAsync` 里：`SettingsPage.initState` 会 `await`
///   一串走 FFI 的加载，而 `testWidgets` 默认在 **FakeAsync** 下 pump ——
///   那些真异步的 gap 永远不完成 ⇒ `_loading` 永远是 true ⇒ 截出来一片黑。
///   `runAsync` 期间定时器按**真实时钟**走，加载才会真正落地。
///   （代价：这段时间里不再推进测试的假时钟，所以不要在 runAsync 里
///   依赖 `pump(Duration)` 的动画推进。）
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 120),
        ));
    await tester.pump();
  }
}

void main() {
  final dataDir = Platform.environment['SOURIN_SHOT_DATA'];

  setUpAll(() async {
    loadRealFonts();
    if (dataDir != null) await SourinCore.startAsync(dataDir);
  });

  // ⚠️ 这个截图台要**真核心**才能截到真实内容（否则设置页永远是转圈态、
  //   截出来一片黑）。环境依赖型测试必须门控 —— 没数据目录就跳过。
  const gate =
      '需要真核心才能截到真实内容。跑法：把 rust/sourin_core/target/release/'
      'sourin_core.dll 拷到 worktree 根，再带 SOURIN_SHOT_DIR=<输出目录> 与 '
      'SOURIN_SHOT_DATA=<临时数据目录> 跑，跑完把 dll 删掉。';

  testWidgets('设置首页 · 桌面', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const SettingsPage()));
    await settle(tester);
    // ignore: avoid_print
    print('SHOT-TREE 设置桌面: ' + _probe(tester).join(' | '));
    await saveViewShot(tester, 'settings_home_desktop');
  });

  testWidgets('设置首页 · 手机', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(412, 915));
    await tester.pumpWidget(_app(const SettingsPage()));
    await settle(tester);
    await saveViewShot(tester, 'settings_home_phone');
  });

  testWidgets('Emby 页 · 桌面', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const EmbySettingsPage()));
    await settle(tester);
    await saveViewShot(tester, 'emby_desktop');
  });

  testWidgets('插件编辑对话框', (tester) async {
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(
      _app(const Scaffold(
        body: Center(child: PluginEditDialogBody()),
      )),
    );
    await settle(tester);
    await saveViewShot(tester, 'plugin_edit_dialog');
  });

  testWidgets('搜索页 · 桌面', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const SearchPage()));
    await settle(tester);
    await saveViewShot(tester, 'search_desktop');
  });

  testWidgets('搜索页 · 手机', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(412, 915));
    await tester.pumpWidget(_app(const SearchPage()));
    await settle(tester);
    await saveViewShot(tester, 'search_phone');
  });

  test('输出目录', () {
    // ignore: avoid_print
    print('SHOTDIR=${shotDir().path}');
  });
}

/// 截图台自检用：把「这一帧到底画出了什么」打出来，避免截到空页还当成功。
List<String> _probe(WidgetTester tester) => [
      if (find.text('设置').evaluate().isNotEmpty) '标题',
      if (find.text('内容源与插件').evaluate().isNotEmpty) '组:内容源与插件',
      if (find.text('JS 插件').evaluate().isNotEmpty) '入口:JS插件',
      if (find.text('远程').evaluate().isNotEmpty) '组:远程',
      if (find.text('外观').evaluate().isNotEmpty) '组:外观',
      if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty)
        '还在转圈',
      if (find.byType(ErrorWidget).evaluate().isNotEmpty) 'ErrorWidget',
    ];
