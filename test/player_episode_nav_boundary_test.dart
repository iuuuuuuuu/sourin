@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`，它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  ①-C 上一集/下一集：**边界时不许切集**（task-28，用户报的 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 明明**没有下一集**，却还是**请求下一集**，这是 bug，需要修复
//
// # ★★★ 为什么这个文件测的是"行为"而不是"显示"
//
// ```text
// 显示层：最后一集时「下一集」按钮是不是灰的/在不在   ← 只能证明外观
// 行为层：最后一集时到底有没有【真的执行切集】        ← ★ 用户报的是这个
// ```
// 一个灰着的按钮**完全可能**背后还接着能用的回调
//（`onPressed` 忘了置 null 是很常见的写法），
// 所以"看起来禁用了"证明不了"真的没切"。
//
// 本文件读的是 `debugPlayerGotoEpisodeCalls()` —— 计数点在
// `_gotoEpisode` 的**入口**（所有切集路径的唯一汇流点），
// 数的是**动作本身**，不是"按钮被点了"。
//
// # ★★ 阳性对照（铁律②：仪器失灵 ⇒ 结论作废）
//
// "最后一集时计数没涨"有两种可能：
// ```text
// ① 判据拦住了           ← 期望
// ② 仪器根本数不到        ← 那结论作废
// ```
// 所以**每组都先做阳性对照**：停在**中间**某一集，点「下一集」，
// 确认 `gotoEpisodeCalls` **确实 +1**。
// 对照不通过 ⇒ 同组的阴性结论一律不采信。
//
// # 环境（照抄 `pc_arrow_keys_test.dart` 的实测结论）
//
// ```text
// ① media_kit 需要 libmpv-2.dll —— 仓库自带，显式指过去即可
// ② RemoteBridge 有 5 秒复查定时器 —— setUp 里 stop()
// ③ 播放器会持续产生定时器 —— 绝不 pumpAndSettle，只 pump 固定帧
// ④ 用例结束前要把时间推过去（drainTimers），否则报
//    "A Timer is still pending even after the widget tree was disposed"
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 造 N 集假数据（id 稳定，便于断言"切到了哪一集"）
List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(
          id: 'ep$i',
          title: '第$i集',
          url: 'https://example.invalid/$i.m3u8',
        ),
    ];

