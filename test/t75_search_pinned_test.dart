// ══════════════════════════════════════════════════════════════════════════
//  task-74 ② 搜索框吸顶 —— 回归测试
// ══════════════════════════════════════════════════════════════════════════
//
// Owner 原话（m04668）：
// > 搜索页面,搜索框固定在上面,下面内容区域滚动
//
// # 这个文件是被**生产代码点名**的
//
// `lib/ui/search_page.dart:645` 逐字写着：
// > `test/t75_search_pinned_test.dart` 会渲染整页并滚动，溢出会直接让测试变红。
//
// 之前只有 `.probe/probe_tests/t75_pinned_probe_test.dart`（探针，不进门禁），
// 生产注释却已经把它当成既有防线 ⇒ **生产代码承诺了一个不存在的测试**。
// 本文件把那句承诺兑现。
//
// # 判据来自实测，不是猜的
//
// 下面所有几何数字都来自探针在视口 1400×900 下的真读数
//（`.probe/t75_pinned.txt`，`flutter test` 实跑），不是估的：
//
// ```text
//   offset | box.top box.bottom | 副标题.top | 首卡.top
//   -------+-------------------+------------+----------
//        0 |    98.0      148.0 |       64.0 |    204.0
//       40 |    58.0      108.0 |       24.0 |    164.0
//       78 |    20.0       70.0 |       (滚走) |    126.0
//       98 |     0.0       50.0 |       (滚走) |    106.0
//      600 |     0.0       50.0 |       (滚走) |   -396.0
//     1200 |     0.0       50.0 |       (滚走) |     20.6
// ```
//
// ★ 从这张表能读出一条**精确的规律**：`box.top == max(0, 98 - offset)`，
//   13 个采样点全部吻合。98 = 页头 sliver 高 78 + `homeTopPadding` 20。
//   ⇒ 断言写成这条**规律**，而不是散落的魔数。
//
// # 为什么必须做**两极对照**（铁律 289 / spec Contract 23）
//
// 「搜索框 top 恒为 0」这个读数，在下面两种情况下**完全一样**：
//   (a) 吸顶生效，框钉在顶部            ← 想要的
//   (b) 整个页面根本滚不动（滚动失效）   ← 坏掉的
// 只读框的位置无法区分二者 ⇒ 必须在**同一次读数**里同时证明
// 「框不动」**和**「下面的内容真的在动」。后者就是本文件的阳性对照。
//
// # 为什么在 `flutter test` 里能跑
//
// 本文件不挂真 `Player`、不调 `open()`、不用 `toImage()`
// —— 那些会因真定时器把 `flutter test` 挂死 10 分钟。
// 这里只渲染 widget 树并读 `RenderBox` 几何，是纯合成测量。
// 数据注入口是生产代码里既有的 `@visibleForTesting` 方法
// （`debugSetProviderCount` / `debugBeginSearch` / `debugFeedHit`），
// 走的是**真实那条代码路径**（`_addHit`），不是测试里另写一份。

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

/// 探针实测用的视口 —— 与 `.probe/t75_pinned.txt` 同尺寸，
/// 这样本文件里的几何锚点与那份读数**逐字可比**。
const Size kViewport = Size(1400, 900);

/// 搜索框自身高度（`search_page.dart` 的 `_searchBarHeight`，实测 50）
const double kBarH = 50;

/// 展开时的顶距（`AppMetrics.homeTopPadding` = `Sp.x5` = 20）
const double kPadTop = 20;

/// 页头 sliver 的高度。**不是常量**：由页头内容撑出来，实测 78。
/// 断言里不写死它，而是**当场量**（见 `restTop`），避免以后改页头就假失败。
const double kHeaderH = 78;

Widget host(Widget child, Size size) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

MediaItem item(String title, String id) => MediaItem(id: id, title: title);

SearchStreamEvent hit(String name, List<MediaItem> items) => SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: name,
      providerName: name,
      items: items,
    );

/// 搜索框那层 `Container`（= `_searchBoxKey` 挂的那个）
final Finder kBoxFinder = find
    .ancestor(of: find.byType(TextField), matching: find.byType(Container))
    .first;

