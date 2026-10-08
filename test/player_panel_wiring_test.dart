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
//  ①-A 接线层：`SheetTransition.slideFrom` 到底从哪来（task-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（★ 这是"补洞"，不是"再写一遍"）
//
// `test/sheet_close_animation_test.dart` 验的是 `SheetTransition`
// 这个**组件本身**的动画机制 —— 它全部通过（+7），而且机制是对的。
//
// 但它验"往下滑"时用的是**自建宿主**，`slideFrom` 是**硬编码**的：
// ```dart
// await t.pumpWidget(const _Host(slideFrom: Offset(0, 24)));   // ← 它自己传的
// ```
// 而**生产**的方向决策在 `player_page.dart` 里：
// ```dart
// SheetTransition(
//   visible: _episodeSheetOpen,
//   slideFrom: Device.isDesktop
//       ? const Offset(24, 0)      // PC      → 往右
//       : const Offset(0, 24),     // 手机/TV → 往下
// ```
// ⇒ 两者之间**没有任何测试**。全 `test/` 下 grep `slideFrom`，
//   命中的全是 peer 那个 `_Host` 自己传的值。
//
// # ★★★ 这个洞是真的（注入回归实验，2026-09-25 实测）
//
// 把生产接线改成常量 `Offset(0, 24)`（= 桌面也往下滑）：
// ```text
// test/sheet_close_animation_test.dart  → +7 All tests passed!    ← ★ 照样全绿
// 本文件                                 → +3 -2 Some tests failed ← ★ 当场变红
// ```
// ⇒ **测试绿 ≠ 行为对**。真机上桌面端会「从右边进来、往下面出去」
//   （用户说的"被甩飞"），而原有测试**一条都不会红**。
//
// # 本文件验什么
//
// 挂载**真实 `PlayerPage`**，点「选集」打开面板，
// 然后**从 widget 树里读 `SheetTransition.slideFrom`** ——
// 读的是生产代码真正传进去的值，不是我自己造的。
//
// # ★★ 两个必须如实写明的限制
//
// ```text
// ① 手机分支（Offset(0,24)）在 Windows 上**跑不到**：
//    Device._detect() 第一句就是
//      `if (!Platform.isAndroid) return DeviceKind.desktop;`
//    ⇒ 本机 isDesktop 恒为 true，手机分支不可达。
//    ⇒ 那条用**结构断言**（读生产源码）补，并注明这是静态判据。
//
// ② 线路面板当时也只能静态验：
//    它的按钮门控是 `hasStreams: _streams.length > 1`
//    （player_page.dart 的 _BottomBar 参数），而 `flutter test` 里
//    没有网络 ⇒ `_load()` 失败 ⇒ `_streams` 为空
//    ⇒ 「线路」按钮**根本不渲染** ⇒ tap 必然失败。
//
//    ★★★ 2026-09-29 task-74【④】：这条限制**已经不成立** ——
//    task-72 加了 `debugPlayerSetStreamsForProbe`，可以绕过网络把
//    线路直接注入**生产状态**，于是线路面板也能读**真实 widget 树**了。
//    ⇒ 组 B2 已从静态字符串断言改成与组 B 同手法（见「坑 4」）。
// ```
//
// # ⚠️ 写这个文件时踩的三个仪器坑（留给后人）
//
// ```text
// 坑 1：断言「桌面上【所有】SheetTransition 都必须是 (24,0)」—— 错。
//       实测 slideFrom = [(24.0,0.0), (0.0,24.0)]，因为两个面板形态不同：
//         · 选集面板 EpisodePanel  桌面=右侧抽屉(24,0) / 手机=底部(0,24)
//         · 线路面板 _StreamSheet  ★ 见下面的"坑 4"
//       ⇒ "所有都相同"是个**错误的不变量**，必须按面板分别断言。
//
// 坑 4（★ 2026-09-29 task-74【④】补记 —— 这是**比坑 1 更贵**的一课）：
//      上面这条"线路面板 Positioned(bottom:0) ⇒ 恒为 (0,24)"的**前提过期了**。
//      task-70 把 `_StreamSheet` 从 `Positioned(right:0)` 改成了
//      `Align(centerRight)`（右侧抽屉，player_page.dart:9028-9031），
//      但**这条断言没跟着改** ⇒ 它把 bug **锁成了契约**：
//      ```text
//      面板贴在右边、却断言"必须往下滑"
//        ⇒ 任何人想把方向改对，都会看到这条测试变红
//        ⇒ 于是"测试要求保持这个 bug"
//      ```
//      用户实际报的就是它：「线路,出来的弹窗是从上往下出现的」。
//      ★ 与 task-70 是**同一类缺陷**（"测试为了能跑/照旧而绕开生产真相"），
//        只是这次绕开的方式是"静态字符串断言 + 过期前提"。
//      ⇒ 本次把它**升级成读真实 widget 树**（与组 B 同手法），
//        前提变了会当场变红，而不是反过来把 bug 钉住。
//
// 坑 2：`find.ancestor(of: find.byType(EpisodePanel), ...)` 返回空 ——
//       因为面板**关闭时** SheetTransition 渲染的是
//       `const SizedBox.shrink()`（`if (!_mounted) return ...`）
//       ⇒ 子树整个不在树上。必须先 tap 打开面板再读。
//
// 坑 3：`expect(x, reason: ...)` 单参写法在 testWidgets 里会解析到
//       `WidgetTester.expect(actual, matcher)` ⇒ 编译错。
//       必须写 `expect(x, isTrue, reason: ...)`。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(
          id: 'ep$i',
          title: '第$i集',
          url: 'https://example.invalid/$i.m3u8',
        ),
    ];

