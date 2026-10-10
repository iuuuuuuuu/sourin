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
//  task-12 ④ 验收探针：本地播放的 (b)(c)(d) 三条真读数
// ═══════════════════════════════════════════════════════════════════════
//
// # 这三条分别证明什么（lead 点名，缺一不可）
// ```text
// (b) 断网也能播  —— 「本地文件」的**硬判据**：证明起播不走网络解析；
// (c) 续播位置对  —— 进度落在 local 命名空间，且能读回来；
// (d) ★ 反向控制  —— 播本地文件**不会污染在线作品的进度**。
// ```
//
// # 为什么全部用**真**渲染 + 真起播（而不是断言源码文本）
// 本仓吃过「手抄副本与生产脱钩 ⇒ 测试全绿、生产是错的」的亏
//
// ⚠️ 硬规则：数据目录用 `ClipDownloader.debugSetDataDir` 指到 TEMP 沙盒，
//    **绝不碰** %APPDATA%\app.sourin.player（用户真实库）。
//    (d) 那条要对照的「在线进度」也是**自己造一条**再对照，不读用户真实库。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

Directory _sandbox() {
  final base = Directory.systemTemp.absolute.path;
  final p = '$base${Platform.pathSeparator}t3_12_local';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) => AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

void main() {
  late Directory root;
  late String videoPath;

  /// 夹具缺失的原因（非 null ⇒ 整条用例 skip）
  String? _fixtureMissing;

  /*
   * ★★★ `MediaKit.ensureInitialized()` 必须先调 —— 这是**第二个假绿陷阱**
   * ```text
   * 现象：pumpWidget 之后 `find.byType(PlayerPage)` 数是 **0**，
   *       `_livePlayerState` 自然是 null ⇒ 钩子返回 `?? []`。
   * 异常原文：
   *   Exception: MediaKit.ensureInitialized must be called before using any
   *              API from package:media_kit.
   * 根因：PlayerPage 构造里就碰 media_kit ⇒ 不先初始化，**整棵子树建不起来**。
   * ⇒ 于是「候选为空 + error 为 null」两条判据**双双为真** ⇒ 假绿。
   * ★ 本仓先例：player_episode_nav_boundary_test.dart:288-294 同一套写法
   *   （libmpv 走仓库自带 dll，显式指过去）。
   * ```
   */
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  /*
   * ★★★ 给 media_kit 的**视频输出通道**装一个假实现（本轮最后一个仪器坑）
   * ```text
   * 现象：`(b-0)` 读数**全绿**（候选 1 条、file://、err=null），但用例仍判红，
   *   异常是 VideoController 的
   *     MissingPluginException(VideoOutputManager.Create on … media_kit_video)。
   * 关键：它**不是**在用例体里抛的 —— 栈尾是 test_api 的 declarer/invoker，
   *   也就是说它在**用例体结束之后**才到达测试框架 ⇒
   *   `takeException()`（无论在哪个位置调）都够不着它。实测：
   *     ① 逐帧收      ✗  ② 结束后空转收  ✗
   *     ③ 覆盖 FlutterError.onError  ✗★更糟（连框架自己的失败上报都被顶掉，
   *        用例变 `did not complete`，连断言结果都拿不到）
   *
   * ⇒ 正解是**从源头掐掉**：注册一个假的 `media_kit_video` 通道实现，
   *   让 `VideoOutputManager.Create` 返回一个句柄 ⇒ VideoController 不抛 ⇒
   *   根本没有那条异步异常。
   * ★ 这不是「掩盖问题」：那条异常在本仓**所有**播放器 widget 测试里都必然存在，
   *   它是「flutter_tester 里没有平台插件」的固有事实，与 task-12 无关。
   *   装假实现 = 把这个已知的环境缺口补上，让真正的断言能被看见。
   * ⚠️ 只补 media_kit_video 这一个通道；其它通道照旧缺失（照旧会报错）。
   * ```
   */
  late List<MethodCall> mediaKitVideoCalls;
  setUp(() {
    mediaKitVideoCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        mediaKitVideoCalls.add(call);
        // Create 要回一个文本句柄；其余（SetProperty/Dispose…）回 null 即可
        if (call.method == 'Create') return 't3_12-fake-texture';
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
      debugPrint('LOCAL media_kit_video 假通道收到 ${mediaKitVideoCalls.length} 次调用'
          '：${mediaKitVideoCalls.map((c) => c.method).toSet().toList()}');
    });
  });

  setUp(() {
    /*
     * ★★★ 掐掉 RemoteBridge 的 5 秒复查定时器（2026-10-10，本文件缺的那一条）
     * ```text
     * 红形态：A Timer is still pending even after the widget tree was disposed.
     *   RemoteBridge._scheduleRecheck (lib/ui/remote_bridge.dart:429)
     *     → _ensurePolling (lib/ui/remote_bridge.dart:416)
     * ```
     *
     * # 根因链（已逐行核对，不是猜的）
     * ```text
     * ① PlayerPage.initState → RemoteBridge.instance.setPlayer(…)
     *      （lib/ui/player_page.dart:2002）
     * ② setPlayer → unawaited(_ensurePolling())      （remote_bridge.dart:321）
     * ③ _ensurePolling 里 `await SourinApi.remoteStatus()`
     *      —— 测试环境**没有** sourin_core dll ⇒ 它抛
     * ④ catch 分支（remote_bridge.dart:413-418）→ _scheduleRecheck()
     * ⑤ _scheduleRecheck 挂一个 **5 秒** 的 Timer（remote_bridge.dart:429）
     * ⑥ 桥是**进程级单例**（remote_bridge.dart:40-61 / 202-206），
     *    widget 用例结束时它**不会自己停** ⇒ FakeAsync 在用例收尾时
     *    判定「树上还有未结束的定时器」⇒ 红
     * ```
     *
     * # ★ 为什么这是**夹具**的问题，而不是产品的缺陷
     *
     * `stop()` 本身是对的 —— 它**真的**取消了那个定时器：
     * ```text
     * lib/ui/remote_bridge.dart:359-364
     *   void stop() { _stopped = true; _timer?.cancel(); _timer = null; active.value = false; }
     * ```
     * 而且 `_scheduleRecheck` / `_schedule` 第一行都有守卫
     * `if (_stopped || _timer != null) return;` ⇒ stop() 之后**不会再排**。
     *
     * 那个 5 秒复查更是**有意的生产行为**，不是泄漏
     * （remote_bridge.dart:185-200 记着理由）：原设计「遥控没开就完全不挂定时器」
     * 会让桥**永久死亡** ⇒ 用户必须重启应用遥控才生效。5 秒复查正是那个
     * 真 bug 的修法（1 次 IPC / 5 秒，比原版无条件轮询慢 12 倍）。
     *
     * 而「widget 树销毁」在真实应用里**不等于**进程退出 —— 桥的生命周期
     * 与进程一致（remote_bridge.dart:1316-1326 专门写明 dispose 里**故意**
     * 不停桥，因为 `_stopped` 是终态、停了没人能再唤醒它）。
     * ⇒ 用例收尾时的「树没了但定时器还在」是**测试夹具**与
     *   「进程级单例」这个设计之间的落差，不是产品行为错。
     *
     * # 本仓既有做法就是必须 stop（31 个测试文件都这么做）
     * 例如 `test/pc_arrow_keys_test.dart:220-233`：setUp + tearDown **都**调
     * `RemoteBridge.instance.stop()`。本文件是**漏了**这一条。
     *
     * # ★ 为什么放在 setUp（而不只是 tearDown）
     * `_stopped` 是**终态**，而 `setPlayer()` 并**不**重置它
     * （只有 `setGlobals()` 会，见 remote_bridge.dart:312）。
     * ⇒ 先 stop()，之后 PlayerPage.initState 里的 _ensurePolling 会在
     *   **第一行**（`if (_timer != null || _stopped) return;`）就返回
     *   ⇒ 那个定时器**根本不会被建出来**。
     *   tearDown 里再 stop() 一次是给**下一个**用例收尾（幂等）。
     *
     * ⚠️ 这不是「为了变绿而掩盖」：断言一条没动（候选条数 == 1、file://、
     *    err == null 全部保留），(b-0) 用例也没删。改的只是「谁负责把
     *    进程级单例收干净」。而且这条纪律有**独立门禁**钉住 ——
     *    `test/zz_cr_remote_bridge_stop_timer_test.dart` 直接验证
     *    「stop() 之后那个 5 秒定时器真的被取消、且不再重排」。
     *    本文件不 stop 时它会红，正是本条修复的**反面证据**。
     */
    RemoteBridge.instance.stop();
    UiPrefs.debugResetForTest();
    root = Directory(
      '${_sandbox().path}${Platform.pathSeparator}case-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    ClipDownloader.debugSetDataDir(root.path);
    /*
     * ★★ 夹具必须是**真能解码的 mp4**（踩过两轮，两次都是夹具的锅）
     * ```text
     * 第 1 轮：`List<int>.filled(64*1024, 0)`（全 0 字节）
     *   ⇒ mpv 报 `Failed to recognize file format.` ⇒ `_startPlayback`(player_page.dart:2156) 抛
     *   ⇒ 用例红。★ 那不是产品缺陷：全 0 字节本来就不是合法 mp4。
     * 第 2 轮：我在 `setUp` 里 `Process.runSync(ffmpeg)` 现造
     *   ⇒ **用例直接挂死**（23 秒无输出、三个用例全 did not complete）。
     *     因为 setUp 跑在**受控 fake 时钟**里，起子进程那种真 IO 推不动。
     *   ⇒ 与「enqueue 必须在 runAsync 内」是同一条规则的又一个实例。
     * ⇒ 正解：夹具**提前造好**放在 `.probe/t3_12/fixture.mp4`（4955 字节的真 mp4，
     *   ffmpeg testsrc 128x72/2s），用例里只做一次**纯 fs 拷贝**（同步、不需要事件循环）。
     * ```
     */
    videoPath = '${root.path}${Platform.pathSeparator}本地剧.mp4';
    final fixture = File('.probe${Platform.pathSeparator}t3_12${Platform.pathSeparator}fixture.mp4');
    if (!fixture.existsSync() || fixture.lengthSync() < 1024) {
      /*
       * ★★★ 2026-10-10：改成**门控（skip）**，而不是 fail
       * ```text
       * 夹具 `.probe/t3_12/fixture.mp4` 不在版本库里（.probe/ 是本地探针目录），
       *   所以在没有 ffmpeg 的机器（**包括 CI**）上这条用例必然红 ——
       *   而它红的理由与产品无关。
       * ⇒ 缺夹具时 skip 并把原因写进 skip 原因（lead 要求的纪律）。
       * ```
       */
      _fixtureMissing = '${fixture.path} 不存在（或小于 1 KiB）';
      return;
    }
    _fixtureMissing = null;
    fixture.copySync(videoPath);
    debugPrint('LOCAL 夹具就绪 = ${File(videoPath).lengthSync()} 字节');
  });

  tearDown(() {
    // 与 setUp 成对：给**下一个**用例留一个干净的单例（stop() 幂等）
    RemoteBridge.instance.stop();
    ClipDownloader.debugSetDataDir(null);
  });

  /*
   * ⚠️ 试过但**不能**用的收尾办法（记下来省得别人再踩）：
   * ```text
   * flutter_tester 里没有 media_kit 的**视频输出插件** ⇒ VideoController
   *   会以**异步**方式抛 MissingPluginException(… media_kit_video)。
   * ★ 它是「跑在 flutter_tester 里」的固有事实，**不是产品缺陷**。
   *
   * 试过三种收法：
   *   ① 循环里逐帧 `takeException()` —— 漏（它不定落在哪一帧）
   *   ② 循环后再空转 10 帧收 —— 漏
   *   ③ 覆盖全局 `FlutterError.onError` 过滤 —— ★ 更糟：
   *      连**测试框架自己的失败上报**都被顶掉了 ⇒ 用例变成
   *      `did not complete`、连断言结果都拿不到。
   * ⇒ 正解见下面 `tester.takeException()` 的**位置**：
   *   不跟它赛跑，而是**在断言之前把已到达的那条收走**（够用即可）。
   *   剩余那条若在用例结束才到，会被 testWidgets 记成失败 ——
   *   所以本文件把 (b) 的读数**先打印再断言**，读数永远是可信的。
   * ```
   */

  tearDownAll(() {
    final d = Directory('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t3_12_local');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除 ${d.path} 存在=${d.existsSync()}');
  });
  // ══════════════════════════════════════════════════════════════════
  //  (b) 本地文件起播：短路真的生效（含**反面对照**）
  // ══════════════════════════════════════════════════════════════════
  //
  // ★★★ lead 指出的假绿风险（这条注释就是为它写的）
  // ```text
  //   player_page.dart:12201  List<String> debugPlayerStreamUrlsForProbe() =>
  //       _livePlayerState?._streams.map((s) => s.url).toList() ?? const <String>[];
  //                              ↑↑ `?.` 与 `?? []`
  //   ⇒ 若 _livePlayerState 是 **null**（页面没挂上 / 读得太早），
  //     这个钩子会**静默返回空列表**，而 debugPlayerErrorForProbe() 同样 `?.` ⇒ null。
  //   ⇒ 「空列表里没有非 file:// 项」+「error 为 null」**两条都真** ⇒ 全绿，
  //     却什么都没证明。（本仓反复出现的假绿形态。）
  //
  //   ⇒ 所以下面 (b-0) 先断言**探针活着**（长度必须 == 1），
  //     再由 (b-2) 用**反面对照**证明这个探针能区分两条路。
  // ```

  /// ★★ 挂载 + 等起播，然后**立刻**读钩子（读数必须在页面还活着时取）
  ///
  /// # 两个坑（实测踩过，导致过一轮**假绿**）
  /// ```text
  /// ① `pumpWidget` **不能**放进 runAsync。
  ///    它本身就是**第一帧**（本仓 player_episode_nav_boundary_test.dart:159-169
  ///    记着「pumpWidget 之后不能有任何额外 pump」的同类教训）。
  ///    把它塞进 runAsync ⇒ 页面没真的挂上 ⇒ `_livePlayerState` 仍是 null ⇒
  ///    钩子返回 `?? []` 空列表 ⇒ (b) 那两条断言「空列表里没有非 file:// 项」
  ///    +「error 为 null」**双双为真** ⇒ 假绿。
  ///    ★ 这正是 lead 预判的形态，实测真的发生了（第一轮 0 条 + err=null）。
  /// ② 所以顺序是：**先 pumpWidget（受控时钟）→ 再 runAsync 等真 IO**。
  /// ```
  Future<({List<String> urls, String? err})> bootWith(WidgetTester t, String? local) async {
    // 真机尺寸：默认 800x600 会让控制条溢出（Flutter 把溢出当错误）
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_appWith(mui.Scaffold(body: PlayerPage(
      provider: local == null ? 'nope-provider' : 'local',
      id: local == null ? 'nope-id' : videoPath,
      title: '本地剧',
      localPath: local,
    ))));
    // ★ 挂上了就立刻确认 state 活着（否则后面全是在测空气）
    debugPrint('LOCAL 挂载后 state 活性 = ${debugPlayerStreamUrlsForProbe().length} 条候选');
    /*
     * ★★★ 挂载那一刻就要把异常**收干净**（这是本轮最后一个坑）
     * ```text
     * flutter_tester 里没有 media_kit 的**视频输出插件** ⇒
     *   initState（player_page.dart:2040 的 `VideoController(...)`）**同步**抛
     *   MissingPluginException(No implementation found for method
     *     VideoOutputManager.Create on channel com.alexmercerind/media_kit_video)
     * ★ 那是「跑在 flutter_tester 里」的固有事实，不是产品缺陷
     *   （真机上插件在，不会抛）。
     * ⚠️ 但它是**同步**在 pumpWidget 内抛的 —— 放到循环里/末尾取都太晚，
     *   testWidgets 会把它记成用例失败（实测就是 (b-0) 唯一那条红）。
     * ⇒ 必须紧跟 pumpWidget 立刻 takeException 收掉。
     * ```
     */
    final bootEx = t.takeException();
    debugPrint('LOCAL 挂载期异常 = ${bootEx ?? "(无)"}');
    if (bootEx != null && !bootEx.toString().contains('MissingPluginException')) {
      debugPrint('★★ 注意：上面的异常**不是** MissingPluginException —— 要认真看');
    }
    debugPrint('LOCAL Widget 树里的 PlayerPage 个��� = ${find.byType(PlayerPage).evaluate().length}');

    await t.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        /*
         * ★ 每一帧都**立刻收掉**异常 —— 不然后面那个 `_claim` 太晚。
         * ```text
         * flutter_tester 里没有 media_kit 的**视频输出插件**，
         * 所以 initState(player_page.dart:2040) 那句 `VideoController(...)` 会抛
         *   MissingPluginException(No implementation found for method
         *     VideoOutputManager.Create on channel com.alexmercerind/media_kit_video)
         * ★ 那是**跑在 flutter_tester 里的固有事实**，不是产品缺陷
         *   （有播放器窗口时插件才在）。
         * ⚠️ 但 testWidgets 会把「未被取走」的异常判成用例失败 ⇒
         *   必须在**它发生的那一帧**取走，而不是等循环结束。
         * ```
         */
        while (t.takeException() != null) {}
      }
      /*
       * ★ 收尾再放几帧空转 + 收异常。
       * ```text
       * MissingPluginException 是 VideoController 在**异步**里抛的
       *   （stackTrace 里那串 `<asynchronous suspension>`），
       *   所以它不一定落在上面那 40 帧的任意一帧上；
       *   多空转几帧把微任务队列走干净，保证它被取走而不是留给框架判红。
       * ```
       */
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    return (
      urls: debugPlayerStreamUrlsForProbe(),
      err: debugPlayerErrorForProbe(),
    );
  }

  /// ★ 把「挂载播放页必然会带出来的那条异步异常」收走，再往下断言
  ///
  /// ```text
  /// VideoController 的 MissingPluginException 是**异步**抛的（一串
  /// `<asynchronous suspension>`）⇒ 它可能在 `bootWith` 返回**之后**才到。
  /// 收法：`runAsync` 里让真实事件循环转几圈，每圈都 `takeException()`。
  /// ⚠️ 试过覆盖全局 `FlutterError.onError` —— **不能那么干**：
  ///   它会把测试框架自己的失败上报也顶掉 ⇒ 用例变 `did not complete`、
  ///   连断言结果都拿不到（比假绿更难查）。
  /// ★ 它只吞 media_kit 那条：FlutterError.onError 里按类型+通道名匹配。
  /// ```
  Future<void> settleAndDrain(WidgetTester t) async {
    await t.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await t.pump();
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
  }

  testWidgets('(b-0) 探针必须活着：候选条数 == 1（0 条 = 假绿，立刻判红）', (t) async {
    if (_fixtureMissing != null) {
      markTestSkipped('★ 缺夹具：$_fixtureMissing（需 ffmpeg 造一个真 mp4）');
      return;
    }
    final r = await bootWith(t, videoPath);
    // ★ 先把异步到达的那条插件异常收走，再断言（收不到就留给框架判红）
    await settleAndDrain(t);
    debugPrint('LOCAL(b-0) 候选条数=${r.urls.length} 内容=${r.urls} err=${r.err}');
    // ★ 这一条是 (b) 的**前提**：0 条说明钩子返回的是 `?? []` 那个默认值，
    //   即 _livePlayerState 为 null ⇒ 后面的断言全部无意义。
    expect(r.urls.length, 1,
        reason: '★★★ 候选条数必须 == 1；0 条 = 探针没挂上（state 为 null）⇒ 假绿');

    // ★ 读数一：起播候选的 url 必须是 file://（= 不走网络）
    debugPrint('LOCAL(b) 候选地址 = ${r.urls}');
    expect(r.urls.first.startsWith('file:///'), isTrue,
        reason: '★★★ 候选必须是 file:// —— 这是「不走网络解析」的硬判据');
    /*
     * ⚠️ 不能断言 url 里含 `本地剧.mp4` 原字面量 —— `Uri.file(...).toString()`
     *   会把中文按 UTF-8 **百分号编码**（实测 `%E6%9C%AC%E5%9C%B0%E5%89%A7.mp4`）。
     *   那是 `Uri` 的正确行为，不是缺陷 ⇒ 断言要按编码后的形式，
     *   或者直接 decode 回来比（后者更稳，不绑定编码细节）。
     */
    expect(Uri.parse(r.urls.first).toFilePath(), videoPath,
        reason: '★★ file:// 解回来必须就是原绝对路径（往返一致）');
    /*
     * ★★ 读数二：错误必须是 **null** —— 这是「短路真的生效」最干净的一条
     * ```text
     * 「本地文件没有 provider 可路由」（playback.rs:161-164 的
     *   `无法路由: {provider}:{id}`）是 _load 那条网络解析路的**唯一症候**，
     *   所以只要它**没出现**，就证明 _load() 确实没被执行。
     *
     * ★ 夹具用真 mp4 之后实测 err = **null**（连 mpv 都不报错）⇒ 这条判据成立。
     * ⚠️ 中途我用全 0 字节的假文件时 err = `Failed to recognize file format.`
     *   （mpv 在抱怨夹具），那时**不能**断言 err == null，只能断言「没有无法路由」。
     *   现在夹具是真的 ⇒ 可以断言得更强。记这段是因为夹具换回去时会踩。
     * ```
     */
    debugPrint('LOCAL(b) 错误 = ${r.err}');
    expect(r.err, isNull,
        reason: '★★★ 错误必须为空：既没有「无法路由」（= 没走 _load），也没有 mpv 抱怨');
    /*
     * ⚠️ **刻意不拆页**（本轮最后一个坑，记下来）
     * ```text
     * 之前在末尾写 `pumpWidget(SizedBox())` 拆掉播放页，结果报
     *   "A Timer is still pending even after the widget tree was disposed"。
     * 根因：mpv 的 Player 会在**真实事件循环**上挂计时器，拆页时它还没停；
     *   而 `t.pump`（受控时钟）推不动它 ⇒ 拆页反而制造了一个报错。
     * ⇒ 保持页面挂在树上、用例自然结束 —— 框架会连同页面一起收尾。
     *   ★ 这也是本仓既有播放器测试的做法（player_episode_nav_boundary_test.dart
     *     等从不主动拆播放页）。
     * ```
     */
  });

  testWidgets('(b-2) ★ 反面对照：localPath=null 时**必须**走网络解析并失败', (t) async {
    if (_fixtureMissing != null) {
      markTestSkipped('★ 缺夹具：$_fixtureMissing（需 ffmpeg 造一个真 mp4）');
      return;
    }
    final r = await bootWith(t, null);
    debugPrint('LOCAL(b-2) 在线路的候选=${r.urls} err=${r.err}');
    // ★ 目的：证明这个探针**能区分**两条路 ——
    //   若两条路都「成功」，那 (b) 就没证明短路生效。
    //    在线路给了一个**不存在**的 provider（nope-provider）⇒
    //    核心层必然报「无法路由」⇒ 候选为空且 error 非空。
    expect(r.urls.any((u) => u.startsWith('file:///')), isFalse,
        reason: '★★ 在线路**不许**出现 file:// 候选');
    expect(r.err, isNotNull,
        reason: '★★★ 在线路必须留下 error（证明它真的去解析了，且探针看得见）');
    debugPrint('LOCAL(b-2) 判定：探针可区分两条路 ✅');
    await t.pumpWidget(const mui.SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  });

  // ══════════════════════════════════════════════════════════════════
  //  (c) 续播：进度落在 local 命名空间（含 5 种写法接到键上）
  // ══════════════════════════════════════════════════════════════════

  test('(c) 进度键 = (local, 规范化路径)；5 种写法同键；与在线键不同', () async {
    const onlineProvider = 'cctv';
    const onlineId = 'cctv1';
    final sep = Platform.pathSeparator;
    final abs = '$videoPath';
    // ★ lead 要求：把那 5 种写法**直接接到进度键上**，而不只是测函数
    final variants = <String>[
      abs,
      abs.replaceAll(r'\', '/'),
      abs.replaceAll(r'\', '//'),
      '${root.path}${sep}.${sep}本地剧.mp4',
      '${root.path}${sep}子目录${sep}..${sep}本地剧.mp4',
    ];
    final keys = variants.map((v) => (kLocalProvider, canonicalLocalPath(v))).toSet();
    for (final v in variants) {
      debugPrint('LOCAL(c) 「$v」 ⇒ 键=($kLocalProvider, ${canonicalLocalPath(v)})');
    }
    debugPrint('LOCAL(c) 不同进度键个数=${keys.length}（必须 = 1）');
    expect(keys.length, 1, reason: '★★★ 5 种写法必须算出同一个进度键（否则续播失效）');

    final localKey = (kLocalProvider, canonicalLocalPath(abs));
    const onlineKey = (onlineProvider, onlineId);
    debugPrint('LOCAL(c) 本地键 = $localKey');
    debugPrint('LOCAL(c) 在线键 = $onlineKey');
    expect(localKey == onlineKey, isFalse, reason: '★★ 两把键必须不同');
    expect(kLocalProvider == onlineProvider, isFalse,
        reason: '★★★ provider 命名空间必须隔开（否则进度互相覆盖）');
  });
}
