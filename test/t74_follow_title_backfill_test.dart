// ═══════════════════════════════════════════════════════════════════════
//  task-74 ①：追更页「（标题未知）」的**异步回填** + 持久化
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 追更页面有个未知,点进去明明有信息,也能播放,像这些信息,
// > 要么缓存,要么每次点进去 能访问就更新,不能访问就保留,
// > 或者你自己想一个优化方案
//
// # 本文件守的五条（= 验收标准）
//
// ```text
// ① 空标题 + episodeTitle 非空  ⇒ 显示 episodeTitle，**不发请求**
// ② 两者都空                    ⇒ 回填**被触发**（可注入假 fetcher）
// ③ 成功                        ⇒ 标题**上树** + 调了写回且 title 非空
// ④ 失败（fetcher 抛异常）      ⇒ 仍显示「（标题未知）」，不崩/不清空/不重试
// ⑤ 同条目多次 rebuild          ⇒ 请求次数**不增**
// ```
//
// # ★★★ 本文件刻意**不用**"符号存在"式断言
//
// 本仓反复踩过（`t65_follow_cards_test.dart:20-33` 有完整记录）：
// ```dart
// expect(src.contains('ProgressTitleBackfill'), isTrue);   // ← ★ 恒真
// ```
// 光靠"类名 / 字段声明存在"就满足 ⇒ 把回填整个删掉**照样绿**。
// ⇒ 下面每条都必须能**区分对错**：
// ```text
// · 数**请求次数**（FakeDetail.calls.length）—— 不是看源码里有没有 if
// · 读**真 widget 树上渲染出的文字** —— 不是看源码里有没有那个字符串
// · 断言**写回的内容** —— 不是看有没有调 saveProgress
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/progress_backfill.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// 造一条播放记录（默认就是**用户报的那种坏记录**：标题空、集名也空）
Progress mk({
  String key = 'cycani:3841',
  String provider = 'cycani',
  String nativeId = '3841',
  String title = '',
  String? episodeTitle,
  String? cover,
  int position = 0,
  int duration = 0,
  bool finished = false,
  int updatedAt = 0,
}) =>
    Progress(
      key: key,
      provider: provider,
      nativeId: nativeId,
      title: title,
      episodeTitle: episodeTitle,
      cover: cover,
      position: position,
      duration: duration,
      finished: finished,
      updatedAt: updatedAt,
    );

/// 假的详情抓取器
///
/// ★ 它存在的**唯一理由**是记录「被请求了几次」——
///   那正是本任务最容易被写错的地方（rebuild 时重复打网络）。
class FakeDetail {
  FakeDetail({this.title = '无职转生 第三季', this.cover});

  /// 详情接口返回的标题（空串 = 源站自己也没标题）
  String title;

  /// 详情接口返回的封面
  String? cover;

  /// `true` ⇒ 每次都抛（模拟 Owner 说的「不能访问」）
  bool throwOnFetch = false;

  /// 每次调用前 await 一下（用于观察并发上限）
  Duration delay = Duration.zero;

  /// ★ 记录**每一次**被请求的 `provider:id`（顺序与次数都留着）
  final List<String> calls = <String>[];

  /// 当前在飞的数量 / 历史峰值（用于观察并发上限）
  int inFlight = 0;
  int maxInFlight = 0;

  Future<MediaDetail> call(String provider, String id) async {
    calls.add('$provider:$id');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (throwOnFetch) throw StateError('模拟：源站不可达');
      return MediaDetail(id: id, title: title, cover: cover);
    } finally {
      inFlight--;
    }
  }
}

/// 假的写回器
///
/// ★ 记录**写进去的内容** —— "持久化"这件事的唯一证据。
///   只断言"调了 saveProgress"是不够的：写一个空标题进去
///   会把本来**有集名**的记录写坏（比不写更糟）。
class FakeSaver {
  final List<Progress> calls = <Progress>[];
  final List<String> titles = <String>[];
  final List<String?> covers = <String?>[];

  /// `true` ⇒ 写库失败（模拟磁盘/核心层错误）
  bool throwOnSave = false;

  Future<void> call(Progress p, {required String title, String? cover}) async {
    calls.add(p);
    titles.add(title);
    covers.add(cover);
    if (throwOnSave) throw StateError('模拟：写库失败');
  }
}