/// 挂载**真实** `PlayerPage`，停在第一帧
///
/// ⚠️ 只 pump 一帧（`pumpWidget` 本身就是第一帧）——
///    多 pump 会让 `_load()` 失败置上 `_error`，控制条就不渲染了
///    （见 `.probe/probe_tests/README.md` 第 4 节「坑①」）。
Future<void> mountPlayer(WidgetTester t, {required List<Episode> eps}) async {
  // 控制条有 ~13 个按钮，默认 800x600 会溢出（见 README 第 4 节「坑②」）
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '接线验证',
        episodes: eps,
        episodeIndex: 0,
        episodeId: eps.first.id,
        episodeTitle: eps.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

/// 打开「选集」面板（控制条上的按钮）
///
/// ★ 必须先打开 —— 关闭时 `SheetTransition` 渲染的是 `SizedBox.shrink()`
///   （见文件头「坑 2」）。
///
/// ★★★ 2026-09-29 task-74 修：原来的 `pump()` + `pump(16ms)` **不够**，
///     表现为整条用例红在 `readEpisodeSlideFrom` 的
///     `Expected: non-empty / Actual: []`（面板压根没打开）。
///
/// # 为什么：PC 上单击 `onTap` 要等**双击窗口**过期
/// ```text
/// player_page.dart:6605  onDoubleTap: _isTouchGestureTarget ? null : (…)  ← PC 非空
/// kDoubleTapTimeout = 300ms（定义在 gestures/constants.dart）
/// ⇒ 屏幕上的任何单击，其 `onTap` 都要等 300ms 才派发。
/// ```
/// ★ 这是**本项目已实测过的同一个坑**（`test/t72_stream_sheet_test.dart`
///   L203-221 有完整证据：只 `pump()` 零时长 ⇒ 抽屉不关，日志里留着
///   `Timer(0:00:00.040000) #7 DoubleTapGestureRecognizer._trackTap`）。
///   ⇒ 这里补到 400ms（300 的窗口 + 余量），与那处同量级。
///
/// ⚠️ **不能用 `pumpAndSettle`**：本页有 5 秒周期定时器（`_progressTimer`）
///    与 3 秒的 `_hideTimer` ⇒ 永远 settle 不下来。
/// 打开「选集」面板
///
/// ★ 必须先打开 —— 关闭时 `SheetTransition` 渲染的是 `SizedBox.shrink()`
///   （见文件头「坑 2」）。
///
/// ★★★ 2026-09-29 task-74 修：原来走 `tap(find.text('选集'))`，
///     而那条路**在本机已经走不通**（实测诊断读数）：
/// ```text
/// DIAG|点之前:        选集按钮=1  EpisodePanel=0
/// DIAG|pump() 之后:   选集按钮=0  EpisodePanel=0   ← ★ 按钮自己没了
/// DIAG|pump(400ms) 后: 选集按钮=0  EpisodePanel=0  SheetTransition=3
/// ```
/// 根因 = 本文件头部的「坑①」：`_load()` 的 `resolveStream` 走 FFI，
/// 而 flutter_tester **加载不了 `sourin_core.dll`**（error 126）
/// ⇒ `_error` 置上 ⇒ `_BottomBar` 的渲染条件不成立
/// ⇒ 「选集」按钮**第一帧之后就消失** ⇒ `tap` 必然失败
/// （报错形态是 `readEpisodeSlideFrom` 里 `Expected: non-empty / Actual: []`，
///   看起来像"忘了打开面板"，其实**按钮已经点不到了**）。
///
/// ⇒ 改用**与组 B2 同一手法**的探针 `debugPlayerOpenEpisodeSheetForProbe`：
///   直接置生产状态 `_episodeSheetOpen`，绕过点不到的按钮。
///   ★ 读的仍是**生产那棵树**里的 `SheetTransition.slideFrom`（不是手抄副本）。
///
/// ⚠️ 原来"多 pump 会让 `_load()` 失败"的顾虑依然成立 ——
///    所以这里只 `pump()` 一帧（探针已同步置位，不需要等动画）。
Future<void> openEpisodeSheet(WidgetTester t) async {
  final opened = debugPlayerOpenEpisodeSheetForProbe();
  expect(opened, isTrue, reason: '探针要真的把 `_episodeSheetOpen` 置上');
  await t.pump();
  expect(debugPlayerAnySheetOpen(), isTrue,
      reason: '阳性对照：选集面板确实处于打开态');
}

/// 读**生产代码真正传给**「选集」面板的 `slideFrom`
Offset readEpisodeSlideFrom(WidgetTester t) {
  final f = find.ancestor(
    of: find.byType(EpisodePanel),
    matching: find.byType(SheetTransition),
  );
  final ws = t.widgetList<SheetTransition>(f).toList();
  // ⚠️ `isNotEmpty` **本身就是** matcher ⇒ 只传两个位置参数。
  //    写成 `expect(ws, isNotEmpty, isTrue, ...)` 会编译错
  //    （3 个位置参数，WidgetTester.expect 只收 2 个）。
  expect(ws, isNotEmpty,
      reason: '必须找到包着 EpisodePanel 的 SheetTransition —— '
          '若为空，检查是不是忘了先打开面板');
  return ws.first.slideFrom;
}

/// 读**生产代码真正传给**「线路」面板的 `slideFrom`（task-74【④】新增）
///
/// # 为什么不按类型找
/// `_StreamSheet` 是**私有类**，测试文件里引用不到它的类型。
/// ⇒ 改用一个**只有它会画**的字符串当锚点：表头 `'线路 / 清晰度'`
///   （`player_page.dart` 的 `_StreamSheet.build` 里），
///   再沿祖先链找包着它的 `SheetTransition`。
///
/// ⚠️ 用 `'线路 / 清晰度'` 而**不是** `'线路'`：
///    底栏那个按钮的文字是 `'线路'`，`find.text` 默认精确匹配，
///    两者不会混 —— 但若有人把表头改成 `'线路'`，这里会一次找到两个。
///    ⇒ 断言 `ws.length == 1`，让它当场变红而不是悄悄读错一个。
Offset readStreamSheetSlideFrom(WidgetTester t) {
  final f = find.ancestor(
    of: find.text('线路 / 清晰度'),
    matching: find.byType(SheetTransition),
  );
  final ws = t.widgetList<SheetTransition>(f).toList();
  expect(ws.length, 1,
      reason: '必须**恰好**有一个 SheetTransition 包着线路面板 —— '
          '为 0 说明抽屉没打开（或表头文案改了）；'
          '多于 1 说明表头文案与别处重复 ⇒ 本读取器读到的可能不是线路面板');
  return ws.first.slideFrom;
}

Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
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

  group('①-A 生产接线：SheetTransition 的 slideFrom 从哪来', () {
    testWidgets('组 A ★ 阳性对照：真实 PlayerPage 里能读到 SheetTransition',
        (t) async {
      await mountPlayer(t, eps: fakeEpisodes(5));

      final offsets = t
          .widgetList<SheetTransition>(find.byType(SheetTransition))
          .map((w) => w.slideFrom)
          .toList();

      expect(
        offsets,
        isNotEmpty,
        reason: '★ 阳性对照：真实播放页里必须能找到 SheetTransition —— '
            '找不到 ⇒ 本文件的读取器无效 ⇒ 下面结论作废（铁律②）',
      );
      await drainTimers(t);
    });

    testWidgets('组 B ★★★ 桌面：**选集**面板必须往右 Offset(24, 0)', (t) async {
      await mountPlayer(t, eps: fakeEpisodes(5));

      await openEpisodeSheet(t);
      final got = readEpisodeSlideFrom(t);

      /*
       * ★ 读的是**生产代码真正传进去的值** ——
       *   若有人把 `player_page.dart` 的接线改坏（例如恒写成 (0,24)），
       *   这一条会**当场变红**，而 `sheet_close_animation_test.dart`
       *   的 7 条**不会**（它用自己的 `_Host`，不读生产接线）。
       *   红度证明见文件头。
       */
      if (Device.isDesktop) {
        expect(
          got,
          const Offset(24, 0),
          reason: '★ 桌面端「选集」是**右侧**抽屉 ⇒ 必须往右滑出。'
              '接线在 player_page.dart：'
              '`slideFrom: Device.isDesktop ? const Offset(24, 0) : const Offset(0, 24)`',
        );
      }
      await drainTimers(t);
    });

    testWidgets('组 B2 ★★★ 线路面板：方向必须跟**几何**走（右侧抽屉 ⇒ 往右）',
        (t) async {
      await mountPlayer(t, eps: fakeEpisodes(5));

      /*
       * ★★★ 2026-09-29 task-74【④】重写 —— 这条原来是**静态字符串断言**，
       *     而且它的前提在 task-70 就已经过期了：
       * ```text
       * 旧前提：`_StreamSheet` 是 `Positioned(bottom: 0)` ⇒ 恒为底部抽屉
       * 实  际：task-70 已改成 `Align(centerRight)` ⇒ **右侧**抽屉
       *         （player_page.dart:9028-9031）
       * ```
       * ⇒ 它把 bug **锁成了契约**：谁想把方向改对，这条就变红。
       *   用户报的正是它：「线路,出来的弹窗是从上往下出现的」。
       *
       * ⇒ 现在改成与**组 B 同一手法**：用探针注入线路 + 打开抽屉，
       *   然后从 widget 树里读**生产真正传进去的** `slideFrom`。
       *   前提再变（面板挪到别处）会当场变红，而不是反过来钉住 bug。
       *
       * ⚠️ 原来"只能静态验"的理由（文件头「限制 ②」：没网络 ⇒ `_streams`
       *    为空 ⇒ 按钮不渲染）**已经不成立** ——
       *    task-72 加了 `debugPlayerSetStreamsForProbe`，
       *    可以绕过网络把线路直接注入生产状态。旧注释没跟着更新。
       */
      expect(
        debugPlayerSetStreamsForProbe(const [
          StreamCandidate(url: 'https://x.invalid/1.m3u8', label: 'A'),
          StreamCandidate(url: 'https://x.invalid/2.m3u8', label: 'B'),
        ]),
        isTrue,
        reason: '探针要真的把线路注入进去，否则「线路」按钮不渲染 ⇒ 测不了',
      );
      final opened = debugPlayerOpenStreamSheetForProbe();
      await t.pump();
      expect(opened, isTrue, reason: '线路抽屉要真的打开');
      expect(debugPlayerAnySheetOpen(), isTrue,
          reason: '阳性对照：抽屉确实处于打开态');

      final got = readStreamSheetSlideFrom(t);

      if (Device.isDesktop) {
        expect(got, const Offset(24, 0),
            reason: '★★★ 桌面端「线路」面板贴**右侧**'
                '（`_StreamSheet.build` = `Align(centerRight)` + '
                '`SizedBox(width:320)`，player_page.dart:9028-9031）'
                '⇒ 必须往**右**滑出。'
                '读成 (0,24) ⇒ 正是用户报的「从上往下出现」：'
                '面板在右边、却竖向滑走，与 `SheetTransition` 自己的契约'
                '（episode_strip.dart:1105-1106「必须与面板的进入方向一致」）'
                '相矛盾');
      }
      await drainTimers(t);
    });

    testWidgets('组 C ★★ 手机分支 (0, 24) 存在（Windows 上跑不到那条分支）',
        (t) async {
      /*
       * ★ 为什么只能静态验：
       *   `Device._detect()` 第一句就是
       *   `if (!Platform.isAndroid) return DeviceKind.desktop;`
       *   ⇒ Windows 上 `isDesktop` 恒为 true，手机分支**不可达**。
       *   这是**测试环境的限制**，不是代码的问题 —— 如实标注。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final idx = src.indexOf('slideFrom: Device.isDesktop');
      expect(
        idx,
        greaterThan(0),
        reason: '★ 选集面板的 slideFrom 必须按端分流 —— '
            '若被改成常量，手机端就会「从下面进来、往右边出去」',
      );

      // ⚠️ 取到**行边界**为止（下一个 `slideFrom:` 或 400 字符封顶）——
      //    固定 160 字符窗口不够：缩进 24 空格 + 两分支各占一行，
      //    第二分支会落在窗口外 ⇒ 假红（我踩过）。
      var end = src.indexOf('slideFrom:', idx + 10);
      if (end < 0 || end > idx + 400) end = idx + 400;
      final seg = src.substring(idx, end);

      expect(
        seg.contains('Offset(24, 0)') && seg.contains('Offset(0, 24)'),
        isTrue,
        reason: '★ 两个分支都必须存在：桌面 (24,0) 往右 / 手机 (0,24) 往下',
      );
      await drainTimers(t);
    });

    testWidgets('组 D ★ 两个面板都走 SheetTransition（关闭才有动画）', (t) async {
      await mountPlayer(t, eps: fakeEpisodes(5));

      final n = find.byType(SheetTransition).evaluate().length;
      expect(
        n,
        greaterThanOrEqualTo(2),
        reason: '★ 选集面板和线路面板都应该包在 SheetTransition 里 —— '
            '否则该面板关闭时没有动画（用户报的是"弹窗关闭没动画"）',
      );
      await drainTimers(t);
    });
  });
}
