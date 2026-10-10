// ///////////////////////////////////////////////////////////////////////////
//  CR-13 回归探针：详情区点「已下载」的某一集 ⇒ 发出的会话 id 必须是**那一集**
// ///////////////////////////////////////////////////////////////////////////
//
// # 缺陷一句话
// MediaPage._onPlayLocalEpisode 构造 PlayRequestData 时写的是
//     id: _contentId,               ← 进页时那一集的 id，对所有本地集都相同
//     localPath: ref.absolutePath,  ← 但真正播的文件是点的那一集
// ⇒ req.id 与实际播放的文件**不是同一个键**。
//
// # 后果（数据损坏级）
// applySession 的 setState 里 _contentId = req.id（player_page.dart:6758-6759），
// 而 _saveProgress 用 (_provider, _contentId) 当进度主键
// （player_page.dart:5965-5967 SourinApi.saveProgress(_provider, _contentId, …)）
// ⇒ 看第 2 集播了一分钟，进度被写进**第 1 集**那个键：
//   · 第 1 集的续播位置被第 2 集顶掉（进度串集）；
//   · 第 2 集永远显示 0%（_watchRatioOf 查不到自己那一条）。
//
// # 判据
// 点第 N 集（N=2,3），详情区交给播放器的 req.id 必须等于
//   canonicalLocalPath(<第 N 集的绝对路径>)，且**不等于**进页时那一集的键。
//
// # ★★ 为什么改用接缝观测，而不是劫持 debugPrint（原版是假门禁，已实测）
// 原版抓的是 _onDetailPlay 里那行
//   '[MEDIA] 详情区请求播放 ⇒ 转发给当前播放器 (provider:id ep=… src=…)'
// 实测（--concurrency=1，exit 1）：
//   · 断言炸在「抓到日志条数=11」上：11 条里**一条 [MEDIA] 都没有**；
//   · 但 stdout 里紧挨着就有那两行 [MEDIA]/[PLAYER] 日志
//     ⇒ 点击生效、缺陷真复现，**是日志捕获丢了**。
// 根因（flutter_test 源码 binding.dart）：
//   · :1073-1078 构造时 debugPrint = debugPrintOverride（= debugPrintSynchronously）
//   · :1771-1796 FlutterError.onError：第 1 条异常走 reportExceptionNoticed，
//     它把 debugPrint 换成 debugPrintSynchronously 并「记住当时的 debugPrint」；
//     第 2 条异常走 _pendingExceptionDetails != null 分支
//     ⇒ debugPrint = debugPrintOverride ⇒ **测试装的劫持被永久丢掉**。
//   本用例里 media_kit 未初始化必然抛异常（环境噪声，见 dart_test.yaml）
//   ⇒ 那行日志**永远**进不了捕获列表 ⇒ 判据永远是 not null 失败 = 假门禁。
//
// # 现在的观测点（真接缝，生产路径零影响）
// lib/ui/media_page.dart 顶层（@visibleForTesting，与 lib/ui/detail_page.dart:513
// 的 CR-12 接缝 debugLocalOriginRecords 同款）：
//   void Function(PlayRequestData req)? debugOnDetailPlayForward;
//   void debugSetOnDetailPlayForward(void Function(PlayRequestData req)? f);
// 它在 _onDetailPlay 里 **await applySession 之前**、紧挨着那行 debugPrint 被调用
// （media_page.dart:623-624）。为 null 时（生产恒为 null）零行为差异。
//
// 为什么这个点就是缺陷本体 —— req.id 一路原样变成进度主键：
//   _onDetailPlay(req) ⇒ req.id ⇒ MediaSession.applySession(req)
//     ⇒ player_page.dart:6759 _contentId = req.id
//     ⇒ player_page.dart:5965-5967 SourinApi.saveProgress(_provider, _contentId, …)
//
// # 为什么不去断言进度表本身（SourinApi.getProgress）
// flutter test 下 sourin_core.dll 必然加载失败（Failed to load dynamic library，
// 环境噪声）⇒ 真 FFI 进度表读不到；写成那样才是假门禁。
// 本接缝拿到的 req.id 就是**写进那张表时用的键**，语义等价且不依赖 FFI。
//
// # 跑法
//   cmd.exe /c flutter.bat test test/zz_cr_dl_c13_local_episode_id_test.dart --concurrency=1 --reporter=expanded
library;

import 'dart:io';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/media_session.dart';

Directory _sandbox() {
  final p = Directory('${Directory.systemTemp.absolute.path}'
      '${Platform.pathSeparator}cr_dl_c13');
  p.createSync(recursive: true);
  return p;
}

Widget _appWith(Widget home) => mui.MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: home,
    );

/// flutter_tester 里必然有异常（sourin_core.dll 加载失败、window_manager
/// 的 isFullScreen 缺插件、media_kit 未初始化）—— 全是环境噪声，不是缺陷。
/// 不吞掉的话 testWidgets 会因为「unhandled exception」红，掩盖真正的判据。
void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 以「第 01 集」为进页会话打开合并页（与 shell 传进来的形态一致），
/// 并等「已下载」区块把磁盘上的本地集列出来。
Future<void> _openMediaPageOnEp1(
  WidgetTester t, {
  required String key1,
  required String ep1Path,
  required CachedWork work,
}) async {
  await t.runAsync(() async {
    await t.pumpWidget(_appWith(MediaPage(
      provider: kLocalProvider,
      id: key1,
      title: 'CR13 剧',
      episodeId: '第01集 CR13.mp4',
      localPath: ep1Path,
      localMeta: work,
    )));
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
      _claim(t);
    }
  });
  _claim(t);
}

