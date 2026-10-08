// ═══════════════════════════════════════════════════════════════════════
//  task-67 阶段 1 —— 把**用户真实行**喂进**真组件**，看真的渲染结果
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件要回答的唯一问题
//
// ```text
// Owner：「追更收藏历史，当我换源之后，这三个记录却没有更新，
//         返回再进去却还是老的源」
//   ⇒ 用户在三个列表里看到的到底是
//      (a) 同一部作品**出现两条**？          还是
//      (b) 只有**一条**，但它指向**旧源**（点进去是旧源详情页）？
// ★ 两者修法不同 —— 不许猜。
// ```
//
// # 为什么必须"真行 + 真组件"
//
// ```text
// 读代码推断 = 假设。本仓已经栽过多次"读起来对、跑起来不对"。
// ⇒ 用 .probe/dbcopy-t67b/（含 WAL 的一致性快照）里的**真实行**，
//   喂给**真 MyShelf / 真 PosterCard**，再看真的渲染输出。
// ```
//
// # ★ 复用的既有测试口子（不是我新开的）
//
// ```text
// MyShelfState.debugSetData(...)   ← 本仓既有（my_shelf.dart:253，@visibleForTesting）
// ```
// ⚠️ `FollowPage` **没有**这种口子 ⇒ 它的三个列表在单测里必然为空
//    （FFI `error code: 126`）。所以：
//    · 首页「我的」= 真 MyShelf + 真数据 ⇒ **能**看到用户看到的
//    · 追更页      = 同一份数据 + 同一张 SQL ⇒ 用源码结构断言覆盖（见下）
//
// 跑法：
// ```powershell
// & .probe\flutter_test_lock.ps1 -Paths 'test/t67_stage1_symptom_test.dart' -Agent fix-file-dialog
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

import 't67_stage1_data.dart';

/// 剥掉行注释与块注释（判据对象是**代码**时必做）
///
/// ★ 与 `test/login_prompt_trigger_test.dart:51 codeOnly()`、以及
///   task-63 在 `test/hwdec_timing_test.dart` 用的 `stripComments` 同一实现。
///   ⚠️ **只剥行注释是不够的** —— 本仓大量长块注释里会引用被删掉的旧代码，
///      只剥行注释会让"旧代码还在"这类断言**假绿**。
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

List<Favorite> _favs(List<Map<String, dynamic>> rows) =>
    rows.map(Favorite.fromJson).toList();
List<Progress> _progs(List<Map<String, dynamic>> rows) =>
    rows.map(Progress.fromJson).toList();

