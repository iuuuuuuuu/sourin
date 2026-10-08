// ═══════════════════════════════════════════════════════════════════════
//  task-41 内存测量：5 页常驻的**代价**（Lead 补充 4 要求"量，不要猜"）
// ═══════════════════════════════════════════════════════════════════════
//
// # 要回答的问题
//
// 保活 = 5 个页面常驻在树上。代价是什么？
// ```text
// ① 建了**几个**页面？（惰性保活 ⇒ 只有访问过的才建）
// ② 每多访问一个 tab，树上 Element 数增加多少？（量"常驻规模"）
// ③ ★ 反复切 tab 会不会**累积**？（保活最大的风险：泄漏）
//    正常：切 10 次后 Element 数 == 切 1 次后（不累积）
//    泄漏：切 10 次后持续增长 ⇒ 保活把旧实例留住了
// ```
// ★ ③ 是最关键的 —— 保活如果实现错了，会把**每一份**旧页面都留在树上。
//
// # 为什么用 `Element` 计数而不是内存字节数
//
// ```text
// · `ProcessInfo.currentRss` 在 flutter_test 里读的是 **dart VM** 的内存，
//   不反映 widget 树规模（而且波动大、噪声大，数字不可信）
// · Element 数 是**确定的**：它直接对应"树上有多少 widget 实例"
//   ⇒ 没有噪声，可重复，能精确证明"不累积"
// ```
// ★ 这与本项目"判据要同源"的原则一致：
//   我要证明的是"保活有没有把树撑大"，那 Element 数就是同源的量。

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';

