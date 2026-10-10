@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签：它 `MediaKit.ensureInitialized()` 加载真
//   libmpv-2.dll（flutter_tester 里偶发 native 崩溃，见 dart_test.yaml 顶部）。
//   手动跑：
//     flutter test test/zz_ops13_mirror_write_test.dart --run-skipped --tags native-media --concurrency=1
library;

// ═══════════════════════════════════════════════════════════════════════
//  OPS-13（反馈 C）**写入侧**：本地会话看完 ⇒ 真的多写一条「原来源」镜像
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # 本文件钉住什么（★ 行为，不是「源码里有没有那行字」）
//
// ```text
// ① 本地会话 _saveProgress() 走完之后，**另一个键**（站点 provider + 站点 id）
//    上真的多了一条进度 —— 用注入点记录**那一次写入的真实载荷**。
// ② 那条镜像**不带 episode_id**（带了就会被在线侧的「按集校验」挡掉 ⇒ 白写）。
// ③ 那条镜像的标题是**去掉后缀的文件名**（本地会话手上没有集标题）。
// ④ 没有来源（老下载 / 手拷进来的目录）⇒ **一条都不写**（不猜）。
// ⑤ 端到端：真的落进 SQLite，SourinApi.getProgress 读得回来。
// ```
//
// # ★ 为什么必须真挂 PlayerPage、真调 _saveProgress()
//
// 本仓反复吃过「手抄副本与生产脱钩 ⇒ 测试全绿、生产是错的」的亏。
// 「镜像那条到底写没写出去、写成什么样」正是本任务的**全部内容**，
// 复刻一份写入逻辑等于把被测对象换成影子。
// ⇒ 走 debugPlayerSaveProgressForProbe()（它直接调生产的 _saveProgress）。
//
// ⚠️ 硬规则：数据目录指到 TEMP 沙盒，**绝不碰** %APPDATA% 下的用户真实库。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) =>
        AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

