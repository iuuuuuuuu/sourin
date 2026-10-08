// ═══════════════════════════════════════════════════════════════════════
//  task-63：播放记录显示「？」—— 回归守护
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 还有，播放记录多了几个 显示 ？ 的记录，没有封面没有名字点进去才知道是什么
//
// # 「？」是**三层**叠加的结果（缺一层都修不干净）
//
// ```text
// 第 1 层（数据）  `_saveProgress` 写的是 `widget.title`/`widget.cover`
//                  —— 那是 **final 构造参数**，而合并页入口 `_mediaRoute()`
//                  传的是 `title: ''`、**没有 cover** ⇒ 两值恒为空
// 第 2 层（传参）  `my_shelf.dart` history 分支把 `p.title`（空串）原样传下去
// 第 3 层（渲染）  `poster_card.dart` 的 `? '?'` —— ★ 用户看到的那个字符
// ```
//
// ★ 三层是**独立**的：只修第 1 层，存量那 3 行仍然是「？」；
//   只修第 2 层，第 3 层照样画 '?'；只修第 3 层，数据仍然是空的。
//
// # 实测依据（用户真实库，只读副本 `.probe/dbcopy-q/`）
//
// ```text
// progress 表 15 行，其中 3 行 title='' 且 cover=NULL：
//   360:86969   pos=665 dur=2777
//   cycani:3841 pos=122 dur=1422
//   cycani:3862 pos=77  dur=1420   ← 「无职转生」
// ★ 另有两条**关键**实测事实：
//   ① `title` 非空但 `cover` NULL = **0 行** ⇒ 两字段"同生同死"
//   ② 那 3 行的 `episode_id` 也**都是 None**
// ```
//
// ⚠️ 本文件**不**挂真 `PlayerPage`（它一构建就建 `Player`，要 mpv + 网络）。
//    结构用**源码断言**（剥注释），纯函数用**直接调用**。
//    本仓既有先例：`t58_media_page_test.dart`（同样手法）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart' show Progress;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/// 读生产源码并**剥掉注释**
///
/// ⚠️ 必须剥注释：本仓踩过这个坑（把注释里的示例代码当成真代码 ⇒ 假绿/假红）。
///    ★ 本文件的被测代码里有**大段注释引用了旧写法**（`? '?'`、
///      `title: widget.title`），不剥注释会让"旧写法已消失"这类断言**永远失败**。
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

/// 造一条进度记录
Progress _p({
  String title = '',
  String? cover,
  String? episodeTitle,
  int position = 77,
  int duration = 1420,
}) =>
    Progress(
      key: 'cycani:3862',
      provider: 'cycani',
      nativeId: '3862',
      title: title,
      cover: cover,
      episodeTitle: episodeTitle,
      position: position,
      duration: duration,
    );

// ═══════════════════════════════════════════════════════════════════════
//  真件渲染用的仪器（★ 上面那批是**静态**断言，看不到"渲染出来是什么"）
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 为什么必须补渲染断言（lead 的验收 ③ 明确要求）
// ```text
// 静态断言只能证明"源码里没有 `? '?'` 这个字符串"，
// ★ 但证明不了"渲染出来的是什么" ——
//   例如 `? '？'`（全角）能绕过 `contains("? '?'")`，
//   而用户看到的仍然是「？」。
// ⇒ 必须**真的渲染**再读文字（本仓纪律：只测真件，不测影子副本）。
// ```

/// 带**真主题**挂载（`PosterCard` 依赖 `Theme.of` 取色，裸 MaterialApp 会崩/取不到色）
Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light
        ? buildLightMaterialTheme(theme)
        : buildMaterialTheme(theme),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(
      backgroundColor: AppTheme.floorColor(brightness),
      body: Center(child: child),
    ),
  );
}

/// 渲染树里**所有**可见文字（`Text` 的 data 或 textSpan）
List<String> _allTexts(WidgetTester t) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget;
    if (w is Text) {
      final s = w.data ?? w.textSpan?.toPlainText();
      if (s != null && s.isNotEmpty) out.add(s);
    }
  }
  return out;
}

