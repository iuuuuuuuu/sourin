// ═══════════════════════════════════════════════════════════════════════
//  task-41 可见性单一真相 —— **不变量**回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 来源：独立验证发现的缺口（2026-09-25）
//
// 独立验证者（`fix-autoscroll`）做变异测试时发现：
// ```text
// 把 `_syncVisibility()` 调用删掉（= 可见性不投影）
//   ⇒ `_liveVisible` 恒为 false（初值）
//   ⇒ LivePage(visible:) **永远**收到 false
//   ⇒ 后果：直播页**播放中**切走 → 收不到"不可见"通知 → **播放器不停**
//   ⇒ ★ 但当时 5 个测试文件**全绿** ⇒ **没有任何测试守这个不变量**
// ```
// ★ 并且用独立探针**抓到了它**（变异后 `violations=3`）⇒
//   **可观测**、**不是等价变异体** ⇒ 是真缺口（铁律 99 的鉴别法）。
//
// # 本文件守的不变量
//
// ```text
// _liveVisible.value  ==  (_activeTab.value == AppTab.live)     恒成立
// ```
//
// # ★★ 为什么断"不变量"而不是断"某个具体值"
//
// ```text
// ✗ 弱写法: `expect(liveVisible, false)` 在某一步
//           ⇒ 只验了一个点，别处分叉抓不到
// ✓ 强写法: 在**每一次**切换后都验**关系**（不变量）
//           ⇒ 任何一处投影失配都会红
// ```
// ★ 且要覆盖**重复切同一个 tab** —— 那条路径会走
//   `_switchTo` 开头的 `if (t == _tab) return;` **早退**，
//   是"投影可能漏更新"的最可疑位置。
//
// # 两侧怎么读（**公开接口**，不碰私有字段）
//
// ```text
// 权威值 `_activeTab`: 经 `ShellScope`（InheritedNotifier）下发
//                      ⇒ 用 `ShellScope.activeTabOf(context)` 读
// 投影值 `_liveVisible`: 经 `LivePage(visible:)` 注入
//                      ⇒ 用 `LivePage.visible?.value` 读
// ```
// ★ 从**公开接口**读两侧才是"两套真相"的真实暴露面 ——
//   私有字段拿不到，而子页面也只能看到这两个接口。
//
// # ⚠️ 收尾（我第一版漏了 ⇒ 探针红，而数据其实是对的）
//
// ```text
// ① 等过 3 秒 —— `SettingsPageState._flash` 有个 3 秒一次性 Timer
//    不等它到点 ⇒ harness 报 "A Timer is still pending"
// ② 再卸载整棵树 + 认领异常
// ③ 否则 `HomePage` 的 `SliverPersistentHeader` 在测试视口下抛的
//    「layoutExtent exceeds paintExtent」会在 teardown 变成未处理异常
// ```
// ★ 这套收尾是从 `keepalive_memory_test.dart` 学的（他们的测试都有）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
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

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {
    // 认领环境噪声（无核心的 FFI 异常 + SliverPersistentHeader 布局断言）
  }
}

