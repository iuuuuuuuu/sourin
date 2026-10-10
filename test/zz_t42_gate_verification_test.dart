// ═══════════════════════════════════════════════════════════════════════
//  task-42 三道门控 + "一次按键只切一个台" —— 回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 来源：独立验证（2026-09-25，`fix-autoscroll`）的变异测试
//
// ```text
// 对 `_onHardwareKey` 的三道门控各做一个变异（改坏）：
//   ① 可见性门控失效（恒放行）  -> 目标测试**全绿** ★
//   ② 最上层路由门控失效        -> 目标测试**全绿** ★
//   ③ 输入框守卫失效            -> 目标测试**全绿** ★
// ⇒ 3/3 全绿 ⇒ 当时**没有任何测试守着这三道门控**。
// ```
//
// # ★★★ 关键：先证明"可测"，再说"缺口"
//
// "没有测试守住"有两种原因，**必须分辨**（否则会误报缺口）：
// ```text
// (a) 作者漏了测试       ⇒ 真缺口
// (b) **结构上测不了**   ⇒ 结构墙（铁律 79），不是缺口
// ```
// ★ `live_page_test.dart` 文件头**声称**是 (b)：
// ```text
// 「`LivePage` 整页依赖 FFI bridge（`SourinApi.getLiveChannels` 走
//   `SourinCore.callAsync`），`flutter test` 里起不来。」
// ```
// ★★ 独立验证**实测证明这个声称是假的**：
// ```text
// VERIFY42A|mounted_ok=true
// VERIFY42A|looks_like_FFI_failure=false
// VERIFY42A|LivePage_elements=1
// VERIFY42B|VERDICT live_mountable_in_shell=true
// ⇒ LivePage **挂得起来**（独立挂 + 在 ShellPage 里挂都行）
// ```
// ★ 为什么挂得起来：`loadAll()` 里的 FFI 调用**失败被 catch 了**
//   （日志 `[LIVE] 加载直播频道失败: ...sourin_core.dll...`），
//   **不影响 widget 建树** ⇒ 页面照样 mount，只是频道列表为空。
// ⇒ 所以 (a) 成立：这是**真缺口**，三道门控**应该**有测试。
//
// # ⚠️⚠️ 2026-09-25 修 bug 后，**观测方式必须改**（否则判据恒假）
//
// ```text
// 我第一版用 `HardwareKeyboard.instance.handleKeyEvent(↓)` **直接**发键 ——
// 那时 LivePage 注册在 `HardwareKeyboard` 上 ⇒ 能触发 ✓
//
// ★ 但修 bug 时改成了 `FocusManager.instance.addEarlyKeyEventHandler`
//   （根因：`HardwareKeyboard.addHandler` 的返回值**不中止派发** ⇒ 切两个台）
// ⇒ 实测（`.probe/probe_tests/zz_v42_prefix_test.dart` VERIFY42Q2）：
//     方式A 直接 handleKeyEvent : hw=1 early=**0**  ← ★ 不再触发 early handler
//     方式B tester.sendKeyEvent  : hw=1 early=**1**  ← ✓
//   ⇒ 若继续用方式A ⇒ 三条判据**恒为 false** ⇒ 假的"全被挡住"（铁律 78）
// ```
// ⇒ 本文件统一走**完整管道** `tester.sendKeyEvent`（经
//   `ServicesBinding` → `HardwareKeyboard` → `FocusManager` → early handler）。
//
// # ★ 观测手段：`_onHardwareKey` 在**三道门控之后**打的那行日志
//
// ```text
// `_onHardwareKey` 的结构：
//     [LIVE-KEY] ⓪ 入口：...（**无条件**，最先打）
//     门控① 可见性 / 门控② 路由 / 门控③ 输入框
//     [LIVE-KEY] ② 事件层：硬件 handler 收到 ↓     ← ★ 只在这之后打
//     cycleChannel(1)
// ⇒ 捕获到 `② 事件层` ⟺ 三道门控**全部通过**
// ★ 这个观测**不依赖频道列表非空**（`cycleChannel` 判空在后面）
//   ⇒ 不需要 FFI 数据 ⇒ 门控是**纯逻辑**，完全可测。
// ```
//
// # ⚠️ 每条都带**阳性对照**（否则"挡住"可能只是"没测到"）
//
// ```text
// 只断言"被盖住 ⇒ 没打日志"是不够的 —— 若探针本身失效（比如
// `debugPrint` 没被捕获），也是"没打日志"。
// ⇒ 必须同时断言"正常情况 ⇒ 打了日志"（阳性对照）。
// ★ 这正是铁律 2：阳性对照失败 ⇒ 判据无效 ⇒ 结论作废。
// ```

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