/// 点「已下载」里的某一行（行正文 = CachedEpisode.displayName，不带扩展名）
Future<void> _tapLocalEpisodeRow(WidgetTester t, String rowText) async {
  await t.ensureVisible(find.text(rowText));
  await t.tap(find.text(rowText));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  _claim(t);
}

void main() {
  late Directory root;
  late Directory workDir;
  late CachedWork work;
  late String ep1Path;
  late String key1;

  setUp(() {
    // ★ 掐掉 media_kit 的视频输出插件（flutter_tester 里没有那个插件）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async =>
          call.method == 'Create' ? 'cr13-fake-texture' : null,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
    });

    UiPrefs.debugResetForTest();
    root = _sandbox();
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    ClipDownloader.debugSetDataDir(root.path);
    CachePage.debugScanRootOverride = root.path;
    addTearDown(() {
      CachePage.debugScanRootOverride = null;
      ClipDownloader.debugSetDataDir(null);
      // ★ 接缝必须复位，否则污染同进程里的其他用例
      debugSetOnDetailPlayForward(null);
    });

    final sep = Platform.pathSeparator;
    workDir = Directory('${root.path}${sep}CR13 剧')..createSync();
    for (var i = 1; i <= 3; i++) {
      File('${workDir.path}$sep第0$i集 CR13.mp4')
          .writeAsBytesSync(List<int>.filled(1024, 0x42));
    }
    work = CachedWork(
      dirName: 'CR13 剧',
      path: workDir.path,
      episodes: <CachedEpisode>[
        for (final f in workDir.listSync().whereType<File>())
          CachedEpisode(
            fileName: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            isComplete: true,
          ),
      ],
    );
    expect(work.completedCount, 3, reason: '★ 前提：磁盘上有 3 集');

    ep1Path = '${workDir.path}$sep第01集 CR13.mp4';
    key1 = canonicalLocalPath(ep1Path);
  });

  /// 一个用例 = 点第 N 集，断言发出去的 req.id 是第 N 集自己的键
  ///
  /// ★ 集号/路径/键**必须在用例体里算**：setUp 是在用例之前跑的，
  ///   在 main() 里注册用例时读 late 字段会炸
  ///   （'Local ep2Path has not been initialized.' ⇒ 连文件都加载不了）。
  void caseTapEpisode({required int n}) {
    final rowText = '第0$n集 CR13';
    final fileName = '$rowText.mp4';
    testWidgets(
        '★★ CR-13：点「已下载」的$rowText，交给播放器的会话 id '
        '必须是**它自己**的键（而不是进页时那一集的）', (t) async {
      final epPath = '${workDir.path}${Platform.pathSeparator}$fileName';
      final keyN = canonicalLocalPath(epPath);
      expect(keyN, isNot(key1),
          reason: '★ 前提：本集的键必须不同于进页时那一集的键');

      // ★ 窗口放大到 1600x1000：800x600 下 MediaPage 判定为窄屏（wide=false）
      //   ⇒ 详情区收起、「已下载」列表落在视口外，点不到（会变成假红）。
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      // ★ 接缝：抓住详情区真正交给播放器的那个请求
      final got = <PlayRequestData>[];
      debugSetOnDetailPlayForward(got.add);

      await _openMediaPageOnEp1(t, key1: key1, ep1Path: ep1Path, work: work);

      final texts = t
          .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
          .map((w) => w.data ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      expect(texts.contains(rowText), isTrue,
          reason: '★ 前提：「已下载」必须列出 $rowText（否则点不到，判据无意义）');
      expect(got, isEmpty,
          reason: '★ 前提：只进页、还没点任何一集时，详情区不该发出过播放请求');

      await _tapLocalEpisodeRow(t, rowText);

      expect(got, hasLength(1),
          reason: '★ 前提：点一下必须**恰好**让详情区发出一次播放请求'
              '（0 次 = 没点到；≥2 次 = 判据有歧义）。实发 ${got.length} 次');
      final req = got.single;
      debugPrint('CR-13 实测：详情区发出 id=${req.id} '
          'ep=${req.episodeId ?? '(null)'} '
          'localPath=${req.localPath ?? '(null)'}');

      expect(req.episodeId, fileName,
          reason: '★ 前提：请求里的 episodeId 必须是点的那一集');
      expect(req.localPath, epPath,
          reason: '★ 前提：请求里的 localPath 必须是点的那一集的文件');

      // ★★ 判据本体：id 必须是**点的那一集**的键
      expect(req.id, keyN,
          reason: '★★ 详情区点「$rowText」，却把会话 id 发成了进页时那一集的键'
              '（$key1）。进度会写进那个键 ⇒ 第 1 集的续播位置被顶掉、'
              '$rowText 永远显示 0%。本地进度键的约定是 '
              '(kLocalProvider, canonicalLocalPath(文件绝对路径))，'
              '期望 $keyN');
      expect(req.id, isNot(key1),
          reason: '★★ 发出的 id 不能是进页时那一集的键');
    });
  }

  caseTapEpisode(n: 2);
  caseTapEpisode(n: 3);
}