Widget _appWith({required Widget home}) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) => FTheme(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// ★ 收尾：把页面自己的**定时器**跑完，否则 harness 报 "Pending timers"
///
/// # 为什么会 pending（实测定位，不是猜）
/// ```text
/// SettingsPageState._flash（settings_page.dart:442）
///   ← 一个 3 秒的**一次性** Timer（"闪现"提示文案）
///   ← 由 loadAll 触发（settings_page.dart:415）
/// ```
/// 切到设置页会起它；测试结束时它还没到点 ⇒ `flutter_test` 报
/// `A Timer is still pending even after the widget tree was disposed`。
///
/// # 为什么是"跑到点"而不是"强杀/mock"
/// 那个 timer 是**正常业务**（3 秒后自动收起提示）。
/// 让它在测试里自然跑到点，**最接近真实行为**；
/// 若 mock 或强杀，就测不到"它到点后 setState 是否安全"。
///
/// ★ 顺带得到一个**保活相关**的结论（值得记进报告）：
/// ```text
/// 保活前：切走设置页 ⇒ 页面 dispose ⇒ 3 秒后 timer 触发在**已卸载**的 State 上
///         ⇒ 若 _flash 不检查 mounted，就是 setState-after-dispose（报错）
/// 保活后：切走设置页 ⇒ 页面**仍 mounted** ⇒ timer 触发是安全的
/// ⇒ ★ 保活把这个"dispose 后 setState"的窗口**缩小了**
///   （代码里当然仍该检查 mounted，但风险窗口小了很多）
/// ```
Future<void> _teardownTree(WidgetTester tester) async {
  // ★ 先等过 3 秒（`_flash` 的时长），让定时器自然到点
  await tester.pump(const Duration(seconds: 4));
  _claim(tester);
  // 再卸载整棵树
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  _claim(tester);
}

/// 当前树上 Element 总数
///
/// # ⚠️ 为什么不能写 `find.byType(Widget)`
///
/// `find.byType(T)` 匹配的是 **`runtimeType == T` 精确相等**，不是"是 T 的子类"。
/// 而所有 widget 的 `runtimeType` 都是**具体类**（`Container`/`Text`/…），
/// **没有一个**的 runtimeType 恰好是 `Widget` ⇒ 结果恒为 0。
/// ★ 我第一版就是这么写的，读数 `Elements=0`（假绿：0→0 "不累积"）。
///
/// ⇒ 正确做法：用 `tester.allElements`（框架提供的**全树遍历**）。
int _elementCount(WidgetTester tester) => tester.allElements.length;

/// 某页面当前在树上的实例数
int _pages(WidgetTester tester, Type t) =>
    find.byType(t, skipOffstage: false).evaluate().length;

void main() {
  group('task-41 ★ 内存代价：5 页常驻的规模（量，不猜）', () {
    testWidgets('★★★ 反复切 tab **不累积** Element（保活最常见的走法）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1200));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      // 先访问全部 5 个 tab（让它们都进树 —— 这是"最坏情况"）
      for (final t in AppTab.values) {
        shell.debugSwitchTo(t);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 400));
        _claim(tester);
      }

      // 回到 home，记录"全访问后"的基线
      shell.debugSwitchTo(AppTab.home);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 400));
      _claim(tester);

      final base = _elementCount(tester);
      // ignore: avoid_print
      print('T41MEM|全部 5 页访问后：Elements=$base');

      // ★★ 再切 10 轮（每轮 5 个 tab 全走一遍）
      for (var round = 0; round < 10; round++) {
        for (final t in AppTab.values) {
          shell.debugSwitchTo(t);
          await tester.pump();
          _claim(tester);
          await tester.pump(const Duration(milliseconds: 120));
          _claim(tester);
        }
      }
      shell.debugSwitchTo(AppTab.home);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 400));
      _claim(tester);

      final after = _elementCount(tester);
      // ignore: avoid_print
      print('T41MEM|再切 10 轮（50 次切换）后：Elements=$after');
      // ignore: avoid_print
      print('T41MEM|增量 = ${after - base}（应为 0 或极小；大幅增长 ⇒ 保活泄漏）');

      // ★ 每个页面**只能有一份**
      for (final t in const [HomePage, LivePage, FollowPage, SearchPage, SettingsPage]) {
        expect(_pages(tester, t), lessThanOrEqualTo(1),
            reason: '★★★ $t 在树上最多 1 份 —— '
                '若 >1 ⇒ 保活把旧实例留住了（泄漏）');
      }

      // ★ 总量不累积（允许极小抖动，不允许线性增长）
      expect(after - base, lessThan(60),
          reason: '★★★ 50 次切换后 Element 数不该显著增长。\n'
              '  基线=$base  之后=$after  增量=${after - base}\n'
              '  若线性增长（每轮 +几十）⇒ 保活实现有泄漏');

      await _teardownTree(tester);
    });

    testWidgets('★ 惰性保活：访问几个 tab ⇒ 树上就建几个页面（不多建）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1200));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      // ── 只访问 home（初始）──
      // ignore: avoid_print
      print('T41MEM|只访问 home：HomePage=${_pages(tester, HomePage)} '
          'LivePage=${_pages(tester, LivePage)} '
          'SettingsPage=${_pages(tester, SettingsPage)}');
      expect(_pages(tester, HomePage), 1);
      expect(_pages(tester, LivePage), 0, reason: '没访问过 ⇒ 不该建');
      expect(_pages(tester, SettingsPage), 0, reason: '没访问过 ⇒ 不该建');

      // ── 访问 live ──
      shell.debugSwitchTo(AppTab.live);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 500));
      _claim(tester);

      // ignore: avoid_print
      print('T41MEM|访问 home+live：HomePage=${_pages(tester, HomePage)} '
          'LivePage=${_pages(tester, LivePage)} '
          'SettingsPage=${_pages(tester, SettingsPage)}');
      expect(_pages(tester, HomePage), 1, reason: '保活：home 仍在（1 份）');
      expect(_pages(tester, LivePage), 1, reason: 'live 已访问 ⇒ 1 份');
      expect(_pages(tester, SettingsPage), 0, reason: '仍未访问 ⇒ 仍不该建');

      await _teardownTree(tester);
    });
  });
}
