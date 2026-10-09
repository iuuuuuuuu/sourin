// ═══════════════════════════════════════════════════════════════════════
//  选集三端形态 —— 回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 被验收的交互（Owner 原话 → 三条可断言的行为）
//
// ```text
// ① 「一般是显示一部分，然后如果集数多，就有个小箭头」
//    → 手机/TV 上 >20 集时出箭头；≤20 集不出
// ② 「点击一下，从下面弹出来选择集数」
//    → 点箭头 → 底部弹出面板（含全部分集）
// ③ 「也跟首页的那个一样，是会自动滚动到当前播放集数的，可视区域的」
//    → 条与面板都要滚到当前集
// ④ 「桌面端 tv app 显示的逻辑应该是不一样的」
//    → 桌面 = 二维网格；手机/TV = 横向一行
// ```
//
// # ⚠️ 关于静态断言 —— 必须**先剥掉注释行**
//
// 项目里踩过 3 次「断言匹配到注释文本 → 假通过」。
// 本文件的静态断言统一走 [stripComments]：
// ```dart
// final code = stripComments(File(path).readAsStringSync());
// ```
// 所以 `// 桌面 → 换行网格` 这类**说明文字**不会让断言通过 ——
// 只有**真正的代码**才算。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ⚠️ 不要单独再 import `package:flutter/rendering.dart` ——
//    `material_ui` 已经转出了 `RenderBox` 等全部用到的符号，
//    多那一行会得到 `unnecessary_import`
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 造 N 集（标题带序号，方便断言"渲染的是哪几集"）
List<Episode> _eps(int n) => [
      for (var i = 0; i < n; i++)
        Episode(id: 'ep-$i', title: '第${i + 1}集', index: i),
    ];

