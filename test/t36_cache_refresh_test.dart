// ═══════════════════════════════════════════════════════════════════════
//  task-36 ⑤ 页面缓存 + 「我的」三 tab 切换自动刷新
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 还有，每个页面不应该每次点进去都是完全新的状态，页面应该有缓存
// > 但是像首页的。追更收藏历史  还有。追更页面的这三个，
// > **切换页面应该要自动刷新的**   请优化操作体验
//
// # ★ 为什么这些断言必须"真的点/真的 pop"
//
// 源码断言（`src.contains('onSelect: _selectTab')`）只能证明**字符串在**，
// 不能证明"点下去真的会重拉" —— 而"点下去刷不刷"正是缺陷本体。
// 本项目已踩过这个坑（`shelf_card_opens_detail_test.dart` 的文件头
// 记着同样的教训：那时源码断言也证明不了"点下去走哪条路"）。
//
// # 仪器：数 `[SHELF]` 日志行 = 数 `load()` 调用次数
//
// `load()` 在 `flutter_test` 里必然走 FFI 失败路径（没有 sourin_core.dll），
// 三路各自打一行 `[SHELF] ...`：
// ```text
// [SHELF] 取收藏失败（保留旧数据）: ...
// [SHELF] 取追更失败（保留旧数据）: ...
// [SHELF] 取历史失败（保留旧数据）: ...
// ```
// ⇒ 3 行 = 1 次 `load()`。
//
// ★★ 每个用到这个仪器的用例**都必须带阳性对照**（铁律 2）：
//    显式调一次 `load()`，断言计数真的增加。否则"没增加"可能只是
//    仪器不灵（比如 FFI 某天在测试里能跑通，就一行日志都没有）。
//
// ⚠️ `debugPrint` 是 foundation 的**调试变量**，改完必须在**测试体内**
//    就地恢复 —— 放到 `addTearDown` 里太晚：`_verifyInvariants` 先跑，
//    会报 "The value of a foundation debug variable was changed"。
//    （我第一版就是这么写错的，见 `.probe/probe_tests/` 的 v1。）

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

// ═══════════════════════════════════════════════════════════════════════
//  测试数据构造
// ═══════════════════════════════════════════════════════════════════════

/// ⚠️ `key` 是 `Favorite.fromJson` 的**必填**字段（缺了会抛），
///    所以这里必须给 —— 否则测试在造数据时就炸，而不是在断言处失败。
Favorite fav(String provider, String nativeId, String title) =>
    Favorite.fromJson(<String, dynamic>{
      'key': '$provider:$nativeId',
      'provider': provider,
      'native_id': nativeId,
      'title': title,
      'cover': null,
      'kind': 'series',
      'favorited': true,
      'following': true,
      'unread_count': 0,
    });

Progress prog(String provider, String nativeId, String title) =>
    Progress.fromJson(<String, dynamic>{
      'key': '$provider:$nativeId',
      'provider': provider,
      'native_id': nativeId,
      'title': title,
      'position': 120.0,
      'duration': 600.0,
      'episode_id': 'ep-1',
    });

// ═══════════════════════════════════════════════════════════════════════
//  仪器
// ═══════════════════════════════════════════════════════════════════════

/// 截获 `debugPrint`，返回 (日志缓冲, 卸载函数)
///
/// ★ 卸载函数必须在**测试体内**调用（不能只放 addTearDown —— 见文件头）。
({List<String> log, void Function() uninstall}) capturePrint() {
  final original = debugPrint;
  final log = <String>[];
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) log.add(message);
  };
  return (log: log, uninstall: () => debugPrint = original);
}

/// `[SHELF]` 行数 ÷ 3 = `MyShelf.load()` 的调用次数
int shelfLoads(List<String> log) =>
    log.where((l) => l.contains('[SHELF]')).length ~/ 3;

