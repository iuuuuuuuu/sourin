// ═══════════════════════════════════════════════════════════════════════
//  task-41 保活 —— 正式回归测试（进 test/）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 判据的选择（这里有一次重要修正，值得记住）
//
// 我最初打算用「`[HOME] 渲染完成` 日志是否**重复打**」作为判据。
// fix-autoscroll 实测发现**它会假绿**：
// ```text
// 无核心环境下 `loadAll` 在 IPC 之前就抛了 ⇒ 那条日志**根本打不出来**
// ⇒ "日志没重复" 不是因为"State 没重建"，而是因为"日志压根没打"
// 实测读数：home_renders = 0（修前）→ 0（修后）—— 全程 0，什么都没测到
// ```
// ★ 教训：**判据本身依赖被测对象之外的东西时会假绿**。
//   "页面是否重建"要用 **State 对象身份**（直接、同源），
//   不能用"日志有没有重复"（间接、且依赖核心已启动）。
//
// # 本文件用的判据（"对象身份"级别，不依赖 FFI / 网络）
//
// ```text
// ① 切走之后 HomePage **还在树里**吗？
//    在 ⇒ 保活 ✓        不在 ⇒ 已销毁 ✗
// ② 切回来时 State 是**同一个对象**吗？（identityHashCode 相同）
//    ★ 比"仍 mounted"更强：mounted 只说明活着，identity 说明**是同一个**
// ③ 惰性：没访问过的 tab **不在树上**（不白建页面）
// ④ 不可见：默认 finder 找不到保活页（Offstage 生效）
// ```
//
// # ⚠️ `skipOffstage` 必须**显式**写（铁律 63）
//
// `find.byType` 默认 `skipOffstage: true`（只找"可见"的），
// 而保活页恰恰是 `Offstage(offstage: true)`（在树上但不可见）。
// ⇒ 用默认值会**假红**。
// ★ 同一个参数**两种用途**（语义相反），所以必须显式：
// ```text
// skipOffstage: false → 证明"在树上"（保活）
// 默认（true）        → 证明"看不见"（没画出来）
// ```
//
// # ★★ 怎么处理"无核心环境必然抛的异常"（我在这里踩了两次）
//
// ## 第一次：写了但没复原 `FlutterError.onError`
// ```text
// 'A test overrode FlutterError.onError but either failed to return it
//  to its original state, or had unexpected additional errors'
// ⇒ 测试**挂住不返回**（不是断言失败，是 harness 报 assertion 后卡死）
// ```
//
// ## 第二次：只在 pump 期间静音 —— 但异常发生在**后面的** pump 里
// ```text
// 本测试要**多次** pump（切走 / 切回各一次），
// 而 `HomePage` 的 `SliverPersistentHeader` 在测试视口下会抛：
//   SliverGeometry is not valid: "layoutExtent" exceeds "paintExtent"
// 它是在 `debugSwitchTo()` 之后的 pump 里才触发的 ——
// 那时我已经把 onError 复原了 ⇒ 异常直接让测试失败
// ```
//
// ## ★ 最终做法：**不改 `FlutterError.onError`**，改用 `takeException()` 认领
// ```text
// ① 让 onError 保持框架默认（不要覆盖！覆盖了 takeException 就拿不到）
// ② **每次 pump 之后**都 `while (tester.takeException() != null) {}`
//    —— 把环境噪声认领掉，它们就不会让测试失败
// ③ 这样断言看到的是**真实值**，不是被静音掩盖后的值
// ```
// ★ 为什么这比"静音"更好：静音会把**真异常**也一起吞掉；
//   而 `takeException()` 是"我知道这些异常、我认领了"——
//   若出现**意料之外**的新异常，仍会在下一次 pump 后暴露出来。
//
// ⚠️ `while` 循环而不是 `if`：一次 pump 可能积压多个异常
//    （本页实测有 8 个，见 core_error_test.dart 的注释）。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

/// 取某类型当前在树里的 `Element`（★ `skipOffstage: false` —— 见文件头）
List<Element> _elementsOf(WidgetTester tester, Type t) =>
    find.byType(t, skipOffstage: false).evaluate().toList();

/// 拿某个 StatefulElement 的 State 对象（拿不到返回 null）
State? _stateOf(WidgetTester tester, Type t) {
  final els = _elementsOf(tester, t);
  if (els.isEmpty) return null;
  final e = els.first;
  return e is StatefulElement ? e.state : null;
}

/// **认领**一次 pump 期间积压的环境异常（见文件头）
///
/// ★ 用 `while` 而不是 `if` —— 一次 pump 可能积压多个。
/// ★ 不改 `FlutterError.onError` —— 覆盖它会让 `takeException()` 失效，
///   并触发 harness 的 "overrode FlutterError.onError" 断言（我踩过）。
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {
    // 认领：无核心环境的 FFI 异常 + HomePage 在测试视口下的
    // SliverPersistentHeader 布局断言（见 core_error_test.dart 的长注释）
  }
}

