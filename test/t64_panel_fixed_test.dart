// ═══════════════════════════════════════════════════════════════════════
//  task-64：右侧面板**整体固定**，只有选集区内部可滚
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 右侧整体固定，不能上下滚动，只有选集部分内部可以滚动
//
// # 改前 / 改后
//
// ```text
// 改前  `_buildBody` 返回 `ListView`（头部 + 选集一起滚）
//       ⇒ 头部会随页面**滚出视野**
// 改后  `_buildBody` 返回 `Column`（**没有任何外层可滚体**）
//       ⇒ 头部结构上不可能被滚走；选集仍是固定高度 + 自己内部滚
// ```
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ 本文件的核心价值：**真件渲染**（不只是读源码）
// ══════════════════════════════════════════════════════════════════════
//
// 本仓既有测试（`t61_panel_scroll_test.dart`）**全是静态断言** ——
// 它只能证明"源码里没有 `ListView(` 这个字符串"，
// ★ 证明不了"渲染出来的树里头部真的不在 Scrollable 里"。
//
// 例如把头部包进 `SingleChildScrollView` 后仍叫 `Column`，
// 静态断言照样绿 —— 而用户看到的**头部还是会被滚走**。
//
// ⇒ 本文件用 `debugSetDetail`（task-64 新增的测试口子）注入真数据，
//   跑**真 `_buildBody`**，再用 `find.ancestor` 在**真实 Element 树**上
//   断言"头部不在任何 Scrollable 里"。
//
// ⚠️ 这不是"影子副本"：被测的就是生产代码本身，只是绕过了 FFI 取数
//    （`flutter test` 里 `sourin_core.dll` 必然加载失败，见 `debugSetDetail` 注释）。
//
// 跑法：
//   powershell -File .probe\flutter_test_lock.ps1 `
//     -Paths 'test/t64_panel_fixed_test.dart','test/t61_panel_scroll_test.dart' `
//     -Agent fix-autoscroll

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

/// 剥注释（本仓铁律⑤：`contains` 必须先剥注释）
///
/// ★ 复用 `t61_panel_scroll_test.dart` 的**同一实现**（逐字节复制它的状态机）——
///   不自己写正则版（正则版会把字符串里的 `//` 当注释，本仓已有教训）。
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

/// 造一份详情（字段够 `_bodyTop` 渲染出可见文字即可）
MediaDetail detail({
  int epCount = 12,
  String title = '无职转生',
}) =>
    MediaDetail(
      id: 'cycani:3862',
      title: title,
      description: '这是一段用于撑开头部的简介文字，重复几遍让它有高度。'
          '这是一段用于撑开头部的简介文字，重复几遍让它有高度。',
      year: '2021',
      area: '日本',
      kind: 'series',
      badges: const ['12 集'],
      episodes: [
        for (var i = 1; i <= epCount; i++)
          Episode(id: 'ep-$i', title: '第${i.toString().padLeft(2, '0')}集'),
      ],
    );

