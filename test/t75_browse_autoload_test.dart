// ══════════════════════════════════════════════════════════════════════════
//  task-75 浏览页两条需求（Owner 截图原话）
// ══════════════════════════════════════════════════════════════════════════
//
// Owner 原话（附 1280x760 截图）：
// ```text
// 触底加载更多,不要 加载更多  按钮
// 返回按钮不要随这页面消失,往下滑固定在上面
// ```
//
// 需求①：滚到接近底部就**自动**取下一页；底部那个「加载更多」按钮删掉。
// 需求②：返回按钮 + 标题**吸顶**，滚到哪都留在视口顶。
//
// # ★ 为什么这两条必须各有"两极对照"
//
// 本仓铁律：**永远为真的判据不是判据**。这两条需求都极易写出
// 「删掉按钮 ⇒ 断言 find.text('加载更多') 为空 ⇒ 恒真（按钮本来就没画过）」
// 这种空转断言。所以：
// ```text
// 需求①  阳性：滚到底 ⇒ 条目数真的从 20 变 40（取到第 2 页了）
//        阴性：已经到底 ⇒ 再触发不增（闸门真的闸住了）
// 需求②  阳性：内容真的在滚（卡片 y 变小）
//        阴性：同一次读数里，返回按钮 y **纹丝不动**
// ```
// ②的"阳性对照"尤其关键：如果内容根本没滚，那"返回按钮没动"是**必然**的，
// 证明不了吸顶（#522：反向找到一个容器永远会成功 ⇒ 无效判据）。
//
// # ★ 为什么要有 `debugSetPageLoader` 这个口子
//
// `flutter test` 里 `sourin_core.dll` **必然加载失败** ⇒ `SourinApi.getList`
// 必抛 ⇒ `_items` 恒为空 ⇒ 所有"触底会不会自动取下一页"的断言都会退化成
// 对**空树**的断言（铁律 149）。本仓既有同款口子：
// `search_page.dart:392 debugSetProviderCount`、`follow_page.dart:612
// debugSetContinueList`。
// ⚠️ 它替换的只是**取数那一次调用**，不是 `_load` —— 代次检查、列表拼接、
//    视口补取、`_page`/`_pageCount` 更新全都还是生产那份代码在跑。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart' as models;
import 'package:sourin_spike/ui/browse_page.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

/// 视口 —— 与 Owner 截图同宽（1280），高取 900 便于量吸顶几何
const Size kViewport = Size(1280, 900);

/// 吸顶高度（`browse_page.dart` 的 `_headerMinExtent` = 48 + `Sp.x5`）
const double kHeaderMin = 48 + 20;

/// 展开高度（= 吸顶高度 + `Sp.x8`）
const double kHeaderMax = kHeaderMin + 32;

Widget host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: const MediaQueryData(size: kViewport),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

models.MediaItem item(int i) =>
    models.MediaItem(id: 'demo:$i', title: '条目$i');

/// 一页 [n] 条，共 [pageCount] 页
models.Page<models.MediaItem> pageOf(int n, {int page = 1, int? pageCount}) =>
    models.Page<models.MediaItem>(
      items: [for (var i = 0; i < n; i++) item((page - 1) * n + i)],
      page: page,
      pageCount: pageCount,
    );

/// 返回按钮（`Icons.chevron_left`）—— 需求②的主角
final Finder kBack = find.byIcon(Icons.chevron_left);

/// 吸顶条那层 `Container`（delegate 里画底色的那个）
///
/// ⚠️ 用 `.first`：pinned 头的子树里 `Container` 不止一个。
final Finder kBar = find
    .descendant(
      of: find.byType(SliverPersistentHeader),
      matching: find.byType(Container),
    )
    .first;

/// 分类胶囊的容器（分类栏里那些圆角 `InkWell`）
final Finder kCatChip = find.byType(InkWell);