void main() {
  group('task-41 ★ 可见性单一真相（不变量）', () {
    testWidgets('★★★ `_liveVisible` 必须恒等于 `(_activeTab == live)`',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState;
      expect(shell, isNotNull,
          reason: '拿不到 shell state ⇒ 无法驱动切换，结论不作数（前置）');

      /// 投影值：从 `LivePage(visible:)` 读
      bool? projection() {
        final els = find.byType(LivePage, skipOffstage: false).evaluate();
        if (els.isEmpty) return null;
        final w = (els.first as StatefulElement).widget as LivePage;
        return w.visible?.value;
      }

      /// 权威值：从 `ShellScope` 读（子页面视角）
      AppTab? authoritative() {
        final els = find.byType(LivePage, skipOffstage: false).evaluate();
        if (els.isEmpty) return null;
        return ShellScope.activeTabOf(els.first as Element)?.value;
      }

      var checks = 0;

      /// 在**每一次**切换后验不变量
      void checkInvariant(String label) {
        final proj = projection();
        final auth = authoritative();
        /*
         * 前置：live 页还没被访问过时拿不到 LivePage
         * ⇒ 那时**无法**验不变量（不是"不变量成立"）—— 显式跳过并记录。
         * ★ 这与"不变量成立"是**两回事**，不能混（铁律 78）。
         */
        if (proj == null || auth == null) return;
        checks++;
        final want = auth == AppTab.live;
        expect(proj, want,
            reason: '★★★ 可见性不变量被破坏 [$label]\n'
                '  权威 `_activeTab` = ${auth.name}\n'
                '  投影 `_liveVisible` = $proj\n'
                '  期望 = $want（应等于 `_activeTab == live`）\n'
                '  ⇒ 两套真相分叉 ⇒ 直播页会收到错的可见性 ⇒\n'
                '     播放中切走时**收不到通知** ⇒ 播放器不停。\n'
                '  ★ 判据来源：变异测试把 `_syncVisibility()` 删掉时，\n'
                '     这里会出现 violations=3（独立验证实测）。');
      }

      // ── 切遍所有 5 个 tab ──
      for (final t in AppTab.values) {
        shell!.debugSwitchTo(t);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 600));
        _claim(tester);
        checkInvariant('switch->${t.name}');
      }

      // ── ★★ 重复切同一个 tab（走 `if (t == _tab) return;` 早退路径）──
      for (final t in [AppTab.live, AppTab.live, AppTab.home, AppTab.home]) {
        shell!.debugSwitchTo(t);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 300));
        _claim(tester);
        checkInvariant('repeat->${t.name}');
      }

      // ignore: avoid_print
      print('T41VIS|不变量检查次数=$checks（应 >=8）');

      /*
       * ★★ 存在性断言（铁律 78）：
       * "不变量成立"与"根本没测到"必须能区分。
       * 若 checks == 0 ⇒ 上面所有 expect **一次都没跑** ⇒ 那是假绿。
       */
      expect(checks, greaterThanOrEqualTo(8),
          reason: '★★ 必须**真的验过**不变量（不能一次都没跑就"通过"）。\n'
              '  实测应 >=8：5 次切换 + 4 次重复切换里\n'
              '  从 `switch->live` 起 LivePage 就存在了。\n'
              '  若 =0 ⇒ 上面的断言全是空的（假绿）。');

      // ★ 收尾（等 3 秒 Timer + 卸载 + 认领）—— 见文件头"收尾"说明
      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });

    testWidgets('★★ ShellScope 必须**真的覆盖** LivePage（否则不变量无从查）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;
      shell.debugSwitchTo(AppTab.live);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      final els = find.byType(LivePage, skipOffstage: false).evaluate();
      expect(els, isNotEmpty, reason: '前置：live 页应在树上');

      final el = els.first as Element;
      final viaScope = ShellScope.activeTabOf(el);

      /*
       * ★ 为什么这条重要（文档里承诺的契约）：
       * `ShellScope` 的文档说"5 个 tab 页**拿得到**，
       * 参数化页面（detail/browse）与播放器**刻意拿不到**"。
       * ⇒ 若 LivePage **拿不到** ⇒ 那个"唯一真相"对它不可见
       *   ⇒ 它只能靠 `visible:` 投影 ⇒ 投影错了**没人纠**。
       */
      expect(viaScope, isNotNull,
          reason: '★★ LivePage 必须能通过 `ShellScope.activeTabOf` '
              '拿到权威值 —— 否则"唯一真相"对它不可见，'
              '只能依赖 bool 投影，投影失配时无从发现');
      expect(viaScope!.value, AppTab.live,
          reason: '★ 当前在 live ⇒ 权威值应为 live');

      /*
       * ★ 收尾：等过 `_flash` 的 3 秒 Timer，再卸载整棵树。
       *
       * ⚠️ 我第一版**只在第 1 个测试里加了收尾，忘了这里** ——
       *    结果第 2 个测试报：
       * ```text
       * A Timer is still pending even after the widget tree was disposed.
       * Timer (duration: 0:00:03.000000, periodic: false)
       * ```
       * ★ 教训：**收尾逻辑要么抽成公共函数，要么每个测试都写** ——
       *   写在一个里就以为"已经处理了"是最容易漏的形态。
       */
      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });
  });
}
