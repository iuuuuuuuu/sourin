// ═══════════════════════════════════════════════════════════════════════
//  task-11 ① 窗口无响应 —— 主 isolate 阻塞取证（探针，不入库）
// ═══════════════════════════════════════════════════════════════════════
//
// # 要证明什么
// Owner 原话：「下载的过程中还出现窗口变那种无响应状态的样子…再过一会儿就又好了」。
// Windows 判「无响应」的硬定义：窗口消息队列 >5 秒没被处理。
// 本探针量的是**主 isolate 事件循环被同步占用的最长时长**（max block），
// 以及 16ms 心跳的实际间隔分布 —— 那是 UI 掉帧的直接读数。
//
// # 四个假设（lead 排序），本探针逐条读：
//   H1 sink.add 大块 + flush 挤占 UI 帧
//   H2 AppLog.write → debugPrint 在 release 也写 stdout，同步 print 阻塞
//   H3 Windows Defender 实时扫描 .part（外部因素，探针只能标注）
//   H4 DownloadQueue._publish() 每 8 片一次 → ValueNotifier → 重建整树
//
// # 仪器
// 心跳 Timer.periodic(4ms) 记录每次回调的「距上次的间隔」。
// 事件循环被同步占用时，Timer 回调必然被推迟 ⇒ 间隔的峰值 = 阻塞峰值。
// ★ 心跳间隔本身就包含了我们的测量开销，所以取 4ms（远小于 16ms 帧预算）。
//
// ⚠️ 必须用 flutter_tester 跑（真事件循环），不是 build 成 exe。
//    因为要精确控制上游字节数/分片数，真网络做不到可重复。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

// ── 心跳仪器 ─────────────────────────────────────────────────────────
class Heartbeat {
  Heartbeat(this.period);
  final Duration period;
  Timer? _t;
  int _last = 0;
  int beats = 0;
  /// 每个间隔（ms）
  final List<int> gaps = <int>[];
  int maxGapMs = 0;
  void start() {
    _last = DateTime.now().microsecondsSinceEpoch;
    _t = Timer.periodic(period, (_) {
      final now = DateTime.now().microsecondsSinceEpoch;
      final gapUs = now - _last;
      _last = now;
      beats++;
      gaps.add(gapUs ~/ 1000);
      final ms = gapUs ~/ 1000;
      if (ms > maxGapMs) maxGapMs = ms;
    });
  }
  void stop() => _t?.cancel();
  /// 超过 [budgetMs] 的心跳数（= 掉帧次数）
  int over(int budgetMs) => gaps.where((g) => g > budgetMs).length;
  String describe(int budgetMs) {
    final sorted = [...gaps]..sort();
    int pct(double p) => sorted.isEmpty ? 0 : sorted[(p * (sorted.length - 1)).round()];
    return 'beats=${beats} maxGap=${maxGapMs}ms p50=${pct(0.5)}ms '
        'p95=${pct(0.95)}ms over>=${budgetMs}ms=${over(budgetMs)}次';
  }
}

Directory _sandboxRoot() {
  final base = Directory.systemTemp.absolute.path;
  final p = '$base\\t11_block';
  final d = Directory(p);
  if (!d.isAbsolute) {
    fail('★ 探针沙盒必须是绝对路径，实际 = $p');
  }
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 上游：HLS 清单 + N 个分片，每片 [segBytes] 字节
class Upstream {
  Upstream(this.segCount, this.segBytes);
  final int segCount;
  final int segBytes;
  late HttpServer _srv;
  int get port => _srv.port;
  int bytesServed = 0;
  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      final path = req.uri.path;
      if (path == '/master.m3u8') {
        // 主清单：指一个媒体清单
        final body = <String>['#EXTM3U', '#EXT-X-STREAM-INF:BANDWIDTH=2000000', 'media.m3u8', ''].join('\n');
        req.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(body);
        await req.response.close();
        return;
      }
      if (path == '/media.m3u8') {
        final b = StringBuffer(<String>['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:4', ''].join('\n'));
        for (var i = 0; i < segCount; i++) {
          b.write('#EXTINF:4.0,' + '\n' + 'seg$i.ts' + '\n');
        }
        b.write('#EXT-X-ENDLIST' + '\n');
        req.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(b.toString());
        await req.response.close();
        return;
      }
      if (path.startsWith('/seg')) {
        final body = List<int>.filled(segBytes, 0xAB);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        bytesServed += body.length;
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }
  Future<void> close() => _srv.close(force: true);
}

DownloadTask _task(String k) => DownloadTask(
      id: 'block-$k',
      title: '探针剧',
      episodeTitle: '第1集',
      provider: 'cctv',
      mediaId: 'm1',
      episodeId: 'ep1',
      sourceCode: 'src',
      fileName: 'block-$k.mp4',
    );

Future<void> _waitIdle() async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DownloadQueue.activeCount > 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}



// ═══════════════════════════════════════════════════════════════════════
//  ② 假设逐条排除：H2 日志 / H4 监听者 / 大分片
// ═══════════════════════════════════════════════════════════════════════