/// 挂载 `MyShelf` 并注入历史数据（复用既有的 `debugSetData` 测试口子）
Future<void> _mountShelf(WidgetTester t, List<Progress> history) async {
  /*
   * ★ 用**真实窗口尺寸** 1280x800，不用 flutter_test 默认的 800x600 ——
   *   默认视口太窄会让卡片列 `RenderFlex overflowed`（那是测试环境造成的
   *   假失败，真实窗口是 1280x800，见 `shell.dart` 的 WindowOptions）。
   *   ★ 本仓既有测试（`shelf_card_opens_detail_test.dart`）就是这么处理的。
   */
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<MyShelfState>();
  await t.pumpWidget(
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
  await t.pump();
  key.currentState!.debugSetData(history: history, tab: ShelfTab.history);
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 第 1 层：写库读**活值**，不读 final 构造参数
  // ═══════════════════════════════════════════════════════════════════

  group('① 第 1 层（数据）：_saveProgress 必须读活值', () {
    test('★★★ `_saveProgress` 的 title/cover 不得再读 `widget.*`', () {
      final src = _src('lib/ui/player_page.dart');
      final i = src.indexOf('Future<void> _saveProgress(');
      expect(i, greaterThan(0), reason: '找不到 _saveProgress 实现');
      // 取到 `saveProgress(` 调用之后的一段（足够覆盖那个实参表）
      final body = src.substring(i, (i + 2500).clamp(0, src.length));

      expect(body.contains('title: _title'), isTrue,
          reason: '★★★ `_saveProgress` 的 title 必须读**活值** `_title` —— '
              '`widget.title` 在合并页里**恒为空串**（入口传 `title: ""`）'
              '⇒ 写进库就是空标题 ⇒ 播放记录显示「？」');
      expect(body.contains('cover: _cover'), isTrue,
          reason: '★★★ cover 必须读 `_cover` —— '
              '`widget.cover` 在合并页里**恒为 null**（入口根本没传 cover）');

      expect(body.contains('title: widget.title'), isFalse,
          reason: '★ 旧写法（读构造参数）必须已消失');
      expect(body.contains('cover: widget.cover'), isFalse,
          reason: '★ 旧写法（读构造参数）必须已消失');
    });

    test('★★ 兜底仍在（直播/遥控等路径不走 updateDisplayTitle）', () {
      final src = _src('lib/ui/player_page.dart');
      expect(src.contains('_title.isNotEmpty ? _title : widget.title'), isTrue,
          reason: '★ 必须保留 `widget.*` 兜底 —— 直播/遥控可能直接构造 '
              '`PlayerPage(title:, cover:)` 而从不走 updateDisplayTitle');
      expect(src.contains('_cover ?? widget.cover'), isTrue,
          reason: '★ cover 的兜底形态');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 展示元信息：标题与封面**各自独立**判断
  // ═══════════════════════════════════════════════════════════════════

  group('② 展示元信息：两字段独立', () {
    test('★★★ 接口签名必须能同时带 title 与 cover', () {
      final src = _src('lib/ui/media_session.dart');
      expect(
          src.contains('void updateDisplayTitle(String title, {String? cover})'),
          isTrue,
          reason: '★ 详情加载时手里**同时**有标题与封面 ⇒ 一次送达；'
              '若只有 title 参数，封面就永远传不到播放器（第 1 层永远写 null）');
    });

    test('★★★ `_onDetailLoaded` 必须把 cover 一起转发', () {
      final src = _src('lib/ui/media_page.dart');
      expect(src.contains('updateDisplayTitle(d.title, cover: d.cover)'), isTrue,
          reason: '★★★ 详情页手里有 `d.cover` —— 不转发它就永远进不了库。'
              '这正是「没有封面」那一半的根因。');
    });

    test('★★★ 两字段各自独立判断（不能互相清掉）', () {
      /*
       * ★ 这条是**前瞻性**判据 —— 请勿因"现实里看不出差别"而删除它。
       *
       * # 为什么现在测不出差别，却仍然要有
       *
       * 实测用户真实库：`title` 非空但 `cover` NULL = **0 行**
       * ⇒ 现实数据里两字段**同生同死**（一起有、一起无）
       * ⇒ 所以"独立判断"这个修复在**当前数据上观察不到差异**。
       *
       * 但它防的是**将来**只有一半信息的调用路径：
       * ```text
       * 若实现写成"任一为空就两个一起覆盖"：
       *   先到标题（cover 为 null）⇒ 会把已记住的封面清成 null
       *   先到封面（title 为空）  ⇒ 会把已记住的标题清成空
       * ⇒ 又回到「？」 —— 而且是**间歇性**的（取决于两次调用顺序）
       * ```
       * ★ 顺序敏感性正是"现实里看不出"却仍然危险的那类缺陷。
       */
      final src = _src('lib/ui/player_page.dart');
      final i = src.indexOf('void updateDisplayTitle(');
      expect(i, greaterThan(0), reason: '找不到 updateDisplayTitle 实现');
      final body = src.substring(i, (i + 2000).clamp(0, src.length));

      // 两个字段必须**各自**有"有没有新值"的判断
      expect(body.contains('newTitle'), isTrue,
          reason: '★ 标题要有独立的"有新值吗"判断');
      expect(body.contains('newCover'), isTrue,
          reason: '★ 封面要有独立的"有新值吗"判断');
      // 且必须**分别**赋值（不是一个 if 里一起写）
      expect(body.contains('if (newTitle != null) _title = newTitle;'), isTrue,
          reason: '★★★ 标题必须**单独**赋值 —— 若与封面写在同一个 if 里，'
              '就会"只传封面时把标题也覆盖掉"');
      expect(body.contains('if (newCover != null) _cover = newCover;'), isTrue,
          reason: '★★★ 封面必须**单独**赋值（对称理由）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 第 3 层：空标题**不得**渲染成 '?'
  // ═══════════════════════════════════════════════════════════════════

  group('③ 第 3 层（渲染）：空标题不画 "?"', () {
    test('★★★ poster_card 不得再有 `? \'?\'` 兜底', () {
      final src = _src('lib/ui/widgets/poster_card.dart');
      expect(src.contains("? '?'"), isFalse,
          reason: '★★★ 那个 `\'?\'` 就是 Owner 看到的字符。'
              '空标题时**没有"首字"可画** ⇒ "首字占位"策略不适用 ⇒ 必须换中性图形');
      expect(src.contains('Icons.movie_outlined'), isTrue,
          reason: '★ 空标题时应当画**中性图标**（不假装是数据、不像出错）');
    });

    test('★★ poster_card 是共享组件 —— 首字占位对非空标题仍然保留', () {
      final src = _src('lib/ui/widgets/poster_card.dart');
      expect(src.contains('characters.first'), isTrue,
          reason: '★ 非空标题仍走"首字占位"（5 个调用点都在用这个观感）—— '
              '不能为了修空标题把这个既有行为删掉');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 第 2 层 + 纯函数：兜底逻辑本身
  // ═══════════════════════════════════════════════════════════════════

  group('④ 第 2 层（传参）：逐级兜底 + 副标题不重复', () {
    test('★ my_shelf history 分支不得把空 title 原样传下去', () {
      final src = _src('lib/ui/widgets/my_shelf.dart');
      expect(src.contains('title: _historyTitle(p)'), isTrue,
          reason: '★★ 必须走兜底函数 —— 原来的 `title: p.title` 会把空串'
              '一路传到 PosterCard（第 2 层的缺口）');
      expect(src.contains('title: p.title,'), isFalse,
          reason: '★ 旧写法必须已消失');
    });

    test('★★★ 兜底链：title → episodeTitle → 中性占位（永不返回空串）', () {
      final src = _src('lib/ui/widgets/my_shelf.dart');
      final i = src.indexOf('static String _historyTitle(');
      expect(i, greaterThan(0), reason: '找不到 _historyTitle 实现');
      final body = src.substring(i, (i + 600).clamp(0, src.length));

      expect(body.contains('p.title'), isTrue, reason: '① 优先用正式标题');
      expect(body.contains('p.episodeTitle'), isTrue,
          reason: '② 退而求其次用集名（至少告诉用户"看到哪一集"）');
      expect(body.contains('（标题未知）'), isTrue,
          reason: '★★★ ③ **必须**有最终中性占位 —— '
              '实测那 3 条坏记录 `episode_title` **也是 NULL** ⇒ '
              '只做 ② 的话它们仍然是空，等于没修');
      expect(body.contains('?'), isFalse,
          reason: '★ 兜底里不得出现 "?" 字符');
    });

    test('★★★ 副标题不得与标题重复（加兜底时新引入的边角情况）', () {
      /*
       * 当 title 为空、episodeTitle 非空时：
       * ```text
       * 标题   = p.episodeTitle   ← 兜底来的
       * 副标题 = p.episodeTitle   ← 若照旧写法，同一句
       * ⇒ 卡片上出现**两遍同样的字**（"第01集" / "第01集"）
       * ```
       * ★ 这是"加兜底"这个动作**自己引入**的新情况 —— 必须一起处理。
       */
      final src = _src('lib/ui/widgets/my_shelf.dart');
      expect(src.contains('_historySubtitle(p)'), isTrue,
          reason: '★★★ 副标题必须走配对函数 —— 它要知道"标题用掉了什么"');
      final i = src.indexOf('static String _historySubtitle(');
      expect(i, greaterThan(0), reason: '找不到 _historySubtitle 实现');
      final body = src.substring(i, (i + 700).clamp(0, src.length));
      expect(body.contains('_historyTitle(p) == et'), isTrue,
          reason: '★ 判据必须复用 `_historyTitle`（同一个判据函数）—— '
              '若在这里重写一遍"title 是否为空"，两处判据会漂');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★★★ 真件渲染 —— 静态断言看不到"渲染出来是什么"
  // ═══════════════════════════════════════════════════════════════════
  //
  // ★ 为什么静态断言不够（本组的价值）
  // ```text
  // ④ 组断言的是源码里**没有** `? '?'` 这个字符串。
  // ★ 但 `? '？'`（全角）能绕过它，而用户看到的仍然是「？」。
  // ⇒ 只有**真的渲染再读文字**才能证明"用户看到的是什么"。
  // ```

  group('⑤ 真件渲染：用户**实际看到**的文字', () {
    testWidgets('⓪ 仪器自检：非空标题读得到（证明"读文字"没瞎）', (t) async {
      /*
       * ★ 这是本组的**阳性对照**：若仪器读不到明明存在的文字，
       *   那下面所有"不含 ?"的断言都是**假绿**（读不到任何东西时永远成立）。
       */
      await t.binding.setSurfaceSize(const Size(600, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_host(const PosterCard(title: '怒鲨狂潮')));
      await t.pump(const Duration(milliseconds: 50));

      expect(_allTexts(t), contains('怒鲨狂潮'),
          reason: '★ 仪器读不到已存在的标题 ⇒ 后面的"不含 ?"全是假绿');
    });

    testWidgets('★★★ PosterCard：空标题 ⇒ 不画 `?`（画中性图标）', (t) async {
      await t.binding.setSurfaceSize(const Size(600, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_host(const PosterCard(title: '')));
      await t.pump(const Duration(milliseconds: 50));

      final texts = _allTexts(t);
      expect(texts.any((s) => s.contains('?')), isFalse,
          reason: '★★★ 空标题时**不许**出现 `?` —— 那个字符就是 Owner 报的'
              '「显示 ？ 的记录」（UI 语义是"出错"，而这里没有出错）。'
              '实测文字=$texts');
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget,
          reason: '★★ 空标题应画中性图标 —— 什么都不画会让海报区像"图挂了"。'
              '实测文字=$texts');
    });

    testWidgets('★★ PosterCard：标题非空 ⇒ 仍走首字占位（正常路径没被改坏）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(600, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_host(const PosterCard(title: '怒鲨狂潮')));
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('怒'), findsOneWidget,
          reason: '★ 非空标题必须仍然显示首字（原版 `title.slice(0,1)`）—— '
              '别为了修空标题把 5 个调用点的既有观感改掉');
      expect(find.byIcon(Icons.movie_outlined), findsNothing,
          reason: '★ 有标题时**不该**画中性图标');
    });

    testWidgets('★★★ MyShelf 历史：喂用户库里那条坏记录 ⇒ 显示体面占位', (t) async {
      /*
       * ★ 这是**端到端**的那条：喂一条**与用户库里逐字段一致**的坏记录
       *   （`title=''`、`cover=NULL`、`episode_title=NULL` —— 三个值都是
       *    `.probe/t63_read_db.py` 实测出来的），断言卡片上的文字。
       */
      await _mountShelf(t, [_p(title: '', cover: null, episodeTitle: null)]);

      final texts = _allTexts(t);
      expect(texts.any((s) => s.contains('?')), isFalse,
          reason: '★★★ 空标题记录**不许**渲染出 `?`。实测文字=$texts');
      expect(texts.any((s) => s.contains('标题未知')), isTrue,
          reason: '★★★ 应显示体面占位「（标题未知）」。实测文字=$texts\n'
              '★ 注意：那 3 条坏记录 `episode_title` **也是 NULL** '
              '⇒ 只靠 episodeTitle 兜底不够，必须有最终中性占位');
    });

    testWidgets('★★ MyShelf 历史：标题空但 episodeTitle 有 ⇒ 用它兜底且不重复',
        (t) async {
      await _mountShelf(t, [_p(title: '', episodeTitle: '第01集')]);

      final texts = _allTexts(t);
      expect(texts.any((s) => s.contains('第01集')), isTrue,
          reason: '★ 有集名时应优先用它（比"标题未知"信息量大）。实测文字=$texts');
      expect(texts.any((s) => s.contains('标题未知')), isFalse,
          reason: '★ 有集名时不该再显示"标题未知"');
      expect(texts.where((s) => s.contains('第01集')).length, 1,
          reason: '★★「第01集」必须**只出现一次** —— 标题吃掉了它，'
              '副标题就不能再用（否则卡片上两遍同样的字）。实测文字=$texts');
    });

    testWidgets('★ MyShelf 历史：正常记录 ⇒ 原行为不变（防改坏）', (t) async {
      await _mountShelf(t, [_p(title: '无职转生', episodeTitle: '第01集')]);

      final texts = _allTexts(t);
      expect(texts.any((s) => s.contains('无职转生')), isTrue,
          reason: '★ 正常记录的标题必须原样显示');
      expect(texts.any((s) => s.contains('第01集')), isTrue,
          reason: '★ 正常记录的副标题应是集名（原行为）');
      expect(texts.any((s) => s.contains('标题未知')), isFalse,
          reason: '★ 正常记录不该出现占位文案');
    });

    testWidgets('★★★ 反面：仪器能读到 `?`（否则"不含 ?"是假绿）', (t) async {
      /*
       * ★ 元判据：故意渲染一个 `?`，证明"不含 ?"这条断言**有分辨力**。
       *   若仪器恒假（读不到任何文字），"不含 ?" 永远成立 ⇒ 假绿。
       */
      await t.binding.setSurfaceSize(const Size(600, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_host(const Center(child: Text('?'))));
      await t.pump(const Duration(milliseconds: 50));

      expect(_allTexts(t).any((s) => s.contains('?')), isTrue,
          reason: '★★★ 仪器**必须**能读到 `?` —— 否则本组所有"不含 ?"'
              '的断言都是假绿（读不到文字时永远成立）');
    });
  });
}