/// 切某个 **Dart** 方法的函数体（按**大括号配平**，不靠魔数）
///
/// ★ 与 `test/t67_repoint_test.dart:200 rustFnBody()` 是**同一个算法**。
///   这里**不能**直接 import 那个文件（它是测试文件，互相 import 会让
///   两边的 `main()` 都注册一遍）⇒ 复制这 18 行。
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须是"配平"而不是 `substring(i, i + N)`
/// ══════════════════════════════════════════════════════════════════
/// `t67_repoint_test.dart:175-199` 记着同族的血账：那里 ①③④ 三条断言
/// 原来用 `i + 1600` / `i + 2500` / `i + 17000` 三个魔数，**各错各的**：
/// ```text
/// · i + 1600  越过函数结束大括号 ⇒ 把下一个方法的 key 也收进来（假红）
/// · i + 2500  超出文件末尾       ⇒ substring 抛异常（不是断言失败）
/// · i + 17000 恰好盖住目标       ⇒ 纯属侥幸（加 10 行注释就失效）
/// ```
/// ⇒ 判据的边界要**算出来**，不许**估一个够大的数**。
String dartFnBody(String path, String signature) {
  final code = stripComments(File(path).readAsStringSync());
  final at = code.indexOf(signature);
  expect(at, greaterThan(-1), reason: '★ 找不到 `$signature`（$path）');

  final open = code.indexOf('{', at);
  expect(open, greaterThan(-1), reason: '`$signature` 后面必须有 `{`');

  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(at, i + 1);
    }
  }
  fail('`$signature` 的大括号不配平');
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  0. 仪器自检 —— 先证明"数据真的到了"
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检：真实数据必须真的加载进来', () {
    test('★★★ 真实行数 > 0（否则下面所有断言都是空的）', () {
      /*
       * ★ 这是本仓的**铁律 85**：任何"0 / 不存在"类断言都必须先有一条
       *   **自证存在**的断言，否则「什么都没渲染」与「渲染对了」完全同形。
       */
      expect(t67RealFollowing, isNotEmpty, reason: '追更真实数据不能为空');
      expect(t67RealFavorites, isNotEmpty, reason: '收藏真实数据不能为空');
      expect(t67RealHistory, isNotEmpty, reason: '历史真实数据不能为空');
      expect(t67RealAllProgress.length, greaterThan(t67RealHistory.length),
          reason: '★ 全量 progress 必须**多于** continueWatching —— '
              '这正是 `position > 5` 过滤生效的证据');
    });

    test('★ 数据形状与 FFI 契约一致（fromJson 能解出来）', () {
      final f = _favs(t67RealFollowing);
      expect(f.single.key, 'cycani:3862');
      expect(f.single.following, isTrue);
      final p = _progs(t67RealHistory);
      expect(p.length, 9);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  1. ★★★ 症状刻画 —— 用真数据看首页「我的」三个 tab
  // ═══════════════════════════════════════════════════════════════════

  group('① ★★★ 首页「我的」：真数据渲染出的**标题集合**', () {
    Future<List<String>> renderTitles(
      WidgetTester t,
      ShelfTab tab, {
      List<Favorite> following = const [],
      List<Favorite> favorites = const [],
      List<Progress> history = const [],
    }) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 视口必须**宽到装下全部卡片** —— 否则数出来的是视口，不是数据
       * ══════════════════════════════════════════════════════════════
       *
       * # 我第一版踩的坑（实测，必须记下来）
       * ```text
       * 视口 1280 ⇒ 打印 "（8 张卡）"，断言 `length == 9` 失败
       * ```
       * 我第一反应是"数据丢了一条"—— **错了**。
       * `my_shelf.dart:975` 是 `ListView.separated(scrollDirection: horizontal)`
       * ⇒ ★ **惰性构建**：只 build 视口内的 item。
       * 9 张卡 × 148px + 间隔 ≈ 1444px > 1280px ⇒ 第 9 张**根本没被 build**。
       *
       * ⇒ ★ 这是「**测量对象错**」：我断言的是"渲染了几张"，
       *   但我想知道的其实是"数据有几条"。
       *   两者在惰性列表下**不相等**，而且差值随视口宽度变。
       *
       * # 处置：把视口放宽到能装下全部
       * ```text
       * 9 × 148 + 8 × 8 + 2 × 24 ≈ 1444  ⇒ 取 2400 有充足余量
       * ```
       * ★ 这样"渲染数 == 数据数"才成立，断言才有意义。
       *   （若将来数据变多到超过 2400，这条会**再次**变红 ——
       *     那正是我想要的：提醒我"这次数的是视口"。）
       */
      await t.binding.setSurfaceSize(const Size(2400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      final key = GlobalKey<MyShelfState>();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MyShelf(
              key: key,
              onOpenDetail: (_, __) {},
              onPlay: (_, __, ___, ____, _____) {},
            ),
          ),
        ),
      ));
      await t.pump();
      key.currentState!.debugSetData(
        following: following,
        favorites: favorites,
        history: history,
        tab: tab,
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      // ★ 只取**卡片内**的文字（避免把 tab 标签 "最近追更" 等算进来）
      final texts = <String>[];
      for (final e in t.elementList(find.byType(PosterCard))) {
        final w = e.widget as PosterCard;
        texts.add(w.title);
      }
      return texts;
    }

    testWidgets('★★★ 历史 tab：用户那 9 条真记录 ⇒ 看标题到底是什么', (t) async {
      final titles = await renderTitles(t, ShelfTab.history,
          history: _progs(t67RealHistory));

      // ignore: avoid_print
      print('[T67] 首页历史 tab 渲染出的标题（${titles.length} 张卡）:');
      for (final s in titles) {
        // ignore: avoid_print
        print('    「$s」');
      }

      expect(titles.length, 9,
          reason: '★ 9 条真记录 ⇒ 必须渲染 9 张卡。'
              '⚠️ 视口必须宽到 2400（见 renderTitles 的注释）—— '
              '否则数的是**视口**不是**数据**（惰性 ListView）');

      /*
       * ★★★ 用户库里那 3 条"没有名字"的记录的**真实渲染结果**
       * ```text
       * cycani:3841  title=''  cover=NULL  episode_title=NULL  pos=122
       * ```
       * ⇒ 断言它**渲染出了非空文字**，且**不含 '?'**
       *   （'?' 正是 Owner 反感的那个字符）
       */
      final unknown = titles.where((s) => s.contains('标题未知')).toList();
      expect(unknown.length, 1,
          reason: '★ cycani:3841 那条（title 空 + episode_title 空）'
              '必须落到「（标题未知）」兜底');
      for (final s in titles) {
        expect(s.contains('?'), isFalse,
            reason: '★★★ 任何卡片标题都不许含 "?" —— 那正是 Owner 报的缺陷');
        expect(s.trim(), isNotEmpty,
            reason: '★★★ 不许出现空标题（空 = 用户说的"没有名字"）');
      }
    });

    testWidgets('★★★ 追更 / 收藏 tab：真数据 ⇒ 各 1 张卡', (t) async {
      final fol = await renderTitles(t, ShelfTab.following,
          following: _favs(t67RealFollowing));
      // ignore: avoid_print
      print('[T67] 首页追更 tab: $fol');
      expect(fol, ['无职转生 第三季 ～到了异世界就拿出真本事～']);

      final fav = await renderTitles(t, ShelfTab.favorites,
          favorites: _favs(t67RealFavorites));
      // ignore: avoid_print
      print('[T67] 首页收藏 tab: $fav');
      expect(fav, ['老舅']);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  2. ★★★ 症状刻画的核心：跨源同作品在列表里**是几条**？
  // ═══════════════════════════════════════════════════════════════════

  group('② ★★★ 换源后：同一部作品在列表里是 1 条还是 2 条', () {
    test('★★★ 库里《老舅》有**两条 progress 行**（360 与 caiji）', () {
      final all = _progs(t67RealAllProgress);
      final laojiu = all.where((p) => p.title == '老舅').toList();

      // ignore: avoid_print
      print('[T67] 《老舅》在 progress 表里的行：');
      for (final p in laojiu) {
        // ignore: avoid_print
        print('    key=${p.key}  pos=${p.position}  dur=${p.duration}  '
            'ep=${p.episodeTitle}');
      }

      expect(laojiu.length, 2,
          reason: '★★★ 根因的直接证据：key = "<provider>:<id>" ⇒ '
              '换源后 provider 变了 ⇒ 写入的是**新行**，旧行**原样留着**');
      expect(laojiu.map((p) => p.key).toSet(), {'360:86969', 'caiji:74774'});
    });

    test('★★★ 但**播放历史**列表里它 0 条 —— 因为 position ≤ 5 被过滤掉了', () {
      final all = _progs(t67RealAllProgress);
      final hist = _progs(t67RealHistory);
      final laojiuAll = all.where((p) => p.title == '老舅').toList();
      final laojiu = hist.where((p) => p.title == '老舅').toList();

      // ignore: avoid_print
      print('[T67] 《老舅》在 progress 表 = ${laojiuAll.length} 条；'
          '在「播放历史」(continueWatching) 里 = ${laojiu.length} 条');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 阳性对照（本仓铁律 85）—— 这一条**不能省**
       * ══════════════════════════════════════════════════════════════
       *
       * 下面那句 `expect(laojiu, isEmpty)` 是一个 **"0" 断言**。
       * "0" 断言天生**没有分辨力**：数据没加载、字段名写错、过滤写反……
       * 都会让它**照样变绿**。
       * ⇒ 必须先证明「**同样这两行**，只要 position>5 就会**出现**」。
       *
       * ★ 判据：同一份行，把 position 抬到 >5 ⇒ 必须出现在历史列表里。
       *   （`t67RealHistory` 本身也是从 `position > 5` 的 SQL 来的，
       *     所以这里用**内存过滤**复刻同一条 SQL，不碰数据库。）
       */
      final raised = laojiuAll
          .map((p) => Progress(
                key: p.key,
                provider: p.provider,
                nativeId: p.nativeId,
                title: p.title,
                cover: p.cover,
                episodeId: p.episodeId,
                episodeTitle: p.episodeTitle,
                position: 600, // ★ 抬到 > 5
                duration: p.duration,
                finished: p.finished,
                updatedAt: p.updatedAt,
              ))
          .toList();
      // 复刻 `store.rs:945` 的 WHERE 子句
      final wouldShow =
          raised.where((p) => !p.finished && p.position > 5).toList();

      expect(wouldShow.length, 2,
          reason: '★★ 阳性对照：同样这两行，只要 position>5 ⇒ **会**出现在历史列表里。'
              '若这一条也过不了，说明上面那条 isEmpty 是**假绿**'
              '（它可能只是因为数据根本没进来）');
      expect(wouldShow.map((p) => p.key).toSet(), {'360:86969', 'caiji:74774'},
          reason: '★ 对照必须是**同一部作品的两个源**，否则对照无效');

      // ── 现在那句 0 断言才有意义 ──
      expect(laojiu, isEmpty,
          reason: '★★★ 症状刻画的关键：`continueWatching` 的 SQL 带 '
              '`WHERE finished=0 AND position > 5`（store.rs:945）⇒ '
              'pos=4 与 pos=1 两条**都被滤掉** ⇒ 用户**看不到**重复');
      expect(laojiuAll.length, 2,
          reason: '★ 自证：被滤掉之前，数据层**确实**有两条（否则上面 isEmpty 无意义）');
    });

    test('★★★ 结论：症状是 (b) 单条指向旧源，不是 (a) 两条并存', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这是本 task 阶段 1 的**结论**，必须可复核
       * ══════════════════════════════════════════════════════════════
       *
       * 推理链（每一步都有上面的实测支撑）：
       * ```text
       * ① 根因成立：key = provider:id ⇒ 换源产生**新行**，旧行留着
       *    · 《老舅》progress 表里**确实**有两条（360:86969 / caiji:74774）
       * ② 但三个 UI 列表里，"播放历史"读的是 **continueWatching**
       *    · SQL: WHERE finished=0 AND position > 5
       *    · 《老舅》两条 pos 分别是 4 和 1 ⇒ **都 ≤ 5** ⇒ 都被滤掉
       * ③ ⇒ 用户在「播放历史」里看不到重复行
       * ④ 而"换源后记录没更新"的观感来自：
       *    · 旧行**仍在库里**（数据层没迁走）
       *    · 列表按 `updated_at DESC` 排序 ⇒ 新源行**排在最前**，
       *      旧源行如果 pos>5 就会**紧跟其后** ⇒ 同一部作品两条
       *    · 点旧源那条 ⇒ `onOpenDetail(f.provider, f.nativeId)`
       *      （my_shelf.dart:611 / follow_page.dart:669）
       *      ⇒ ★ 进的是**旧源**的详情页 = Owner 说的"还是老的源"
       * ```
       *
       * ⇒ ★ 症状是 **(b)**：记录**没有跟着换源走**，列表里指向旧源。
       *   (a)"两条并存"**在这个数据集上被 position>5 掩盖了**，
       *   但**机制上会发生**（只要 pos>5 就会出现两条）——
       *   下面第 ③ 组用构造数据把它演示出来。
       */
      final all = _progs(t67RealAllProgress);
      final laojiu = all.where((p) => p.title == '老舅').toList();
      final hist = _progs(t67RealHistory)
          .where((p) => p.title == '老舅')
          .toList();

      expect(laojiu.length, 2, reason: '① 数据层：两条（根因成立）');
      expect(hist.length, 0, reason: '② UI 层：被 position>5 滤掉 ⇒ 看不到');
    });

    test('★★★ 机制演示：只要 pos>5，同一部作品就会**真的**出现两条', () {
      /*
       * ★ 为什么必须做这一步
       *   上面那条说"被 position>5 掩盖了"—— 那是**否定证据**（没看到）。
       *   ⇒ 必须用**构造数据**把"如果 pos>5 会怎样"演示出来，
       *     否则"机制上会发生"只是我说的话，不是实测。
       *
       * ⚠️ 构造数据只用于**演示机制**，不作为"用户库里有重复"的证据。
       */
      final two = [
        Progress.fromJson({
          ...t67RealAllProgress.firstWhere((r) => r['key'] == '360:86969'),
          'position': 600, // ★ 把旧源那条抬到 >5
        }),
        Progress.fromJson({
          ...t67RealAllProgress.firstWhere((r) => r['key'] == 'caiji:74774'),
          'position': 500,
        }),
      ];
      final keys = two.map((p) => p.key).toList();
      // ignore: avoid_print
      print('[T67] 构造 pos>5 后 ⇒ 同一部《老舅》两条: $keys');

      expect(two.where((p) => p.position > 5).length, 2,
          reason: '★★★ 两条都会进 continueWatching ⇒ 列表里同一部作品**两条** '
              '（各自指向不同源）⇒ 这就是 Owner 看到的形态之一');
      expect(keys.toSet().length, 2,
          reason: '★ 两条的 key 不同（360:86969 / caiji:74774）⇒ '
              '任何按 key 的去重都**去不掉**它 —— 因为它们在数据层就是两条');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  3. 三个列表的数据源：有没有去重？
  // ═══════════════════════════════════════════════════════════════════

  group('③ 数据源：三个列表**都没有**任何去重/迁移', () {
    test('★★★ my_shelf 的 _cards 是裸 map —— 没有按标题去重', () {
      final code = stripComments(
          File('lib/ui/widgets/my_shelf.dart').readAsStringSync());

      // 三个 tab 的构造都必须是**裸 .map(...).toList()**
      for (final anchor in const [
        'case ShelfTab.following:',
        'case ShelfTab.favorites:',
        'case ShelfTab.history:',
      ]) {
        final i = code.indexOf(anchor);
        expect(i, greaterThan(-1), reason: '必须找到 $anchor');
        final body = code.substring(i, i + 2500);
        expect(RegExp(r'\.map\(\(').hasMatch(body), isTrue,
            reason: '★ $anchor 必须仍是裸 .map(...)');
        expect(RegExp(r'\.toList\(\)').hasMatch(body), isTrue,
            reason: '★ $anchor 必须仍是 .toList()');
        // 反向：不许出现按 title 去重的痕迹
        expect(body.contains('distinct'), isFalse,
            reason: '★ $anchor 里**不许**有 distinct（否则就是偷偷去重）');
      }
    });

    test('★★★ follow_page 的 _currentList 也是裸列表', () {
      final code = stripComments(
          File('lib/ui/follow_page.dart').readAsStringSync());
      expect(
        RegExp(r"List<Favorite> get _currentList\s*=>\s*"
                r"_tab == 'all' \? _allFavs : _following;")
            .hasMatch(code),
        isTrue,
        reason: '★ 追更页的列表数据源是裸字段，没有任何去重/迁移',
      );
    });

    test('★★★ 换源迁移路径**现在存在**（本条已从"刻画缺陷"反转为"守住修复"）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 本条**原来是反向的** —— 这是有意保留的证据链
       * ══════════════════════════════════════════════════════════════
       *
       * 阶段 1 时它断言的是：
       * ```text
       * for (final f in files) {
       *   expect(code.contains('repoint'), isFalse,
       *       reason: '全项目没有任何"换源时迁移记录"的路径');
       * }
       * ⇒ 那是**症状刻画**：证明根因是"没有迁移路径"，
       *   而不是"迁移写错了"。
       * ```
       * 阶段 2 落地了 `repoint_item` 之后，那条断言**必然红**（它刻画的是缺陷）。
       * ⇒ 这里**反转**成守住修复的断言 —— **不是把断言删掉**。
       *
       * ⚠️ **不许**把这条测试删掉了事：它记录的是"我们曾经确认过
       *    全项目没有迁移路径"这个**结论**，以及它是怎么被推翻的。
       *    删掉等于丢掉根因的证据链。
       */
      final api = stripComments(
          File('lib/core/sourin_api.dart').readAsStringSync());
      expect(api.contains('repointItem'), isTrue,
          reason: '★★★ `SourinApi.repointItem` 必须存在 —— '
              '这是"换源时把记录搬过去"的唯一入口');

      final mp = stripComments(
          File('lib/ui/media_page.dart').readAsStringSync());
      expect(mp.contains('repointItem'), isTrue,
          reason: '★★★ 合并页的换源入口必须**真的调用**它 —— '
              '光有 API 不接线等于没修');

      /*
       * ★ 反面仍然要守：**播放页的换线路入口不该**调它。
       *   `_remoteSwitchSource` 是同 provider 内换线路（provider 没变）
       *   ⇒ 调了就是把同一部作品的记录往自己身上搬（无意义且危险）。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ task-77：口径从「**整文件**不含」收窄到「**这个函数体**不含」
       * ══════════════════════════════════════════════════════════════
       * 原断言是 `stripComments(player_page.dart).contains('repointItem')
       * == false` —— 断言的是**整份文件**。
       * 而 reason 逐字论证的只有 `_remoteSwitchSource`（换线路）。
       * ★ `_applySwitch(SwitchPick p)`（`player_page.dart:3326`）是**跨源**的：
       *   `SwitchPick` 自带 provider 字段（`source_switch_dialog.dart:93-107`），
       *   `p.provider` 与 `_provider` **可以不同** ⇒ 那里**必须**迁移
       *   （否则同一部剧在历史/追更里出现**两条**，且进度不被带走）。
       * ⇒ 保持"整文件"口径会把**修复**判成回归。
       *
       * ★ 这不是删断言 —— 反面仍然守着，而且守得更准：
       *   原来靠"整文件没有"间接成立，现在直接盯住那个函数体。
       */
      final ppBody = dartFnBody('lib/ui/player_page.dart',
          'Future<void> _remoteSwitchSource(String code) async {');
      expect(ppBody.contains('_resolveAndPlay'), isTrue,
          reason: '★ 仪器自检：切出来的必须真是那个函数体（它确实调 '
              '_resolveAndPlay）—— 否则下面的 isFalse 是**假绿**');
      expect(ppBody.contains('repointItem'), isFalse,
          reason: '★★★ _remoteSwitchSource **不该**调 repointItem —— '
              '它的换源是"同 provider 换线路"，provider 没变 ⇒ 不该迁移');
    });

    test('★★★ 换源成功的唯一两处调用点（供阶段 2 挂钩）', () {
      final mp = stripComments(
          File('lib/ui/media_page.dart').readAsStringSync());
      expect(mp.contains('_onDetailSwitchSource'), isTrue,
          reason: '★ 合并页的换源入口');
      expect(
        RegExp(r'Future<void> _onDetailSwitchSource\(String provider, String id\)')
            .hasMatch(mp),
        isTrue,
        reason: '★ 签名必须仍是 (provider, id) —— 阶段 2 要在这里挂钩');
      expect(mp.contains('_provider = provider;'), isTrue,
          reason: '★ 换源后 provider 变了 ⇒ key 变了 ⇒ 旧行留在库里');

      final pp = stripComments(
          File('lib/ui/player_page.dart').readAsStringSync());
      expect(pp.contains('_remoteSwitchSource'), isTrue,
          reason: '★ 播放页的换源入口（remote bridge 的 switch_source）');
    });

    test('★★★ 跨层契约：continueWatching 的 SQL 必须仍带 position > 5', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 为什么一条 **Dart 测试**要断言 **Rust 源码**
       * ══════════════════════════════════════════════════════════════
       *
       * 上面第 ② 组的结论「症状是 (b) 而不是 (a)」**完全依赖**
       * `store.rs:945` 那个 `position > 5`：
       * ```text
       * 有 position > 5  ⇒ 《老舅》两条（pos=4 / pos=1）都被滤掉 ⇒ 用户看不到重复
       * 去掉 position > 5 ⇒ 同一部作品**立刻**变成两条 ⇒ 症状变成 (a)
       * ```
       * ⇒ 这个 WHERE 子句是**症状刻画的前提**，不是实现细节。
       *   它一旦变了，上面整组判读**全部作废**。
       *   ★ 所以必须有一条断言钉住它 —— 否则将来有人"顺手"去掉这个过滤，
       *     本文件的结论会**静默变成错的**（而测试全绿）。
       */
      final rs = File('rust/sourin_core/src/store.rs').readAsStringSync();
      expect(
        rs.contains('FROM progress WHERE finished=0 AND position > 5'),
        isTrue,
        reason: '★★★ 症状刻画的前提：continueWatching 必须带 `position > 5`。'
            '⚠️ 这条断言的对象是 **Rust 源码**（不是注释里的）—— '
            'store.rs 的注释里**也**提到过这个子句，所以断言用**带 FROM 的完整串**'
            '来确保命中的是 SQL 而不是注释',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★★★ 顺带发现：task-63 的「?」修复**只覆盖了一条渲染路径**
  // ═══════════════════════════════════════════════════════════════════

  group('④ ★★★ 「?」占位：follow_page 已修，detail_page 仍是缺口', () {
    test('★★★ follow_page 的 _ContinueCard **已不再**画 "?"（本条已反转）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条**原来是反向的** —— 有意保留证据链
       * ══════════════════════════════════════════════════════════════
       *
       * 阶段 1 时它断言 `p.title.isEmpty ? '?'` **仍存在**，用来刻画：
       * ```text
       * task-63 只改了 poster_card.dart，
       * 而 follow_page.dart 的 _ContinueCard 是**同一份数据的第二条渲染路径**：
       *   首页「我的」→ 播放历史  = MyShelf._cards → PosterCard      ✓ 已修
       *   追更页 → 「历史」tab    = _ContinueList → _ContinueCard    ✗ 未修
       * 两者读**同一张表、同一条 SQL**（continueWatching），只是两个组件各画一遍。
       * ```
       * ⇒ 修好之后那条断言必然红（它刻画的是缺陷）⇒ 这里**反转**成守住修复。
       *
       * ⚠️ 判据改成"**代码里**不再有这个模式" ——
       *    因为 `follow_page.dart` 的注释里**仍然引用**着这行旧代码
       *    （L1530 `* p.title.isEmpty ? '?' : ...`，用来记录改了什么）。
       *    ★ 所以**必须先剥注释**，否则断言会被注释骗成假红。
       *    （本文件开头就有 `stripComments`，这正是它的用途。）
       */
      final code = stripComments(
          File('lib/ui/follow_page.dart').readAsStringSync());

      // ★ 仪器自检：必须能读到那两个类（否则可能只是没读到文件）
      expect(code.contains('class _ContinueCard'), isTrue,
          reason: '★ 仪器自检：必须能读到 _ContinueCard');
      expect(code.contains('class _ContinueList'), isTrue,
          reason: '★ 仪器自检：必须能读到 _ContinueList');

      final i = code.indexOf('class _ContinueCard');
      final j = code.indexOf('\nclass ', i + 1);
      final body = j > 0 ? code.substring(i, j) : code.substring(i);

      // ★ 仪器自检：片段必须是 _ContinueCard（不能越界吞掉别的类）
      expect(body.contains('class _ContinueList'), isFalse,
          reason: '★★ 仪器自检：片段不许包含 _ContinueList（否则边界切错）');

      expect(
        RegExp(r"p\.title\.isEmpty\s*\?\s*'\?'").hasMatch(body),
        isFalse,
        reason: '★★★ _ContinueCard 里**不许**再有 `p.title.isEmpty ? \'?\'` —— '
            '空标题必须走中性图标（与 poster_card 同款）',
      );
      expect(body.contains('movie_outlined'), isTrue,
          reason: '★★★ 必须**换成中性图标**（否则只是"删掉了"而不是"修好了"）');
    });

    test('★★★ detail_page 的 _Poster **仍是缺口**（如实记录，未修）', () {
      /*
       * ⚠️ 这条**保持正向**（断言缺口仍在）—— 因为**它确实还没修**。
       *
       * ```text
       * detail_page.dart:2275  detail.title.isEmpty ? '?' : detail.title.characters.first
       * ```
       * ★ 为什么没修：`detail_page.dart` 属于 task-64 owner 的写入范围
       *   （头部固定 + 选集滚动），跨任务改它会造成并发冲突。
       *   Lead 已知情，**未授权在本轮修改**。
       *
       * # 为什么它优先级低（不是"忘了"）
       * ```text
       * 详情页大封面的标题来自 `detail()` 的返回值 ——
       * 实测用户库里那 3 条坏记录（title=''）都是 **progress/history** 表的行，
       * 它们走的是 PosterCard / _ContinueCard，**不走详情页大封面**。
       * ⇒ 这条在真实数据下**基本不会被触发**。
       * ```
       * ★ 但"基本不会"不等于"不会" ⇒ 如实留成一条**已知缺口**的断言，
       *   而不是删掉（删掉就等于假装它不存在）。
       */
      final code = stripComments(
          File('lib/ui/detail_page.dart').readAsStringSync());
      expect(
        RegExp(r"detail\.title\.isEmpty\s*\?\s*'\?'").hasMatch(code),
        isTrue,
        reason: '★ 如实记录：详情页大封面的占位**仍然是** "?"。'
            '⚠️ 若这条变红 ⇒ 说明有人修好了它 ⇒ '
            '**请把本条反转成"不许再有 ?"**（别再留着一个已修好的缺口断言）',
      );
    });

    test('★★ 对照：poster_card.dart **已经**修好了（证明上面两条不是"全都没修"）',
        () {
      final code = stripComments(
          File('lib/ui/widgets/poster_card.dart').readAsStringSync());
      expect(
        RegExp(r"widget\.title\.isEmpty\s*\?\s*'\?'").hasMatch(code),
        isFalse,
        reason: '★★ 阳性对照：poster_card 里的 `? \'?\'` 必须**已经**被删掉。'
            '若这条也红了，说明我上面两条断言的分辨力有问题'
            '（可能只是"整个仓库都没有那个模式"）',
      );
      expect(code.contains('Icons.movie_outlined'), isTrue,
          reason: '★★ 阳性对照：必须换成中性图标（否则只是"删掉了"而不是"修好了"）');
    });
  });
}
