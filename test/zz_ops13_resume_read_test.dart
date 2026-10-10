@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签（它加载真 libmpv-2.dll，见 dart_test.yaml 顶部）。
//   手动跑：
//     flutter test test/zz_ops13_resume_read_test.dart --run-skipped --tags native-media --concurrency=1
library;

// ═══════════════════════════════════════════════════════════════════════
//  OPS-13（反馈 C）**读取侧**：两个方向都要能续上
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # ★ 为什么「两个方向」都必须测（只测一个方向等于只修一半）
//
// ```text
// 方向 ①：本地看完 ⇒ **在线**续上
//   写侧把镜像写进了 (站点, 站点内容 id)；
//   在线会话读的**就是自己那个键** ⇒ 直接续上（不需要读任何"对侧键"）。
//
// 方向 ②：在线看完 ⇒ **本地**续上
//   本地会话读**自己的 local 键** + **对侧键**（来自 originProvider/originMediaId），
//   取 updatedAt 更新的那条。
// ```
// 两者走的是**不同的代码路径**（一个是"镜像落在自己键上"、一个是"读两个键取新的"），
// 只测一个必然漏另一个。
//
// ⚠️ 全部是**行为断言**：真挂 PlayerPage、真调 `_prepareResume()`、
//    再读真实的 `_pendingSeek`（"续播将要 seek 到哪"）。
//    ★ 只看源码里有没有 `pickResumeProgress` 那种写法，
//      在"取反了 / 被集号守卫挡掉"时**照样全绿**。
//
// ⚠️ 硬规则：数据目录指到 TEMP 沙盒，**绝不碰**用户真实库。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
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

  setUpAll(() async {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    /*
     * 真核心：必须真的起来（原因同 zz_ops13_mirror_write_test.dart 的注释 ——
     * 核心没起来时 getProgress 抛异常被 catch 吞掉，红的原因会是**环境**）。
     */
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'ops13_read_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    if (!SourinCore.isStarted) {
      await SourinCore.startAsync(sandbox.path);
    }
    debugPrint('OPS13-R 真核心 isStarted=${SourinCore.isStarted} '
        'sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('OPS13-R 清理沙盒失败（不影响结论）: $e');
    }
  });

  setUp(() {
    RemoteBridge.instance.stop(); // 同写入侧：掐掉 400ms 轮询定时器
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
  });

  /// 挂一个**本地会话**页（真 PlayerPage）
  Future<void> mountLocal(
    WidgetTester t, {
    String? originProvider,
    String? originMediaId,
    String tag = 'a',
  }) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        /*
         * ★★★ key 必须**每个用例唯一**。
         *
         * # 为什么（本轮实测抓到的假绿）
         * ```text
         * 同一个用例里连续 pumpWidget 两个 PlayerPage 时，若两棵树的
         * **类型与 key 都相同**，Flutter 会**复用同一个 State**
         * （只走 didUpdateWidget，不再走 initState）⇒ _provider/_contentId
         * 仍是第一个会话的值。
         * ⇒ 「本地看完 → 换成在线会话读续播」那条用例其实还在本地会话里，
         *   在**没有修**的代码上也是绿的（实测确认）。
         * ```
         */
        key: ValueKey('local-$tag'),
        provider: kLocalProvider,
        id: localId,
        title: '本地剧',
        // ★ 与 shell.dart 的 _openCachedWork 逐字同形（本地会话的"集号"= 文件名）
        episodeId: '第01集.mp4',
        localPath: videoPath,
        originProvider: originProvider,
        originMediaId: originMediaId,
      ),
    )));
    while (t.takeException() != null) {}
    await t.pump(const Duration(milliseconds: 50));
    while (t.takeException() != null) {}
    debugPrint('OPS13-R 挂上本地会话 ⇒ 当前会话键 = '
        '${debugPlayerSessionKeyForProbe()}（必须是 local: 开头）');
  }

  /// 挂一个**在线会话**页（真 PlayerPage，provider/id 都是站点那套）
  Future<void> mountOnline(
    WidgetTester t, {
    required String provider,
    required String id,
  }) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        // ★ 与本地那棵树**不同的 key** ⇒ 强制重建 State（见 mountLocal 的说明）
        key: ValueKey('online-$provider-$id'),
        provider: provider,
        id: id,
        title: '在线剧',
      ),
    )));
    while (t.takeException() != null) {}
    await t.pump(const Duration(milliseconds: 50));
    while (t.takeException() != null) {}
    debugPrint('OPS13-R 挂上在线会话 ⇒ 当前会话键 = '
        '${debugPlayerSessionKeyForProbe()}（必须是 $provider:$id）');
  }

  /// 清掉续播守卫，再**显式**驱动一次 `_prepareResume`，返回 `_pendingSeek`
  ///
  /// # 为什么必须显式驱动（而不是靠 initState 那条自动路径）
  /// ```text
  /// 起播时 _prepareResume 是**自动**跑的，但它与 resolveStream / 播放器
  /// 事件是**并发**的 ⇒ 读到的 _pendingSeek 取决于时序，读数不可复现。
  /// ⇒ 先 reset（_resumedThisSession / _pendingSeek / _position 全复位），
  ///   再显式调一次，读数就是确定的。
  /// ★ reset 之后必须**先断言探针活着**（否则 _livePlayerState 为 null 时
  ///   读数恒为 null，与"不续播"同值 ⇒ 假绿）。
  /// ```
  Future<Duration?> readResume(WidgetTester t) async {
    final alive = debugPlayerResetResumeGuardForProbe();
    expect(alive, isTrue,
        reason: '★★★ 播放页没挂上（_livePlayerState 为 null）⇒ '
            '下面的 _pendingSeek 恒为 null，与"不续播"同值 —— 本仓最经典的假绿形态');
    final ok = await t.runAsync<bool>(() => debugPlayerPrepareResumeForProbe());
    expect(ok, isTrue, reason: '★ 必须真的走到了 _prepareResume');
    return debugPlayerPendingSeekForProbe();
  }

  // ══════════════════════════════════════════════════════════════════
  //  方向 ①：本地看完 ⇒ 在线续上（Owner 原话里的那个场景）
  // ══════════════════════════════════════════════════════════════════
  group('① 本地看完 ⇒ 在线续播接得上（端到端）', () {
    testWidgets('★★★ 本地会话写 30s ⇒ 在线会话进页续到 30s', (t) async {
      const provider = 'bilibili';
      const id = 'BV1ops13readA';

      // ① 先确认这个站点键**本来是空的**（否则下面的读数没有分辨力）
      final pre = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(provider, id));
      expect(pre, isNull, reason: '★ 前置：站点键必须是空的');

      // ② 本地会话看了一会儿（真跑生产写入路径，镜像随之落到站点键）
      await mountLocal(t,
          originProvider: provider, originMediaId: id);
      final saved = await t.runAsync<bool>(() => debugPlayerSaveProgressForProbe(
            duration: const Duration(seconds: 1800),
            position: const Duration(seconds: 30),
          ));
      expect(saved, isTrue);

      // ③ 换成**在线**会话打开同一集 —— Owner 要的正是这一步能接上
      await mountOnline(t, provider: provider, id: id);
      /*
       * ★★★ 先钉住「现在真的是**在线**会话」这件事。
       *
       * # 为什么这条断言不能省（它是本轮抓到的那个假绿的直接产物）
       * ```text
       * 实测：两棵 PlayerPage 树若**类型与 key 都相同**，Flutter 会复用
       * 同一个 State（不重跑 initState）⇒ 这里其实还在**本地**会话里，
       * 读的是本地自己的键 ⇒ 在**没有修**的代码上这条用例也是绿的。
       * ```
       */
      expect(debugPlayerSessionKeyForProbe(), '$provider:$id',
          reason: '★★★ 这里必须真的换成了**在线**会话 —— 否则读的是本地自己的键，'
              '整条用例在没有修复的代码上也会绿（假绿）');
      final seek = await readResume(t);
      debugPrint('OPS13-R 方向① 在线会话续播到 = $seek');

      expect(seek, isNotNull,
          reason: '★★★ 本地看过的进度必须能在**在线**会话里续上 —— '
              'null = 「本地和线上彻底分开」原样没修（这就是 Owner 报的那条）');
      expect(seek!.inSeconds, 30,
          reason: '★★★ 必须续到本地看到的那一秒');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  方向 ②：在线看完 ⇒ 本地续上（读两个键取新的那条）
  // ══════════════════════════════════════════════════════════════════
  group('② 在线看完 ⇒ 本地续播接得上', () {
    testWidgets('★★★ 站点键有 321s、本地键空 ⇒ 本地会话续到 321s', (t) async {
      const provider = 'bilibili';
      const id = 'BV1ops13readB';

      // 造一条"在线看过"的记录（模拟在线会话自己写的那条）
      await t.runAsync(() => SourinApi.saveProgress(
            provider,
            id,
            title: '第01集',
            position: 321,
            duration: 1800,
          ));

      // 本地键**确实是空的** —— 证明续播位置只能来自对侧键
      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kLocalProvider, localId));
      expect(own, isNull,
          reason: '★ 前置：本地键必须是空的 —— 否则证明不了"读了对侧键"');

      await mountLocal(t, originProvider: provider, originMediaId: id, tag: 'B');
      final seek = await readResume(t);
      debugPrint('OPS13-R 方向② 本地会话续播到 = $seek');

      expect(seek, isNotNull,
          reason: '★★★ 在线看过的进度必须能在**本地**会话里续上 —— '
              'null = 只读自己那个键 = 两个命名空间还是分开的');
      expect(seek!.inSeconds, 321);
    });

    testWidgets('★★★ 两侧都有 ⇒ 取 updatedAt **更新**的那条（不是无脑用镜像）',
        (t) async {
      const provider = 'bilibili';
      const id = 'BV1ops13readC';

      // 站点键：**旧**的（100s）
      await t.runAsync(() => SourinApi.saveProgress(
            provider,
            id,
            title: '第01集',
            position: 100,
            duration: 1800,
          ));
      // 本地键：**新**的（800s）—— 必须让它赢
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await SourinApi.saveProgress(
          kLocalProvider,
          localId,
          title: '第01集',
          position: 800,
          duration: 1800,
        );
      });

      final mirror = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(provider, id));
      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kLocalProvider, localId));
      debugPrint('OPS13-R 对照 updatedAt: 站点=${mirror?.updatedAt} '
          '本地=${own?.updatedAt}');
      expect(own!.updatedAt, greaterThan(mirror!.updatedAt),
          reason: '★★ 仪器自检：两侧 updatedAt 必须真的不同 —— '
              '否则这条断言没有分辨力（本仓铁律：先证尺子有分辨力）');

      await mountLocal(t, originProvider: provider, originMediaId: id, tag: 'C');
      final seek = await readResume(t);
      debugPrint('OPS13-R 方向② 取新的那条 ⇒ 续播到 = $seek');
      expect(seek!.inSeconds, 800,
          reason: '★★★ 必须取 updatedAt **更新**的那条 —— '
              '无脑用镜像 = 本地刚看的进度被一条更旧的记录顶掉');
    });

    testWidgets('★★ 没有来源 ⇒ 只用自己那个键（行为与改前逐字一致）', (t) async {
      // 这条是**反面**判据：防「无条件去读一个猜出来的键」
      await t.runAsync(() => SourinApi.saveProgress(
            kLocalProvider,
            localId,
            title: '第01集',
            position: 55,
            duration: 1800,
          ));

      await mountLocal(t, tag: 'D'); // 不传 origin*
      expect(debugPlayerMirrorOriginForProbe(), isNull,
          reason: '★ 没有来源时不该去读任何对侧键');
      final seek = await readResume(t);
      debugPrint('OPS13-R 无来源 ⇒ 续播到 = $seek');
      expect(seek!.inSeconds, 55,
          reason: '★ 老数据（没有旁文件）必须继续能续播 —— 行为退化成今天的样子');
    });
  });
}
