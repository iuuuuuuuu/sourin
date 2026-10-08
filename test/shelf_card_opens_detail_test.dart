// ═══════════════════════════════════════════════════════════════════════
//  任务㉑② 首页「我的」三个 tab 点卡片必须进**详情页**（不是播放页）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 追更 历史 收藏 点进去又变成直接播放页了。
// > 这里我刚测试,追更页面这三个点进去正常,首页的是直接进播放页
//
// 以及更早的明确要求（记录在 `follow_page.dart:436-437`）：
// > 最近追更 最近收藏 播放历史 点进去都应该进 **详情页**,而不是播放页
//
// # 根因
//
// `my_shelf.dart` 卡片的 `onTap` 调的是 `onPlay` → 直接 push 播放器。
// 而**追更页已经改对了**（三个 tab 全走 `onOpenDetail`），
// 所以只有首页坏 —— 与用户"追更页正常、首页不正常"的描述**逐字吻合**。
//
// # 这个测试为什么必须"真的渲染 + 真的点击"
//
// 源码断言（`contains('onOpenDetail')`）只能证明**字符串在**，
// 不能证明**点下去真的走那条路** —— 而"点下去走哪条"正是缺陷本体。
// 所以这里：
// ```text
// ① 用 debugSetData 注入三条真实形状的数据（绕过 FFI）
// ② 真的 pump 出卡片
// ③ 真的 tap 卡片
// ④ 断言 onOpenDetail 被调用、onPlay 一次都没被调用
// ```
// ★ 三个 tab 各测一遍 —— 用户说的是"三个 tab 都坏了"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

/// 造一条追更/收藏记录
///
/// ⚠️ `key` 是 `Favorite.fromJson` 的**必填**字段（`jstr(j, 'key')` 缺了会抛），
///    所以这里必须给 —— 否则测试会在构造数据时就炸，而不是在断言处失败。
Favorite fav({
  required String provider,
  required String nativeId,
  required String title,
  int unread = 0,
  String? lastEpisodeTitle,
}) =>
    Favorite.fromJson(<String, dynamic>{
      'key': '$provider:$nativeId',
      'provider': provider,
      'native_id': nativeId,
      'title': title,
      'cover': null,
      'kind': 'series',
      'favorited': true,
      'following': true,
      'unread_count': unread,
      'last_episode_title': lastEpisodeTitle,
    });

/// 造一条播放历史
Progress prog({
  required String provider,
  required String nativeId,
  required String title,
}) =>
    Progress.fromJson(<String, dynamic>{
      'key': '$provider:$nativeId',
      'provider': provider,
      'native_id': nativeId,
      'title': title,
      'position': 120.0,
      'duration': 600.0,
      'episode_id': 'ep-1',
    });

/// 挂载 MyShelf 并注入数据，返回记录调用情况的闭包
Future<({List<String> opened, List<String> played})> mount(
  WidgetTester tester, {
  required ShelfTab tab,
  List<Favorite> following = const [],
  List<Favorite> favorites = const [],
  List<Progress> history = const [],
}) async {
  final opened = <String>[];
  final played = <String>[];

  /*
   * ★ 用**真实窗口尺寸**（1280x800），不用 flutter_test 默认的 800x600。
   *
   * 默认视口下卡片列会 `RenderFlex overflowed by 4.0 pixels` ——
   * 那是**测试环境太窄**造成的假失败，不是产品缺陷
   * （真实窗口是 1280x800，见 `shell.dart` 的 `WindowOptions`）。
   * 用假失败去改产品布局是本末倒置。
   */
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final key = GlobalKey<MyShelfState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MyShelf(
          key: key,
          onOpenDetail: (p, i) => opened.add('$p/$i'),
          onPlay: (p, i, t, c, e) => played.add('$p/$i'),
        ),
      ),
    ),
  );
  await tester.pump();

  key.currentState!.debugSetData(
    following: following,
    favorites: favorites,
    history: history,
    tab: tab,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  return (opened: opened, played: played);
}

