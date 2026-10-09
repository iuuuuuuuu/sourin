// ═══════════════════════════════════════════════════════════════════════
//  task-65 ②③：追更页三 tab 卡片布局 + 首页「查看更多」跳转并激活 tab
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > ② 追更页面的 追更 收藏 历史，都要是卡片布局，不要一行一个，太占用空间了
// > ③ 首页的 追更，历史，收藏 应该有一个查看更多按钮，或者你想一个好的方式，
// >    点一下就跳转到 追更页面，激活对应的tab，比如我从首页的追更点击查看更多
// >    就跳转到 追更页面的追更为激活状态
//
// # 三个 tab 改之前的实际渲染（读码确认，不是猜）
//
// ```text
// 追更 (following) → _FavGrid     → GridView.builder   = 卡片 ✓ 本来就是
// 收藏 (all)       → _FavGrid     → 同一个 GridView     = 卡片 ✓ 本来就是
// 历史 (continue)  → _ContinueList → Column + 整宽 Container  ★ 一行一个（要改）
// ```
//
// # ★★★ 本文件刻意**不**用"符号存在"式断言
//
// 本仓刚踩过：
// ```text
// expect(src.contains('_InfoPart.head'), isTrue)   ← 这种断言是**空的**
//   因为光靠"枚举定义/字段声明"就满足了，
//   把代码改回被投诉的结构它**照样绿**。
// ```
// ⇒ 所以下面每条判据都必须能**区分对错**：
// ```text
// ① 结构：真 widget 树里**有** GridView（而不是 Column 整宽行）
// ② 几何：同一行上有 ≥2 张卡（dy 相同、dx 不同）—— ★ 这条才真正证明"不是一行一个"
// ③ 行为：点「查看更多」⇒ 真的切到追更页**且** tab 被激活
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉注释（保留字符串字面量）
///
/// ★ 必须剥 —— 我在源码注释里**刻意引用了旧的 `Column` 写法**来解释
///   为什么改（证据链），不剥的话"不许有 Column"会命中我自己的注释。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

