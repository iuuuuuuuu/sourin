// ═══════════════════════════════════════════════════════════════════════
//  task-17 ① 探针：缓存页**旁文件缺失**时从库里找回真封面
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（附截图：缓存卡是灰底「无」首字占位）
// > 已缓存的也要显示原来的封面
//
// # 根因（lead 已查清，含硬证据 —— 这里复述以便后人不必重查）
// ```text
// Owner 那个视频 mtime = 15:43:02，而写旁文件的 _writeSidecarFor 在 git HEAD 里
//   **不存在**（今天未提交的新代码）⇒ 那条历史数据本来就没有元数据。
// 但真实数据**是存在的**（dsh-media.db 的 WAL 里有）：
//   cycani:3862 | cycani | 3862 | 无职转生 第三季 ～到了异世界就拿出真本事～
//   https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/1f/9e/501963_bXlEP.jpg
// ```
// ⇒ 要做的：旁文件没有 ⇒ 按**目录名**去 history/favorites 找 ⇒ 补上 provider/cover。
//
// # 这份探针要证明的四件事
// ```text
// ① 命中：目录名与库里标题**归一化后相等** ⇒ 拿到 cover/provider/id
// ② ★ 负面对照：库里查不到的目录名 ⇒ 仍走首字占位（**不编造封面**）
// ③ 多条命中：不放弃，按「有封面 > 有 id > 历史更近 > provider 字典序」选第一条
// ④ memo：同一目录名第二次调用**不再查库**（滚动列表不许每帧查 DB）
// ```
//
// # ⚠️ 为什么用注入而不是连真核心
// ```text
// flutter_test 里**加载不了 sourin_core.dll**（error 126，本项目实测过）
//   ⇒ SourinApi.listHistory() 必然抛 ⇒ 走 catch ⇒ 恒返回 null
//   ⇒ "命中"与"没命中"读数完全一样 ⇒ 什么都测不出来。
// ⇒ 注入两份假历史/收藏，测的是**本文件的匹配 + 排序 + memo 逻辑**。
// ★ 端到端那条（真库 → 真封面）由真机读数证（见 REPORT）。
// ```
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart' show Favorite, HistoryEntry;
import 'package:sourin_spike/ui/cache_page.dart';

/// 探针沙盒（绝对路径 + 收尾自清理；**绝不落仓库根**）
Directory _sandbox() {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
      't17_cover';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  if (d.existsSync()) d.deleteSync(recursive: true);
  d.createSync(recursive: true);
  return d;
}

void _put(String path, int bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x41));
}

/// Owner 那条真实记录（逐字取自 dsh-media.db 的 WAL）
const kRealTitle = '无职转生 第三季 ～到了异世界就拿出真本事～';
const kRealCover = 'https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me'
    '/pic/cover/l/1f/9e/501963_bXlEP.jpg';
/// 磁盘上的目录名 = safeName(剧名)。safeName 只换非法字符，
/// 所以这里与标题**逐字相同**（全角 ～ 是合法文件名字符）。
const kDirName = kRealTitle;

HistoryEntry _h({
  required String provider,
  required String id,
  required String title,
  String? cover,
  int watchedAt = 0,
}) =>
    HistoryEntry(
      key: '$provider:$id',
      provider: provider,
      nativeId: id,
      title: title,
      cover: cover,
      watchedAt: watchedAt,
    );

Favorite _f({
  required String provider,
  required String id,
  required String title,
  String? cover,
}) =>
    Favorite(
      key: '$provider:$id',
      provider: provider,
      nativeId: id,
      title: title,
      cover: cover,
    );

