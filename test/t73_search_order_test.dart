// test/t73_search_order_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
// task-73：搜索结果按**匹配度**排序
// ══════════════════════════════════════════════════════════════════════════
//
// Owner 原话：
//   「搜索的结果,应该也按照匹配度往下排序,而不是不沾边的排第一,
//     匹配度高的却在下面」
//
// # 判据
// ```text
//   匹配度 = titleSimilarity(keyword, item.title)     ← lib/core/title_match.dart
//   组间分 = 组内**最高**分（bestTitleScore）
//   组间 / 组内都是**降序**；**同分保持到达顺序**（稳定排序）
// ```
//
// # 本文件刻意遵守的两条纪律
//
// ① **断言结构，不读符号**（本仓铁律）。
//    `expect(src.contains('rankHitGroups'), isTrue)` 这种"符号存在"式断言是
//    **空的** —— 它只证明名字出现过，不证明顺序对。
//    ⇒ 主力断言是**真 widget 树上的几何顺序**：把结果喂进真的 `SearchPage`，
//      用 `tester.getRect` 读每张卡的坐标，按 (top, left) 排出**阅读顺序**，
//      再和硬编码的期望顺序比对。
//
// ② **期望顺序是独立算出来的，不是用被测函数反推的**。
//    期望分数由 `.probe/t73_scores.py`（Python 独立复刻同一套 bigram
//    Jaccard 算法）算出，见 `.probe/t73_scores.txt`：
//    ```text
//      1.000000  鬼灭之刃
//      0.500000  鬼灭之刃 粤配版
//      0.428571  鬼灭之刃 柱训练篇
//      0.071429  鬼灭食堂32（杀死武赞的方法）
//      0.000000  不好，放错图片了
//    ```
//    ⇒ 若测试用 `stableRankDesc` 自己算一遍再来当期望，那是**循环论证**：
//      函数错了，期望也跟着错，测试照样绿。
//    另外每条夹具的分数都**单独断言**一次（见 ①-0），这样夹具一旦漂移
//    （比如有人改了 `titleSimilarity` 的算法）会立刻红，而不是悄悄换一套顺序。
//
// # 夹具全部来自真机返回
//    `.probe/t71_real_search.json`（关键词「鬼灭之刃」，35 条真实条目），
//    标题逐字取自该文件（见 `.probe/t73_fixture_dump.txt`）。
//
// # 为什么需要 `debugSetProviderCount` + `debugBeginSearch` + `debugFeedHit`
//   真实结果来自 `SourinApi.searchAllStream()`（FFI 到 Rust 核心）。
//   `flutter test` 里**没有核心 DLL** ⇒ 两个后果：
//   ```text
//     listProviders() 抛异常 ⇒ _totalProviders 恒为 0
//       ⇒ build 里 `if (_totalProviders == 0)` 那句"当前没有支持搜索的内容源"
//         会**挡住整个结果区** ⇒ 结果区永远不渲染
//     searchAllStream() 抛异常 ⇒ _hits 恒为空
//   ```
//   ⇒ 三个注入口分别补上真实链路里对应那一段的**前置条件**
//     （`_loadProviderCount` / `_doSearch` 开头 / `hit` 分支），
//     **不改任何渲染或排序逻辑**：
//     喂进去的事件仍然走真的 `_addHit` ⇒ 真的 `rankHitGroups`
//     ⇒ 真的 `_ResultGroup` 渲染。
//
// # 铁律 149
//   「候选集为空时，全称断言恒真」—— 所以下面每条几何断言都先断言
//   **卡真的渲染出来了**（`found == 1`），再断言顺序。否则"排对了"和
//   "根本没有数据"看起来一模一样。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/title_match.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

/// 真机搜索用的关键词（`.probe/t71_real_search.json`）
const String kW = '鬼灭之刃';

// 真实标题（逐字取自 .probe/t73_fixture_dump.txt）
const String tExact = '鬼灭之刃'; //                            1.000000
const String tYue = '鬼灭之刃 粤配版'; //                       0.500000
const String tZhu = '鬼灭之刃 柱训练篇'; //                     0.428571 = 3/7
const String tCanteen = '鬼灭食堂32（杀死武赞的方法）'; //        0.071429 = 1/14
const String tWrong = '不好，放错图片了'; //                     0.000000

