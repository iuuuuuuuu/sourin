// ═══════════════════════════════════════════════════════════════════════
//  ⑤ 片头片尾二级页：**平铺列表 + 顶部固定搜索框**（task-44）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
//
// > 片头片尾**抽到第二级页了,可以平铺了**,然后加一个 **搜索功能**,
// > 这个搜索要**固定在上面**,结果**在下面滚动**
//
// # ★★★ 先澄清"可以平铺了"≠"搬回一级页"（我核实过）
//
// `lib/ui/settings/skip_page.dart` L27-31 记着用户**上次**的相反要求：
// ```text
// // # ★★★ 2026-09-25 用户要求：**改成「按钮 → 弹窗」**
// // 用户原话：
// // > 片头片尾，我说了 **做成按钮，点击后弹窗显示配置的影片的片头片尾**，
// // > 而不是**平铺在上面**
// ```
// 而 L33-42 给了量化的理由（`N=20 → 1200px` 把下面区块全推走）——
// 那个理由针对的是**一级页**（要跟别的区块抢高度）。
//
// ⇒ 所以用户这次说的是：**二级页是独立整页，现在有条件平铺了**。
//   一级页入口**不动**（`settings_page.dart` L1803-1807 保持原样）。
//
// # 本文件验什么
//
// ```text
// ① 【平铺】列表直接铺在二级页里（不再是一层"按钮 → 弹窗"）
// ② 【搜索】能按作品标题过滤（含 provider 兜底）
// ③ ★★★ 【固定】滚动结果列表时，搜索框**始终在视口内**
// ④ 【零影响】另外 5 个二级页的行为**逐字不变**
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/settings/skip_page.dart';
import 'package:sourin_spike/ui/widgets/settings_sub_page.dart';

/// 造 N 条片头片尾记录（标题带序号，便于按标题断言）
List<SkipMarker> markers(int n) => [
      for (var i = 1; i <= n; i++)
        SkipMarker(
          key: 'k$i',
          provider: i.isEven ? 'cycani' : 'tyyszy',
          nativeId: 'id$i',
          title: '测试作品$i',
          introStart: 0,
          introEnd: 90,
          outroStart: 1200,
          outroEnd: 1290,
          updatedAt: 1700000000 + i,
        ),
    ];