/// 挂载**真实** PlayerPage，并停在指定的一集
///
/// ⚠️ 不 `pumpAndSettle`：播放器持续产生帧/定时器，settle 永远不返回。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 两个必须知道的坑（**第三方独立验证发现**，我第一版全踩了）
/// ══════════════════════════════════════════════════════════════════════
///
/// # 坑 ①：**pump 帧数不能多** —— 8 帧之后控制条就没了
///
/// 我第一版写的是 `for (i < 8) pump(50ms)`，结果**整个 `_BottomBar`
/// 都不渲染**（上一集/下一集/选集/换源 全是 0 个）：
/// ```text
/// ISO[1 默认画布800x600 + 1帧] 上一集=1 下一集=1 重试=0   ← 按钮在
/// ISO[3 大画布   + 8帧]        上一集=0 下一集=0 重试=1   ← ★ 控制条没了
/// ```
/// 根因链：
/// ```text
/// flutter test 里没有网络 ⇒ `_load()` 失败 ⇒ `_error` 被置上
///   ⇒ player_page.dart 的
///        if (_controlsVisible && _error == null && ...)
///      为假 ⇒ 整条 `_BottomBar` 不渲染
/// ★ 而 `_load()` 是**异步**的：第 1 帧时它还没返回，所以按钮还在；
///   8 帧（400ms 假时间）之后它早就失败了 —— 按钮随之消失。
/// ```
/// ⇒ **只 pump 1 帧**：让首帧建出控制条，又不等 `_load()` 失败。
///
/// ⚠️ 这不是"绕过问题"，而是**测对了东西**：本文件要验的是
///    "边界时会不会切集"，与控制条在"起播失败"后是否隐藏**无关**。
///
/// # 坑 ②：默认画布 800x600 **装不下控制条**
///
/// ```text
/// A RenderFlex overflowed by 62 pixels on the right.
/// constraints: BoxConstraints(0.0<=w<=768.0, ...)   ← 只有 768 逻辑像素
/// ```
/// 控制条上有 上一集/下一集/线路/换源/片头片尾/选集/画中画/全屏/设置 ——
/// 768px 排不下。而**溢出会让测试直接失败**（Flutter 把它当错误）。
/// ⇒ 设成真机尺寸 **1280x800**。
///
/// ⚠️ `setSurfaceSize` **必须 await**（本项目踩过），
///    而且要在 tearDown 里恢复 `null`，否则污染后面的用例。
Future<void> mountPlayer(
  WidgetTester t, {
  required List<Episode> episodes,
  required int episodeIndex,
}) async {
  // ── 坑 ②：真机尺寸（默认 800x600 会让控制条溢出）──
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '①-C 边界验收',
        episodes: episodes,
        episodeIndex: episodeIndex,
        episodeId: episodes.isEmpty ? null : episodes[episodeIndex].id,
        episodeTitle: episodes.isEmpty ? null : episodes[episodeIndex].title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 坑 ①：**这里不能有任何额外的 `pump`** —— 一帧都不行
   * ══════════════════════════════════════════════════════════════════════
   *
   * `pumpWidget` **本身就是第一帧**。它之后每多 pump 一次，
   * 控制条就离消失更近一步（第三方独立验证，单变量隔离到帧）：
   * ```text
   * FRAME[0 extra] 下一集=1  错误浮层=0   ← pumpWidget 之后不再 pump ⇒ 按钮在 ✓
   * FRAME[1 extra] 下一集=0  错误浮层=1   ← 再多 pump(50ms) ⇒ ★ 按钮没了 ✗
   * FRAME[0 extra + tap] 计数 0 -> 1      ← 0 帧版本能真的点到并切集 ✓
   * ```
   * 机制：
   * ```text
   * flutter test 里没有网络 ⇒ `_load()` 必然失败 ⇒ 置 `_error`
   *   ⇒ player_page.dart 的
   *        if (_controlsVisible && _error == null && ...)
   *      为假 ⇒ 【整条 `_BottomBar` 不渲染】
   *   ★ `错误浮层=1` 就是 `_error` 确实置上了的直接证据
   * ```
   *
   * ⚠️ 我第一版写的是 `for (i < 8) pump(50ms)`（8 帧）——
   *    于是控制条早就没了，`find.text('下一集')` 恒为 0 个，
   *    4 条测试全红。**那不是产品 bug，是测试挂载方式错了。**
   *
   * ⚠️ 这不是"绕过问题"，而是**测对了东西**：本文件验的是
   *    "边界时会不会切集"，与控制条在"起播失败"后是否隐藏**无关**。
   *    如果哪天真要测"起播失败后控制条该不该藏"，
   *    那需要**注入一个能立刻成功的 `_load()` 桩**，而不是靠多 pump 几帧。
   */
}