MediaItem item(String title, [String id = 'p:1']) =>
    MediaItem(id: id, title: title);

SearchStreamEvent hit(String provider, List<MediaItem> items) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: provider,
      items: items,
    );

/// ★ 这个名字**不能**叫 group —— 会和 `flutter_test` 的分组函数同名
/// （后者的第 2 个参数是闭包）⇒ 本文件的局部定义**遮蔽**了它 ⇒
/// 所有被测组都会被解析成「第 2 实参是 List<MediaItem>」，
/// analyze 报 9 条 `Null Function() can't be assigned to 'List<MediaItem>'`。
/// 那是**编译期**错误 —— 改名是唯一干净的修法。
/// ⚠️ 本注解刻意不把那种调用形态原样写出来：红度/自检脚本按正则统计调用点，
///    注释里出现的同样文本会被数进去（第一版就因此假失败）。
({String provider, String name, List<MediaItem> items}) grp(
  String name,
  List<MediaItem> items,
) =>
    (provider: name, name: name, items: items);

// ══════════════════════════════════════════════════════════════════════════
// 脚手架
// ══════════════════════════════════════════════════════════════════════════

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

Future<void> sizeView(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// ★ 几何 key：先比 `top`，同一行再比 `left`。
///
/// 网格里同一行的卡片 `top` **相同**、`left` 不同 ⇒
/// 只比 `top` 无法区分左右顺序（**假通过**）。
double readingKey(WidgetTester t, String text) {
  final r = t.getRect(find.text(text));
  return r.top * 10000 + r.left;
}

/// 把一组标题按**渲染出来的阅读顺序**（先上后下、同行先左后右）排出来。
List<String> readingOrder(WidgetTester t, List<String> titles) {
  final pairs = <(String, double)>[
    for (final s in titles) (s, readingKey(t, s)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final p in pairs) p.$1];
}

/// 造好一个已经"搜过一轮、有一个源可用"的搜索页，返回它的 State。
Future<SearchPageState> seeded(WidgetTester t, Size size) async {
  await sizeView(t, size);
  await t.pumpWidget(host(const SearchPage(), size));
  await t.pump();
  final st = t.state<SearchPageState>(find.byType(SearchPage));
  // 前置条件：等于 listProviders() 成功（见文件头说明）
  st.debugSetProviderCount(4);
  st.debugBeginSearch(kW);
  await t.pump();
  return st;
}

/// 断言某段文本**恰好命中 1 个** widget —— 证明卡片真的渲染出来了
/// （铁律 149：候选集为空时"顺序"断言恒真）。
void expectExactlyOne(WidgetTester t, String text, {String? because}) {
  final n = t.widgetList(find.text(text)).length;
  expect(
    n,
    1,
    reason: '「$text」应恰好渲染 1 处，实际 $n 处'
        '${because == null ? '' : '（$because）'}'
        '—— 0 处说明这一段根本没渲染，顺序断言会退化成恒真',
  );
}

// ══════════════════════════════════════════════════════════════════════════
// 源码审计工具
// ══════════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 与 `/* */` 注释，**保留字符串字面量**。
///
/// ★ 必须有：源码里有大量长注释，其中**刻意引用**了被改掉的旧写法作为
///   证据链（"改之前这里是 `items: ev.items`"）。不剥注释的话，
///   断言「`items: ev.items` 不存在」会因为**注释里的引用**而假失败。
///
/// ⚠️ 已知局限：不识别三引号字符串与 `r'...'` 里的转义差异。
///   本文件只对**下面这几个切片**用，切片内没有这些形态。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\') {
        if (i + 1 < src.length) {
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
      } else if (c == quote) {
        quote = null;
      }
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
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

/// 读源码。★ 读不到时**必须**报出 cwd，否则"文件不存在"会变成一条
/// 看起来通过的断言（断言的是空串）。
String srcOf(String rel) {
  final f = File(rel);
  if (!f.existsSync()) {
    fail('读不到 $rel（cwd=${Directory.current.path}）——'
        '说明测试不在包根目录跑，源码断言会全部退化成对空串的断言');
  }
  final s = f.readAsStringSync();
  if (s.trim().isEmpty) fail('$rel 是空文件');
  return s;
}

/// 取 `from` 与 `to` 之间的片段。★ 两个锚点都必须**恰好出现 1 次**，
/// 否则报错 —— 切片边界错了会切到空/重复内容，断言照样"通过"。
String slice(String src, String from, String to) {
  final a = src.indexOf(from);
  if (a < 0) fail('切片左锚点找不到：$from');
  if (src.indexOf(from, a + 1) >= 0) fail('切片左锚点出现多次：$from');
  final b = src.indexOf(to, a + from.length);
  if (b < 0) fail('切片右锚点找不到：$to');
  return src.substring(a, b);
}

void main() {
  // ════════════════════════════════════════════════════════════════════════
  group('① 判据本身：分数必须与独立算出的期望一致', () {
    test('①-0 夹具分数（由 .probe/t73_scores.py 独立算出）', () {
      expect(titleSimilarity(kW, tExact), closeTo(1.0, 1e-9));
      expect(titleSimilarity(kW, tYue), closeTo(0.5, 1e-9));
      expect(titleSimilarity(kW, tZhu), closeTo(3 / 7, 1e-9));
      expect(titleSimilarity(kW, tCanteen), closeTo(1 / 14, 1e-9));
      expect(titleSimilarity(kW, tWrong), closeTo(0.0, 1e-9));
    });

    test('①-1 组代表分 = 组内最高分（不是平均分）', () {
      // 组里只有 1 条相关的 + 4 条无关：最高分 = 0.5，平均分 = 0.125
      final items = [
        item(tWrong, 'a:1'),
        item(r'无关条目01', 'a:2'),
        item(tYue, 'a:3'),
        item(r'无关条目02', 'a:4'),
        item(r'无关条目03', 'a:5'),
      ];
      expect(bestTitleScore(kW, items), closeTo(0.5, 1e-9));
      // 用平均分就会得 0.125 ⇒ 「准确命中 1 条、其余是噪声」的源会排到后面
      final avg = items
              .map((it) => titleSimilarity(kW, it.title))
              .reduce((a, b) => a + b) /
          items.length;
      expect(avg, lessThan(0.2));
      expect(bestTitleScore(kW, items), greaterThan(avg));
    });

    test('①-2 空组防御（max of empty 会抛）', () {
      expect(bestTitleScore(kW, const []), 0.0);
      expect(rankItemsByTitleDesc(kW, const []), isEmpty);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('② 组间排序（纯函数）', () {
    test('②-1 按最高分降序', () {
      // 喂入顺序 = 从最差到最好（模拟"不沾边的先返回"）
      final input = [
        grp('丁站', [item(tWrong, 'd:1')]), //            0.0
        grp('丙站', [item(tCanteen, 'c:1')]), //          0.0714
        grp('乙站', [item(tZhu, 'b:1')]), //              0.4286
        grp('甲站', [item(tExact, 'a:1')]), //            1.0
      ];
      final out = rankHitGroups(kW, input);
      expect([for (final g in out) g.name], ['甲站', '乙站', '丙站', '丁站']);
    });

    test('②-2 组的分数取组内最高分（组内顺序不影响组间）', () {
      // 甲组第一条无关、第二条满分 ⇒ 整组仍是第一
      final out = rankHitGroups(kW, [
        grp('乙站', [item(tYue, 'b:1')]), //              0.5
        grp('甲站', [item(tWrong, 'a:1'), item(tExact, 'a:2')]), // max 1.0
      ]);
      expect([for (final g in out) g.name], ['甲站', '乙站']);
    });

    test('②-3 同分组保持到达顺序（稳定）', () {
      final out = rankHitGroups(kW, [
        grp('第一', [item(tWrong, 'x:1')]),
        grp('第二', [item(r'无关条目07', 'x:2')]),
        grp('第三', [item(r'无关条目08', 'x:3')]),
      ]);
      expect([for (final g in out) g.name], ['第一', '第二', '第三']);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('③ 组内排序（纯函数）', () {
    test('③-1 按分降序 —— 最像的排第一', () {
      final out = rankItemsByTitleDesc(kW, [
        item(tWrong, 'a:1'), //     0.0
        item(tZhu, 'a:2'), //       0.4286
        item(tYue, 'a:3'), //       0.5
        item(tExact, 'a:4'), //     1.0
        item(tCanteen, 'a:5'), //   0.0714
      ]);
      expect([for (final it in out) it.title], [
        tExact,
        tYue,
        tZhu,
        tCanteen,
        tWrong,
      ]);
    });

    test('③-2 不修改原列表（不改调用方的数据）', () {
      final src = [item(tWrong, 'a:1'), item(tExact, 'a:2')];
      final before = [for (final it in src) it.title];
      final out = rankItemsByTitleDesc(kW, src);
      expect([for (final it in src) it.title], before);
      expect(out, isNot(same(src)));
    });

    test('③-3 全部同分时逐一保持原顺序', () {
      final src = [
        for (var i = 0; i < 40; i++) item('无关条目${i.toString().padLeft(2, '0')}', 'a:$i'),
      ];
      final out = rankItemsByTitleDesc(kW, src);
      expect([for (final it in out) it.title], [for (final it in src) it.title]);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('④ 稳定性（裸 List.sort 会打乱同分项）', () {
    /*
     * ★★ 为什么夹具必须 ≥ 34 条
     *
     * 由 `.probe/probe_tests/t73_threshold_probe_test.dart` 实测：
     * ```text
     *   NAIVE_KEEPS_ORDER_AT_N  = [2..33]
     *   NAIVE_BREAKS_ORDER_AT_N = [34..48]
     *   FIRST_BREAKING_N        = 34
     * ```
     * Dart 的 `List.sort`（introsort）在 n ≤ 33 时走插入排序 ⇒
     * 对相等元素**不移位**，看起来"稳定"。n ≥ 34 才可能重排。
     *
     * ⇒ 夹具小于 34 条时，把 `stableRankDesc` 换成裸 `..sort()` 的变异体
     *   **照样绿** —— 这条断言就成了恒真的空判据。
     */
    test('④-1 36 条同分：stableRankDesc 保持顺序（裸 sort 会打乱）', () {
      final src = List<int>.generate(36, (i) => i);
      final out = stableRankDesc(src, (_) => 1.0);
      expect(out, src, reason: '36 条全同分 ⇒ 必须原样返回');

      // 阳性对照 / 判别力证明：同尺寸下裸 sort **确实**会打乱
      // （若哪天 Dart 换了排序算法，这条会红 —— 那时说明夹具需要重挑，
      //   而不是说明实现错了）
      final naive = List<int>.of(src)..sort((a, b) => 0);
      expect(
        naive,
        isNot(src),
        reason: '裸 sort 在 n=36 全同分时应打乱顺序 —— '
            '它没打乱说明本夹具失去判别力，必须重挑（阈值可能变了）',
      );
    });

    test('④-2 同分块内保持原顺序、不同分仍降序', () {
      // 分数形如 [0,0,1,1,2,2,...] 的混合夹具
      final src = List<int>.generate(40, (i) => i);
      final scoreOf = (int i) => (i ~/ 2).toDouble();
      final out = stableRankDesc(src, scoreOf);
      expect(out, hasLength(40));
      // 降序：分数单调不增
      for (var i = 1; i < out.length; i++) {
        expect(
          scoreOf(out[i - 1]),
          greaterThanOrEqualTo(scoreOf(out[i])),
          reason: '第 $i 位破坏了降序',
        );
      }
      // 同分块内：原索引递增
      for (var i = 1; i < out.length; i++) {
        if (scoreOf(out[i - 1]) == scoreOf(out[i])) {
          expect(out[i - 1], lessThan(out[i]), reason: '同分块内顺序被打乱');
        }
      }
    });

    test('④-3 边界：空、1 条、2 条', () {
      expect(stableRankDesc(<int>[], (_) => 0.0), isEmpty);
      expect(stableRankDesc(<int>[7], (_) => 0.0), <int>[7]);
      expect(stableRankDesc(<int>[1, 2], (i) => 0.0), <int>[1, 2]);
      expect(stableRankDesc(<int>[1, 2], (i) => i.toDouble()), <int>[2, 1]);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('⑤ 真 widget 树：组间顺序（端到端）', () {
    testWidgets('⑤-1 最差先到，最匹配的仍排最上面', (t) async {
      final st = await seeded(t, const Size(1400, 2400));

      // 喂入顺序刻意选成**从最差到最好** —— 也就是 Owner 抱怨的那个场景：
      // 不沾边的源先返回、排在前面；匹配度高的源后返回、被压在下面。
      st.debugFeedHit(hit('丁站', [item(tWrong, 'd:1')])); //      0.0
      await t.pump();
      st.debugFeedHit(hit('丙站', [item(tCanteen, 'c:1')])); //    0.0714
      await t.pump();
      st.debugFeedHit(hit('乙站', [item(tZhu, 'b:1')])); //        0.4286
      await t.pump();
      st.debugFeedHit(hit('甲站', [item(tExact, 'a:1')])); //      1.0
      await t.pump();

      // ★ 先证明 4 张卡真的都渲染出来了（铁律 149）
      for (final s in [tExact, tZhu, tCanteen, tWrong]) {
        expectExactlyOne(t, s);
      }
      for (final s in ['甲站', '乙站', '丙站', '丁站']) {
        expectExactlyOne(t, s);
      }

      // 组标题的顺序
      expect(
        readingOrder(t, ['甲站', '乙站', '丙站', '丁站']),
        ['甲站', '乙站', '丙站', '丁站'],
        reason: '组标题的渲染顺序 ≠ 匹配度降序',
      );

      // 卡片本身的顺序（比组标题更接近用户看到的东西）
      final order = readingOrder(t, [tExact, tZhu, tCanteen, tWrong]);
      expect(
        order,
        [tExact, tZhu, tCanteen, tWrong],
        reason: '卡片渲染顺序 = $order，'
            '期望 [满分 → 3/7 → 1/14 → 0]',
      );

      // 把实测 y 坐标也打出来，便于人工核对（失败时最容易看出问题）
      // ignore: avoid_print
      print('[T73] 组间 y：'
          '甲=${readingKey(t, tExact).toStringAsFixed(0)} '
          '乙=${readingKey(t, tZhu).toStringAsFixed(0)} '
          '丙=${readingKey(t, tCanteen).toStringAsFixed(0)} '
          '丁=${readingKey(t, tWrong).toStringAsFixed(0)}');
    });

    testWidgets('⑤-2 中间插入更匹配的组 ⇒ 它插到前面，而不是被追加到末尾',
        (t) async {
      final st = await seeded(t, const Size(1400, 2400));

      st.debugFeedHit(hit('丁站', [item(tWrong, 'd:1')])); //     0.0
      await t.pump();
      st.debugFeedHit(hit('甲站', [item(tExact, 'a:1')])); //     1.0
      await t.pump();
      // 中途再来一个 0.4286 的 —— 它应插在 丁 之前、甲 之后
      st.debugFeedHit(hit('乙站', [item(tZhu, 'b:1')]));
      await t.pump();

      expectExactlyOne(t, tWrong);
      expectExactlyOne(t, tExact);
      expectExactlyOne(t, tZhu);

      expect(
        readingOrder(t, [tExact, tZhu, tWrong]),
        [tExact, tZhu, tWrong],
      );
    });

    testWidgets('⑤-3 全部无关时保持到达顺序（不因排序而乱跳）', (t) async {
      final st = await seeded(t, const Size(1400, 2400));
      final titles = ['无关条目00', '无关条目01', '无关条目02'];
      for (var i = 0; i < titles.length; i++) {
        st.debugFeedHit(hit('站$i', [item(titles[i], 'z:$i')]));
        await t.pump();
      }
      for (final s in titles) {
        expectExactlyOne(t, s);
      }
      expect(readingOrder(t, titles), titles);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('⑥ 真 widget 树：组内顺序（端到端）', () {
    testWidgets('⑥-1 一个源返回多条 ⇒ 组内也按匹配度降序', (t) async {
      final st = await seeded(t, const Size(1400, 2400));

      // 到达顺序 = 最差的在前、满分的在最后
      st.debugFeedHit(hit('某站', [
        item(tWrong, 'a:1'), //   0.0
        item(tCanteen, 'a:2'), // 0.0714
        item(tYue, 'a:3'), //     0.5
        item(tExact, 'a:4'), //   1.0
      ]));
      await t.pump();

      for (final s in [tWrong, tCanteen, tYue, tExact]) {
        expectExactlyOne(t, s);
      }

      final order = readingOrder(t, [tWrong, tCanteen, tYue, tExact]);
      expect(
        order,
        [tExact, tYue, tCanteen, tWrong],
        reason: '组内渲染顺序 = $order，期望 [1.0 → 0.5 → 1/14 → 0]',
      );
    });

    testWidgets('⑥-2 组内同分保持源返回的顺序', (t) async {
      final st = await seeded(t, const Size(1400, 2400));
      final titles = ['无关条目10', '无关条目11', '无关条目12', '无关条目13'];
      st.debugFeedHit(hit('某站', [
        for (var i = 0; i < titles.length; i++) item(titles[i], 'b:$i'),
      ]));
      await t.pump();
      for (final s in titles) {
        expectExactlyOne(t, s);
      }
      expect(readingOrder(t, titles), titles);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('⑦ 真 widget 树：36 条同分（稳定性在真实链路上也成立）', () {
    /*
     * ★ 纯函数稳 ≠ 链路稳：`_addHit` 里的列表拼接
     *   `rankHitGroups(kw, [..._hits, newGroup])` 每次回填都重排**整表**，
     *   如果排序不稳定，同分的组会随着每次回填来回换位。
     *   这里在真树上用 36 条同分验证"顺序就是到达顺序"。
     *
     * ★ 视图高度 4000 是为了让 36 张卡**全部**渲染出来
     *   （GridView 懒加载，视口外的不建 Element ⇒ 读不到坐标）。
     */
    testWidgets('⑦-1 36 条同分：阅读顺序 = 到达顺序', (t) async {
      final st = await seeded(t, const Size(1400, 4000));
      final titles = [
        for (var i = 0; i < 36; i++) '无关条目${i.toString().padLeft(2, '0')}',
      ];
      st.debugFeedHit(hit(
        '某站',
        [for (var i = 0; i < titles.length; i++) item(titles[i], 'c:$i')],
      ));
      await t.pump();

      var visible = 0;
      for (final s in titles) {
        visible += t.widgetList(find.text(s)).length;
      }
      expect(
        visible,
        titles.length,
        reason: '只有 $visible/${titles.length} 张卡可见 —— '
            '视口不够大，顺序断言会被截断（把视图调高）',
      );

      final order = readingOrder(t, titles);
      expect(
        order,
        titles,
        reason: '36 条同分（≥ 阈值 34）时出现了重排 ⇒ '
            '排序不稳定，或这条链路上绕过了 stableRankDesc',
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('⑧ 接线审计：判据只有一份、且真的被这条链路调用', () {
    test('⑧-1 全仓只有一份 titleSimilarity 定义', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final s = stripComments(e.readAsStringSync());
        if (s.contains('double titleSimilarity(')) {
          hits.add(e.path.replaceAll(r'\', '/'));
        }
      }
      expect(
        hits,
        ['lib/core/title_match.dart'],
        reason: '判据被复制了第二份 ⇒ 两份迟早漂移，'
            '搜索页与换源弹层会给出不同顺序。实际出现在：$hits',
      );
    });

    test('⑧-2 换源弹层原地 export（老 import 点一行都不用改）', () {
      final raw = srcOf('lib/ui/widgets/source_switch_dialog.dart');
      final clean = stripComments(raw);
      expect(clean.contains("export '../../core/title_match.dart';"), isTrue);
      expect(clean.contains("import '../../core/title_match.dart';"), isTrue);
      // 定义已经搬走
      expect(clean.contains('double titleSimilarity('), isFalse);
    });

    test('⑧-3 _addHit 真的调用 rankHitGroups（不是死代码）', () {
      final raw = srcOf('lib/ui/search_page.dart');
      final body = stripComments(
        slice(
          raw,
          'void _addHit(String keyword, SearchStreamEvent ev) {',
          '/// ★ 测试注入口',
        ),
      );
      // ★ 仪器自检：切片必须真的覆盖 _addHit 的函数体
      expect(
        body.contains('_settled++'),
        isTrue,
        reason: '切片没覆盖 _addHit 的函数体 ⇒ 下面的断言是空判据',
      );
      expect(body.contains('rankHitGroups(keyword, ['), isTrue);
      expect(body.contains('items: rankItemsByTitleDesc(keyword, ev.items),'),
          isTrue);
    });

    test('⑧-4 hit 分支走 _addHit（关键词是闭包捕获的 kw）', () {
      final raw = srcOf('lib/ui/search_page.dart');
      final body = stripComments(
        slice(raw, 'await SourinApi.searchAllStream(kw, (ev) {', 'case SearchEventKind.miss:'),
      );
      expect(body.contains('_addHit(kw, ev);'), isTrue);
      // ★ 上次搜索的延迟结果必须用**它自己那次**的关键词打分，不能用 _lastKeyword
      expect(
        body.contains('_addHit(_lastKeyword'),
        isFalse,
        reason: '用了 _lastKeyword ⇒ 改关键词后旧结果会被新关键词重排',
      );
    });

    test('⑧-5 rankHitGroups 的判据 = 组内最高分', () {
      final raw = srcOf('lib/ui/search_page.dart');
      final body = stripComments(
        slice(raw, 'List<SearchHitGroup> rankHitGroups(', '/// 搜索页'),
      );
      expect(
        body.contains('stableRankDesc(groups, (g) => bestTitleScore(keyword, g.items));'),
        isTrue,
      );
    });

    test('⑧-6 排序判据用 title、不用 note', () {
      final raw = srcOf('lib/ui/search_page.dart');
      final clean = stripComments(raw);
      // 排序相关的地方不许出现 it.note / item.note
      expect(clean.contains('titleSimilarity(kW, it.note)'), isFalse);
      expect(clean.contains('it.note'), isFalse,
          reason: 'note 是「全 27 集」这类副标题，与匹配度无关');
      // 卡片副标题显示的**仍然**是 note —— 那是对的
      expect(raw.contains('subtitle: group.items[i].note'), isTrue);
    });

    test('⑧-7 换源弹层组内也排（⑥）', () {
      final raw = srcOf('lib/ui/widgets/source_switch_dialog.dart');
      final clean = stripComments(raw);
      expect(clean.contains('items: rankItemsByTitleDesc(widget.title, ev.items),'),
          isTrue);
      // 组间排序也是稳定的
      expect(
        clean.contains('stableRankDesc(_candidates, (c) => c.score);'),
        isTrue,
      );
      // ★ take(8) 之前必须已经排好 —— 排序发生在 _candidates.add(...) 里
      expect(clean.contains('candidate.items.take(8)'), isTrue);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('⑨ 回归：改之前的老写法不许回来', () {
    test('⑨-1 纯追加的写法已消失', () {
      final clean = stripComments(srcOf('lib/ui/search_page.dart'));
      // 改之前：_hits = [..._hits, (provider: ev.provider, name: ..., items: ev.items)];
      expect(
        clean.contains('items: ev.items'),
        isFalse,
        reason: '组内没有排序（直接透传 ev.items）',
      );
    });

    test('⑨-2 老的不稳定排序写法已消失', () {
      final clean = stripComments(
        srcOf('lib/ui/widgets/source_switch_dialog.dart'),
      );
      expect(
        clean.contains('b.score.compareTo(a.score)'),
        isFalse,
        reason: '裸 List.sort() 不是稳定排序 ⇒ 同分组会乱跳',
      );
      final sp = stripComments(srcOf('lib/ui/search_page.dart'));
      expect(sp.contains('.sort((a, b) =>'), isFalse);
    });

    test('⑨-3 稳定性不靠"排序算法恰好稳定"', () {
      final clean = stripComments(srcOf('lib/core/title_match.dart'));
      // 必须显式把原索引当次关键字
      expect(clean.contains('a.compareTo(b)'), isTrue,
          reason: '同分时要显式用原索引做次关键字');
      expect(clean.contains('order.sort('), isTrue);
    });
  });
}