void main() {
  late Directory sandbox;
  late Directory caseDir;
  late String videoPath;
  late String localId;
  final mirrorCalls = <ProgressMirrorCall>[];

  setUpAll(() async {
    /*
     * ① libmpv：与 test/zz_t12_local_play_probe_test.dart 同一条（仓库自带 dll）。
     */
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    /*
     * ② 真核心：**必须真的起来**。
     *
     * # 为什么不能省（实测推理）
     * ```text
     * saveProgressWithMirror 的第一件事就是**原样写会话自己的键**
     *   （await SourinApi.saveProgress(provider, id, …)）。
     * 核心没起来时这一句抛 SourinCoreException(unsupported) ⇒
     * 被 _saveProgress 的 catch 吞掉 ⇒ **镜像那一步根本走不到**
     * ⇒ 注入点一条记录都没有。
     * ★ 那时测试会红，但红的原因是**环境**而不是产品 ——
     *   所以这里必须把核心真的起起来，让红/绿都只反映产品行为。
     * ```
     */
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'ops13_write_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    if (!SourinCore.isStarted) {
      await SourinCore.startAsync(sandbox.path);
    }
    debugPrint('OPS13-W 真核心 isStarted=${SourinCore.isStarted} '
        'sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      // Windows 上 SQLite 文件可能还被核心持有 —— 删不掉不是失败
      debugPrint('OPS13-W 清理沙盒失败（不影响结论）: $e');
    }
  });

  setUp(() {
    /*
     * ★★ 掐掉 RemoteBridge 的轮询定时器（本仓播放器测试的既有做法，
     *    见 test/pc_arrow_keys_test.dart:220-233）。
     *
     * 它是**应用级**单例：播放页一挂上就开始 `_ensurePolling()`，
     * 而 flutter_test 在**每个用例结束时**断言「树上不许有未结束的计时器」：
     * ```text
     * A Timer is still pending even after the widget tree was disposed.
     * Failed assertion: line 2543 pos 12: '!timersPending'
     * ```
     * ⚠️ 实测（2026-10-10）：**只有第一条用例**红 —— 因为那个 400ms 的
     *    定时器在第一条用例期间被建起来，之后的用例复用了同一个单例。
     *    它不是产品缺陷（真机上它本来就该一直轮询），所以在这里掐掉。
     */
    RemoteBridge.instance.stop();
    /*
     * ★ 假 media_kit_video 通道（同 zz_t12_local_play_probe_test.dart）。
     *
     * flutter_tester 里没有视频输出插件 ⇒ VideoController(...) 会抛
     * MissingPluginException（**跑在 flutter_tester 里的固有事实**，不是产品缺陷）
     * ⇒ 从源头补上这个环境缺口，让真正的断言能被看见。
     */
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'Create') return 'ops13-fake-texture';
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
      debugProgressMirrorSink = null; // ★ 用完必须复位，否则污染同进程其它用例
      RemoteBridge.instance.stop();
    });

    caseDir = Directory('${sandbox.path}${Platform.pathSeparator}'
        'case-${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    videoPath = '${caseDir.path}${Platform.pathSeparator}第01集.mp4';
    final fixture = File('.probe${Platform.pathSeparator}t3_12'
        '${Platform.pathSeparator}fixture.mp4');
    if (fixture.existsSync()) fixture.copySync(videoPath);
    localId = canonicalLocalPath(videoPath);
    mirrorCalls.clear();
    debugProgressMirrorSink = (ProgressMirrorCall call) async {
      mirrorCalls.add(call);
      debugPrint('OPS13-W 镜像写入被拦截: $call');
    };
  });

  /// 挂一个**本地会话**的播放页（真 PlayerPage），再驱动真实写入路径
  ///
  /// ⚠️ 顺序（实测踩过）：pumpWidget 必须在**受控时钟**里，
  ///    真 FFI 才放进 runAsync。反过来的话页面没挂上 ⇒
  ///    _livePlayerState 是 null ⇒ 探针返回 false ⇒ 假绿。
  Future<void> mountLocal(
    WidgetTester t, {
    String? originProvider,
    String? originMediaId,
  }) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        provider: kLocalProvider,
        id: localId,
        title: '本地剧',
        /*
         * ★★★ 这一行必须与生产**逐字同形**。
         *
         * shell.dart 的 _openCachedWork 传的是 `req.episode.fileName`
         *   （形如 `第01集.mp4`）—— 本地会话的「集号」就是**文件名**。
         * 而镜像那条的标题正是从它推出来的（`mirrorProgressTitle`：
         *   没有集标题 ⇒ 文件名去后缀）。
         * ⚠️ 我第一版漏了这一行 ⇒ episodeId 为 null ⇒ 标题推不出来 ⇒
         *    `saveProgressWithMirror` 直接 return ⇒ 测试红，
         *    而红的原因是**夹具与生产不同形**，不是产品缺陷。
         *    记在这里：夹具必须照抄生产构造点的参数表。
         */
        episodeId: '第01集.mp4',
        localPath: videoPath,
        originProvider: originProvider,
        originMediaId: originMediaId,
      ),
    )));
    // 挂载期那条插件异常立刻收走（否则 testWidgets 记成失败）
    while (t.takeException() != null) {}
    await t.pump(const Duration(milliseconds: 50));
    while (t.takeException() != null) {}
  }

  /// 真跑一遍生产的 _saveProgress（走 runAsync，因为里面是真 FFI）
  ///
  /// ⚠️ 时长与位置**在同一次调用里**灌进去（见探针的说明）：
  ///    中间夹一次 `pump()` 会被真实的 `stream.duration` 事件冲掉 ⇒
  ///    `_saveProgress` 早退 ⇒ 测试把「环境没喂上」误判成「产品没实现」。
  Future<bool> driveSave(WidgetTester t) async {
    final mounted = debugPlayerSetDurationForProbe(const Duration(seconds: 100));
    expect(mounted, isTrue,
        reason: '★★★ 播放页没挂上（_livePlayerState 为 null）⇒ '
            '下面的读数全是空的（本仓最经典的假绿形态）');
    debugPlayerPushPositionForProbe(const Duration(seconds: 30));
    await t.pump(const Duration(milliseconds: 20));
    while (t.takeException() != null) {}
    final ok = await t.runAsync<bool>(() => debugPlayerSaveProgressForProbe(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 30),
        ));
    return ok ?? false;
  }

  group('① 写入侧：本地看完 ⇒ 站点键上多一条镜像', () {
    testWidgets('★★★ 真跑 _saveProgress ⇒ 镜像那条落到 (站点, 站点内容 id)',
        (t) async {
      await mountLocal(t,
          originProvider: 'bilibili', originMediaId: 'BV1ops13write');
      debugPrint('OPS13-W 本会话会镜像到: '
          '${debugPlayerMirrorOriginForProbe()}');

      final ok = await driveSave(t);
      expect(ok, isTrue, reason: '★ 必须真的走到了 _saveProgress');

      debugPrint('OPS13-W 拦截到 ${mirrorCalls.length} 条镜像: $mirrorCalls');
      expect(mirrorCalls.length, 1,
          reason: '★★★ 本地会话看完**必须**多写一条镜像 —— '
              '一条都没有 = 「本地和线上彻底分开」原样没修');

      final c = mirrorCalls.single;
      expect(c.provider, 'bilibili',
          reason: '★★ 镜像必须打到**原来源**的 provider 上');
      expect(c.mediaId, 'BV1ops13write',
          reason: '★★ 镜像必须打到**原来源**的站点内容 id 上');
      expect(c.position, 30, reason: '★ 位置要原样带过去');
      expect(c.duration, 100, reason: '★ 时长要原样带过去');
    });

    testWidgets('★★★ 镜像那条**不带** episode_id（带了会被在线守卫挡掉）',
        (t) async {
      /*
       * # 为什么这条是硬判据
       * ```text
       * 本地会话的「集号」是**文件名**（shell.dart 传 req.episode.fileName），
       * 在线的「集号」是站点集 id（如 51463）—— 二者**必然不等**。
       * 若把文件名写进镜像的 episode_id，在线那条守卫
       *   （player_page.dart 的 p.episodeId != curEpId）会判成
       *   「进度属于另一集」而**拒绝续播** ⇒ 镜像白写。
       * ```
       */
      await mountLocal(t,
          originProvider: 'bilibili', originMediaId: 'BV1ops13epid');
      expect(await driveSave(t), isTrue);

      expect(mirrorCalls.length, 1);
      expect(mirrorCalls.single.episodeId, isNull,
          reason: '★★★ 镜像的 episode_id 必须是 null —— '
              '写文件名进去 = 在线永远续不上（功能白做，且日志看起来很正常）');
    });

    testWidgets('★★★ 镜像的标题 = 文件名去后缀（本地会话没有集标题）',
        (t) async {
      await mountLocal(t,
          originProvider: 'bilibili', originMediaId: 'BV1ops13title');
      expect(await driveSave(t), isTrue);

      expect(mirrorCalls.length, 1);
      expect(mirrorCalls.single.title, '第01集',
          reason: '★★ 本地会话手上只有 第01集.mp4 ⇒ 写进播放记录的必须是'
              '去掉后缀的 第01集（否则列表里出现「第01集.mp4」这种条目）');
    });
  });

  group('② 反面对照：没有来源 ⇒ 一条镜像都不写', () {
    testWidgets('★★★ originProvider/originMediaId 全缺 ⇒ 只写自己那条', (t) async {
      /*
       * ★ 这条是**反向**判据，防的是「无条件镜像」这种修法：
       *   老下载 / 手拷进来的目录**没有旁文件** ⇒ 真不知道来源 ⇒
       *   猜一个写进去会污染**别人的**播放记录。
       */
      await mountLocal(t);
      debugPrint('OPS13-W 无来源时会镜像到: '
          '${debugPlayerMirrorOriginForProbe()}');
      expect(debugPlayerMirrorOriginForProbe(), isNull,
          reason: '★ 没有来源时必须为 null（不猜）');

      expect(await driveSave(t), isTrue);
      expect(mirrorCalls, isEmpty,
          reason: '★★★ 没有来源时**一条都不许写** —— '
              '猜一个来源 = 污染别人作品的播放记录');
    });

    testWidgets('★★★ 来源就是 local ⇒ 也不写（那是原地重写自己）', (t) async {
      await mountLocal(t,
          originProvider: kLocalProvider, originMediaId: 'D:/a.mp4');
      expect(debugPlayerMirrorOriginForProbe(), isNull);
      expect(await driveSave(t), isTrue);
      expect(mirrorCalls, isEmpty);
    });
  });

  group('③ 端到端：那条镜像真的落进了 SQLite', () {
    testWidgets('★★★ 去掉注入点后，SourinApi.getProgress 能读回那条镜像',
        (t) async {
      const originProvider = 'bilibili';
      const originMediaId = 'BV1ops13e2e';
      /*
       * ★ 这一步是「端到端」的硬证据：注入点只证明**调用了**，
       *   不证明**真的写进了库**（键拼错、参数名写错都照样绿）。
       * ⇒ 摘掉注入点，让 saveProgressWithMirror 走真 FFI。
       */
      debugProgressMirrorSink = null;

      await mountLocal(t,
          originProvider: originProvider, originMediaId: originMediaId);

      final pre = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(originProvider, originMediaId));
      expect(pre, isNull, reason: '★ 前置：这个键必须是空的（否则下面的读数没有分辨力）');

      expect(await driveSave(t), isTrue);

      final got = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(originProvider, originMediaId));
      debugPrint('OPS13-W 端到端读回: key=${got?.key} '
          'title=${got?.title} pos=${got?.position}/${got?.duration} '
          'episodeId=${got?.episodeId}');
      expect(got, isNotNull,
          reason: '★★★ 本地看完之后，**站点键**上必须真的有一条进度 —— '
              '这条不存在 = 「在线看时记不住本地看过」原样没修');
      expect(got!.position, 30, reason: '★ 位置要对得上（不是写了个空记录）');
      expect(got.duration, 100);
      expect(got.title, '第01集',
          reason: '★ 标题必须是去掉后缀的文件名');
      expect(got.episodeId, isNull,
          reason: '★★★ 落库那条也**不带** episode_id（JSON 里干脆没有这个键）');

      // 会话自己的那条也必须在（既有行为逐字不变）
      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kLocalProvider, localId));
      debugPrint('OPS13-W 会话自己那条: key=${own?.key} pos=${own?.position}');
      expect(own, isNotNull,
          reason: '★★ 镜像只是**补充** —— 会话自己的那条不许因此丢');
      expect(own!.position, 30);
    });
  });
}