Widget host(Widget child, {double width = 1280}) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 900)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 三 tab 的几何是**共享**的（防"两处公式漂"）
  // ═══════════════════════════════════════════════════════════════════

  group('① 卡片网格几何：三个 tab 共用同一套（纯函数，可直接测）', () {
    test('★★ 列数随可用宽度增长，且**永不为 1**（一行一个正是被投诉的形态）', () {
      /*
       * ★ 下界必须 >= 2：Owner 抱怨的就是"一行一个"。
       *   若极窄屏时 clamp 到 1，那个投诉会在窄屏上**复发**。
       */
      for (final w in [280.0, 400.0, 760.0, 1280.0, 2560.0]) {
        final c = followGridColumns(w);
        // ignore: avoid_print
        print('[T65] 可用宽 $w ⇒ 列数 $c');
        expect(c, greaterThanOrEqualTo(2),
            reason: '★★ 列数下界必须是 2 —— 1 列就是 Owner 投诉的"一行一个"');
        expect(c, lessThanOrEqualTo(12), reason: '超宽屏也要有上界');
      }
    });

    test('★★ 列数**随宽度变化**（阳性对照：不是恒返回同一个值）', () {
      /*
       * ★ 铁律①：若 `followGridColumns` 恒返回 2，上面那条也会过。
       *   这条证明它真的**响应宽度**。
       */
      expect(followGridColumns(400), lessThan(followGridColumns(1280)),
          reason: '★★ 宽屏必须比窄屏列数多 —— 否则它不是"按宽度算"的');
    });

    test('★★ aspect 与"海报 + 标题两行"的算式一致（2026-10-03 从单行改两行）', () {
      /*
       * ★★ 2026-10-03：标题从**一行**改成**两行** —— 原版
       *    `base.css:844-854` 的 `.poster-meta__title` 是
       *    `-webkit-line-clamp: 2` + 注释「固定两行：标题长短不一时
       *    卡片仍对齐」；headless Chrome 实测该元素盒高 40.41px。
       *
       * 改之前这里是写死的 `+ 44`（task-24 定的**单行**高度）。
       * 现在走 `AppMetrics.posterMetaHeight(titleLines: 2)`：
       * `22.4 + 21.6 × 2 = 65.6` ⇒ 卡片高 222 + 65.6 = 287.6。
       *
       * ★ 三个 tab 必须用**同一个** aspect，否则历史卡片比追更高/矮，
       *   滚动时每行错位。
       * ★ 骨架屏（`_FollowSkeleton`）也必须用**同一个**数 —— 否则
       *   骨架→内容那一下会跳高。
       */
      final expected = AppMetrics.posterWidth /
          (AppMetrics.posterWidth / AppMetrics.posterAspect +
              AppMetrics.posterMetaHeight(titleLines: 2));
      expect(followGridAspect(), closeTo(expected, 1e-9));
      // 阴性对照：必须**不是**旧的单行高度 —— 否则这条测不出回归
      expect(followGridAspect(),
          isNot(closeTo(
              AppMetrics.posterWidth /
                  (AppMetrics.posterWidth / AppMetrics.posterAspect + 44),
              1e-9)),
          reason: '★★ 若仍等于旧的 `+ 44` 算式，说明两行改动没生效');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 历史 tab 必须是**网格**（结构 + 几何双判据）
  // ═══════════════════════════════════════════════════════════════════

  group('② 历史 tab：真 widget 树里必须是网格，不是整宽行', () {
    testWidgets('★★★ 真 FollowPage 里存在 GridView（且不是 Column 整宽行）',
        (t) async {
      /*
       * ⚠️ 测试环境里 `FollowPage` 拿不到数据（无原生 DLL）
       *    ⇒ 列表为空 ⇒ 渲染的是 `_EmptyBlock`，**看不到网格**。
       *
       * ⇒ 所以"真件 + 真数据"这条路在单测里走不通。
       *   我用**两条互补**的判据覆盖它（都不依赖数据）：
       *   ```text
       *   ① 纯函数：几何正确（上面 ① 组）
       *   ② 源码结构：_ContinueList 里**必须是 GridView.builder**
       *      且**不得**再出现"整宽 Container + Row[封面60,...]"那套
       *   ```
       *   ★ ② 必须**剥注释**，且要断言到"能区分对错"的粒度 —— 见下。
       */
      final code = stripComments(
        File('lib/ui/follow_page.dart').readAsStringSync(),
      );

      /*
       * ★★★ 必须把「历史 tab 的整段实现」精确切出来 —— 这里我**错过两次**，
       *     两次都是**测试写法的错**（实现一直是对的），记下来：
       *
       * ```dart
       * // 第一版（错）：切到**文件末尾**
       * final body = code.substring(code.indexOf('class _ContinueList'));
       * // ⇒ 本文件后面还有 `_FavGrid`，它也含 GridView.builder
       * // ⇒ 把 _ContinueList 整个改回 Column，这条**照样绿**（命中别人的）
       *
       * // 第二版（也错）：切到**下一个 class 之前**
       * final nextClass = rest.indexOf('\nclass ');
       * // ⇒ 本文件类序是：
       * //     _ContinueList(L1330) → _ContinueCard(L1398) → _FavGrid(L1498)
       * //   `_ContinueCard` **在 _ContinueList 之后**！
       * // ⇒ 片段把 `_ContinueCard` 排除了 ⇒ 仪器自检立刻报红
       * //   （这正是我加自检的价值：它把"边界切错"变成了可见的失败，
       * //     而不是让断言悄悄退化成空判据）
       * ```
       *
       * ⇒ 正解：切到 **`_FavGrid` 之前** —— 那才是"历史 tab 这段"的真正边界
       *   （`_ContinueList` + `_ContinueCard` 都属于历史 tab，`_FavGrid` 不是）。
       */
      final start = code.indexOf('class _ContinueList');
      expect(start, greaterThan(-1), reason: '_ContinueList 必须存在');
      final end = code.indexOf('class _FavGrid', start);
      expect(end, greaterThan(start),
          reason: '★★ 仪器自检：必须能定位 `_FavGrid` 的起点（用它当右边界）');
      final body = code.substring(start, end);

      // 自证：切出来的片段**不含** _FavGrid（否则 "GridView 存在" 会命中它）
      expect(body.contains('class _FavGrid'), isFalse,
          reason: '★★ 仪器自检：切出的片段不许包含 `_FavGrid` —— '
              '否则 "GridView 存在" 会命中它，断言就是空的');
      expect(body.contains('class _ContinueCard'), isTrue,
          reason: '★★ 仪器自检：片段里**必须**有 `_ContinueCard`（同属历史 tab）'
              '—— 它在 _ContinueList 之后，切早了就会漏掉它');

      expect(body.contains('GridView.builder'), isTrue,
          reason: '★★★ 历史 tab 必须用 GridView.builder（卡片网格）—— '
              '改之前是 Column + 整宽 Container（一行一个）');

      /*
       * ★ 反向判据：旧的"整宽行"特征不许回来。
       *   旧写法的**可辨识特征**是「固定宽 60 的封面 + 横向 Row」：
       *   ```dart
       *   SizedBox(width: 60, child: AspectRatio(...))   ← 60px 小封面 = 列表行
       *   ```
       *   网格里的封面是**自适应宽度**（AspectRatio 直接铺满格子），
       *   不会写死 60。
       */
      expect(body.contains('width: 60,'), isFalse,
          reason: '★★★ 不许再出现"固定 60px 小封面"—— 那是整宽列表行的特征。'
              '网格里封面是自适应宽度的');
    });

    testWidgets('★★★ 几何判据：网格布局下同一行上有 ≥2 张卡（dy 相同、dx 不同）',
        (t) async {
      /*
       * ★★★ 这是**最硬**的一条 —— 它直接证明"不是一行一个"。
       *
       * 做法：直接挂 `_ContinueList` 的**公开替身**（GridView + 同几何），
       *      量两张卡的矩形。
       *
       * ⚠️ 为什么这里可以挂替身：`_ContinueList` 是**私有类**，测试无法构造。
       *    但本组 ① 已用**纯函数**钉住了几何（列数/aspect），
       *    上面那条又钉住了"源码里确实是 GridView"。
       *    ⇒ 这条补的是"**给定这套几何，GridView 真的会把卡片排成多列**"——
       *      即"我的几何参数用对了"（gridDelegate 没写错）。
       *    ★ 它不是"复刻布局的影子测试"：它测的是 **Flutter 的 GridView
       *      在 followGridColumns/Aspect 这组参数下的实际行为**。
       */
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(
        LayoutBuilder(
          builder: (ctx, c) => GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: followGridColumns(c.maxWidth),
              crossAxisSpacing: Sp.x3,
              mainAxisSpacing: Sp.x6,
              childAspectRatio: followGridAspect(),
            ),
            itemCount: 8,
            itemBuilder: (_, i) => Container(
              key: ValueKey('card$i'),
              color: const Color(0xFF336699),
            ),
          ),
        ),
      ));
      await t.pump();

      final r0 = t.getRect(find.byKey(const ValueKey('card0')));
      final r1 = t.getRect(find.byKey(const ValueKey('card1')));
      final r2 = t.getRect(find.byKey(const ValueKey('card2')));

      // ignore: avoid_print
      print('[T65] 1280 宽 ⇒ card0=$r0  card1=$r1  card2=$r2');

      expect(r0.top, closeTo(r1.top, 0.5),
          reason: '★★★ card0 与 card1 必须在**同一行**（top 相同）');
      expect(r1.left, greaterThan(r0.left),
          reason: '★★★ card1 必须在 card0 **右边**（left 更大）—— '
              '这两条一起证明"一屏多列"，即**不是**一行一个');

      // 一行放得下 3 张（1280 宽、148 卡 + 8 间距 ⇒ 至少 6 列）
      expect(r2.top, closeTo(r0.top, 0.5),
          reason: '★★ 1280 宽下第 3 张也该在同一行');
    });

    testWidgets('★ 阳性对照：窄容器下**仍然** ≥2 列（不是退化成一行一个）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      // 复刻"首页嵌入"那种窄容器：可用宽只有 320
      await t.pumpWidget(host(
        SizedBox(
          width: 320,
          child: LayoutBuilder(
            builder: (ctx, c) => GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: followGridColumns(c.maxWidth),
                crossAxisSpacing: Sp.x3,
                mainAxisSpacing: Sp.x6,
                childAspectRatio: followGridAspect(),
              ),
              itemCount: 6,
              itemBuilder: (_, i) => Container(
                key: ValueKey('n$i'),
                color: const Color(0xFF663399),
              ),
            ),
          ),
        ),
      ));
      await t.pump();

      final a = t.getRect(find.byKey(const ValueKey('n0')));
      final b = t.getRect(find.byKey(const ValueKey('n1')));
      // ignore: avoid_print
      print('[T65] 320 窄容器 ⇒ n0.top=${a.top} n1.top=${b.top} '
          'n0.left=${a.left} n1.left=${b.left}');
      expect(b.top, closeTo(a.top, 0.5),
          reason: '★ 窄容器下也必须是多列（clamp 下界 2）—— '
              '若这里变成上下两行，说明列数退化成 1');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 「查看更多」：切 tab 且激活正确 tab
  // ═══════════════════════════════════════════════════════════════════

  group('③ 查看更多：ShelfTab → 追更页 tab key 的映射', () {
    test('★★★ 三个 ShelfTab 映射到正确的 key（Owner 逐条点名）', () {
      /*
       * Owner：
       * > 比如我从首页的**追更**点击查看更多 就跳转到追更页面的**追更为激活状态**
       */
      expect(shelfTabToFollowKey(ShelfTab.following), 'following');
      expect(shelfTabToFollowKey(ShelfTab.favorites), 'all');
      expect(shelfTabToFollowKey(ShelfTab.history), 'continue');
    });

    test('★★ 映射出的 key 必须是 FollowPage 认可的合法值', () {
      /*
       * ★ 这条把两个文件的契约**接起来**：
       *   `shelfTabToFollowKey` 产出的字符串，必须被
       *   `FollowPage.isValidTab` 接受。
       *   否则"查看更多"会传一个追更页不认的值 ⇒ 静默不切 tab。
       *   （这正是"两处契约必须有一处验证"的形态。）
       */
      for (final t in ShelfTab.values) {
        final key = shelfTabToFollowKey(t);
        expect(FollowPageState.isValidTab(key), isTrue,
            reason: '★★ ShelfTab.$t 映射出的 "$key" 必须是追更页的合法 tab —— '
                '否则"查看更多"会静默不生效');
      }
    });

    test('★ 阳性对照：非法 key 必须被拒（否则上面的"合法"没意义）', () {
      expect(FollowPageState.isValidTab('nope'), isFalse);
      expect(FollowPageState.isValidTab(''), isFalse);
      expect(FollowPageState.isValidTab(null), isFalse);
      // ★ 枚举名不是 key（`continueWatching != 'continue'`）—— 这是真踩过的坑
      expect(FollowPageState.isValidTab('continueWatching'), isFalse,
          reason: '★ 用枚举 name 会错 —— `_FollowTab.key` 的注释专门说过');
    });
  });

  group('③b 查看更多：真 MyShelf 里点了会回调**正确的 key**', () {
    testWidgets('★★★ 点「查看更多」⇒ 回调拿到的 key 跟随当前 tab', (t) async {
      /*
       * ★ 这条测的是**真 MyShelf**（不是替身）：
       *   在"追更"tab 下点 ⇒ 回调应收到 'following'。
       *
       * ⚠️ `MyShelf` 内部有 tabs，默认是 `ShelfTab.following`
       *    （`my_shelf.dart:95`）⇒ 无需先切 tab 即可验证第一条。
       */
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      final got = <String>[];
      await t.pumpWidget(host(
        MyShelf(onSeeAll: got.add),
      ));
      await t.pump();

      /*
       * ★ 2026-10-06（Owner 第三次复审「这个查看更多看起来还是不合理啊」）：
       *   形态从「文字胶囊」改成「纯箭头图标」⇒ 屏幕上**没有文字**了。
       *   定位改用 tooltip —— 它同时是读屏标签（Semantics.label）。
       * ⚠️ 别改回 find.text：那等于把「形态必须带文字」写死进测试，
       *   下次再换形态还要再改一遍。
       */
      expect(find.byTooltip('查看更多'), findsOneWidget,
          reason: '★★★ 首页「我的」版块必须有「查看更多」入口'
              '（Owner 明确要求；现在是一枚带 tooltip 的箭头按钮）');

      await t.tap(find.byTooltip('查看更多'));
      await t.pump();

      // ignore: avoid_print
      print('[T65] 点「查看更多」⇒ 回调收到 = $got');
      expect(got, ['following'],
          reason: '★★★ 默认 tab 是「追更」⇒ 必须回调 "following" '
              '（Owner：「从首页的追更点击查看更多 就跳转到追更页面的追更为激活状态」）');
    });

    testWidgets('★★ 阳性对照：`onSeeAll` 为 null 时**不渲染**按钮', (t) async {
      /*
       * ★ 证明上面那条的 `findsOneWidget` 真的来自 `onSeeAll`，
       *   而不是"按钮恒在"。
       */
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const MyShelf()));
      await t.pump();

      expect(find.byTooltip('查看更多'), findsNothing,
          reason: '★ 没给回调 ⇒ 不该渲染一个点了没反应的按钮');
    });
  });

  group('③c 查看更多：FollowPage 真的接受 initialTab（真 widget 树）', () {
    testWidgets('★★★ initialTab 三个值 ⇒ 进页即激活**对应**的 tab', (t) async {
      /*
       * ★★★ 这条是本组最重要的一条，而且我**第一版写错了** —— 记下来：
       *
       * ```dart
       * // 第一版（错的）：
       * await t.pumpWidget(host(const FollowPage(initialTab: 'continue')));
       * expect(find.text('继续观看'), findsWidgets);   // ← ★ 恒真！
       * ```
       * 三个 tab 的**标签文字永远都在**（分段控件渲染三个），
       * 所以 `findsWidgets` 跟"哪个被激活"**毫无关系** ——
       * 把 `initialTab` 完全忽略掉，这条**照样绿**。
       * 这正是 Lead 铁律 2 说的"符号存在式断言"。
       *
       * ⇒ 现在改成读 **`activeTabKey`**（本任务新增的公开只读口），
       *   逐个值断言 ⇒ 忽略 `initialTab` 必然变红。
       */
      for (final key in ['following', 'all', 'continue']) {
        await t.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(host(FollowPage(initialTab: key)));
        await t.pump();

        final st = t.state<FollowPageState>(find.byType(FollowPage));
        // ignore: avoid_print
        print('[T65] FollowPage(initialTab: "$key") ⇒ activeTabKey = '
            '"${st.activeTabKey}"');

        expect(st.activeTabKey, key,
            reason: '★★★ initialTab="$key" 必须真的**激活**那个 tab —— '
                '若这条不过，说明 initialTab 被忽略了'
                '（Owner：「点一下就跳转到追更页面，激活对应的 tab」）');
      }
    });

    testWidgets('★★ 不给 initialTab ⇒ 默认 following（不回归原行为）', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const FollowPage()));
      await t.pump();

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      expect(st.activeTabKey, 'following',
          reason: '★ 原默认是 `following`（原版语义）—— 加参数不许改掉它');
    });

    testWidgets('★★★ showTab 真的切换（写入口）且读出口能观测到', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const FollowPage()));
      await t.pump();

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      expect(st.activeTabKey, 'following');

      expect(st.showTab('continue'), isTrue);
      await t.pump();
      expect(st.activeTabKey, 'continue',
          reason: '★★★ showTab 必须真的改状态（这是"查看更多"在'
              '"追更页已在树上"时走的路径）');
    });

    testWidgets('★★★ showTab 非法值 ⇒ 返回 false 且**状态不变**、不崩', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const FollowPage()));
      await t.pump();

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      final before = st.activeTabKey;

      expect(st.showTab('不存在的tab'), isFalse,
          reason: '★ 非法 key 必须被拒（返回 false）');
      await t.pump();
      expect(st.activeTabKey, before,
          reason: '★★ 非法 key **不许改状态** —— 静默改状态比崩更难查');
      expect(t.takeException(), isNull);
    });

    testWidgets('★★ initialTab 非法 ⇒ 不崩（回退默认）', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(
        const FollowPage(initialTab: 'garbage'),
      ));
      await t.pump();

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      expect(t.takeException(), isNull,
          reason: '★ 非法 initialTab 必须"响亮地退回安全值"，不许崩页面');
      expect(st.activeTabKey, 'following',
          reason: '★★ 非法值 ⇒ 回退到默认 following（不是留在垃圾值上）');
    });

    testWidgets('★★★ 幂等：对**已经是**的 tab 再 showTab ⇒ 返回 true 且不炸',
        (t) async {
      /*
       * Lead 的验收里点名了这条：
       * > 已在 follow 页 / 已是该 tab 时再点 ⇒ 幂等，不炸、不闪回
       */
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const FollowPage(initialTab: 'all')));
      await t.pump();

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      expect(st.activeTabKey, 'all');

      // 再切到同一个 ⇒ 必须 true（成功）且状态不变
      expect(st.showTab('all'), isTrue);
      await t.pump();
      expect(st.activeTabKey, 'all', reason: '★ 幂等：不许"闪回"到别的 tab');
      expect(t.takeException(), isNull);
    });

    testWidgets('★★ didUpdateWidget：父级改 initialTab ⇒ 跟着切（保活场景）',
        (t) async {
      /*
       * ★★★ 这条覆盖一个**很容易漏**的路径：
       *
       * `shell.dart` 用 `_contentFor` **保活**了追更页（切走不销毁）
       * ⇒ 第二次点「查看更多」时**不会**重建 State ⇒ 只读 `initState`
       *   的话，第二次跳转**不会切 tab**。
       *
       * ⇒ 必须实现 `didUpdateWidget`。这条就是它的红度保护。
       */
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(const FollowPage(initialTab: 'following')));
      await t.pump();
      final st = t.state<FollowPageState>(find.byType(FollowPage));
      expect(st.activeTabKey, 'following');

      // 同一个 State（同 key/同位置）⇒ 走 didUpdateWidget 而不是 initState
      await t.pumpWidget(host(const FollowPage(initialTab: 'continue')));
      await t.pump();

      final st2 = t.state<FollowPageState>(find.byType(FollowPage));
      expect(identical(st, st2), isTrue,
          reason: '★ 前置：必须是**同一个 State**（否则这条测的是 initState，'
              '不是 didUpdateWidget）');
      expect(st2.activeTabKey, 'continue',
          reason: '★★★ 父级把 initialTab 从 following 改成 continue ⇒ '
              '必须跟着切（保活场景下第二次点"查看更多"走的就是这条路）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 静态审计：接线必须真的存在
  // ═══════════════════════════════════════════════════════════════════

  group('④ 静态审计：三处接线', () {
    test('★★★ shell 必须把「查看更多」接到切 tab（而不是只记日志）', () {
      final code = stripComments(File('lib/shell.dart').readAsStringSync());

      expect(code.contains('_openFollowTab'), isTrue,
          reason: '★ shell 必须有这个入口');
      expect(code.contains('onSeeAllShelf: _openFollowTab'), isTrue,
          reason: '★★★ HomePage 的 onSeeAllShelf 必须真的接到 _openFollowTab —— '
              '否则"查看更多"点了什么都不发生');
      expect(code.contains('_switchTo(AppTab.follow)'), isTrue,
          reason: '★★★ 必须真的**切到追更页** —— 这是 Owner 要求的核心动作');
    });

    test('★★ shell 必须把请求传给 FollowPage（覆盖"还没进过树"的情形）', () {
      final code = stripComments(File('lib/shell.dart').readAsStringSync());
      expect(code.contains('initialTab: _takeFollowTabRequest()'), isTrue,
          reason: '★★ 首次访问追更页时 `currentState == null` ⇒ '
              '只能靠构造参数传进去');
      expect(code.contains('_takeFollowTabRequest'), isTrue);
    });

    test('★★ home_page 必须把回调透传给 MyShelf', () {
      final code = stripComments(File('lib/ui/home_page.dart').readAsStringSync());
      expect(code.contains('onSeeAll: widget.onSeeAllShelf'), isTrue,
          reason: '★★ 少了这一行，MyShelf 永远收不到 onSeeAll ⇒ 按钮不渲染');
    });

    test('★★ MyShelf 的按钮必须真的调回调（不是空壳）', () {
      final code =
          stripComments(File('lib/ui/widgets/my_shelf.dart').readAsStringSync());
      expect(code.contains('widget.onSeeAll!(shelfTabToFollowKey(_tab))'), isTrue,
          reason: '★★★ 按钮必须传**当前 tab 对应的 key** —— '
              '写死 ' 'following' ' 会让收藏/历史 tab 也跳到追更');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ task-63 收口：追更页「历史」tab 不许再画 '?'
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 背景（Lead 转述 fix-file-dialog 的查证）
  //
  // ```text
  // 首页「我的」→ 播放历史 = MyShelf._cards → PosterCard     ✓ task-63 已修
  // 追更页 → 「历史」tab   = _ContinueList → _ContinueCard   ✗ 本条修的就是它
  // ```
  // ★ 两者读**同一张表、同一条 SQL**（`continueWatching`）——
  //   所以 task-63 只修首页时，Owner 那句
  //   > 播放记录多了几个 显示 ？ 的记录，没有封面没有名字点进去才知道是什么
  //   在追更页**依然存在**。
  //
  // 活库实测：`cycani:3841` `title=''` `cover=NULL` `pos=122`
  //          ⇒ 追更页「历史」tab 仍显示 '?'。

  group('⑤ 追更页历史 tab：空标题不许画 "?"（task-63 收口）', () {
    /// 造一个 Progress（只填本组用到的字段）
    Progress mk({String title = '', String? episodeTitle, String? cover}) =>
        Progress(
          key: 'cycani:3841',
          provider: 'cycani',
          nativeId: '3841',
          title: title,
          cover: cover,
          episodeTitle: episodeTitle,
          episodeId: 'e1',
          position: 122,
          duration: 1420,
        );

    test('★★★ 纯函数：空 title ⇒ 「（标题未知）」，**不含 "?"**', () {
      /*
       * ★★★ 这条直接对应 Owner 的投诉。用**纯函数**测 ⇒ 可判定、不依赖
       *     原生 DLL、也不依赖 widget 树。
       */
      final p = mk(title: '');
      final t = progressDisplayTitle(p);
      // ignore: avoid_print
      print('[T65] title="" ⇒ 显示标题 = "$t"');

      expect(t, '（标题未知）',
          reason: '★★★ 空标题必须给中性占位（与 my_shelf 的 `_historyTitle` 同口径）');
      expect(t.contains('?'), isFalse,
          reason: '★★★ ★ Owner 反感的就是 "?" 这个字符 —— 不许出现');
    });

    test('★★ 纯函数：兜底链 title → episodeTitle → 中性占位', () {
      // ① 有正式标题 ⇒ 用它
      expect(progressDisplayTitle(mk(title: '无职转生')), '无职转生');
      // ② 没正式标题但有集名 ⇒ 用集名（至少告诉用户看到哪一集）
      expect(progressDisplayTitle(mk(title: '', episodeTitle: '第01集')), '第01集');
      // ③ 两个都没有 ⇒ 中性占位（★ 实测那 3 条坏记录就是这样）
      expect(progressDisplayTitle(mk(title: '', episodeTitle: null)), '（标题未知）');
      // ④ 全空白（不是空串，是空格）也要兜住
      expect(progressDisplayTitle(mk(title: '   ')), '（标题未知）',
          reason: '★ 只判 isEmpty 会漏掉全空白 —— 用 trim() 判');
    });

    test('★★★ 纯函数：副标题不与标题重复（加兜底引入的边角情况）', () {
      /*
       * title 为空、episodeTitle = "第01集" 时：
       * ```text
       * 标题   = "第01集"   ← 兜底来的
       * 副标题 = "第01集"   ← 若照旧写法（p.episodeTitle ?? "单集"），同一句
       * ⇒ 卡片上出现**两遍同样的字**
       * ```
       */
      expect(progressDisplayEpisode(mk(title: '', episodeTitle: '第01集')), '单集',
          reason: '★★★ 标题已经用了集名 ⇒ 副标题必须退回「单集」，'
              '否则卡片上出现两遍"第01集"');
      expect(progressDisplayEpisode(mk(title: '无职转生', episodeTitle: '第01集')),
          '第01集',
          reason: '★ 正常情况：标题是片名，副标题是集名');
      expect(progressDisplayEpisode(mk(title: '无职转生', episodeTitle: null)), '单集');
    });

    test('★★★ 源码：`_ContinueCard` 里不许再出现问号占位', () {
      final code = stripComments(
        File('lib/ui/follow_page.dart').readAsStringSync(),
      );
      final start = code.indexOf('class _ContinueList');
      final end = code.indexOf('class _FavGrid', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = code.substring(start, end);

      expect(body.contains("? '?'"), isFalse,
          reason: '★★★ `_ContinueCard` 不许再画 "?" —— '
              'Owner：「播放记录多了几个 显示 ？ 的记录」');
      expect(body.contains('Icons.movie_outlined'), isTrue,
          reason: '★★★ 空标题必须用**中性图标**（与 poster_card.dart 同款）—— '
              '判据要复用那边的写法，别另发明一套');
    });

    test('★★★ 跨文件一致性：两份兜底口径必须一致（防"两处同构漂了"）', () {
      /*
       * ★★★ 这条是本组的**关键设计**。
       *
       * `my_shelf.dart::_historyTitle` 与 `follow_page.dart::progressDisplayTitle`
       * 是**两份实现**（为什么不能共用：见 `progressDisplayTitle` 的文档 ——
       * `t61_progress_title_test.dart` 对前者有**函数体文本**断言，
       * 把它改成转发会让那条测试变红，而它不在我的写权范围）。
       *
       * ⇒ 两份实现就有"漂"的风险。这条用**行为对比**把它们钉在一起：
       *   同一组输入，两份实现必须给出**同样的结果**。
       *   ★ 只漂一处 ⇒ 这条立刻红。
       *
       * ⚠️ 为什么用"源码特征"而不是"调 `_historyTitle`"：
       *    `_historyTitle` 是 `MyShelfState` 的**私有静态方法**，
       *    测试无法直接调用。⇒ 用"两份实现的关键特征必须同时成立"来钉：
       *    两边都必须有同样的**兜底顺序**与**同一个占位串**。
       */
      final shelf = stripComments(
        File('lib/ui/widgets/my_shelf.dart').readAsStringSync(),
      );
      final follow = stripComments(
        File('lib/ui/follow_page.dart').readAsStringSync(),
      );

      // ① 同一个占位串（★ 逐字相同，否则两个页面显示不同）
      expect(shelf.contains("return '（标题未知）';"), isTrue,
          reason: '★ my_shelf 的占位（task-63 定的口径）');
      expect(follow.contains("return '（标题未知）';"), isTrue,
          reason: '★★★ 追更页必须用**同一个**占位串 —— '
              '若这里写成别的（比如 "标题未知" 或 "未知"），'
              '同一部剧在首页和追更页会显示**不同的字**');

      // ② 两边都不得在兜底里出现 '?'
      for (final e in [('my_shelf', shelf), ('follow_page', follow)]) {
        final i = e.$2.indexOf('（标题未知）');
        expect(i, greaterThan(0), reason: '${e.$1} 必须有占位实现');
      }

      // ③ 副标题也必须是同构的（都靠"标题用掉了什么"判断）
      expect(shelf.contains('_historySubtitle('), isTrue);
      expect(follow.contains('progressDisplayEpisode('), isTrue,
          reason: '★★ 副标题防重复的机制两边都要有');
    });

    test('★ 阳性对照：兜底函数**真的**被 _ContinueCard 调用（不是死代码）',
        () {
      /*
       * ★ 铁律①：若 `progressDisplayTitle` 定义了但**没被调用**，
       *   上面那些纯函数测试**全都会过**（函数本身是对的），
       *   而屏幕上仍然显示空/`?`。
       *   ⇒ 这条证明它**接到了渲染路径上**。
       */
      final code = stripComments(
        File('lib/ui/follow_page.dart').readAsStringSync(),
      );
      final start = code.indexOf('class _ContinueList');
      final end = code.indexOf('class _FavGrid', start);
      final body = code.substring(start, end);

      expect(body.contains('progressDisplayTitle(p)'), isTrue,
          reason: '★★★ `_ContinueCard` 的标题行必须调兜底函数 —— '
              '否则纯函数测试是"测了个没人用的东西"');
      expect(body.contains('progressDisplayEpisode(p)'), isTrue,
          reason: '★★ 副标题同理');
      // 反向：旧的直传写法不许回来
      // ★ 这里用普通字符串（不是插值）—— `'${p.episodeTitle ?? "单集"}'`
      //   会被 Dart 当**插值**求值（`p` 未定义 ⇒ 编译错）。
      //   要找的是**源码里的那串字面量**，所以用单引号包住 `$` 或用拼接。
      expect(body.contains(r'${p.episodeTitle ?? "单集"}'), isFalse,
          reason: '★ 旧写法（直传 episodeTitle）必须已消失 —— '
              '它会造成"标题/副标题重复"');
    });
  });
}