/// 挂载**真实**二级页（走真实 `SettingsSubPage` 外壳，与生产同一条路径）
///
/// ⚠️ `SettingsSubPage` 自己就是一个 `ListView`（含返回按钮/标题/副标题），
///    所以本页必须在真实外壳里测 —— 裸 `pump` 一个 Column 测不出
///    "搜索框固定"这个约束（那正是要靠外壳结构来保证的）。
Widget host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 搜索框的 finder（`TextField`）
final searchField = find.byType(TextField);

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 【平铺】列表直接在二级页里（不再套一层弹窗）
  // ═══════════════════════════════════════════════════════════════════
  group('① 平铺：列表直接在二级页里', () {
    testWidgets('★★★ 二级页里**直接**看到作品行（不需要再点开弹窗）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      /*
       * ★ 判据：把 `_skipMarkers` 灌进去后，**屏幕上直接**能看到作品标题。
       *
       * 改前：二级页只有一个「查看 / 管理片头片尾(N)」按钮，
       *       作品标题**必须点开弹窗**才看得到 ⇒ 本条必须**失败**（红度）。
       * 改后：标题直接铺在页面里 ⇒ 通过。
       *
       * ⚠️ 需要注入数据。真实页面自己调 `SourinApi.listSkipMarkers()`
       *    （FFI，测试里拿不到）⇒ 用一个可注入的测试入口。
       */
      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(3),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('测试作品1'), findsOneWidget,
          reason: '★★★ 用户要「可以平铺了」—— 作品行必须**直接**铺在'
              '二级页里。若这一条失败，说明列表还藏在弹窗后面，'
              '用户得再点一次才能看到');
      expect(find.text('测试作品3'), findsOneWidget,
          reason: '★ 平铺应当把所有行都铺出来（不只是第一条）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 【搜索】按标题过滤
  // ═══════════════════════════════════════════════════════════════════
  group('② 搜索：按作品标题过滤', () {
    testWidgets('★★★ 输入关键词 → 只留下匹配的行', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(5),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(searchField, findsOneWidget, reason: '★ 必须有搜索框');

      await t.enterText(searchField, '作品2');
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('测试作品2'), findsOneWidget,
          reason: '★ 匹配的那条必须留着');
      expect(find.text('测试作品1'), findsNothing,
          reason: '★ 不匹配的必须被过滤掉');
    });

    testWidgets('★★★ 阳性对照：无搜索词时**所有**行都在（证明过滤真的在生效）',
        (t) async {
      /*
       * ★★ 铁律②：如果没有这条对照，"搜完只剩 1 条"有两种解释：
       * ```text
       * ① 过滤生效了（期望）        ← 但需要证明"没搜时确实有 5 条"
       * ② 页面本来就只渲染 1 条     ← 仪器瞎了
       * ```
       */
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(5),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      for (var i = 1; i <= 5; i++) {
        expect(find.text('测试作品$i'), findsOneWidget,
            reason: '★★ 阳性对照：没搜索时「测试作品$i」必须在 —— '
                '这一条不过，上面"过滤后只剩 1 条"就无法解释');
      }
    });

    testWidgets('★★ 搜 provider 也能命中（用户可能记得"是 cycani 设的"）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(4),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      await t.enterText(searchField, 'cycani');
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      // markers() 里 i 为偶数 → cycani → 作品2 / 作品4
      expect(find.text('测试作品2'), findsOneWidget);
      expect(find.text('测试作品4'), findsOneWidget);
      expect(find.text('测试作品1'), findsNothing,
          reason: '★ 奇数条是 tyyszy，不该被 cycani 命中');
    });

    testWidgets('★★ 搜不到 → 明确的空态（不是一片空白）', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(3),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      await t.enterText(searchField, '这个绝对搜不到zzz');
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      // 空态文案里应当提到"没有匹配"/"搜不到"，而不是无声空白
      final hasHint = find.textContaining('没有').evaluate().isNotEmpty ||
          find.textContaining('没找到').evaluate().isNotEmpty ||
          find.textContaining('无匹配').evaluate().isNotEmpty;
      expect(hasHint, isTrue,
          reason: '★ 搜不到时必须给明确空态 —— 一片空白用户会以为页面坏了');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ ★★★ 【固定】滚动结果时搜索框始终在视口内
  // ═══════════════════════════════════════════════════════════════════
  group('③ ★★★ 搜索框固定在上面，结果在下面滚动', () {
    testWidgets('★★★ 滚动结果列表后，搜索框**仍在视口内**', (t) async {
      const win = Size(1280, 800);
      await t.binding.setSurfaceSize(win);
      addTearDown(() => t.binding.setSurfaceSize(null));

      /*
       * ★ 造**足够多**的行，让结果区一定可以滚动。
       *
       * ⚠️ 铁律 149：候选集必须断言非空 —— 若行数太少、压根不能滚，
       *    那"滚动后搜索框还在"就是**空断言**（伪装成"合规"）。
       *    所以下面先断言"滚动真的发生了"。
       */
      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(40),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(searchField, findsOneWidget);
      final before = t.getRect(searchField);
      expect(before.top, greaterThanOrEqualTo(0),
          reason: '★ 初始时搜索框必须在视口内');
      expect(before.bottom, lessThanOrEqualTo(win.height),
          reason: '★ 初始时搜索框必须完整在视口内');

      /*
       * ── 滚到底 ──
       *
       * ★ 用 `drag` 而不是直接设 `controller.jumpTo` —— 前者是**真实
       *   用户操作**，能真正走过手势链路（本项目铁律：验真实路径）。
       */
      final scrollable = find.byType(Scrollable);
      expect(scrollable, findsWidgets, reason: '★ 必须有一个可滚动的结果区');

      // 找**结果区**那个 scrollable（不是外层页面）
      final target = scrollable.last;

      /*
       * ★★ 铁律 149：在**这一个**测试里就证明"滚动真的发生了"。
       *
       * 否则"滚动后搜索框还在原位"可能是**空断言**：
       * ```text
       * ① 搜索框真的固定了（期望）
       * ② 压根没滚动 ⇒ 没动是必然的（假绿）
       * ```
       * 所以下面必须读到 `pixels` 的**前后差值 != 0**。
       */
      final posBefore = t.state<ScrollableState>(target).position.pixels;
      expect(t.state<ScrollableState>(target).position.maxScrollExtent,
          greaterThan(0),
          reason: '★ 40 行必须产生可滚动内容（否则"搜完没动"是废话）');

      await t.drag(target, const Offset(0, -2000));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      final posAfter = t.state<ScrollableState>(target).position.pixels;
      expect(posAfter, isNot(posBefore),
          reason: '★★★ 滚动位置必须**真的变了**（$posBefore → $posAfter）—— '
              '否则下面"搜索框没动"就是空断言');

      final after = t.getRect(searchField);
      // ignore: avoid_print
      print('[FIXED] 滚动前搜索框 = $before');
      // ignore: avoid_print
      print('[FIXED] 滚动后搜索框 = $after');
      // ignore: avoid_print
      print('[FIXED] 滚动位置 $posBefore → $posAfter');

      expect(
        after.bottom,
        lessThanOrEqualTo(win.height),
        reason: '★★★ 用户原话「这个搜索要**固定在上面**，结果在下面滚动」—— '
            '滚动结果后搜索框**不能**被卷走。'
            '若这里失败，说明搜索框被放进了滚动区里（会跟着滚出去）',
      );
      expect(
        after.top,
        greaterThanOrEqualTo(0),
        reason: '★★★ 搜索框不能滚到视口上方之外',
      );
      // ★ 而且它应当**基本没动**（固定 = 不随滚动位移）
      expect(
        (after.top - before.top).abs(),
        lessThan(1.0),
        reason: '★★★ "固定"意味着搜索框的 y 坐标**不随滚动变化**。'
            '实测位移 ${(after.top - before.top).abs().toStringAsFixed(1)}px',
      );
    });

    testWidgets('★★★ 铁律149：必须先证明"结果区真的能滚"（否则是空断言）',
        (t) async {
      const win = Size(1280, 800);
      await t.binding.setSurfaceSize(win);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(SkipMarkersSettingsPage(
        initialMarkersForTest: markers(40),
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      /*
       * ★ 这条是"仪器有效性"证明：
       *   滚动位置**真的变了** ⇒ 上面那条"搜索框没动"才有意义。
       *   若结果区压根不能滚，那"滚动后搜索框还在"是**恒真**的废话。
       */
      var moved = false;
      for (final e in find.byType(Scrollable).evaluate()) {
        final pos = (e.widget as Scrollable).controller?.position ??
            Scrollable.of(e).position;
        if (pos.maxScrollExtent > 0) moved = true;
      }
      expect(moved, isTrue,
          reason: '★ 40 行必须产生可滚动的内容 —— '
              '若 maxScrollExtent == 0，"滚动后搜索框仍可见"就是空断言');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 【零影响】另外 5 个二级页行为不变
  // ═══════════════════════════════════════════════════════════════════
  group('④ ★★ 外壳改动对另外 5 个二级页零影响', () {
    testWidgets('★★ 不传新参数时，外壳仍按**原结构**渲染（标题/副标题/正文都在）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const SettingsSubPage(
        title: '主题',
        subtitle: '跟随系统 / 浅色 / 深色',
        children: [Text('区块内容')],
      )));
      await t.pump();

      expect(find.text('主题'), findsOneWidget);
      expect(find.text('区块内容'), findsOneWidget);
      expect(find.text('返回设置'), findsOneWidget,
          reason: '★ 返回按钮必须还在');

      /*
       * ⚠️ **不要**断言"外壳是一个 ListView" —— 我第一版这么写了，
       *    然后**假红**了。
       *
       * 原因：另一位代理（`fix-settings-merge`，做用户 ④「返回按钮
       * sticky」）把 `_scrollingBody` 从 `ListView` 改成了
       * `CustomScrollView + SliverPersistentHeader(pinned: true)` ——
       * 那是**用户 ④ 的正确实现**，与我的改动**互不冲突**（我的
       * `pinnedHeader`/`scrollBody` 参数都还在）。
       *
       * ⇒ 我的断言锁死了"实现细节（用哪个滚动控件）"，而**用户要的是
       *   行为**。这正是项目铁律⑥：**断言锁死字面实现会把重构变假回归**。
       * ⇒ 改成断言**可观察行为**：能滚动 + 三个元素都在。
       */
      expect(find.byType(Scrollable), findsWidgets,
          reason: '★ 不传新参数时，页面仍必须可滚动（原行为）');
    });

    test('★★ 源码：新参数必须是**可选**的（有默认值）', () {
      final src =
          File('lib/ui/widgets/settings_sub_page.dart').readAsStringSync();
      expect(src.contains('pinnedHeader'), isTrue,
          reason: '★ 外壳必须有 `pinnedHeader` 参数（搜索框固定在顶部用）');
      // ★ 必须可选 —— 否则 6 个调用方全部编译失败
      final hasOptional = src.contains('this.pinnedHeader') ||
          src.contains('pinnedHeader,');
      expect(hasOptional, isTrue,
          reason: '★★ `pinnedHeader` 必须是可选参数（另外 5 个二级页不传它）');
    });
  });
}
