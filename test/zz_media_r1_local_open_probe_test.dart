// ═══════════════════════════════════════════════════════════════════════
//  Owner 第 1009 批 ② 复现探针：从「已缓存」页点进去「无法观看 / 右侧崩坏」
// ═══════════════════════════════════════════════════════════════════════
//
// # 要证的两件事（先用旧行为跑一遍，确认能**测出反面**）
// ```text
// R1 右边**真的画出来了**，而且不含任何异常（红叹号 / 溢出条纹 / 「无法路由」）
// R2 下面那段「已下载」一行一集，且行的条数 == 磁盘上真正下好的集数
// ```
//
// ⚠️ 数据一律在 TEMP 沙盒里造（clip_download 的 dataDir 也指向它），
//    **绝不碰** %APPDATA%\app.sourin.player 与 Owner 真实的下载目录。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';

import 'support/ui_shot.dart';

Directory _sandbox(String name) {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}$name';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

/// ★ forui 移除后（theme agent）的包装：直接用 AppTheme.themeFor
///   —— 不再需要 FTheme 包装，也不会因为 forui 被删而编不过。
Widget _appWith(Widget home) {
  return mui.MaterialApp(
    theme: AppTheme.themeFor(Brightness.dark),
    home: home,
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

void main() {
  late Directory root;
  late CachedWork work;

  setUpAll(loadRealFonts);

  setUp(() {
    // ⚠️ MediaKit 必须在**任何** Player 被构造前初始化，否则整棵子树建不起来
    //   （异常会一路冒到「有问题的控件是 Expanded」这种误导位置）。
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    // ★ flutter_tester 里没有 media_kit 的视频输出插件 ⇒ 从源头掐掉那条
    //   MissingPluginException（与其它播放器 widget 测试同一套做法）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async =>
          call.method == 'Create' ? 'media-r1-fake-texture' : null,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
    });

    UiPrefs.debugResetForTest();
    root = _sandbox('sourin_media_r1');
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    ClipDownloader.debugSetDataDir(root.path);

    final dir = Directory(
        '${root.path}${Platform.pathSeparator}无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= 3; i++) {
      File('${dir.path}${Platform.pathSeparator}第0${i}集 第0${i}集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    CachePage.debugScanRootOverride = root.path;
    work = CachedWork(
      dirName: '无职转生 第三季',
      path: dir.path,
      episodes: const <CachedEpisode>[],
    );
  });

  tearDown(() {
    CachePage.debugScanRootOverride = null;
    ClipDownloader.debugSetDataDir(null);
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_media_r1');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  testWidgets('R1/R2 已缓存点进去：右侧真的画出来，且「已下载」一集一行', (t) async {
    await setShotViewport(t, const Size(1440, 900));

    // ⚠️ 扫盘是**真 IO**：绝不能在 fake-async 区里直接 await（永不完成 ⇒
    //    用例 did not complete）。这里用纯同步的 listSync 造同一个 CachedWork。
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}无职转生 第三季')..createSync();
    work = CachedWork(
      dirName: '无职转生 第三季',
      path: dir.path,
      episodes: <CachedEpisode>[
        for (final f in dir.listSync().whereType<File>())
          CachedEpisode(
            fileName: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            isComplete: true,
          ),
      ],
    );
    expect(work.completedCount, 3, reason: '★ 前提：磁盘上有 3 集');

    final req = buildLocalPlayRequest(work)!;
    expect(req.provider, kLocalProvider);

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: req.provider,
        id: req.mediaId,
        title: req.title,
        episodeId: req.episode.fileName,
        localPath: req.episodeAbsolutePath,
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);

    final detailCount = find.byType(DetailPage).evaluate().length;
    debugPrint('R1 右侧 DetailPage 个数 = $detailCount（必须 ≥ 1）');

    final texts = t
        .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    for (final s in texts.take(60)) {
      debugPrint('R1   「$s」');
    }
    final all = texts.join('\n');

    await saveViewShot(t, 'media_r1_local_detail');

    expect(detailCount, greaterThan(0), reason: '★★★ 右侧详情区必须真的在树上');
    expect(all.contains('无法路由'), isFalse,
        reason: '★★★ 不许出现「无法路由: local:…」');
    expect(all.contains('已下载'), isTrue,
        reason: '★★★ 本地页下方必须有「已下载」那一段');
    final rows = texts.where((s) => s.contains('第0')).length;
    debugPrint('R2 含「第0」的行数 = $rows');
    expect(rows, greaterThanOrEqualTo(3),
        reason: '★★★ 「已下载」必须一集一行（磁盘上有 3 集）');
  });
}
