// ═══════════════════════════════════════════════════════════════════════
//  task-12 **缺陷 A** 探针：右侧按「磁盘状态」判，而不是内存队列
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 真机截图暴露的必现缺陷（这是本探针要钉住的）
// ```text
// 真实下载的《无职转生 第三季》第01集（798 MB）在播，右侧一片：
//   SourinCoreException(other): 无法路由: local:c:/users/.../第01集 第01集.mp4
// 根因：右侧原来按**内存队列**判（media_page.dart:987-999），
//       重启后队列空 ⇒ 退回 DetailPage ⇒ DetailPage 拿 (local, 绝对路径)
//       去拉详情 ⇒ Rust registry.route() 没有 local 这个 provider ⇒ 抛。
// ★ 存量下载**没有旁文件**（旁文件是 task-12 才加的）⇒ 这是必经之路。
// ```
//
// # 本探针要证的三条
// ```text
// A-1 队列为空 + 磁盘有已下好的集  ⇒ 右侧**仍然**是 DownloadPanel（不再退回详情）
// A-2 那一行真的写着「已下载」+ 有「播放」按钮，且总量与磁盘一致
// A-3 ★ 点「播放」⇒ 组织出的会话是 (local, 规范化绝对路径)，
//       并且**带上 localPath**（= 走本地播放，不再去网络解析 ⇒ 不会有「无法路由」）
// ```
//
// ⚠️ 硬规则：沙盒在 $env:TEMP，带 isAbsolute 断言 + 自清理；
//    **绝不碰** %APPDATA%\app.sourin.player。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/widgets/download_panel.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Directory _sandbox() {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t3_12_defA';
  if (!Directory(p).isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  return Directory(p)..createSync(recursive: true);
}

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) =>
        AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

