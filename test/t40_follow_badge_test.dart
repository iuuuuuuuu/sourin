// ═══════════════════════════════════════════════════════════════════════
//  task-40 追更徽标 = 「总集数 − 已看集数」（还剩几集没看）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
//
// > 底部的菜单栏，追更默认就显示  3  徽标，这是错误的
// > 首页的追更  底部的追更 追更页面的追更   这几个都应该按照这个追更这个剧
// > 还有多少集没看来显示这个徽标，比如 12集，只看了一集 就显示11，
// > 以此类推，当往后看到12集则计数器为0，纠正一下这里的逻辑
//
// # 这个文件守什么
//
// ```text
// ① 算法本体（followRemaining）—— 用户举的例子必须**逐字**成立
// ② 边缘情况（每一条都有理由，不是拍脑袋）
// ③ ★ 三处**共用同一个函数**（防"两处同构漂了"——本项目踩过）
// ④ ★ 硬编码 3 **不许回来**
// ```
//
// # ★ 为什么要有 ③（源码契约）
//
// 用户明确点了**三个**界面。若哪天有人把某一处改回 `f.unreadCount`，
// 行为测试**测不出来**（三处各自渲染，各自都对）。所以额外用
// "源码里不许出现旧字段"的契约测试兜住 —— 与 task-36 里
// 「三个 catchError 不得返回空列表」是同一个思路。
//
// ⚠️ 先剥注释（铁律⑤：grep 命中注释会造成假断言）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

// ═══════════════════════════════════════════════════════════════════════
//  造数据
// ═══════════════════════════════════════════════════════════════════════

Favorite fav(String id, {int lastEpisodeCount = 0, int unread = 0}) =>
    Favorite.fromJson(<String, dynamic>{
      'key': 'cycani:$id',
      'provider': 'cycani',
      'native_id': id,
      'title': '测试剧 $id',
      'cover': null,
      'kind': 'series',
      'favorited': true,
      'following': true,
      'last_episode_count': lastEpisodeCount,
      'unread_count': unread,
      'unreadCount': unread,
    });