Widget _themed({required Widget home, GlobalKey<NavigatorState>? navKey}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    navigatorKey: navKey,
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

/// 日志探针：捕获 `[LIVE-KEY]` 的两行关键日志
///
/// ```text
/// ⓪ 入口   —— **无条件**打（证明 handler 真的被调用了）
/// ② 事件层 —— 只在**三道门控全过**之后打
/// ```
///
/// # ⚠️⚠️ 必须**显式还原** `debugPrint`（我第一版漏了 ⇒ 4 条测试全红）
///
/// ```text
/// 我第一版只 install 不 restore ⇒ 报：
///   debugAssertAllFoundationVarsUnset.<anonymous closure>
///   (package:flutter/src/foundation/debug.dart:45:7)
/// ⇒ ★ flutter_test 在**每个测试结束时**断言"框架全局变量已复原"，
///   而 `debugPrint` 是其中之一 ⇒ 不还原就**每个测试都失败**。
///
/// ★ 我试过用 `addTearDown(restore)` —— **太晚**（断言在 teardown 之前跑）。
/// ⇒ 必须在**测试体内**显式调 `restore()`。
/// ★ 项目里已记过同一个坑（task-41 的 keepalive_acceptance_test）：
///   「`debugPrint` 被 binding 接管 ⇒ 覆盖它捕获不到」
///   以及「覆盖必须在测试体内还原，`addTearDown` 太晚」。
/// ```
class KeyProbe {
  final List<String> logs = [];
  void Function(String?, {int? wrapWidth})? _orig;

  void install() {
    _orig = debugPrint;
    final orig = _orig!;
    debugPrint = (String? msg, {int? wrapWidth}) {
      if (msg != null && msg.contains('[LIVE-KEY]')) logs.add(msg);
      orig(msg, wrapWidth: wrapWidth);
    };
  }

  /// ★ 必须在**测试体内**调用（不能只靠 `addTearDown`）
  void restore() {
    final o = _orig;
    if (o != null) {
      debugPrint = o;
      _orig = null;
    }
  }

  void clear() => logs.clear();

  /// handler 是否被调用过（**无条件**那行）
  bool get reachedHandler => logs.any((l) => l.contains('⓪ 入口'));

  /// `⓪ 入口` 出现的**次数**
  ///
  /// ★ 用途（`add-remote-order` 建议的判据）：
  ///   一次按键只应产生 **1** 行入口日志 ——
  ///   若 =2 ⇒ 说明有**两个 keydown** 到达（可能是按键重复或投递两次），
  ///   那就**不是**"双路径"的锅，而是输入层的问题。
  ///   ⇒ 它是"只有一次按键"的**前置证据**（排除干扰解释）。
  int get entryCount => logs.where((l) => l.contains('⓪ 入口')).length;

  /// 三道门控是否**全部通过**（那行只在门控之后打）
  bool get passedGates => logs.any((l) => l.contains('② 事件层'));

  /// `cycleChannel` 被调用了几次（★ 用于"一次按键只切一个台"）
  int get cycleCalls => logs.where((l) => l.contains('③ 逻辑层')).length;
}

/// 发一次 ↓（走**完整管道**），返回已捕获日志的探针
///
/// ★ 必须 `await` —— `sendKeyEvent` 是异步的。
///
/// # ★★ 为什么在**函数内部**就 `restore()`
/// ```text
/// `flutter_test` 在**每个测试结束时**断言"框架全局变量已复原"
/// （`debugAssertAllFoundationVarsUnset`，debug.dart:45）——
/// `debugPrint` 是其中之一 ⇒ 不还原 ⇒ **每个测试都失败**。
/// ★ 我第一版只 install 不 restore ⇒ 4 条测试全红。
/// ★ 也不能只靠 `addTearDown(restore)` —— 断言在 teardown **之前**跑。
///
/// ⇒ 最稳的位置是**这里**：日志在 `sendKeyEvent` + `pump` 期间已经
///   全部捕获进 `logs` 列表（`restore` 不会清空它），
///   所以发完就立刻还原 ⇒ 调用方**不需要**记得还原（少一个坑）。
/// ```
Future<KeyProbe> _arrowDown(WidgetTester tester) async {
  final p = KeyProbe()..install();
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await tester.pump();
  p.restore(); // ★ 立刻还原（日志已捕获）
  return p;
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _settle(WidgetTester tester, [int ms = 600]) async {
  await tester.pump();
  _claim(tester);
  await tester.pump(Duration(milliseconds: ms));
  _claim(tester);
}

/// 收尾（★ 铁律 107：抽成公共函数，不要写在单个测试里）
///
/// ```text
/// `LivePage` 有 30 秒 periodic Timer（`_clock`）—— 不等它到点会报
/// "A Timer is still pending"。
/// ★ 我第一版只在第 1 个测试里写了收尾，第 2 个就报了 —— 见铁律 107。
/// ```
Future<void> _teardownTree(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  _claim(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  _claim(tester);
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

void main() {
  group('task-42 ★ 直播页方向键三道门控（判定表）', () {
    testWidgets('★★★ 门控① 可见性：visible=false ⇒ 挡住 / true ⇒ 放行',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final notifier = ValueNotifier<bool>(false);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(_themed(home: LivePage(visible: notifier)));
      await _settle(tester);

      // ★★ 阳性对照（先做）：handler **必须**被调用 ——
      //    否则后面的"没通过门控"可能只是"根本没收到键"
      final a = await _arrowDown(tester);
      expect(a.reachedHandler, isTrue,
          reason: '★★ 阳性对照：↓ 必须**到达** handler（`⓪ 入口` 那行）。\n'
              '  若这里就是 false ⇒ 键根本没进 Flutter ⇒ 后面的判据全部无效。');

      // ★ 阴性：明确说"不可见" ⇒ 必须被门控①挡住
      expect(a.passedGates, isFalse,
          reason: '★★ 门控①：`visible=false`（且拿不到 ShellScope）时\n'
              '  `_isVisibleForKeys()` 必须返回 false ⇒ 挡住方向键。\n'
              '  若这里 passed ⇒ 保活页在后台会**抢键**：\n'
              '  用户在首页按 ↓ 会把直播页的台切掉。');

      // ★★ 阳性对照 2：同一页面改成"可见" ⇒ 必须放行
      notifier.value = true;
      await _settle(tester, 200);
      final b = await _arrowDown(tester);
      expect(b.passedGates, isTrue,
          reason: '★★ 阳性对照：`visible=true` 时必须**放行**。\n'
              '  若这里也是 false ⇒ 说明"挡住"不是因为门控，\n'
              '  而是探针/管道有问题（判据无效 ⇒ 结论作废）。');

      await _teardownTree(tester);
    });

    testWidgets('★★★ 门控② 最上层路由：被盖住 ⇒ 挡住 / 最上层 ⇒ 放行',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
          _themed(home: const LivePage(), navKey: navKey));
      await _settle(tester);

      // ★★ 阳性对照：最上层 ⇒ 放行
      final a = await _arrowDown(tester);
      expect(a.reachedHandler, isTrue, reason: '★ 阳性对照：handler 必须被调用');
      expect(a.passedGates, isTrue,
          reason: '★★ 阳性对照：本页是最上层路由时必须**放行**。');

      // push 一层盖住 ⇒ 应挡住
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('盖住'))),
      ));
      await _settle(tester, 400);

      final b = await _arrowDown(tester);
      expect(b.passedGates, isFalse,
          reason: '★★ 门控②：全屏播放页 / 详情页压在上面时，↑/↓ 是它们的\n'
              '  （播放器是音量、详情页是选剧集）⇒ **不能抢**。\n'
              '  若这里 passed ⇒ 用户在播放页按 ↓ 会同时切直播的台。');

      await _teardownTree(tester);
    });

    testWidgets('★★★ 门控③ 输入框：焦点在 TextField ⇒ 挡住 / 否则放行',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_themed(home: const _LiveWithField()));
      await _settle(tester);

      // ★★ 阳性对照：焦点不在输入框 ⇒ 放行
      final a = await _arrowDown(tester);
      expect(a.reachedHandler, isTrue, reason: '★ 阳性对照：handler 必须被调用');
      expect(a.passedGates, isTrue,
          reason: '★★ 阳性对照：焦点不在输入框时必须**放行**。');

      // 把焦点移到 TextField
      await tester.tap(find.byType(TextField));
      await _settle(tester, 200);

      final b = await _arrowDown(tester);
      expect(b.passedGates, isFalse,
          reason: '★★ 门控③：输入框里 ↑/↓ 该移动光标，不该切台。\n'
              '  若这里 passed ⇒ 用户在搜索框里按 ↓ 会切掉直播的台。\n'
              '  ★ 这条在 early handler 下**尤其重要**：\n'
              '    early handler 在**所有 Focus 之前**跑 ⇒\n'
              '    若它不认输入框，就会把本该给输入框的 ↓ 吃掉。');

      await _teardownTree(tester);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 修 bug 的回归：按一次 ↓ **只能切一个台**
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 守的是什么（独立验证发现 + 已修）
  //
  // ```text
  // Flutter `hardware_keyboard.dart` `_dispatchKeyEvent`：
  //     for (final handler in _handlers) {
  //       final bool thisResult = handler(event);
  //       handled = handled || thisResult;      // ★ 没有 break
  //     }
  // 同文件 `handleKeyData`：
  //     _hardwareKeyboard.handleKeyEvent(event);        // ← 跑 addHandler
  //     _dispatchKeyMessage(<KeyEvent>[event], null);   // ★ **无条件也跑**
  // ⇒ `HardwareKeyboard.addHandler` 返回 true **不能中止派发**。
  // ```
  // 实测（`.probe/probe_tests/zz_v42_mechanism_test.dart`）：
  // ```text
  // VERIFY42O|hardware handler = 1 ／ Focus.onKeyEvent = 1 ／ 合计 = 2  ★★
  // VERIFY42P|early handler    = 1 ／ Focus.onKeyEvent = 0 ／ 合计 = 1  ← 修法
  // ```
  // ⇒ 旧实现：本 handler 切一次台 + 焦点树的 `_onKey` **又**切一次
  //   ⇒ **按一次 ↓ 跳过中间一个台**。
  //
  // # 判据：数 `cycleChannel` 的调用次数
  //
  // ```text
  // `cycleChannel` 里有 `debugPrint('[LIVE-KEY] ③ 逻辑层：cycleChannel(...)')`
  //   ⇒ 1 行 = 正常（切一个台）
  //     2 行 = ★★ bug 复发（切两个台）
  // ```
  // ★ 阳性对照：`③ 逻辑层` 必须**至少出现 1 次**
  //   （否则"没切两个"可能只是"一次都没切"——铁律 78）。
  group('task-42 ★★ 修 bug 回归：一次 ↓ 只切一个台', () {
    testWidgets('★★★ 按一次 ↓ ⇒ `cycleChannel` 只能被调用 **1** 次',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_themed(home: const LivePage()));
      await _settle(tester, 800);

      final p = await _arrowDown(tester);
      await tester.pump(const Duration(milliseconds: 200));
      _claim(tester);

      // ignore: avoid_print
      print('T42ONE|⓪ 入口=${p.entryCount} ② 门控全过=${p.passedGates} '
          '③ cycleChannel=${p.cycleCalls}');

      /*
       * ★★ 前置证据：**只有一次按键**（`add-remote-order` 建议的判据）
       *
       * ```text
       * 他的真机日志里"⓪ 入口"**只有 1 行** ⇒ 证明只有**一个 keydown**
       *   到达 Flutter ⇒ 排除了"发了两次键"这个干扰解释
       *   ⇒ 那"切两个台"就**只能**是"两条处理路径"造成的。
       * ★ 这条是**前置**（放在核心判据之前）：若入口=2，
       *   那 cycleCalls=2 的解释就完全不同了（输入层问题，不是双路径）。
       * ```
       */
      expect(p.entryCount, 1,
          reason: '★★ 前置：一次按键只能有**一个** keydown 到达 Flutter\n'
              '  （`⓪ 入口` 恰好 1 行）。\n'
              '  若 =2 ⇒ 是输入层投递了两次，**不是**双路径问题 ⇒\n'
              '  下面的 `cycleCalls` 判据解释会不同（必须排除这个干扰）。');

      // ★★ 阳性对照：键必须真的走到了"切台"那一步
      expect(p.reachedHandler, isTrue,
          reason: '★ 阳性对照：↓ 必须到达 handler');
      expect(p.passedGates, isTrue,
          reason: '★ 阳性对照：门控必须全过（否则测不到"切台次数"）');
      expect(p.cycleCalls, greaterThanOrEqualTo(1),
          reason: '★★ 阳性对照：`cycleChannel` 必须**至少被调用 1 次**。\n'
              '  若 =0 ⇒ 这次按键根本没走到切台逻辑 ⇒\n'
              '  "没有切两次"这个结论**不作数**（铁律 78：区分不了\n'
              '  "没违规"与"没测到"）。');

      // ★★★ 核心判据
      expect(p.cycleCalls, 1,
          reason: '★★★ 按一次 ↓ 只能切**一个**台（`cycleChannel` 恰好 1 次）。\n'
              '  =2 ⇒ **bug 复发**：`addHandler` 的返回值不中止派发 ⇒\n'
              '        early handler 切一次 + 焦点树的 `_onKey` 又切一次\n'
              '        ⇒ 用户按一下会**跳过中间一个台**。\n'
              '  修法：`FocusManager.instance.addEarlyKeyEventHandler`\n'
              '        （返回值**真的**会中止派发）。\n'
              '  ★ 实测：修前 =2，修后 =1（见 .probe/ 的变异记录）。');

      await _teardownTree(tester);
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ `_onKey`（焦点树那条路）也必须有门控 —— **静态契约**测试
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么这条只能做**静态**断言（我实测过，行为层测不到）
  //
  // ```text
  // `_onKey` 挂在 `Focus(onKeyEvent: _onKeyAny)` 上 ⇒ 要触发它，
  //   `Focus` 必须**在树上** ⇒ 只有 `build()` 的**正常分支**才建它。
  // 但正常分支要求 `_groups` 非空（有频道数据）⇒ 本环境 FFI 失败
  //   （`sourin_core.dll` 缺失）⇒ `_groups` 恒空 ⇒ 停在 `_EmptyState`
  //   ⇒ ★ **结构墙**（铁律 79）：`_onKey` 在 `flutter test` 里**行为层不可达**。
  // ```
  // ★ 我的红度证明实测确认了这一点：
  // ```text
  // R4b 删 `_onKey` 里的 `if (_isTypingInField()) return ignored;`
  //   -> ★★ GREEN —— 行为层判据**抓不住**（因为 `_onKey` 根本没跑）
  // ```
  //
  // # 但它在**生产里可达**，所以门控是**必需的**
  //
  // ```text
  // `focus_manager.dart` L2256-2273：
  //     case KeyEventResult.ignored: break;      // ★ 不中止 ⇒ 继续走焦点树
  //     ...
  //     if (handled) return true;
  //     // Walk the current focus from the leaf to the root ...   ← 焦点树
  // ⇒ early handler 因**门控挡住**而返回 `ignored` ⇒ 焦点树**照走**
  //   ⇒ `_onKey` 被调用 ⇒ 若它没有门控 ⇒ **cycleChannel 仍然执行**
  // ⇒ ★ 该挡住的时候没挡住（比"切两个台"更严重）
  // ```
  //
  // # ⇒ 用静态契约补上这个盲区（剥注释后断言）
  //
  // ★ 剥注释是**必须的**：本项目的经典坑是"断言匹配到注释文本 ⇒ 假通过"。
  group('task-42 ★★ `_onKey` 的门控（静态契约，行为层有结构墙）', () {
    test('★★★ `_onKey` 必须含三道门控（剥注释后）', () {
      final src = _codeOnly(_readLivePage());
      final body = _functionBody(src, 'KeyEventResult _onKey(');

      expect(body, isNotEmpty,
          reason: '★ 前置：必须能定位 `_onKey` 函数体。\n'
              '  若为空 ⇒ 下面的断言全是空的（假绿，铁律 78）。');

      // ★★ 存在性断言（先证明"找到了"）
      expect(body, contains('cycleChannel('),
          reason: '★ 前置：`_onKey` 必须真的会切台（否则它不需要门控）');

      // ★★★ 三道门控
      expect(body, contains('_isVisibleForKeys()'),
          reason: '★★ 门控①：`_onKey` 必须检查**本页可见**。\n'
              '  缺了它 ⇒ 保活页在后台时，焦点树那条路会切直播的台。');
      expect(body, contains('isCurrent'),
          reason: '★★ 门控②：`_onKey` 必须检查**本页是最上层路由**。\n'
              '  缺了它 ⇒ 全屏播放页/详情页压在上面时会被抢键。');
      expect(body, contains('_isTypingInField()'),
          reason: '★★★ 门控③：`_onKey` 必须检查**焦点是否在输入框**。\n'
              '  缺了它 ⇒ early handler 挡住（返回 ignored）后焦点树照走，\n'
              '  `_onKey` **没有门控** ⇒ 输入框里按 ↓ 会切台（门控被绕过）。\n'
              '  ★ 这正是红度证明里 R4b 变异**没被行为层抓住**的那一条\n'
              '    （`_onKey` 在 flutter test 里结构不可达）⇒ 用本静态契约兜住。');
    });
  });
}

/// LivePage + 一个 TextField（用来验门控③）
class _LiveWithField extends StatelessWidget {
  const _LiveWithField();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Column(
        children: [
          Expanded(child: LivePage()),
          TextField(),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  静态分析工具
// ═══════════════════════════════════════════════════════════════════════

String _readLivePage() {
  // ★ 相对路径按 `flutter test` 的工作目录（项目根）解析
  final f = File('lib/ui/live_page.dart');
  if (f.existsSync()) return f.readAsStringSync();
  // 兜底：从测试文件位置回推
  final alt = File('${Directory.current.path}/lib/ui/live_page.dart');
  return alt.readAsStringSync();
}

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释，支持嵌套）
///
/// ★ 必须剥 —— 本项目踩过多次"断言匹配到注释文本 ⇒ 假通过"。
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (c == '/' && n == '*') {
        depth++;
        i += 2;
        continue;
      }
      if (c == '*' && n == '/') {
        depth--;
        i += 2;
        continue;
      }
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      depth++;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取某个函数/方法的**函数体**（从签名到配平的 `}`）
///
/// ★ 用配平括号而不是正则 —— 正则遇到嵌套花括号会截错。
String _functionBody(String code, String signaturePrefix) {
  final start = code.indexOf(signaturePrefix);
  if (start < 0) return '';
  final braceOpen = code.indexOf('{', start);
  if (braceOpen < 0) return '';
  var depth = 0;
  for (var i = braceOpen; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(braceOpen, i + 1);
    }
  }
  return '';
}
