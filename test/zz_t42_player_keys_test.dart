@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 与 `pc_arrow_keys_test.dart` 同因
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`（见下方 setUpAll），
// 它会加载 **libmpv-2.dll**。实测：在 `flutter test` 的 flutter_tester
// 进程里加载该原生库，会**偶发 native 崩溃**（访问违例 c0000005，
// 退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（见 .probe/native-media-tests.md）
// ```
//
// ★ 2026-09-26 补记：本文件**原先漏了这个标签** —— 全仓 7 个加载 libmpv 的
//   测试文件里，**只有这一个没标**。实测后果：默认全量 6 次跑里红 2 次，
//   且**每次都是本文件**在 `(tearDownAll) - did not complete`。
//   修法就是补上这个标签（其余 6 个文件早就标了）。
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --run-skipped --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读（见 dart_test.yaml）。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  task-42：播放页键盘/手势（空格 / Enter / 双击 = 全屏）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// ```text
// 然后播放页面要支持空格暂停/播放,enter 和 双击 进入/退出 全屏
// ```
//
// # ★★★ 为什么用 widget 测试（这是刻意的选择，不是退而求其次）
//
// 我先在真机上复现，结果**每一步都卡在"进不去播放页"**：
// ```text
// · 点内嵌播放器的全屏按钮 —— 7 个候选坐标全未命中（[PLAYER] 计数不变）
// · ★ 而我判断"在不在直播页"用的是**累计**日志（`"[LIVE]" in 全文`）——
//   一旦进过一次就永远为真 ⇒ 它在首页时我也以为在直播页
//   ⇒ 这是**我自己的探针 bug**（累计 vs 增量），不是产品问题
// ```
// ★ 本仓库**已有**能挂载**真 PlayerPage** 的夹具（`pc_arrow_keys_test.dart`），
//   它驱动的是**真实 `_onKey` 与真实 `GestureDetector`** ——
//   不受前台/坐标/遮挡影响，比真机点坐标**更可靠**。
//
// # 判据（全部用**已有 + 新增的只读探针**，不靠"看代码有这么一行"）
// ```text
// ① 空格（PC）  → debugPlayerTogglePlayCalls() +1
// ② Enter（PC） → debugPlayerFullscreenCalls() +1（**不是** togglePlay）
// ③ Enter（TV） → togglePlay +1 且 fullscreen **不变**（TV 确认键不能改）
// ④ 双击（PC）  → fullscreen +1
// ⑤ 双击（触摸）→ fullscreen **不变**（仍是左右快进快退）
// ⑥ F（PC）     → fullscreen +1（既有键位，不许被我改坏）
// ⑦ 面板打开时 Enter 不抢全屏
// ```

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂载**真实** PlayerPage
Future<void> mount(
  WidgetTester t, {
  required bool isTv,
  required bool isTouchOnly,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'task-42 播放页键盘',
        isTv: isTv,
        isTouchOnly: isTouchOnly,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器推完（否则用例结束报 "A Timer is still pending"）
///
/// ★ 照抄 `pc_arrow_keys_test.dart` 的做法与理由：有 `sourin_core.dll` 时
///   会多一个 `resolveStream` 的 120s timeout。
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 一次完整的按键（down + up）—— 与真人敲键一致
Future<void> tapKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(k);
  await t.pump(const Duration(milliseconds: 40));
  await t.sendKeyUpEvent(k);
  await t.pump(const Duration(milliseconds: 40));
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    for (final k in [
      'player.gesture.doubleTap.enabled',
      'player.gesture.doubleTap.seconds',
    ]) {
      UiPrefs.remove(k);
    }
  });

  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ① 阳性对照：夹具真的能把键送进 `_onKey`
  // ═══════════════════════════════════════════════════════════════════
  group('① 阳性对照（先证明仪器有效 —— 铁律②）', () {
    testWidgets('★ F 键（既有全屏键）能触发全屏 ⇒ 键真的到了 _onKey',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final before = debugPlayerFullscreenCalls();
      expect(before, isNotNull,
          reason: '★ 读不到探针 ⇒ 后面所有断言都无从判起（空断言比没断言更危险）');

      await tapKey(t, LogicalKeyboardKey.keyF);

      expect(
        debugPlayerFullscreenCalls(),
        before! + 1,
        reason: '★★ F 是**既有**全屏键，它必须仍能触发全屏。'
            '若这条都不过 ⇒ 说明键根本没到 _onKey（仪器问题），'
            '下面所有结论作废',
      );
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 空格 = 暂停/播放（PC）
  // ═══════════════════════════════════════════════════════════════════
  group('② 空格（PC）', () {
    testWidgets('★ 空格 = 播放/暂停（不是全屏）', (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final tp0 = debugPlayerTogglePlayCalls();
      final fs0 = debugPlayerFullscreenCalls();
      expect(tp0, isNotNull);

      await tapKey(t, LogicalKeyboardKey.space);

      expect(debugPlayerTogglePlayCalls(), tp0! + 1,
          reason: '★ 空格必须触发一次播放/暂停');
      expect(debugPlayerFullscreenCalls(), fs0,
          reason: '★ 空格**不该**触发全屏（那是 Enter/双击/F 的事）');
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ Enter（PC）= 全屏（本次用户要求）
  // ═══════════════════════════════════════════════════════════════════
  group('③ Enter（PC）= 进入/退出全屏', () {
    testWidgets('★ Enter 触发全屏切换（**不是**播放/暂停）', (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final tp0 = debugPlayerTogglePlayCalls();
      final fs0 = debugPlayerFullscreenCalls();

      await tapKey(t, LogicalKeyboardKey.enter);

      expect(debugPlayerFullscreenCalls(), fs0! + 1,
          reason: '★★ 用户明确要求「enter 进入/退出 全屏」'
              '⇒ Enter 必须切换全屏');
      expect(debugPlayerTogglePlayCalls(), tp0,
          reason: '★ Enter 在桌面**不再**是播放/暂停（已改给全屏；'
              'PC 的播放/暂停仍可用空格）');
      await drain(t);
    });

    testWidgets('★ 连按两次 Enter ⇒ 进入再退出（计数 +2，布尔回原值）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final fs0 = debugPlayerFullscreenCalls()!;
      final wasFs = debugPlayerIsFullscreen();

      await tapKey(t, LogicalKeyboardKey.enter);
      final afterOne = debugPlayerIsFullscreen();
      await tapKey(t, LogicalKeyboardKey.enter);

      expect(debugPlayerFullscreenCalls(), fs0 + 2,
          reason: '★ 两次 Enter ⇒ 两次切换（**计数**才能证明"退出"也发生了；'
              '只看布尔会以为没反应）');
      expect(afterOne, !(wasFs ?? false),
          reason: '★ 第一次 Enter 之后全屏状态应反转');
      expect(debugPlayerIsFullscreen(), wasFs,
          reason: '★ 第二次 Enter 应回到原状态（进得去也出得来）');
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ Enter（TV）**仍是**播放/暂停（不许改坏遥控）
  // ═══════════════════════════════════════════════════════════════════
  group('④ Enter（TV）= 确认键，不许改成全屏', () {
    testWidgets('★★ TV 的 Enter 仍是播放/暂停，且**不**触发全屏', (t) async {
      await mount(t, isTv: true, isTouchOnly: false);
      final tp0 = debugPlayerTogglePlayCalls();
      final fs0 = debugPlayerFullscreenCalls();

      await tapKey(t, LogicalKeyboardKey.enter);

      expect(debugPlayerTogglePlayCalls(), tp0! + 1,
          reason: '★ TV 的确认键必须仍是播放/暂停 —— '
              '它同时是选集/按钮的确认键（见 L4086 那段长注释）');
      expect(debugPlayerFullscreenCalls(), fs0,
          reason: '★★ TV 上 Enter **绝不能**变成全屏 —— '
              '否则会复发"看得见、走得动、**选不了**"那个 bug');
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 双击 = 全屏
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 双击', () {
    testWidgets('★ PC 双击画面 ⇒ 全屏', (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final fs0 = debugPlayerFullscreenCalls();

      final center = t.getCenter(find.byType(Scaffold));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 120));

      expect(
        debugPlayerFullscreenCalls(),
        fs0! + 1,
        reason: '★★ 用户要求「双击 进入/退出 全屏」⇒ PC 双击必须切全屏。'
            '★ 注意 PC 上"双击左右快进快退"是**关闭**的'
            '（`doubleTapEnabledFor(isTouch:)` 对非触摸恒 false）'
            '⇒ 这里是空档，零冲突',
      );
      await drain(t);
    });

    testWidgets('★★ 触摸端双击**不**触发全屏（仍是左右快进快退）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: true);
      final fs0 = debugPlayerFullscreenCalls();

      final center = t.getCenter(find.byType(Scaffold));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 120));

      expect(
        debugPlayerFullscreenCalls(),
        fs0,
        reason: '★ 触摸端的双击**必须**保持为"左右快进快退"（既有行为 + 设置开关），'
            '本次改动**不许**碰它',
      );
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 浮层打开时 Enter 不抢
  // ═══════════════════════════════════════════════════════════════════
  group('⑥ 浮层打开时 Enter 让给浮层', () {
    testWidgets('★ 按 Esc 打开/关闭浮层后 Enter 语义正确（用可达的浮层）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);

      /*
       * ★ 这里刻意**不**造浮层（当时没有 `ForProbe` 那样的入口，不新增
       *   只为测试而存在的生产 API —— 那会污染产品代码）。
       * ⇒ 改为断言**判据本身**成立：`_anySheetOpen` 把浮层**列全**。
       *   真正的"浮层里 Enter 归浮层"由既有的
       *   `player_episode_nav_boundary_test.dart` 覆盖（那是 TV 场景）。
       *
       * ⚠️ 2026-10-04 补：**现在已经有** `debugPlayerOpenHintsForProbe()`
       *   （`player_page.dart:9007`）可以真的打开浮层，且
       *   `t63_shot_ui_test.dart` 正在用它做「浮层下 S 键不生效」的门控用例
       *   —— 那条用例与这里断言的是**同一件事的两种层**（行为层 vs 源码层），
       *   两者都留着：源码层能挡住「getter 被拆开/漏项」，行为层能挡住「门控被删」。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-04 修：原来断言的是**带换行的逐字源码**
       * ```dart
       * src.contains('bool get _anySheetOpen =>\n'
       *              '      _episodeSheetOpen || _settingsOpen || _streamSheetOpen || _hintsOpen;')
       * ```
       * ⇒ 那条断言**已被源码推翻**：`_anySheetOpen` 现在列 **6** 种浮层
       *   （task-53【③】加了 `_liveChannelsOpen`，task-13 ⑦ 加了 `_danmakuSheetOpen`），
       *   而「4 成员那一行」**早已不存在** ⇒ `contains` 恒 false ⇒ 本用例**假红**
       *   （实测：本文件 mtime 2026-09-26，之后没人再跑过它 —— 它是 native-media 标签，
       *     默认套件里被 skip，所以红了两周没人看见）。
       *
       * ★ 它错在**判据与要守的东西不同层**：它守的是「列全」，却写成
       *   「逐字等于某一行」⇒ 加浮层是**合法**改动，反而会把它撞红
       *   ⇒ 于是它既挡不住漏项（换行/空格一变就失去分辨力），又误伤合法改动。
       * ⇒ 换成与「列全」同层的判据：**把 getter 正文抠出来，逐个点名**。
       *   「漏一个」会红（判据有效），「多一个」不会红（不误伤）。
       *   实测数字：当前 getter 共列 **6** 种浮层（下面逐个断言）。
       */
      final gi = src.indexOf('bool get _anySheetOpen');
      expect(
        gi,
        greaterThanOrEqualTo(0),
        reason: '★ 前置条件：getter 必须还在 —— 否则下面测的是空串（恒真，等于没测）',
      );
      final body = src
          .substring(gi, src.indexOf(';', gi))
          .replaceAll(RegExp(r'//[^\n]*'), '')
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
      for (final name in const [
        '_episodeSheetOpen',
        '_settingsOpen',
        '_streamSheetOpen',
        '_hintsOpen',
        '_liveChannelsOpen',
        '_danmakuSheetOpen',
      ]) {
        expect(
          body.contains(name),
          isTrue,
          reason: '★★ `_anySheetOpen` 必须列全**六种**浮层 —— '
              '漏了 $name 就会出现「面板开着按 Enter 却全屏了」',
        );
      }
      expect(
        src.contains('!widget.isTv && !_anySheetOpen'),
        isTrue,
        reason: '★★ 桌面 Enter=全屏必须同时满足「不是 TV」且「没有浮层」',
      );
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ ★★★ 硬件层兜底（焦点**不在**播放页时也要工作）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么这是本轮最关键的一组
  // ```text
  // 真机实测：键盘 0 条 [PLAYER-KEY]，鼠标双击有效
  //   ⇒ 键进了 Flutter，但 `Focus(onKeyEvent: _onKey)` 收不到
  //   ⇒ 根因：用户 push 进播放页后焦点仍在**上一页**（兄弟关系，不在祖先链上）
  // ★ 所以"焦点正常时能工作"**不足以**证明用户能用 ——
  //   必须证明"**焦点不在本页时**也能工作"。
  // ```
  group('⑦ ★★★ 硬件层兜底（焦点不在播放页）', () {
    testWidgets('★★ 焦点被移走后，空格**仍然**能播放/暂停（兜底生效）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);

      // ① 先把焦点**移出**播放页（模拟"用户从上一页 push 进来"）
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump(const Duration(milliseconds: 60));
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '(无)';
      expect(
        label.contains('PlayerPage'),
        isFalse,
        reason: '★ 前置条件：焦点必须真的离开播放页（当前=$label），'
            '否则这条测的还是"焦点正常"那条路（等于没测兜底）',
      );

      // ② 记录基线
      final tp0 = debugPlayerTogglePlayCalls();
      expect(tp0, isNotNull);

      // ③ 发空格 —— 此时 `_onKey` 收不到（焦点不在），只能靠兜底
      await tapKey(t, LogicalKeyboardKey.space);

      expect(
        debugPlayerTogglePlayCalls(),
        tp0! + 1,
        reason: '★★ 焦点不在播放页时，空格**必须**仍能播放/暂停 —— '
            '这正是真机上"按空格没反应"的根因所在。'
            '若这条不过 ⇒ 用户点名的功能在真机上仍然不工作',
      );
      await drain(t);
    });

    testWidgets('★★ 焦点被移走后，Enter 仍能切换全屏（兜底生效）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);

      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump(const Duration(milliseconds: 60));

      final fs0 = debugPlayerFullscreenCalls();
      await tapKey(t, LogicalKeyboardKey.enter);

      expect(
        debugPlayerFullscreenCalls(),
        fs0! + 1,
        reason: '★★ 焦点不在播放页时，Enter 仍须切换全屏',
      );
      await drain(t);
    });

    testWidgets('★★★ 防双触发：焦点**在**本页时，空格只触发一次',
        (t) async {
      /*
       * ★ 这是"加了兜底之后才会出现的新 bug"的守卫。
       *
       * 本 handler 跑在 `_onKey` **之前**。若两条路都处理空格：
       * ```text
       * 暂停 → 播放 ⇒ 净效果 = **没反应**（用户会以为键坏了）
       * ```
       * 而且它**只在焦点正常时**出现 ⇒ 真机上"有时好有时坏"，最难查。
       */
      await mount(t, isTv: false, isTouchOnly: false);

      final tp0 = debugPlayerTogglePlayCalls()!;
      await tapKey(t, LogicalKeyboardKey.space);

      expect(
        debugPlayerTogglePlayCalls(),
        tp0 + 1,
        reason: '★★★ 空格必须**恰好**触发一次 —— '
            '2 次说明 `_onKey` 与硬件兜底**都**处理了（净效果=没反应）',
      );
      await drain(t);
    });

    testWidgets('★★ 焦点被移走后，Esc 仍能退出全屏（逃生口不能丢）',
        (t) async {
      /*
       * ★ 真机实测发现的缺口（`.probe/t42_player_final.txt`）：
       * ```text
       * Enter ⇒ 进全屏 ✓（2560x1440）
       * 双击  ⇒ 退全屏 ✓（1280x800）
       * Esc   ⇒ ★ 被入口记到了，但**没退全屏**
       * ```
       * 原因：Esc 的退出全屏逻辑在 `_onKey`（焦点路径），
       * 而这条测试正是"焦点不在本页"的场景 ⇒ 需要兜底。
       * ★ 全屏是"用户可能被困住"的状态（窗口没标题栏、没边框），
       *   所以 Esc 这个通用逃生口**必须**在兜底路径里也有。
       */
      await mount(t, isTv: false, isTouchOnly: false);

      // 先进入全屏（用 Enter，此时焦点还在页内 ⇒ 走 _onKey）
      await tapKey(t, LogicalKeyboardKey.enter);
      expect(debugPlayerIsFullscreen(), isTrue,
          reason: '★ 前置条件：必须先真的进了全屏，否则测不出"退不出"');

      // 再把焦点移走（模拟真机上"焦点不在播放页"）
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump(const Duration(milliseconds: 60));

      final fs0 = debugPlayerFullscreenCalls()!;
      await tapKey(t, LogicalKeyboardKey.escape);

      expect(
        debugPlayerFullscreenCalls(),
        fs0 + 1,
        reason: '★★ 焦点不在播放页时，Esc **必须**仍能退出全屏 —— '
            '否则用户进了全屏又没有焦点，就被**困在**全屏里了',
      );
      expect(debugPlayerIsFullscreen(), isFalse);
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑧ ★★★ 浮层打开时空格必须让给浮层（另一代理独立验证发现的真 bug）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 症状（`.probe/` 里 V43h 那组实测）
  // ```text
  // V43h|【阳性对照】无浮层：togglePlay 增量=1 ✓
  // V43h|浮层打开后：togglePlay 增量 = **1**   ← ★★ 穿透
  // V43h|浮层状态（浮层=true）= true           ← ★ 前置条件成立
  // ```
  // # 根因
  // ```text
  // 硬件路径 `_onHardwareKey` 有全局 `_anySheetOpen` 门控 ⇒ 返回 ignored
  // ⇒ 派发**继续** ⇒ 焦点路径 `_onKey` 被调用
  // ★ 而 `_onKey` 的**桌面空格分支**没有浮层检查 ⇒ 后台播放器被切
  // ```
  group('⑧ ★★★ 浮层打开时，空格让给浮层', () {
    testWidgets('★ 阳性对照：无浮层时空格能切播放（先证明判据有效）',
        (t) async {
      await mount(t, isTv: false, isTouchOnly: false);
      final tp0 = debugPlayerTogglePlayCalls()!;
      await tapKey(t, LogicalKeyboardKey.space);
      expect(
        debugPlayerTogglePlayCalls(),
        tp0 + 1,
        reason: '★ 阳性对照：**没有浮层**时空格必须能切播放 —— '
            '若这条不过，下面的"浮层下不切"就可能是"键根本没到"（假阴性）',
      );
      await drain(t);
    });

    testWidgets('★★★ 浮层打开时，空格**不**切后台播放器', (t) async {
      await mount(t, isTv: false, isTouchOnly: false);

      /*
       * ★ 先**真的打开**一个浮层，并断言它开了 ——
       *   否则这条测的还是"无浮层"那条路（等于没测）。
       * ★ 用快捷键提示浮层（`_hintsOpen`）：它是四者中唯一
       *   不依赖 FFI 数据的（选集/线路要靠真实剧集/线路）。
       */
      final opened = debugPlayerOpenHintsForProbe();
      await t.pump(const Duration(milliseconds: 80));
      expect(
        opened,
        isTrue,
        reason: '★★ 前置条件：浮层必须**真的打开了** —— '
            '否则本用例测的是"无浮层"，结论无效'
            '（这正是"必须能区分违规与没测到"的用法）',
      );
      expect(
        debugPlayerAnySheetOpen(),
        isTrue,
        reason: '★★ 断言"浮层打开"这个状态本身（不靠推断）',
      );

      final tp0 = debugPlayerTogglePlayCalls()!;
      await tapKey(t, LogicalKeyboardKey.space);

      expect(
        debugPlayerTogglePlayCalls(),
        tp0,
        reason: '★★★ 浮层打开时空格**绝不能**切后台播放器 —— '
            '浮层挡着画面，用户看不见播放器变了，只会觉得"怎么乱了"。'
            '★ 这与 L4367 修过的"面板打开按 OK 却暂停了"是**同族**问题：'
            '那次修的是 TV 的确认键，**空格（PC 主键）一直没设防**',
      );
      await drain(t);
    });

    testWidgets('★★ 浮层打开时，Enter **仍**能到浮层（不许被顺手改坏）',
        (t) async {
      /*
       * ★ 这条守的是"修 bug 时别把既有功能改坏"。
       *
       * `_onKey` 里 Enter 的既有逻辑**自己**用了 `_anySheetOpen` 做分支：
       * ```dart
       * if (enterLike) {
       *   if (!widget.isTv && !_anySheetOpen) { …全屏… }
       *   _togglePlay();          // ← 浮层打开时落到这里
       * }
       * ```
       * ⇒ 若为了修空格而在**函数开头**写全局 `if (_anySheetOpen) return ignored;`
       *   Enter 就永远到不了那个 fallback ⇒ **把既有行为改坏**。
       * ★ 所以我只在空格分支加检查；这条测试证明 Enter 未受影响。
       */
      await mount(t, isTv: false, isTouchOnly: false);
      final opened = debugPlayerOpenHintsForProbe();
      await t.pump(const Duration(milliseconds: 80));
      expect(opened, isTrue, reason: '★ 前置条件：浮层要真的打开');

      final fs0 = debugPlayerFullscreenCalls()!;
      final tp0 = debugPlayerTogglePlayCalls()!;
      await tapKey(t, LogicalKeyboardKey.enter);

      expect(
        debugPlayerFullscreenCalls(),
        fs0,
        reason: '★ 浮层打开时 Enter **不该**全屏（这是既有语义）',
      );
      expect(
        debugPlayerTogglePlayCalls(),
        tp0 + 1,
        reason: '★ 浮层打开时 Enter 落到既有 fallback（播放/暂停）—— '
            '修空格**不许**动这条',
      );
      await drain(t);
    });
  });
}