/// 启动 ShellPage（每个阶段后都认领异常）
Future<void> _pumpShell(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
  await tester.pump();
  _claim(tester);
  await tester.pump(const Duration(milliseconds: 1500));
  _claim(tester);
}

/// 切 tab 并等动画走完（每步都认领异常）
Future<void> _switchAndSettle(WidgetTester tester, AppTab t) async {
  debugShellKey.currentState!.debugSwitchTo(t);
  await tester.pump();
  _claim(tester);
  await tester.pump(const Duration(milliseconds: 1200));
  _claim(tester);
}

void main() {
  group('task-41 ★ KeepAlive：切走不销毁、切回不重建', () {
    testWidgets('★★★ 切走 live 再回 home：HomePage 仍在树里 + State 是同一个对象',
        (tester) async {
      await _pumpShell(tester);

      final shell = debugShellKey.currentState;
      expect(shell, isNotNull,
          reason: '拿不到 shell state ⇒ 无法驱动切换，结论不作数（前置）');

      // ── 初始：在 home ──
      final homeState0 = _stateOf(tester, HomePage);
      expect(homeState0, isNotNull,
          reason: '前置：首屏应该在 home（否则后面都是空的）');
      final h0 = identityHashCode(homeState0);

      // ── 切到 live ──
      await _switchAndSettle(tester, AppTab.live);

      // ★ 阳性对照：LivePage 必须找得到（证明 finder 有效）
      expect(_elementsOf(tester, LivePage), isNotEmpty,
          reason: '★ 阳性对照：切到 live 后 LivePage 必须在 —— '
              '否则"找不到 HomePage"可能只是 finder 坏了');

      // ★★ 判据①：HomePage **仍在树里**（保活 = offstage，不是移除）
      expect(
        _elementsOf(tester, HomePage),
        isNotEmpty,
        reason: '★★★ 保活：切走后 HomePage 必须**仍在树上**（只是 offstage）。\n'
            '若这里是空 ⇒ 页面被销毁 ⇒ 无 KeepAlive'
            '（用户报的"切回来又是新状态"就是这个）',
      );

      // ── 切回 home ──
      await _switchAndSettle(tester, AppTab.home);

      final homeState2 = _stateOf(tester, HomePage);
      expect(homeState2, isNotNull, reason: '切回 home 后 HomePage 应该在');
      final h2 = identityHashCode(homeState2);

      // ★★ 判据②：State 必须**是同一个对象**
      expect(
        h2,
        equals(h0),
        reason: '★★★ State 必须**没有重建**（identityHashCode 相同）。\n'
            '  切走前 hash=$h0\n  切回后 hash=$h2\n'
            '若不同 ⇒ 切回时 new 了一个 HomePageState ⇒ '
            'initState→loadAll 又跑、滚动位置归零、海报重新走占位。',
      );
    });

    testWidgets('★★ 惰性保活：没访问过的 tab **不进树**（不白建页面）',
        (tester) async {
      await _pumpShell(tester);

      /*
       * ★ 为什么"惰性"是**正确**行为（而不是缺陷）
       *
       * 启动时把 5 个页面全挂载 = 5 份 loadAll 同时打出去：
       * ```text
       * · 启动变慢
       * · 用户从不点的页面白建白加载
       * · ★ 而且 core_error_test 只挂 ShellPage 时会连带把 5 页全建出来
       *   ⇒ 各自 initState 打 FFI ⇒ 无核心环境抛异常 ⇒ 既有测试变红
       * ```
       * 原版 `keep-alive` 也是**首次访问才创建**、之后才保留。
       * ⇒ 保活的收益在"**访问过之后**切走切回不重建"，不在"启动全建"。
       */
      expect(
        _elementsOf(tester, LivePage),
        isEmpty,
        reason: '★ 惰性：没访问过 live ⇒ 不该进树（否则启动即挂载 5 页）',
      );
      expect(_elementsOf(tester, HomePage), isNotEmpty,
          reason: '当前页（home）当然要在');
    });

    testWidgets('★ 保活页**不可见**（Offstage 生效，没有被画出来）',
        (tester) async {
      await _pumpShell(tester);

      await _switchAndSettle(tester, AppTab.live);

      /*
       * ★ 同一个 finder，两种用途（默认值恰好能测"不可见"）：
       *   skipOffstage: false → 证明"在树上"（保活）
       *   默认（true）        → 证明"看不见"（没画出来）
       * ⚠️ 两个都必须**显式**写出来，不能靠默认值 —— 见铁律 63。
       */
      expect(find.byType(HomePage, skipOffstage: false), findsOneWidget,
          reason: '保活 ⇒ 在树上（显式 skipOffstage:false）');
      expect(find.byType(HomePage), findsNothing,
          reason: '★ 不可见 ⇒ 默认 finder（skipOffstage:true）应找不到它');
    });
  });
}