/// 挂载 BrowsePage 并注入取页函数，返回 (State, 取页调用记录)
///
/// ★ 注入走**构造参数** `pageLoaderForTest`，不是挂载后再 `debugSetPageLoader`。
///   `_init()` 挂在 post-frame 回调上，而 `pumpWidget()` 会把第 1 帧
///   （含 post-frame 回调）跑完才返回 —— 挂载后再注入就已经晚了：
///   第 1 页早用真 FFI 取过（必抛，`flutter test` 里没有核心 DLL）
///   ⇒ `_items` 恒为空 ⇒ 所有断言都退化成对**空树**的断言。
Future<(BrowsePageState, List<int>)> mount(
  WidgetTester t, {
  required Future<models.Page<models.MediaItem>> Function(int page) loader,
  int? cats,
}) async {
  t.view.physicalSize = kViewport;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final calls = <int>[];
  await t.pumpWidget(
    host(
      BrowsePage(
        provider: 'demo',
        title: '电影',
        pageLoaderForTest: (p) {
          calls.add(p);
          return loader(p);
        },
      ),
    ),
  );

  final st = t.state<BrowsePageState>(find.byType(BrowsePage));
  if (cats != null) {
    st.debugSetCategories([
      for (var i = 0; i < cats; i++) models.Category(id: '$i', name: '分类$i'),
    ]);
  }
  await t.pump();
  await t.pump();
  return (st, calls);
}

/// 滚到某偏移并等若干帧（`jumpTo` 是瞬时的，不走物理/回弹）
Future<void> at(WidgetTester t, ScrollController c, double off) async {
  c.jumpTo(off.clamp(0.0, c.position.maxScrollExtent));
  await t.pump();
  await t.pump();
  await t.pump();
}