void _hypotheses() {
  test('H2 AppLog.write 日志风暴：主 isolate 阻塞', () async {
    AppLog.debugSetEnabled(true);
    final hb = Heartbeat(const Duration(milliseconds: 4))..start();
    final sw = Stopwatch()..start();
    // 模拟「每片一条日志」的极端情形：3000 条
    for (var i = 0; i < 3000; i++) {
      AppLog.write('DL', '探针日志 #$i ' * 4);
    }
    sw.stop();
    hb.stop();
    debugPrint('MEASURE H2 3000 条 AppLog.write elapsed=${sw.elapsedMilliseconds}ms ' +
        '${hb.describe(16)}');
    debugPrint('MEASURE H2 最长阻塞 = ${hb.maxGapMs} ms');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('H4 _publish 有监听者时（每 8 片一次广播）的代价', () async {
    // 起一个真实下载，同时挂一个会重建的监听者
    const segCount = 300;
    const segBytes = 256 * 1024;
    final ups = Upstream(segCount, segBytes);
    await ups.start();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${ups.port}/master.m3u8'));
    final dir = Directory('${_sandboxRoot().path}\\h4')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(dir.path);
    var rebuilds = 0;
    var itemsSeen = 0;
    void listener() {
      rebuilds++;
      itemsSeen += DownloadQueue.tasks.value.length;
    }
    DownloadQueue.tasks.addListener(listener);
    final hb = Heartbeat(const Duration(milliseconds: 4))..start();
    DownloadQueue.enqueue(_task('h4'));
    await _waitIdle();
    hb.stop();
    DownloadQueue.tasks.removeListener(listener);
    debugPrint('MEASURE H4 广播次数=$rebuilds 心跳 ${hb.describe(16)}');
    debugPrint('MEASURE H4 最长阻塞 = ${hb.maxGapMs} ms');
    await ups.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('大分片（8 MB/片，贴近真实 1080p）', () async {
    const segCount = 24;
    const segBytes = 8 * 1024 * 1024;
    final ups = Upstream(segCount, segBytes);
    await ups.start();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${ups.port}/master.m3u8'));
    final dir = Directory('${_sandboxRoot().path}\\big')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(dir.path);
    final hb = Heartbeat(const Duration(milliseconds: 4))..start();
    DownloadQueue.enqueue(_task('big'));
    await _waitIdle();
    hb.stop();
    final t = DownloadQueue.tasks.value.first;
    debugPrint('MEASURE 大分片 state=${t.state} bytesServed=${ups.bytesServed} ' +
        '${hb.describe(16)}');
    debugPrint('MEASURE 大分片 最长阻塞 = ${hb.maxGapMs} ms');
    await ups.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

void main() {
  _hypotheses();
  setUp(() {
    DownloadQueue.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });
  tearDown(() {
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  test('① HLS 整片下载：主 isolate 最长阻塞 / 帧间隔', () async {
    // 24 集 × 每集 300 片 × 每片 256KB ≈ 1.8 GB（贴近一集真实体量）
    const segCount = 300;
    const segBytes = 256 * 1024;
    final ups = Upstream(segCount, segBytes);
    await ups.start();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${ups.port}/master.m3u8'));
    final dir = Directory('${_sandboxRoot().path}\\hls')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(dir.path);

    // 打开日志（H2：debugPrint 在写出）
    AppLog.debugSetEnabled(true);

    final hb = Heartbeat(const Duration(milliseconds: 4))..start();
    final sw = Stopwatch()..start();
    DownloadQueue.enqueue(_task('hls'));
    await _waitIdle();
    sw.stop();
    hb.stop();

    final t = DownloadQueue.tasks.value.first;
    debugPrint('MEASURE HLS state=${t.state} done=${t.done}/${t.total} '
        'bytesServed=${ups.bytesServed} elapsed=${sw.elapsedMilliseconds}ms');
    debugPrint('MEASURE HLS 心跳 ${hb.describe(16)}');
    debugPrint('MEASURE HLS 最长阻塞 = ${hb.maxGapMs} ms');
    debugPrint('MEASURE HLS 掉帧(>16ms) = ${hb.over(16)} 次 / ${hb.beats} 拍');
    debugPrint('MEASURE HLS 严重阻塞(>100ms) = ${hb.over(100)} 次');
    debugPrint('MEASURE HLS >1s = ${hb.over(1000)} 次');
    await ups.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('① 对照：同样的工作量但**不下载**（纯心跳基线）', () async {
    final hb = Heartbeat(const Duration(milliseconds: 4))..start();
    final sw = Stopwatch()..start();
    // 做等量的「写文件」但不走下载路径：手工 openWrite + sink.add
    final dir = Directory('${_sandboxRoot().path}\\baseline')..createSync(recursive: true);
    final f = File('${dir.path}\\b.ts');
    final sink = f.openWrite();
    final buf = List<int>.filled(256 * 1024, 0xAB);
    for (var i = 0; i < 300; i++) {
      sink.add(buf);
      if (i % 8 == 0) await sink.flush();
    }
    await sink.flush();
    await sink.close();
    sw.stop();
    hb.stop();
    debugPrint('MEASURE 基线(纯 sink.add 300x256KB) elapsed=${sw.elapsedMilliseconds}ms '
        '${hb.describe(16)}');
    debugPrint('MEASURE 基线 最长阻塞 = ${hb.maxGapMs} ms');
  }, timeout: const Timeout(Duration(minutes: 2)));
}