void main() {
  late Directory root;
  late String workDir;

  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  /*
   * ★★ 给 media_kit 的**视频输出通道**装一个假实现
   * ```text
   * `MediaPage` 里挂着 `PlayerPage`，它的 `VideoController` 会抛
   *   MissingPluginException(VideoOutputManager.Create on … media_kit_video)。
   * ★ 那是「flutter_tester 里没有平台插件」的**固有事实**，与缺陷 A 无关
   *   （local_probe 那轮已经踩过并验证过这个修法）。
   * ⇒ 从源头掐掉：让 Create 返回一个句柄。
   * ```
   */
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'Create') return 't3_12-defA-fake-texture';
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
    });

    UiPrefs.debugResetForTest();
    DownloadQueue.debugReset();        // ★ 模拟「客户端刚重启」：内存队列为空
    ClipDownloader.debugSetDataDir(null);
    root = _sandbox();
    // 清掉上一轮
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    workDir = '${root.path}${Platform.pathSeparator}无职转生 第三季';
    Directory(workDir).createSync(recursive: true);
    // ★ 造两集**下好**的（无旁文件 —— 正是存量下载的形态）
    File('$workDir${Platform.pathSeparator}第01集 第01集.mp4')
        .writeAsBytesSync(List<int>.filled(3 * 1024 * 1024, 0x42));
    File('$workDir${Platform.pathSeparator}第02集 第02集.mp4')
        .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    // 一集没下完的（.part）—— 不该进「已下载好」列表
    File('$workDir${Platform.pathSeparator}第03集 第03集.mp4.part')
        .writeAsBytesSync(List<int>.filled(1024 * 1024, 0x42));
    // ★ 探针注入点：让扫盘落在沙盒（与「已缓存」页共用同一个注入点）
    CachePage.debugScanRootOverride = root.path;
    DownloadQueue.debugSetResolver(null);
  });

  tearDown(() {
    CachePage.debugScanRootOverride = null;
  });

  tearDownAll(() {
    final d = Directory(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t3_12_defA',
    );
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除 ${d.path} 存在=${d.existsSync()}');
  });

  // ══════════════════════════════════════════════════════════════════
  //  A-1 / A-2：队列为空 + 磁盘有货 ⇒ 右侧仍是面板，且列出磁盘上的集
  // ══════════════════════════════════════════════════════════════════

  testWidgets('A-1/A-2 重启后（队列空）右侧仍列出磁盘上已下好的集', (t) async {
    // ★ 先确认前提：内存队列**真的**是空的（模拟重启成功）
    expect(DownloadQueue.tasks.value.length, 0,
        reason: '★ 前提：内存队列必须为空（模拟客户端重启）');

    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    /*
     * ★★ `MediaPage` 的挂载必须在 runAsync 里（与 PlayerPage 相反！）
     * ```text
     * 实测：直接 `pumpWidget` ⇒ 用例 **did not complete**（25 秒无进展）。
     * 根因：MediaPage.initState 里有真 IO ——
     *   windowManager.addListener / `_syncFullscreen()`（碰平台通道 + 真 IO）
     *   ⇒ 它们登记在**受控时钟**上 ⇒ pumpWidget 那一帧永远建不完。
     * ★ 注意与 PlayerPage 的区别：PlayerPage 的 `pumpWidget` **必须**在
     *   runAsync 外面（它就是第一帧）；MediaPage 反过来。
     *   ⇒ 结论不是「哪个对」，而是**每个页面的挂载约束要各自实测**。
     * ```
     */
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        MediaPage(provider: 'local', id: workDir, title: '无职转生 第三季'),
      ));
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);

    final panelCount = find.byType(DownloadPanel).evaluate().length;
    debugPrint('A-1 右侧 DownloadPanel 个数 = $panelCount（必须 ≥ 1）');
    debugPrint('A-1 队列长度 = ${DownloadQueue.tasks.value.length}（必须 = 0）');

    final texts = t
        .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    debugPrint('A-2 屏幕上的字（含「已下载」/集名/大小的）：');
    for (final s in texts.where((s) =>
        s.contains('已下载') || s.contains('第0') || s.contains('MiB'))) {
      debugPrint('A-2   「$s」');
    }
    final stat = texts.where((s) => s.startsWith('已下载 · ')).toList();
    debugPrint('A-2 「已下载 · X」行数 = ${stat.length}（必须 = 2，.part 不算）');

    expect(panelCount, greaterThan(0),
        reason: '★★★ 队列空但磁盘有货 ⇒ 右侧必须仍是下载面板（这正是 Owner 那条报错的根因）');
    expect(stat.length, 2,
        reason: '★★★ 必须恰好列出 2 集已下载好的（第03集是 .part，不算）');
    // ★ 那条报错不许出现
    final all = texts.join('\n');
    expect(all.contains('无法路由'), isFalse,
        reason: '★★★ 不许出现「无法路由: local:…」—— 那正是 Owner 截图里的错');
  });

  // ══════════════════════════════════════════════════════════════════
  //  A-3：点「播放」⇒ 会话是 (local, 规范化绝对路径) 且带 localPath
  // ══════════════════════════════════════════════════════════════════

  test('A-3 点已下载的集 ⇒ 组织出的本地会话带 localPath（不再走网络解析）', () {
    // ★ 直接验「生产那条组织会话的函数」——面板点播放最终就调它
    final w = CachedWork(
      dirName: '无职转生 第三季',
      path: workDir,
      episodes: <CachedEpisode>[
        CachedEpisode(
          fileName: '第01集 第01集.mp4',
          bytes: 3 * 1024 * 1024,
          isComplete: true,
        ),
      ],
    );
    final ep = w.episodes.first;
    final req = buildLocalPlayRequest(w, prefer: ep);
    expect(req, isNotNull);
    debugPrint('A-3 provider = ${req!.provider}（必须 = local）');
    debugPrint('A-3 mediaId  = ${req.mediaId}');
    debugPrint('A-3 本地路径 = ${req.episodeAbsolutePath}');
    debugPrint('A-3 fileUrl  = ${req.fileUrl}');
    expect(req.provider, kLocalProvider);
    expect(req.mediaId, canonicalLocalPath(req.episodeAbsolutePath));
    expect(req.mediaId, isNot(equals(req.episodeAbsolutePath)),
        reason: '★ mediaId 是**规范化后**的 key（小写、正斜杠），与原始路径不同');
    expect(req.episodeAbsolutePath.startsWith(workDir), isTrue);
  });

  // ══════════════════════════════════════════════════════════════════
  //  A-4 ★ 反面对照：磁盘上**没有**这部剧 ⇒ 右侧回到详情页（老行为不变）
  // ══════════════════════════════════════════════════════════════════

  testWidgets('A-4 对照：磁盘上没有这部剧 ⇒ 不画面板（老行为逐字不变）', (t) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        MediaPage(provider: 'cctv', id: 'cctv1', title: '磁盘上没有这部剧'),
      ));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);

    final panelCount = find.byType(DownloadPanel).evaluate().length;
    debugPrint('A-4 对照：右侧 DownloadPanel 个数 = $panelCount（必须 = 0）');
    expect(panelCount, 0,
        reason: '★★ 磁盘上没有 + 队列里也没有 ⇒ 右侧必须还是详情页（不许乱画面板）');
  });
}