void main() {
  late Directory root;

  setUp(() {
    root = _sandbox();
    debugClearCacheMetaMemo();
    debugMetaFetchers = null;
  });

  tearDown(() {
    // ★ 注入点必须恢复 —— 否则污染同进程的其它测试文件
    debugMetaFetchers = null;
    debugClearCacheMetaMemo();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('① 旁文件缺失 + 库里命中 ⇒ 卡片拿到真封面/provider/id', () async {
    // 磁盘上只有视频，**没有** _sourin-cache.json（= Owner 那个目录的真实形态）
    final dir = Directory('${root.path}${Platform.pathSeparator}$kDirName')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集 第01集.mp4', 1024 * 1024);

    debugMetaFetchers = (
      history: () async => [
        _h(
          provider: 'cycani',
          id: '3862',
          title: kRealTitle,
          cover: kRealCover,
          watchedAt: 1759900000,
        ),
      ],
      favorites: () async => <Favorite>[],
    );

    final works = await scanCacheWorks(root.path);
    expect(works.length, 1);
    final w = works.first;

    debugPrint('① 命中读数: 目录=${w.dirName}');
    debugPrint('   provider=${w.provider} id=${w.mediaId}');
    debugPrint('   cover=${w.cover}');
    debugPrint('   title=${w.title}（displayTitle=${w.displayTitle}）');

    expect(w.cover, kRealCover,
        reason: '★★ Owner 要的那张真封面必须被找回来');
    expect(w.provider, 'cycani', reason: '★ 详情页来源要用它（不是 local）');
    expect(w.mediaId, '3862');
    expect(w.displayTitle, kRealTitle);
  });

  test('② ★ 负面对照：库里查不到的目录名 ⇒ 仍是首字占位（不编造）', () async {
    const ghost = '这个剧库里根本没有';
    final dir = Directory('${root.path}${Platform.pathSeparator}$ghost')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 2048);

    debugMetaFetchers = (
      history: () async => [
        _h(provider: 'cycani', id: '3862', title: kRealTitle, cover: kRealCover),
      ],
      favorites: () async => <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('② 负面对照读数: 目录=${w.dirName}');
    debugPrint('   cover=${w.cover} provider=${w.provider} '
        'mediaId=${w.mediaId}');

    expect(w.cover, isNull,
        reason: '★★ 库里没有它 ⇒ **必须**没有封面（乱配比没有更糟：'
            '用户会以为看的是别的剧）');
    expect(w.provider, isNull);
    expect(w.mediaId, isNull);
    expect(w.displayTitle, ghost, reason: '★ 退回目录名');
  });

  test('②-b 近似但**不相等**的标题不许命中（避免乱配）', () async {
    // 目录名是《无职转生 第三季》（少了副标题），库里是全名
    const shortName = '无职转生 第三季';
    final dir = Directory('${root.path}${Platform.pathSeparator}$shortName')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);

    debugMetaFetchers = (
      history: () async => [
        _h(provider: 'cycani', id: '3862', title: kRealTitle, cover: kRealCover),
      ],
      favorites: () async => <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('②-b 近似标题读数: 目录=$shortName cover=${w.cover}');
    expect(w.cover, isNull,
        reason: '★ titleSimilarity 对"子串"并不给 1.0 ⇒ '
            '这条线天然只在逐字相等时才成立（最保守）');
  });

  test('③ 多条命中 ⇒ 不放弃，按「有封面 > 有 id > 历史更近 > provider」选第一条',
      () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$kDirName')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);

    // 与 lead 在真机上抓到的那两条一致：cycani:3862、hongniuzy2:150722
    debugMetaFetchers = (
      history: () async => [
        // 后看的、但**没封面** ⇒ 不该被选中
        _h(
          provider: 'hongniuzy2',
          id: '150722',
          title: kRealTitle,
          watchedAt: 1759999999,
        ),
        _h(
          provider: 'cycani',
          id: '3862',
          title: kRealTitle,
          cover: kRealCover,
          watchedAt: 1759900000,
        ),
      ],
      favorites: () async => <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('③ 多条命中读数: 选中的 = ${w.provider}:${w.mediaId}');
    debugPrint('   cover=${w.cover}');

    expect(w.provider, 'cycani',
        reason: '★ 排序第一条：**有封面的优先**（没封面就解决不了 Owner 的问题），'
            '哪怕它历史更旧');
    expect(w.mediaId, '3862');
    expect(w.cover, kRealCover);
  });

  test('③-b 都没封面时 ⇒ 历史更近的优先', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$kDirName')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);

    debugMetaFetchers = (
      history: () async => [
        _h(provider: 'aaa', id: '1', title: kRealTitle, watchedAt: 100),
        _h(provider: 'bbb', id: '2', title: kRealTitle, watchedAt: 900),
      ],
      favorites: () async => <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('③-b 无封面时读数: 选中 = ${w.provider}:${w.mediaId}');
    expect(w.provider, 'bbb', reason: '★ watchedAt 更大的（更近）优先');
  });

  test('④ memo：同一目录名第二次调用**不再查库**', () async {
    var historyCalls = 0;
    debugMetaFetchers = (
      history: () async {
        historyCalls++;
        return [
          _h(provider: 'cycani', id: '3862', title: kRealTitle, cover: kRealCover),
        ];
      },
      favorites: () async => <Favorite>[],
    );

    final a = await resolveCacheMetaByDirName(kDirName);
    final b = await resolveCacheMetaByDirName(kDirName);
    debugPrint('④ memo 读数: historyCalls=$historyCalls '
        '（期望 1）第一次=${a?.provider} 第二次=${b?.provider}');

    expect(historyCalls, 1,
        reason: '★★ 缓存页是滚动列表：每部作品都查一次库 = 50 部 100 次 IPC ⇒ 列表明显卡');
    expect(a?.provider, 'cycani');
    expect(b?.provider, 'cycani', reason: '★ 第二次必须拿到同一份（不能变 null）');
  });

  test('④-b 负结果也要 memo（否则"库里没有"的目录每次白查）', () async {
    var calls = 0;
    debugMetaFetchers = (
      history: () async {
        calls++;
        return <HistoryEntry>[];
      },
      favorites: () async => <Favorite>[],
    );

    final a = await resolveCacheMetaByDirName('库里没有的剧');
    final b = await resolveCacheMetaByDirName('库里没有的剧');
    debugPrint('④-b 负结果 memo 读数: calls=$calls（期望 1）a=$a b=$b');
    expect(a, isNull);
    expect(b, isNull);
    expect(calls, 1, reason: '★ 负结果不 memo 的话，没封面的老目录每次都白查一遍');
  });

  test('③-c 历史里没有、**收藏**里有 ⇒ 也能命中（两条数据源都要走）', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}只收藏了的剧')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);

    debugMetaFetchers = (
      history: () async => <HistoryEntry>[],
      favorites: () async => [
        _f(
          provider: 'hongniuzy2',
          id: '150722',
          title: '只收藏了的剧',
          cover: 'https://example.com/fav.jpg',
        ),
      ],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('③-c 收藏命中读数: provider=${w.provider} id=${w.mediaId} '
        'cover=${w.cover}');
    expect(w.provider, 'hongniuzy2', reason: '★ 历史没有就该去收藏里找');
    expect(w.cover, 'https://example.com/fav.jpg');
  });

  test('⑤ 旁文件**已有** cover ⇒ 绝不被库里的结果覆盖', () async {
    // 旁文件是"下载那一刻"的事实，比事后按标题猜的更可信
    final dir = Directory('${root.path}${Platform.pathSeparator}有旁文件的剧')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);
    File('${dir.path}${Platform.pathSeparator}$kCacheSidecarName')
        .writeAsStringSync(
      '{"provider":"cctv","id":"cctv1","title":"有旁文件的剧",'
      '"cover":"https://example.com/sidecar.jpg"}',
    );

    debugMetaFetchers = (
      history: () async => [
        _h(
          provider: 'cycani',
          id: '9999',
          title: '有旁文件的剧',
          cover: 'https://example.com/wrong.jpg',
        ),
      ],
      favorites: () async => <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('⑤ 旁文件优先读数: provider=${w.provider} cover=${w.cover}');
    expect(w.cover, 'https://example.com/sidecar.jpg',
        reason: '★★ 旁文件已有封面 ⇒ 不许被库里按标题猜的结果覆盖');
    expect(w.provider, 'cctv');
  });

  test('⑥ 查库抛异常 ⇒ 静默降级（绝不让整页失败）', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}库炸了')
      ..createSync(recursive: true);
    _put('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024);

    debugMetaFetchers = (
      history: () async => throw StateError('无核心 / DB 锁'),
      favorites: () async => throw StateError('无核心 / DB 锁'),
    );

    final works = await scanCacheWorks(root.path);
    debugPrint('⑥ 降级读数: works=${works.length} cover=${works.first.cover}');
    expect(works.length, 1, reason: '★ 查库失败不许让扫盘整体失败');
    expect(works.first.cover, isNull, reason: '★ 降级 = 首字占位');
  });
}
