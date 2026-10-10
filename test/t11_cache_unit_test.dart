// ═══════════════════════════════════════════════════════════════════════
//  task-11：首页列表缓存的上限 / 失效语义（纯单测，不碰 FFI / 不碰网络）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这条测试要单独存在（真机探针已经量了同一件事）
//
// ```text
// 真机探针（.probe/t11-cache.txt）量的是**端到端**：切源第一帧有没有卡片、
//   那一刻发了几次列表请求 —— 但它要 flutter build windows（全 app 编译），
//   会被**别人的中间态**卡住（本轮实测被 lib/ui/detail_page.dart 卡过两次）。
// 这条单测量的是**缓存类自己**：上限 / 淘汰顺序 / TTL / 指纹作废。
//   ⇒ 前者证明「用户看得见」，后者证明「内存不会涨」—— 两条互补，都要有。
// ```
//
// ⚠️ 判据用**返回值**（take() 给的快照是不是 null），不数内部字段 ——
//    内部字段可以「标记不命中却仍留着对象」，那样内存照样涨。
//    ★ 所以每条「不命中」都同时断言 length 变小（对象真的被丢掉了）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// ⚠️ home_page.dart **不导出** 领域模型（它只是 import 了），
//    所以要拿 MediaItem / ProviderGroup 必须自己再引一次 core/models.dart。
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/home_page.dart';

HomeSnapshot snap(String fp, DateTime at, {int cards = 0}) {
  final items = <String, List<MediaItem>>{};
  if (cards > 0) {
    items['p::s'] = List<MediaItem>.generate(
      cards,
      (i) => MediaItem(id: 'p:s$i', title: 't$i'),
    );
  }
  return HomeSnapshot(
    fingerprint: fp,
    groups: const <ProviderGroup>[],
    items: items,
    at: at,
  );
}

void main() {
  final now = DateTime(2026, 10, 9, 20, 0, 0);

  group('① 上限：LRU 真的丢对象（不只是「不命中」）', () {
    test('★★ 塞满 maxEntries+5 个键后，驻留数**恰好**等于上限', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries + 5; i++) {
        c.put('p$i', snap('fp', now));
      }
      expect(c.length, kHomeCacheMaxEntries,
          reason: '★ 上限是**硬约束**（任务书第 4 条：不许让内存无限增长）');
    });

    test('★★ 被淘汰的是**最久未用**的那个（LRU 顺序）', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries + 5; i++) {
        c.put('p$i', snap('fp', now));
      }
      for (var i = 0; i < 5; i++) {
        expect(c.take('p$i', fingerprint: 'fp', now: now), isNull,
            reason: '★ p$i 是第 ${i + 1} 个写入的 ⇒ 最早被淘汰');
      }
      expect(
        c.take('p${kHomeCacheMaxEntries + 4}', fingerprint: 'fp', now: now),
        isNotNull,
      );
    });

    test('★ 命中会把该键**提升**为最近使用（否则 LRU 退化成 FIFO）', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries; i++) {
        c.put('p$i', snap('fp', now));
      }
      expect(c.take('p0', fingerprint: 'fp', now: now), isNotNull);
      c.put('px', snap('fp', now));
      expect(c.length, kHomeCacheMaxEntries);
      expect(c.take('p0', fingerprint: 'fp', now: now), isNotNull,
          reason: '★ 刚用过的不该被淘汰 —— 否则「命中提升」没生效');
      expect(c.take('p1', fingerprint: 'fp', now: now), isNull,
          reason: '★ 该被淘汰的应当是 p1');
    });
  });

  group('② 失效：TTL 与骨架指纹', () {
    test('★★ 超过 TTL 的快照不算命中，**且真的从表里删掉**', () {
      final c = HomeListCache();
      c.put('a',
          snap('fp', now.subtract(kHomeCacheTtl + const Duration(minutes: 1))));
      expect(c.take('a', fingerprint: 'fp', now: now), isNull,
          reason: '★ 应用在后台搁了很久 ⇒ 宁可冷加载一次，'
              '也不能把很久以前的数据当「秒开」端上去');
      expect(c.length, 0,
          reason: '★★ 不只是「不命中」：对象必须真的被丢掉，否则内存照涨');
    });

    test('★★ 指纹不符（用户刚启停过源）⇒ 不算命中，也真的删掉', () {
      final c = HomeListCache();
      c.put('a', snap('old-fingerprint', now));
      expect(c.take('a', fingerprint: 'new-fingerprint', now: now), isNull,
          reason: '★ 骨架变了 ⇒ 旧快照的分区列表与当前对不上，画出来是错的标题');
      expect(c.length, 0);
    });

    test('★ 边界：刚好等于 TTL 仍然算命中（判据是 > 不是 >=）', () {
      final c = HomeListCache();
      c.put('a', snap('fp', now.subtract(kHomeCacheTtl)));
      expect(c.take('a', fingerprint: 'fp', now: now), isNotNull,
          reason: '边界写错会在「刚好 TTL」那一刻出现无谓的冷加载');
    });
  });

  group('③ 命中：拿到的是同一份数据 + 计数器真的在动', () {
    test('★★ 命中返回的快照内容与写入时一致（160 张那种规模）', () {
      final c = HomeListCache();
      c.put('a', snap('fp', now, cards: 160));
      final got = c.take('a', fingerprint: 'fp', now: now);
      expect(got, isNotNull);
      expect(got!.cardCount, 160);
      expect(c.hits, 1);
      expect(c.misses, 0);
    });

    test('★ items 是**只读视图**（防止别处顺手原地改坏缓存）', () {
      final c = HomeListCache();
      c.put('a', snap('fp', now, cards: 1));
      final got = c.take('a', fingerprint: 'fp', now: now)!;
      expect(() => got.items['x'] = const <MediaItem>[], throwsUnsupportedError,
          reason: '★ 缓存里的 Map 必须不可变 —— 否则「存引用省一次拷贝」'
              '就会变成「两处互相改」的隐蔽 bug');
    });

    test('★ clear() 之后一个都不留（测试/换源清单时要用）', () {
      final c = HomeListCache(maxEntries: 2);
      c.put('a', snap('fp', now));
      c.put('b', snap('fp', now));
      c.clear();
      expect(c.length, 0);
    });

    test('★ 空 provider 不许写入（否则会出现一个永远取不到的垃圾条目）', () {
      final c = HomeListCache();
      c.put('', snap('fp', now));
      expect(c.length, 0);
    });
  });

  group('④ 常量契约（上限 / TTL 是公开可读的，改它必须是有意的）', () {
    test('★ 上限 = 12 / TTL = 10 分钟', () {
      expect(kHomeCacheMaxEntries, 12,
          reason: '★ 改这个数要同时说明内存代价（见 home_page.dart 的注释：'
              '一个条目 ≈ 一个源的卡片引用数，cctv 实测 160 张）');
      expect(kHomeCacheTtl, const Duration(minutes: 10));
    });
  });
}