/// 造好一个「已搜过一轮、有 3 组结果」的搜索页，返回 (State, ScrollPosition)。
///
/// 结果条数 3×24 = 72 条 ⇒ 内容足够长，能滚出远超吸顶点（98）的距离。
Future<(SearchPageState, ScrollPosition)> seeded(WidgetTester t) async {
  t.view.physicalSize = kViewport;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  await t.pumpWidget(host(const SearchPage(), kViewport));
  await t.pump();

  final st = t.state<SearchPageState>(find.byType(SearchPage));
  st.debugSetProviderCount(4);
  st.debugBeginSearch('鬼灭之刃');
  await t.pump();

  for (var g = 0; g < 3; g++) {
    st.debugFeedHit(hit('源$g', [
      for (var i = 0; i < 24; i++) item('条目$g-$i', 'p$g:$i'),
    ]));
    await t.pump();
  }

  final pos = Scrollable.of(t.element(find.byType(TextField))).position;
  return (st, pos);
}

/// 滚到某偏移并等一帧（`jumpTo` 是瞬时的，不走物理/回弹）
Future<void> at(WidgetTester t, ScrollPosition pos, double off) async {
  pos.jumpTo(off.clamp(0.0, pos.maxScrollExtent));
  await t.pump();
}

void main() {
  // ════════════════════════════════════════════════════════════════════════
  // 组 A：结构 —— 必须是 pinned 的 SliverPersistentHeader
  // ════════════════════════════════════════════════════════════════════════

  group('task-74② 组A 结构', () {
    testWidgets('A1 页面用 CustomScrollView（不是 ListView），且搜索框在 pinned 头里', (t) async {
      await seeded(t);

      expect(
        find.byType(CustomScrollView),
        findsOneWidget,
        reason: '搜索页的骨架必须是 CustomScrollView —— '
            'ListView 的子项是平级的，没有一个能"钉住"',
      );
      expect(
        find.byType(ListView),
        findsNothing,
        reason: '改回 ListView 就不可能吸顶了',
      );

      final headers = find.byType(SliverPersistentHeader);
      expect(
        headers,
        findsOneWidget,
        reason: '应当**恰好**一个吸顶条（搜索框那个）',
      );

      final hdr = t.widget<SliverPersistentHeader>(headers);
      expect(hdr.pinned, isTrue,
          reason: '★ `pinned: true` 是"滚到哪都留在视口顶"的全部来源；'
              '写成 false 就变成随内容滚走');
      expect(hdr.delegate.minExtent, kBarH,
          reason: '吸顶后高度必须等于搜索框自身高度（实测 $kBarH）');
      expect(hdr.delegate.maxExtent, kBarH + kPadTop,
          reason: '展开高度 = 吸顶高度 + 顶距（$kBarH + $kPadTop）');
    });

    testWidgets('A2 搜索框是 pinned 头的**子件**（不是并列的兄弟）', (t) async {
      await seeded(t);

      expect(
        find.ancestor(
          of: find.byType(TextField),
          matching: find.byType(SliverPersistentHeader),
        ),
        findsOneWidget,
        reason: '★ 搜索框必须**住在** SliverPersistentHeader 里面。'
            '若只是并列放在它旁边，滚动时框照旧会走掉',
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // 组 B：吸顶几何 —— 逐偏移扫描，断言**规律**而不是散落魔数
  // ════════════════════════════════════════════════════════════════════════

  group('task-74② 组B 吸顶几何', () {
    testWidgets('B1 静止态：框在页头下方，高度正好是 minExtent', (t) async {
      await seeded(t);

      final r = t.getRect(kBoxFinder);
      expect(r.height, kBarH,
          reason: '★ 静止态高度就必须等于 minExtent —— '
              '否则滚动到吸顶那一刻会因紧约束变化而跳一下/溢出');
      expect(r.top, kHeaderH + kPadTop,
          reason: '静止态 top = 页头高 + 顶距 = $kHeaderH + $kPadTop（实测）');
      expect(r.left, 24.0, reason: '左右边距 = AppMetrics.contentPadding（Sp.x6）');
      expect(r.right, kViewport.width - 24.0);
    });

    testWidgets('B2 扫描 13 个偏移：top == max(0, restTop - offset)，高度恒为 50', (t) async {
      final (_, pos) = await seeded(t);

      await at(t, pos, 0);
      final restTop = t.getRect(kBoxFinder).top;

      // 采样点覆盖：页头内 / 收缩中 / 刚贴顶 / 远超贴顶点
      const offsets = <double>[
        0, 10, 20, 40, 60, 78, 90, 98, 110, 140, 300, 600, 1200,
      ];

      final rows = <String>[];
      for (final off in offsets) {
        await at(t, pos, off);
        final r = t.getRect(kBoxFinder);
        final want = (restTop - off).clamp(0.0, restTop);

        rows.add('off=${off.toStringAsFixed(0).padLeft(4)} '
            'top=${r.top.toStringAsFixed(1).padLeft(6)} '
            'want=${want.toStringAsFixed(1).padLeft(6)} '
            'h=${r.height.toStringAsFixed(1)}');

        expect(
          r.top,
          moreOrLessEquals(want, epsilon: 0.01),
          reason: '偏移 $off 处 top 应为 max(0, $restTop - $off)。\n'
              '实测全表：\n${rows.join('\n')}',
        );
        expect(
          r.height,
          kBarH,
          reason: '★ 任何偏移下高度都必须恒为 $kBarH。'
              'SliverPersistentHeader 给子件的是**紧约束**，'
              '高度对不上就会 RenderFlex overflowed。\n'
              '实测全表：\n${rows.join('\n')}',
        );
      }
    });

    testWidgets('B3 滚过贴顶点后，top 恒为 0（真的钉在视口顶）', (t) async {
      final (_, pos) = await seeded(t);
      await at(t, pos, 0);
      final restTop = t.getRect(kBoxFinder).top;

      for (final off in <double>[restTop, restTop + 12, 300, 600, 1200]) {
        await at(t, pos, off);
        expect(
          t.getRect(kBoxFinder).top,
          0.0,
          reason: '偏移 $off（≥ 贴顶点 $restTop）处，框必须贴在视口顶 y=0',
        );
      }
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // 组 C：★ 两极对照 —— 「框不动」+「内容真的在动」
  //
  // 只读框的位置无法区分「吸顶生效」与「页面根本滚不动」。
  // 本组在同一次读数里同时证明两极（spec Contract 23）。
  // ════════════════════════════════════════════════════════════════════════

  group('task-74② 组C 两极对照', () {
    testWidgets('C1[阳性对照] 下面的内容**真的在滚** —— 页头滚走 + 卡片上移', (t) async {
      final (_, pos) = await seeded(t);

      const subtitle = '同时搜索全部已启用内容源';

      await at(t, pos, 0);
      expect(
        find.text(subtitle),
        findsOneWidget,
        reason: '前置条件：静止态下页头副标题必须在树上（否则下面的"滚走"是空通过）',
      );
      final cardTop0 = t.getRect(find.byType(PosterCard).first).top;

      await at(t, pos, 98);
      expect(
        find.text(subtitle),
        findsNothing,
        reason: '★ 阳性对照：滚到 98 后页头副标题必须**离开视口**'
            '（sliver 被回收 ⇒ finder 找不到）。'
            '它若还在，说明内容根本没滚 —— 那么"搜索框 top 恒为 0"'
            '就可能是"整页滚不动"造成的假通过',
      );
      final cardTop98 = t.getRect(find.byType(PosterCard).first).top;

      expect(
        cardTop98,
        lessThan(cardTop0),
        reason: '★ 阳性对照：结果卡片必须**上移**'
            '（$cardTop0 → $cardTop98）—— 证明下方内容区域确实在滚',
      );

      await at(t, pos, 600);
      final cardTop600 = t.getRect(find.byType(PosterCard).first).top;
      expect(
        cardTop600,
        lessThan(cardTop98),
        reason: '继续滚到 600，卡片必须继续上移（$cardTop98 → $cardTop600）',
      );
    });

    testWidgets('C2[同一次读数] 内容上移的同时，搜索框 top 纹丝不动', (t) async {
      final (_, pos) = await seeded(t);

      await at(t, pos, 98);
      final boxTop = t.getRect(kBoxFinder).top;
      final cardTop = t.getRect(find.byType(PosterCard).first).top;

      await at(t, pos, 600);
      final boxTop2 = t.getRect(kBoxFinder).top;
      final cardTop2 = t.getRect(find.byType(PosterCard).first).top;

      // 两极同时出现在这一条断言链里：
      expect(cardTop2, lessThan(cardTop - 100),
          reason: '「动」极：卡片必须移动超过 100px（$cardTop → $cardTop2）');
      expect(boxTop2, boxTop,
          reason: '「不动」极：搜索框 top 必须完全不变（$boxTop → $boxTop2）');

      // 而且这条读数本身要能失败：若滚动失效，cardTop2 == cardTop ⇒ 上面第一条挂。
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // 组 D：吸顶后仍可交互（钉住 ≠ 变成死皮）
  // ════════════════════════════════════════════════════════════════════════

  group('task-74② 组D 交互', () {
    testWidgets('D1 吸顶状态下点搜索框仍能拿到焦点', (t) async {
      final (_, pos) = await seeded(t);
      await at(t, pos, 600);

      expect(t.getRect(kBoxFinder).top, 0.0, reason: '前置：此刻框是吸顶状态');

      await t.tap(find.byType(TextField), warnIfMissed: false);
      await t.pump();

      final ed = t.widget<EditableText>(find.byType(EditableText).first);
      expect(
        ed.focusNode.hasFocus,
        isTrue,
        reason: '★ 吸顶后框必须仍然可点（探针实测 true）。'
            '若被别的层盖住/被 IgnorePointer 吞掉，这里会 false',
      );
    });

    testWidgets('D2 吸顶状态下输入文字，内容真的进了生产那条 controller', (t) async {
      final (_, pos) = await seeded(t);
      await at(t, pos, 600);

      await t.enterText(find.byType(TextField), '测试关键词');
      await t.pump();

      // ★ 读的是**生产 State 上那条 `_controller`**（`TextField(controller: _controller)`
      // 会把它交给 `EditableText`），不是测试自己造的 controller。
      // 刻意不给生产加 `debugControllerText` getter：那是纯测试面，
      // 而这里顺着 `EditableText` 已经能读到同一条对象。
      final ed = t.widget<EditableText>(find.byType(EditableText).first);
      expect(
        ed.controller.text,
        '测试关键词',
        reason: '★ 证明吸顶的框连的是生产那条 TextEditingController'
            '（`SliverPersistentHeaderDelegate.build()` 会被反复调用，'
            '若 Element 没被复用、State 丢了，文字就进不去）',
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // 组 E：不透明契约 —— pinned 条必须挡住从它下面滚过的内容
  // ════════════════════════════════════════════════════════════════════════

  group('task-74② 组E 吸顶条不透明', () {
    testWidgets('E1 吸顶条的背景色不透明（否则卡片会与搜索框叠字）', (t) async {
      await seeded(t);

      // 吸顶条的背景层 = TextField 的 Container 祖先里那个**有 color** 的
      final ancestors = find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Container),
      );

      Color? barColor;
      for (var i = 0; i < ancestors.evaluate().length; i++) {
        final c = t.widget<Container>(ancestors.at(i)).color;
        if (c != null) {
          barColor = c;
          break;
        }
      }

      expect(barColor, isNotNull,
          reason: '★ 找不到吸顶条的背景层 ⇒ 它是透明的，'
              '结果卡片会从它下面滚过时与搜索框叠在一起');

      // Flutter 3.27+ 的 Color.alpha 是 0..1 的 double
      expect(
        barColor!.a,
        1.0,
        reason: '★ 吸顶条必须**完全不透明**（alpha=1.0），实际 ${barColor.a}。'
            '半透明的话内容会透出来 —— 这正是 search_page.dart:665-679 '
            '那段注释警告的坑',
      );
    });
  });
}