Progress prog(String id, {String? episodeId, String? episodeTitle}) =>
    Progress.fromJson(<String, dynamic>{
      'key': 'cycani:$id',
      'provider': 'cycani',
      'native_id': id,
      'title': '测试剧 $id',
      'episode_id': episodeId,
      'episode_title': episodeTitle,
      'position': 100.0,
      'duration': 600.0,
      'finished': false,
    });

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① ★★★ 用户举的例子必须逐字成立
  // ═══════════════════════════════════════════════════════════════════
  group('① 用户举的例子（12 集剧）', () {
    test('★★ 全 12 集，看到第 1 集 ⇒ 显示 11', () {
      expect(
        followRemaining(
          totalEpisodes: 12,
          watchedEpisodeId: 'ep1',
          episodeIds: const ['ep1', 'ep2', 'ep3', 'ep4', 'ep5', 'ep6',
              'ep7', 'ep8', 'ep9', 'ep10', 'ep11', 'ep12'],
        ),
        11,
        reason: '★ 用户原话：「比如 12集，只看了一集 就显示11」',
      );
    });

    test('★★ 全 12 集，看到第 12 集 ⇒ 0（徽标消失）', () {
      expect(
        followRemaining(
          totalEpisodes: 12,
          watchedEpisodeId: 'ep12',
          episodeIds: const ['ep1', 'ep2', 'ep3', 'ep4', 'ep5', 'ep6',
              'ep7', 'ep8', 'ep9', 'ep10', 'ep11', 'ep12'],
        ),
        0,
        reason: '★ 用户原话：「当往后看到12集则计数器为0」'
            '—— 0 在 UI 层意味着**徽标消失**（PosterCard/bottom bar '
            '都是 `> 0` 才画）',
      );
    });

    test('★ 中间值逐点核对（第 2/5/11 集）', () {
      const eps = ['ep1', 'ep2', 'ep3', 'ep4', 'ep5', 'ep6',
          'ep7', 'ep8', 'ep9', 'ep10', 'ep11', 'ep12'];
      expect(followRemaining(
          totalEpisodes: 12, watchedEpisodeId: 'ep2', episodeIds: eps), 10);
      expect(followRemaining(
          totalEpisodes: 12, watchedEpisodeId: 'ep5', episodeIds: eps), 7);
      expect(followRemaining(
          totalEpisodes: 12, watchedEpisodeId: 'ep11', episodeIds: eps), 1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 边缘情况（每条都有理由）
  // ═══════════════════════════════════════════════════════════════════
  group('② 边缘情况', () {
    test('★ 下季更新（12→13），看到第 12 集 ⇒ 显示 1', () {
      /*
       * 这正是"必须用**当前**总集数"的理由：
       * `last_episode_count` 每轮巡检被更新成 new_count（follow.rs:109）
       * ⇒ 下季播出后它会变成 13 ⇒ 12 集看完的用户看到 "1"。
       */
      expect(
        followRemaining(
          totalEpisodes: 13,
          watchedEpisodeId: 'ep12',
          episodeIds: List.generate(13, (i) => 'ep${i + 1}'),
        ),
        1,
        reason: '★ 用"追更时的基准集数"就会永远显示 0 —— 那是错的',
      );
    });

    test('★ 没看过（watched == null）⇒ 0，不显示', () {
      expect(
        followRemaining(totalEpisodes: 12, watchedEpisodeId: null),
        0,
        reason: '★ 设计决定：刚追更一部 100 集的剧立刻显示"100"是噪音。'
            '用户举的例子是"只看了一集"（已开看）的场景。',
      );
    });

    test('★ 没有集数信息（电影 / B站单视频）⇒ 0', () {
      expect(followRemaining(totalEpisodes: 0, watchedEpisodeId: 'x'), 0);
      expect(followRemaining(totalEpisodes: -1, watchedEpisodeId: 'x'), 0);
    });

    test('★ 集列表里找不到该 episodeId ⇒ 0（宁可少显示）', () {
      expect(
        followRemaining(
          totalEpisodes: 12,
          watchedEpisodeId: '不存在的id',
          episodeIds: const ['ep1', 'ep2'],
        ),
        0,
        reason: '★ 换了源/集被删时会这样 —— 宁可**不显示**也不要显示错的数字',
      );
    });

    test('★ watched > total（数据不一致）⇒ clamp 到 0，不出负数', () {
      expect(
        followRemaining(
          totalEpisodes: 2,
          watchedEpisodeId: 'ep9',
          episodeIds: List.generate(9, (i) => 'ep${i + 1}'),
        ),
        0,
        reason: '★ 集列表变短/后端集数回退时会出现 —— 负数徽标是明显的 bug',
      );
    });

    test('★ 空字符串 episodeId 视同"没看过"', () {
      expect(followRemaining(totalEpisodes: 12, watchedEpisodeId: ''), 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ ★ 「第NN集」标题解析（实测用户真实数据后加的兜底）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么需要（**实测**得出，不是推测）
  //
  // `.probe/t40_db_probe.py` 只读查了用户真实数据，`episode_id` 是：
  // ```text
  // '51699'                        内部数字 id —— 与集号**毫无关系**
  // 'BV1o2eM6kEDT|41961327629'     B 站复合 id
  // 'https://vod1.../index.m3u8'   一个完整 URL
  // ```
  // ⇒ 拿它当序号用是**错的**（我第一版差点这么写）。
  // 而 `episode_title` 对中文源稳定：'第01集' / '第27集' / '正片' / null
  group('③ 「第NN集」标题解析', () {
    test('★ 常见形态', () {
      expect(episodeNumberFromTitle('第01集'), 1);
      expect(episodeNumberFromTitle('第1集'), 1);
      expect(episodeNumberFromTitle('第12集'), 12);
      expect(episodeNumberFromTitle('第27集'), 27);
      expect(episodeNumberFromTitle('第 3 集'), 3); // 带空格
      expect(episodeNumberFromTitle('第100话'), 100); // 话
      expect(episodeNumberFromTitle('第 8 話'), 8); // 繁体
    });

    test('★ 全角数字（实测中文源会出）', () {
      expect(episodeNumberFromTitle('第０１集'), 1);
      expect(episodeNumberFromTitle('第１２集'), 12);
    });

    test('★ 解析不出的返回 null（不做过度猜测）', () {
      // ★ 猜错会把徽标显示成**错的数字**，比不显示更糟
      expect(episodeNumberFromTitle('正片'), isNull);
      expect(episodeNumberFromTitle('预告'), isNull);
      expect(episodeNumberFromTitle(''), isNull);
      expect(episodeNumberFromTitle(null), isNull);
      expect(episodeNumberFromTitle('第0集'), isNull); // 0 不是合法集号
    });

    test('★★ 标题兜底真能算对（episodeId 对不上集列表时）', () {
      expect(
        followRemaining(
          totalEpisodes: 12,
          watchedEpisodeId: '51699', // ★ 内部 id，不在集列表里
          watchedEpisodeTitle: '第01集', // ← 靠它兜底
          episodeIds: const ['50001', '50002', '50003'],
        ),
        11,
        reason: '★ 这就是用户真实数据的形态：episode_id 是内部 id，'
            '但 episode_title 说得出第几集',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 批量版（三处界面共用的入口）
  // ═══════════════════════════════════════════════════════════════════
  group('④ followRemainingByKey 批量', () {
    test('★ 多部剧各自算，且与单片版结果一致', () {
      final following = [
        fav('a', lastEpisodeCount: 12),
        fav('b', lastEpisodeCount: 24),
        fav('c', lastEpisodeCount: 5), // 没看过 ⇒ 0
      ];
      final all = [
        prog('a', episodeTitle: '第01集'), // 12-1 = 11
        prog('b', episodeTitle: '第20集'), // 24-20 = 4
        // c 没有进度
      ];
      final m = followRemainingByKey(following: following, allProgress: all);
      expect(m['cycani:a'], 11);
      expect(m['cycani:b'], 4);
      expect(m['cycani:c'], 0);
    });

    test('★★ 底部徽标 = 所有追更的总和（用户要的"底部追更"）', () {
      final following = [
        fav('a', lastEpisodeCount: 12),
        fav('b', lastEpisodeCount: 24),
      ];
      final all = [
        prog('a', episodeTitle: '第01集'), // 11
        prog('b', episodeTitle: '第20集'), // 4
      ];
      final m = followRemainingByKey(following: following, allProgress: all);
      final sum = m.values.fold<int>(0, (a, b) => a + b);
      expect(sum, 15, reason: '★ 底部徽标显示的就是这个总和');
    });

    test('★ 「已看完」必须算成 0（靠 listAllProgress 不过滤）', () {
      /*
       * ⚠️ 这条守的是**取数方式**：
       * 若用 `continueWatching()`（带 `WHERE finished=0 AND position>5`），
       * 已看完的行**根本不在返回里** ⇒ 徽标不会消失。
       * 这里用"已看到最后一集"模拟。
       */
      final following = [fav('a', lastEpisodeCount: 3)];
      final all = [prog('a', episodeTitle: '第3集')];
      final m = followRemainingByKey(following: following, allProgress: all);
      expect(m['cycani:a'], 0, reason: '★ 看完 ⇒ 0 ⇒ 徽标消失（用户明确要求）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★★ 源码契约：三处必须共用同一个函数
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ ★★ 三处共用同一算法（防漂）', () {
    /// 剥注释（铁律⑤：不剥注释会命中注释里的字符串 ⇒ 假绿/假红）
    String strip(String s) {
      final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
      return noBlock
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }

    String readSrc(String p) => strip(File(p).readAsStringSync());

    test('★★★ 硬编码 `int _unread = 3` 不许回来', () {
      final src = readSrc('lib/shell.dart');
      expect(
        RegExp(r'int\s+_unread\s*=\s*3\s*;').hasMatch(src),
        isFalse,
        reason: '★★★ 用户原话：「底部的菜单栏，追更默认就显示 3 徽标，'
            '这是错误的」—— 那正是一个字面量 `int _unread = 3;`。',
      );
    });

    test('★★ shell.dart 必须用共享函数（不是自己写一套）', () {
      final src = readSrc('lib/shell.dart');
      /*
       * ★★★ 必须断言**调用**（带括号），不能只断言标识符出现
       *
       * # 为什么（红度证明抓出来的假绿）
       *
       * 我第一版写的是 `src.contains('followRemainingByKey')`。
       * 红度证明把调用点删掉之后，这条测试**照样绿** —— 因为
       * shell.dart 顶部还有一行 import：
       * ```dart
       * import 'core/models.dart' show Episode, Favorite, Progress,
       *                                   followRemainingByKey;
       * ```
       * 光有 import、没有调用，等于**没接上**（算法写了但没人用）。
       * ⇒ 加 `(` 才是"真的调用了"。
       */
      expect(src.contains('followRemainingByKey('), isTrue,
          reason: '★ 底部徽标必须**调用**共享算法 —— '
              '只 import 不调用等于没接上（三处写三遍必然漂）');
    });

    test('★★ my_shelf.dart 追更徽标必须用共享函数', () {
      final src = readSrc('lib/ui/widgets/my_shelf.dart');
      expect(src.contains('followRemainingByKey('), isTrue,
          reason: '★ 首页「我的」追更 tab 必须**调用**共享算法');
    });

    test('★★ follow_page.dart 必须用共享函数', () {
      final src = readSrc('lib/ui/follow_page.dart');
      expect(src.contains('followRemainingByKey('), isTrue,
          reason: '★ 追更页必须**调用**共享算法');
    });

    test('★★ 三处都**不许**再用 unreadCount 当徽标值', () {
      /*
       * 旧语义 = `Favorite.unreadCount`（"自上次巡检后新增了几集"）——
       * 与用户要的"还剩几集没看"**不是一回事**。
       * 这条防的是"某一处被改回去"（行为测试测不出，因为三处各自都对）。
       */
      for (final p in [
        'lib/shell.dart',
        'lib/ui/widgets/my_shelf.dart',
        'lib/ui/follow_page.dart',
      ]) {
        final src = readSrc(p);
        expect(src.contains('unread: f.unreadCount'), isFalse,
            reason: '★ $p 里还有 `unread: f.unreadCount` —— '
                '那是旧语义（巡检累加），不是"还剩几集没看"');
      }
    });

    test('★★★ 取值 helper **内部**不许回退到 unreadCount（红度证明抓出的洞）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这个洞是**红度证明第 ⑬ 条**抓出来的（改错13 GREEN）
       * ══════════════════════════════════════════════════════════════
       *
       * 上面那条只查 `unread: f.unreadCount` **字面量**。
       * 于是把它换成 `_remainingOf(f)`、再让 helper 内部返回
       * `f.unreadCount` —— 一个字面量都不出现 ⇒ **照样绿**：
       * ```dart
       * // 徽标取值那行长这样（看起来完全正确）：
       * unread: _remainingOf(f),
       * // 但 helper 被改成：
       * int _remainingOf(Favorite f) => f.unreadCount;   // ★ 旧语义回来了
       * ```
       * ⇒ 判据必须**下沉到 helper 的实现体**，而不是只看调用点。
       */
      final src = readSrc('lib/ui/widgets/my_shelf.dart');

      expect(src.contains('_remainingByKey[f.key]'), isTrue,
          reason: '★★★ `_remainingOf` 必须查**算好的 map**');

      final m = RegExp(r'int _remainingOf\(Favorite f\)\s*=>\s*([^;]+);')
          .firstMatch(src);
      expect(m, isNotNull,
          reason: '★ 找不到 `_remainingOf` 的定义 —— 它被改名/删掉了？'
              '那样这条断言会失去意义，必须**显式失败**而不是静默通过');
      expect(m!.group(1)!.contains('unreadCount'), isFalse,
          reason: '★★★ `_remainingOf` 实现体里出现了 unreadCount —— '
              '旧语义从后门回来了（调用点看不出来）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ ★★★ 用户追加要求：「追更中」三个字从卡片下面删掉 + 显示徽标
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话（逐字）：
  // > 最近追更  所追更的影视下面删除，追更中文字，
  // > 追更中``的影视要显示徽标  用来显示还有多少集没看
  //
  // ★ 为什么这条必须**真渲染**（源码断言不够）：
  // ```text
  // `contains("追更中")` 为 false 只能证明"字符串不在源码里"，
  // 不能证明"那一行真的不画了" —— 而用户抱怨的是**画面上**那三个字。
  // ```
  group('⑥ ★★★ 「追更中」删除 + 徽标显示（真实渲染）', () {
    /// 当前渲染树里所有 Text（含隐藏的）
    List<String> renderTexts(WidgetTester tester) {
      final out = <String>[];
      for (final e in find.byType(Text, skipOffstage: false).evaluate()) {
        final t = (e.widget as Text).data;
        if (t != null && t.isNotEmpty) out.add(t);
      }
      return out;
    }

    Future<GlobalKey<MyShelfState>> mount(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final k = GlobalKey<MyShelfState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: MyShelf(
                key: k,
                onOpenDetail: (_, __) {},
                onPlay: (_, __, ___, ____, _____) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return k;
    }

    testWidgets('★★★ 没标题的追更卡片下面**不许**再出现「追更中」',
        (tester) async {
      final k = await mount(tester);
      k.currentState!.debugSetData(
        following: [
          // ★ 用户真实数据形态：last_episode_title 是空的
          //   （`.probe/t40_db_probe.py` 只读实测：两部追更的
          //    last_episode_title **都是 None**）
          Favorite.fromJson(<String, dynamic>{
            'key': 'cycani:a',
            'provider': 'cycani',
            'native_id': 'a',
            'title': '怒鲨狂潮',
            'kind': 'series',
            'favorited': true,
            'following': true,
            'last_episode_count': 12,
            'last_episode_title': null,
            'unread_count': 0,
          }),
        ],
        tab: ShelfTab.following,
      );
      await tester.pump();

      final texts = renderTexts(tester);
      expect(texts.any((t) => t.contains('追更中')), isFalse,
          reason: '★★★ 用户原话：「最近追更  所追更的影视下面删除，'
              '追更中文字」—— 实测用户数据里两部追更的 '
              'last_episode_title 都是空 ⇒ 那个 fallback 会在**每一张**'
              '卡片下面打出「追更中」');
      // 前置条件：卡片真的渲染了（否则"没有追更中"是空的证据）
      expect(texts.contains('怒鲨狂潮'), isTrue,
          reason: '★ 卡片标题必须在 —— 否则上面那条断言证明不了什么');
    });

    testWidgets('★★ 有标题时那行仍显示（只删 fallback，不删功能）',
        (tester) async {
      final k = await mount(tester);
      k.currentState!.debugSetData(
        following: [
          Favorite.fromJson(<String, dynamic>{
            'key': 'cycani:b',
            'provider': 'cycani',
            'native_id': 'b',
            'title': '测试剧',
            'kind': 'series',
            'favorited': true,
            'following': true,
            'last_episode_count': 12,
            'last_episode_title': '更新至 12 集',
            'unread_count': 0,
          }),
        ],
        tab: ShelfTab.following,
      );
      await tester.pump();

      final texts = renderTexts(tester);
      expect(texts.contains('更新至 12 集'), isTrue,
          reason: '★ 用户说的是删「追更中」那几个字，'
              '**不是**把副标题功能删掉 —— 有真实标题时那行是有用的');
    });

    testWidgets('★★ 徽标 = 还剩几集；0 时不画（用户要的效果）', (tester) async {
      final k = await mount(tester);
      k.currentState!.debugSetData(
        following: [
          Favorite.fromJson(<String, dynamic>{
            'key': 'cycani:a', 'provider': 'cycani', 'native_id': 'a',
            'title': '甲', 'kind': 'series', 'favorited': true,
            'following': true, 'last_episode_count': 12,
            'unread_count': 0,
          }),
          Favorite.fromJson(<String, dynamic>{
            'key': 'cycani:b', 'provider': 'cycani', 'native_id': 'b',
            'title': '乙', 'kind': 'series', 'favorited': true,
            'following': true, 'last_episode_count': 12,
            'unread_count': 0,
          }),
        ],
        tab: ShelfTab.following,
        // 甲：还剩 11（看到第 1 集）；乙：0（看完了）
        remaining: const {'cycani:a': 11, 'cycani:b': 0},
      );
      await tester.pump();

      final texts = renderTexts(tester);
      expect(texts.contains('11'), isTrue,
          reason: '★ 用户原话：「12集，只看了一集 就显示11」');
      expect(texts.contains('0'), isFalse,
          reason: '★★ 用户原话：「当往后看到12集则计数器为0」'
              '—— 0 应该是**徽标消失**，而不是显示一个"0"'
              '（PosterCard 内部是 `unread > 0` 才画）');
    });
  });
}