/// 带真主题挂载 `DetailPage`（`embedded: true` = 合并页下半屏）
Widget host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 挂载并注入详情，返回 state（供进一步操作）
Future<GlobalKey<State<DetailPage>>> mountDetail(
  WidgetTester t, {
  required Size size,
  int epCount = 12,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<State<DetailPage>>();
  await t.pumpWidget(host(
    Scaffold(
      body: DetailPage(
        key: key,
        provider: 'cycani',
        id: '3862',
        embedded: true,
      ),
    ),
  ));
  await t.pump();

  // ★ 注入真数据（绕过 FFI —— 见 `debugSetDetail` 的注释）
  //
  // ⚠️ 必须**同时**传 `episodes:` —— `_episodes` 是**独立的 state 字段**
  //    （生产路径里由 `_loadEpisodes` / `d.episodes` 写入，L954）。
  //    只把 episodes 放进 `MediaDetail` **不会**让选集区渲染出来
  //    ⇒ `_bodyEpisodes` 里 `if (_episodes.isNotEmpty ...)` 为假
  //    ⇒ 选集一个按钮都没有。
  //    ★ 我第一版就漏了这个参数，导致 4 条"选集仍在 Scrollable 里"的断言
  //      失败 —— 那是**测试的错**，不是产品的错（如实记录）。
  final d = detail(epCount: epCount);
  final st = key.currentState!;
  // ignore: avoid_dynamic_calls
  (st as dynamic).debugSetDetail(d, episodes: d.episodes);
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return key;
}

/// 某个 widget 的**最近** `Scrollable` 祖先（没有 ⇒ null）
///
/// ★ 这是"头部有没有被放进可滚体"的**直接**判据 ——
///   比读源码可靠：它看的是**真实 Element 树**。
Scrollable? nearestScrollableAncestor(WidgetTester t, Finder f) {
  final anc = find.ancestor(of: f, matching: find.byType(Scrollable));
  final els = anc.evaluate().toList();
  if (els.isEmpty) return null;
  return els.first.widget as Scrollable;
}

void main() {
  late String src;

  setUpAll(() {
    src = stripComments(File('lib/ui/detail_page.dart').readAsStringSync());
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检 —— 先证明"找祖先 Scrollable"这个工具不是恒真/恒假
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检（防假绿：工具必须能区分"在/不在"可滚体里）', () {
    testWidgets('★ 裸 Text 没有 Scrollable 祖先', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(host(const Scaffold(body: Text('裸的'))));
      await t.pump();

      expect(nearestScrollableAncestor(t, find.text('裸的')), isNull,
          reason: '★ 仪器自检：裸 Text 不该有 Scrollable 祖先');
    });

    testWidgets('★★ Text 放进 ListView ⇒ **必须**找得到 Scrollable 祖先',
        (t) async {
      /*
       * ★ 这条是本文件所有"头部不在可滚体里"断言的**阳性对照**：
       *   若这个工具恒返回 null，那些断言全部假绿。
       */
      await t.binding.setSurfaceSize(const Size(400, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(host(
        Scaffold(body: ListView(children: const [Text('在列表里')])),
      ));
      await t.pump();

      expect(nearestScrollableAncestor(t, find.text('在列表里')), isNotNull,
          reason: '★★ 仪器必须能发现 ListView 里的 Text —— '
              '否则"头部不在可滚体里"是假绿');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① ★★★ 真件渲染：头部**不在任何可滚体**里（宽档）
  // ═══════════════════════════════════════════════════════════════════

  group('① 真件渲染：头部固定（宽档 1280x800）', () {
    testWidgets('★★★ 标题不在任何 Scrollable 里（头部结构上不可能被滚走）',
        (t) async {
      await mountDetail(t, size: const Size(1280, 800));

      final f = find.text('无职转生');
      expect(f, findsWidgets,
          reason: '★ 阳性对照：标题必须真的渲染出来了 —— '
              '否则"找不到 Scrollable 祖先"是因为**什么都没渲染**（假绿）');

      expect(nearestScrollableAncestor(t, f.first), isNull,
          reason: '★★★ 标题（头部的一部分）**不许**在任何 Scrollable 里 —— '
              'Owner 要求「右侧整体固定，不能上下滚动」。'
              '★ 若头部被包进 ListView/SingleChildScrollView，用户一滚它就没了');
    });

    testWidgets('★★★ 简介也不在任何 Scrollable 里', (t) async {
      await mountDetail(t, size: const Size(1280, 800));

      final f = find.textContaining('用于撑开头部');
      expect(f, findsWidgets, reason: '★ 阳性对照：简介要真的渲染出来');
      expect(nearestScrollableAncestor(t, f.first), isNull,
          reason: '★★★ 简介属于头部 ⇒ 不许可滚');
    });

    testWidgets('★★★ 选集区**仍然**在 Scrollable 里（内部可滚没被删掉）',
        (t) async {
      /*
       * ★ 这条与上面两条**方向相反**，缺了它就会出现
       *   "整页不滚了、但选集也不能滚" ⇒ 后面的集数**看不见**（更糟）。
       */
      await mountDetail(t, size: const Size(1280, 800));

      final ep = find.text('第01集');
      expect(ep, findsWidgets, reason: '★ 阳性对照：选集按钮要真的渲染出来');
      expect(nearestScrollableAncestor(t, ep.first), isNotNull,
          reason: '★★★ 选集**必须**仍在可滚体里（固定高度 + 内部滚）—— '
              '否则超出视口那些集**永远看不见**（把"整页滚"换成"选集被裁掉"）');
    });

    testWidgets('★★ 外层没有整页可滚体（`_buildBody` 的根不是 Scrollable）',
        (t) async {
      await mountDetail(t, size: const Size(1280, 800));

      /*
       * ★ 判据：**头部**的祖先链里没有 Scrollable（上面已断言）+
       *   本页的 `Scrollable` 总数应当是**选集那一个**（不是两个）。
       *   ⚠️ `Scrollbar` 内部可能再包一个 ⇒ 用集合去重后的**数量上界**。
       */
      final n = find.byType(Scrollable).evaluate().length;
      // ignore: avoid_print
      print('[T64] 宽档 Scrollable 总数 = $n');
      expect(n, lessThanOrEqualTo(2),
          reason: '★★ 宽档下 Scrollable 只应来自**选集那一个**'
              '（`SingleChildScrollView` + 可能的 `Scrollbar` 包装）—— '
              '多出来就说明又有一个可滚体（很可能是外层整页）。实测 n=$n');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② ★★★ 真件渲染：窄档（<900，下半屏）也要满足同一契约
  // ═══════════════════════════════════════════════════════════════════

  group('② 真件渲染：窄档（下半屏）也头部固定 + 选集滚', () {
    testWidgets('★★★ 窄档 640x800：标题不在可滚体里', (t) async {
      /*
       * ★ `media_page.dart`：`wide = mq.size.width >= 900`
       *   ⇒ 640 走**上下分栏**，详情区是**下半屏**。
       *   ★ m01887 第③条起，下半屏的 flex 由 `_narrowVideoHeight` 动态算
       *     （640×800 ⇒ 视频 360 / 详情 440，与旧的 9:11 逐像素相同）。
       * ★ 本用例直接给 `DetailPage` 一个窄盒（模拟下半屏），
       *   验的是"同一份 `_buildBody` 在窄宽下也满足契约"。
       */
      await mountDetail(t, size: const Size(640, 800));

      final f = find.text('无职转生');
      expect(f, findsWidgets, reason: '★ 阳性对照：窄档下标题也要渲染出来');
      expect(nearestScrollableAncestor(t, f.first), isNull,
          reason: '★★★ 窄档（下半屏）下头部**同样**不许可滚 —— '
              'Owner 的要求与档位无关');
    });

    testWidgets('★★★ 窄档：选集**仍然**内部可滚', (t) async {
      await mountDetail(t, size: const Size(640, 800));

      final ep = find.text('第01集');
      expect(ep, findsWidgets, reason: '★ 阳性对照：窄档选集要渲染出来');
      expect(nearestScrollableAncestor(t, ep.first), isNotNull,
          reason: '★★★ 窄档下选集也必须能内部滚');
    });

    testWidgets('★★★ 窄档：头部固定 + 选集可滚，且**不溢出**（生产可达尺寸）',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条**原来用 360×300** —— 那个尺寸**生产上不可达**
       * ══════════════════════════════════════════════════════════════
       *
       * # 实测证据（`.probe/probe_tests/t64_header_measure_test.dart`）
       * ```text
       * surface=1280×800  ⇒ 头部自然高 ≈ 366.0px
       * surface= 640×800  ⇒ 头部自然高 ≈ 397.0px   ← 窄档更高（封面换行）
       * surface= 400×300  ⇒ 头部自然高 ≈ 334.0px
       * surface= 400×200  ⇒ 头部自然高 ≈ 334.0px
       * ```
       * ★ 头部自然高由内容决定（**334~397px**），与窗口高度无关。
       * ⇒ 在 300px 高的窗口里同时满足「头部固定不可滚」+「不溢出」
       *   **数学上不可能**（334 > 300 恒成立）。
       *
       * # ★★ 而那个尺寸**本来就不该被测** —— 根因在 `shell.dart`
       * ```text
       * 原版 `src-tauri/tauri.conf.json`：minWidth 900 / minHeight 600
       * 我们的 `shell.dart` 却写着：
       *     minimumSize: Size(200, 200), // AG-EXPERIMENT-TEMP (revert)
       *                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       *                                   ★ 某次实验的临时值，**忘了还原**
       * ⇒ 两个后果：
       *   ① 用户真能把窗口拖到 200×200 ⇒ 头部(334)吃光视口
       *      ⇒ **选集被整个推出可视区**（用户看不到剧集）
       *   ② 测试去追一个"因为 bug 才存在"的尺寸 ⇒ 目标本身不可达
       * ```
       * ⇒ ★ 已在 `shell.dart` 把 `minimumSize` 还原成 **900×600**（= 原版）。
       *   ⇒ 本测试改用**生产可达**的窄档尺寸。
       *
       * # 判据（改成真实契约）
       * ```text
       * 窄档 640×800  ⇒ 不溢出（这是 900×600 窗口下分栏后的真实宽度）
       * 最小窗口 900×600 ⇒ 不溢出
       * ```
       * ⚠️ 不删这条：它记录的是"我们量过头部自然高、并找到
       *    `minimumSize` 被改坏"这个**结论**。
       */
      // ① 窄档真实形态：640×800（不溢出）
      await mountDetail(t, size: const Size(640, 800), epCount: 30);
      expect(find.byType(DetailPage), findsOneWidget,
          reason: '★ 窄档真实形态（640×800）必须不溢出');

      // ② 最小窗口：900×600（= 原版 minWidth/minHeight）
      await mountDetail(t, size: const Size(900, 600), epCount: 30);
      expect(find.byType(DetailPage), findsOneWidget,
          reason: '★★★ 最小窗口（900×600，= 原版 Tauri 的 minWidth/minHeight）'
              '必须不溢出 —— 这是用户**能拖到的最小尺寸**');
    });

    testWidgets('★★★ 最小窗口（900×600）下选集区**仍然**内部可滚', (t) async {
      /*
       * ⚠️ 这条原来用 **400×200** —— 同样不可达（见上一条的说明）。
       *
       * ⇒ 改成断言**真正重要的行为**，且在**生产可达的最小尺寸**上验：
       *   「选集区仍然是一个可内部滚的区域」——
       *   否则用户在最小窗口里看不到后面的集数（那才是真缺陷）。
       */
      await mountDetail(t, size: const Size(900, 600), epCount: 30);

      // ⚠️ 标签格式必须与本文件的 fixture 一致（`第01集`，**补零无空格**）——
      //    我第一版写成 `第 1 集` ⇒ 找到 0 个 ⇒ 假红。
      final ep = find.text('第01集');
      expect(ep, findsWidgets, reason: '★ 最小窗口下选集仍要渲染出来');
      expect(nearestScrollableAncestor(t, ep.first), isNotNull,
          reason: '★★★ 极矮窗口下选集**仍必须能内部滚** —— '
              '这正是 Owner 那句「只有选集部分内部可以滚动」的底线');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 纯函数：`episodeViewportHeight` 的契约（未被 task-64 改动）
  // ═══════════════════════════════════════════════════════════════════

  group('③ `episodeViewportHeight` 契约不变（task-62 已验收，不许动）', () {
    test('★★★ 800/390 ⇒ 322（与 t61 的 B2 组同一读数）', () {
      expect(episodeViewportHeight(topH: 390, availH: 800), 322.0,
          reason: '★ 800 − 390 − Sp.x6(24) − Sp.x16(64) = 322 —— '
              'task-64 改的是**外层容器**，这个纯函数的契约**一个字都没改**');
    });

    test('★★★ 剩余比下限小 ⇒ 退回 148（不许缩成看不见）', () {
      expect(episodeViewportHeight(topH: 250, availH: 300), kEpsViewportH);
    });

    test('★★ 可用高为 null / 无穷 ⇒ 退回下限', () {
      expect(episodeViewportHeight(topH: 390, availH: null), kEpsViewportH);
      expect(episodeViewportHeight(topH: 390, availH: double.infinity),
          kEpsViewportH);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 静态审计：结构 + 防"偷偷加一条滚动"
  // ═══════════════════════════════════════════════════════════════════

  group('④ 静态审计（补充真件渲染，不是替代）', () {
    test('★★★ `_buildBody` 里没有任何可滚体 + 根是 Column', () {
      final i = src.indexOf('Widget _buildBody(');
      expect(i, greaterThan(0), reason: '找不到 `_buildBody`');
      var depth = 0;
      var end = i;
      for (var k = src.indexOf('{', i); k < src.length; k++) {
        if (src[k] == '{') depth++;
        if (src[k] == '}') {
          depth--;
          if (depth == 0) {
            end = k;
            break;
          }
        }
      }
      final body = src.substring(i, end);

      for (final forbidden in const [
        'ListView(',
        'SingleChildScrollView(',
        'CustomScrollView(',
        'GridView(',
        'PageView(',
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: '★★★ `_buildBody` 里不得出现 `$forbidden` —— '
                'Owner 要求「右侧整体固定，不能上下滚动」');
      }
      expect(body.contains('return Column('), isTrue,
          reason: '★ 外层应是 `Column`（自然高度、不可滚）');
    });

    test('★★★ `Flexible` 安全网必须在（Column 下防溢出）', () {
      /*
       * ★ 为什么它不是"多余的一层"：
       *   `_topH` 由 post-frame 写入 ⇒ **首帧为 null** ⇒
       *   首帧 `epsH ≈ availH − 88` ⇒ 头部再一占 ⇒ **必然**超出可用高。
       *   ListView 里无害（滚一下），Column 里就是溢出条纹。
       * ⇒ `Flexible`（loose）把子级**夹到剩余空间** ——
       *   这个上界是**框架**算的，比任何"自己估剩余"都可靠。
       */
      expect(src.contains('Flexible('), isTrue,
          reason: '★★★ 选集视口必须包在 `Flexible` 里 —— '
              '否则首帧（`_topH == null`）在 Column 下**必然** RenderFlex overflow');
      /*
       * ⚠️ 必须是 `loose`（默认）—— `tight` 会把 epsH 撑到全部剩余，
       *    破坏"固定高度"契约（t61 的 B 组钉的是 `height: epsH`）。
       */
      expect(src.contains('FlexFit.tight'), isFalse,
          reason: '★ 不许用 `FlexFit.tight` —— 它会把选集撑到全部剩余空间，'
              '破坏"固定高度"契约（B 组：`height: epsH`）');
    });

    test('★★★ 窄档也走同一份 `_buildBody`（没有第二套布局）', () {
      /*
       * ★ 窄档由 `media_page.dart` 的 `Expanded(...)`（flex 动态）给一个**窄盒**，
       *   而详情区内部**没有**自己的宽窄分支（只有 `_Info` 内部按宽度排布）。
       * ⇒ 所以"窄档也满足契约"是**结构保证**的，不是靠再写一套。
       *   这条钉住那个前提：若有人加了"窄档换布局"的分支，就必须重新审。
       */
      final n = RegExp(r'return Column\(').allMatches(src).length;
      expect(n, greaterThan(0));
      // 只应有一个 `_buildBody`
      expect(RegExp(r'Widget _buildBody\(').allMatches(src).length, 1,
          reason: '★ 只允许一个 `_buildBody` —— 多一个就是"第二套布局"，'
              '那会让"窄档也满足"变成未验证的假设');
    });

    test('★★ 不许用 flutter/material.dart（本仓硬约束）', () {
      expect(src.contains("import 'package:flutter/material.dart'"), isFalse);
    });

    test('★★★ 堵住绕过路径（与 t61 同源，这里再钉一次）', () {
      for (final bad in const [
        'Scrollable.ensureVisible',
        'Scrollable.of(',
        'PrimaryScrollController',
        '.position.jumpTo',
      ]) {
        expect(src.contains(bad), isFalse,
            reason: '★★★ 不许出现 `$bad` —— 它会向上遍历/指到**外层**，'
                '把整页滚走（本仓 task-3 同族事故）');
      }
    });
  });
}