/// 网格间距（原版 `gap: 6px`）—— 与生产代码的 `_kGridGap` 同值
///
/// ⚠️ 生产那个是**私有**的（`_kGridGap`），测试拿不到。
///    这里复写一份，并在几何断言里用它把「格子总宽 + 间距 == 容器宽」
///    钉死 —— 万一将来生产改成别的值，那条断言会**立刻失败**
///    （而不是悄悄错下去）。
const double _gap = 6;

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释）
///
/// ⚠️ 这是本文件所有静态断言的前提 —— 见文件头的说明。
///
/// # 为什么要处理块注释（我第一版漏了，测试当场假失败）
///
/// 第一版只过滤 `trimLeft().startsWith('//')` 的行，
/// 于是 `/* ... */` 里的**说明文字**留在了"代码"里：
/// ```text
/// 横向条里那句注释： `ListView.builder` 是**懒构建**的……
///   → 它以 `*` 开头，不是 `//`，没被剥掉
///   → 断言 "横向条里不能有 ListView.builder" **误报**
/// ```
/// 这正是项目里踩过 3 次的「断言匹配到注释文本」——
/// 只不过这次是**反向**的（注释让测试**假失败**），
/// 而它同样说明：**只要注释参与匹配，结论就不可信**。
///
/// # 为什么用状态机而不是正则
///
/// 要区分三种情况：
/// ```text
/// 'http://x'     字符串里的 `//` **不是**注释
/// "a /* b"       字符串里的 `/*` 不是注释
/// /*  //  */     块注释里的 `//` 不是行注释
/// ```
/// 正则做不到（需要记忆状态）。所以走一遍字符。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（记录引号字符）

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    // ── 在字符串里：原样保留，只找结束引号 ──
    if (quote != null) {
      if (c == r'\') {
        // 转义：连同下一个字符一起保留
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }

    // ── 不在字符串里 ──
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      // 行注释：跳到行尾（保留换行，行号不变）
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      // 块注释：跳到 */
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        // 保留换行，行号才对得上
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

/// 把控件套进真实的壳（forui 主题 + material_ui 的 MaterialApp）
///
/// ⚠️ 与 `shell.dart` 同款：`FTheme` 在 `builder` 里。
///    必须用 `material_ui` 的 `MaterialApp` —— 用 `flutter/material`
///    会拿到 `ThemeData.fallback()`（亮色），测试环境和生产不一致。
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 三端分流
  // ═══════════════════════════════════════════════════════════════════

  group('① 三端分流 —— 形态由 Device 决定，不是窗口宽度', () {
    testWidgets('桌面 → 二维网格（Wrap 换行），不是横向 ListView', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 800,
        child: EpisodeStrip(
          episodes: _eps(6),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: true,
        ),
      )));
      await t.pumpAndSettle();

      // 网格 = Wrap；横向条 = 单行 Row/ListView
      expect(find.byType(Wrap), findsOneWidget,
          reason: '桌面必须是换行网格（抄腾讯 PC 播放页的 flex-wrap:wrap）');
      expect(find.byType(Wrap), findsOneWidget);
    });

    testWidgets('手机 → 横向一行（没有 Wrap）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(6),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.byType(Wrap), findsNothing,
          reason: '手机是横向一行（只占一行高，竖向空间宝贵）');
      // 横向滚动容器必须在
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });

    testWidgets('★ 桌面**不显示**展开箭头（双重隐藏）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 800,
        child: EpisodeStrip(
          episodes: _eps(50),
          currentIndex: 0,
          onPick: (_) {},
          onExpand: () {},
          isDesktopOverride: true,
        ),
      )));
      await t.pumpAndSettle();

      // 箭头是「50 ⬇」；桌面上一个集数按钮都不该是它
      expect(find.text('50'), findsNothing,
          reason: '桌面已有内部滚动，再加折叠是**双重隐藏**'
              '（用户要先滚再点），原版腾讯 PC 上也没有折叠');
      // 50 集全都在网格里
      expect(find.text('第50集'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 「显示一部分 + 箭头弹出」
  // ═══════════════════════════════════════════════════════════════════

  group('② 「显示一部分 + 箭头」—— Owner 的 20 集阈值', () {
    testWidgets('≤20 集：不折叠、**不显示箭头**', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(20),
          currentIndex: 0,
          onPick: (_) {},
          onExpand: () {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.text('第20集'), findsOneWidget);
      expect(find.text('20'), findsNothing,
          reason: '正好 20 集不折叠（阈值是「**超过** 20」）');
    });

    testWidgets('★ >20 集：只渲染前 20 集 + 末尾出现箭头', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(500),
          currentIndex: 0,
          onPick: (_) {},
          onExpand: () {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      // 「显示一部分」—— 前 20 集在，第 21 集不在
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第20集'), findsOneWidget);
      expect(find.text('第21集'), findsNothing,
          reason: '折叠态只渲染前 kEpisodeCollapseAfter 集');

      // 箭头带总数（原版 `<span class="epstrip__morenum">{{ episodes.length }}</span>`）
      expect(find.text('500'), findsOneWidget,
          reason: '箭头要显示**总数**，用户才知道"还有多少"');

      // 箭头图标
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('★ 点箭头触发 onExpand（交互不能丢）', (t) async {
      var expanded = 0;
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(30),
          currentIndex: 0,
          onPick: (_) {},
          onExpand: () => expanded++,
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.keyboard_arrow_down));
      await t.pumpAndSettle();
      expect(expanded, 1, reason: '「点击一下，从下面弹出来选择集数」');
    });

    testWidgets('★ 点某一集触发 onPick（且是那一集，不是别的）', (t) async {
      Episode? picked;
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (e) => picked = e,
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('第3集'));
      await t.pumpAndSettle();
      expect(picked?.id, 'ep-2');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 完整面板（从底部弹出）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 完整选集面板', () {
    testWidgets('面板显示**全部**集（不受 20 集折叠影响）', (t) async {
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(30),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pumpAndSettle();

      expect(find.text('第21集'), findsOneWidget,
          reason: '弹出面板是"选择集数"用的 —— 必须能看到全部');
      expect(find.text('第30集'), findsOneWidget);
    });

    testWidgets('★ 面板里点某一集 → onPick', (t) async {
      Episode? picked;
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(10),
        currentIndex: 0,
        onPick: (e) => picked = e,
        onClose: () {},
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('第7集'));
      await t.pumpAndSettle();
      expect(picked?.id, 'ep-6');
    });

    testWidgets('★ 分卷：>100 集才出现，且默认定位到**当前集所在的段**', (t) async {
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(250),
        currentIndex: 150, // 第 151 集 → 第 2 段（101-200）
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pumpAndSettle();

      // 三段
      expect(find.text('1-100'), findsOneWidget);
      expect(find.text('101-200'), findsOneWidget);
      expect(find.text('201-250'), findsOneWidget);

      /*
       * ★ 打开时**直接落在当前集所在的段** —— 原版注释：
       * > 必须在 onMounted 之前算好，否则会先渲染第 1 段，
       * > 再跳段，用户看到闪一下。
       */
      expect(find.text('第151集'), findsOneWidget,
          reason: '默认段必须是当前集所在段（101-200），不是第 1 段');
      expect(find.text('第1集'), findsNothing);
    });

    testWidgets('≤100 集**不分段**', (t) async {
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(80),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pumpAndSettle();

      expect(find.text('1-80'), findsNothing,
          reason: '实测多数剧集 < 100，分段通常不出现');
      expect(find.text('第80集'), findsOneWidget);
    });

    testWidgets('★ 点背景关闭（原版 @click.self）', (t) async {
      var closed = 0;
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(10),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () => closed++,
        // 用底部抽屉形态，背景在面板上方
        asDialog: false,
      )));
      await t.pumpAndSettle();

      // 点最上方（面板只占底部 72%，顶部一定是背景）
      await t.tapAt(const Offset(200, 10));
      await t.pumpAndSettle();
      expect(closed, 1, reason: '点背景关闭');
    });

    testWidgets('★ 点面板**内部**不会关闭（别穿透）', (t) async {
      var closed = 0;
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(10),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () => closed++,
        asDialog: false,
      )));
      await t.pumpAndSettle();

      await t.tap(find.text('选集'));
      await t.pumpAndSettle();
      expect(closed, 0,
          reason: '点内部（标题「选集」）不该关掉自己');
    });

    testWidgets('点 X 关闭', (t) async {
      var closed = 0;
      await t.pumpWidget(_host(EpisodeSheet(
        episodes: _eps(10),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () => closed++,
      )));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.close));
      await t.pumpAndSettle();
      expect(closed, 1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 桌面 vs 手机/TV 的外壳差别
  // ═══════════════════════════════════════════════════════════════════

  group('④ EpisodePanel 按端选外壳', () {
    testWidgets('桌面 → **右侧抽屉**（Align.centerRight）',
        (t) async {
      /*
       * ★ 断言方向被**用户需求反转**了（2026-09-25，任务㊄⑩）
       *
       * 用户原话：
       * > 这个选集,我希望 **pc 操作是点击然后右侧出现抽屉进行选集**
       *
       * 所以桌面壳从「居中弹窗」改成了「贴右侧」。
       * 旧断言要求 `Alignment.center` —— 它现在会把**正确的**实现判成失败。
       *
       * ⚠️ 这不是“为了变绿而放宽断言”：被守的**契约没变**
       *    （桌面壳必须锚在某一个**确定的边**，不能漂），
       *    只是“哪个边”按用户要求改了。严格程度一样：
       *    仍然要求一个**确切的** Alignment 值。
       *
       * ★ 右侧抽屉的位置也有 `episode_drawer_test.dart`
       *   那边的**像素级**断言兜底（量真实 rect 的右边）。
       */
      await t.pumpWidget(_host(EpisodePanel(
        episodes: _eps(12),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
        isDesktopOverride: true,
      )));
      await t.pumpAndSettle();

      final align = t.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight,
          reason: '★ 用户要求 PC 选集是**右侧抽屉** —— '
              '桌面壳必须贴右，不能是居中弹窗。');
    });

    testWidgets('手机/TV → 底部（Align.bottomCenter）—— 「从下面弹出来」', (t) async {
      await t.pumpWidget(_host(EpisodePanel(
        episodes: _eps(12),
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
        isDesktopOverride: false,
      )));
      await t.pumpAndSettle();

      final align = t.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.bottomCenter,
          reason: 'Owner：「从下面弹出来选择集数」—— 底部抽屉是硬要求');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 静态审计（**剥掉注释**再匹配）
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 静态审计 —— 剥注释后匹配，防假通过', () {
    test('★ stripComments 本身有效（先证明工具是对的）', () {
      const src = '// 桌面 → 换行网格\nfinal a = 1;\n/// doc\n';
      final code = stripComments(src);
      expect(code.contains('换行网格'), isFalse,
          reason: '行注释必须被剥掉');
      expect(code.contains('doc'), isFalse, reason: '文档注释也要剥掉');
      expect(code.contains('final a = 1;'), isTrue, reason: '真代码要留下');
    });

    test('★ stripComments 处理块注释与字符串（否则会误报/漏报）', () {
      // 块注释里的说明文字必须消失
      expect(stripComments('/* 这里写着 ListView.builder */\nfinal a=1;')
          .contains('ListView.builder'), isFalse,
          reason: '块注释里的文字不能参与匹配 —— '
              '我第一版就漏了这个，导致断言误报');

      // 多行块注释也要剥干净，且行号要能对上
      final multi = stripComments('/*\n 第一行\n 第二行\n*/\nfinal b=2;');
      expect(multi.contains('第一行'), isFalse);
      expect(multi.split('\n').length, 5,
          reason: '块注释里的换行要保留 —— 否则报错行号会错位');

      // 字符串里的 // 不能被当成注释
      expect(stripComments("final u = 'http://x';").contains('http://x'), isTrue,
          reason: '字符串里的 // 不是注释');

      // 字符串里的 /* 也不能
      expect(stripComments("final s = 'a /* b';").contains('a /* b'), isTrue);
    });

    test('★ 禁止 `package:flutter/material.dart`（两套 Theme 串台）', () {
      final bad = <String>[];
      for (final p in const [
        'lib/ui/widgets/episode_strip.dart',
        'lib/ui/player_page.dart',
      ]) {
        final code = stripComments(File(p).readAsStringSync());
        if (code.contains("import 'package:flutter/material.dart'")) {
          bad.add(p);
        }
      }
      expect(bad, isEmpty,
          reason: 'Flutter 3.47 把 Material 拆到了 material_ui；'
              '混用会让 Theme.of 拿到 ThemeData.fallback()（亮色），'
              '对比度只剩 1.16:1 —— 项目踩过');
    });

    test('★ player_page 的选集面板已换成按端分流的 EpisodePanel', () {
      final code = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );

      expect(code.contains('EpisodePanel('), isTrue,
          reason: '选集面板必须走 EpisodePanel（按端分流）');

      // 旧的单一右侧栏**不能**再出现
      final re = RegExp(r'class\s+_EpisodeSheet\b');
      expect(re.hasMatch(code), isFalse,
          reason: '旧的 _EpisodeSheet（320px 右侧实心黑栏，三端一个样）'
              '必须删掉 —— 它与三端分流直接冲突');
    });

    test('★ 横向条必须**非懒构建**（否则自动滚动静默失效）', () {
      final code = stripComments(
        File('lib/ui/widgets/episode_strip.dart').readAsStringSync(),
      );

      /*
       * ★ 这条是本文件里最"值钱"的断言。
       *
       * `ListView.builder` 懒构建 → 视口外的格子 `currentContext == null`
       * → `_scrollToCurrent` 静默 return → **Owner 要求的自动滚动没生效**，
       * 而且不报任何错。
       *
       * 横向条里**不能**出现 `ListView.builder`（折叠态最多 20 个格子，
       * 一次全建出来的代价可以忽略）。
       */
      final re = RegExp(r'ListView\.(builder|separated)');
      // 面板里的"分卷条"是允许用 ListView.separated 的（那是横向小列表，
      // 不需要按 key 定位）；所以只断言**横向条那个类**里没有。
      final railStart = code.indexOf('class _HorizontalRailState');
      expect(railStart, greaterThanOrEqualTo(0), reason: '横向条类必须存在');
      final railEnd = code.indexOf('class _GridRail', railStart);
      expect(railEnd, greaterThan(railStart));

      final railCode = code.substring(railStart, railEnd);
      expect(re.hasMatch(railCode), isFalse,
          reason: '横向条用 ListView 会懒构建视口外的格子，'
              'GlobalKey.currentContext 为 null → 自动滚动**静默失效**');

      expect(railCode.contains('SingleChildScrollView'), isTrue);
    });

    test('★ 自动滚动**不能**再用 `Scrollable.ensureVisible` 假装 nearest', () {
      final code = stripComments(
        File('lib/ui/widgets/episode_strip.dart').readAsStringSync(),
      );

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条是本轮修掉的**真 bug** —— 旧的字符串断言放过了它
       * ══════════════════════════════════════════════════════════════
       *
       * 旧写法（注释里还写着「0.0 = nearest 语义」）：
       * ```dart
       * Scrollable.ensureVisible(ctx, alignment: center ? 0.5 : 0.0);
       * ```
       * 那个注释是**错的**。`alignment: 0.0` 的语义是
       * 「把目标**起始边对齐视口起始边**」，它**不看**目标是否已可见：
       * ```text
       * 当前集在视口正中（完全看得见，用户正看着）
       *   → 切下一集 → alignment 0.0 把它硬拽到最左边
       *   → 整条大幅平移（"条自己跳了一下"）
       * ```
       * 而原版是明确的 **nearest**（`if (br.left >= rr.left && ...) return;`
       * —— 已可见就**一个像素都不动**）。
       *
       * 现在两个形态都自己算偏移。断言用「不许出现 ensureVisible」
       * 这个**行为约束**，而不是匹配某个函数名。
       */
      expect(RegExp(r'Scrollable\.ensureVisible').hasMatch(code), isFalse,
          reason: 'ensureVisible 的 alignment 没有"已可见就不动"的语义 —— '
              '切集时会把整条拽一下，与原版 nearest 不符');

      expect(code.contains('railScrollTarget('), isTrue,
          reason: '横向条（手机/TV）要按 nearest/center 自己算偏移');
      expect(code.contains('gridScrollTarget('), isTrue,
          reason: '网格（桌面 / 弹出面板）是纵向滚动 + 已可见不动');
    });

    test('★ TV 焦点环存在（遥控器唯一的位置指示）', () {
      final code = stripComments(
        File('lib/ui/widgets/episode_strip.dart').readAsStringSync(),
      );
      expect(code.contains('Device.needsFocusRing'), isTrue,
          reason: 'TV 上没有鼠标悬停，焦点是唯一的位置指示 —— '
              '没有焦点环用户不知道停在哪一集');
      expect(code.contains('onFocusChange'), isTrue);
    });

    test('★ 播放页让方向键给选集面板（否则 TV 选不了集）', () {
      final code = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
      expect(code.contains('_episodeSheetOpen && _arrowKeys.contains(k)'),
          isTrue,
          reason: '面板打开时方向键必须让给面板焦点树 —— '
              '否则 TV 上按方向键只会改音量/跳进度，面板里一动不动');
      expect(code.contains('KeyEventResult.ignored'), isTrue);
    });

    test('★★★ 播放页让**确认键**给选集面板（只让方向键是不够的）', () {
      final code = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这是本轮修的**第二个真 bug** —— 上一轮只做了方向键
       * ══════════════════════════════════════════════════════════════
       *
       * 上一轮的注释写着「否则 TV 选不了集」，但它只放行了 `_arrowKeys`。
       * 结果是**半好**：
       * ```text
       * 方向键 → 焦点环会动 ✓        （能"走"）
       * OK 键  → _togglePlay()      ✗（选不了 —— 用户以为按钮坏了）
       * ```
       * 「能移动焦点」≠「能选片」——
       * 与 `spatial_nav.dart` 文件头记的那个假象同类。
       *
       * 根因：按键从 `primaryFocus` **往祖先走**，播放页根的
       * `Focus(onKeyEvent: _onKey)` 是格子的祖先，把 enter/select
       * 当"播放/暂停"先 `handled` 掉了 → `ActivateIntent` 到不了 InkWell。
       *
       * # 为什么这条是**静态**断言而不是 widget 断言
       *
       * 真跑 `PlayerPage` 要 media_kit + 平台通道（重且脆）。
       * 而这个修复的本质是**一处按键路由判断**，静态钉住"那三个确认键
       * 必须出现在同一条 `_episodeSheetOpen` 判断里"就够了 ——
       * 但**行为**由 ⑦ 组那两条端到端断言兜底（按 Enter/select
       * 真的调用 onPick）。
       */
      final gate = RegExp(
        r'_episodeSheetOpen\s*&&\s*\(?\s*k\s*==\s*LogicalKeyboardKey\.enter',
      );
      expect(gate.hasMatch(code), isTrue,
          reason: '★ 面板打开时 enter 键必须**不被播放器消费** —— '
              '否则 TV 用户按 OK 只会暂停/播放，永远选不中那一集');

      // select / gameButtonA 也要放行（Android TV 的 OK 常映射成它们）
      expect(code.contains('LogicalKeyboardKey.select'), isTrue,
          reason: 'Android TV 遥控器的 OK 常映射成 select');

      // 而且这个放行必须**只在面板开着时**生效（面板关着时 enter 仍是播放/暂停）
      expect(code.contains('widget.isTv &&'), isTrue,
          reason: '确认键放行只对 TV 且只在面板打开时生效 —— '
              '桌面/手机、以及面板关着时都必须保持原行为（已验收，不能动）');
    });

    test('★ 三端形态表（原版文件头）已照抄进注释', () {
      // ⚠️ 这条**故意**匹配注释 —— 它检查的就是"设计理由有没有记录下来"
      final src = File('lib/ui/widgets/episode_strip.dart').readAsStringSync();
      for (final k in const [
        '桌面 | 鼠标 + 滚轮',
        '手机 | 手指滑动',
        'TV   | 遥控器方向键',
        'flex-wrap:**wrap**',
        'overflow-y:**auto**',
        'max-height:**440px**',
        '为什么 TV 不也用网格',
        '为什么桌面不用箭头',
      ]) {
        expect(src.contains(k), isTrue,
            reason: '原版 EpisodeStrip.vue 文件头的三端形态表与设计理由'
                '必须照抄进来：缺「$k」');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ TV 形态（遥控器）—— 本机没有 Android TV，用 overrideKind 覆盖
  // ═══════════════════════════════════════════════════════════════════

  group('⑦ TV 形态 —— 遥控器必须能选片', () {
    tearDown(() => Device.overrideKind(null)); // 每例跑完还原，别污染别的测试

    testWidgets('★ TV 上每一集都**可聚焦**（否则方向键走不动）', (t) async {
      Device.overrideKind(DeviceKind.tv);
      expect(Device.needsFocusRing, isTrue, reason: '前提：TV 需要焦点环');

      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      // TV 形态下必须画出焦点环（AnimatedContainer + foregroundDecoration）
      final ringed = t.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
      expect(ringed, isNotEmpty,
          reason: 'TV 上没有鼠标悬停 —— 焦点环是**唯一**的位置指示，'
              '少了它用户不知道遥控器停在哪一集');
    });

    testWidgets('★ TV 上自动把焦点放到**当前集**（不是第一集）', (t) async {
      Device.overrideKind(DeviceKind.tv);

      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 5, // 第 6 集
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      /*
       * 面板打开时原来持有焦点的「选集」按钮已被移除，
       * 焦点会掉到播放器根节点 —— 那时按方向键起点是**整屏矩形**，
       * 第一个邻居不可预期。所以必须主动把焦点放到当前集。
       */
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull, reason: 'TV 上必须有焦点，否则遥控器从零开始');

      // 焦点所在的控件应该就是第 6 集那个 chip
      final ctx = focused!.context;
      expect(ctx, isNotNull);
      final txt = find.descendant(
        of: find.byWidget(ctx!.widget),
        matching: find.text('第6集'),
      );
      expect(txt, findsOneWidget,
          reason: 'TV 上焦点必须落在**当前集**上 —— '
              '否则用户一按方向键就不知道从哪开始');
    });

    testWidgets('★ TV 上方向键能在选集条里移动焦点（左右）', (t) async {
      Device.overrideKind(DeviceKind.tv);

      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      Rect? rectOf(FocusNode? n) {
        final ro = n?.context?.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return null;
        return ro.localToGlobal(Offset.zero) & ro.size;
      }

      final before = rectOf(FocusManager.instance.primaryFocus);
      expect(before, isNotNull, reason: '前提：已经有焦点');

      // 按右方向键 —— 应该移到下一集
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();

      final after = rectOf(FocusManager.instance.primaryFocus);
      expect(after, isNotNull);
      expect(after!.left, greaterThan(before!.left),
          reason: 'TV 上按 → 焦点必须往右走 —— '
              '`spatial_nav.dart` 的文件头记过真机 bug：'
              '「按 → 后 Focus Δ=(0,0)，遥控器根本没法选片」');
    });

    testWidgets('★ 触摸端**不**画焦点环（没有遥控器，纯噪音）', (t) async {
      Device.overrideKind(DeviceKind.touchOnly);
      expect(Device.needsFocusRing, isFalse);

      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.byType(AnimatedContainer), findsNothing,
          reason: '手机上没有焦点这回事，包一层 AnimatedContainer 是纯开销');
    });

    testWidgets('★★★ TV 上方向键能从最后一集走到**箭头**（否则展开不了）',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条是任务里点名的风险：「别让遥控器在网格里走不动」
       * ══════════════════════════════════════════════════════════════
       *
       * 手机/TV 形态是「前 20 集 + 箭头」。如果箭头**不可聚焦**，
       * 遥控器按到第 20 集就**到头了** —— 第 21 集之后永远看不到，
       * 也就是「500 集的剧在 TV 上只能看前 20 集」。
       *
       * 这正是 `spatial_nav.ts` 文件头记录的那类假象：
       * 「能移动焦点 ≠ 能选片」，而这里是「能走 20 格 ≠ 能到箭头」。
       *
       * 断言：从最后一集（第 20 集）按 →，焦点必须**真的往右移动**
       * 到箭头那个按钮上（几何位置更靠右）。
       */
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(500),
          currentIndex: 19, // 第 20 集 = 折叠态**最后一个**可见集
          onPick: (_) {},
          onExpand: () {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      Rect? rectOf(FocusNode? n) {
        final ro = n?.context?.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return null;
        return ro.localToGlobal(Offset.zero) & ro.size;
      }

      final before = rectOf(FocusManager.instance.primaryFocus);
      expect(before, isNotNull,
          reason: '前提：TV 上焦点已在**当前集**（第 20 集）上');

      // ★ 一路按 → 直到走到箭头（最多按 5 次，防死循环）
      var moved = false;
      Rect? last = before;
      for (var i = 0; i < 5; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pumpAndSettle();
        final now = rectOf(FocusManager.instance.primaryFocus);
        if (now != null && last != null && now.left > last.left + 1) {
          last = now;
          moved = true;
        } else {
          break;
        }
      }

      expect(moved, isTrue,
          reason: '★ 从最后一集按 → 必须能走到**箭头**上 —— '
              '箭头不可聚焦的话，遥控器到第 20 集就"走不动"了，'
              '而第 21 集之后的剧集**在 TV 上永远看不到**');

      // 走到箭头后按确认键 → 展开
      var expanded = 0;
      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(500),
          currentIndex: 19,
          onPick: (_) {},
          onExpand: () => expanded++,
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      // 直接点箭头（TV 上就是"走到 + 确认"）
      await t.tap(find.byIcon(Icons.keyboard_arrow_down));
      await t.pumpAndSettle();
      expect(expanded, 1, reason: '箭头是"显示一部分"之外的唯一入口');
    });

    testWidgets('★★★ TV 上按**确认键**真的能选中焦点那一集（不是播放/暂停）',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条对应本轮修掉的**第二个真 bug**
       * ══════════════════════════════════════════════════════════════
       *
       * 只把**方向键**让给面板是不够的（上一轮就是这么做的，注释还
       * 写着"否则 TV 选不了集"，但那只解决了"走得动"）。
       *
       * 症状：
       * ```text
       * 方向键 → 焦点环正常移动 ✓
       * 按 OK  → 播放器暂停/播放了一下，**集没选上** ✗
       * ```
       * 根因：按键派发是从 `primaryFocus` **往祖先走**的，
       * 播放页根那个 `Focus(onKeyEvent: _onKey)` 是格子的**祖先**，
       * 它把 `enter/select` 定义成"播放/暂停"并先返回 `handled`
       * → `ActivateIntent` 永远到不了 `InkWell.onTap`。
       *
       * 原版是 DOM `<button>`：TV 上 Enter 直接 `click()`，**按钮优先**。
       * 所以"面板开着时确认键归面板"才是与原版一致。
       *
       * 这里直接断言**端到端结果**：按 Enter 之后 onPick 被调用、
       * 且选中的就是当前焦点那一集。
       */
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      final picked = <Episode>[];
      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: picked.add,
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      // 先按 → 把焦点移到第 2 集（证明"走得动"）
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();

      // ★ 再按确认键 —— 必须真的选中焦点那一集
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();

      expect(picked, hasLength(1),
          reason: '★ TV 上按确认键必须**选中**焦点那一集 —— '
              '如果 onPick 没被调用，说明按键被祖先的播放器快捷键吃掉了：'
              '用户会看到"焦点能走，但按 OK 只是暂停/播放"');
      expect(picked.single.id, 'ep-1',
          reason: '★ 选中的必须是**焦点所在**那一集（按了一次 →，'
              '焦点在第 2 集 = ep-1），不是第 1 集也不是别的');
    });

    testWidgets('★ TV 上 `<select>` 键也能确认（部分遥控器映射成它）', (t) async {
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      final picked = <Episode>[];
      await t.pumpWidget(_host(SizedBox(
        width: 960,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: picked.add,
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(picked, hasLength(1),
          reason: 'Android TV 的遥控器 OK 常映射成 select 而不是 enter');
      expect(picked.single.id, 'ep-0', reason: '当前集是第 1 集');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 常量与设备判据
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ 阈值常量（Owner 定的数字）', () {
    test('折叠阈值 = 20（Owner：「超过 20 集就出箭头」）', () {
      expect(kEpisodeCollapseAfter, 20);
    });

    test('分卷大小 = 100（照抄原版 chunkSize）', () {
      expect(kEpisodeChunkSize, 100);
    });

    testWidgets('★ 形态跟随 Device，**不跟随宽度**', (t) async {
      /*
       * 同一次 build 里，窗口宽度变化**不该**改变形态 ——
       * 因为输入设备不会中途变（原版注释：
       * 「窗口宽度会随用户拖窗口变化导致形态跳变，而输入设备不会」）。
       */
      await t.pumpWidget(_host(SizedBox(
        width: 1200,
        child: EpisodeStrip(
          episodes: _eps(6),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false, // 强制"不是桌面"
        ),
      )));
      await t.pumpAndSettle();
      // 1200px 宽，但仍然是横向条（没有 Wrap）
      expect(find.byType(Wrap), findsNothing,
          reason: '宽度大 ≠ 桌面 —— 判据是 Device.isDesktop（能力检测）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑧ ★★★ 纯几何 —— **像素级断言**（字符串断言挡不住算错）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须有这一组
  //
  // 项目里的两次教训都指向同一件事：
  // ```text
  // ① 断言匹配到注释 → 假通过（踩过 3 次）
  // ② 源码里有那段代码，但**几何算错了** → 断言照样全绿
  // ```
  // ② 尤其阴险：`Scrollable.ensureVisible(alignment: 0.0)` 那版，
  // 「自动滚动」的代码**在**、函数**被调用**、测试**全绿**，
  // 而用户看到的是切集时整条被拽一下 —— 因为 0.0 不是 nearest。
  //
  // 所以这一组直接断言**数值**：列数、格宽、限高、滚动偏移。

  group('⑧ 纯几何（像素级）', () {
    // ── 网格列数与格宽：复刻 CSS `minmax(84px, 1fr)` ──

    test('列数 = floor((W + gap) / (cell + gap))，最少 1 列', () {
      /*
       * 判据推导（CSS `auto-fill` 的语义）：
       * ```text
       * N 列放得下 ⟺ N*84 + (N-1)*6 <= W
       *             ⟺ N*90 - 6 <= W
       *             ⟺ N <= (W + 6) / 90
       * ```
       * 所以 `floor((W + gap) / (cell + gap))` 正是这条 —— 那个 `+gap`
       * 就是把"末尾那个不存在的间距"补回来。
       *
       * ⚠️ 我第一版把边界写错了（以为 179px 只能 1 列），被这条断言当场
       *    抓住 —— **这正是"算一遍数字"的价值**：光看代码看不出边界在哪。
       */
      // 1 列的下界：84px（1*84 + 0*6）
      expect(gridColumns(84), 1, reason: '正好一格宽 → 1 列');
      expect(gridColumns(83), 1, reason: '差 1px 只能 1 列');

      // 2 列的下界：2*84 + 1*6 = 174
      expect(gridColumns(174), 2,
          reason: '174 = 2 格 + 1 间距，**正好**放得下 2 列');
      expect(gridColumns(173), 1, reason: '差 1px 退回 1 列');

      // 3 列的下界：3*84 + 2*6 = 264
      expect(gridColumns(264), 3);
      expect(gridColumns(263), 2);

      expect(gridColumns(800), 8,
          reason: '800 → floor(806/90) = 8（原版 auto-fill 的算法）');
      expect(gridColumns(0), 1, reason: '宽度为 0 时也不能返回 0 列（除零）');
      expect(gridColumns(-5), 1, reason: '负宽度是异常输入，兜到 1 列');
    });

    test('★ 格宽是 `1fr` 均分 —— 必须把剩余宽度填满（右侧不留空档）', () {
      const w = 800.0;
      final cols = gridColumns(w);
      final cell = gridCellWidth(w, cols);

      // ★ 关键断言：cols 个格子 + (cols-1) 个间距 **正好等于** 容器宽度
      expect(cell * cols + _gap * (cols - 1), closeTo(w, 0.001),
          reason: '1fr 的语义是"均分剩余宽度"—— '
              '格子总宽 + 间距必须**精确等于**容器宽，否则右侧会留空档');

      // 而且必须**不小于** 84（那是 minmax 的下限）
      expect(cell, greaterThanOrEqualTo(84.0),
          reason: '84 是 minmax 的**下限**不是定值 —— 算出来的格宽不该小于它');

      // 旧实现的错法：每格写死 84 → 右边空 86px（比一个格子还宽）
      expect(cell, greaterThan(84.0),
          reason: '800px 容器下均分后每格应 > 84（旧版写死 84 会右边空一大条）');
    });

    test('★ 限高 = 3 行，且**恰好**盖住 3 行（不多不少）', () {
      final h = gridMaxHeight();
      // 3 行 + 2 个行间距
      expect(h, closeTo(3 * 40 + 2 * _gap, 0.001),
          reason: '限高必须由「行数」推导 —— 写死像素的话字号一变就露半行');
      expect(h, closeTo(132, 0.001));
      // 少于 4 行：第 4 行**不该**露出来
      expect(h, lessThan(4 * 40 + 3 * _gap - 1),
          reason: '限高必须能真的挡住第 4 行（不然"限高 3 行"是假的）');
      expect(gridMaxHeight(rows: 0), 0);
      expect(gridMaxHeight(rows: 1), 40, reason: '1 行时没有行间距');
    });

    // ── 横向条滚动：nearest vs center ──

    test('★★★ nearest：目标**已完全可见**时一个像素都不动（原版的核心语义）', () {
      /*
       * 这是本轮修掉的真 bug。旧代码用
       * `Scrollable.ensureVisible(alignment: 0.0)` —— 它会把
       * **已经看得见**的格子硬拽到视口左边缘。
       *
       * 场景：视口 400 宽，当前滚动 200；目标在视口内 [120, 176)。
       */
      final t1 = railScrollTarget(
        itemStart: 120,
        itemExtent: 56,
        viewportExtent: 400,
        contentExtent: 2000,
        current: 200,
        center: false,
      );
      expect(t1, 200, reason: '★ 已可见就不动 —— 这就是 nearest；'
          'alignment:0.0 会算成 200+120=320（把格子拽到最左边）');

      // 右边界刚好贴住也算"已可见"（闭区间）
      final t2 = railScrollTarget(
        itemStart: 344, // 344 + 56 = 400 == 视口右边界
        itemExtent: 56,
        viewportExtent: 400,
        contentExtent: 2000,
        current: 200,
        center: false,
      );
      expect(t2, 200, reason: '刚好贴住右边界也算可见（原版用 >= / <= 闭区间）');
    });

    test('★ nearest：目标在右边**看不见**时 → 滚到"留 12px 边距"处', () {
      // 目标在视口右外侧：itemStart = 460（> 400）
      final t = railScrollTarget(
        itemStart: 460,
        itemExtent: 56,
        viewportExtent: 400,
        contentExtent: 2000,
        current: 200,
        center: false,
      );
      // 原版：scrollLeft + (br.left - rr.left) - 12 = 200 + 460 - 12
      expect(t, 648, reason: '原版 nearest 分支减 12（kRailScrollMargin）'
          '—— 让目标不要紧贴边缘');
    });

    test('★ nearest：目标在左边看不见时 → 同样留 12px（不能为负）', () {
      final t = railScrollTarget(
        itemStart: -100,
        itemExtent: 56,
        viewportExtent: 400,
        contentExtent: 2000,
        current: 200,
        center: false,
      );
      expect(t, 88, reason: '200 + (-100) - 12 = 88');
    });

    test('★ center：目标居中（挂载时用，让人看到"我在哪"）', () {
      final t = railScrollTarget(
        itemStart: 460,
        itemExtent: 56,
        viewportExtent: 400,
        contentExtent: 2000,
        current: 200,
        center: true,
      );
      // 200 + 460 - (400-56)/2 = 200 + 460 - 172 = 488
      expect(t, 488, reason: '居中 = current + itemStart - (视口 - 目标)/2');
    });

    test('★ 滚动偏移必须夹在 [0, maxScroll]（不能滚出内容外）', () {
      // 内容比视口短 → 上限是 0，任何目标都返回 0
      expect(
        railScrollTarget(
          itemStart: 500,
          itemExtent: 56,
          viewportExtent: 400,
          contentExtent: 300, // 内容 300 < 视口 400
          current: 0,
          center: true,
        ),
        0,
        reason: '内容比视口短时不能滚（maxScroll 要夹到 0，不能是负数）',
      );

      // 目标远在右边 → 夹到 maxScroll（1000 - 400 = 600）
      expect(
        railScrollTarget(
          itemStart: 5000,
          itemExtent: 56,
          viewportExtent: 400,
          contentExtent: 1000,
          current: 0,
          center: true,
        ),
        600,
        reason: '不能滚过 maxScrollExtent',
      );

      // 目标远在左边 → 夹到 0（不能是负数）
      expect(
        railScrollTarget(
          itemStart: -5000,
          itemExtent: 56,
          viewportExtent: 400,
          contentExtent: 1000,
          current: 300,
          center: true,
        ),
        0,
        reason: '不能滚到负偏移',
      );
    });

    // ── 网格滚动：竖向 + 忽略 center ──

    test('★ 网格：已可见就不动', () {
      final t = gridScrollTarget(
        itemStart: 50,
        itemExtent: 40,
        viewportExtent: 132,
        contentExtent: 2000,
        current: 400,
      );
      expect(t, 400, reason: '网格同样是"已可见就不动"（原版网格分支第一句）');
    });

    test('★ 网格：超出视口时居中，且**忽略 center 参数**', () {
      // 目标在视口下方外侧
      final below = gridScrollTarget(
        itemStart: 200,
        itemExtent: 40,
        viewportExtent: 132,
        contentExtent: 2000,
        current: 400,
      );
      // 400 + 200 - (132-40)/2 = 400 + 200 - 46 = 554
      expect(below, 554, reason: '网格分支是"居中"，不是对齐起始边');

      // 目标在视口上方外侧
      final above = gridScrollTarget(
        itemStart: -60,
        itemExtent: 40,
        viewportExtent: 132,
        contentExtent: 2000,
        current: 400,
      );
      expect(above, 294, reason: '400 - 60 - 46 = 294');
    });

    test('★ 折叠数量：**超过** 20 才折叠（正好 20 不折叠）', () {
      expect(visibleEpisodeCount(19), 19);
      expect(visibleEpisodeCount(20), 20,
          reason: 'Owner 定的是「**超过** 20 集」—— 正好 20 不折叠、不出箭头');
      expect(visibleEpisodeCount(21), 20,
          reason: '21 集时只渲染前 20 个 + 箭头');
      expect(visibleEpisodeCount(500), 20);
      expect(visibleEpisodeCount(0), 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑨ ★★ 端到端几何 —— 真的渲染出来再量像素
  // ═══════════════════════════════════════════════════════════════════

  group('⑨ 端到端几何（渲染后量真实像素）', () {
    /// 量某个 finder 的全局矩形
    Rect rectOf(WidgetTester t, Finder f) {
      final ro = f.evaluate().first.findRenderObject();
      expect(ro, isA<RenderBox>(), reason: '拿不到 RenderBox');
      final box = ro! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    testWidgets('★ 桌面网格：格子排成网格，且每行**填满**容器宽度', (t) async {
      const w = 800.0;
      await t.pumpWidget(_host(SizedBox(
        width: w,
        child: EpisodeStrip(
          episodes: _eps(24),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: true,
        ),
      )));
      await t.pumpAndSettle();

      final text1 = find.text('第1集');
      final text2 = find.text('第2集');
      expect(text1, findsOneWidget);
      expect(text2, findsOneWidget);

      // 同一行（top 相同）且第 2 个在第 1 个右边
      final r1 = rectOf(t, text1);
      final r2 = rectOf(t, text2);
      expect(r2.top, closeTo(r1.top, 0.5), reason: '前两个格子应在同一行');
      expect(r2.left, greaterThan(r1.left), reason: '第二个在第一个右边');

      // ★ 网格必须换行（不是横向一行）：找第 2 行的格子
      final cols = gridColumns(w);
      expect(cols, greaterThan(1));
      final firstOfRow2 = find.text('第${cols + 1}集');
      expect(firstOfRow2, findsOneWidget,
          reason: '第 ${cols + 1} 集应当换到第 2 行');
      final r2nd = rectOf(t, firstOfRow2);
      expect(r2nd.top, greaterThan(r1.top),
          reason: '★ 桌面是**换行网格** —— 第 ${cols + 1} 集必须换行，'
              '而不是排在右边（那是手机/TV 的横向一行）');
    });

    testWidgets('★ 桌面网格：限高真的是 3 行（第 4 行被挡住，可滚动）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 800,
        child: EpisodeStrip(
          episodes: _eps(60), // 60 集 → 远多于 3 行
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: true,
        ),
      )));
      await t.pumpAndSettle();

      // 找到那个纵向滚动容器（桌面网格特有）
      final scrollables = t.widgetList<Scrollable>(find.byType(Scrollable));
      expect(scrollables, isNotEmpty, reason: '网格必须有内部滚动');

      // 量网格视口高度 —— 应该（约）等于 gridMaxHeight()
      final gridBox = find
          .descendant(
            of: find.byType(EpisodeStrip),
            matching: find.byType(Scrollbar),
          )
          .evaluate()
          .first
          .findRenderObject()! as RenderBox;
      expect(gridBox.size.height, lessThanOrEqualTo(gridMaxHeight() + 0.5),
          reason: '★ 限高必须是 ${gridMaxHeight()}（3 行）—— '
              '不限高的话 60 集会铺 8 行，把下面的内容全挤出屏幕');
    });

    testWidgets('★ 手机横向条：是**一行**（第 2 个不换行）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      final r1 = rectOf(t, find.text('第1集'));
      final r2 = rectOf(t, find.text('第2集'));
      // ★ 横向一行 = 所有格子的纵向位置完全相同
      expect(r2.top, closeTo(r1.top, 0.5),
          reason: '手机是横向一行 —— 只占一行高（竖向空间宝贵）');
      expect(r2.left, greaterThan(r1.left));
      expect(r2.top, closeTo(r1.top, 0.5));

      // 高度就是胶囊高度（一行），远小于网格的 3 行
      final stripBox = rectOf(t, find.byType(EpisodeStrip));
      expect(stripBox.height, lessThan(60),
          reason: '横向条只占一行（36px 胶囊）—— 这是"手机竖向空间宝贵"的体现');
    });

    testWidgets('★ 当前集高亮的是**当前那一集**（底色，不是靠猜）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        child: EpisodeStrip(
          episodes: _eps(8),
          currentIndex: 3, // 第 4 集
          onPick: (_) {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      final active = t.widget<Text>(find.text('第4集'));
      final other = t.widget<Text>(find.text('第1集'));
      // 选中态的字重是 w600（对照组 w400）—— 与底色一起构成"选中"信号
      expect(active.style?.fontWeight, FontWeight.w600,
          reason: '当前集要高亮');
      expect(other.style?.fontWeight, FontWeight.w400,
          reason: '非当前集不该高亮');
      // 颜色也必须不同（只差字重的话对比太弱）
      expect(active.style?.color, isNot(other.style?.color),
          reason: '选中态的主信号是**底色 + 文字色**，不能只靠字重');
    });

    testWidgets('★ 点箭头 → 真的进到完整面板（不是只触发回调）', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 412,
        height: 700,
        child: EpisodePanel(
          episodes: _eps(500),
          currentIndex: 0,
          onPick: (_) {},
          onClose: () {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      // 第一层：选集条（只显示前 20 集 + 箭头「500 ⬇」）
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第21集'), findsNothing,
          reason: '第一层只"显示一部分"（前 20 集）');
      expect(find.text('500'), findsOneWidget, reason: '箭头带总数');

      // ★ 点箭头 → 第二层（完整面板）：21 集之后要出现
      await t.tap(find.byIcon(Icons.keyboard_arrow_down));
      await t.pumpAndSettle();

      expect(find.text('第21集'), findsOneWidget,
          reason: '★ 点箭头必须进到"从下面弹出来"的完整面板 —— '
              'Owner：「点击一下，从下面弹出来选择集数」'
              '（第一层只到第 20 集，第 21 集出现就证明进第二层了）');

      /*
       * ⚠️ 「第500集」**不该**在这一屏 —— 500 集要分卷（chunkSize 100）。
       *
       * 我第一版断言了 `find.text('第500集')`，当场失败 ——
       * 但那是**代码对、测试错**：分卷正是原版的设计
       * （原版注释：「500 集一次性渲染在低端 TV 盒子上会卡」）。
       *
       * 所以"能看到全部"的正确证据是**分卷按钮覆盖了 500 集** ——
       * 用户点「401-500」就能到第 500 集。
       *
       * ★★★ 而这条断言**当场抓到了一个真 divergence**：
       *     我当时用横向 `ListView` 放分卷按钮（懒构建 + 无滚动条），
       *     窄屏上第 5 个「401-500」**根本没被构建** ——
       *     用户**点不到最后一卷**，而且看不出来右边还有东西。
       *     原版 `.epsheet__chunks` 是 `flex-wrap: wrap`（换行），
       *     5 个按钮全都在。现在改成 `Wrap`，这条断言就能过了。
       */
      for (final label in const ['1-100', '101-200', '201-300', '301-400', '401-500']) {
        expect(find.text(label), findsOneWidget,
            reason: '分卷按钮「$label」必须**都渲染出来** —— '
                '原版是 flex-wrap:wrap（换行），'
                '用横向 ListView 会把最后一卷截在屏幕外、点不到');
      }

      // 而且真的能点到最后一集
      await t.tap(find.text('401-500'));
      await t.pumpAndSettle();
      expect(find.text('第500集'), findsOneWidget,
          reason: '切到第 5 段后，最后一集必须在（这才是"选择集数"）');
    });

    testWidgets('★ 完整面板要能**返回**选集条那一层（不是一次退两层）', (t) async {
      /*
       * ⚠️ 这一例必须把设备设成 **TV**。
       *
       * 原因：Esc 是**遥控器**的「返回」键 —— 而按键派发是从
       * `primaryFocus` 往祖先链走的（`FocusManager`）。桌面/手机上
       * `_focusCurrent` 直接 return（`needsFocusRing == false`），
       * **没有任何格子持有焦点** → 按键没有派发路径 → Esc 谁也收不到。
       *
       * 那不是 bug，是"桌面根本不用遥控器返回"。
       * 所以这里还原真实前提：TV + 焦点在某一集上。
       */
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      await t.pumpWidget(_host(SizedBox(
        width: 412,
        height: 700,
        child: EpisodePanel(
          episodes: _eps(500),
          currentIndex: 0,
          onPick: (_) {},
          onClose: () {},
          isDesktopOverride: false,
        ),
      )));
      await t.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, isNotNull,
          reason: '前提：TV 上选集条会把焦点放到当前集上');

      await t.tap(find.byIcon(Icons.keyboard_arrow_down));
      await t.pumpAndSettle();
      expect(find.text('第21集'), findsOneWidget,
          reason: '前提：已在完整面板（第一层只到第 20 集）');

      // 按 Esc（遥控器「返回」）→ 应退回**选集条**那一层
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      expect(find.text('第21集'), findsNothing,
          reason: 'Esc 应当离开完整面板（回到只显示前 20 集的那一层）');
      expect(find.text('第1集'), findsOneWidget,
          reason: '★ 退回的是**选集条那一层**（原版的条是常驻的，'
              '关掉弹出层后用户看到的还是那一条）');
    });
  });
}
