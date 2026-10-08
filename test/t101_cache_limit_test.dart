// ═══════════════════════════════════════════════════════════════════════
//  t101 —— 缓存上限真的生效 + 三个目录可管理（Owner 2026-10-07 第 6 条）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（逐字）：
// > 缓存目录也应该有大小限制，而不是无限制，并且要可以进行管理
//
// # 这个文件钉的是什么
//
// 修之前 `enforceCacheLimit()` 已经存在、也已经真的会删（探针 P1/P9 证明
// 上限**确实生效**），但有**五个洞**（都是探针 `.probe_i56\` 跑出来的真
// 读数，不是推测）：
//
//   ① 并发删过头 —— P10：6 个旧种子 60MB + 4 个并发 10MB 新下载，
//      理论上只需删到 64MB，**实测终态 0 个文件、磁盘 0 字节**。
//   ② rename 保留 .part 的 mtime ⇒ 刚下完的大文件被当最旧秒删 ——
//      P4：`long.mp4 mtime=19:08:02` vs `small-5 mtime=19:43:02`，
//      `deleted=1`、`long.mp4 被删=true`。
//   ③ 上限只管 clip-cache —— P2：shots 躺着 209715200 字节，一个字节不管。
//   ④ `.part` 不受约束 —— P3：裁剪后 `cacheBytes=62914560`，
//      而磁盘真实占用 125829120（两倍）。
//   ⑤ 改上限不触发淘汰 —— P7：上限 256→64MB，占用仍停在 104857600。
//
// 下面每一组对应一个洞，**用修之前会红的断言**钉住。
//
// ⚠️ 全程只碰系统临时目录（`debugSetDataDir`）——**绝不**碰
//    `%APPDATA%\app.sourin.player` 里的真实收藏/历史/进度/截图。
// ⚠️ 大文件用 `RandomAccessFile.truncate()` 造**稀疏**文件，不真写字节。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 造一个 `bytes` 字节的文件（稀疏，不真写）；`mtime` 可指定，用于排淘汰序。
Future<File> makeFile(String path, int bytes, {DateTime? mtime}) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final raf = await f.open(mode: FileMode.write);
  await raf.truncate(bytes);
  await raf.close();
  if (mtime != null) await f.setLastModified(mtime);
  return f;
}

const int mb = 1024 * 1024;

