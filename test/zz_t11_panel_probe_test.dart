// ═══════════════════════════════════════════════════════════════════════
//  task-11 ②③④ 实测探针：下载 → 面板 → 暂停/继续/删除 → 整剧删除
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真跑（不能用假的 assert）
// Owner 要的是「暂停啊 删除啊」「已经下载好的就可以播放 可以删除」——
// 这些**都会真碰盘**。只断言状态字段变了毫无意义：
// ★ 要证明的是「暂停之后 .part **真的还在**且长度 >0」「删除之后文件真的没了」。
//
// # 三件真事
// ① 真 HttpServer 当上游（真 m3u8 + 真分片字节）
// ② 真 DownloadQueue → 真 HlsDownloader → 真写盘
// ③ 每个动作后**读文件系统**（File.exists/length）作为独立佐证
//
// ⚠️ 沙盒在 %TEMP% 下，**断言绝对路径**（照抄 t3_20 探针的事故修复）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

Directory _sandboxRoot() {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t11_panel';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 上游：故意每片慢一点，好让「暂停」有机会落在分片边界之间
class Upstream {
  Upstream(this.segCount, this.segBytes, this.delayMs);
  final int segCount;
  final int segBytes;
  final int delayMs;
  late HttpServer _srv;
  int get port => _srv.port;
  int served = 0;
  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      final path = req.uri.path;
      if (path == '/master.m3u8') {
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(
            <String>['#EXTM3U', '#EXT-X-STREAM-INF:BANDWIDTH=2000000', 'media.m3u8', '']
                .join('\n'));
        await req.response.close();
        return;
      }
      if (path == '/media.m3u8') {
        final b = StringBuffer(
            <String>['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:4', '']
                .join('\n'));
        for (var i = 0; i < segCount; i++) {
          b.write('#EXTINF:4.0,' + '\n' + 'seg$i.ts' + '\n');
        }
        b.write('#EXT-X-ENDLIST' + '\n');
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(b.toString());
        await req.response.close();
        return;
      }
      if (path.startsWith('/seg')) {
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        final body = List<int>.filled(segBytes, 0xCD);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        served++;
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }
  Future<void> close() => _srv.close(force: true);
}

DownloadTask _task(String title, int k) => DownloadTask(
      id: 'cctv:m1:ep$k',
      title: title,
      episodeTitle: '第${k + 1}集',
      provider: 'cctv',
      mediaId: 'm1',
      episodeId: 'ep$k',
      sourceCode: 'src',
      fileName: '第${(k + 1).toString().padLeft(2, '0')}集 探针',
      cover: 'https://example.invalid/c.jpg',
    );

/// ★ 等某个任务到达**终态**（done/failed）。
///
/// 为什么不能等 `activeCount == 0`：
///   暂停后点「继续」的那一刻，任务会先变成 queued，而 _settling 还没清空 ⇒
///   `activeCount` 可能瞬时为 0 ⇒ `_waitFor(activeCount==0)` **提前返回** ⇒ 断言读到 queued。
///   这是**探针的等待判据错**，不是产品错。
Future<void> _waitTerminal(String id, {int timeoutMs = 120000}) async {
  final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(dl)) {
    final t = DownloadQueue.tasks.value.where((x) => x.id == id).toList();
    if (t.isEmpty) return;
    final s = t.first.state;
    if (s == DownloadState.done || s == DownloadState.failed) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// ★★ 等目录里的文件**不再变化**（连续 [quietMs] 内两次清点结果相同）
///
/// # 为什么需要（Lead 2026-10-10 抓到的一处真竞态）
/// `DownloadQueue._run` 里 **`state=done` 是先发布、后写旁文件**的：
/// ```text
/// download_queue.dart:1038-1046  copyWith(state: done) + _publish()   ← 任务变 done
/// download_queue.dart:1059-1061  await _writeSidecarFor(t, dir)      ← 之后才写
///                                    └─ 内含 cacheCoverImage(url) 的
///                                       8s 连接 / 20s 读取超时
/// ```
/// 而探针的 [_waitTerminal] 只看 `state` ⇒ 它一看到 done 就返回，
/// 此刻 `_sourin-cache.json` **可能还没落盘**（封面 URL 不可达时会卡满超时）。
/// ⇒ 紧接着手工清点目录就比预览少一个文件 ⇒ ④ 那条断言偶发
/// `Expected: <6> / Actual: <7>`（差 1 正好是旁文件），**与产品缺陷无关**。
///
/// ⇒ 这里显式等「安静」：目录连续两次清点结果相同且间隔 `[quietMs]` 才算稳。
Future<int> _stableFileCount(Directory dir, {
  int quietMs = 900,
  int timeoutMs = 40000,
}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  var last = -1;
  var sameSince = DateTime.now();
  while (DateTime.now().isBefore(deadline)) {
    var n = 0;
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) n++;
      }
    }
    if (n == last) {
      if (DateTime.now().difference(sameSince).inMilliseconds >= quietMs) return n;
    } else {
      last = n;
      sameSince = DateTime.now();
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  return last;
}

Future<void> _waitFor(bool Function() pred, {int timeoutMs = 30000}) async {
  final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!pred() && DateTime.now().isBefore(dl)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Upstream ups;
  late String dir;

  setUp(() async {
    DownloadQueue.debugReset();
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
    // 每片慢 25ms ⇒ 300 片要 ~7.5s，足够在边界观察到暂停
    ups = Upstream(300, 64 * 1024, 25);
    await ups.start();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${ups.port}/master.m3u8'));
    final d = Directory('${_sandboxRoot().path}${Platform.pathSeparator}work')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(d.path);
    dir = d.path;
  });

  tearDown(() async {
    await ups.close();
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  test('③ 暂停 ⇒ .part 在盘上且长度>0；继续 ⇒ 接着下完（不重下）', () async {
    DownloadQueue.enqueue(_task('探针剧', 0));
    // 等它真的开始下了一些分片
    await _waitFor(() {
      final t = DownloadQueue.tasks.value.first;
      return t.state == DownloadState.running && t.done >= 8;
    }, timeoutMs: 20000);
    final servedAtPause = ups.served;
    final okPause = DownloadQueue.pause('cctv:m1:ep0');
    debugPrint('MEASURE 暂停调用返回 = $okPause');
    // 等暂停生效（状态变 paused，且槽位归还）
    await _waitFor(() =>
        DownloadQueue.tasks.value.first.state == DownloadState.paused,
        timeoutMs: 10000);
    final t1 = DownloadQueue.tasks.value.first;
    final part = File('$dir${Platform.pathSeparator}探针剧${Platform.pathSeparator}第01集 探针.ts.part');
    final partAlt = File('$dir${Platform.pathSeparator}探针剧${Platform.pathSeparator}第01集 探针.part');
    final exists = part.existsSync() || partAlt.existsSync();
    final len = part.existsSync()
        ? part.lengthSync()
        : (partAlt.existsSync() ? partAlt.lengthSync() : 0);
    debugPrint('MEASURE 暂停后 state=${t1.state} done=${t1.done}/${t1.total}');
    debugPrint('MEASURE 暂停后 .part 存在=$exists 长度=$len 字节');
    debugPrint('MEASURE 暂停后 服务器已发片段数=${ups.served}（暂停前 $servedAtPause）');
    expect(t1.state, DownloadState.paused, reason: '暂停后状态必须是 paused');
    expect(exists, isTrue, reason: '★ 暂停必须保留 .part（已下分片一片不丢）');
    expect(len, greaterThan(0), reason: '★ .part 必须有内容');

    // 继续
    final doneBefore = t1.done;
    final servedBefore = ups.served;
    final okResume = DownloadQueue.resume('cctv:m1:ep0');
    debugPrint('MEASURE 继续调用返回 = $okResume settling=${DownloadQueue.debugSettlingCount()}');
    // ★ 等**终态**而不是等 activeCount —— 见 _waitTerminal 的注释
    await _waitTerminal('cctv:m1:ep0');
    final t2 = DownloadQueue.tasks.value.first;
    debugPrint('MEASURE 继续后 state=${t2.state} done=${t2.done}/${t2.total} '
        'doneBefore=$doneBefore servedBefore=$servedBefore servedNow=${ups.served}');
    expect(t2.state, DownloadState.done, reason: '继续后必须下完');
    /*
     * ★★ 续传的硬证据：继续时**没有重下**前面的分片。
     *   继续后服务器新增发的分片数 = total - doneBefore（近似，±1 片并发窗口）。
     */
    final delta = ups.served - servedBefore;
    debugPrint('MEASURE 续传：继续后新增分片=$delta（若重下会是 ${t2.total}）');
    expect(delta, lessThan(t2.total),
        reason: '★ 必须少于总片数 —— 否则就是从头重下了');
    final finalFile = File('$dir${Platform.pathSeparator}探针剧${Platform.pathSeparator}第01集 探针.ts');
    debugPrint('MEASURE 完成后落定文件存在=' +
        '${finalFile.existsSync()} 长度=' +
        '${finalFile.existsSync() ? finalFile.lengthSync() : 0}');
    expect(finalFile.existsSync(), isTrue, reason: '完成后应有 .ts 成品');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('③ 删除单集 ⇒ 文件从盘上消失（真删真读）', () async {
    DownloadQueue.enqueue(_task('探针剧', 1));
    await _waitTerminal('cctv:m1:ep1');
    final f = File('$dir${Platform.pathSeparator}探针剧${Platform.pathSeparator}第02集 探针.ts');
    debugPrint('MEASURE 删除前 成品存在=${f.existsSync()} '
        '长度=${f.existsSync() ? f.lengthSync() : 0}');
    expect(f.existsSync(), isTrue, reason: '前置：应已下完');
    final nBefore = DownloadQueue.tasks.value.length;
    await DownloadQueue.remove('cctv:m1:ep1');
    final nAfter = DownloadQueue.tasks.value.length;
    debugPrint('MEASURE 删除后 成品存在=${f.existsSync()} '
        '队列 ${nBefore} → $nAfter');
    expect(f.existsSync(), isFalse, reason: '★ 删除后文件必须真的没了');
    expect(nAfter, nBefore - 1, reason: '★ 队列里也该少一条');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('④ 整剧删除：先预览（列出将删什么）→ 真删 → 目录消失', () async {
    for (var k = 0; k < 3; k++) {
      DownloadQueue.enqueue(_task('探针剧', k + 2));
    }
    for (var k = 0; k < 3; k++) {
      await _waitTerminal('cctv:m1:ep${k + 2}');
    }
    final workDir = Directory('$dir${Platform.pathSeparator}探针剧');
    // ★ 先等目录安静下来（旁文件在 state=done **之后**才写，见 _stableFileCount 注释）
    final files = await _stableFileCount(workDir);
    var bytes = 0;
    await for (final e in workDir.list()) {
      if (e is File) {
        bytes += (await e.length()).toInt();
      }
    }
    debugPrint('MEASURE 整剧删除前 目录存在=${workDir.existsSync()} '
        '文件数=$files 合计=${(bytes / 1048576).toStringAsFixed(2)} MB');
    expect(files, greaterThan(0), reason: '前置：目录里应有成品');

    // ① 预览（不真删）
    final p = await DownloadQueue.previewRemoveWork('探针剧');
    debugPrint('MEASURE 预览 fileCount=${p.fileCount} sizeText=${p.sizeText} '
        'episodeCount=${p.episodeCount} names=${p.fileNames.take(3).toList()}');
    expect(p.fileCount, files, reason: '预览的文件数必须与实际一致');
    expect(workDir.existsSync(), isTrue, reason: '★ 预览**不许**真删');

    // ② 演练（force 缺省 false）——也不许删
    final dry = await DownloadQueue.removeWork('探针剧');
    debugPrint('MEASURE 演练 deleted=${dry.deleted} 目录还在=${workDir.existsSync()}');
    expect(dry.deleted, isFalse, reason: '★ 没传 force 时不许真删');
    expect(workDir.existsSync(), isTrue, reason: '★ 演练后目录必须还在');

    // ③ 真删
    final q = await DownloadQueue.removeWork('探针剧', force: true);
    debugPrint('MEASURE 真删 deleted=${q.deleted} '
        'deletedFiles=${q.deletedFiles} '
        'deletedBytes=${q.deletedBytes} '
        '(${(q.deletedBytes / 1048576).toStringAsFixed(2)} MB) '
        '目录还在=${workDir.existsSync()} '
        '队列剩=${DownloadQueue.tasks.value.length}');
    expect(q.deleted, isTrue);
    expect(q.deletedFiles, files, reason: '★ 报的删除数必须与实际一致');
    expect(workDir.existsSync(), isFalse, reason: '★ 真删后目录必须消失');
    expect(DownloadQueue.tasks.value.length, 0, reason: '★ 队列里该剧全部任务应清空');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('② 面板：任务出现/清空时 tasks 通知面正确', () async {
    expect(DownloadQueue.tasks.value, isEmpty, reason: '初始应为空（面板整块不画）');
    var notifications = 0;
    void lis() => notifications++;
    DownloadQueue.tasks.addListener(lis);
    DownloadQueue.enqueue(_task('探针剧', 5));
    await _waitTerminal('cctv:m1:ep5');
    DownloadQueue.tasks.removeListener(lis);
    debugPrint('MEASURE 面板通知次数=$notifications 末状态=' +
        '${DownloadQueue.tasks.value.first.state}');
    expect(notifications, greaterThan(0), reason: '★ 必须有通知（否则面板不会更新）');
    expect(DownloadQueue.tasks.value.first.state, DownloadState.done);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
