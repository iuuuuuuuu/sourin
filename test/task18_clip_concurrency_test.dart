// ═══════════════════════════════════════════════════════════════════════
//  task-18 独立复核（android-phone）—— ③ 并发池：真并行，不是串行伪装
// ═══════════════════════════════════════════════════════════════════════
//
// 为什么这个文件由复核者自己写、而不是采信 player-features 的自述：
//
// Lead 的判据 3 原文：
// > 光证明「上限生效」不够，还要证明**它真的并行**：把并发设为 2 或以上，
// > 跑**至少 2 个**同时下载，断言 `ClipDownloader.maxObservedActive >= 2`。
// > 否则一个**串行**下载器也能满足「不超过上限」，那是假通过。
//
// ★ 我 grep 过：`test/` 里对 `maxObservedActive` / `clip_download` / `AppLog`
//   的命中数**全部为 0** ⇒ 这条判据此前**没有任何测试覆盖**。
//   本文件是它的第一份独立证据。
//
// # ★★ 证据强度：服务端自己数并发连接 + 时间重叠
//
// 最弱的形式是「信一个内部计数器」。本文件用**本地 HttpServer 数并发**：
// 服务端每收到一个请求就 +1，并**保持响应 400ms 不结束**。
// 于是「服务端同时开着 N 个连接」是**外部可观测事实**，
// 不依赖 `ClipDownloader` 自己的 `_active` 记账 —— 两边都断言，互为交叉验证。
//
// 走的是**公开 API**（`ClipDownloader.download`），不新增任何探针钩子、
// 不改 `lib/` 一个字节 ⇒ 复核不污染被测对象。
//
// # ★ 为什么不用「一次性闸门」而用「固定保持时长」
//
// 第一版用 `Completer` 闸门 + `pending.first.complete()`，隐含假设
// 「先发起的那个下载先到达服务端」。**这个假设不成立**（谁先到达不由调用
// 顺序决定）⇒ 放行了 A 的闸门却去 `await B`，测试自己挂死 30s。
// 那是**测试自身的缺陷（假阴性）**，不是被测代码的问题。
// 固定保持时长没有顺序假设：并发度 = 时间轴上的重叠，天然与顺序无关。
//
// ⚠️ 不碰真实用户数据：全程 `debugSetDataDir` 指向系统临时目录。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('t18_review_');
    ClipDownloader.debugSetDataDir(tmp.path);
    UiPrefs.debugResetForTest();
    ClipDownloader.debugResetProbeCounters();
  });

  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    UiPrefs.debugResetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ── 一个「慢速」HTTP 服务端：每个请求保持 hold 毫秒才回 200 ──────────
  late HttpServer server;
  var serverConcurrent = 0;
  var serverPeak = 0;
  var serverTotal = 0;
  var hold = const Duration(milliseconds: 400);
  final body = List<String>.filled(100, '0123456789').join(); // 1000 字节

  Future<void> startServer() async {
    serverConcurrent = 0;
    serverPeak = 0;
    serverTotal = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      unawaited(() async {
        serverTotal++;
        serverConcurrent++;
        if (serverConcurrent > serverPeak) serverPeak = serverConcurrent;
        await Future<void>.delayed(hold);
        req.response
          ..statusCode = 200
          ..headers.contentLength = body.length;
        req.response.write(body);
        await req.response.close();
        serverConcurrent--;
      }());
    });
  }

  Future<void> stopServer() async {
    await server.close(force: true);
  }

  String url(String name) =>
      'http://${server.address.address}:${server.port}/$name';

  group('③ 上限语义（纯读，无网络）', () {
    test('默认 4；非法值回落默认；clamp 到 0..8', () {
      expect(ClipDownloader.defaultConcurrency, 4);
      expect(ClipDownloader.concurrency, 4, reason: '未设置时用产品默认值');

      UiPrefs.set(ClipDownloader.kConcurrencyKey, '99');
      expect(ClipDownloader.concurrency, 8, reason: '上限是 8');

      UiPrefs.set(ClipDownloader.kConcurrencyKey, '-3');
      expect(ClipDownloader.concurrency, 0, reason: '下限是 0（= 不限制）');

      UiPrefs.set(ClipDownloader.kConcurrencyKey, 'abc');
      expect(ClipDownloader.concurrency, 4, reason: '解析不了回落默认，不抛');
    });

    test('concurrencyLabel：0 读作「不限制」，其余读作「N 个」', () {
      expect(ClipDownloader.concurrencyLabel(0), '不限制');
      expect(ClipDownloader.concurrencyLabel(3), '3 个');
    });

    test('键名就是 Lead 判据里的那两个（防改名）', () {
      expect(ClipDownloader.kConcurrencyKey, 'dsh.download.concurrency');
      expect(ClipDownloader.kCacheLimitKey, 'dsh.cache.limitMb');
    });
  });

  group('③ 并发池 —— ★ 真并行（Lead 判据 3 的核心）', () {
    setUp(startServer);
    tearDown(stopServer);

    test('★ 上限=2：服务端**同时**开着 2 个连接（真并行，不是串行伪装）', () async {
      hold = const Duration(milliseconds: 400);
      ClipDownloader.setConcurrency(2);
      ClipDownloader.debugResetProbeCounters();

      final sw = Stopwatch()..start();
      final r = await Future.wait([
        ClipDownloader.download(
            url: url('a.mp4'), fileName: 'a.mp4', enforceLimitAfter: false),
        ClipDownloader.download(
            url: url('b.mp4'), fileName: 'b.mp4', enforceLimitAfter: false),
      ]);
      sw.stop();

      expect(r[0].bytes, body.length);
      expect(r[1].bytes, body.length);
      expect(
        serverPeak,
        2,
        reason: '★ 服务端峰值只有 1 ⇒ 池子是**串行**的。那正是判据 3 要防的假通过：'
            '串行下载器也能满足「不超过上限」',
      );
      expect(serverTotal, 2);
      expect(
        ClipDownloader.maxObservedActive,
        greaterThanOrEqualTo(2),
        reason: '★ Lead 判据 3 的原始断言：maxObservedActive >= 2',
      );
      // 交叉验证：两个请求在时间轴上真的重叠（2 × 400ms 串行要 ≥800ms）
      expect(
        sw.elapsedMilliseconds,
        lessThan(760),
        reason: '★ 若串行，两个 400ms 请求要 ≥800ms；实测 ${sw.elapsedMilliseconds}ms',
      );
      expect(ClipDownloader.activeCount, 0, reason: '完成后槽位归零');
    });

    test('★ 上限=1：服务端**峰值永远是 1**，3 个下载被串行化', () async {
      hold = const Duration(milliseconds: 300);
      ClipDownloader.setConcurrency(1);
      ClipDownloader.debugResetProbeCounters();

      final sw = Stopwatch()..start();
      await Future.wait([
        for (var i = 0; i < 3; i++)
          ClipDownloader.download(
              url: url('s$i.mp4'),
              fileName: 's$i.mp4',
              enforceLimitAfter: false),
      ]);
      sw.stop();

      expect(serverTotal, 3, reason: '三个都该跑到');
      expect(
        serverPeak,
        1,
        reason: '★ 上限=1 ⇒ 服务端**任何时刻**都只该有 1 个连接',
      );
      expect(ClipDownloader.maxObservedActive, 1, reason: '★ 峰值始终 1');
      expect(
        sw.elapsedMilliseconds,
        greaterThanOrEqualTo(850),
        reason: '★ 3 × 300ms 串行 ⇒ 至少 900ms；实测 ${sw.elapsedMilliseconds}ms。'
            '若远小于此，说明它们并行了 —— 上限没起作用',
      );
      expect(ClipDownloader.activeCount, 0);
    });

    test('★ 改**大**上限：setConcurrency 立刻放行排队者（不等第一个结束）', () async {
      hold = const Duration(milliseconds: 700);
      ClipDownloader.setConcurrency(1);
      ClipDownloader.debugResetProbeCounters();

      final f1 = ClipDownloader.download(
          url: url('e.mp4'), fileName: 'e.mp4', enforceLimitAfter: false);
      final f2 = ClipDownloader.download(
          url: url('f.mp4'), fileName: 'f.mp4', enforceLimitAfter: false);

      // 等到第一个请求确实进了服务端（第二个还被池子拦着）
      for (var i = 0; i < 40 && serverTotal < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(serverTotal, 1, reason: '第二个此刻还被池子拦着');
      expect(serverPeak, 1);

      // ★ 关键：**不**等第一个结束，直接把上限拉到 3
      ClipDownloader.setConcurrency(3);
      for (var i = 0; i < 60 && serverPeak < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        serverPeak,
        2,
        reason: '★ setConcurrency 必须调 _wakeWaiters —— 否则用户拉大滑杆会「看着没反应」'
            '（clip_download.dart:161-168 的注释承诺了这一点）',
      );

      await Future.wait([f1, f2]);
      expect(serverTotal, 2);
    });

    test('0 = 不限制：10 个请求全部同时到达服务端', () async {
      hold = const Duration(milliseconds: 400);
      ClipDownloader.setConcurrency(0);
      ClipDownloader.debugResetProbeCounters();

      await Future.wait([
        for (var i = 0; i < 10; i++)
          ClipDownloader.download(
              url: url('n$i.mp4'),
              fileName: 'n$i.mp4',
              enforceLimitAfter: false),
      ]);

      expect(serverTotal, 10);
      expect(serverPeak, 10, reason: '0 = 不限制 ⇒ 全部同时放行');
      expect(ClipDownloader.maxObservedActive, greaterThanOrEqualTo(10));
    });
  });

  group('③ 失败路径（池子不会因为异常泄漏槽位）', () {
    test('HTTP 500 ⇒ 抛 ClipDownloadException，且槽位归零、不留 .part', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(() async {
        await for (final req in s) {
          req.response.statusCode = 500;
          await req.response.close();
        }
      }());
      addTearDown(() => s.close(force: true));

      ClipDownloader.setConcurrency(2);
      await expectLater(
        ClipDownloader.download(
            url: 'http://${s.address.address}:${s.port}/x.mp4',
            fileName: 'x.mp4',
            enforceLimitAfter: false),
        throwsA(isA<ClipDownloadException>()),
      );
      expect(ClipDownloader.activeCount, 0, reason: '★ 失败也要在 finally 里还槽位');
      final leftovers = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();
      expect(leftovers, isEmpty, reason: '失败不留 .part 残骸');
    });
  });
}