void main() {
  group('任务㉑② 首页「我的」：点卡片 → 详情页', () {
    testWidgets('★ 追更 tab：点卡片 → onOpenDetail，不是 onPlay', (tester) async {
      final r = await mount(
        tester,
        tab: ShelfTab.following,
        following: [
          fav(
            provider: 'cycani',
            nativeId: 'abc',
            title: '怒鲨狂潮',
            unread: 2,
            lastEpisodeTitle: '第3集',
          ),
        ],
      );

      expect(find.text('怒鲨狂潮'), findsOneWidget,
          reason: '★ 卡片必须真的渲染出来，否则这个测试是空的（假绿）');
      await tester.tap(find.text('怒鲨狂潮'));
      await tester.pump();

      expect(r.opened, ['cycani/abc'],
          reason: '★ 点追更卡片必须走详情页');
      expect(r.played, isEmpty,
          reason: '★ 绝不能直接进播放页 —— 这正是用户报的缺陷');
    });

    testWidgets('★ 收藏 tab：点卡片 → onOpenDetail，不是 onPlay', (tester) async {
      final r = await mount(
        tester,
        tab: ShelfTab.favorites,
        favorites: [
          fav(provider: '154', nativeId: 'x9', title: '鬼灭之刃'),
        ],
      );

      expect(find.text('鬼灭之刃'), findsOneWidget);
      await tester.tap(find.text('鬼灭之刃'));
      await tester.pump();

      expect(r.opened, ['154/x9'], reason: '★ 收藏也要进详情页');
      expect(r.played, isEmpty, reason: '★ 不能进播放页');
    });

    testWidgets('★★ 播放历史 tab：**也**要进详情页（原版这里曾直接续播）',
        (tester) async {
      /*
       * 原版 `MyShelf.vue:401` 是：
       * ```js
       * @click="tab === 'history' ? resume(c) : open(c)"
       * ```
       * 即**历史 tab 例外**，直接续播。
       *
       * 但用户后来**明确推翻了这个例外**（`follow_page.dart:436` 记录）：
       * > 最近追更 最近收藏 播放历史 点进去都应该进 详情页,而不是播放页
       *
       * ★ 所以这里断言"历史也进详情页" —— 这是**用户的显式决定**，
       *   不是我们照抄原版就能得出的结论。
       */
      final r = await mount(
        tester,
        tab: ShelfTab.history,
        history: [
          prog(provider: '360', nativeId: 'h1', title: 'SHARK FRENZY'),
        ],
      );

      expect(find.text('SHARK FRENZY'), findsOneWidget);
      await tester.tap(find.text('SHARK FRENZY'));
      await tester.pump();

      expect(r.opened, ['360/h1'],
          reason: '★ 用户明确要求历史也进详情页（推翻了原版的历史例外）');
      expect(r.played, isEmpty,
          reason: '★ 历史 tab 同样不能直接进播放页');
    });
  });

  group('任务㉑② 边界：数据不完整时不静默', () {
    testWidgets('★ provider/id 缺失 → 不调用任何回调，但会记日志', (tester) async {
      /*
       * 老数据可能缺 `provider` / `native_id`。
       * 「点了没反应且没有任何记录」是最难查的表现 ——
       * 与 `follow_page._openDetailFor` 同样处理：记日志 + 不崩溃。
       */
      final r = await mount(
        tester,
        tab: ShelfTab.favorites,
        favorites: [
          fav(provider: '', nativeId: '', title: '坏数据'),
        ],
      );

      expect(find.text('坏数据'), findsOneWidget);
      await tester.tap(find.text('坏数据'));
      await tester.pump();

      expect(r.opened, isEmpty, reason: '不完整的数据不该被当成正常记录打开');
      expect(r.played, isEmpty, reason: '更不能拿去起播');
    });
  });

  group('任务㉑② 与追更页的**一致性**（用户就是拿它做对照的）', () {
    test('★ 两个页面的卡片都必须走 onOpenDetail，不许走 onPlay', () {
      /*
       * 用户原话：「追更页面这三个点进去正常,首页的是直接进播放页」
       * → 追更页是**正确样板**。这条断言把两边的行为钉在一起，
       *   防止以后只改一边、又出现"一个页面对一个页面不对"。
       */
      String stripComments(String s) {
        final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
        return noBlock
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
      }

      final shelf = stripComments(
        File('lib/ui/widgets/my_shelf.dart').readAsStringSync(),
      );
      final follow = stripComments(
        File('lib/ui/follow_page.dart').readAsStringSync(),
      );

      // 两边都要有 onOpenDetail 的调用
      expect(shelf.contains('onOpenDetail?.call('), isTrue,
          reason: '首页必须调 onOpenDetail');
      expect(follow.contains('onOpenDetail?.call('), isTrue,
          reason: '追更页（正确样板）调的是 onOpenDetail');

      // ★ 首页的卡片 onTap 里不得再出现 onPlay 的调用
      expect(
        shelf.contains('onPlay?.call('),
        isFalse,
        reason: '★ 首页卡片不得再调 onPlay —— 那会让用户"点进去直接播放"，'
            '多集内容就没法选集了',
      );
    });
  });
}