void main() {
  late Directory tmp;
  late String clipDir;
  late String mpvDir;
  late String shotsDir;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('t101_cache_');
    ClipDownloader.debugSetDataDir(tmp.path);
    UiPrefs.debugResetForTest();
    ClipDownloader.debugClearBusy();
    ClipDownloader.debugResetProbeCounters();
    clipDir = await ClipDownloader.cacheDir();
    mpvDir = await ClipDownloader.mpvCacheDir();
    shotsDir = await ClipDownloader.shotsDir();
  });

  tearDown(() {
    ClipDownloader.debugClearBusy();
    ClipDownloader.debugSetDataDir(null);
    UiPrefs.debugResetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String clip(String name) => '$clipDir${Platform.pathSeparator}$name';
  String mpv(String name) => '$mpvDir${Platform.pathSeparator}$name';
  String shot(String name) => '$shotsDir${Platform.pathSeparator}$name';

  // ════════════════════════════════════════════════════════════════════
  //  0：常量不许漂（`kCacheLimitKey` / 选项 / 默认值 / clamp 都是钉子）
  // ════════════════════════════════════════════════════════════════════
  group('0 常量与取值（回归钉）', () {
    test('键名 / 选项 / 默认值 / clamp 全部保持不变', () {
      expect(ClipDownloader.kCacheLimitKey, 'dsh.cache.limitMb');
      expect(ClipDownloader.cacheLimitOptions, [64, 128, 256, 512]);
      expect(ClipDownloader.defaultCacheLimitMb, 256);
      expect(ClipDownloader.cacheLimitMb, 256, reason: '未设置时用默认值');

      UiPrefs.set(ClipDownloader.kCacheLimitKey, '32');
      expect(ClipDownloader.cacheLimitMb, 64, reason: '下限 64');
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '4096');
      expect(ClipDownloader.cacheLimitMb, 512, reason: '上限 512');
      UiPrefs.set(ClipDownloader.kCacheLimitKey, 'abc');
      expect(ClipDownloader.cacheLimitMb, 256, reason: '解析不了回落默认，不抛');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  1：上限真的生效 + 保留最新（探针 P1 的复刻）
  // ════════════════════════════════════════════════════════════════════
  group('1 超限后裁到 <= 上限，且保留最新', () {
    test('100MB -> 64MB 上限：删到 <= 上限，留下的全是新的', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      // clip-0 最旧 …… clip-9 最新，每个 10MB，合计 100MB
      for (var i = 0; i < 10; i++) {
        await makeFile(clip('clip-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: i)));
      }
      expect(await ClipDownloader.cacheBytes(), 100 * mb);

      final deleted = await ClipDownloader.enforceCacheLimit();
      final after = await ClipDownloader.cacheBytes();
      expect(after, lessThanOrEqualTo(64 * mb), reason: '★ 必须裁到上限以内');
      expect(deleted, greaterThan(0), reason: '超限了就必须真删');

      final left = (await ClipDownloader.cacheEntries()).map((e) => e.name).toList();
      expect(left.contains('clip-9.mp4'), isTrue, reason: '★ 最新的必须在');
      expect(left.contains('clip-0.mp4'), isFalse, reason: '★ 最旧的必须被删');
      expect(left.length, 6, reason: '100MB 裁到 60MB，正好剩 6 个');
    });

    test('未超限时一个都不删（不是每次都清）', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      await makeFile(clip('a.mp4'), 1 * mb);
      expect(await ClipDownloader.enforceCacheLimit(), 0);
      expect(File(clip('a.mp4')).existsSync(), isTrue);
    });

    test('磁盘真实占用与 cacheBytes 一致（洞④：.part 以前不受约束）', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      for (var i = 0; i < 10; i++) {
        await makeFile(clip('clip-$i.mp4'), 10 * mb,
            mtime: DateTime(2026, 10, 7, 19, i));
      }
      // 一个 30MB 的 .part 残留：它**不算成品**，所以不该出现在读数里
      await makeFile(clip('half.mp4.part'), 30 * mb);
      final entries = await ClipDownloader.cacheEntries();
      expect(entries.any((e) => e.name.endsWith('.part')), isFalse,
          reason: '.part 不是成品，不进清单');

      await ClipDownloader.enforceCacheLimit();
      final after = await ClipDownloader.cacheBytes();
      expect(after, lessThanOrEqualTo(64 * mb));
      // ★ 真实读盘复核：成品那部分必须和读数一致（读数不许少报）
      var onDisk = 0;
      await for (final e in Directory(clipDir).list(followLinks: false)) {
        if (e is! File) continue;
        if (e.path.endsWith('.part')) continue;
        onDisk += await e.length();
      }
      expect(onDisk, after, reason: '★ 读数必须等于磁盘上成品的真实占用');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  2：正在下载的成品绝不被删（洞①：探针 P10 的删空）
  // ════════════════════════════════════════════════════════════════════
  group('2 正在下载的成品不被淘汰（并发不再删空）', () {
    test('busy 的成品既不进 total 也不进候选集', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      for (var i = 0; i < 6; i++) {
        await makeFile(clip('old-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: i)));
      }
      // 模拟「刚 rename 完、download() 还没收尾」的 4 个新成品
      for (var i = 0; i < 4; i++) {
        final f = await makeFile(clip('fresh-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: 100 + i)));
        ClipDownloader.debugMarkBusy(f.path);
      }
      expect(ClipDownloader.debugBusyCount, 4);

      await ClipDownloader.enforceCacheLimit();
      for (var i = 0; i < 4; i++) {
        expect(File(clip('fresh-$i.mp4')).existsSync(), isTrue,
            reason: '★ 刚下完的 fresh-$i 不许被淘汰（洞①）');
      }
    });

    test('★ 4 个并发 enforce 不再把目录删空（P10 的确定性复刻）', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      // 6 个旧种子 60MB
      for (var i = 0; i < 6; i++) {
        await makeFile(clip('seed-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: i)));
      }
      // 4 个「正在下载」的新成品 40MB（合计 100MB，超 64MB）
      final freshPaths = <String>[];
      for (var i = 0; i < 4; i++) {
        final f = await makeFile(clip('dl-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: 100 + i)));
        freshPaths.add(f.path);
        ClipDownloader.debugMarkBusy(f.path);
      }

      // 4 个并发淘汰（修之前每个各自读快照、各删各的 ⇒ 删空）
      await Future.wait(List.generate(4, (_) => ClipDownloader.enforceCacheLimit()));

      for (final p in freshPaths) {
        expect(File(p).existsSync(), isTrue,
            reason: '★ 刚下完的 $p 必须还在（P10 修之前 0/4 全灭）');
      }
      final left = await ClipDownloader.cacheEntries();
      expect(left.length, greaterThanOrEqualTo(4),
          reason: '★ 至少 4 个在下载的成品要活着（修之前是 0 个）');
      /*
       * ★ 上限守的是「**可淘汰**的那部分」——正在下载的成品是**豁免**的。
       *   这不是放宽：豁免是**瞬态**的（download() 一收尾就摘掉 busy），
       *   下一次下载或用户点「按上限清理」时它立刻参与计数。
       *   反过来说，如果这里改用 `cacheBytes()`（含 busy）去断言，
       *   就等于要求「把用户刚下完的文件删掉来达标」—— 那正是洞①。
       */
      var evictable = 0;
      for (final e in left) {
        if (!e.busy) evictable += e.bytes;
      }
      expect(evictable, lessThanOrEqualTo(64 * mb),
          reason: '★ 可淘汰的那部分必须守在上限以内');
      expect(await ClipDownloader.cacheBytes(), greaterThan(64 * mb),
          reason: '读数如实包含豁免中的成品（不瞒报磁盘占用）');
    });

    test('★ 同名并发：一个收尾不许撤掉另一个的豁免（引用计数）', () async {
      final path = clip('same-name.mp4');
      await makeFile(path, 1 * mb);
      // 两个 download() 撞同一个 fileName ⇒ 两个持有者
      ClipDownloader.debugMarkBusy(path);
      ClipDownloader.debugMarkBusy(path);
      expect(ClipDownloader.debugBusyRefCount(path), 2);
      ClipDownloader.debugUnmarkBusy(path);
      expect(ClipDownloader.debugBusyRefCount(path), 1,
          reason: '★ 还有一个人在写盘 ⇒ 豁免不能撤（裸 Set 的 remove 会撤掉）');
      expect((await ClipDownloader.cacheEntries()).first.busy, isTrue);
      ClipDownloader.debugUnmarkBusy(path);
      expect(ClipDownloader.debugBusyRefCount(path), 0, reason: '计数归 0 才注销');
      expect((await ClipDownloader.cacheEntries()).first.busy, isFalse);
    });

    test('摘掉 busy 之后才允许被淘汰', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final f = await makeFile(clip('big.mp4'), 100 * mb);
      ClipDownloader.debugMarkBusy(f.path);
      await ClipDownloader.enforceCacheLimit();
      expect(File(f.path).existsSync(), isTrue, reason: 'busy 期间不许删');
      ClipDownloader.debugClearBusy();
      await ClipDownloader.enforceCacheLimit();
      expect(File(f.path).existsSync(), isFalse, reason: '不再 busy 就该按上限删掉');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  3：clearCache 的语义与范围一个字没改（t63 的钉子）
  // ════════════════════════════════════════════════════════════════════
  group('3 clearCache 只清 clip-cache（不碰截图与播放器缓存）', () {
    test('清空片段缓存后，shots 与 mpv-cache 原封不动（P6）', () async {
      await makeFile(clip('c1.mp4'), 1 * mb);
      await makeFile(clip('c2.mp4'), 1 * mb);
      final s = await makeFile(shot('shot-1.png'), 2 * mb);
      final m = await makeFile(mpv('mpv-1.bin'), 3 * mb);

      final n = await ClipDownloader.clearCache();
      expect(n, 2, reason: '只删 clip-cache 里的 2 个');
      expect(File(s.path).existsSync(), isTrue, reason: '★ 截图不许动');
      expect(File(m.path).existsSync(), isTrue, reason: '★ 播放器缓存不许动');
      expect(await ClipDownloader.cacheBytes(), 0);
    });

    test('clearMpvCache 只清 mpv-cache', () async {
      await makeFile(clip('c1.mp4'), 1 * mb);
      final s = await makeFile(shot('shot-1.png'), 2 * mb);
      await makeFile(mpv('mpv-1.bin'), 3 * mb);
      final n = await ClipDownloader.clearMpvCache();
      expect(n, 1);
      expect(File(clip('c1.mp4')).existsSync(), isTrue, reason: '片段不许动');
      expect(File(s.path).existsSync(), isTrue, reason: '截图不许动');
      expect(await ClipDownloader.mpvCacheBytes(), 0);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  4：三个目录的读数（洞③：shots 以前零读数）
  // ════════════════════════════════════════════════════════════════════
  group('4 三目录读数与合计', () {
    test('shotsBytes / totalBytes 报的是真实占用', () async {
      await makeFile(clip('c1.mp4'), 1 * mb);
      await makeFile(mpv('m1.bin'), 2 * mb);
      await makeFile(shot('s1.png'), 3 * mb);
      expect(await ClipDownloader.shotsBytes(), 3 * mb,
          reason: '★ 截图占用以前**根本没有读数**（P2：209715200 字节无人知）');
      expect(await ClipDownloader.mpvCacheBytes(), 2 * mb);
      expect(await ClipDownloader.cacheBytes(), 1 * mb);
      expect(await ClipDownloader.totalBytes(), 6 * mb, reason: '1+2+3');
    });

    test('目录不存在时读数是 0，不抛', () async {
      expect(await ClipDownloader.shotsBytes(), 0);
      expect(await ClipDownloader.mpvCacheBytes(), 0);
      expect(await ClipDownloader.totalBytes(), 0);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  5：按上限清理（三个目录，按「先扔最不值钱的」顺序）
  // ════════════════════════════════════════════════════════════════════
  group('5 sweepAllLimits：三目录合计压回上限', () {
    test('未超限：一个都不删，如实返回 0', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      await makeFile(clip('c1.mp4'), 1 * mb);
      await makeFile(shot('s1.png'), 1 * mb);
      final r = await ClipDownloader.sweepAllLimits();
      expect(r.nothingDeleted, isTrue);
      expect(r.deletedTotal, 0);
      expect(ClipDownloader.describeSweep(r), contains('无需清理'));
    });

    test('★ 先删播放器缓存；够用就绝不动截图', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      await makeFile(clip('c1.mp4'), 10 * mb);
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      for (var i = 0; i < 4; i++) {
        await makeFile(mpv('m$i.bin'), 50 * mb,
            mtime: base.add(Duration(minutes: i)));
      }
      final s = await makeFile(shot('s1.png'), 5 * mb);
      expect(await ClipDownloader.totalBytes(), 215 * mb);

      final r = await ClipDownloader.sweepAllLimits();
      expect(r.mpvDeleted, greaterThan(0), reason: '先动最便宜的播放器缓存');
      expect(r.shotsDeleted, 0, reason: '★ 够用就不许碰用户截图');
      expect(File(s.path).existsSync(), isTrue);
      expect(r.clipDeleted, 0, reason: '片段只占 10MB，还没轮到它');
      expect(r.bytesAfter, lessThanOrEqualTo(64 * mb));
    });

    test('★ 只有 mpv 不够时才动截图，且删的是最旧的', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      // mpv 只有 10MB（清光也不够），shots 100MB，合计 110MB > 64MB
      await makeFile(mpv('m0.bin'), 10 * mb, mtime: base);
      for (var i = 0; i < 10; i++) {
        await makeFile(shot('s$i.png'), 10 * mb,
            mtime: base.add(Duration(minutes: 10 + i)));
      }

      final r = await ClipDownloader.sweepAllLimits();
      expect(r.mpvDeleted, 1);
      expect(r.shotsDeleted, greaterThan(0), reason: '①②都不够 ⇒ 才动最后一档');
      expect(File(shot('s0.png')).existsSync(), isFalse, reason: '删最旧的截图');
      expect(File(shot('s9.png')).existsSync(), isTrue, reason: '留最新的');
      expect(r.bytesAfter, lessThanOrEqualTo(64 * mb));
      expect(ClipDownloader.describeSweep(r), contains('截图'),
          reason: '★ 删了截图必须在结果里明说，不能混成一句「已清理」');
    });

    test('结果对象逐项可读（UI 靠它给用户交代）', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      await makeFile(mpv('m0.bin'), 100 * mb);
      final r = await ClipDownloader.sweepAllLimits();
      expect(r.limitBytes, 64 * mb);
      expect(r.deletedTotal, r.clipDeleted + r.mpvDeleted + r.shotsDeleted);
      expect(r.touchedShots, isFalse);
      expect(ClipDownloader.describeSweep(r), contains('播放器缓存'));
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  6：真实下载路径 —— 「下载成功」之后文件必须还在（洞② 的端到端钉）
  // ════════════════════════════════════════════════════════════════════
  group('6 真实下载：刚下完的成品不许被自己的淘汰删掉', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        unawaited(() async {
          final body = List<int>.filled(1 * mb, 65);
          req.response
            ..statusCode = 200
            ..headers.contentLength = body.length;
          req.response.add(body);
          await req.response.close();
        }());
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('超限时下载：文件在、读数 <= 上限、mtime 是完成时刻', () async {
      UiPrefs.set(ClipDownloader.kCacheLimitKey, '64');
      final base = DateTime(2026, 10, 7, 19, 0, 0);
      // 塞满：8 个 10MB 旧文件 = 80MB，已超 64MB
      for (var i = 0; i < 8; i++) {
        await makeFile(clip('old-$i.mp4'), 10 * mb,
            mtime: base.add(Duration(minutes: i)));
      }
      final url =
          'http://${server.address.address}:${server.port}/ep.mp4';
      final started = DateTime.now();
      final r = await ClipDownloader.download(
        url: url,
        fileName: 'this-episode.mp4',
      );
      expect(File(r.path).existsSync(), isTrue,
          reason: '★ 下载成功之后文件必须还在（P4：修之前刚下完就被当最旧删掉）');
      expect(ClipDownloader.debugBusyCount, 0,
          reason: 'download() 收尾后必须把 busy 登记摘干净');
      final st = await File(r.path).stat();
      expect(st.modified.isAfter(started.subtract(const Duration(seconds: 5))),
          isTrue,
          reason: '★ mtime 必须是完成时刻（rename 会保留 .part 的旧 mtime）');
      expect(await ClipDownloader.cacheBytes(), lessThanOrEqualTo(64 * mb),
          reason: '上限依然守住');
    });
  });
}