/// 当前屏幕上所有 `Text` 的内容（判断"内容区到底换了没有"）
Set<String> visibleTexts(WidgetTester tester) {
  final out = <String>{};
  for (final e in find.byType(Text).evaluate()) {
    final t = (e.widget as Text).data;
    if (t != null && t.isNotEmpty) out.add(t);
  }
  return out;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 切 tab 必须自动刷新（用户明确要求）
  // ═══════════════════════════════════════════════════════════════════
  group('① 首页「我的」：切 tab 自动刷新', () {
    testWidgets('★ 点「最近收藏」→ load() 真的被调用（+阳性对照）',
        (tester) async {
      final cap = capturePrint();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final key = GlobalKey<MyShelfState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MyShelf(
                key: key,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        key.currentState!.debugSetData(
          following: [fav('cycani', 'a1', '追更片')],
          favorites: [fav('154', 'b1', '收藏片')],
          history: [prog('360', 'c1', '历史片')],
          tab: ShelfTab.following,
        );
        await tester.pump();

        // 前置条件：tab 标签必须在（否则点不到，结论无意义）
        expect(find.text('最近收藏'), findsOneWidget,
            reason: '★ 找不到 tab 标签 ⇒ 点不到目标，后面的断言全是空的');

        final before = shelfLoads(cap.log);

        await tester.tap(find.text('最近收藏'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final after = shelfLoads(cap.log);

        // ★ 阳性对照：显式调一次，计数必须增加
        key.currentState!.load();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final pos = shelfLoads(cap.log);

        expect(pos, greaterThan(after),
            reason: '★★ 阳性对照失败 ⇒ 判据无效 ⇒ 结论作废。'
                '显式调 load() 都没让计数增加，说明这个仪器'
                '根本数不出 load() 的调用。');

        expect(after, greaterThan(before),
            reason: '★ 用户明确要求「切换页面应该要自动刷新的」—— '
                '点 tab 必须触发一次重拉。'
                '修之前实测 delta=0（`.probe/probe_tests/zz_t36_repro_test.dart`）。');
      } finally {
        cap.uninstall();
      }
    });

    testWidgets('★ 点**当前** tab 也要刷新（用户"看看有没有新的"的自然动作）',
        (tester) async {
      final cap = capturePrint();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final key = GlobalKey<MyShelfState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MyShelf(
                key: key,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        );
        await tester.pump();
        key.currentState!.debugSetData(
          following: [fav('cycani', 'a1', '追更片')],
          tab: ShelfTab.following,
        );
        await tester.pump();

        final before = shelfLoads(cap.log);
        // 「最近追更」已经是当前 tab —— 再点一次
        await tester.tap(find.text('最近追更'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final after = shelfLoads(cap.log);

        expect(after, greaterThan(before),
            reason: '★ 点当前 tab 也该重拉 —— 否则用户想"刷新一下看看"'
                '时只能去别处找入口');
      } finally {
        cap.uninstall();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 从详情页返回必须刷新（原版靠 watch(route)，Flutter 没有）
  // ═══════════════════════════════════════════════════════════════════
  group('② 首页「我的」：从详情页返回自动刷新', () {
    testWidgets('★★ push 详情页 → pop 回来，load() 真的被调用（+阳性对照）',
        (tester) async {
      final cap = capturePrint();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final navKey = GlobalKey<NavigatorState>();
        final shelfKey = GlobalKey<MyShelfState>();

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: MyShelf(
                key: shelfKey,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        shelfKey.currentState!.debugSetData(
          following: [fav('cycani', 'a1', '追更片')],
        );
        await tester.pump();

        final before = shelfLoads(cap.log);

        // ── 盖一个详情页 ──
        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('详情页'))),
          ),
        );
        await tester.pumpAndSettle();

        // ── 返回 ──
        navKey.currentState!.pop();
        await tester.pumpAndSettle();

        final after = shelfLoads(cap.log);

        // ★ 阳性对照
        shelfKey.currentState!.load();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final pos = shelfLoads(cap.log);

        expect(pos, greaterThan(after),
            reason: '★★ 阳性对照失败 ⇒ 判据无效 ⇒ 结论作废');

        expect(after, greaterThan(before),
            reason: '★★ 原版 `MyShelf.vue:255` 靠 Vue Router 监听刷新：'
                '`watch(() => route.path, (p) => { if (p === "/") void load(); })`。'
                'Flutter 侧没有等价钩子（IndexedStack 保活，pop 回来不重建）'
                '⇒ 必须用 ModalRoute.isCurrentOf 补上。'
                '修之前实测 delta=0（`.probe/probe_tests/zz_t36_pages_test.dart` PROBE-3b）。');
      } finally {
        cap.uninstall();
      }
    });

    testWidgets('★★★ 首次加载**失败**时，返回也必须重试（真机探针抓出的 bug）',
        (tester) async {
      /*
       * # 这个用例守的是一个**只在真实 shell 里才暴露**的 bug
       *
       * 我第一版写的是 `if (mounted && _loadedOnce) unawaited(load());`。
       * 上面那条测试**测不出来** —— 它先 `debugSetData(...)`，而
       * `debugSetData` 会把 `_loadedOnce` 置成 true ⇒ 条件永远满足。
       *
       * 真实 ShellPage 探针（`.probe/probe_tests/
       * zz_t36_realshell_return_test.dart`）暴露了它：
       * ```text
       * POS before=2 after=3 delta=1          ← 阳性对照通过
       * after_pop=3 delta_on_return=0         ← ★ 返回刷新没发生
       * real_shell_refreshes_on_return=false
       * ```
       * 根因：`_loadedOnce` 只在**至少一路成功**时才置位
       * ⇒ **首次加载失败时它永远是 false** ⇒ 从详情页返回永不重试，
       *   界面一直空着，直到用户去点 tab 才有救。
       *
       * # 为什么这条测试要"故意不调 debugSetData"
       *
       * 不调它，`_loadedOnce` 才保持 false —— 那正是要复现的状态。
       * （`flutter_test` 里 FFI 必然失败 ⇒ 首次 load 必然"全失败"。）
       */
      final cap = capturePrint();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final navKey = GlobalKey<NavigatorState>();
        final shelfKey = GlobalKey<MyShelfState>();

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: MyShelf(
                key: shelfKey,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // ★ 前置条件：**不**调 debugSetData ⇒ _loadedOnce 保持 false
        //   （首次 load 在测试里必然失败 ⇒ 这就是"首屏没加载出来"的状态）

        final before = shelfLoads(cap.log);

        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('详情页'))),
          ),
        );
        await tester.pumpAndSettle();
        navKey.currentState!.pop();
        await tester.pumpAndSettle();

        final after = shelfLoads(cap.log);

        // ★ 阳性对照
        shelfKey.currentState!.load();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final pos = shelfLoads(cap.log);

        expect(pos, greaterThan(after),
            reason: '★★ 阳性对照失败 ⇒ 判据无效 ⇒ 结论作废');

        expect(after, greaterThan(before),
            reason: '★★★ 首次加载失败后，从详情页返回**必须重试**。'
                '加了 `_loadedOnce` 条件的话这里 delta=0 ⇒ '
                '首屏失败的页面**永远不会自愈**。');
      } finally {
        cap.uninstall();
      }
    });
  });
  //
  // # 这个 bug 是"让切 tab 刷新"**引入**的，必须单独守
  //
  // 原来三个 `.catchError` 都返回**空列表** ⇒ "查失败"与"确实是空的"
  // 在下游完全同形。在只有"首次加载一次"时不明显（失败就是空的，没得比）。
  // 但一旦"切 tab / 返回都重拉"，它立刻变成数据丢失：
  // ```text
  // 用户有 20 条收藏 → 切个 tab 触发重拉 → 核心瞬时失败
  //   → catchError 返回 [] → setState 把 20 条**覆盖成空**
  //   → ★ 界面显示"还没有收藏"，而数据明明还在
  // ```
  group('③ ★★★ 刷新失败必须保留旧数据（不许清空）', () {
    testWidgets('★★ 重拉失败后，已有的卡片**仍在屏幕上**', (tester) async {
      final cap = capturePrint();
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final key = GlobalKey<MyShelfState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MyShelf(
                key: key,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        );
        await tester.pump();
        key.currentState!.debugSetData(
          following: [fav('cycani', 'a1', '追更片')],
          favorites: [fav('154', 'b1', '收藏片')],
          history: [prog('360', 'c1', '历史片')],
        );
        await tester.pump();

        // 前置条件：三张卡都真的在（否则这个测试是空的）
        expect(find.text('追更片'), findsOneWidget,
            reason: '★ 注入的数据必须真的渲染出来，否则后面的断言证明不了什么');

        /*
         * ★ 触发一次**必然失败**的重拉。
         *
         * 在 `flutter_test` 里 FFI 一定加载不了（没有 sourin_core.dll）
         * ⇒ 三路全失败。这正是要模拟的场景："刷新失败时会不会清空"。
         */
        key.currentState!.load();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // ignore: avoid_print
        print('T36|after_failed_reload texts=${visibleTexts(tester)}');

        /*
         * ★★★ 三个数据平面**逐个**检查 —— 不能只看当前 tab
         *
         * # 为什么必须逐个查（我第一版就是这里漏了，红度证明抓出来的）
         *
         * 第一版只在「最近追更」tab 上断言 `追更片` 还在。于是：
         * ```text
         * 红度证明回退**收藏**那一路的 catchError（return <Favorite>[]）
         *   → _favorites 被清空
         *   → 但当前 tab 是「追更」，屏幕上根本没有收藏卡片
         *   → ★ 断言照样绿 —— 判据无效
         * ```
         * 三条 catchError 是**三个独立的**缺陷点，必须三个都守。
         *
         * ⚠️ 切 tab 本身现在也会触发一次（失败的）重拉 —— 那正好是
         *    更严格的场景：连续多次失败刷新之后，数据仍然不许丢。
         */
        for (final entry in {
          '最近追更': '追更片',
          '最近收藏': '收藏片',
          '播放历史': '历史片',
        }.entries) {
          await tester.tap(find.text(entry.key));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.text(entry.value),
            findsOneWidget,
            reason: '★★★ 重拉失败后「${entry.key}」的数据**不许**被清空 —— '
                '修之前这里会变成空状态文案。'
                '用户的数据明明还在，界面却说没有，这是最难察觉的一类 bug。',
          );
        }

        // 空状态文案**不该**出现（它是"确实没有"的专用文案）
        expect(
          find.textContaining('还没有追更的内容'),
          findsNothing,
          reason: '★ 失败 ≠ 空。显示空状态文案等于对用户撒谎',
        );
        expect(
          find.textContaining('还没有收藏'),
          findsNothing,
          reason: '★ 同上 —— 收藏那一路也不能被清空',
        );
      } finally {
        cap.uninstall();
      }
    });

    test('★ 三个 catchError 都不得返回空列表（源码契约）', () {
      /*
       * 上面那条 widget 测试守的是**行为**；这条守**实现契约** ——
       * 防止以后有人"顺手"把 `return null` 改回 `return <Favorite>[]`
       * 而恰好那条行为测试没跑到（比如换了个测试环境让 FFI 能通）。
       *
       * ⚠️ 先剥注释（本项目已踩 7 次"grep 命中注释"的假断言，铁律⑤）。
       */
      String stripComments(String s) {
        final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
        return noBlock
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
      }

      final src = stripComments(
        File('lib/ui/widgets/my_shelf.dart').readAsStringSync(),
      );

      for (final empty in [
        'return <Favorite>[];',
        'return <Progress>[];',
      ]) {
        expect(src.contains(empty), isFalse,
            reason: '★ `$empty` 会把"查失败"变成"确实是空的" ⇒ '
                '刷新失败时清空用户数据。必须 `return null`（保留旧值）。');
      }

      expect(src.contains('return null;'), isTrue,
          reason: '★ 失败必须用 null 标记 —— 空列表分不出"失败"与"真的空"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 手机版触控目标（用户第 1 句：符合人类操作直觉）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 判据来源：项目**自己的**规范，不是我发明的
  //
  // `cctv_to_client/DEVELOPMENT.md` 坑 35：
  // > ★ 触控目标不得小于 ~34px —— 实测巡检发现 52 处偏小
  //
  // 而且原版 `MyShelf.vue` 的 `.mtab` 逐字记着**为什么是 10px**：
  // > 触控目标 ≥34px（见 DEVELOPMENT.md 坑 35）。
  // > 8px 上下内边距 + 14px 行高只到 31px，差一点不达标，故加到 10px。
  //
  // ⇒ 我们原来用 `Sp.x2(8)`，与原版明确**否掉**的那一版一样。
  group('④ 手机版触控目标（项目规范 ≥34px）', () {
    /// 量「我的」三个 tab 的 InkWell 高度
    Future<List<double>> shelfTabHeights(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MyShelf(onOpenDetail: (_, __) {}, onPlay: (_, __, ___, ____, _____) {}),
          ),
        ),
      );
      await tester.pump();
      final hs = <double>[];
      for (final e in find
          .descendant(of: find.byType(MyShelf), matching: find.byType(InkWell))
          .evaluate()) {
        final box = e.renderObject as RenderBox?;
        if (box == null) continue;
        // 只取 tab（宽 96），排除海报卡
        if ((box.size.width - 96).abs() < 0.5) hs.add(box.size.height);
      }
      return hs;
    }

    testWidgets('★★ 「我的」三个 tab 的高度 ≥34px（手机尺寸下量）',
        (tester) async {
      // 典型 Android 手机竖屏（Pixel 逻辑像素）
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final hs = await shelfTabHeights(tester);

      expect(hs.length, 3,
          reason: '★ 必须量到 3 个 tab（量到 0 个说明选择器失效，'
              '那样下面的断言会**假绿**）');
      for (final h in hs) {
        expect(h, greaterThanOrEqualTo(34.0),
            reason: '★★ 项目规范（DEVELOPMENT.md 坑 35）要求触控目标 ≥34px。'
                '实测修之前是 **33**（`Sp.x2*2 + 17 文字行高`）—— '
                '与原版注释里"8px + 14px 只到 31px，差一点不达标"是同一个坑。'
                '当前 $h。');
      }
    });

    testWidgets('★ 阳性对照：这个方法真的能量出"偏小"', (tester) async {
      /*
       * ★★ 铁律 2：阳性对照失败 ⇒ 判据无效 ⇒ 结论作废。
       *    上面那条断言"≥34"如果测量方法本身不灵（比如永远返回 41），
       *    它就是一条永远绿的假断言。这里用一个**已知偏小**的控件证明
       *    测量方法真的会判出"不达标"。
       */
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 20, // ← 已知偏小
                child: InkWell(onTap: () {}, child: const Text('小')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final box = find.byType(InkWell).evaluate().first.renderObject as RenderBox;
      expect(box.size.height, lessThan(34.0),
          reason: '★★ 阳性对照：一个 20px 高的控件必须被判为不达标。'
              '若这里也"通过"，说明测量方法无效，上面那条断言作废。');
    });

    testWidgets('★★ 追更页三个 tab 的高度也 ≥34px（两处必须一起改）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FollowPage(
              isTv: false,
              onUnreadChanged: (_) {},
              onOpenDetail: (_, __) {},
              onPlay: (_, __, ___, ____, _____) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final hs = <double>[];
      for (final e in find.byType(InkWell).evaluate()) {
        final box = e.renderObject as RenderBox?;
        if (box == null) continue;
        if ((box.size.width - 96).abs() < 0.5) hs.add(box.size.height);
      }

      expect(hs.length, 3,
          reason: '★ 追更页也必须有 3 个 tab（量到 0 个 ⇒ 假绿）');
      for (final h in hs) {
        expect(h, greaterThanOrEqualTo(34.0),
            reason: '★★ 追更页这三个 tab 与首页「我的」**逐字同构** —— '
                '只改一处会立刻变成"一个页面对、一个页面不对"'
                '（本项目踩过：用户原话「追更页面这三个点进去正常，'
                '首页的是直接进播放页」）。当前 $h。');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 缓存：切 tab 不得闪骨架（文件头 ③ 那条修过的滚动 bug）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 切 tab 不许闪骨架（缓存语义）', () {
    testWidgets('★ 已有数据时切 tab，内容**原地替换**而不是塌成骨架',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final key = GlobalKey<MyShelfState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MyShelf(
              key: key,
              onOpenDetail: (_, __) {},
              onPlay: (_, __, ___, ____, _____) {},
            ),
          ),
        ),
      );
      await tester.pump();
      key.currentState!.debugSetData(
        following: [fav('cycani', 'a1', '追更片')],
        favorites: [fav('154', 'b1', '收藏片')],
        history: [prog('360', 'c1', '历史片')],
      );
      await tester.pump();

      // 切一圈，每切一次都检查"有没有塌成骨架"
      for (final entry in {
        '最近收藏': '收藏片',
        '播放历史': '历史片',
        '最近追更': '追更片',
      }.entries) {
        await tester.tap(find.text(entry.key));
        /*
         * ⚠️ 只 pump **一帧**就断言 —— 骨架如果会出现，就在这一帧。
         *    pump 完动画再看的话，骨架可能已经过去了（漏判）。
         */
        await tester.pump();
        expect(find.text(entry.value), findsOneWidget,
            reason: '★ 切到「${entry.key}」的**第一帧**就该有数据 —— '
                '塌成骨架会让容器高度骤降，'
                '那是文件头 ③ 记录的那条真 bug 的成因'
                '（原版实测：浏览器把 scrollTop 钳到 261，'
                '滚动位置记忆永远恢复不了）');
        await tester.pump(const Duration(milliseconds: 500));
      }
    });
  });
}