void main() {
  // ══════════════════════════════════════════════════════════════════════
  group('task-75① 需求①：触底自动加载（按钮已删）', () {
    testWidgets('A1 页面上**没有**「加载更多」按钮 —— 且它不是"从来就没画过"',
        (t) async {
      final (st, calls) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );

      // ── 前置：页面真的活了（否则"没有按钮"是空树上的空真）──
      expect(
        st.debugItemCount,
        20,
        reason: '★ 前置：第 1 页必须真的进来了（实测 ${st.debugItemCount} 条）'
            '—— 不成立的话下面"没有按钮"就是对空树的断言',
      );

      // ── 本需求的主角 ──
      expect(
        find.text('加载更多'),
        findsNothing,
        reason: '★★ 需求①：那个按钮必须真的不存在了',
      );
      expect(
        find.text('加载中…'),
        findsNothing,
        reason: '★ 需求①：连它的加载态文案也一起没了',
      );
      // ★ 负向也留个正向锚：旧的按钮是 `FilledButton.tonal`。
      //   这里不断言"一个 FilledButton 都没有"（分类栏将来可能加），
      //   只断言带这个文案的按钮没了 —— 上面两条已覆盖。
      expect(calls, [1], reason: '★ 前置：只应取过第 1 页（实测 $calls）');
    });

    testWidgets('B1[阳性对照] 滚到底 ⇒ **真的**自动取回第 2 页（20 → 40）',
        (t) async {
      final (st, calls) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );

      expect(st.debugItemCount, 20, reason: '★ 前置：先有第 1 页');
      final before = t.getTopLeft(find.text('条目0'));

      await at(t, st.debugScrollController, 100000);

      expect(
        calls,
        contains(2),
        reason: '★★ 需求①：滚到底必须**自动**发第 2 页请求'
            '（实测取页记录 = $calls）',
      );
      expect(
        st.debugItemCount,
        40,
        reason: '★★ 需求①：第 2 页必须真的拼进列表（实测 ${st.debugItemCount} 条）',
      );
      // ★ 阳性对照：内容真的动了 —— 否则"滚到底"这个前提本身没成立
      final after = t.getTopLeft(find.text('条目0'));
      expect(
        after.dy,
        lessThan(before.dy),
        reason: '★★ 阳性对照：内容必须真的在滚（条目0 的 y 从 ${before.dy} '
            '变成 ${after.dy}）—— 不成立则"触底"这个前提没成立',
      );
    });

    testWidgets('B2[阴性对照] 已经到底 ⇒ 再触发**不**增加条目（闸门真的闸住）',
        (t) async {
      final (st, calls) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 2),
      );

      // 取到第 2 页（= 最后一页）
      await at(t, st.debugScrollController, 100000);
      expect(st.debugItemCount, 40, reason: '★ 前置：第 2 页已到');
      expect(st.debugHasMore, isFalse, reason: '★ 前置：pageCount=2 ⇒ 没有下一页了');
      final callsAtEnd = List<int>.from(calls);

      // 再滚、再显式触发
      await at(t, st.debugScrollController, 100000);
      await st.debugLoadMore();
      await t.pump();
      await t.pump();

      expect(
        calls,
        callsAtEnd,
        reason: '★★ 阴性对照：到底之后再滚/再触发都**不该**发请求'
            '（实测取页记录 $callsAtEnd → $calls）',
      );
      expect(st.debugItemCount, 40, reason: '★ 条目数不该变');
      expect(
        find.text('已经到底了'),
        findsOneWidget,
        reason: '★ 到底了要有终点提示（替代原来的按钮）',
      );
    });

    testWidgets('C1[空真防护] 内容**不满一屏**时也要能取到第 2 页', (t) async {
      /*
       * ★★★ 这是"删掉按钮"引入的**新**问题，必须有守卫：
       *   按钮还在时，内容不满一屏只是"按钮挂在最下面"。
       *   换成触底自动加载后：内容不满一屏 ⇒ 页面根本没法滚动 ⇒
       *   滚动回调永远不触发 ⇒ **永远取不到第 2 页**，用户被卡在第 1 页。
       *   4 条 @1280 宽 = 1 行 ≈288px（2026-10-03 标题改两行后从 ≈266 长高），
       *   加上页头远小于 900 ⇒ maxScrollExtent == 0。
       */
      final (st, calls) = await mount(
        t,
        loader: (p) async => pageOf(4, page: p, pageCount: 5),
      );

      expect(
        st.debugScrollController.position.maxScrollExtent,
        0.0,
        reason: '★ 前置：这一屏必须真的**滚不动**（否则本测试测的是别的东西）',
      );
      expect(
        calls,
        contains(2),
        reason: '★★ 需求①：内容填不满一屏 ⇒ 必须继续补取，'
            '否则用户永远看不到第 2 页（实测取页记录 = $calls）',
      );
    });

    testWidgets('C2[阴性对照] 上游返回空页 ⇒ 补取必须**停下**（不死循环）',
        (t) async {
      /*
       * `_fillViewportIfNeeded` 的 `grew` 判据：只有上一页**真的带回了条目**
       * 才继续补。空页不增加内容 ⇒ `maxScrollExtent` 恒为 0 ⇒
       * 没有这个判据就是无限发请求。
       */
      var served = 0;
      final (st, calls) = await mount(t, loader: (p) async {
        served++;
        // 第 1 页给 4 条（填不满一屏），之后**全是空页**
        return served == 1
            ? pageOf(4, page: 1, pageCount: 99)
            : models.Page<models.MediaItem>(
                items: const [],
                page: p,
                pageCount: 99,
              );
      });

      final n = calls.length;
      expect(n, greaterThan(1), reason: '★ 前置：至少补取过一次（实测 $calls）');
      expect(
        n,
        lessThan(12),
        reason: '★★ 阴性对照：空页必须让补取**停下**，不能无限发请求'
            '（实测发了 $n 次：$calls）',
      );
      expect(st.debugItemCount, 4, reason: '★ 条目数还是 4');
    });

    testWidgets('D1[竞态] 换分类后，旧分类迟到的那一页必须被**丢弃**', (t) async {
      /*
       * ★ 自动加载把"第 2 页还在飞、用户已经点了别的分类"从理论竞态
       *   变成**常态**。迟到的那页是旧分类的，拼上去就会让列表里
       *   混进上一个分类的片子，还会覆盖 `_page` / `_pageCount`。
       */
      final gate = <int, Completer<models.Page<models.MediaItem>>>{};
      final (st, calls) = await mount(t, loader: (p) {
        final c = Completer<models.Page<models.MediaItem>>();
        gate[p] = c;
        return c.future;
      });

      // 第 1 页先放行
      gate[1]!.complete(pageOf(20, page: 1, pageCount: 5));
      await t.pump();
      await t.pump();
      expect(st.debugItemCount, 20, reason: '★ 前置：第 1 页已到');

      // 滚到底 ⇒ 第 2 页请求发出（挂在 gate 上，还没回）
      await at(t, st.debugScrollController, 100000);
      expect(calls, contains(2), reason: '★ 前置：第 2 页请求已发出（实测 $calls）');
      /*
       * ★ 先把**旧代次**的第 2 页这个 Completer 抓在手里 —— 后面换分类时
       *   `_load(1)` 会重新往 `gate[1]` 里塞一个新的（覆盖 map 里的旧条目），
       *   而 `gate[2]` 也会被新代次的补取覆盖。抓在手里才放行得了旧的那个。
       */
      final stalePage2 = gate[2]!;

      // 用户换分类 ⇒ 代次 +1，然后放行**旧分类**的第 2 页
      st.debugSetCategories([
        const models.Category(id: '9', name: '分类9'),
      ]);
      await t.pump();
      /*
       * ⚠️ 必须先滚回顶部才能点分类 —— `find` 只遍历**已 build 的元素树**，
       *    而此刻滚动位置在底部（≈ maxScrollExtent），分类栏那个
       *    `SliverToBoxAdapter` 已在视口上方、连缓存区都出界 ⇒
       *    `find.text('分类9')` 会得 0（首跑就踩了这个）。
       *    ⚠️ 滚回 0 会再次触发 `_onScroll`，但 `_loadingMore` 还是 true
       *    （第 2 页挂在 gate 上没回）⇒ `_maybeLoadMore` 的闸门挡住，
       *    不会多发请求。
       */
      await at(t, st.debugScrollController, 0);
      // 直接调生产那条 `_switchCategory` 路径（走 UI 点击，不是私有方法）
      final chip = find.text('分类9');
      expect(chip, findsOneWidget, reason: '★ 前置：分类胶囊已渲染');
      await t.tap(chip);
      await t.pump();
      final freshPage1 = gate[1]!;
      expect(
        freshPage1.isCompleted,
        isFalse,
        reason: '★ 前置：新代次的第 1 页还在飞（否则下面量不到"迟到"）',
      );

      /*
       * ⓐ 阳性对照：**先**放行旧代次迟到的第 2 页。
       *
       * ⚠️ 顺序是这条测试的命门：必须先放旧页、**后**放新页。
       *    反过来的话，"列表是 3 条"既能解释成"旧页被丢弃"，
       *    也能解释成"新页把 40 条整个覆盖掉了" —— 两种机理读数相同，
       *    这条测试就证明不了代次检查（#522 家族）。
       *    先放旧页 ⇒ 此刻 `_items` 还是 20 条，旧页若被拼上就是 **40** 条
       *    ⇒ "还是 20" 唯一地证明它被丢弃了。
       */
      stalePage2.complete(pageOf(20, page: 2, pageCount: 5));
      await t.pump();
      await t.pump();

      expect(
        st.debugItemCount,
        20,
        reason: '★★ 竞态：旧分类迟到的第 2 页必须被丢弃，**不能**拼进列表'
            '（实测 ${st.debugItemCount} 条；拼上就是 40，清空就是 0）',
      );
      expect(
        st.debugItems.map((e) => e.id),
        isNot(contains('demo:20')),
        reason: '★★ 旧页的第 1 条（demo:20）**不能**出现在列表里',
      );

      /*
       * ⓑ 再验一道闸：旧页的 `finally` **不能**把新页的 `_loading` 清掉。
       *
       * ★ 旧页的 `finally` 里是 `if (mounted && gen == _gen)` —— 代次对不上
       *   就**不**动标志位。少了那个判断，旧页回来时会把 `_loading` 清成
       *   false，而新分类的第 1 页**还在飞** ⇒ 闸门全开 ⇒ 下面这一滚
       *   就会抢发新分类的第 2 页（第 2 页比第 1 页先发，老问题重演）。
       *   ⚠️ 所以这里必须**真的滚一下**把闸门消费掉，光读标志位不算数
       *   （检查了不等于闸住了，#524）。
       */
      final before = calls.length;
      await at(t, st.debugScrollController, 100000);
      expect(
        calls.length,
        before,
        reason: '★★ 旧页的 finally 不能误清新页的 `_loading`：新分类第 1 页'
            '还在飞的时候，滚到底**不该**发出任何新请求（实测多发了 '
            '${calls.sublist(before)}）',
      );

      /*
       * ⓒ 阳性对照：新代次的第 1 页回来 ⇒ 列表**真的**被换成 3 条。
       *    没有这一步，上面"还是 20 条"也能被解释成"新页根本没生效"。
       */
      freshPage1.complete(pageOf(3, page: 1, pageCount: 9));
      await t.pump();
      await t.pump();
      expect(
        st.debugItemCount,
        3,
        reason: '★ 阳性对照：新分类的第 1 页必须真的生效（实测 ${st.debugItemCount} 条）',
      );
    });

    testWidgets('D2[换分类] 换分类那一下**不能**抢发第 2 页', (t) async {
      /*
       * ★★ 这条测的是一个**闸门洞**：`_switchCategory` 里 `jumpTo(0)`
       *    会**同步**触发 `_onScroll`（`jumpTo` 走 `forcePixels` ⇒
       *    `notifyListeners`）。而它在 setState 里已经把 `_page` 置 1、
       *    `_pageCount` 清成 null、`_loadingMore` 清成 false
       *    ⇒ `_hasMore` 为 true、闸门全开 ⇒ 会抢在 `_load(1)` **之前**
       *    发出 `_load(2)`，即"新分类的第 2 页比第 1 页先发"。
       *
       * ⚠️ 要触发它，换分类那一刻的 `maxScrollExtent` 必须 <
       *    `_loadMoreAhead`(600) —— 否则 `_onScroll` 第一句就早退了。
       *    所以这里**不能**把第 2 页放行（放行后 40 条 ⇒ 1187 > 600，
       *    洞就被自己的内容堵住了，测试会空转成绿）。
       *
       * ⚠️ 采样偏移取 20：分类栏住在内容坐标 100..140，而吸顶页头
       *    在偏移 20 时占视口 0..80 ⇒ 胶囊落在视口 80..120，**点得到**。
       *    偏移一旦 ≥ 32，页头就完全盖住分类栏（`t.tap` 会打到页头上）。
       */
      final gate = <int, Completer<models.Page<models.MediaItem>>>{};
      final (st, calls) = await mount(t, loader: (p) {
        final c = Completer<models.Page<models.MediaItem>>();
        gate[p] = c;
        return c.future;
      });

      gate[1]!.complete(pageOf(20, page: 1, pageCount: 5));
      await t.pump();
      await t.pump();
      expect(st.debugItemCount, 20, reason: '★ 前置：第 1 页已到');

      await at(t, st.debugScrollController, 20);
      expect(
        calls,
        contains(2),
        reason: '★ 前置：滚到 20 就该自动取第 2 页了'
            '（20 条时 maxScrollExtent 只有 233.5 < 600；实测 $calls）',
      );

      st.debugSetCategories([
        const models.Category(id: '9', name: '分类9'),
      ]);
      await t.pump();
      final chip = find.text('分类9');
      expect(chip, findsOneWidget, reason: '★ 前置：分类胶囊在视口里');
      expect(
        st.debugScrollController.offset,
        greaterThan(0),
        reason: '★ 前置：此刻**不在**顶部 —— 否则 `jumpTo(0)` 不发通知，'
            '这条测试会空转成绿',
      );

      final before = calls.length;
      await t.tap(chip);
      await t.pump();

      expect(
        calls.sublist(before),
        [1],
        reason: '★★ 换分类后**只该**发第 1 页。先发第 2 页的话，它会拼在'
            '旧分类那 20 条后面（列表混进上一个分类的内容），'
            '随后第 1 页再整体覆盖 —— 白跑一趟还闪一下错内容'
            '（实测 ${calls.sublist(before)}）',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('task-75② 需求②：返回按钮吸顶', () {
    testWidgets('A1 页头在 `SliverPersistentHeader` 里，且 `pinned: true`',
        (t) async {
      await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );

      final h = t.widget<SliverPersistentHeader>(
        find.byType(SliverPersistentHeader),
      );
      expect(
        h.pinned,
        isTrue,
        reason: '★★ 需求②：页头必须 `pinned: true` —— 这是"钉在视口顶"的**唯一**来源',
      );
      expect(
        find.descendant(of: find.byType(SliverPersistentHeader), matching: kBack),
        findsOneWidget,
        reason: '★★ 需求②：返回按钮必须是这个 pinned 头的**子件**（不是并列兄弟）',
      );
    });

    testWidgets('A2 分类栏**不**在 pinned 头里（只有页头吸顶）', (t) async {
      await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
        cats: 3,
      );

      expect(find.text('分类0'), findsOneWidget, reason: '★ 前置：分类栏已渲染');
      expect(
        find.descendant(
          of: find.byType(SliverPersistentHeader),
          matching: find.text('分类0'),
        ),
        findsNothing,
        reason: '★ 只钉页头 —— 分类栏若也钉住会吃掉一大块可视高度'
            '（Owner 只要求"返回按钮"固定）',
      );
    });

    testWidgets('B1 静止态：页头高度正好是 maxExtent（与改造前逐像素一致）',
        (t) async {
      await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );

      // 页头那层 `Container`（delegate 里那个）—— 取 pinned 头内的第一个
      final box = t.renderObject<RenderBox>(
        find
            .descendant(
              of: find.byType(SliverPersistentHeader),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        box.size.height,
        kHeaderMax,
        reason: '★ 静止态高度必须 == maxExtent($kHeaderMax)：'
            '改造前是 `Sp.x8 + 48 + Sp.x5` = 100，观感不许变（实测 ${box.size.height}）',
      );
    });

    testWidgets('B2 扫描 9 个偏移：页头**钉在视口顶**，按钮最多上移「收缩量」',
        (t) async {
      /*
       * ★★ 判据怎么定的（不是照抄 delegate 的公式 —— 那等于抄答案，见铁律 #522）
       *
       * 只断言**用户能看见的性质**：
       * ```text
       * ① 页头条的顶边**恒为 0**       ⇒ 它真的钉在视口顶（pinned 的定义）
       * ② 页头条高度恒在 [min,max] 内  ⇒ 既不会塌成 0，也不会比静止态还高
       * ③ 返回按钮**始终在视口内**      ⇒ Owner 要的就是"不要随页面消失"
       * ④ 按钮相对静止态**最多上移 32px** ⇒ 收缩量有上界，不会一路滑出去
       * ```
       * ⚠️ 这条设计是**可收缩**页头（静止 100 → 吸顶 68），与
       *    `lib/ui/search_page.dart:663-672` 的搜索框吸顶条同源：
       *    多出来的那 32px 是**顶部呼吸**，随滚动收掉。
       *    ⇒ 按钮会**上移 32px 然后永远不动**，而不是"从第一像素起就不动"。
       *    这是刻意的，B3 单独验证"收完之后一步不动"。
       */
      final (st, _) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );
      final c = st.debugScrollController;

      final hdr = t.widget<SliverPersistentHeader>(
        find.byType(SliverPersistentHeader),
      );
      final collapse = hdr.delegate.maxExtent - hdr.delegate.minExtent;

      await at(t, c, 0);
      final restTop = t.getTopLeft(kBack).dy;

      final rows = <String>[];
      for (final off in <double>[0, 10, 20, collapse, 60, 120, 240, 480, 900]) {
        await at(t, c, off);
        final top = t.getTopLeft(kBack).dy;
        final barTop = t.getTopLeft(kBar).dy;
        final barH = t.getSize(kBar).height;
        rows.add('off=${off.toStringAsFixed(0).padLeft(4)} '
            'btn=${top.toStringAsFixed(1).padLeft(6)} '
            'barTop=${barTop.toStringAsFixed(1).padLeft(5)} '
            'barH=${barH.toStringAsFixed(1).padLeft(6)}');

        expect(
          barTop,
          closeTo(0.0, 0.51),
          reason: '★★ 需求②：页头条顶边必须恒为 0（钉在视口顶）。\n'
              '实测全表：\n${rows.join('\n')}',
        );
        expect(
          barH,
          inInclusiveRange(kHeaderMin - 0.01, kHeaderMax + 0.01),
          reason: '★ 页头高度必须落在 [minExtent, maxExtent] 内 —— '
              '塌成 0 就是"又消失了"，比静止态还高就是算错了。\n'
              '实测全表：\n${rows.join('\n')}',
        );
        expect(
          top,
          inInclusiveRange(-0.51, kViewport.height),
          reason: '★★ 需求②：返回按钮必须**始终在视口内**（这才是 Owner 的原话'
              '"不要随这页面消失"）。\n实测全表：\n${rows.join('\n')}',
        );
        expect(
          top,
          inInclusiveRange(restTop - collapse - 0.51, restTop + 0.51),
          reason: '★ 按钮相对静止态最多上移「收缩量」($collapse px) —— '
              '上移超过它就是一路滑出去了。\n实测全表：\n${rows.join('\n')}',
        );
      }
    });

    testWidgets('B3 收完之后：按钮 y **一步不动**（比较多个偏移的读数）',
        (t) async {
      /*
       * ★ 判据是「**多次测量之间相等**」，不是「等于某个我算出来的数」——
       *   后者只是把我的算术抄进测试，测不出东西。
       */
      final (st, _) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );
      final c = st.debugScrollController;

      final hdr = t.widget<SliverPersistentHeader>(
        find.byType(SliverPersistentHeader),
      );
      final collapse = hdr.delegate.maxExtent - hdr.delegate.minExtent;

      // 取「刚好收完」那一刻作为基准
      await at(t, c, collapse);
      final pinned = t.getTopLeft(kBack).dy;

      final rows = <String>['off=${collapse.toStringAsFixed(0)} '
          'btn=${pinned.toStringAsFixed(2)}  ← 基准'];
      for (final off in <double>[collapse + 1, 100, 200, 400, 800]) {
        await at(t, c, off);
        final top = t.getTopLeft(kBack).dy;
        rows.add('off=${off.toStringAsFixed(0)} btn=${top.toStringAsFixed(2)}');

        expect(
          top,
          closeTo(pinned, 0.51),
          reason: '★★ 需求②：页头收完之后，返回按钮必须**一步不动**'
              '（这是"固定在上面"的字面判据）。\n实测全表：\n${rows.join('\n')}',
        );
      }
    });

    testWidgets('C1[两极对照] 同一次读数：内容**真的在滚**，而返回按钮**纹丝不动**',
        (t) async {
      /*
       * ★★★ 这条是本组最关键的 —— 没有它，"返回按钮没动"证明不了吸顶：
       *   如果内容根本没滚，按钮不动是**必然**的（#522 家族）。
       *   所以必须在**同一次读数**里同时量两件事。
       *
       * ⚠️ 两个采样点都取在**页头收完之后**（≥ 收缩量）—— 否则量到的
       *    差异里混着那 32px 的呼吸收缩，就不是"钉住"的判据了。
       *
       * ⚠️ 量的是 `条目7`（第 2 行第 1 张），**不是** `条目0`：
       *    实测 20 条 / 7 列时 `maxScrollExtent` 只有 **233.5**，
       *    第 1 行在滚到 432 时已被推出视口上方 ⇒ `find` 得 0
       *    （首跑就踩了这个）。第 2 行在两个采样点都稳稳落在视口内。
       *
       * ⚠️ 判据用**实测**的两次读数之差，不用我算出来的数。
       */
      final (st, _) = await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );
      final c = st.debugScrollController;

      final hdr = t.widget<SliverPersistentHeader>(
        find.byType(SliverPersistentHeader),
      );
      final collapse = hdr.delegate.maxExtent - hdr.delegate.minExtent;

      await at(t, c, collapse);
      final o1 = c.offset;
      final cardBefore = t.getTopLeft(find.text('条目7')).dy;
      final backBefore = t.getTopLeft(kBack).dy;

      await at(t, c, collapse + 400);
      final o2 = c.offset;
      final cardAfter = t.getTopLeft(find.text('条目7')).dy;
      final backAfter = t.getTopLeft(kBack).dy;

      // ── 前置：这两次读数之间，滚动位置**真的**变了 ──
      expect(
        o2 - o1,
        greaterThan(100),
        reason: '★ 前置：两次采样之间的滚动位置必须真的差一大截'
            '（实测 $o1 → $o2，只差 ${o2 - o1}px）',
      );
      // ── 阳性：内容真的滚了 ──
      expect(
        cardBefore - cardAfter,
        greaterThan(100),
        reason: '★★ 阳性对照：内容必须真的滚走一大截'
            '（条目7 的 y：$cardBefore → $cardAfter）',
      );
      // ── 阴性：按钮一步没动 ──
      expect(
        backAfter,
        closeTo(backBefore, 0.51),
        reason: '★★ 需求②：内容滚了 ${cardBefore - cardAfter}px，'
            '返回按钮的 y 必须**纹丝不动**（实测 $backBefore → $backAfter）',
      );
    });

    testWidgets('D1 吸顶状态下点返回按钮，仍然真的能 pop（不是只剩个画）',
        (t) async {
      final theme = FTheme.neutral.light.desktop;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme.toApproximateMaterialTheme(),
        builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
        home: MediaQuery(
          data: const MediaQueryData(size: kViewport),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BrowsePage(
                          provider: 'demo',
                          title: '电影',
                          // ★ 必须走构造参数：`_init()` 挂在 post-frame 上，
                          //   push 完再注入就已经晚了（见 `mount` 的注释）。
                          pageLoaderForTest: (p) async =>
                              pageOf(20, page: p, pageCount: 5),
                        ),
                      ),
                    ),
                    child: const Text('进浏览页'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));

      await t.tap(find.text('进浏览页'));
      await t.pumpAndSettle();
      expect(find.byType(BrowsePage), findsOneWidget, reason: '★ 前置：已进浏览页');

      final st = t.state<BrowsePageState>(find.byType(BrowsePage));
      await t.pump();
      await t.pump();
      expect(st.debugItemCount, 20, reason: '★ 前置：第 1 页真的进来了');

      // 滚到深处（按钮处于吸顶状态）
      await at(t, st.debugScrollController, 800);
      final y1 = t.getTopLeft(kBack).dy;
      await at(t, st.debugScrollController, 900);
      final y2 = t.getTopLeft(kBack).dy;
      expect(y2, closeTo(y1, 0.51), reason: '★ 前置：已吸顶（y=$y1 → $y2 不动）');

      await t.tap(kBack);
      await t.pumpAndSettle();

      expect(
        find.byType(BrowsePage),
        findsNothing,
        reason: '★★ 需求②：吸顶状态下点返回必须**真的** pop —— '
            '否则"钉住"只是个画，用户还是出不去',
      );
    });

    testWidgets('E1 吸顶条底色**不透明**（否则卡片会从它下面透出来叠字）',
        (t) async {
      await mount(
        t,
        loader: (p) async => pageOf(20, page: p, pageCount: 5),
      );

      // delegate 里那层 `Container` 的 color（widget 层读，最直接）
      final container = t.widget<Container>(
        find
            .descendant(
              of: find.byType(SliverPersistentHeader),
              matching: find.byType(Container),
            )
            .first,
      );
      final color = container.color;
      expect(color, isNotNull, reason: '★ 吸顶条必须显式给底色');
      expect(
        color!.a,
        1.0,
        reason: '★★ 吸顶条底色必须**完全不透明**（实测 alpha=${color.a}）'
            '—— 内容会从它下面滚过，半透明会叠字',
      );
    });
  });
}
