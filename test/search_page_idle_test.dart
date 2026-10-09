// ═══════════════════════════════════════════════════════════════════════
//  搜索页「未搜索」空态 + 搜索按钮启用态 —— 回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// 对应原版 cctv_to_client/src/views/SearchView.vue:365-371：
//
//   <!-- 未搜索 -->
//   <EmptyState v-else-if="!searched" :icon="icons.search"
//               title="搜索全部内容源" desc="输入关键词后回车即可同时搜索" />
//
// # 为什么必须有这个文件
//
// 真机上量到（.probe/phone-verify/a71_search_idle.xml、a66_typed_2026.xml）：
//   · 搜索框下面是**空的** —— 空档 1576 px = 600.4 dp（该分支在 Dart 侧不存在）
//   · 输入框里明明有字，「搜索」按钮仍是 enabled="false" clickable="false"
//     ⇒ 点下去被吞掉（.probe/phone-verify/k4_kbsubmit 前后像素差 = 0）
//
// # 三个坑（本文件就是为了钉死它们）
//
// ① slivers: 里只能放 Sliver —— 空态必须包在 SliverToBoxAdapter 里。
//    直接塞一个 Column 是**运行时崩**，不是编译错。见 A3。
// ② _totalProviders == 0 会挡住整个结果区（build 的第一个分支）。
//    flutter test 里没有核心 DLL ⇒ listProviders() 必抛 ⇒ 恒为 0
//    ⇒ 必须用生产代码里既有的 debugSetProviderCount 补环境前置条件。
//    见 fixture() 里那条反向断言。
// ③ TextField 的 onChanged 缺失时，_controller.text 变了但 build 不重跑
//    ⇒ 按钮启用态 / ✕ 永远是旧的。B 组直接断言**按钮的 onPressed**，
//    而不是断言「输入框里有字」（后者恒真，钉不住任何东西）。
//
// ⚠️ 本文件不挂真 Player、不调 open()、不用 toImage() —— 同 t75_search_pinned_test.dart。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

/// 探针实测用的视口 —— 与 `t75_search_pinned_test.dart` 同尺寸，逐值可比。
const Size kViewport = Size(1400, 900);

Widget host(Widget child, Size size) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

/// 造好一个「没搜过、但有 4 个可用源」的搜索页。
///
/// ⚠️ `debugSetProviderCount(4)` **不是**可选的：
///    `flutter test` 里 `listProviders()` 必然抛异常（无核心 DLL），
///    `_totalProviders` 恒为 0 ⇒ `build` 在**第一个分支**就渲染
///    「当前没有支持搜索的内容源」，把空态/按钮那几段全挡住 ⇒
///    下面所有断言都会退化成对**空树**的断言（恒真，钉不住任何东西）。
Future<SearchPageState> fixture(WidgetTester t) async {
  t.view.physicalSize = kViewport;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  await t.pumpWidget(host(const SearchPage(), kViewport));
  await t.pump();

  final st = t.state<SearchPageState>(find.byType(SearchPage));
  st.debugSetProviderCount(4);
  await t.pump();

  // ★ 反向断言：确认第一个分支真的没在挡路。
  expect(
    find.textContaining('当前没有支持搜索的内容源'),
    findsNothing,
    reason: '源数为 0 时 build 会在第一个分支就吃掉整段结果区 —— '
        '那时本文件所有断言都是对空树断言，全部假通过',
  );

  return st;
}

/// 「搜索」那个 `FilledButton`（全页**只有**一个：搜索框右侧那个）。
FilledButton searchButton(WidgetTester t) =>
    t.widget<FilledButton>(find.byType(FilledButton));

void main() {
  // ════════════════════════════════════════════════════════════════════
  // 组 A：未搜索空态
  // ════════════════════════════════════════════════════════════════════

  group('搜索页未搜索空态', () {
    testWidgets('A1 未搜索时显示空态引导（标题 + 说明）', (t) async {
      await fixture(t);

      expect(find.text('搜索全部内容源'), findsOneWidget,
          reason: '原版 SearchView.vue:365-371 EmptyState 的 title');
      expect(find.text('输入关键词后回车即可同时搜索'), findsOneWidget,
          reason: '原版同一条 EmptyState 的 desc');
      expect(find.byIcon(Icons.search), findsWidgets,
          reason: '空态图标是 Icons.search（搜索框左边那个也是它，所以是 findsWidgets）');
    });

    testWidgets('A2 未搜索时不显示「没有找到相关内容」', (t) async {
      await fixture(t);

      expect(find.text('没有找到相关内容'), findsNothing,
          reason: '还没搜就报「没找到」是误报 —— 两者是不同的语义分支');
      expect(find.textContaining('个结果'), findsNothing,
          reason: '一个源都还没回来，不可能有结果组');
    });

    testWidgets('A3 空态是 Sliver（不是盒模型孩子）', (t) async {
      await fixture(t);

      expect(
        find.ancestor(
          of: find.text('搜索全部内容源'),
          matching: find.byType(SliverToBoxAdapter),
        ),
        findsOneWidget,
        reason: 'slivers: 里只能放 Sliver。若把空态写成裸 Column，'
            'CustomScrollView 会在**运行时**抛断言（不是编译错）',
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // 组 B：输入后按钮启用 + ✕ 出现
  // ════════════════════════════════════════════════════════════════════

  group('搜索按钮启用态', () {
    testWidgets('B1 未输入：按钮 onPressed == null，且没有 ✕', (t) async {
      await fixture(t);

      expect(searchButton(t).onPressed, isNull,
          reason: '空关键词搜索是空操作 ⇒ 按钮应当是禁用态');
      expect(find.byIcon(Icons.close), findsNothing,
          reason: '没内容可清空时不该出现 ✕');
    });

    testWidgets('B2 输入后：按钮 onPressed != null，且 ✕ 出现', (t) async {
      await fixture(t);

      await t.enterText(find.byType(TextField), 'x');
      await t.pump();

      expect(searchButton(t).onPressed, isNotNull,
          reason: '★ 这一条就是真机上「按钮常灰、点了没反应」的回归闸门：'
              '没有 onChanged 时 build 不重跑，onPressed 会一直是 null');
      expect(find.byIcon(Icons.close), findsOneWidget,
          reason: '★ 同一个重建问题：if (_controller.text.isNotEmpty) 也不会重算');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // 组 C：清空后回到初始态
  // ════════════════════════════════════════════════════════════════════

  group('清空回退', () {
    testWidgets('C1 点 ✕ 清空：按钮回到禁用、✕ 消失、空态回来', (t) async {
      await fixture(t);

      await t.enterText(find.byType(TextField), 'x');
      await t.pump();
      expect(searchButton(t).onPressed, isNotNull);

      await t.tap(find.byIcon(Icons.close));
      await t.pump();

      expect(searchButton(t).onPressed, isNull,
          reason: '清空后 _controller.text 为空 ⇒ 按钮必须回到禁用');
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('搜索全部内容源'), findsOneWidget,
          reason: '_clear() 把 _searched 也复位 ⇒ 空态必须回来');
    });

    testWidgets('C2 只有空白字符时按钮仍禁用', (t) async {
      await fixture(t);

      await t.enterText(find.byType(TextField), '   ');
      await t.pump();

      expect(searchButton(t).onPressed, isNull,
          reason: '判据是 _controller.text.trim().isEmpty ⇒ 纯空格不算关键词');
      expect(find.byIcon(Icons.close), findsOneWidget,
          reason: '✕ 的判据是 text.isNotEmpty（不 trim）—— 空格也是内容');
    });
  });
}
