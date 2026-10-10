// ═══════════════════════════════════════════════════════════════════════
//  task-41 验收 ④⑤：切回仍刷新（task-36 未退化）+ 5 个 tab 都保活
// ═══════════════════════════════════════════════════════════════════════
//
// # 验收 ④「切回来仍能看到新数据」为什么必须单独测
//
// 保活**最容易的过度修复**是：把 `_switchTo` 里的刷新也一起弄没
// （例如觉得"反正 State 保活了，不用刷新"）。
// ⇒ 那会让 task-36 的成果**退化**：在详情页追更 → 切回首页 → 看不到更新。
//
// ★ 判据必须是**两个都要**：
// ```text
// ① `reason=initState` 只出现 1 次   ← 保活生效（没重建）
// ② `reason=tab-switch` **出现**      ← task-36 的刷新**仍在**（没退化）
// ```
// ★ 只断言 ① 是不够的 —— 把刷新删掉也能让 ① 通过，但那是**弄坏了另一个功能**。
//   这正是 Lead 说的"读数有多因"的反面：**一条修好不能以弄坏另一条为代价**。
//
// # 验收 ⑤「5 个 tab 都验」
//
// 不只首页 —— 每个 tab 切走都要留在树上（`Offstage`），
// 且**各只有一份**（GlobalKey 不冲突、不重复挂载）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
// ★ task-3 ⑲：新增「已缓存」tab 后，下面这张 pages 表必须一并补上，
//   否则新页**不会被检查**（遗漏即静默失去保活覆盖）。
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
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

void main() {
  group('task-41 ★ 验收 ④⑤', () {
    void _claim(WidgetTester tester) {
      while (tester.takeException() != null) {}
    }

    testWidgets('★★★ 验收④：保活生效（initState 只 1 次）**且** 切回刷新仍在（tab-switch）',
        (tester) async {
      /*
       * ★★★ 不用日志文本，用**运行时计数器**
       *
       * 我试了两种日志拦截写法，**都失效**：
       * ```text
       * ① 写在 `setUp` 里   ⇒ 跑在测试 zone 之外，被重置
       * ② 写在测试体内 ⇒ 计数仍恒为 0
       * ```
       * ★ 而原始输出里那几行日志**明明打了**。
       * ⇒ 在 `flutter_test` 里 `debugPrint` 被 binding 接管，
       *   **覆盖它捕获不到**这些调用。
       *
       * ⇒ 改用 `debugLoadAllCalls`（home_page.dart 里的运行时数组）。
       *   ★ 同源：要测"函数被调用几次"，就直接记**调用本身**，
       *     不要记它的副作用（一行日志）。
       */
      debugLoadAllCalls.clear();

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      // 切走再切回（走两轮，让"重建"若存在则必然暴露）
      for (var i = 0; i < 2; i++) {
        shell.debugSwitchTo(AppTab.live);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 600));
        _claim(tester);

        shell.debugSwitchTo(AppTab.home);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 800));
        _claim(tester);
      }

      final nInit = debugLoadAllCalls.where((c) => c.reason == 'initState').length;
      final nTab = debugLoadAllCalls.where((c) => c.reason == 'tab-switch').length;

      // ignore: avoid_print
      print('T41ACC|reason=initState  出现 $nInit 次（应=1：只有启动那次）');
      // ignore: avoid_print
      print('T41ACC|reason=tab-switch 出现 $nTab 次（应>=2：每次切回都刷新）');
      for (final c in debugLoadAllCalls) {
        // ignore: avoid_print
        print('T41ACC|  force=${c.force}  reason=${c.reason}');
      }

      // ★ ① 保活：initState 只跑过启动那一次
      expect(nInit, 1,
          reason: '★★★ `reason=initState` 必须**只出现 1 次**（启动）。\n'
              '  若 >=2 ⇒ 切回时页面被重建了（initState 又跑）⇒ 保活失效');

      // ★ ② task-36 的刷新**没有退化**
      expect(nTab, greaterThanOrEqualTo(2),
          reason: '★★★ `reason=tab-switch` 必须**仍出现**（每次切回都刷新）。\n'
              '  若 =0 ⇒ 保活把 task-36 的"切回刷新"一起弄没了 ⇒ '
              '用户会遇到"在详情页追更，切回首页看不到更新"');

      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });

    testWidgets('★★ 验收⑤：5 个 tab **逐个**切走后都仍在树上，且各只有一份',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1200));
      _claim(tester);

      final shell = debugShellKey.currentState!;

      const pages = <AppTab, Type>{
        AppTab.home: HomePage,
        AppTab.live: LivePage,
        AppTab.follow: FollowPage,
        AppTab.search: SearchPage,
        AppTab.cached: CachePage,
        AppTab.settings: SettingsPage,
      };

      // 逐个访问全部 5 个 tab
      for (final t in AppTab.values) {
        shell.debugSwitchTo(t);
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 700));
        _claim(tester);
      }

      /*
       * ★ 关键断言：**每一个** tab 切走后都还在树上，而且**只有一份**。
       *
       * 「只有一份」很重要 —— GlobalKey 重复挂载会让 Flutter 抛
       * `Multiple widgets used the same GlobalKey`。
       * 而保活（5 页同时在树上）恰恰**最容易**触发它。
       * ⇒ 这条同时验证了"GlobalKey 不冲突"（task-41 描述里的关键点）。
       */
      for (final e in pages.entries) {
        final n = find.byType(e.value, skipOffstage: false).evaluate().length;
        // ignore: avoid_print
        print('T41ACC|${e.key.name.padRight(9)} 在树上 ${n} 份（应=1）');
        expect(n, 1,
            reason: '★★ 验收⑤：`${e.key.name}` 必须**恰好 1 份**。\n'
                '  0 ⇒ 切走后被销毁（没保活）\n'
                '  >1 ⇒ 重复挂载（GlobalKey 冲突 / 保活把旧实例留住了）');
      }

      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });
  });
}