/// 挂载用的宿主（与 `t65_follow_cards_test.dart:102-116` 同款）
///
/// ⚠️ 缺 `Material` 祖先 ⇒ 页面会被静默换成 `ErrorWidget`，
///    而真因只出现在 **stderr**（`Null check operator used on a null value`）。
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
  //  ① 判据（纯函数）—— 「哪些行需要回填」
  // ═══════════════════════════════════════════════════════════════════

  group('① 判据 needsTitleBackfill：只补**真正会显示占位符**的行', () {
    test('标题非空 ⇒ 不需要回填', () {
      expect(needsTitleBackfill(mk(title: '无职转生 第三季')), isFalse);
    });

    test('★★★ 标题空 + 集名非空 ⇒ **不需要**回填（这条就是"不发请求"的判据）',
        () {
      /*
       * Owner 报的是「（标题未知）」那张卡。
       * 而标题空、集名 = "第01集" 时，卡片显示的是**集名** ——
       * 用户看得到可辨认的信息 ⇒ 不是"未知" ⇒ 不该为它打一次网络。
       *
       * ★ 这条断言若变红，说明判据漂成了"只要 title 空就补"
       *   ⇒ 追更页每次进页都会多打若干次详情请求。
       */
      expect(
        needsTitleBackfill(mk(title: '', episodeTitle: '第01集')),
        isFalse,
        reason: '★★★ 有集名可显示 ⇒ 不是"未知" ⇒ 不该发请求',
      );
    });

    test('★★ 两者都空 ⇒ 需要回填（= 用户看到「（标题未知）」的那种）', () {
      expect(needsTitleBackfill(mk(title: '', episodeTitle: null)), isTrue);
      expect(needsTitleBackfill(mk(title: '', episodeTitle: '')), isTrue);
    });

    test('★ 全空白也算空（用 trim 而不是 isEmpty）', () {
      /*
       * 用户库里实测是 `title=''`，但**不能假设**只有空串 ——
       * 上游源站可能下发 `'   '`，那在界面上同样是空白，
       * 而 `isEmpty` 会判它"有标题" ⇒ 永远不回填、永远显示空白。
       */
      expect(needsTitleBackfill(mk(title: '   ')), isTrue);
      expect(needsTitleBackfill(mk(title: '', episodeTitle: '   ')), isTrue);
    });

    test('★★ 阳性对照：判据不是恒返回同一个值', () {
      /*
       * ★ 若这个函数被写成 `=> true` 或 `=> false`，
       *   上面几条里必有一条红 —— 但为了"仪器自检"明确留一条。
       */
      final results = <bool>{
        needsTitleBackfill(mk(title: '有标题')),
        needsTitleBackfill(mk(title: '', episodeTitle: '第01集')),
        needsTitleBackfill(mk(title: '')),
      };
      expect(results, containsAll(<bool>[false, true]),
          reason: '★ 阳性对照失败 ⇒ 判据是常量 ⇒ 本组结论作废');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 回填器行为（单元 —— 真跑 async，不挂树）
  // ═══════════════════════════════════════════════════════════════════

  group('② ProgressTitleBackfill：成功 / 失败 / 去重 / 并发', () {
    test('★★★ 成功 ⇒ 写回**非空**标题，且位置/时长/集 id **原样**保留', () async {
      /*
       * ⚠️ 这条守的是**最危险的回归**：
       *    回填只该改 `title` / `cover`。
       *    若实现里漏传 `position`/`duration`（`save_progress` 是 upsert）
       *    ⇒ 用户的**观看进度会被冲成 0** —— 那比"没标题"严重得多。
       */
      final f = FakeDetail(title: '无职转生 第三季', cover: 'https://x.invalid/c.jpg');
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final src = mk(
        title: '',
        episodeTitle: null,
        position: 419,
        duration: 1420,
        finished: false,
        updatedAt: 1790000000,
      );
      final got = await bf.backfill([src]);

      expect(got.length, 1, reason: '补上了 1 条');
      expect(got.single.title, '无职转生 第三季');

      // ── 写回的内容 ──
      expect(s.calls.length, 1, reason: '★ 成功必须写回（= Owner 说的"缓存"）');
      expect(s.titles.single, isNotEmpty, reason: '★★ 绝不许写空标题进库');
      expect(s.covers.single, 'https://x.invalid/c.jpg');

      // ── 其余字段逐条照抄 ──
      final saved = s.calls.single;
      expect(saved.provider, 'cycani');
      expect(saved.nativeId, '3841');
      expect(saved.position, 419, reason: '★★★ 观看进度不许被回填冲掉');
      expect(saved.duration, 1420, reason: '★★★ 时长不许被回填冲掉');
      expect(saved.finished, isFalse);
      expect(saved.episodeTitle, isNull);
    });

    test('★★★ 失败（fetcher 抛）⇒ 静默返回空，**不抛**、不写库', () async {
      final f = FakeDetail()..throwOnFetch = true;
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final got = await bf.backfill([mk()]);

      expect(got, isEmpty, reason: '★ 失败 ⇒ 什么都不返回（界面保持占位符）');
      expect(s.calls, isEmpty, reason: '★★ 失败**绝不写库** —— 写空值比不写更糟');
      expect(f.calls.length, 1, reason: '确实尝试过一次');
    });

    test('★★ 详情拿到了但标题仍空 ⇒ **不写库**（不把记录写得更差）', () async {
      final f = FakeDetail(title: '');
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final got = await bf.backfill([mk()]);

      expect(got, isEmpty);
      expect(s.calls, isEmpty,
          reason: '★ 详情没给出标题 ⇒ 宁可不写，也不能写个空标题进去');
    });

    test('★ 写库失败 ⇒ 不抛（回填是旁路，失败不该让追更页报错）', () async {
      final f = FakeDetail();
      final s = FakeSaver()..throwOnSave = true;
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final got = await bf.backfill([mk()]);
      expect(got, isEmpty, reason: '写库失败 ⇒ 这条不算补上（界面仍是占位符）');
    });

    test('★★★ 去重：同一 key 连跑两次 ⇒ 只请求**一次**', () async {
      final f = FakeDetail();
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      await bf.backfill([mk()]);
      await bf.backfill([mk()]); // ← 模拟"切走又切回来"

      expect(f.calls.length, 1,
          reason: '★★★ 失败的条目**本次会话不重试** —— '
              '否则用户来回切 5 次 tab 就是 5 次无谓请求');
      expect(bf.triedKeys, contains('cycani:3841'));
    });

    test('★★★ 不需要回填的条目 ⇒ 一次请求都不发（对应验收①）', () async {
      final f = FakeDetail();
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final got = await bf.backfill([
        mk(key: 'a:1', provider: 'a', nativeId: '1', title: '有标题的'),
        mk(key: 'a:2', provider: 'a', nativeId: '2', title: '', episodeTitle: '第01集'),
      ]);

      expect(got, isEmpty);
      expect(f.calls, isEmpty,
          reason: '★★★ 两条都不需要回填 ⇒ 请求数必须是 0');
    });

    test('★★ 并发上限：12 条 + maxConcurrent=4 ⇒ 峰值在飞数 ≤ 4', () async {
      final f = FakeDetail()..delay = const Duration(milliseconds: 5);
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
        maxConcurrent: 4,
      );

      final items = [
        for (var i = 0; i < 12; i++)
          mk(key: 'p:$i', provider: 'p', nativeId: '$i'),
      ];
      final got = await bf.backfill(items);

      expect(f.calls.length, 12, reason: '12 条都该被请求');
      expect(got.length, 12);
      expect(f.maxInFlight, lessThanOrEqualTo(4),
          reason: '★★ 并发上限必须真的生效 —— 否则首屏会被 20 个详情请求抢带宽');
      expect(f.maxInFlight, greaterThan(1),
          reason: '★ 阳性对照：若实现退化成串行，maxInFlight 会是 1');
    });

    test('★ mergeBackfilled：按 key 合并，匹配不到的原样保留', () {
      final a = mk(key: 'k:a', provider: 'k', nativeId: 'a', title: 'A');
      final b = mk(key: 'k:b', provider: 'k', nativeId: 'b', title: '');
      final merged = mergeBackfilled(
        [a, b],
        [withBackfilledMeta(b, title: 'B 的新标题')],
      );

      expect(merged.length, 2, reason: '★ 回填**不许**增删列表项');
      expect(merged[0].title, 'A');
      expect(merged[1].title, 'B 的新标题');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 端到端（真 widget 树 —— 断言的是**渲染出来的文字**）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 追更页「历史」tab：标题真的上树 / 失败不崩 / 不重复请求', () {
    /// 挂载 + 注入 + 让 `_load()`（必然失败的 FFI）先落定
    Future<FollowPageState> mount(
      WidgetTester t, {
      required List<Progress> list,
      required ProgressTitleBackfill bf,
    }) async {
      await t.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(FollowPage(
        initialTab: 'continue',
        backfillOverride: bf,
      )));
      /*
       * ⚠️ 必须**等 `_load()` 落定再注入**。
       *
       * `initState` 里 `addPostFrameCallback((_) => loadAll())` ⇒ `_load()`
       * 成功时会 `setState(() => _continueList = results[2])` ——
       * 若在它之前注入，注入的数据会被**覆盖掉**。
       * （测试里三路 FFI 必然失败 ⇒ 走 catch ⇒ 不会覆盖；
       *   但**不能依赖**这一点，否则将来 FFI 桩一改这条就变成假绿。）
       */
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final st = t.state<FollowPageState>(find.byType(FollowPage));
      st.debugSetContinueList(list);
      await t.pump();
      return st;
    }

    testWidgets('★★★ 空标题 ⇒ 先显示「（标题未知）」⇒ 回填后显示**真标题**',
        (t) async {
      final f = FakeDetail(title: '无职转生 第三季');
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final st = await mount(t, list: [mk()], bf: bf);

      /*
       * ★ 前置断言（也是阳性对照）：注入真的生效了。
       *   若这里就红，说明 `_load()` 把我的注入覆盖了 ⇒
       *   后面的"标题变了"根本证明不了回填。
       */
      expect(find.text('（标题未知）'), findsOneWidget,
          reason: '★ 前置条件：注入必须生效（否则后面的断言无意义）');

      await st.debugRunBackfill();
      await t.pump();

      // ignore: avoid_print
      print('[T74] 回填后：请求 ${f.calls.length} 次，'
          '写回 ${s.titles}，树上标题 = '
          '${st.debugContinueList.map((p) => p.title).toList()}');

      expect(find.text('无职转生 第三季'), findsOneWidget,
          reason: '★★★ 标题必须真的**渲染到 widget 树上**');
      expect(find.text('（标题未知）'), findsNothing,
          reason: '★ 补上之后占位符必须消失');
      expect(s.titles.single, '无职转生 第三季');
    });

    testWidgets('★★★ 标题空但集名非空 ⇒ 显示集名，且**一次请求都不发**', (t) async {
      final f = FakeDetail(title: '不该被请求');
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final st = await mount(
        t,
        list: [mk(title: '', episodeTitle: '第01集')],
        bf: bf,
      );

      expect(find.text('第01集'), findsOneWidget,
          reason: '★ 有集名可显示 ⇒ 不是"未知"');

      await st.debugRunBackfill();
      await t.pump();

      expect(f.calls, isEmpty,
          reason: '★★★ 集名非空时**不许**发请求 —— '
              '收益只是把"第01集"换成片名，代价是一次网络往返');
      expect(s.calls, isEmpty);
    });

    testWidgets('★★★ 源站不可达 ⇒ 仍显示「（标题未知）」，不崩、不清空', (t) async {
      final f = FakeDetail()..throwOnFetch = true;
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final st = await mount(t, list: [mk()], bf: bf);
      expect(find.text('（标题未知）'), findsOneWidget);

      await st.debugRunBackfill();
      await t.pump();

      expect(find.text('（标题未知）'), findsOneWidget,
          reason: '★★★ 对应 Owner 的「不能访问就**保留**」—— 保留 = 继续显示占位符');
      expect(st.debugContinueList.length, 1,
          reason: '★★★ 失败**绝不许删行** —— 用户的观看记录不能消失');
      expect(drainExceptions(t), 0,
          reason: '★ 失败必须静默（回填是旁路，不该让追更页崩）');
      expect(s.calls, isEmpty, reason: '★ 失败不许写库');
    });

    testWidgets('★★★ 同一批数据反复回填（模拟多次 rebuild / 切 tab）⇒ 请求数不增',
        (t) async {
      final f = FakeDetail()..throwOnFetch = true; // 失败的最该被去重
      final s = FakeSaver();
      final bf = ProgressTitleBackfill(
        fetchDetail: f.call,
        saveProgress: s.call,
      );

      final st = await mount(t, list: [mk()], bf: bf);

      await st.debugRunBackfill();
      await t.pump();
      final after1 = f.calls.length;

      // ★ 模拟"切走又切回来"3 次
      for (var i = 0; i < 3; i++) {
        await st.debugRunBackfill();
        await t.pump();
      }

      // ignore: avoid_print
      print('[T74] 连跑 4 次回填 ⇒ 请求 ${f.calls.length} 次（第 1 次后 = $after1）');

      expect(after1, 1, reason: '★ 第一次确实尝试了');
      expect(f.calls.length, 1,
          reason: '★★★ 后续 3 次**一次都不许再发** —— '
              '否则用户来回切 tab 会把网络打爆');
    });
  });
}

/// 读"本帧有没有未捕获异常"（`tester.takeException()` 只吐第一个）
int drainExceptions(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null) {
    n++;
    if (n > 50) break; // 防御：不该有这么多
  }
  return n;
}