/// 把挂起的定时器在**用例体内**跑完（见文件头 ④）
Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 通过**遥控通道**发一条命令
///
/// # 为什么必须单独测这条路（①-C 的关键）
///
/// 手机端可以**直接发命令**，完全绕过控制条按钮的 enabled 态。
/// 如果边界判据只做在按钮上（`onPressed: null`），遥控这条路就会
/// **照切不误** —— 那正是用户报的「没有下一集却还是请求下一集」。
///
/// `execCommandForTest` 是 `RemoteBridge` 提供的 `@visibleForTesting`
/// 入口（它调的就是私有的 `_execCommand`），所以这里走的是
/// **与真实手机命令完全同一条分发路径**。
///
/// # ★★★ 我在这里踩了一个坑，必须记下来（否则测试永远是假绿）
///
/// 第一版这条测试**恒不生效**，症状是"计数怎么都不动"：
/// ```text
/// 遥控 next_episode 后：0 → 0
/// ```
/// 我一开始怀疑是判据拦住了 —— **错了**。真正的原因是
/// `_execCommand` 的**第一行**：
/// ```dart
/// final g = _globals;
/// if (g == null) return;        // ← ★ 全局能力没注册，直接返回
/// ```
/// `_globals` 由 `setGlobals()` 注册，而那是**应用启动时**才调的
/// （`shell.dart`）—— `flutter test` 里没人调它，所以**所有遥控命令
/// 都在第一行被丢掉**。
///
/// ⚠️ 这意味着：**不注册 globals 的话，"遥控命令没切集"这个结论
///    完全是假的** —— 它根本没走到播放页。
///    这正是铁律②说的"阳性对照失败 ⇒ 结论作废"：
///    如果我没写阳性对照，就会把"命令被丢弃"误读成"判据拦住了"。
///
/// 所以这里**必须先 `setGlobals`**（用一个空实现，只为让命令能往下走）。
Future<void> execRemoteForTest(WidgetTester t, String kind) async {
  // 只注册一次（幂等：重复 setGlobals 会重置 _stopped，无害）
  RemoteBridge.instance.setGlobals(GlobalBridge(
    search: (_) async {},
    loadHome: () async {},
  ));

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 这里用 `unawaited` 是**测试便利**，不是"更真实"
   *     （我第一版把它说成"真实桥就是 fire-and-forget" —— **说错了**）
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 为什么不能 await（实测）
   *
   * 那条 await 会一路等到 `_gotoEpisode` → `_reload()` **完全跑完**：
   * ```text
   * _reload() → SourinApi.resolveStream(...)   ← FFI 调用，带 120s 超时
   * ```
   * 而 `flutter test` 里没有真实网络/核心，这个 await **长时间不返回**
   *（实测那一轮跑了 10 分钟）⇒ 我的 `t.pump()` 根本没机会跑
   * ⇒ 计数读到的是"还没开始" ⇒ **阳性对照假红**。
   *
   * # ★ 真实遥控桥**是 await**（我核实过源码，不是猜的）
   *
   * ```dart
   * // remote_bridge.dart:484-487（_tick 的命令循环里）
   * for (final raw in cmds) {
   *   final c = RemoteCommand.fromJson(raw);
   *   await _execCommand(c);          // ← ★ 是 await，不是 unawaited
   * }
   * ```
   * ⇒ 真机上桥**会等**命令执行完（含 `_reload` → `resolveStream` 那条链）。
   *   所以我**不能**说"unawaited 更真实" —— 那是错的。
   *
   * # 本测试**验什么 / 不验什么**（边界必须写清楚）
   *
   * ```text
   * ✅ 验  ：命令是否被**正确拦下**（计数有没有涨）
   * ❌ 不验：整条链是否跑完（`_reload` 之后的起播）
   * ```
   * 这对本次要回答的问题**足够** —— 用户报的是"有没有发起切集动作"，
   * 而计数点在 `_gotoEpisode` 的**入口**，是那条链的**最上游**：
   * 只要入口没被调用，后面整条链都不会发生。
   *
   * ⚠️ 若将来要验"整条链跑完"，必须**注入一个能立刻返回的
   *    `resolveStream` 桩**，而不是靠 `unawaited` 绕过。
   */
  unawaited(RemoteBridge.instance.execCommandForTest(RemoteCommand(kind)));
  // 让 microtask 队列跑起来（`_gotoEpisode` 在第一个 await 之前就已把计数 +1）
  await t.pump(const Duration(milliseconds: 50));
  await t.pump(const Duration(milliseconds: 50));
  RemoteBridge.instance.stop();
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 第一组：行为层 —— 最后一集时**不许切集**
  // ═══════════════════════════════════════════════════════════════════
  group('①-C 行为层：最后一集点「下一集」不得切集', () {
    testWidgets('★★★ 阳性对照：中间某一集点「下一集」**必须**切集',
        (t) async {
      /*
       * ★ 这是**仪器自检** —— 先证明"计数能数到正常的切集"。
       *
       * 若这一条失败，说明探针数不到切集动作 ⇒
       * 下面那条"最后一集计数不变"就**不能**解读为"判据拦住了"
       * （可能只是仪器瞎了）。这正是铁律②的用法。
       */
      final eps = fakeEpisodes(5);
      // 停在第 3 集（中间）—— 前后都有
      await mountPlayer(t, episodes: eps, episodeIndex: 2);

      final before = debugPlayerGotoEpisodeCalls();
      expect(before, isNotNull, reason: '★ 必须有播放页实例才能读计数');

      /*
       * ★ 中间某一集：「下一集」**可见且可点** —— 这是本组的阳性对照。
       *
       * ⚠️ 用 `t.tap` 而不是"检查按钮在不在" —— 要点下去才算数，
       *    因为要验的是"**点了之后**计数会不会涨"。
       */
      final f = find.text('下一集');
      expect(f, findsOneWidget,
          reason: '★ 中间某一集时「下一集」按钮必须可见');
      await t.tap(f);
      await t.pump(const Duration(milliseconds: 200));
      final after = debugPlayerGotoEpisodeCalls();
      expect(
        after! - before!,
        1,
        reason: '★★ 阳性对照：正常切集必须被计数到 —— '
            '这一条不过，下面所有"没切集"的结论都不成立',
      );

      await drainTimers(t);
    });

    testWidgets('★★★ 最后一集点「下一集」：计数**不变**（真的没切集）',
        (t) async {
      final eps = fakeEpisodes(5);
      // 停在最后一集（下标 4 = 第 5 集）
      await mountPlayer(t, episodes: eps, episodeIndex: 4);

      final before = debugPlayerGotoEpisodeCalls();
      final blockedBefore = debugPlayerBlockedNavCalls();
      expect(before, isNotNull);

      /*
       * ★ 按钮**仍然可见但被禁用** —— 这是与旧测试
       *   （`player_capability_test.dart`）一致的**产品行为**。
       *
       * 我一度想改成"隐藏"，但被推翻了（理由见 `_BottomBar` 里那段长注释）：
       * ```text
       * ① 用户报的是"还是【请求】下一集"，不是"按钮不该显示"
       * ② 那个"请求"经编排者核实来自一个【探针】，不是客户端
       * ③ 客户端所有切集出口都已有 null 判据
       * ④ 旧测试来自用户原始诉求「要有按钮」—— 禁用仍可见，满足它
       * ```
       * ⇒ 所以这里断言的是"**点不动**"，不是"看不见"。
       */
      final f = find.text('下一集');
      expect(f, findsOneWidget,
          reason: '★ 最后一集时「下一集」按钮**仍然可见**（禁用而非隐藏）—— '
              '与旧测试 `player_capability_test.dart` 一致');

      // ★ 点它 —— 禁用状态下不该触发任何切集
      await t.tap(f, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 200));

      expect(
        debugPlayerGotoEpisodeCalls(),
        before,
        reason: '★★★ 用户报的 bug：最后一集**不得**执行切集。'
            '计数涨了 = 判据失效 = 真 bug',
      );

      await drainTimers(t);
    });

    testWidgets('★★★ 第一集点「上一集」：计数**不变**', (t) async {
      final eps = fakeEpisodes(5);
      await mountPlayer(t, episodes: eps, episodeIndex: 0);

      final before = debugPlayerGotoEpisodeCalls();
      expect(before, isNotNull);

      final f = find.text('上一集');
      expect(f, findsOneWidget,
          reason: '★ 第一集时「上一集」必须**可见**（禁用而非隐藏）');

      // 灰按钮点了不该有反应
      await t.tap(f, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 200));
      expect(
        debugPlayerGotoEpisodeCalls(),
        before,
        reason: '★★ 第一集点「上一集」不得切集',
      );

      await drainTimers(t);
    });

    testWidgets('★★ 最后一集时两个按钮都在（"下一集"只是禁用）',
        (t) async {
      /*
       * 防止"一刀切隐藏"—— 用户仍然需要看到这两个按钮的位置。
       * 按钮位置跳动（第一集/最后一集时消失）本身也是观感问题。
       */
      final eps = fakeEpisodes(5);
      await mountPlayer(t, episodes: eps, episodeIndex: 4);

      expect(find.text('上一集'), findsOneWidget,
          reason: '★ 最后一集时「上一集」必须还在');
      expect(find.text('下一集'), findsOneWidget,
          reason: '★ 最后一集时「下一集」**仍然可见**（禁用）—— '
              '隐藏会让按钮位置跳动');

      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 第二组：遥控通道也走同一条路（不能绕过判据）
  // ═══════════════════════════════════════════════════════════════════
  group('①-C 遥控通道：next_episode 在最后一集也必须被拦', () {
    testWidgets('★★★ 遥控 next_episode：最后一集时计数不变', (t) async {
      /*
       * ★ 为什么单独测遥控：手机端可以**直接发命令**，
       *   完全绕过控制条按钮的 enabled 态。
       *   如果判据只在按钮上做（`onPressed: null`），
       *   遥控这条路就会**照切不误** —— 那正是用户报的现象
       *   （"没有下一集却还是请求下一集"）。
       */
      final eps = fakeEpisodes(5);
      await mountPlayer(t, episodes: eps, episodeIndex: 4);

      final before = debugPlayerGotoEpisodeCalls();
      expect(before, isNotNull);

      // 通过遥控通道发一条 next_episode
      await execRemoteForTest(t, 'next_episode');
      await t.pump(const Duration(milliseconds: 200));

      expect(
        debugPlayerGotoEpisodeCalls(),
        before,
        reason: '★★★ 遥控发 next_episode 时，最后一集也**不得**切集 —— '
            '这是手机端绕过按钮 enabled 态的路径',
      );

      await drainTimers(t);
    });

    testWidgets('★★ 阳性对照：遥控 next_episode 在中间集**必须**切集',
        (t) async {
      final eps = fakeEpisodes(5);
      await mountPlayer(t, episodes: eps, episodeIndex: 2);

      final before = debugPlayerGotoEpisodeCalls();
      await execRemoteForTest(t, 'next_episode');
      await t.pump(const Duration(milliseconds: 200));

      expect(
        debugPlayerGotoEpisodeCalls()! - before!,
        1,
        reason: '★ 阳性对照：遥控切集必须被计数到',
      );

      await drainTimers(t);
    });
  });
}
