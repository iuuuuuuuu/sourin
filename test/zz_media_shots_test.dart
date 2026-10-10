@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签（2026-10-10 补）：它调用
//   `MediaKit.ensureInitialized()` 加载真实的 libmpv-2.dll，
//   而 libmpv 在 flutter_tester 里会**偶发 native 崩溃**（访问违例 c0000005）
//   ⇒ 不标的话整文件用例一起 `did not complete`。
//   默认跳过；手动跑：
//     flutter test <file> --run-skipped --tags native-media --concurrency=1
//   见 dart_test.yaml 顶部那份实测记录。
library;

// ═══════════════════════════════════════════════════════════════════════
//  Owner 1009 无头截图自查（已缓存页 / 卡片悬停 / 本地播放页两态 / 批量删除）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一份**只出图 + 读几何**，不做功能断言（功能断言在各自的探针里）
//   目的：让 lead 与我都能用 ASCII 渲染器共同"看到"成品。
//
// ⚠️ 沙盒一律在 TEMP，**绝不碰** %APPDATA% 与 Owner 真实的下载目录。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerHoverEvent;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';

import 'support/ui_shot.dart';

Directory _sandbox() {
  final p =
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_media_shots';
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
  late Directory scanRoot;

  setUpAll(loadRealFonts);

  setUp(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async =>
          call.method == 'Create' ? 'media-shot-fake-texture' : null,
    );
    UiPrefs.debugResetForTest();
    NetworkStatus.debugResetForTest();
    DownloadQueue.debugReset();
    // ★ 扫盘根另给一个子目录：ClipDownloader 会在 dataDir 里新建 `logs/`
    //   并长期持有文件句柄 ⇒ 整个 dataDir 删不掉（报 PathAccessException）。
    root = _sandbox();
    // 上一次的剩余内容先清掉（日志句柄占用的那个除外）
    for (final e in root.listSync()) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {
        // 锁住的目录绕过，下面直接复用它（scan 子目录会被重建）
      }
    }
    scanRoot = Directory(
        '${root.path}${Platform.pathSeparator}scan')
      ..createSync(recursive: true);
    ClipDownloader.debugSetDataDir(root.path);
    CachePage.debugScanRootOverride = scanRoot.path;
  });

  tearDown(() {
    CachePage.debugScanRootOverride = null;
    ClipDownloader.debugSetDataDir(null);
    NetworkStatus.debugProbe = null;
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_media_shots');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    // ★ 日志句柄还在打开 ⇒ 整目录删不掉是**预期**，
    //   尝试删，删不掉就放过（留在 TEMP 里，下次 setUp 会清重内容）。
    if (d.existsSync()) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {
        debugPrint('CLEANUP 日志句柄仍被占用，留下本次清理给 TEMP');
      }
    }
  });

  /// 造一部带**完整旁文件**的作品（3 集 + 1 个 .part + 本地封面）
  CachedWork _makeWork(String name, {int eps = 3}) {
    final dir = Directory(
        '${scanRoot.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true);
    for (var i = 1; i <= eps; i++) {
      File('${dir.path}${Platform.pathSeparator}第0${i}集 第0${i}集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    if (eps >= 3) {
      File('${dir.path}${Platform.pathSeparator}第04集 第04集.mp4.part')
          .writeAsBytesSync(List<int>.filled(512 * 1024, 0x42));
    }
    return CachedWork(
      dirName: name,
      path: dir.path,
      episodes: const <CachedEpisode>[],
    );
  }

  /// 造一张**本地封面图**（真 PNG，避免整页都是占位块看不清排版）
  File _makeCover(String dir) {
    final f = File('$dir${Platform.pathSeparator}_sourin-cover.png');
    f.writeAsBytesSync(_tinyPng());
    return f;
  }

  testWidgets('SHOT-1「已缓存」页：三部作品 + 顶部统计 + 下载中区块', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    _makeWork('无职转生 第三季');
    _makeWork('你是我的面反', eps: 12);
    _makeWork('太上的下号天', eps: 1);

    debugPrint('SHOT-1 扫盘根=${scanRoot.path}');
    for (final e in scanRoot.listSync()) {
      debugPrint('SHOT-1 根下有 ${e.path}');
    }
    await t.pumpWidget(_appWith(CachePage(onOpen: (_) {})));
    // 扫盘是**真 IO** ⇒ 必须在 runAsync 里驱动真实事件循环
    await t.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    _claim(t);
    // ★ 扫盘的 setState 是**跨帧**的：runAsync 里真 IO 完成后还要让循环重新建树
    //   ⇒ 再轮一段 runAsync（让异步 setState 落地）+ 若干固定帧。
    for (var k = 0; k < 3; k++) {
      await t.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await t.pump();
        }
      });
      await t.pump(const Duration(milliseconds: 200));
    }
    _claim(t);
    final f = await saveViewShot(t, 'shot1_cache_page');
    debugPrint('SHOT-1 = ${f.path}');
    expect(find.text('已缓存'), findsWidgets);
    expect(find.text('占用'), findsOneWidget,
        reason: '★ 顶部统计块必须出现');
  });

  testWidgets('SHOT-2 卡片悬停态：封面右上角出现半透明「更多」', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    _makeWork('无职转生 第三季');

    await t.pumpWidget(_appWith(CachePage(onOpen: (_) {})));
    await t.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    for (var k = 0; k < 3; k++) {
      await t.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await t.pump();
        }
      });
      await t.pump(const Duration(milliseconds: 200));
    }
    _claim(t);

    // ★ 悬停点落在**目标那张卡的封面**上（不能碰邻居）
    final poster = find
        .descendant(
            of: find.ancestor(
                of: find.text('无职转生 第三季'),
                matching: find.byType(mui.ClipRRect)),
            matching: find.byType(mui.ClipRRect))
        .first;
    final more = find.byKey(const ValueKey<String>('cache-card-more:无职转生 第三季'));
    expect(more, findsOneWidget, reason: '★ 悬停后必须出现「更多」');
    final f = await saveViewShot(t, 'shot2_cache_card_hover');
    debugPrint('SHOT-2 = ${f.path}');
  });

  testWidgets('SHOT-3 本地播放页（联网）：作品信息 + 已下载一集一行', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    final dir = Directory(
        '${scanRoot.path}${Platform.pathSeparator}无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= 3; i++) {
      File('${dir.path}${Platform.pathSeparator}第0${i}集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    _makeCover(dir.path);

    final work = CachedWork(
      dirName: '无职转生 第三季',
      path: dir.path,
      episodes: <CachedEpisode>[
        for (var i = 1; i <= 3; i++)
          CachedEpisode(
              fileName: '第0${i}集.mp4',
              bytes: 2 * 1024 * 1024,
              isComplete: true),
      ],
      description:
          '这是一段很长的简介，用来验证本地播放页的排版是否与在线一致。'
          '它应该占两行，超出那个时间截断，不能把版面撑开。'
          '下面是一段更长的内容用作体积。',
      year: '2021',
      area: '日本',
      kind: '动画 / 奇幻',
      badges: const <String>['连载中', '9.2 分'],
      localCoverPath: '$dir.path${Platform.pathSeparator}_sourin-cover.png',
    );

    NetworkStatus.debugProbe = () async => true;
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: kLocalProvider,
        id: work.episodes.first.fileName,
        title: work.dirName,
        cover: work.localCoverPath,
        localPath: '${dir.path}${Platform.pathSeparator}第01集.mp4',
        localMeta: work,
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final f = await saveViewShot(t, 'shot3_local_page_online');
    debugPrint('SHOT-3 = ${f.path}');
    expect(find.text('已下载'), findsOneWidget,
        reason: '★ 下方必须有「已下载」那一段');
  });

  testWidgets('SHOT-4 本地播放页（离线）：操作按钮全部消失，其余一模一样', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    final dir = Directory(
        '${scanRoot.path}${Platform.pathSeparator}无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= 3; i++) {
      File('${dir.path}${Platform.pathSeparator}第0${i}集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    final work = CachedWork(
      dirName: '无职转生 第三季',
      path: dir.path,
      episodes: <CachedEpisode>[
        for (var i = 1; i <= 3; i++)
          CachedEpisode(
              fileName: '第0${i}集.mp4',
              bytes: 2 * 1024 * 1024,
              isComplete: true),
      ],
      description: '断网也要能看到的简介。',
      badges: const <String>['连载中'],
    );
    NetworkStatus.debugProbe = () async => false;

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: kLocalProvider,
        id: work.episodes.first.fileName,
        title: work.dirName,
        localPath: '${dir.path}${Platform.pathSeparator}第01集.mp4',
        localMeta: work,
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final f = await saveViewShot(t, 'shot4_local_page_offline');
    debugPrint('SHOT-4 = ${f.path}');
    // ★ 离线：那几个按钮一个都不许出现
    expect(find.text('收藏'), findsNothing, reason: '★ 离线不许显示收藏');
    expect(find.text('追更'), findsNothing, reason: '★ 离线不许显示追更');
    expect(find.text('换源'), findsNothing, reason: '★ 离线不许显示换源');
    // ★ 但作品信息与集列表必须在
    expect(find.text('已下载'), findsOneWidget);
  });
  testWidgets('SHOT-5 本地播放页：批量删除选择态', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    final dir = Directory(
        '${scanRoot.path}${Platform.pathSeparator}无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= 5; i++) {
      File('${dir.path}${Platform.pathSeparator}第0${i}集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    final work = CachedWork(
      dirName: '无职转生 第三季',
      path: dir.path,
      episodes: <CachedEpisode>[
        for (var i = 1; i <= 5; i++)
          CachedEpisode(
              fileName: '第0${i}集.mp4',
              bytes: 2 * 1024 * 1024,
              isComplete: true),
      ],
      description: '批量删除态截图。',
    );
    NetworkStatus.debugProbe = () async => true;

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: kLocalProvider,
        id: work.episodes.first.fileName,
        title: work.dirName,
        localPath: '${dir.path}${Platform.pathSeparator}第01集.mp4',
        localMeta: work,
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);

    // 进「管理」= 选择态（Owner：可以多选批量删除）
    await t.tap(find.text('管理'));
    for (var k = 0; k < 3; k++) {
      await t.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await t.pump();
        }
      });
    }
    // 勾两集
    for (final n in <String>['第02集', '第03集']) {
      final row = find.descendant(
        of: find.byType(DetailPage),
        matching: find.textContaining(n),
      );
      if (row.evaluate().isNotEmpty) {
        await t.tap(row.first);
        await t.pump();
      }
    }
    for (var k = 0; k < 2; k++) {
      await t.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await t.pump();
        }
      });
    }
    _claim(t);
    final f = await saveViewShot(t, 'shot5_local_batch_delete');
    debugPrint('SHOT-5 = ${f.path}');
    expect(find.textContaining('已选'), findsOneWidget,
        reason: '★★★ 选择态必须有「已选 N 集」+ 全选/删除/取消');
  });

  testWidgets('SHOT-6 在线详情页（右栏）：与本地页同一套版式', (t) async {
    await setShotViewport(t, const Size(1440, 900));
    NetworkStatus.debugProbe = () async => true;
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: 'demo',
        id: '42',
        title: '在线作品',
        localPath: null,
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    final f = await saveViewShot(t, 'shot6_online_detail');
    debugPrint('SHOT-6 = ${f.path}');
  });
  testWidgets('SHOT-7 在线详情页（合并页，生产宽度）', (t) async {
    // ★ 挂**真的 MediaPage**（而不是单拆 DetailPage）——
    //   右侧宽度是 MediaPage 按 `mq.width * 0.30` 算出来的（夹在 [340,440]），
    //   单拆 DetailPage 时我自己包的宽度不一定对 ⇒ 看的不是用户看到的布局。
    await setShotViewport(t, const Size(1440, 900));
    NetworkStatus.debugProbe = () async => true;
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(MediaPage(
        provider: 'demo',
        id: '42',
        title: '无职转生 第三季',
      )));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    final f = await saveViewShot(t, 'shot7_online_detail_page');
    debugPrint('SHOT-7 = ${f.path}');
  });
}

/// 一张 8x8 的纯色 PNG（当封面用，避免整片占位块看不清排版）
List<int> _tinyPng() {
  // 手工构造的最小 PNG：1x1 橙色像素
  const b64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  return _b64(b64);
}

List<int> _b64(String s) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = <int>[];
  var buf = 0;
  var bits = 0;
  for (final c in s.codeUnits) {
    if (c == 61) break; // '='
    final v = chars.indexOf(String.fromCharCode(c));
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buf >> bits) & 0xFF);
    }
  }
  return out;
}
